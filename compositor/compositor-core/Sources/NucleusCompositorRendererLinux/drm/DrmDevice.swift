// Phase 10a.1 — Swift DRM device ownership + enumeration policy.
//
// Owns the two leaf DRM resources the device layer holds: a DRM device file
// descriptor (`DrmDeviceFd`) and a GBM device created over one (`GbmDevice`),
// both as noncopyable values with explicit destruction. On top of them sits the
// `drmGetDevices2`-based enumeration and a connector-aware selection policy.
//
// The policy half (candidate filtering + selection) is pure and value-typed, so
// it is exercised against synthetic candidates with no DRM hardware. The
// `enumerate()` half drives real libdrm and runs only where `/dev/dri` exists.

import NucleusCompositorDrmC
import Glibc
import Foundation

// MARK: - Noncopyable resource owners

/// Owns a DRM device file descriptor and closes it on destruction. Noncopyable:
/// exactly one owner, no implicit duplication of the fd. `release()` hands the
/// raw fd to another owner (the seat, or the Swift DRM backend)
/// without closing it.
struct DrmDeviceFd: ~Copyable {
    private(set) var fd: Int32

    /// Take ownership of an already-open DRM fd.
    init(owning fd: Int32) {
        self.fd = fd
    }

    /// Open a DRM node read/write + close-on-exec. Returns nil when the node
    /// can't be opened. Used for the render node; the primary node is opened
    /// through libseat for DRM-master negotiation and handed to `init(owning:)`.
    init?(openingNode path: String) {
        let opened = path.withCString { nucleus_drm_open_device($0) }
        guard opened >= 0 else { return nil }
        self.fd = opened
    }

    var isValid: Bool { fd >= 0 }

    /// Relinquish the fd without closing it, ending this owner. The caller takes
    /// over the close obligation.
    consuming func release() -> Int32 {
        let taken = fd
        discard self
        return taken
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}

/// Owns a `gbm_device*` created over a borrowed DRM fd and destroys it on
/// teardown. GBM does not take ownership of the fd — the `DrmDeviceFd` outlives
/// this and remains responsible for closing it.
struct GbmDevice: ~Copyable {
    private(set) var handle: OpaquePointer?

    /// Create a GBM device over a borrowed DRM fd. Returns nil on failure.
    init?(borrowingFd fd: Int32) {
        guard fd >= 0, let device = gbm_create_device(fd) else { return nil }
        self.handle = device
    }

    var isValid: Bool { handle != nil }

    /// Backend name (e.g. "drm") for diagnostics, or nil if unavailable.
    var backendName: String? {
        guard let handle, let name = gbm_device_get_backend_name(handle) else { return nil }
        return String(cString: name)
    }

    deinit {
        if let handle { gbm_device_destroy(handle) }
    }
}

// MARK: - Enumeration + selection policy (pure, hardware-independent)

/// A DRM device matched during enumeration: the node paths plus the PCI identity
/// the selection policy and downstream Vulkan device matching key on. Value type,
/// copied out of the libdrm `drmDevice` records before they are freed.
struct DrmDeviceCandidate: Sendable, Equatable {
    var renderPath: String
    var primaryPath: String?
    var vendorId: UInt16
    var deviceId: UInt16
    var pciDomain: UInt16
    var pciBus: UInt8
    var pciDev: UInt8
    var pciFunc: UInt8
    /// Connected connectors exposing at least one usable mode. Nil means the
    /// primary node could not be probed before seat acquisition.
    var connectedDisplayCount: Int?
    /// Linux PCI boot-display hint used only when connector topology does not
    /// identify a unique scanout GPU.
    var isBootVGA: Bool

