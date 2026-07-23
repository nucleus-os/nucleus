public import NucleusUI

public enum BaselineSemanticID: String, CaseIterable, Sendable {
    case primaryWindow
    case auxiliaryWindow
    case root
    case title
    case paintedContent
    case image
    case material
    case stack
    case flex
    case grid
    case scroll
    case button
    case toggle
    case slider
    case segments
    case select
    case textField
    case secureField
}

@MainActor
public final class BaselinePaintView: View {
    public override func draw(in context: GraphicsContext) {
        var path = Path()
        path.addRoundedRect(bounds, radius: 8)
        context.fill(
            path,
            with: .linearGradient(
                from: Point(x: 0, y: 0),
                to: Point(x: bounds.size.width, y: bounds.size.height),
                stops: [
                    GradientStop(
                        location: 0,
                        color: Color(0.14, 0.34, 0.92, 1)),
                    GradientStop(
                        location: 1,
                        color: Color(0.58, 0.18, 0.78, 1)),
                ]))
    }
}

@MainActor
public struct BaselineRetainedScene {
    public let windows: [Window]
    public let views: [BaselineSemanticID: View]
    public let textField: TextField
    public let secureField: TextField

    public subscript(_ id: BaselineSemanticID) -> View {
        guard let view = views[id] else {
            preconditionFailure("missing baseline semantic target \(id.rawValue)")
        }
        return view
    }
}

@MainActor
public enum BaselineRetainedSceneFactory {
    public static func make(
        in uiContext: UIContext
    ) -> BaselineRetainedScene {
        uiContext.construct {
            let root = View()
            root.frame = Rect(x: 0, y: 0, width: 720, height: 520)
            root.backgroundColor = Color(0.06, 0.07, 0.10, 1)

            let title = Label("Nucleus foundation")
            title.frame = Rect(x: 20, y: 16, width: 260, height: 28)
            root.addSubview(title)

            let painted = BaselinePaintView()
            painted.frame = Rect(x: 20, y: 56, width: 180, height: 76)
            painted.shadow = Shadow(
                offsetX: 0,
                offsetY: 4,
                blurRadius: 10,
                opacity: 0.5,
                color: Color(0, 0, 0, 0.5),
            )
            root.addSubview(painted)

            let image = ImageView(
                image: ImageHandle(id: 7),
                imageSize: Size(width: 56, height: 56))
            image.frame = Rect(x: 212, y: 66, width: 56, height: 56)
            root.addSubview(image)

            let material = VisualEffectView(
                material: .sidebar,
                state: .active,
                cornerRadius: 10)
            material.frame = Rect(x: 280, y: 56, width: 180, height: 76)
            root.addSubview(material)

            let stack = StackView(
                axis: .horizontal,
                spacing: 10,
                alignment: .center)
            stack.frame = Rect(x: 20, y: 148, width: 440, height: 32)
            let button = Button(title: "Apply")
            button.addTrackingArea(TrackingArea(
                cursor: .pointingHand,
                toolTip: "Apply changes"))
            let toggle = Toggle(isOn: true)
            let slider = Slider()
            slider.value = 0.4
            stack.addArrangedSubview(button)
            stack.addArrangedSubview(toggle)
            stack.addArrangedSubview(slider)
            root.addSubview(stack)

            let flex = FlexView()
            flex.frame = Rect(x: 20, y: 194, width: 440, height: 42)
            flex.columnGap = 8
            let segments = SegmentedControl(segments: [
                SegmentOption(id: "one", title: "One"),
                SegmentOption(id: "two", title: "Two"),
            ])
            let select = SelectControl(options: [
                SelectOption(id: "alpha", title: "Alpha"),
                SelectOption(id: "beta", title: "Beta"),
            ])
            flex.addArrangedSubview(segments)
            flex.addArrangedSubview(select)
            root.addSubview(flex)

            let grid = GridView(columns: [
                .fixed(150),
                .flexible(minimum: 120),
            ])
            grid.frame = Rect(x: 20, y: 250, width: 440, height: 74)
            grid.rowGap = 6
            grid.columnGap = 8
            let textField = TextField(string: "editable")
            let secureField = TextField(
                string: "secret",
                isSecure: true)
            grid.addArrangedSubview(Label("Account"))
            grid.addArrangedSubview(textField)
            grid.addArrangedSubview(Label("Password"))
            grid.addArrangedSubview(secureField)
            root.addSubview(grid)

            let scroll = ScrollView()
            scroll.frame = Rect(x: 480, y: 56, width: 220, height: 268)
            scroll.indicators = .both
            let document = BaselinePaintView()
            document.frame = Rect(x: 0, y: 0, width: 420, height: 520)
            document.transform = Transform.rotation(radians: 0.02)
            scroll.documentView = document
            root.addSubview(scroll)

            let primaryWindow = Window(
                title: "Foundation",
                role: .application,
                level: .normal)
            primaryWindow.setFrame(
                Rect(x: 40, y: 40, width: 720, height: 520),
                display: false)
            primaryWindow.setContentView(root)
            primaryWindow.orderFront()

            let auxiliaryRoot = View()
            auxiliaryRoot.frame = Rect(x: 0, y: 0, width: 220, height: 100)
            auxiliaryRoot.backgroundColor = Color(0.12, 0.14, 0.18, 1)
            let auxiliaryWindow = Window(
                title: "Inspector",
                role: .overlay,
                level: .overlay)
            auxiliaryWindow.setFrame(
                Rect(x: 780, y: 80, width: 220, height: 100),
                display: false)
            auxiliaryWindow.setContentView(auxiliaryRoot)
            auxiliaryWindow.orderFront()

            return BaselineRetainedScene(
                windows: [primaryWindow, auxiliaryWindow],
                views: [
                    .primaryWindow: root,
                    .auxiliaryWindow: auxiliaryRoot,
                    .root: root,
                    .title: title,
                    .paintedContent: painted,
                    .image: image,
                    .material: material,
                    .stack: stack,
                    .flex: flex,
                    .grid: grid,
                    .scroll: scroll,
                    .button: button,
                    .toggle: toggle,
                    .slider: slider,
                    .segments: segments,
                    .select: select,
                    .textField: textField,
                    .secureField: secureField,
                ],
                textField: textField,
                secureField: secureField)
        }
    }
}
