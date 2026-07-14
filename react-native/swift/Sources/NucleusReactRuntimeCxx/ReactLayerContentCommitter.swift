@_spi(NucleusCompositor) import NucleusUI
@_spi(NucleusCompositor) import NucleusLayers

enum ReactLayerContentCommitter {
    @MainActor
    static func commitDisplayContentIfNeeded(for view: View) throws {
        try view.displayIfNeeded()
        try commit(commands: view.layerContent.commands, for: view)
    }

    @MainActor
    static func commit(commands viewCommands: [ViewLayerContentCommand], for view: View) throws {
        let commands = viewCommands
            .filter { $0.kind != .backdrop }
            .map { paintCommand($0) }
        defer {
            releaseTransientTextLayoutHandles(commands)
        }

        let update: LayerPropertyUpdate
        let paintContent: PaintContent?
        if commands.isEmpty {
            update = LayerPropertyUpdate(content: LayerContent.none)
            paintContent = nil
        } else {
            let paint = try PaintContent.register(
                commands,
                width: Float(view.bounds.size.width),
                height: Float(view.bounds.size.height),
                in: view.backingLayer.context)
            update = LayerPropertyUpdate(content: LayerContent(paint))
            paintContent = paint
        }
        view.backingLayer.apply(update)
        LayerTransaction.appendAmbient(
            .properties(layer: view.backingLayer.id, update),
            in: view.backingLayer.context
        )
        withExtendedLifetime(paintContent) {}
    }

    private static func paintCommand(_ command: ViewLayerContentCommand) -> PaintCommand {
        let layoutHandle = command.kind == .textLayout ? makeTextLayoutHandle(command) : 0
        return PaintCommand(
            kind: paintKind(command.kind),
            x: command.x,
            y: command.y,
            w: command.w,
            h: command.h,
            radius: command.radius,
            strokeWidth: command.strokeWidth,
            color: command.color.layersColor,
            imageHandle: command.imageHandle,
            textLayoutHandle: layoutHandle
        )
    }

    private static func paintKind(_ kind: LayerContentCommandKind) -> PaintCommandKind {
        switch kind {
        case .rect:
            .rect
        case .roundedRect:
            .roundedRect
        case .image:
            .image
        case .line:
            .line
        case .textLayout:
            .textLayout
        case .backdrop:
            .rect
        }
    }

    private static func releaseTransientTextLayoutHandles(_ commands: [PaintCommand]) {
        for command in commands where command.kind == .textLayout && command.textLayoutHandle != 0 {
            TextSystem.shared.releaseLayoutHandle(command.textLayoutHandle)
        }
    }

    private static func makeTextLayoutHandle(_ command: ViewLayerContentCommand) -> UInt64 {
        guard let layout = command.textLayout else {
            return 0
        }
        if let storageHandle = layout.storage?.retainedHandle(), storageHandle != 0 {
            return storageHandle
        }
        return TextSystem.shared.makeLayoutHandle(for: layout)
    }

}
