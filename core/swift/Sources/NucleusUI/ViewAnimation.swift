@_spi(NucleusCompositor) import NucleusLayers
import Tracy

/// A view property the compositor can interpolate without invoking main-actor
/// setters on every frame.
public enum AnimatableProperty: Sendable, Equatable {
    case opacity
    case cornerRadius
    case positionX
    case positionY
    case boundsWidth
    case boundsHeight
    case scrollOffsetX
    case scrollOffsetY

    package var keyPath: AnimationKeyPath {
        switch self {
        case .opacity: .opacity
        case .cornerRadius: .cornerRadius
        case .positionX: .positionX
        case .positionY: .positionY
        case .boundsWidth: .boundsW
        case .boundsHeight: .boundsH
        case .scrollOffsetX: .scrollOffsetX
        case .scrollOffsetY: .scrollOffsetY
        }
    }
}

package enum ViewAnimationOperation: Sendable, Equatable {
    case add(Animation)
    case remove(AnimationKeyPath)
}

package struct ViewAnimationRequest: Sendable, Equatable {
    package var generation: UInt64
    package var operation: ViewAnimationOperation
}

/// How an animation moves between its endpoints.
public struct AnimationTiming: Sendable, Equatable {
    public var duration: Double
    public var curve: AnimationCurve

    public init(duration: Double, curve: AnimationCurve = .bezier(.default)) {
        precondition(
            duration.isFinite && duration >= 0,
            "animation duration must be finite and nonnegative"
        )
        self.duration = duration
        self.curve = curve
    }

    public static let fast = AnimationTiming(duration: 0.10)
    public static let standard = AnimationTiming(duration: 0.20)
    public static let slow = AnimationTiming(duration: 0.40)

    public static func spring(
        duration: Double = 0.4,
        _ curve: SpringCurve = .snappy
    ) -> AnimationTiming {
        AnimationTiming(duration: duration, curve: .spring(curve))
    }
}

/// Exactly one terminal result for an accepted or skipped animation request.
public enum AnimationOutcome: Sendable, Equatable {
    case completed
    case cancelled
    case superseded
    case skippedReducedMotion
    case failed
}

/// Main-actor animation ownership token.
///
/// The handle stays pending until the renderer acknowledges a frame containing
/// the animation's terminal state. Calling `cancel()` authors a removal request;
/// it does not invent a producer-side deadline.
@MainActor
public final class AnimationHandle: ~Sendable {
    public let id: UInt64
    public private(set) var outcome: AnimationOutcome?
    public var isFinished: Bool { outcome != nil }

    package private(set) var isPublished = false
    package private(set) var presentationToken: PresentationCompletionToken?
    private let startedAt = ContinuousClock.now
    private var cancellation: (@MainActor () -> Void)?
    private var completionCallbacks: [
        @MainActor (AnimationOutcome) -> Void
    ] = []

    package init(id: UInt64) {
        self.id = id
    }

    package func install(
        token: PresentationCompletionToken,
        cancellation: @escaping @MainActor () -> Void
    ) {
        precondition(presentationToken == nil, "animation handle installed twice")
        presentationToken = token
        self.cancellation = cancellation
    }

    package func installLocalCancellation(
        _ cancellation: @escaping @MainActor () -> Void
    ) {
        precondition(self.cancellation == nil, "animation handle installed twice")
        self.cancellation = cancellation
    }

    public func cancel() {
        guard outcome == nil else { return }
        cancellation?()
    }

    @discardableResult
    public func onCompletion(
        _ callback: @escaping @MainActor (AnimationOutcome) -> Void
    ) -> Self {
        if let outcome {
            callback(outcome)
        } else {
            completionCallbacks.append(callback)
        }
        return self
    }

    package func markPublished() {
        isPublished = true
    }

    package func resolve(_ outcome: AnimationOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let elapsed = startedAt.duration(to: ContinuousClock.now).components
        let nanoseconds: UInt64
        if elapsed.seconds < 0 || elapsed.attoseconds < 0 {
            nanoseconds = 0
        } else {
            nanoseconds = UInt64(elapsed.seconds) &* 1_000_000_000
                &+ UInt64(elapsed.attoseconds / 1_000_000_000)
        }
        Trace.plot(
            "swift.nucleus.animation.completion_latency_ns",
            nanoseconds)
        cancellation = nil
        let callbacks = completionCallbacks
        completionCallbacks.removeAll(keepingCapacity: false)
        for callback in callbacks {
            callback(outcome)
        }
    }
}

/// What should happen to a view after a fade-out reaches its terminal frame.
public enum FadeOutDisposition: Sendable, Equatable {
    case none
    case hide
    case removeFromSuperview
}

