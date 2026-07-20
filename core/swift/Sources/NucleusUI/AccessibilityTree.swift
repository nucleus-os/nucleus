import Tracy

package struct AccessibilityPublicationMetrics: Sendable, Equatable {
    package var nodesVisited: UInt64 = 0
    package var cachedSubtreesReused: UInt64 = 0
    package var nodesInserted: UInt64 = 0
    package var nodesUpdated: UInt64 = 0
    package var nodesRemoved: UInt64 = 0
    package var eventsEmitted: UInt64 = 0

    package init() {}
}

@MainActor
public final class AccessibilityTree: ~Sendable {
    private typealias ActionHandler =
        @MainActor (AccessibilityActionRequest) -> Bool

    private struct Signature: Equatable {
        var structure: UInt64
        var geometry: UInt64
        var visibility: UInt64
        var transform: UInt64
        var scrolling: UInt64
        var accessibility: UInt64
        var subtreeStructure: UInt64
        var subtreeGeometry: UInt64
        var subtreeVisibility: UInt64
        var subtreeTransform: UInt64
        var subtreeScrolling: UInt64
        var subtreeAccessibility: UInt64
    }

    private struct SubtreeResult {
        var roots: [AccessibilityID]
        var nodes: [AccessibilityID: AccessibilityNodeSnapshot]
        var handlers: [AccessibilityID: ActionHandler]

        static let empty = SubtreeResult(
            roots: [],
            nodes: [:],
            handlers: [:])
    }

    private struct CacheRecord {
        var signature: Signature
        var parentID: AccessibilityID?
        var windowID: WindowID
        var windowFrame: Rect
        var result: SubtreeResult
    }

    private weak var scene: WindowScene?
    private var cache: [ViewID: CacheRecord] = [:]
    private var handlers: [AccessibilityID: ActionHandler] = [:]
    public private(set) var snapshot = AccessibilityTreeSnapshot()
    package private(set) var lastMetrics =
        AccessibilityPublicationMetrics()
    private var currentMetrics = AccessibilityPublicationMetrics()

    package init(scene: WindowScene) {
        self.scene = scene
    }

    /// Publish a stable flat snapshot and the smallest semantic diff from the
    /// preceding publication.
    ///
    /// Clean subtrees are reused from their generation cache. A geometry change
    /// on an ancestor rebuilds descendant frames, but an unrelated value or
    /// selection change does not walk clean sibling subtrees.
    @discardableResult
    public func publish() -> AccessibilityTreeUpdate {
        currentMetrics = AccessibilityPublicationMetrics()
        guard let scene else {
            return AccessibilityTreeUpdate(
                revision: snapshot.revision,
                rootIDs: [],
                inserted: [],
                updated: [],
                removed: [],
                notifications: [])
        }

        var nextNodes: [AccessibilityID: AccessibilityNodeSnapshot] = [:]
        var nextHandlers: [AccessibilityID: ActionHandler] = [:]
        var rootIDs: [AccessibilityID] = []
        var contexts: [ObjectIdentifier: UIContext] = [:]

        for window in scene.windows where window.isVisible {
            contexts[ObjectIdentifier(window.uiContext)] = window.uiContext
            let windowParentID = window.accessibilityID
            let content = window.root.map {
                build(
                    view: $0,
                    parentID: windowParentID,
                    window: window,
                    ancestorGeometryChanged: false)
            } ?? .empty

            let windowNode = AccessibilityNodeSnapshot(
                id: windowParentID,
                parentID: nil,
                childIDs: content.roots,
                windowID: window.id,
                role: windowAccessibilityRole(window),
                label: window.title.isEmpty ? nil : window.title,
                description: nil,
                value: nil,
                state: windowState(window),
                actions: [],
                orientation: nil,
                rangeValue: nil,
                textSelection: nil,
                relationships: [:],
                frameInScene: window.frame,
                liveRegion: .off)
            nextNodes[windowParentID] = windowNode
            nextNodes.merge(content.nodes) { _, latest in latest }
            nextHandlers.merge(content.handlers) { _, latest in latest }
            rootIDs.append(windowParentID)
        }

        var notifications = contexts.values.flatMap {
            $0.takeAccessibilityNotifications()
        }
        let oldNodes = snapshot.nodes
        let oldIDs = Set(oldNodes.keys)
        let nextIDs = Set(nextNodes.keys)
        let inserted = nextIDs.subtracting(oldIDs)
            .sorted()
            .compactMap { nextNodes[$0] }
        let removed = oldIDs.subtracting(nextIDs).sorted()
        let updated = nextIDs.intersection(oldIDs)
            .sorted()
            .compactMap { id -> AccessibilityNodeSnapshot? in
                guard let old = oldNodes[id], let next = nextNodes[id],
                      old != next
                else { return nil }
                appendDerivedNotifications(
                    from: old,
                    to: next,
                    into: &notifications)
                return next
            }

        for node in inserted {
            notifications.append(
                AccessibilityNotification(
                    kind: .structure,
                    target: node.id))
        }
        for id in removed {
            notifications.append(
                AccessibilityNotification(
                    kind: .structure,
                    target: id))
        }
        notifications = deduplicated(notifications)
        currentMetrics.nodesInserted = UInt64(inserted.count)
        currentMetrics.nodesUpdated = UInt64(updated.count)
        currentMetrics.nodesRemoved = UInt64(removed.count)
        currentMetrics.eventsEmitted = UInt64(notifications.count)

        let rootsChanged = rootIDs != snapshot.rootIDs
        let changed = !inserted.isEmpty
            || !updated.isEmpty
            || !removed.isEmpty
            || !notifications.isEmpty
            || rootsChanged
        let revision = changed ? snapshot.revision &+ 1 : snapshot.revision
        precondition(
            revision != 0 || !changed,
            "accessibility tree revision exhausted")
        snapshot = AccessibilityTreeSnapshot(
            revision: revision,
            rootIDs: rootIDs,
            nodes: nextNodes)
        handlers = nextHandlers
        lastMetrics = currentMetrics
        publishMetrics(lastMetrics)

        return AccessibilityTreeUpdate(
            revision: revision,
            rootIDs: rootIDs,
            inserted: inserted,
            updated: updated,
            removed: removed,
            notifications: notifications)
    }

