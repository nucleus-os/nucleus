// zwlr_gamma_control_manager_v1 on the router. Lets a privileged client take over
// an output's gamma ramp (night-light / calibration tools). The router owns the
// gamma_size advertisement, the one-controller-per-output arbitration, and reading
// the ramps off the client fd; the DRM side (delegate) reports the ramp size and
// applies/clears the ramps on the physical output.
//
// A new control for an output preempts
// the previous one (which receives `failed`); destroying the active control
// restores the output's default gamma.

import Dispatch
import Glibc
import Synchronization
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

private struct GammaRamp: Sendable {
    var red: [UInt16]
    var green: [UInt16]
    var blue: [UInt16]
}

/// Bounded blocking-I/O isolation for client-owned gamma-ramp files. A hostile
/// filesystem can strand one worker, but cannot strand the compositor actor or
/// create an unbounded number of blocked workers.
private enum GammaRampReader {
    private static let maximumReads = 4
    private static let readsInFlight = Mutex(0)
    private static let queue = DispatchQueue(
        label: "org.nucleus.gamma-ramp-reader",
        qos: .userInitiated,
        attributes: .concurrent)

    static func submit(
        fileDescriptor: Int32,
        size: Int,
        completion: @escaping @MainActor @Sendable (GammaRamp?) -> Void
    ) -> Bool {
        let admitted = readsInFlight.withLock { count in
            guard count < maximumReads else { return false }
            count += 1
            return true
        }
        guard admitted else {
            _ = close(fileDescriptor)
            return false
        }
        queue.async {
            let ramp = read(fileDescriptor: fileDescriptor, size: size)
            _ = close(fileDescriptor)
            readsInFlight.withLock { $0 -= 1 }
            Task { @MainActor in
                completion(ramp)
            }
        }
        return true
    }

