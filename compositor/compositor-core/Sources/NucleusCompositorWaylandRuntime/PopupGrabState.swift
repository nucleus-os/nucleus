/// Seat-owned XDG popup grab stack. Weak entries preserve Wayland resource
/// ownership while keeping dismissal, delivery redirection, and compaction in
/// one state machine.
final class PopupGrabState {
    private final class WeakPopup {
        weak var popup: XdgPopup?

        init(_ popup: XdgPopup) {
            self.popup = popup
        }
    }

    private var stack: [WeakPopup] = []

    func begin(_ popup: XdgPopup) {
        compact()
        guard !popup.popupDoneSent else { return }
        if stack.last?.popup !== popup {
            stack.append(WeakPopup(popup))
        }
    }

    func deliverySurface(fallback: WlSurface) -> WlSurface {
        compact()
        return stack.last?.popup?.xdgSurface?.surface ?? fallback
    }

    /// Dismiss the complete grab stack only when the interaction lands outside
    /// every grabbed popup surface.
    func dismissIfOutside(_ target: WlSurface) -> Bool {
        compact()
        guard !stack.isEmpty else { return false }
        let grabbedSurfaceIDs = Set(stack.compactMap {
            $0.popup?.xdgSurface?.surface?.objectId
        })
        guard !grabbedSurfaceIDs.contains(target.objectId) else {
            return false
        }
        cancel()
        return true
    }

    func cancel() {
        compact()
        for popup in stack.reversed().compactMap(\.popup) {
            popup.sendPopupDone()
        }
        stack.removeAll(keepingCapacity: true)
    }

    private func compact() {
        stack.removeAll {
            $0.popup == nil || $0.popup?.popupDoneSent == true
        }
    }
}