    /// Invoke an action against the currently published semantic identity.
    ///
    /// Adapters marshal requests onto the main actor and call this method; stale
    /// IDs fail normally after their element leaves the latest snapshot.
    @discardableResult
    public func perform(_ request: AccessibilityActionRequest) -> Bool {
        guard snapshot.nodes[request.target]?.actions.contains(
            request.action) == true,
            let handler = handlers[request.target]
        else { return false }
        return handler(request)
    }

    private func build(
        view: View,
        parentID: AccessibilityID?,
        window: Window,
        ancestorGeometryChanged: Bool
    ) -> SubtreeResult {
        currentMetrics.nodesVisited &+= 1
        let signature = signature(for: view)
        let ownGeometryChanged: Bool
        if let old = cache[view.id] {
            ownGeometryChanged =
                old.signature.geometry != signature.geometry
                || old.signature.transform != signature.transform
                || old.signature.scrolling != signature.scrolling
        } else {
            ownGeometryChanged = true
        }
        if !ancestorGeometryChanged,
           let old = cache[view.id],
           old.signature == signature,
           old.parentID == parentID,
           old.windowID == window.id,
           old.windowFrame == window.frame
        {
            currentMetrics.cachedSubtreesReused &+= 1
            return old.result
        }

        guard !view.isHidden else {
            let result = SubtreeResult.empty
            cache[view.id] = CacheRecord(
                signature: signature,
                parentID: parentID,
                windowID: window.id,
                windowFrame: window.frame,
                result: result)
            return result
        }

        let isElement = view.isAccessibilityElement
        let semanticParent = isElement ? view.accessibilityID : parentID
        let normalChildren = view.storedAccessibilityChildren
            ?? view.childViews.map { $0 as any Accessible }
        var childResults: [SubtreeResult] = []
        childResults.reserveCapacity(normalChildren.count)
        for child in normalChildren {
            guard let childView = child as? View else { continue }
            childResults.append(build(
                view: childView,
                parentID: semanticParent,
                window: window,
                ancestorGeometryChanged:
                    ancestorGeometryChanged || ownGeometryChanged))
        }

        let virtualElements =
            view.storedAccessibilityVirtualChildrenProvider?() ?? []
        for virtual in virtualElements {
            childResults.append(build(
                virtual: virtual,
                owner: view,
                parentID: semanticParent,
                window: window))
        }

        var result = SubtreeResult.empty
        for child in childResults {
            result.nodes.merge(child.nodes) { _, latest in latest }
            result.handlers.merge(child.handlers) { _, latest in latest }
        }
        let childRoots = childResults.flatMap(\.roots)

        if isElement {
            let properties = resolvedProperties(for: view)
            let actions = actions(for: view)
                .union(view.storedAccessibilityActions.keys)
            let node = AccessibilityNodeSnapshot(
                id: view.accessibilityID,
                parentID: parentID,
                childIDs: childRoots,
                windowID: window.id,
                role: properties.role ?? .group,
                label: resolvedLabel(for: view, properties: properties),
                description: properties.description ?? properties.hint,
                value: secureValue(for: view, properties: properties),
                state: state(for: view, properties: properties),
                actions: actions,
                orientation: resolvedOrientation(
                    for: view,
                    properties: properties),
                rangeValue: resolvedRangeValue(
                    for: view,
                    properties: properties),
                textSelection: resolvedTextSelection(
                    for: view,
                    properties: properties),
                relationships: properties.relationships,
                frameInScene: sceneFrame(of: view, in: window),
                liveRegion: properties.liveRegion)
            result.nodes[node.id] = node
            result.roots = [node.id]
            result.handlers[node.id] = actionHandler(for: view)
        } else {
            result.roots = childRoots
        }

        cache[view.id] = CacheRecord(
            signature: signature,
            parentID: parentID,
            windowID: window.id,
            windowFrame: window.frame,
            result: result)
        return result
    }

