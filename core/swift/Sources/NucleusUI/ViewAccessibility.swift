extension View {
    public var isAccessibilityElement: Bool {
        get { storedAccessibilityProperties.isElement }
        set {
            guard newValue != storedAccessibilityProperties.isElement else {
                return
            }
            storedAccessibilityProperties.isElement = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityLabel: String? {
        get { storedAccessibilityProperties.label }
        set {
            guard newValue != storedAccessibilityProperties.label else {
                return
            }
            storedAccessibilityProperties.label = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityHint: String? {
        get { storedAccessibilityProperties.hint }
        set {
            guard newValue != storedAccessibilityProperties.hint else {
                return
            }
            storedAccessibilityProperties.hint = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityRole: AccessibilityRole? {
        get { storedAccessibilityProperties.role }
        set {
            guard newValue != storedAccessibilityProperties.role else {
                return
            }
            storedAccessibilityProperties.role = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityTraits: AccessibilityTraits {
        get { storedAccessibilityProperties.traits }
        set {
            guard newValue != storedAccessibilityProperties.traits else {
                return
            }
            storedAccessibilityProperties.traits = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityChildren: [any Accessible]? {
        get { storedAccessibilityChildren }
        set {
            storedAccessibilityChildren = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityProperties: AccessibilityProperties {
        get { storedAccessibilityProperties }
        set {
            guard newValue != storedAccessibilityProperties else { return }
            storedAccessibilityProperties = newValue
            recordMutation(.accessibility)
        }
    }

    public var accessibilityVirtualChildrenProvider:
        (@MainActor () -> [AccessibilityVirtualElement])?
    {
        get { storedAccessibilityVirtualChildrenProvider }
        set {
            storedAccessibilityVirtualChildrenProvider = newValue
            recordMutation(.accessibility)
        }
    }

    public func setAccessibilityAction(
        _ action: AccessibilityAction,
        handler:
            @escaping @MainActor (AccessibilityActionRequest) -> Bool
    ) {
        storedAccessibilityActions[action] = handler
        recordMutation(.accessibility)
    }

    public func clearAccessibilityAction(_ action: AccessibilityAction) {
        guard storedAccessibilityActions.removeValue(forKey: action) != nil
        else { return }
        recordMutation(.accessibility)
    }

    public func postAccessibilityAnnouncement(
        _ announcement: String,
        priority: AccessibilityLiveRegion = .polite
    ) {
        guard !announcement.isEmpty else { return }
        uiContext.postAccessibilityNotification(
            AccessibilityNotification(
                kind: priority == .assertive ? .announcement : .liveRegion,
                target: accessibilityID,
                announcement: announcement))
    }
}
