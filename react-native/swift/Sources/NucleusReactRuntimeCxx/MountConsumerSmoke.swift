import Dispatch
import NucleusReactFabricSmokeC
import NucleusUI
import Synchronization

private final class MountTestDrainScheduler: Sendable {
    private struct State: Sendable {
        var operations: [MountDrainOperation] = []
        var head = 0
    }

    private let state = Mutex(State())

    func schedule(_ operation: @escaping MountDrainOperation) {
        state.withLock {
            $0.operations.append(operation)
        }
    }

    var pendingCount: Int {
        state.withLock {
            $0.operations.count - $0.head
        }
    }

    @MainActor
    func runNext() -> Bool {
        let operation = state.withLock {
            state -> MountDrainOperation? in
            guard state.head < state.operations.count
            else { return nil }
            let operation = state.operations[state.head]
            state.head += 1
            if state.head == state.operations.count {
                state.operations.removeAll(keepingCapacity: true)
                state.head = 0
            }
            return operation
        }
        guard let operation else { return false }
        operation()
        return true
    }
}

@MainActor
private func mountTestContext(
    surfaceID: Int
) -> MountSurfaceContext {
    MountSurfaceContext(
        surfaceID: surfaceID,
        rootView: View(),
        registry: ViewComponentViewRegistry(),
        environment: ReactSurfaceEnvironment())
}

@c @implementation
public func nucleus_rn_mount_batching_smoke() -> Int32 {
    return MainActor.assumeIsolated { () -> Int32 in
        let uiContext = UIContext(services: .inMemory())
        return uiContext.construct {
        let scheduler = MountTestDrainScheduler()
        let consumer = MountConsumer(
            scheduleDrain: scheduler.schedule)
        var appliedOrder: [Int] = []
        let surfaceIDs = Array(100..<124)
        for surfaceID in surfaceIDs {
            let context = mountTestContext(
                surfaceID: surfaceID)
            context.onMaterialize = { _ in
                appliedOrder.append(surfaceID)
            }
            consumer.registerContext(context)
        }
        defer {
            for surfaceID in surfaceIDs {
                consumer.unregisterContext(surfaceID: surfaceID)
            }
        }
        appliedOrder.removeAll(keepingCapacity: true)

        DispatchQueue.concurrentPerform(
            iterations: surfaceIDs.count
        ) { index in
            consumer.didFinishTransaction(
                surfaceID: Int32(surfaceIDs[index]))
        }
        let acceptedOrder =
            consumer.queuedBatchSurfaceIDs()
        guard acceptedOrder.count == surfaceIDs.count
        else { return 1 }
        guard scheduler.pendingCount == 1
        else { return 2 }
        guard scheduler.runNext()
        else { return 3 }
        guard appliedOrder == acceptedOrder
        else { return 4 }
        var metrics = consumer.metricsSnapshot()
        guard
            metrics.completedBatchesQueued
                == UInt64(surfaceIDs.count),
            metrics.drainTasksScheduled == 1,
            metrics.batchesDrained
                == UInt64(surfaceIDs.count),
            metrics.lastBatchesDrainedPerTask
                == UInt64(surfaceIDs.count)
        else { return 5 }

        let finishingScheduler =
            MountTestDrainScheduler()
        let finishingConsumer = MountConsumer(
            scheduleDrain: finishingScheduler.schedule)
        let first = mountTestContext(surfaceID: 301)
        let second = mountTestContext(surfaceID: 302)
        finishingConsumer.registerContext(first)
        finishingConsumer.registerContext(second)
        defer {
            first.onMaterialize = nil
            second.onMaterialize = nil
            finishingConsumer.unregisterContext(surfaceID: 301)
            finishingConsumer.unregisterContext(surfaceID: 302)
        }
        var finishingOrder: [Int] = []
        var appendedDuringDrain = false
        first.onMaterialize = { _ in
            finishingOrder.append(301)
            guard !appendedDuringDrain else { return }
            appendedDuringDrain = true
            finishingConsumer.didFinishTransaction(
                surfaceID: 302)
        }
        second.onMaterialize = { _ in
            finishingOrder.append(302)
        }
        finishingConsumer.didFinishTransaction(
            surfaceID: 301)
        guard finishingScheduler.pendingCount == 1
        else { return 6 }
        guard finishingScheduler.runNext()
        else { return 7 }
        guard finishingOrder == [301, 302]
        else { return 8 }
        metrics = finishingConsumer.metricsSnapshot()
        guard
            metrics.drainTasksScheduled == 1,
            metrics.batchesDrained == 2,
            metrics.lastBatchesDrainedPerTask == 2,
            finishingScheduler.pendingCount == 0
        else { return 9 }
        return 0
        }
    }
}