extension View {
    /// Animate a scalar presentation-safe property.
    ///
    /// The final model value is assigned eagerly. The renderer temporarily
    /// overrides presentation from `from` to `to`, then acknowledges the
    /// handle after that terminal state is presented.
    @discardableResult
    public func animate(
        _ property: AnimatableProperty,
        from: Double,
        to: Double,
        timing: AnimationTiming = .standard,
        id requestedID: UInt64 = 0,
        completion: (@MainActor (AnimationOutcome) -> Void)? = nil
    ) -> AnimationHandle {
        precondition(
            from.isFinite && to.isFinite,
            "animation endpoints must be finite"
        )
        validate(timing)
        let keyPath = property.keyPath
        let animationID = requestedID == 0
            ? uiContext.allocateAnimationID()
            : requestedID
        let handle = makeAnimationHandle(
            id: animationID,
            keyPath: keyPath,
            completion: completion
        )

        uiContext.withActionPolicy(.none) {
            assignModelValue(to, for: property)
        }

        let duration = uiContext.effectiveAnimationDuration(timing.duration)
        guard duration > 0 else {
            completeWithoutPresentation(
                handle,
                result: .skippedReducedMotion
            )
            return handle
        }

        let animation = Animation.scalar(
            keyPath: keyPath,
            from: from,
            to: to,
            duration: duration,
            curve: timing.curve,
            id: animationID,
            completionToken: handle.presentationToken?.rawValue ?? 0
        )
        let generation = recordMutation(.animation)
        animationRequests[keyPath] = ViewAnimationRequest(
            generation: generation,
            operation: .add(animation)
        )
        return handle
    }

    /// Animate the view's complete 4×4 transform as one typed compositor slot.
    @discardableResult
    public func animateTransform(
        from: Transform,
        to: Transform,
        timing: AnimationTiming = .standard,
        id requestedID: UInt64 = 0,
        completion: (@MainActor (AnimationOutcome) -> Void)? = nil
    ) -> AnimationHandle {
        precondition(
            from.isFinite && to.isFinite,
            "transform animation endpoints must be finite"
        )
        validate(timing)
        let animationID = requestedID == 0
            ? uiContext.allocateAnimationID()
            : requestedID
        let handle = makeAnimationHandle(
            id: animationID,
            keyPath: .transform,
            completion: completion
        )

        uiContext.withActionPolicy(.none) {
            transform = to
        }

        let duration = uiContext.effectiveAnimationDuration(timing.duration)
        guard duration > 0 else {
            completeWithoutPresentation(
                handle,
                result: .skippedReducedMotion
            )
            return handle
        }

        let animation = Animation.transform(
            from: from.layersTransform,
            to: to.layersTransform,
            duration: duration,
            curve: timing.curve,
            id: animationID,
            completionToken: handle.presentationToken?.rawValue ?? 0
        )
        let generation = recordMutation(.animation)
        animationRequests[.transform] = ViewAnimationRequest(
            generation: generation,
            operation: .add(animation)
        )
        return handle
    }

    /// Stop the current animation for `property`. A published animation
    /// completes as cancelled only after the renderer presents its removal.
    public func removeAnimation(for property: AnimatableProperty) {
        removeAnimation(forKeyPath: property.keyPath)
    }

    public func removeTransformAnimation() {
        removeAnimation(forKeyPath: .transform)
    }

    /// Fade in from transparent to an explicit target. If no target is passed,
    /// the last nonzero opacity remembered by `fadeOut` is restored.
    @discardableResult
    public func fadeIn(
        to targetOpacity: Double? = nil,
        timing: AnimationTiming = .standard,
        completion: (@MainActor (AnimationOutcome) -> Void)? = nil
    ) -> AnimationHandle {
        let target = min(max(
            0,
            targetOpacity ??
                storedFadeTargetOpacity ??
                (alphaValue > 0 ? alphaValue : 1)
        ), 1)
        storedFadeTargetOpacity = target
        isHidden = false
        return animate(
            .opacity,
            from: 0,
            to: target,
            timing: timing,
            completion: completion
        )
    }

    /// Fade to transparent and optionally hide or remove the view only after
    /// the terminal frame is acknowledged.
    @discardableResult
    public func fadeOut(
        timing: AnimationTiming = .standard,
        disposition: FadeOutDisposition = .none,
        completion: (@MainActor (AnimationOutcome) -> Void)? = nil
    ) -> AnimationHandle {
        let start = alphaValue
        if start > 0 {
            storedFadeTargetOpacity = start
        }
        return animate(
            .opacity,
            from: start,
            to: 0,
            timing: timing
        ) { [weak self] outcome in
            guard let self else { return }
            if outcome == .completed || outcome == .skippedReducedMotion {
                switch disposition {
                case .none:
                    break
                case .hide:
                    isHidden = true
                case .removeFromSuperview:
                    removeFromSuperview()
                }
            }
            completion?(outcome)
        }
    }

    package func markAnimationRequestsPublished(through generation: UInt64) {
        for request in animationRequests.values
        where request.generation <= generation {
            guard case .add(let animation) = request.operation else { continue }
            animationHandles[animation.id]?.markPublished()
        }
    }

    package func cancelOwnedAnimationHandles() {
        let handles = Array(animationHandles.values)
        animationHandles.removeAll(keepingCapacity: false)
        currentAnimationHandleIDs.removeAll(keepingCapacity: false)
        animationRequests.removeAll(keepingCapacity: false)
        for handle in handles where !handle.isFinished {
            if let token = handle.presentationToken {
                uiContext.runtimeHost.presentationCompletions.resolve(
                    token,
                    result: .cancelled
                )
            } else {
                handle.resolve(.cancelled)
            }
        }
    }

