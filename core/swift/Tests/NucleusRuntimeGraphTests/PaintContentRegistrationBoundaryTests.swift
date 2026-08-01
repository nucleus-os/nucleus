import NucleusAppHostProtocols
import NucleusLayers
import NucleusRenderHost
import NucleusRenderModel
import NucleusTypes
import Testing

@testable import NucleusAppHostBundle

@MainActor
@Suite struct PaintContentRegistrationBoundaryTests {
    private func makeBoundary() -> (
        host: SwiftResourceHost,
        registrar: any PaintContentRegistrar
    ) {
        let host = SwiftResourceHost()
        let bundle = NucleusAppHostBundle(resourceHost: host)
        return (host, bundle.paintContentRegistrar)
    }

    private func register(
        _ commands: [PaintCommand],
        payload: [UInt8],
        at boundary: (
            host: SwiftResourceHost,
            registrar: any PaintContentRegistrar
        )
    ) throws -> UInt64 {
        try boundary.registrar.register(
            resourceHostHandle: boundary.host.identity.rawValue,
            width: 64,
            height: 32,
            commands: commands.span,
            payload: payload.span)
    }

    @Test func emptyAndPopulatedPayloadsRoundTripExactly() throws {
        let boundary = makeBoundary()
        let emptyCommand = PaintCommand(kind: .rect)
        let emptyHandle = try register(
            [emptyCommand], payload: [], at: boundary)
        let empty = boundary.host.paintContents.content(
            PaintContentHandle(raw: emptyHandle))
        #expect(empty?.commands == [emptyCommand])
        #expect(empty?.payload == [])

        let payload = Array(UInt8.min...UInt8.max)
        let populatedCommand = PaintCommand(
            kind: .path, payloadOffset: 0,
            payloadLength: UInt32(payload.count))
        let populatedHandle = try register(
            [populatedCommand], payload: payload, at: boundary)
        let populated = boundary.host.paintContents.content(
            PaintContentHandle(raw: populatedHandle))
        #expect(populated?.commands == [populatedCommand])
        #expect(populated?.payload == payload)
    }

    @Test func layerContentOwnsItsRegisteredResourceThroughCommitAndTeardown() throws {
        let host = SwiftResourceHost()
        do {
            let bundle = NucleusAppHostBundle(resourceHost: host)
            let sink = RenderCommitSink(
                store: RetainedTreeStore(resourceHost: host),
                resourceHost: host,
                runtimeHost: bundle.layersHost)
            let context = try NucleusLayers.Context(
                id: NucleusLayers.ContextID(rawValue: 812),
                commitSink: sink)

            var creation = NucleusLayers.LayerTransaction(context: context)
            let layer = creation.createLayer()
            try creation.setPaintCommands(
                [PaintCommand(kind: .rect)],
                width: 16,
                height: 16,
                for: layer)
            try creation.insert(layer)
            try creation.commit()
            #expect(host.paintContents.count == 1)

            var removal = NucleusLayers.LayerTransaction(context: context)
            try removal.remove(layer)
            try removal.commit()
        }
        #expect(host.paintContents.count == 0)
    }

    @Test func bulkCopyInitializesAContiguousSpanOnce() {
        let maximumFixture = Array(repeating: UInt8(0xa5), count: 1 << 20)
        var operations: [Int] = []
        let copied = copyContiguousSpan(maximumFixture.span) {
            operations.append($0)
        }
        #expect(copied == maximumFixture)
        #expect(operations == [maximumFixture.count])

        operations.removeAll()
        let empty: [UInt8] = []
        #expect(
            copyContiguousSpan(empty.span) {
                operations.append($0)
            }.isEmpty)
        #expect(operations.isEmpty, "an empty span forms no source pointer")
    }

    @Test func malformedCommandsRejectWithoutRegisteringContent() {
        let invalidCommands = [
            PaintCommand(
                kind: .rect,
                flags: PaintCommandFlags(rawValue: 1 << 31)),
            PaintCommand(
                kind: .rect,
                flags: [.capRound, .capSquare]),
            PaintCommand(
                kind: .rect,
                flags: [.joinRound, .joinBevel]),
            PaintCommand(
                kind: .path,
                payloadOffset: 2,
                payloadLength: UInt32.max),
        ]

        for command in invalidCommands {
            let boundary = makeBoundary()
            #expect(
                throws: PaintContentRegistrationError.invalidArgument
            ) {
                try register([command], payload: [1, 2, 3], at: boundary)
            }
            #expect(boundary.host.paintContents.count == 0)
        }
    }

    @Test func everyPaintEnumAndFlagAccessorSurvivesRegistration() throws {
        let blends: [PaintBlendMode] = [
            .srcOver, .src, .multiply, .screen,
            .plus, .overlay, .dstIn, .dstOut,
        ]
        let caps: [PaintStrokeCap] = [.butt, .round, .square]
        let joins: [PaintStrokeJoin] = [.miter, .round, .bevel]
        let shadings: [PaintShading] = [
            .color, .linearGradient, .radialGradient,
            .sweepGradient, .effect,
        ]
        var commands: [PaintCommand] = []
        for blend in blends {
            for cap in caps {
                for join in joins {
                    for shading in shadings {
                        commands.append(
                            PaintCommand(
                                kind: .rect,
                                shading: shading,
                                blend: blend,
                                stroke: true,
                                antialias: false,
                                evenOddFill: true,
                                tintsImage: true,
                                strokeCap: cap,
                                strokeJoin: join,
                                transform: PaintTransform(
                                    a: 1, b: 2, c: 3,
                                    d: 4, tx: 5, ty: 6)))
                    }
                }
            }
        }

        let boundary = makeBoundary()
        let handle = try register(commands, payload: [], at: boundary)
        let stored = boundary.host.paintContents.commands(
            PaintContentHandle(raw: handle))
        #expect(stored == commands)
    }
}
