/// A named icon catalog: glyph names mapped onto codepoints in an icon font.
///
/// Icons are font glyphs rather than bitmaps, which is the reference's approach
/// and the right one for a shell — a glyph recolours and rescales for free,
/// needs no texture, and costs one codepoint rather than a decode.
///
/// The font itself is **injected, not bundled.** Which icon font a shell ships
/// is a licensing and asset-size decision that belongs to the shell, not to a
/// widget kit, and a kit that hardcoded one would force it on every consumer.
@MainActor
public final class GlyphCatalog {
    /// The font family the codepoints belong to. Nothing validates that the
    /// family is installed — a missing icon font renders as missing glyphs,
    /// which is a deployment problem and looks like one.
    public let fontFamily: String

    private var codepoints: [String: Character] = [:]
    private var aliases: [String: String] = [:]
    private var consumers: [ViewID: WeakGlyphConsumer] = [:]
    public private(set) var generation: UInt64 = 1

    public init(fontFamily: String) {
        self.fontFamily = fontFamily
    }

    public func register(_ name: String, _ codepoint: Character) {
        guard codepoints[name] != codepoint else { return }
        codepoints[name] = codepoint
        changed()
    }

    /// Register a whole catalog, as loaded from the font's companion metadata.
    public func register(_ entries: [String: Character]) {
        var didChange = false
        for (name, codepoint) in entries where codepoints[name] != codepoint {
            codepoints[name] = codepoint
            didChange = true
        }
        if didChange { changed() }
    }

    /// An alternative name for an existing glyph. Icon sets rename things
    /// between releases, and a widget naming a retired icon should keep working
    /// rather than silently render nothing.
    public func alias(_ alias: String, to name: String) {
        guard aliases[alias] != name else { return }
        aliases[alias] = name
        changed()
    }

    public func contains(_ name: String) -> Bool {
        lookup(name) != nil
    }

    public func lookup(_ name: String) -> Character? {
        if let direct = codepoints[name] { return direct }
        if let target = aliases[name] { return codepoints[target] }
        return nil
    }

    public var names: [String] { Array(codepoints.keys).sorted() }
    public var count: Int { codepoints.count }

    fileprivate func addConsumer(_ view: GlyphView) {
        consumers[view.id] = WeakGlyphConsumer(view)
    }

    fileprivate func removeConsumer(_ id: ViewID) {
        consumers[id] = nil
    }

    private func changed() {
        generation &+= 1
        precondition(generation != 0, "glyph catalog generation exhausted")
        for consumer in consumers.values {
            consumer.value?.glyphCatalogDidChange()
        }
    }
}

@MainActor
package final class WeakGlyphConsumer {
    package weak var value: GlyphView?
    package init(_ value: GlyphView) { self.value = value }
}

/// A single icon, drawn as a glyph from an icon font.
///
/// Sized by *font size* rather than by frame, like the text it is: an icon
/// beside a label should share its optical size, which a pixel frame cannot
/// express.
@MainActor
public final class GlyphView: View {
    /// The explicit per-view catalog. `nil` uses the owning UI context's catalog.
    public var catalog: GlyphCatalog? {
        didSet {
            guard catalog !== oldValue else { return }
            oldValue?.removeConsumer(id)
            resolvedCatalog?.addConsumer(self)
            refresh()
        }
    }

    /// The icon's name. Resolving to nothing renders nothing rather than
    /// substituting a placeholder — a shell showing a wrong icon is worse than
    /// one showing a gap, because the gap is visibly a bug.
    public var name: String? {
        didSet { if name != oldValue { refresh() } }
    }

    /// A codepoint set directly, bypassing the catalog. For glyphs a widget
    /// computes rather than names.
    public var character: Character? {
        didSet { if character != oldValue { refresh() } }
    }

    public var pointSize: Float = 16 {
        didSet { if pointSize != oldValue { refresh() } }
    }

    public var tint: ColorSpec = .role(.onSurface) {
        didSet { if tint != oldValue { setNeedsDisplay() } }
    }

    public init(name: String? = nil, pointSize: Float = 16) {
        self.name = name
        self.pointSize = pointSize
        super.init()
        accessibilityRole = .image
        uiContext.registerGlyphConsumer(self)
        resolvedCatalog?.addConsumer(self)
        refresh()
    }

    isolated deinit {
        resolvedCatalog?.removeConsumer(id)
        uiContext.unregisterGlyphConsumer(id)
    }

    private var resolvedCatalog: GlyphCatalog? {
        catalog ?? uiContext.glyphCatalog
    }

    package func contextGlyphCatalogDidChange(
        from previous: GlyphCatalog?
    ) {
        guard catalog == nil else { return }
        previous?.removeConsumer(id)
        resolvedCatalog?.addConsumer(self)
        refresh()
    }

    fileprivate func glyphCatalogDidChange() {
        refresh()
    }

    /// The character actually drawn: an explicit one wins, then the catalog.
    var resolvedCharacter: Character? {
        if let character { return character }
        guard let name, let catalog = resolvedCatalog else { return nil }
        return catalog.lookup(name)
    }

    private var layoutCache: TextLayout?

    public override var environmentDependencies: UIEnvironmentChanges {
        super.environmentDependencies.union(.textScale)
    }

    public override func environmentDidChange(
        _ changes: UIEnvironmentChanges
    ) {
        if changes.contains(.textScale) {
            refresh()
        }
        super.environmentDidChange(changes)
    }

    private func refresh() {
        layoutCache = nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func glyphLayout() -> TextLayout? {
        if let layoutCache { return layoutCache }
        guard let character = resolvedCharacter,
              let family = resolvedCatalog?.fontFamily
        else { return nil }

        let font = Font(descriptor: FontDescriptor(
            familyName: family, pointSize: pointSize))
            .scaled(by: uiContext.environment.textScale)
        let layout = TextLayout(
            runs: [TextRun(text: String(character), font: font, color: nil)],
            containerWidth: nil,
            alignment: .leading,
            lineBreakMode: .byClipping,
            numberOfLines: 1,
            textSystem: uiContext.services.textSystem)
        layoutCache = layout
        return layout
    }

    public override var intrinsicContentSize: Size {
        guard let layout = glyphLayout() else { return .zero }
        return layout.intrinsicSize
    }

    public override func draw(in context: GraphicsContext) {
        guard let layout = glyphLayout() else { return }
        let size = layout.intrinsicSize
        // Centred in the frame: a glyph's advance rarely equals the box a
        // layout gives it, and an icon that sits off-centre beside a label is
        // immediately visible.
        let origin = Point(
            x: (bounds.size.width - size.width) / 2,
            y: (bounds.size.height - size.height) / 2)
        context.fillColor = resolve(tint)
        context.draw(layout, in: Rect(origin: origin, size: size))
    }

    public override func viewDidChangeEffectiveAppearance() {
        setNeedsDisplay()
        super.viewDidChangeEffectiveAppearance()
    }
}
