/// Chainable configuration for builder expressions.
///
/// Every modifier here sets the same stored property a caller could set
/// directly, returns `self`, and does nothing else. They exist so a body reads
/// as one expression instead of a preamble of assignments — not as a second API
/// surface. If a modifier is ever the *only* way to reach a behaviour, the
/// property it wraps is missing.
///
/// `@discardableResult` throughout, because the mutation is the point; chaining
/// is a convenience.
extension View {
    // MARK: - Geometry

    @discardableResult
    public func frame(_ rect: Rect) -> Self {
        frame = rect
        return self
    }

    @discardableResult
    public func size(width: Double, height: Double) -> Self {
        frame = Rect(origin: frame.origin, size: Size(width: width, height: height))
        return self
    }

    @discardableResult
    public func width(_ value: Double) -> Self {
        frame = Rect(origin: frame.origin, size: Size(width: value, height: frame.size.height))
        return self
    }

    @discardableResult
    public func height(_ value: Double) -> Self {
        frame = Rect(origin: frame.origin, size: Size(width: frame.size.width, height: value))
        return self
    }

    // MARK: - Flexible sizing

    /// Share of a container's surplus main-axis space this view absorbs.
    @discardableResult
    public func grow(_ factor: Double) -> Self {
        growFactor = factor
        return self
    }

    /// Share of a container's main-axis overflow this view gives back.
    @discardableResult
    public func shrink(_ factor: Double) -> Self {
        shrinkFactor = factor
        return self
    }

    /// Main-axis starting size, overriding the measured one.
    @discardableResult
    public func basis(_ value: Double?) -> Self {
        layoutBasis = value
        return self
    }

    // MARK: - Appearance

    @discardableResult
    public func background(_ color: Color?) -> Self {
        backgroundColor = color
        return self
    }

    @discardableResult
    public func cornerRadius(_ radius: Double) -> Self {
        cornerRadius = radius
        return self
    }

    @discardableResult
    public func border(_ border: Border) -> Self {
        self.border = border
        return self
    }

    @discardableResult
    public func opacity(_ value: Double) -> Self {
        alphaValue = value
        return self
    }

    @discardableResult
    public func hidden(_ isHidden: Bool = true) -> Self {
        self.isHidden = isHidden
        return self
    }

    @discardableResult
    public func style(_ style: ViewStyle) -> Self {
        self.style = style
        return self
    }

    @discardableResult
    public func transform(_ transform: Transform) -> Self {
        self.transform = transform
        return self
    }

    @discardableResult
    public func appearance(_ appearance: Appearance?) -> Self {
        self.appearance = appearance
        return self
    }

    // MARK: - Accessibility

    @discardableResult
    public func accessibilityLabel(_ label: String?) -> Self {
        accessibilityLabel = label
        return self
    }

    @discardableResult
    public func accessibilityRole(_ role: AccessibilityRole?) -> Self {
        accessibilityRole = role
        return self
    }

    // MARK: - Escape hatch

    /// Reach any property the modifiers do not cover, without leaving the
    /// expression. Deliberately present so the modifier list never has to grow
    /// to cover a one-off — a rarely-set property is not evidence that a
    /// modifier is missing.
    @discardableResult
    public func configure(_ body: (Self) -> Void) -> Self {
        body(self)
        return self
    }
}

extension Label {
    @discardableResult
    public func text(_ text: String) -> Self {
        self.text = text
        return self
    }

    @discardableResult
    public func font(_ font: Font) -> Self {
        self.font = font
        return self
    }

    @discardableResult
    public func textColor(_ color: Color) -> Self {
        textColor = color
        return self
    }

    @discardableResult
    public func alignment(_ alignment: Label.Alignment) -> Self {
        self.alignment = alignment
        return self
    }

    @discardableResult
    public func lineBreakMode(_ mode: LineBreakMode) -> Self {
        lineBreakMode = mode
        return self
    }

    @discardableResult
    public func numberOfLines(_ count: Int) -> Self {
        numberOfLines = count
        return self
    }
}

extension Button {
    @discardableResult
    public func title(_ title: String) -> Self {
        self.title = title
        return self
    }

    @discardableResult
    public func enabled(_ isEnabled: Bool) -> Self {
        self.isEnabled = isEnabled
        return self
    }
}

extension StackView {
    @discardableResult
    public func axis(_ axis: StackView.Axis) -> Self {
        self.axis = axis
        return self
    }

    @discardableResult
    public func spacing(_ spacing: Double) -> Self {
        self.spacing = spacing
        return self
    }

    @discardableResult
    public func alignment(_ alignment: StackView.Alignment) -> Self {
        self.alignment = alignment
        return self
    }

    @discardableResult
    public func distribution(_ distribution: StackView.Distribution) -> Self {
        self.distribution = distribution
        return self
    }

    @discardableResult
    public func layoutMargins(_ insets: EdgeInsets) -> Self {
        layoutMargins = insets
        return self
    }

    /// Uniform margins, the common case.
    @discardableResult
    public func padding(_ amount: Double) -> Self {
        layoutMargins = EdgeInsets(
            top: amount, left: amount, bottom: amount, right: amount)
        return self
    }
}

extension TextField {
    @discardableResult
    public func placeholder(_ text: String) -> Self {
        placeholderString = text
        return self
    }

    @discardableResult
    public func secure(_ isSecure: Bool = true) -> Self {
        self.isSecure = isSecure
        return self
    }

    @discardableResult
    public func contentType(_ type: TextInputContentType) -> Self {
        contentType = type
        return self
    }

    @discardableResult
    public func maximumLength(_ length: Int?) -> Self {
        maximumLength = length
        return self
    }

    @discardableResult
    public func onSubmit(_ handler: @escaping (TextField) -> Void) -> Self {
        onSubmit = handler
        return self
    }

    @discardableResult
    public func onChange(_ handler: @escaping (TextField) -> Void) -> Self {
        onChange = handler
        return self
    }
}

extension ImageView {
    @discardableResult
    public func image(_ image: ImageHandle?) -> Self {
        self.image = image
        return self
    }

    @discardableResult
    public func imageSize(_ size: Size) -> Self {
        imageSize = size
        return self
    }

    /// Show an image file, decoded to fit this view once it has a size.
    @discardableResult
    public func source(_ path: String?) -> Self {
        sourcePath = path
        return self
    }

    @discardableResult
    public func contentMode(_ mode: ImageContentMode) -> Self {
        contentMode = mode
        return self
    }
}

extension Separator {
    @discardableResult
    public func orientation(_ orientation: Separator.Orientation) -> Self {
        self.orientation = orientation
        return self
    }

    @discardableResult
    public func thickness(_ thickness: Double) -> Self {
        self.thickness = thickness
        return self
    }

    @discardableResult
    public func spacing(_ spacing: Double) -> Self {
        self.spacing = spacing
        return self
    }

    @discardableResult
    public func color(_ color: ColorSpec) -> Self {
        self.color = color
        return self
    }
}

extension ProgressIndicator {
    @discardableResult
    public func progress(_ progress: Double) -> Self {
        self.progress = progress
        return self
    }

    @discardableResult
    public func orientation(_ orientation: ProgressIndicator.Orientation) -> Self {
        self.orientation = orientation
        return self
    }

    @discardableResult
    public func fillColor(_ color: ColorSpec) -> Self {
        self.fillColor = color
        return self
    }

    @discardableResult
    public func trackColor(_ color: ColorSpec) -> Self {
        self.trackColor = color
        return self
    }
}