    private static func read(
        fileDescriptor: Int32,
        size: Int
    ) -> GammaRamp? {
        let valueCount = size.multipliedReportingOverflow(by: 3)
        guard size > 0, !valueCount.overflow else { return nil }
        let byteCount = valueCount.partialValue.multipliedReportingOverflow(
            by: MemoryLayout<UInt16>.stride)
        guard !byteCount.overflow else { return nil }

        var metadata = stat()
        guard unsafe fstat(fileDescriptor, &metadata) == 0,
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            Int64(metadata.st_size) == Int64(byteCount.partialValue)
        else { return nil }

        var values = [UInt16](
            repeating: 0,
            count: valueCount.partialValue)
        let readSucceeded = values.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            var consumed = 0
            while consumed < bytes.count {
                let result = unsafe pread(
                    fileDescriptor,
                    baseAddress.advanced(by: consumed),
                    bytes.count - consumed,
                    off_t(consumed))
                if result > 0 {
                    consumed += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard readSucceeded else { return nil }
        return GammaRamp(
            red: Array(values[0..<size]),
            green: Array(values[size..<(size * 2)]),
            blue: Array(values[(size * 2)..<(size * 3)]))
    }
}

/// The DRM seam. rampSize is the output's per-channel LUT length (0 = unsupported);
/// apply installs the R/G/B ramps; clear restores the default on destroy.
@MainActor
protocol GammaControlDelegate: AnyObject {
    func gammaRampSize(output: WlOutput?) -> UInt32
    func gammaApply(output: WlOutput?, red: [UInt16], green: [UInt16], blue: [UInt16])
    func gammaClear(output: WlOutput?)
}
@MainActor
@safe final class ZwlrGammaControlManager {
    weak var delegate: (any GammaControlDelegate)?
    /// The active control per output (output identity → control).
    private var controls =
        WeakObjectMap<ObjectIdentifier, ZwlrGammaControl>()

    fileprivate func apply(output: WlOutput?, red: [UInt16], green: [UInt16], blue: [UInt16]) {
        delegate?.gammaApply(output: output, red: red, green: green, blue: blue)
    }

    fileprivate func isActive(
        _ control: ZwlrGammaControl,
        output: WlOutput?
    ) -> Bool {
        guard let output else { return false }
        return controls.value(forKey: ObjectIdentifier(output)) === control
    }

    fileprivate func controlFailed(
        _ control: ZwlrGammaControl,
        output: WlOutput?
    ) {
        guard let output else { return }
        let key = ObjectIdentifier(output)
        guard controls.value(forKey: key) === control else { return }
        controls.removeValue(forKey: key)
        delegate?.gammaClear(output: output)
    }

    /// Called from a control's deinit: clear the output's gamma only if it was still
    /// the active control (a preempted control must not clear the new one's ramps).
    fileprivate func controlDestroyed(_ control: ZwlrGammaControl, output: WlOutput?) {
        guard let output else { return }
        let key = ObjectIdentifier(output)
        if controls.value(forKey: key) === control {
            controls.removeValue(forKey: key)
            delegate?.gammaClear(output: output)
        }
    }

    func outputRemoved(_ output: WlOutput) {
        let key = ObjectIdentifier(output)
        let control = controls.removeValue(forKey: key)
        control?.preempt()
        delegate?.gammaClear(output: output)
    }

    func outputRestored(_ output: WlOutput) {
        controls.value(forKey: ObjectIdentifier(output))?.reapply()
    }

}

// get_gamma_control(id, output). The manager is its own resource owner (owner: me on bind).
extension ZwlrGammaControlManager: ZwlrGammaControlManagerV1Requests {
    func getGammaControl(
        _ request: WaylandRequest<ZwlrGammaControlManagerV1Server>,
        id: WlNewId<ZwlrGammaControlV1Server>,
        output outputRes: WaylandBorrowedObject<WlOutputServer>
    ) {
        let output = outputRes.output
        let size = delegate?.gammaRampSize(output: output) ?? 0
        _ = id.create(
            owner: { handle in
                ZwlrGammaControl(
                    resource: handle,
                    manager: self,
                    output: output,
                    size: size)
            },
            installed: { control in
                guard size > 0, let output else {
                    control.resource.sendFailed()
                    return
                }
                let key = ObjectIdentifier(output)
                let previous = self.controls.value(forKey: key)
                self.controls.insert(control, forKey: key)
                previous?.preempt()
                control.resource.sendGammaSize(size: size)
            })
    }
}

/// zwlr_gamma_control_v1 owner (Rule 9). Reads ramps off the client fd and applies
/// them; restores default gamma on destroy if still the active control.
@MainActor
@safe final class ZwlrGammaControl {
    private weak var manager: ZwlrGammaControlManager?
    private weak var output: WlOutput?
    private let size: UInt32
    fileprivate let resource: WaylandResourceHandle<ZwlrGammaControlV1Server>
    private var currentRamp:
        (
            red: [UInt16], green: [UInt16], blue: [UInt16]
        )?
    private var readInFlight = false
    private var failed = false

    init(
        resource: WaylandResourceHandle<ZwlrGammaControlV1Server>,
        manager: ZwlrGammaControlManager,
        output: WlOutput?,
        size: UInt32
    ) {
        self.resource = resource
        self.manager = manager
        self.output = output
        self.size = size
    }
    /// Preempted by a newer control for the same output: tell the client it failed.
    fileprivate func preempt() {
        guard !failed else { return }
        failed = true
        resource.sendFailed()
    }

    fileprivate func reapply() {
        guard !failed, let currentRamp else { return }
        manager?.apply(
            output: output,
            red: currentRamp.red,
            green: currentRamp.green,
            blue: currentRamp.blue)
    }

    isolated deinit { manager?.controlDestroyed(self, output: output) }

    private func fail() {
        guard !failed else { return }
        failed = true
        manager?.controlFailed(self, output: output)
        resource.sendFailed()
    }

    private func finishedReading(_ ramp: GammaRamp?) {
        readInFlight = false
        guard !failed else { return }
        guard let ramp,
            manager?.isActive(self, output: output) == true
        else {
            fail()
            return
        }
        currentRamp = (ramp.red, ramp.green, ramp.blue)
        manager?.apply(
            output: output,
            red: ramp.red,
            green: ramp.green,
            blue: ramp.blue)
    }
}

// set_gamma(fd): the fd holds 3 * size host-endian uint16 ramps (R, G, B).
extension ZwlrGammaControl: ZwlrGammaControlV1Requests {
    func setGamma(
        _ request: WaylandRequest<ZwlrGammaControlV1Server>,
        fd: consuming WaylandOwnedFileDescriptor
    ) {
        let rawFD = fd.take()
        guard !failed, !readInFlight else {
            _ = close(rawFD)
            fail()
            return
        }
        readInFlight = true
        guard
            GammaRampReader.submit(
                fileDescriptor: rawFD,
                size: Int(size),
                completion: { [weak self] ramp in
                    self?.finishedReading(ramp)
                })
        else {
            readInFlight = false
            fail()
            return
        }
    }
}
