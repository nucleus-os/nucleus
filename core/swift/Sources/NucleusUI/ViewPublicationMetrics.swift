import Tracy

package struct ViewPublicationMetrics: Sendable, Equatable {
    package var nodesVisited: UInt64 = 0
    package var cleanSubtreesSkipped: UInt64 = 0
    package var snapshotsAuthored: UInt64 = 0
    package var dirtyStructure: UInt64 = 0
    package var dirtyGeometry: UInt64 = 0
    package var dirtyVisibility: UInt64 = 0
    package var dirtyStyle: UInt64 = 0
    package var dirtyContent: UInt64 = 0
    package var dirtyTransform: UInt64 = 0
    package var dirtyScrolling: UInt64 = 0
    package var dirtyAccessibility: UInt64 = 0
    package var dirtyAnimation: UInt64 = 0
    package var layersCreated: UInt64 = 0
    package var layersRetained: UInt64 = 0
    package var layersHidden: UInt64 = 0
    package var layersReparented: UInt64 = 0
    package var layersRemoved: UInt64 = 0
    package var propertyUpdates: UInt64 = 0
    package var contentRegistrations: UInt64 = 0
    package var contentCacheHits: UInt64 = 0
    package var paintBytes: UInt64 = 0
    package var cacheUpserts: UInt64 = 0
    package var cacheRemovals: UInt64 = 0
    package var recordingsHashed: UInt64 = 0
    package var paintPayloadBytesHashed: UInt64 = 0
    package var paintCacheKeysReconciled: UInt64 = 0
    package var registrationsCreated: UInt64 = 0
    package var localizedPaintUpdates: UInt64 = 0
    package var fullPaintUpdates: UInt64 = 0
    package var damageRegions: UInt64 = 0
    package var animationRequests: UInt64 = 0
    package var commits: UInt64 = 0

    package init() {}
}

extension ViewLayerPublisher {
    func publishMetrics(_ metrics: ViewPublicationMetrics) {
        Trace.plot(
            "swift.nucleus.view_layer.nodes_visited",
            metrics.nodesVisited)
        Trace.plot(
            "swift.nucleus.view_layer.clean_subtrees_skipped",
            metrics.cleanSubtreesSkipped)
        Trace.plot(
            "swift.nucleus.view_layer.snapshots_authored",
            metrics.snapshotsAuthored)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_structure",
            metrics.dirtyStructure)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_geometry",
            metrics.dirtyGeometry)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_visibility",
            metrics.dirtyVisibility)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_style",
            metrics.dirtyStyle)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_content",
            metrics.dirtyContent)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_transform",
            metrics.dirtyTransform)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_scrolling",
            metrics.dirtyScrolling)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_accessibility",
            metrics.dirtyAccessibility)
        Trace.plot(
            "swift.nucleus.view_layer.dirty_animation",
            metrics.dirtyAnimation)
        Trace.plot(
            "swift.nucleus.view_layer.layers_created",
            metrics.layersCreated)
        Trace.plot(
            "swift.nucleus.view_layer.layers_retained",
            metrics.layersRetained)
        Trace.plot(
            "swift.nucleus.view_layer.layers_hidden",
            metrics.layersHidden)
        Trace.plot(
            "swift.nucleus.view_layer.layers_reparented",
            metrics.layersReparented)
        Trace.plot(
            "swift.nucleus.view_layer.layers_removed",
            metrics.layersRemoved)
        Trace.plot(
            "swift.nucleus.view_layer.property_updates",
            metrics.propertyUpdates)
        Trace.plot(
            "swift.nucleus.view_layer.content_registrations",
            metrics.contentRegistrations)
        Trace.plot(
            "swift.nucleus.view_layer.content_cache_hits",
            metrics.contentCacheHits)
        Trace.plot(
            "swift.nucleus.view_layer.paint_bytes",
            metrics.paintBytes)
        Trace.plot(
            "swift.nucleus.view_layer.cache_upserts",
            metrics.cacheUpserts)
        Trace.plot(
            "swift.nucleus.view_layer.cache_removals",
            metrics.cacheRemovals)
        Trace.plot(
            "swift.nucleus.view_layer.recordings_hashed",
            metrics.recordingsHashed)
        Trace.plot(
            "swift.nucleus.view_layer.paint_payload_bytes_hashed",
            metrics.paintPayloadBytesHashed)
        Trace.plot(
            "swift.nucleus.view_layer.paint_cache_keys_reconciled",
            metrics.paintCacheKeysReconciled)
        Trace.plot(
            "swift.nucleus.view_layer.registrations_created",
            metrics.registrationsCreated)
        Trace.plot(
            "swift.nucleus.view_layer.localized_paint_updates",
            metrics.localizedPaintUpdates)
        Trace.plot(
            "swift.nucleus.view_layer.full_paint_updates",
            metrics.fullPaintUpdates)
        Trace.plot(
            "swift.nucleus.view_layer.damage_regions",
            metrics.damageRegions)
        Trace.plot(
            "swift.nucleus.view_layer.animation_requests",
            metrics.animationRequests)
        Trace.plot(
            "swift.nucleus.view_layer.retained_paint_registrations",
            UInt64(retainedPaintRegistrationCount))
        Trace.plot(
            "swift.nucleus.view_layer.commits",
            metrics.commits)
    }
}