@c @implementation
public func nucleus_rn_mount_lifecycle_smoke() -> Int32 {
    return MainActor.assumeIsolated { () -> Int32 in
        let uiContext = UIContext(services: .inMemory())
        return uiContext.construct {
        let scheduler = MountTestDrainScheduler()
        let consumer = MountConsumer(
            scheduleDrain: scheduler.schedule)
        let surfaceID = 401
        let original = mountTestContext(
            surfaceID: surfaceID)
        consumer.registerContext(original)
        consumer.enqueue(.create(
            surfaceID: surfaceID,
            tag: 410,
            componentName: "View",
            component: .view(
                MountViewSnapshot(
                    nativeID: "old",
                    frame: Rect(
                        x: 0, y: 0,
                        width: 10, height: 10)),
                backgroundColor: nil)))
        consumer.didFinishTransaction(
            surfaceID: Int32(surfaceID))
        consumer.unregisterContext(
            surfaceID: surfaceID)

        let replacement = mountTestContext(
            surfaceID: surfaceID)
        consumer.registerContext(replacement)
        guard scheduler.runNext()
        else { return 1 }
        guard
            replacement.registry.component(
                for: 410) == nil,
            consumer.metricsSnapshot()
                .staleBatchesRejected == 1
        else { return 2 }

        consumer.enqueue(.create(
            surfaceID: surfaceID,
            tag: 411,
            componentName: "View",
            component: .view(
                MountViewSnapshot(
                    nativeID: "new",
                    frame: Rect(
                        x: 1, y: 2,
                        width: 30, height: 40)),
                backgroundColor: nil)))
        consumer.didFinishTransaction(
            surfaceID: Int32(surfaceID))
        guard scheduler.runNext()
        else { return 3 }
        guard
            replacement.registry.component(
                for: 411)?.nativeID == "new"
        else { return 4 }

        consumer.unregisterContext(
            surfaceID: surfaceID)
        let baseline = consumer.bookkeepingCounts()
        guard baseline == MountBookkeepingCounts(
            queuedBatches: 0,
            generations: 0,
            retiredSurfaces: 0,
            inFlightSurfaces: 0)
        else { return 5 }

        consumer.enqueue(.delete(
            surfaceID: surfaceID,
            tag: 411))
        consumer.didFinishTransaction(
            surfaceID: Int32(surfaceID))
        guard
            scheduler.pendingCount == 0,
            consumer.bookkeepingCounts() == baseline
        else { return 6 }

        for cycle in 0..<64 {
            let id = 500 + cycle
            consumer.registerContext(
                mountTestContext(surfaceID: id))
            consumer.didFinishTransaction(
                surfaceID: Int32(id))
            guard scheduler.runNext()
            else { return 7 }
            consumer.unregisterContext(surfaceID: id)
        }
        guard consumer.bookkeepingCounts() == baseline
        else { return 8 }
        return 0
        }
    }
}

