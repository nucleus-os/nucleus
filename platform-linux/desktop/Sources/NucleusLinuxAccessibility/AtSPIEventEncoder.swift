import NucleusLinuxDBus
import NucleusUI

extension AtSPIService {
    // MARK: - Events

    @discardableResult
    func emit(_ event: AtSPIEvent) -> Bool {
        guard connectionPhase == .ready, let connection else { return false }
        let descriptor: (String, String)
        switch event.kind {
        case .windowCreated:
            descriptor = ("org.a11y.atspi.Event.Window", "Create")
        case .windowDestroyed:
            descriptor = ("org.a11y.atspi.Event.Window", "Destroy")
        case .focus:
            descriptor = ("org.a11y.atspi.Event.Focus", "Focus")
        case .stateChanged:
            descriptor = ("org.a11y.atspi.Event.Object", "StateChanged")
        case .propertyChanged:
            descriptor = ("org.a11y.atspi.Event.Object", "PropertyChange")
        case .textChanged:
            descriptor = ("org.a11y.atspi.Event.Object", "TextChanged")
        case .valueChanged:
            descriptor = ("org.a11y.atspi.Event.Object", "PropertyChange")
        case .selectionChanged:
            descriptor = ("org.a11y.atspi.Event.Object", "SelectionChanged")
        case .childrenAdded, .childrenRemoved:
            descriptor = ("org.a11y.atspi.Event.Object", "ChildrenChanged")
        case .boundsChanged:
            descriptor = ("org.a11y.atspi.Event.Object", "BoundsChanged")
        case .announcement, .liveRegion:
            descriptor = ("org.a11y.atspi.Event.Object", "Announcement")
        }
        let result = connection.emitSignal(
            path: event.sourcePath,
            interface: descriptor.0,
            member: descriptor.1
        ) { writer in
            guard writer.string(event.detail) >= 0,
                  writer.int32(event.detail1) >= 0,
                  writer.int32(event.detail2) >= 0
            else { return writer.result }
            let variantResult: Int32
            if let related = event.relatedPath {
                variantResult = writer.variant(signature: "(so)") {
                    $0.objectReference(busName: uniqueName, path: related)
                }
            } else if event.kind == .boundsChanged,
                      let object = model.objects[event.sourcePath]
            {
                variantResult = writer.variant(signature: "(iiii)") {
                    $0.structValue(signature: "iiii") {
                        $0.rect(object.frame)
                    }
                }
            } else {
                variantResult = writer.variant(signature: "s") {
                    $0.string(event.text ?? "")
                }
            }
            guard variantResult >= 0 else { return variantResult }
            return writer.stringVariantDictionary([:])
        }
        guard result >= 0 else {
            transitionToReconnect(after: AtSPIServiceError(
                operation: "emitting AT-SPI event",
                code: result))
            return false
        }
        return true
    }

}
