import Foundation
@_spi(NucleusCompositor) import NucleusLayers

/// Semantic identity for one animated value owned by an object.
public struct AnimationPropertyKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "animation property key cannot be empty")
        self.rawValue = rawValue
    }
}

public enum AnimationRepeatBehavior: Sendable, Equatable {
    case once
    case count(Int)
    case forever
}

/// Whether a value follows accessibility motion speed or actual elapsed time.
public enum AnimationTimeMode: Sendable, Equatable {
    case motionScaled
    case realElapsed
}

public struct ValueAnimationOptions: Sendable, Equatable {
    public var timing: AnimationTiming
    public var repeatBehavior: AnimationRepeatBehavior
    public var autoreverses: Bool
    public var timeMode: AnimationTimeMode

    public init(
        timing: AnimationTiming = .standard,
        repeatBehavior: AnimationRepeatBehavior = .once,
        autoreverses: Bool = false,
        timeMode: AnimationTimeMode = .motionScaled
    ) {
        if case .count(let count) = repeatBehavior {
            precondition(count > 0, "animation repeat count must be positive")
        }
        self.timing = timing
        self.repeatBehavior = repeatBehavior
        self.autoreverses = autoreverses
        self.timeMode = timeMode
    }
}

package struct ValueAnimationSlot: Hashable {
    package var owner: ObjectIdentifier
    package var property: AnimationPropertyKey
}

@MainActor
package final class ValueAnimationRecord: ~Sendable {
    package weak var owner: AnyObject?
    package let slot: ValueAnimationSlot
    package let from: Double
    package let to: Double
    package let durationNanoseconds: UInt64
    package let timingCurve: AnimationCurve
    package let repeatBehavior: AnimationRepeatBehavior
    package let autoreverses: Bool
    package let timeMode: AnimationTimeMode
    package let handle: AnimationHandle
    package let update: @MainActor (Double) -> Void
    package var startNanoseconds: UInt64?

    package init(
        owner: AnyObject,
        slot: ValueAnimationSlot,
        from: Double,
        to: Double,
        durationNanoseconds: UInt64,
        timingCurve: AnimationCurve,
        repeatBehavior: AnimationRepeatBehavior,
        autoreverses: Bool,
        timeMode: AnimationTimeMode,
        handle: AnimationHandle,
        update: @escaping @MainActor (Double) -> Void
    ) {
        self.owner = owner
        self.slot = slot
        self.from = from
        self.to = to
        self.durationNanoseconds = durationNanoseconds
        self.timingCurve = timingCurve
        self.repeatBehavior = repeatBehavior
        self.autoreverses = autoreverses
        self.timeMode = timeMode
        self.handle = handle
        self.update = update
    }
}

extension UIContext {
    /// Install the host's coalesced frame-demand hook. The callback is invoked
    /// once when animation work begins and once after each sampled frame while
    /// work remains.
    public func setAnimationFrameRequestHandler(
        _ handler: (@MainActor () -> Void)?
    ) {
        valueAnimationFrameRequest = handler
        valueAnimationFrameRequestPending = false
        if handler != nil, !valueAnimationRecords.isEmpty {
            requestValueAnimationFrame()
        }
    }

