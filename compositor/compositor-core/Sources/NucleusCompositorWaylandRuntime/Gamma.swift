// zwlr_gamma_control_manager_v1 on the router. Lets a privileged client take over
// an output's gamma ramp (night-light / calibration tools). The router owns the
// gamma_size advertisement, the one-controller-per-output arbitration, and reading
// the ramps off the client fd; the DRM side (delegate) reports the ramp size and
// applies/clears the ramps on the physical output.
//
// A new control for an output preempts
// the previous one (which receives `failed`); destroying the active control
// restores the output's default gamma.

import Glibc
import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// The DRM seam. rampSize is the output's per-channel LUT length (0 = unsupported);
/// apply installs the R/G/B ramps; clear restores the default on destroy.
protocol GammaControlDelegate: AnyObject {
    func gammaRampSize(output: WlOutput?) -> UInt32
    func gammaApply(output: WlOutput?, red: [UInt16], green: [UInt16], blue: [UInt16])
    func gammaClear(output: WlOutput?)
}
private final class WeakGammaControl {
    weak var control: ZwlrGammaControl?
    init(_ control: ZwlrGammaControl) { self.control = control }
}

final class ZwlrGammaControlManager {
    weak var delegate: GammaControlDelegate?
    /// The active control per output (output identity → control).
    private var controls: [ObjectIdentifier: WeakGammaControl] = [:]

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_zwlr_gamma_control_manager_v1(), version: 1,
            impl: self, bind: Self.bind)
    }

    fileprivate func apply(output: WlOutput?, red: [UInt16], green: [UInt16], blue: [UInt16]) {
        delegate?.gammaApply(output: output, red: red, green: green, blue: blue)
    }

    /// Called from a control's deinit: clear the output's gamma only if it was still
    /// the active control (a preempted control must not clear the new one's ramps).
    fileprivate func controlDestroyed(_ control: ZwlrGammaControl, output: WlOutput?) {
        guard let output else { return }
        let key = ObjectIdentifier(output)
        if controls[key]?.control === control {
            controls[key] = nil
            delegate?.gammaClear(output: output)
        }
    }

    func outputRemoved(_ output: WlOutput) {
        let key = ObjectIdentifier(output)
        let control = controls.removeValue(forKey: key)?.control
        control?.preempt()
        delegate?.gammaClear(output: output)
    }

    func outputRestored(_ output: WlOutput) {
        controls[ObjectIdentifier(output)]?.control?.reapply()
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: ZwlrGammaControlManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_zwlr_gamma_control_manager_v1(),
            version: Int32(version), id: id, vtable: ZwlrGammaControlManagerV1Server.vtable, owner: me)
    }
}

// get_gamma_control(id, output). The manager is its own resource owner (owner: me on bind).
extension ZwlrGammaControlManager: ZwlrGammaControlManagerV1Requests {
    func getGammaControl(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                         output outputRes: UnsafeMutablePointer<wl_resource>?) {
        let output = WlOutput.from(outputRes)
        let size = delegate?.gammaRampSize(output: output) ?? 0
        let control = ZwlrGammaControl(manager: self, output: output, size: size)
        guard let cres = id.create(vtable: ZwlrGammaControlV1Server.vtable, owner: control) else { return }
        control.bind(cres)
        guard size > 0, let output else {
            zwlr_gamma_control_v1_send_failed(cres)  // unsupported output
            return
        }
        // Preempt any existing control for this output.
        let key = ObjectIdentifier(output)
        let previous = controls[key]?.control
        controls[key] = WeakGammaControl(control)
        previous?.preempt()
        zwlr_gamma_control_v1_send_gamma_size(cres, size)
    }
}

/// zwlr_gamma_control_v1 owner (Rule 9). Reads ramps off the client fd and applies
/// them; restores default gamma on destroy if still the active control.
final class ZwlrGammaControl {
    private weak var manager: ZwlrGammaControlManager?
    private weak var output: WlOutput?
    private let size: UInt32
    private var resource: UnsafeMutablePointer<wl_resource>?
    private var currentRamp: (
        red: [UInt16], green: [UInt16], blue: [UInt16]
    )?

    init(manager: ZwlrGammaControlManager, output: WlOutput?, size: UInt32) {
        self.manager = manager
        self.output = output
        self.size = size
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Preempted by a newer control for the same output: tell the client it failed.
    fileprivate func preempt() {
        if let resource { zwlr_gamma_control_v1_send_failed(resource) }
    }

    fileprivate func reapply() {
        guard let currentRamp else { return }
        manager?.apply(
            output: output,
            red: currentRamp.red,
            green: currentRamp.green,
            blue: currentRamp.blue)
    }

    deinit { manager?.controlDestroyed(self, output: output) }
}

// set_gamma(fd): the fd holds 3 * size host-endian uint16 ramps (R, G, B).
extension ZwlrGammaControl: ZwlrGammaControlV1Requests {
    func setGamma(_ resource: UnsafeMutablePointer<wl_resource>, fd: Int32) {
        defer { if fd >= 0 { close(fd) } }
        let count = Int(size) * 3
        let byteCount = count * 2
        var buf = [UInt8](repeating: 0, count: byteCount)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, byteCount, 0) }
        guard n == byteCount else {
            zwlr_gamma_control_v1_send_failed(resource)
            return
        }
        func u16(_ i: Int) -> UInt16 { UInt16(buf[2 * i]) | (UInt16(buf[2 * i + 1]) << 8) }
        let s = Int(size)
        let red = (0..<s).map { u16($0) }
        let green = (0..<s).map { u16(s + $0) }
        let blue = (0..<s).map { u16(2 * s + $0) }
        currentRamp = (red, green, blue)
        manager?.apply(output: output, red: red, green: green, blue: blue)
    }
}
