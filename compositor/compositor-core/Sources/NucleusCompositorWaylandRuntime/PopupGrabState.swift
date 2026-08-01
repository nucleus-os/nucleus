/// Seat-owned XDG popup grab stack. Weak entries preserve Wayland resource
/// ownership while keeping dismissal, delivery redirection, and compaction in
/// one state machine.
@MainActor
final class PopupGrabState {
    private var stack = WeakObjectList<XdgPopup>()

    func begin(_ popup: XdgPopup) {
        compact()
        guard !popup.popupDoneSent else { return }
        if stack.last !== popup {
            stack.append(popup)
        }
    }

    func deliverySurface(fallback: WlSurface) -> WlSurface {
        compact()
        return stack.last?.xdgSurface?.surface ?? fallback
    }

    /// Dismiss the complete grab stack only when the interaction lands outside
    /// every grabbed popup surface.
    func dismissIfOutside(_ target: WlSurface) -> Bool {
        compact()
        guard !stack.isEmpty else { return false }
        let grabbedSurfaceIDs = Set(
            stack.liveValues().compactMap {
                $0.xdgSurface?.surface?.objectId
            })
        guard !grabbedSurfaceIDs.contains(target.objectId) else {
            return false
        }
        cancel()
        return true
    }

    func cancel() {
        compact()
        for popup in stack.liveValues().reversed() {
            popup.sendPopupDone()
        }
        stack.removeAll(keepingCapacity: true)
    }

    private func compact() {
        stack.removeAll { $0.popupDoneSent }
    }
}