    private func build(
        virtual: AccessibilityVirtualElement,
        owner: View,
        parentID: AccessibilityID?,
        window: Window
    ) -> SubtreeResult {
        currentMetrics.nodesVisited &+= 1
        var childResults: [SubtreeResult] = []
        childResults.reserveCapacity(virtual.children.count)
        for child in virtual.children {
            childResults.append(build(
                virtual: child,
                owner: owner,
                parentID: virtual.id,
                window: window))
        }
        var result = SubtreeResult.empty
        for child in childResults {
            result.nodes.merge(child.nodes) { _, latest in latest }
            result.handlers.merge(child.handlers) { _, latest in latest }
        }
        let properties = virtual.properties
        let childIDs = childResults.flatMap(\.roots)
        let localInWindow = owner.convert(virtual.frame, to: nil)
        let node = AccessibilityNodeSnapshot(
            id: virtual.id,
            parentID: parentID,
            childIDs: childIDs,
            windowID: window.id,
            role: properties.role ?? .group,
            label: properties.label,
            description: properties.description ?? properties.hint,
            value: properties.traits.contains(.secureText)
                ? nil
                : properties.value,
            state: state(from: properties, actions: virtual.actions),
            actions: virtual.actions,
            orientation: properties.orientation,
            rangeValue: properties.rangeValue,
            textSelection: properties.traits.contains(.secureText)
                ? nil
                : properties.textSelection,
            relationships: properties.relationships,
            frameInScene: window.sceneRect(fromWindow: localInWindow),
            liveRegion: properties.liveRegion)
        result.nodes[node.id] = node
        result.roots = [node.id]
        if let handler = virtual.actionHandler {
            result.handlers[node.id] = handler
        }
        return result
    }

    private func signature(for view: View) -> Signature {
        Signature(
            structure: view.dirtyGenerations.structure,
            geometry: view.dirtyGenerations.geometry,
            visibility: view.dirtyGenerations.visibility,
            transform: view.dirtyGenerations.transform,
            scrolling: view.dirtyGenerations.scrolling,
            accessibility: view.dirtyGenerations.accessibility,
            subtreeStructure: view.subtreeDirtyGenerations.structure,
            subtreeGeometry: view.subtreeDirtyGenerations.geometry,
            subtreeVisibility: view.subtreeDirtyGenerations.visibility,
            subtreeTransform: view.subtreeDirtyGenerations.transform,
            subtreeScrolling: view.subtreeDirtyGenerations.scrolling,
            subtreeAccessibility:
                view.subtreeDirtyGenerations.accessibility)
    }

    private func sceneFrame(of view: View, in window: Window) -> Rect {
        window.sceneRect(fromWindow: view.convert(view.bounds, to: nil))
    }

    private func resolvedProperties(
        for view: View
    ) -> AccessibilityProperties {
        var properties = view.accessibilityProperties
        if let field = view as? TextField {
            properties.traits.insert(.editable)
            if field.isSecure {
                properties.traits.insert(.secureText)
                properties.value = nil
                properties.textSelection = nil
            }
            if field.allowsMultilineText {
                properties.traits.insert(.multiline)
                properties.role = .textArea
            }
        }
        if let toggle = view as? Toggle, toggle.isOn {
            properties.traits.insert(.checked)
        }
        return properties
    }