    /// Animate arbitrary scalar semantic state on the main actor.
    ///
    /// `owner` is weakly observed. Once it is destroyed, no subsequent setter
    /// callback is invoked. A second request for the same owner/property
    /// supersedes the first deterministically.
    @discardableResult
    public func animateValue(
        owner: AnyObject,
        property: AnimationPropertyKey,
        from: Double,
        to: Double,
        options: ValueAnimationOptions = ValueAnimationOptions(),
        update: @escaping @MainActor (Double) -> Void,
        completion: (@MainActor (AnimationOutcome) -> Void)? = nil
    ) -> AnimationHandle {
        precondition(
            from.isFinite && to.isFinite,
            "value animation endpoints must be finite"
        )
        validateValueAnimation(options)

        let id = allocateAnimationID()
        let handle = AnimationHandle(id: id)
        if let completion {
            handle.onCompletion(completion)
        }
        let slot = ValueAnimationSlot(
            owner: ObjectIdentifier(owner),
            property: property
        )
        if let replacedID = valueAnimationSlots[slot] {
            finishValueAnimation(id: replacedID, outcome: .superseded)
        }
        handle.installLocalCancellation { [weak self] in
            self?.finishValueAnimation(id: id, outcome: .cancelled)
        }

        let rawDuration = options.timing.duration
        let duration: Double
        switch options.timeMode {
        case .motionScaled:
            duration = effectiveAnimationDuration(rawDuration)
        case .realElapsed:
            duration = rawDuration
        }

        update(from)
        guard duration > 0 else {
            update(to)
            handle.resolve(
                options.timeMode == .motionScaled
                    && environment.reducesMotion
                    ? .skippedReducedMotion
                    : .completed
            )
            return handle
        }

        let durationNanoseconds = UInt64(
            min(duration * 1_000_000_000, Double(UInt64.max))
        )
        let record = ValueAnimationRecord(
            owner: owner,
            slot: slot,
            from: from,
            to: to,
            durationNanoseconds: max(1, durationNanoseconds),
            timingCurve: options.timing.curve,
            repeatBehavior: options.repeatBehavior,
            autoreverses: options.autoreverses,
            timeMode: options.timeMode,
            handle: handle,
            update: update
        )
        record.startNanoseconds = valueAnimationLastPresentationNanoseconds
        valueAnimationRecords[id] = record
        valueAnimationSlots[slot] = id
        requestValueAnimationFrame()
        return handle
    }

    public func cancelAnimations(owner: AnyObject) {
        let ownerID = ObjectIdentifier(owner)
        let ids = valueAnimationRecords.compactMap { id, record in
            record.slot.owner == ownerID ? id : nil
        }
        for id in ids {
            finishValueAnimation(id: id, outcome: .cancelled)
        }
    }

    public func cancelAnimation(
        owner: AnyObject,
        property: AnimationPropertyKey
    ) {
        let slot = ValueAnimationSlot(
            owner: ObjectIdentifier(owner),
            property: property
        )
        guard let id = valueAnimationSlots[slot] else { return }
        finishValueAnimation(id: id, outcome: .cancelled)
    }

    /// Sample every main-actor animation at one host-predicted presentation
    /// timestamp. Returns whether continuous frame demand remains.
    @discardableResult
    public func advanceAnimations(
        predictedPresentationNanoseconds now: UInt64
    ) -> Bool {
        valueAnimationFrameRequestPending = false
        valueAnimationLastPresentationNanoseconds = now
        let ids = valueAnimationRecords.keys.sorted()
        for id in ids {
            guard let record = valueAnimationRecords[id] else { continue }
            guard record.owner != nil else {
                finishValueAnimation(id: id, outcome: .cancelled)
                continue
            }
            if record.startNanoseconds == nil {
                record.startNanoseconds = now
            }
            guard let start = record.startNanoseconds else { continue }
            let elapsed = now >= start ? now - start : 0
            sample(record, id: id, elapsedNanoseconds: elapsed)
        }

        let remainsActive = !valueAnimationRecords.isEmpty
        if remainsActive {
            requestValueAnimationFrame()
        }
        return remainsActive
    }

    package func finishValueAnimation(
        id: UInt64,
        outcome: AnimationOutcome
    ) {
        guard let record = valueAnimationRecords.removeValue(forKey: id) else {
            return
        }
        if valueAnimationSlots[record.slot] == id {
            valueAnimationSlots[record.slot] = nil
        }
        record.handle.resolve(outcome)
    }

    package func finishMotionScaledValueAnimationsForReducedMotion() {
        let ids = valueAnimationRecords.keys.sorted()
        for id in ids {
            guard let record = valueAnimationRecords[id],
                  record.timeMode == .motionScaled
            else {
                continue
            }
            if record.owner != nil {
                record.update(record.to)
            }
            finishValueAnimation(id: id, outcome: .skippedReducedMotion)
        }
    }