    /// `DDDD:BB:DD.F` PCI address, for diagnostics.
    var pciAddress: String {
        func hex(_ v: UInt64, _ width: Int) -> String {
            let s = String(v, radix: 16)
            return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
        }
        return "\(hex(UInt64(pciDomain), 4)):\(hex(UInt64(pciBus), 2)):\(hex(UInt64(pciDev), 2)).\(hex(UInt64(pciFunc), 1))"
    }
}

/// Why device selection produced no single device.
enum DrmSelectionError: Error, Equatable {
    /// `drmGetDevices2` returned a negative errno.
    case enumerationFailed
    /// No PCI GPU exposed a render node (matching the override, if set).
    case noCandidate
    /// More than one device matched and no override disambiguated them.
    case ambiguousCandidate(count: Int)
}

/// Apply the Nucleus selection policy to already-enumerated candidates. An
/// explicit override always wins. Otherwise prefer the unique GPU driving a
/// connected display, then the unique PCI boot VGA device. Truly ambiguous
/// multi-display/multi-GPU configurations still fail closed.
func selectDrmDevice(
    from candidates: [DrmDeviceCandidate],
    overrideRenderPath: String? = nil
) -> Result<DrmDeviceCandidate, DrmSelectionError> {
    if let want = overrideRenderPath {
        let matched = candidates.filter { $0.renderPath == want }
        switch matched.count {
        case 0: return .failure(.noCandidate)
        case 1: return .success(matched[0])
        default: return .failure(.ambiguousCandidate(count: matched.count))
        }
    }
    switch candidates.count {
    case 0: return .failure(.noCandidate)
    case 1: return .success(candidates[0])
    default: break
    }
    let connected = candidates.filter { ($0.connectedDisplayCount ?? 0) > 0 }
    if connected.count == 1 { return .success(connected[0]) }
    let remaining = connected.isEmpty ? candidates : connected
    let boot = remaining.filter(\.isBootVGA)
    if boot.count == 1 { return .success(boot[0]) }
    return .failure(.ambiguousCandidate(count: remaining.count))
}

// MARK: - libdrm enumeration

enum DrmDeviceEnumerator {
    /// Walk DRM devices via `drmGetDevices2` and project the PCI GPUs that expose
    /// a render node into value-typed candidates (PCI bus + render node
    /// required). Returns the enumeration
    /// errno path as `.failure(.enumerationFailed)`.
    static func enumerate() -> Result<[DrmDeviceCandidate], DrmSelectionError> {
        var devices = [drmDevicePtr?](repeating: nil, count: 32)
        let count = devices.withUnsafeMutableBufferPointer { buf in
            drmGetDevices2(0, buf.baseAddress, Int32(buf.count))
        }
        guard count >= 0 else { return .failure(.enumerationFailed) }
        // `drmGetDevices2` fills at most `buf.count` entries but returns the total
        // device count, which can exceed the buffer on a host with >32 DRM devices.
        // Clamp to the buffer capacity so neither the loop nor `drmFreeDevices`
        // reads past the 32-element array.
        let filled = min(Int(count), devices.count)

        defer {
            devices.withUnsafeMutableBufferPointer { buf in
                drmFreeDevices(buf.baseAddress, Int32(filled))
            }
        }

        var candidates: [DrmDeviceCandidate] = []
        for index in 0..<filled {
            guard let device = devices[index] else { continue }
            let d = device.pointee
            guard d.bustype == DRM_BUS_PCI else { continue }
            guard let pciDevice = d.deviceinfo.pci else { continue }
            guard let pciBus = d.businfo.pci else { continue }
            guard (d.available_nodes & (1 << DRM_NODE_RENDER)) != 0 else { continue }
            guard let renderC = d.nodes[Int(DRM_NODE_RENDER)] else { continue }

            let primary: String?
            if (d.available_nodes & (1 << DRM_NODE_PRIMARY)) != 0,
               let primaryC = d.nodes[Int(DRM_NODE_PRIMARY)] {
                primary = String(cString: primaryC)
            } else {
                primary = nil
            }

            candidates.append(DrmDeviceCandidate(
                renderPath: String(cString: renderC),
                primaryPath: primary,
                vendorId: pciDevice.pointee.vendor_id,
                deviceId: pciDevice.pointee.device_id,
                pciDomain: pciBus.pointee.domain,
                pciBus: pciBus.pointee.bus,
                pciDev: pciBus.pointee.dev,
                pciFunc: pciBus.pointee.func,
                connectedDisplayCount: primary.flatMap(Self.connectedDisplayCount),
                isBootVGA: Self.isBootVGA(
                    domain: pciBus.pointee.domain, bus: pciBus.pointee.bus,
                    device: pciBus.pointee.dev, function: pciBus.pointee.func)))
        }
        return .success(candidates)
    }