    private func resolvedLabel(
        for view: View,
        properties: AccessibilityProperties
    ) -> String? {
        if let label = properties.label { return label }
        if let button = view as? Button, !button.title.isEmpty {
            return button.title
        }
        if let label = view as? Label, !label.text.isEmpty {
            return label.text
        }
        return nil
    }

    private func secureValue(
        for view: View,
        properties: AccessibilityProperties
    ) -> String? {
        if properties.traits.contains(.secureText)
            || (view as? TextField)?.isSecure == true
        {
            return nil
        }
        return properties.value
    }

    private func state(
        for view: View,
        properties: AccessibilityProperties
    ) -> AccessibilityState {
        var result = state(from: properties)
        result.insert(.visible)
        if view.acceptsFirstResponder { result.insert(.focusable) }
        if view.isFocused { result.insert(.focused) }
        if let control = view as? Control {
            if control.isEnabled { result.insert(.enabled) }
            if control.isSelected { result.insert(.selected) }
        } else if !properties.traits.contains(.disabled) {
            result.insert(.enabled)
        }
        return result
    }

    private func state(
        from properties: AccessibilityProperties,
        actions: Set<AccessibilityAction> = []
    ) -> AccessibilityState {
        var result: AccessibilityState = [.visible]
        if !properties.traits.contains(.disabled) {
            result.insert(.enabled)
        }
        if properties.traits.contains(.selected) {
            result.insert(.selected)
        }
        if properties.traits.contains(.checked) {
            result.insert(.checked)
        }
        if properties.traits.contains(.expanded) {
            result.insert(.expanded)
        }
        if properties.traits.contains(.editable) {
            result.insert(.editable)
        }
        if properties.traits.contains(.secureText) {
            result.insert(.secure)
        }
        if properties.traits.contains(.modal) {
            result.insert(.modal)
        }
        if properties.traits.contains(.multiline) {
            result.insert(.multiline)
        }
        if actions.contains(.focus) {
            result.insert(.focusable)
        }
        return result
    }

    private func actions(for view: View) -> Set<AccessibilityAction> {
        var result: Set<AccessibilityAction> = []
        if view.acceptsFirstResponder {
            result.insert(.focus)
        }
        if view is Control,
           !(view is TextField),
           !(view is Slider),
           !(view is RangeSlider)
        {
            result.insert(.press)
        }
        if view is Slider {
            result.formUnion([.increment, .decrement, .setValue])
        }
        if let field = view as? TextField, !field.isSecure {
            result.formUnion([
                .setText, .setSelection, .copy, .cut, .paste,
                .selectAll, .undo, .redo,
            ])
        }
        return result
    }

    private func actionHandler(for view: View) -> ActionHandler {
        { [weak view] request in
            guard let view else { return false }
            if let custom = view.storedAccessibilityActions[request.action] {
                return custom(request)
            }
            switch request.action {
            case .focus:
                return view.window?.makeFirstResponder(view) == true
            case .press, .select:
                guard let control = view as? Control else { return false }
                return control.performPrimaryAction(
                    event: Event(type: .action)) != .notHandled
            case .increment, .decrement:
                let key: KeyCode = request.action == .increment
                    ? .rightArrow
                    : .leftArrow
                return view.handleEvent(Event(
                    type: .keyDown,
                    keyCode: key)) != .notHandled
            case .setValue:
                guard let slider = view as? Slider,
                      let value = request.value
                else { return false }
                slider.value = value
                return true
            case .setText:
                guard let field = view as? TextField,
                      !field.isSecure,
                      let text = request.text
                else { return false }
                field.stringValue = text
                return true
            case .setSelection:
                guard let field = view as? TextField,
                      !field.isSecure,
                      let selection = request.selection
                else { return false }
                field.setSelectedRange(selection.utf16Range)
                return true
            case .copy:
                return view.performAction(
                    .copy,
                    event: Event(type: .action))
            case .cut:
                return view.performAction(
                    .cut,
                    event: Event(type: .action))
            case .paste:
                return view.performAction(
                    .paste,
                    event: Event(type: .action))
            case .selectAll:
                return view.performAction(
                    .selectAll,
                    event: Event(type: .action))
            case .undo:
                return view.performAction(
                    .undo,
                    event: Event(type: .action))
            case .redo:
                return view.performAction(
                    .redo,
                    event: Event(type: .action))
            case .expand, .collapse, .dismiss:
                return false
            }
        }
    }