@MainActor
private func mountEventPayloadSmoke() -> Int32 {
        let scheduler = MountTestDrainScheduler()
        let consumer = MountConsumer(
            scheduleDrain: scheduler.schedule)
        let surfaceID = 601
        let context = mountTestContext(
            surfaceID: surfaceID)
        consumer.registerContext(context)

        let viewName = "View"
        let textName = "Paragraph"
        let imageName = "Image"
        let viewNativeID = "container"
        let textNativeID = "title"
        let imageNativeID = "hero"
        let text = "Nucleus"
        let imageSource = "file:///tmp/image.png"
        let textAttributes = TextAttributesSnapshot(
            fontFamily: "Inter",
            fontSize: 14,
            fontWeight: 500,
            fontSlant: 0,
            textColor: nil,
            lineHeight: 18,
            alignment: .leading,
            maximumNumberOfLines: 1,
            lineBreakMode: .clipping)

        consumer.enqueue(.create(
            surfaceID: surfaceID,
            tag: 610,
            componentName: viewName,
            component: .view(
                MountViewSnapshot(
                    nativeID: viewNativeID,
                    frame: Rect(
                        x: 0, y: 0,
                        width: 100, height: 80)),
                backgroundColor: MountEventColor(
                    red: 1, green: 0,
                    blue: 0, alpha: 1))))
        consumer.enqueue(.create(
            surfaceID: surfaceID,
            tag: 611,
            componentName: textName,
            component: .text(
                MountViewSnapshot(
                    nativeID: textNativeID,
                    frame: Rect(
                        x: 2, y: 3,
                        width: 40, height: 20)),
                text: text,
                attributes: textAttributes)))
        consumer.enqueue(.create(
            surfaceID: surfaceID,
            tag: 612,
            componentName: imageName,
            component: .image(
                MountViewSnapshot(
                    nativeID: imageNativeID,
                    frame: Rect(
                        x: 4, y: 5,
                        width: 24, height: 24)),
                source: imageSource)))
        consumer.enqueue(.insert(
            surfaceID: surfaceID,
            parentTag: surfaceID,
            childTag: 612,
            index: 0))
        consumer.enqueue(.insert(
            surfaceID: surfaceID,
            parentTag: surfaceID,
            childTag: 611,
            index: 0))
        consumer.didFinishTransaction(
            surfaceID: Int32(surfaceID))
        guard scheduler.runNext()
        else { return 1 }

        guard
            context.registry.component(
                for: 610) is ReactViewComponentView,
            context.registry.component(
                for: 611) is ReactParagraphComponentView,
            context.registry.component(
                for: 612) is ReactImageComponentView,
            (context.registry.component(for: 612)?.view as? ImageView)?
                .source == .resource("/tmp/image.png"),
            context.registry.component(
                for: 610)?.nativeID == viewNativeID,
            context.registry.component(
                for: 611)?.nativeID == textNativeID,
            context.registry.component(
                for: 612)?.nativeID == imageNativeID,
            context.rootView.subviews.count == 2,
            context.rootView.subviews[0]
                === context.registry.component(for: 611)?.view,
            context.rootView.subviews[1]
                === context.registry.component(for: 612)?.view
        else { return 2 }

        var metrics = consumer.metricsSnapshot()
        guard
            metrics.copiedComponentNameBytes
                == UInt64(
                    viewName.utf8.count
                    + textName.utf8.count
                    + imageName.utf8.count),
            metrics.copiedNativeIDBytes
                == UInt64(
                    viewNativeID.utf8.count
                    + textNativeID.utf8.count
                    + imageNativeID.utf8.count),
            metrics.copiedTextBytes
                == UInt64(text.utf8.count),
            metrics.copiedImageBytes
                == UInt64(imageSource.utf8.count)
        else { return 3 }

        let copyMetricsBeforeStructural = (
            metrics.copiedComponentNameBytes,
            metrics.copiedNativeIDBytes,
            metrics.copiedTextBytes,
            metrics.copiedImageBytes)
        consumer.enqueue(.remove(
            surfaceID: surfaceID,
            childTag: 611))
        consumer.enqueue(.delete(
            surfaceID: surfaceID,
            tag: 611))
        consumer.didFinishTransaction(
            surfaceID: Int32(surfaceID))
        guard scheduler.runNext()
        else { return 4 }
        metrics = consumer.metricsSnapshot()
        guard
            copyMetricsBeforeStructural.0
                == metrics.copiedComponentNameBytes,
            copyMetricsBeforeStructural.1
                == metrics.copiedNativeIDBytes,
            copyMetricsBeforeStructural.2
                == metrics.copiedTextBytes,
            copyMetricsBeforeStructural.3
                == metrics.copiedImageBytes,
            context.registry.component(for: 611) == nil
        else { return 5 }

        let updatedText = "Updated"
        let updatedNativeID = "container-2"
        consumer.enqueue(.update(
            surfaceID: surfaceID,
            tag: 610,
            component: .view(
                MountViewSnapshot(
                    nativeID: updatedNativeID,
                    frame: Rect(
                        x: 7, y: 8,
                        width: 90, height: 70)),
                backgroundColor: nil)))
        consumer.enqueue(.update(
            surfaceID: surfaceID,
            tag: 612,
            component: .image(
                MountViewSnapshot(
                    nativeID: imageNativeID,
                    frame: Rect(
                        x: 4, y: 5,
                        width: 32, height: 32)),
                source: updatedText)))
        consumer.didFinishTransaction(
            surfaceID: Int32(surfaceID))
        guard scheduler.runNext()
        else { return 6 }
        metrics = consumer.metricsSnapshot()
        guard
            context.registry.component(
                for: 610)?.nativeID == updatedNativeID,
            (context.registry.component(for: 612)?.view as? ImageView)?
                .source == nil,
            metrics.copiedComponentNameBytes
                == copyMetricsBeforeStructural.0,
            metrics.copiedNativeIDBytes
                == copyMetricsBeforeStructural.1
                    + UInt64(
                        updatedNativeID.utf8.count
                        + imageNativeID.utf8.count),
            metrics.copiedImageBytes
                == copyMetricsBeforeStructural.3
                    + UInt64(updatedText.utf8.count)
        else { return 7 }
        return 0
}

@c @implementation
public func nucleus_rn_mount_event_payload_smoke()
    -> Int32
{
    MainActor.assumeIsolated {
        let uiContext = UIContext(services: .inMemory())
        return uiContext.construct {
            mountEventPayloadSmoke()
        }
    }
}