    private func makeAnimationHandle(
        id: UInt64,
        keyPath: AnimationKeyPath,
        completion: (@MainActor (AnimationOutcome) -> Void)?
    ) -> AnimationHandle {
        precondition(id != 0, "animation id zero is reserved")
        precondition(
            animationHandles[id] == nil,
            "animation id \(id) is already active on this view"
        )

        if let currentID = currentAnimationHandleIDs[keyPath],
           let current = animationHandles[currentID],
           !current.isPublished
        {
            completeWithoutPresentation(current, result: .superseded)
        }

        let handle = AnimationHandle(id: id)
        if let completion {
            handle.onCompletion(completion)
        }
        let token = uiContext.runtimeHost.presentationCompletions.register {
            [weak self, weak handle] result in
            let outcome = AnimationOutcome(result)
            handle?.resolve(outcome)
            self?.animationHandleDidComplete(id: id, keyPath: keyPath)
        }
        handle.install(token: token) { [weak self, weak handle] in
            guard let self, let handle else { return }
            cancel(handle, keyPath: keyPath)
        }
        animationHandles[id] = handle
        currentAnimationHandleIDs[keyPath] = id
        return handle
    }

    private func cancel(
        _ handle: AnimationHandle,
        keyPath: AnimationKeyPath
    ) {
        guard !handle.isFinished else { return }
        guard currentAnimationHandleIDs[keyPath] == handle.id else {
            return
        }

        let generation = recordMutation(.animation)
        animationRequests[keyPath] = ViewAnimationRequest(
            generation: generation,
            operation: .remove(keyPath)
        )
        if !handle.isPublished {
            completeWithoutPresentation(handle, result: .cancelled)
        }
    }

    private func removeAnimation(forKeyPath keyPath: AnimationKeyPath) {
        let generation = recordMutation(.animation)
        animationRequests[keyPath] = ViewAnimationRequest(
            generation: generation,
            operation: .remove(keyPath)
        )
        guard let id = currentAnimationHandleIDs[keyPath],
              let handle = animationHandles[id],
              !handle.isPublished
        else {
            return
        }
        completeWithoutPresentation(handle, result: .cancelled)
    }

    private func completeWithoutPresentation(
        _ handle: AnimationHandle,
        result: PresentationCompletionResult
    ) {
        guard let token = handle.presentationToken else {
            handle.resolve(AnimationOutcome(result))
            return
        }
        uiContext.runtimeHost.presentationCompletions.resolve(
            token,
            result: result)
    }

    private func animationHandleDidComplete(
        id: UInt64,
        keyPath: AnimationKeyPath
    ) {
        animationHandles[id] = nil
        if currentAnimationHandleIDs[keyPath] == id {
            currentAnimationHandleIDs[keyPath] = nil
        }
    }

    private func assignModelValue(
        _ value: Double,
        for property: AnimatableProperty
    ) {
        switch property {
        case .opacity:
            alphaValue = value
        case .cornerRadius:
            cornerRadius = value
        case .positionX:
            frame = Rect(
                x: value,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            )
        case .positionY:
            frame = Rect(
                x: frame.origin.x,
                y: value,
                width: frame.size.width,
                height: frame.size.height
            )
        case .boundsWidth:
            frame = Rect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: max(0, value),
                height: frame.size.height
            )
        case .boundsHeight:
            frame = Rect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: max(0, value)
            )
        case .scrollOffsetX:
            boundsOrigin = Point(x: value, y: boundsOrigin.y)
        case .scrollOffsetY:
            boundsOrigin = Point(x: boundsOrigin.x, y: value)
        }
    }

    private func validate(_ timing: AnimationTiming) {
        precondition(
            timing.duration.isFinite && timing.duration >= 0,
            "animation duration must be finite and nonnegative"
        )
        switch timing.curve.kind {
        case .linear:
            break
        case .bezier:
            precondition(
                timing.curve.bezierP1x.isFinite &&
                    timing.curve.bezierP1y.isFinite &&
                    timing.curve.bezierP2x.isFinite &&
                    timing.curve.bezierP2y.isFinite,
                "animation Bézier control points must be finite"
            )
        case .spring:
            precondition(
                timing.curve.springMass.isFinite &&
                    timing.curve.springMass > 0 &&
                    timing.curve.springStiffness.isFinite &&
                    timing.curve.springStiffness > 0 &&
                    timing.curve.springDamping.isFinite &&
                    timing.curve.springDamping >= 0 &&
                    timing.curve.springInitialVelocity.isFinite,
                "animation spring parameters are invalid"
            )
        }
    }
}

private extension AnimationOutcome {
    init(_ result: PresentationCompletionResult) {
        switch result {
        case .completed:
            self = .completed
        case .cancelled:
            self = .cancelled
        case .superseded:
            self = .superseded
        case .skippedReducedMotion:
            self = .skippedReducedMotion
        case .failed:
            self = .failed
        }
    }
}