    private func sample(
        _ record: ValueAnimationRecord,
        id: UInt64,
        elapsedNanoseconds: UInt64
    ) {
        let leg = record.durationNanoseconds
        let iterationDuration: (partialValue: UInt64, overflow: Bool) =
            record.autoreverses
            ? leg.multipliedReportingOverflow(by: 2)
            : (partialValue: leg, overflow: false)
        let iterationNs = iterationDuration.overflow
            ? UInt64.max
            : iterationDuration.partialValue
        let iterationLimit: UInt64?
        switch record.repeatBehavior {
        case .once:
            iterationLimit = 1
        case .count(let count):
            iterationLimit = UInt64(count)
        case .forever:
            iterationLimit = nil
        }

        if let iterationLimit {
            let total = iterationNs.multipliedReportingOverflow(
                by: iterationLimit
            )
            let totalNs = total.overflow ? UInt64.max : total.partialValue
            if elapsedNanoseconds >= totalNs {
                record.update(record.autoreverses ? record.from : record.to)
                finishValueAnimation(id: id, outcome: .completed)
                return
            }
        }

        let local = iterationNs > 0
            ? elapsedNanoseconds % iterationNs
            : 0
        let reverses = record.autoreverses && local >= leg
        let legElapsed = reverses ? local - leg : local
        let progress = min(
            1,
            Double(legElapsed) / Double(record.durationNanoseconds)
        )
        let eased = sampleTiming(record.timingCurve, progress: progress)
        let directed = reverses ? 1 - eased : eased
        let value = record.from + (record.to - record.from) * directed
        guard value.isFinite else {
            finishValueAnimation(id: id, outcome: .failed)
            return
        }
        record.update(value)
    }

    private func sampleTiming(
        _ curve: AnimationCurve,
        progress: Double
    ) -> Double {
        switch curve.kind {
        case .linear:
            return progress
        case .bezier:
            return cubicBezier(
                progress,
                x1: Double(curve.bezierP1x),
                y1: Double(curve.bezierP1y),
                x2: Double(curve.bezierP2x),
                y2: Double(curve.bezierP2y)
            )
        case .spring:
            let mass = Double(curve.springMass)
            let stiffness = Double(curve.springStiffness)
            let damping = Double(curve.springDamping)
            let velocity = Double(curve.springInitialVelocity)
            let omega0 = (stiffness / mass).squareRoot()
            let zeta = damping / (2 * (stiffness * mass).squareRoot())
            if zeta < 1 {
                let omegaD = omega0 * (1 - zeta * zeta).squareRoot()
                let decay = exp(-zeta * omega0 * progress)
                let coefficient = (zeta * omega0 - velocity) / omegaD
                return 1 - decay * (
                    cos(omegaD * progress) +
                    coefficient * sin(omegaD * progress)
                )
            }
            return 1 - exp(-omega0 * progress)
        }
    }

    private func cubicBezier(
        _ progress: Double,
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double
    ) -> Double {
        func coordinate(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let inverse = 1 - t
            return 3 * inverse * inverse * t * a +
                3 * inverse * t * t * b +
                t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if coordinate(middle, x1, x2) < progress {
                low = middle
            } else {
                high = middle
            }
        }
        return coordinate((low + high) / 2, y1, y2)
    }

    private func validateValueAnimation(_ options: ValueAnimationOptions) {
        let timing = options.timing
        precondition(
            timing.duration.isFinite && timing.duration >= 0,
            "value animation duration must be finite and nonnegative"
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
                "value animation Bézier control points must be finite"
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
                "value animation spring parameters are invalid"
            )
        }
    }

    private func requestValueAnimationFrame() {
        guard !valueAnimationFrameRequestPending else { return }
        valueAnimationFrameRequestPending = true
        valueAnimationFrameRequest?()
    }
}
