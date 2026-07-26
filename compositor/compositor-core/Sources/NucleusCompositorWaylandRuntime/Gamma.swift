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
                         output outputRes: WaylandBorrowedObject<WlOutputServer>) {
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
    fileprivate let resource:
        WaylandResourceHandle<ZwlrGammaControlV1Server>
    private var currentRamp: (
        red: [UInt16], green: [UInt16], blue: [UInt16]
    )?

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
        resource.sendFailed()
    }

    fileprivate func reapply() {
        guard let currentRamp else { return }
        manager?.apply(
            output: output,
            red: currentRamp.red,
            green: currentRamp.green,
            blue: currentRamp.blue)
    }

    isolated deinit { manager?.controlDestroyed(self, output: output) }
}

// set_gamma(fd): the fd holds 3 * size host-endian uint16 ramps (R, G, B).
extension ZwlrGammaControl: ZwlrGammaControlV1Requests {
    func setGamma(_ request: WaylandRequest<ZwlrGammaControlV1Server>, fd: consuming WaylandOwnedFileDescriptor) {
        let rawFD = fd.take()
        defer { if rawFD >= 0 { close(rawFD) } }
        let count = Int(size) * 3
        let byteCount = count * 2
        var buf = [UInt8](repeating: 0, count: byteCount)
        let n = buf.withUnsafeMutableBytes {
            unsafe pread(rawFD, $0.baseAddress, byteCount, 0)
        }
        guard n == byteCount else {
            resource.sendFailed()
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