    private func resolvedRangeValue(
        for view: View,
        properties: AccessibilityProperties
    ) -> AccessibilityRangeValue? {
        if let range = properties.rangeValue { return range }
        if let slider = view as? Slider {
            return AccessibilityRangeValue(
                minimum: slider.minimumValue,
                maximum: slider.maximumValue,
                current: slider.value,
                increment: slider.step)
        }
        if let progress = view as? ProgressIndicator {
            return AccessibilityRangeValue(
                minimum: 0,
                maximum: 1,
                current: progress.progress)
        }
        return nil
    }

    private func resolvedTextSelection(
        for view: View,
        properties: AccessibilityProperties
    ) -> AccessibilityTextSelection? {
        if let field = view as? TextField, !field.isSecure {
            return AccessibilityTextSelection(
                utf16Range: field.selectedRange)
        }
        return properties.textSelection
    }

    private func resolvedOrientation(
        for view: View,
        properties: AccessibilityProperties
    ) -> AccessibilityOrientation? {
        if let orientation = properties.orientation { return orientation }
        if let progress = view as? ProgressIndicator {
            return progress.orientation == .vertical
                ? .vertical
                : .horizontal
        }
        if view is Slider || view is RangeSlider {
            return .horizontal
        }
        return nil
    }

    private func windowAccessibilityRole(
        _ window: Window
    ) -> AccessibilityRole {
        if window.root?.accessibilityRole == .dialog { return .dialog }
        if window.root?.accessibilityRole == .alert { return .alert }
        if window.role == .popup || window.role == .overlay { return .popover }
        return .window
    }

    private func windowState(_ window: Window) -> AccessibilityState {
        var state: AccessibilityState = [.enabled, .visible]
        if window.isKeyWindow { state.insert(.active) }
        if window.focusScopeRecords.contains(where: {
            $0.root?.focusScopeBehavior == .modal
        }) {
            state.insert(.modal)
        }
        return state
    }

    private func appendDerivedNotifications(
        from old: AccessibilityNodeSnapshot,
        to next: AccessibilityNodeSnapshot,
        into notifications: inout [AccessibilityNotification]
    ) {
        if old.frameInScene != next.frameInScene {
            notifications.append(.init(kind: .bounds, target: next.id))
        }
        if old.value != next.value
            || old.rangeValue != next.rangeValue
        {
            notifications.append(.init(kind: .value, target: next.id))
        }
        let selectionMask: AccessibilityState = [.selected, .checked]
        if old.textSelection != next.textSelection
            || old.state.intersection(selectionMask)
                != next.state.intersection(selectionMask)
        {
            notifications.append(.init(
                kind: .selection,
                target: next.id))
        }
        if old.parentID != next.parentID
            || old.childIDs != next.childIDs
        {
            notifications.append(.init(
                kind: .structure,
                target: next.id))
        }
        if old.liveRegion != next.liveRegion,
           next.liveRegion != .off
        {
            notifications.append(.init(
                kind: .liveRegion,
                target: next.id,
                announcement: next.value ?? next.label))
        }
    }

    private func deduplicated(
        _ notifications: [AccessibilityNotification]
    ) -> [AccessibilityNotification] {
        var seen: Set<NotificationKey> = []
        return notifications.filter {
            seen.insert(NotificationKey($0)).inserted
        }
    }

    private func publishMetrics(
        _ metrics: AccessibilityPublicationMetrics
    ) {
        Trace.plot(
            "swift.nucleus.accessibility.nodes_visited",
            metrics.nodesVisited)
        Trace.plot(
            "swift.nucleus.accessibility.cached_subtrees_reused",
            metrics.cachedSubtreesReused)
        Trace.plot(
            "swift.nucleus.accessibility.nodes_inserted",
            metrics.nodesInserted)
        Trace.plot(
            "swift.nucleus.accessibility.nodes_updated",
            metrics.nodesUpdated)
        Trace.plot(
            "swift.nucleus.accessibility.nodes_removed",
            metrics.nodesRemoved)
        Trace.plot(
            "swift.nucleus.accessibility.events_emitted",
            metrics.eventsEmitted)
    }

    private struct NotificationKey: Hashable {
        var kind: AccessibilityNotificationKind
        var target: AccessibilityID?
        var announcement: String?

        init(_ notification: AccessibilityNotification) {
            kind = notification.kind
            target = notification.target
            announcement = notification.announcement
        }
    }
}