    private static func connectedDisplayCount(primaryPath: String) -> Int? {
        guard let fd = DrmDeviceFd(openingNode: primaryPath) else { return nil }
        guard let resources = drmModeGetResources(fd.fd) else { return nil }
        defer { drmModeFreeResources(resources) }
        var count = 0
        for index in 0..<Int(resources.pointee.count_connectors) {
            guard let connector = drmModeGetConnector(fd.fd, resources.pointee.connectors[index]) else { continue }
            defer { drmModeFreeConnector(connector) }
            if connector.pointee.connection == DRM_MODE_CONNECTED,
               connector.pointee.count_modes > 0 { count += 1 }
        }
        return count
    }

    private static func isBootVGA(domain: UInt16, bus: UInt8, device: UInt8, function: UInt8) -> Bool {
        func hex(_ value: UInt64, width: Int) -> String {
            let raw = String(value, radix: 16)
            return String(repeating: "0", count: max(0, width - raw.count)) + raw
        }
        let address = "\(hex(UInt64(domain), width: 4)):\(hex(UInt64(bus), width: 2)):\(hex(UInt64(device), width: 2)).\(hex(UInt64(function), width: 1))"
        let path = "/sys/bus/pci/devices/\(address)/boot_vga"
        return (try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "1"
    }
}

// MARK: - Compositor bring-up discovery entry

private func logDrmDiscover(_ message: String) {
    let line = "drm-discover: \(message)\n"
    line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
}

/// Discover the DRM device for compositor bring-up: enumerate PCI GPUs via libdrm
/// (`drmGetDevices2` through `NucleusCompositorDrmC`), apply the Nucleus selection policy
/// (`NUCLEUS_DRM_PATH` override, then connected-output/boot-VGA policy), require a
/// primary node, and return both device-node paths. Discovery does not open the
/// render node: DMA-BUF feedback needs only its `dev_t`, which the composition
/// root obtains with `stat(2)`.
public func nucleus_drm_discover(
    _ primaryPathOut: UnsafeMutablePointer<CChar>,
    _ primaryPathCap: Int,
    _ renderPathOut: UnsafeMutablePointer<CChar>,
    _ renderPathCap: Int
) -> Bool {
    if primaryPathCap > 0 { primaryPathOut.pointee = 0 }
    if renderPathCap > 0 { renderPathOut.pointee = 0 }

    let override = getenv("NUCLEUS_DRM_PATH").map { String(cString: $0) }
    guard case .success(let candidates) = DrmDeviceEnumerator.enumerate() else {
        logDrmDiscover("DRM enumeration failed")
        return false
    }
    let selected: DrmDeviceCandidate
    switch selectDrmDevice(from: candidates, overrideRenderPath: override) {
    case .success(let candidate):
        selected = candidate
    case .failure(let error):
        logDrmDiscover("DRM device selection failed: \(error)")
        for candidate in candidates {
            let displays = candidate.connectedDisplayCount.map(String.init) ?? "unknown"
            logDrmDiscover("candidate pci=\(candidate.pciAddress) render=\(candidate.renderPath) primary=\(candidate.primaryPath ?? "none") connected_displays=\(displays) boot_vga=\(candidate.isBootVGA)")
        }
        return false
    }
    guard let primary = selected.primaryPath else {
        logDrmDiscover("matched DRM device \(selected.pciAddress) has no primary node")
        return false
    }
    if primaryPathCap > 0 {
        _ = primary.withCString { strncpy(primaryPathOut, $0, primaryPathCap - 1) }
        primaryPathOut[primaryPathCap - 1] = 0
    }
    if renderPathCap > 0 {
        _ = selected.renderPath.withCString {
            strncpy(renderPathOut, $0, renderPathCap - 1)
        }
        renderPathOut[renderPathCap - 1] = 0
    }
    let displays = selected.connectedDisplayCount.map(String.init) ?? "unknown"
    logDrmDiscover("matched DRM device \(selected.pciAddress) render=\(selected.renderPath) primary=\(primary) connected_displays=\(displays) boot_vga=\(selected.isBootVGA)")
    return true
}
