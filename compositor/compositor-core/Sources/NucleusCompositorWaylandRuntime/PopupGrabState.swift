/// Seat-owned XDG popup grab stack. Weak entries preserve Wayland resource
/// ownership while keeping dismissal, delivery redirection, and compaction in
/// one state machine.
@MainActor
final class PopupGrabState {
    private var stack: [WeakReference<XdgPopup>] = []

    func begin(_ popup: XdgPopup) {
        compact()
        guard !popup.popupDoneSent else { return }
        if stack.last?.value !== popup {
            stack.append(WeakReference(popup))
        }
    }

    func deliverySurface(fallback: WlSurface) -> WlSurface {
        compact()
        return stack.last?.value?.xdgSurface?.surface ?? fallback
    }

    /// Dismiss the complete grab stack only when the interaction lands outside
    /// every grabbed popup surface.
    func dismissIfOutside(_ target: WlSurface) -> Bool {
        compact()
        guard !stack.isEmpty else { return false }
        let grabbedSurfaceIDs = Set(stack.compactMap {
            $0.value?.xdgSurface?.surface?.objectId
        })
        guard !grabbedSurfaceIDs.contains(target.objectId) else {
            return false
        }
        cancel()
        return true
    }

    func cancel() {
        compact()
        for popup in stack.reversed().compactMap(\.value) {
            popup.sendPopupDone()
        }
        stack.removeAll(keepingCapacity: true)
    }

    private func compact() {
        stack.removeAll {
            $0.value == nil || $0.value?.popupDoneSent == true
        }
    }
}
