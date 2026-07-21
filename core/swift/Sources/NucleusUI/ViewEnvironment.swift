extension View {
    /// Per-view appearance override. `nil` inherits from the nearest ancestor,
    /// then from the owning `UIContext`.
    public var effectiveAppearance: Appearance {
        var current: View? = self
        while let view = current {
            if let appearance = view.appearance {
                return appearance
            }
            current = view.parentView
        }
        return uiContext.environment.appearance
    }

    /// The palette this view paints under.
    public var effectivePalette: Palette {
        var current: View? = self
        while let view = current {
            if let palette = view.palette { return palette }
            current = view.parentView
        }
        let base = parentWindow?.windowScene?.palette
            ?? Palette.standard(for: effectiveAppearance)
        return uiContext.environment.increasesContrast
            ? base.increasedContrast()
            : base
    }

    /// Resolve a semantic color against this view's effective palette.
    public func resolve(_ spec: ColorSpec) -> Color {
        spec.resolve(in: effectivePalette)
    }

    package func notifyBackingScaleFactorDidChange() {
        viewDidChangeBackingScaleFactor()
        for child in subviews {
            child.notifyBackingScaleFactorDidChange()
        }
    }

    /// Notify descendants until an explicit appearance or palette boundary.
    func notifyEffectiveAppearanceChanged() {
        viewDidChangeEffectiveAppearance()
        for child in childViews
        where child.palette == nil && child.appearance == nil {
            child.notifyEffectiveAppearanceChanged()
        }
    }
}
