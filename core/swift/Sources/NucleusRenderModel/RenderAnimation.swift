// Phase 10c.4 — the Swift animation engine.
//
// CoreAnimation-inspired native animation: BasicAnimation (timed bezier) and
// SpringAnimation (damped harmonic oscillator), plus their compound-Frame
// counterparts. The per-layer `animations` list holds in-flight records; the
// per-frame tick (`RetainedTreeStore.tick`) evaluates each at the present time,
// writes the interpolated value into the layer's presentation override (or, for
// transform components, rebuilds the combined transform matrix), commits the
// final model value when an animation completes, and fires completion events.
//
// Naming follows Apple's CoreAnimation 1:1. The
// `TimingFunction` (cubic bezier) is the one already ported in
// `RenderPresentationState.swift`; this file reuses it. `M44` rotate/translate/
// scale/concat come from `RenderM44Math.swift`.

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

// MARK: - Key paths + values

/// The animatable property a record drives. Mirrors `animation.AnimationKeyPath`.
public enum AnimationKeyPath: UInt8, Sendable {
    case positionX
    case positionY
    case opacity
    case transformScaleX
    case transformScaleY
    case transformScaleZ
    case transformRotationX
    case transformRotationY
    case transformRotationZ
    case transformTranslationX
    case transformTranslationY
    case transformTranslationZ
    case anchorPointX
    case anchorPointY
    case cornerRadius
    /// Compound rect of (left, top, right, bottom). Drives `position` and
    /// `bounds` overrides together as one retargetable record.
    case frame
    /// Scalar 0..1 progress for an in-flight `PresentationTransition`. The
    /// renderer feeds this into the contents-crossfade `progress` uniform.
    case contents

    /// True for the nine scalar transform components (handled by transform
    /// matrix rebuild, not a direct override field). Mirrors
    /// `isTransformComponentKeyPath`.
    var isTransformComponent: Bool {
        switch self {
        case .transformScaleX, .transformScaleY, .transformScaleZ,
             .transformRotationX, .transformRotationY, .transformRotationZ,
             .transformTranslationX, .transformTranslationY, .transformTranslationZ:
            return true
        default:
            return false
        }
    }
}

public typealias AnimationSlotKey = AnimationKeyPath

/// Tagged value returned by an animation step. Frame-typed animations return
/// `.frame`; everything else `.scalar`. Mirrors `animation.AnimationValue`.
public enum AnimationValue: Equatable, Sendable {
    case scalar(Float)
    case frame(Frame)

    var scalarOrZero: Float {
        switch self {
        case .scalar(let s): return s
        case .frame: return 0
        }
    }
}

/// One step's evaluation: the interpolated value + whether the animation is
/// complete. Mirrors `animation.AnimationResult`.
public struct AnimationResult: Equatable, Sendable {
    public var value: AnimationValue
    public var done: Bool

    public init(value: AnimationValue, done: Bool) {
        self.value = value
        self.done = done
    }
}

/// Opaque animation identity (0 = none). Mirrors `animation.AnimationID`.
public struct AnimationID: Equatable, Hashable, Sendable {
    public var raw: UInt64 = 0
    public init(raw: UInt64 = 0) { self.raw = raw }
    public static let none = AnimationID(raw: 0)
}

/// Opaque completion token (0 = none). Mirrors `animation.CompletionToken`.
public struct CompletionToken: Equatable, Hashable, Sendable {
    public var raw: UInt64 = 0
    public init(raw: UInt64 = 0) { self.raw = raw }
    public static let none = CompletionToken(raw: 0)
}

// MARK: - Basic (timed bezier) animations

/// Timed cubic-bezier scalar interpolation. Mirrors `animation.BasicAnimation`.
public struct BasicAnimation: Equatable, Sendable {
    public var keyPath: AnimationKeyPath
    public var fromValue: Float
    public var toValue: Float
    public var duration: Double = 0.25
    public var timingFunction: TimingFunction = .default
    public var beginTime: Double = 0
    public var elapsed: Double = 0

    public init(
        keyPath: AnimationKeyPath, fromValue: Float, toValue: Float,
        duration: Double = 0.25, timingFunction: TimingFunction = .default,
        beginTime: Double = 0
    ) {
        self.keyPath = keyPath
        self.fromValue = fromValue
        self.toValue = toValue
        self.duration = duration
        self.timingFunction = timingFunction
        self.beginTime = beginTime
    }

    public mutating func evaluateAt(_ presentTimeS: Double) -> AnimationResult {
        let elapsedS = max(0, presentTimeS - beginTime)
        elapsed = elapsedS
        return evaluateElapsed(elapsedS)
    }

    func evaluateElapsed(_ elapsedS: Double) -> AnimationResult {
        let t: Float = duration > 0 ? Float(min(elapsedS / duration, 1.0)) : 1.0
        let eased = timingFunction.evaluate(t)
        let value = fromValue + (toValue - fromValue) * eased
        return AnimationResult(value: .scalar(value), done: t >= 1.0)
    }

    var currentValue: AnimationValue {
        let t: Float = duration > 0 ? Float(min(elapsed / duration, 1.0)) : 1.0
        return .scalar(fromValue + (toValue - fromValue) * timingFunction.evaluate(t))
    }
}

/// Damped-harmonic-oscillator scalar interpolation. Mirrors
/// `animation.SpringAnimation`.
public struct SpringAnimation: Equatable, Sendable {
    public var keyPath: AnimationKeyPath
    public var fromValue: Float
    public var toValue: Float
    public var mass: Float = 1.0
    public var stiffness: Float = 100.0
    public var damping: Float = 10.0
    public var initialVelocity: Float = 0.0
    public var beginTime: Double = 0
    public var currentValueScalar: Float = 0
    public var velocity: Float = 0
    public var initialized: Bool = false

    public init(
        keyPath: AnimationKeyPath, fromValue: Float, toValue: Float,
        mass: Float = 1.0, stiffness: Float = 100.0, damping: Float = 10.0,
        initialVelocity: Float = 0.0, beginTime: Double = 0
    ) {
        self.keyPath = keyPath
        self.fromValue = fromValue
        self.toValue = toValue
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
        self.initialVelocity = initialVelocity
        self.beginTime = beginTime
    }

    mutating func step(_ dt: Double) -> AnimationResult {
        if !initialized {
            currentValueScalar = fromValue
            velocity = initialVelocity
            initialized = true
        }

        let dtF = Float(min(dt, 0.05))
        let w0 = (stiffness / mass).squareRoot()
        let zeta = damping / (2.0 * (stiffness * mass).squareRoot())

        let x = currentValueScalar - toValue
        let v = velocity

        var newX: Float
        var newV: Float
        if zeta >= 1.0 {
            let expTerm = expf(-w0 * zeta * dtF)
            let c1 = x
            let c2 = v + w0 * zeta * x
            newX = (c1 + c2 * dtF) * expTerm
            newV = (c2 - w0 * zeta * (c1 + c2 * dtF)) * expTerm
        } else {
            let wd = w0 * (1.0 - zeta * zeta).squareRoot()
            let expTerm = expf(-w0 * zeta * dtF)
            let cosTerm = cosf(wd * dtF)
            let sinTerm = sinf(wd * dtF)
            newX = expTerm * (x * cosTerm + ((v + w0 * zeta * x) / wd) * sinTerm)
            newV = expTerm * ((v * cosTerm) - ((v * w0 * zeta + x * w0 * w0) / wd) * sinTerm)
        }

        currentValueScalar = newX + toValue
        velocity = newV

        let travel = abs(toValue - fromValue)
        let threshold = max(0.5, travel * 0.005)
        let settled = abs(newX) < threshold && abs(newV) < threshold
        if settled {
            currentValueScalar = toValue
            velocity = 0
        }
        return AnimationResult(value: .scalar(currentValueScalar), done: settled)
    }

    mutating func evaluateAt(_ presentTimeS: Double, _ previousPresentTimeS: Double) -> AnimationResult {
        if !initialized {
            currentValueScalar = fromValue
            velocity = initialVelocity
            initialized = true
        }
        if presentTimeS <= beginTime {
            return AnimationResult(value: .scalar(currentValueScalar), done: false)
        }
        let startS = previousPresentTimeS > beginTime ? previousPresentTimeS : beginTime
        let dt = max(0, presentTimeS - startS)
        return step(dt)
    }

    var currentValue: AnimationValue {
        .scalar(initialized ? currentValueScalar : fromValue)
    }
}

/// Compound-frame counterpart of `BasicAnimation`. Mirrors
/// `animation.BasicFrameAnimation`.
public struct BasicFrameAnimation: Equatable, Sendable {
    public var keyPath: AnimationKeyPath
    public var fromValue: Frame
    public var toValue: Frame
    public var duration: Double = 0.25
    public var timingFunction: TimingFunction = .default
    public var beginTime: Double = 0
    public var elapsed: Double = 0

    public init(
        keyPath: AnimationKeyPath, fromValue: Frame, toValue: Frame,
        duration: Double = 0.25, timingFunction: TimingFunction = .default,
        beginTime: Double = 0
    ) {
        self.keyPath = keyPath
        self.fromValue = fromValue
        self.toValue = toValue
        self.duration = duration
        self.timingFunction = timingFunction
        self.beginTime = beginTime
    }

    public mutating func evaluateAt(_ presentTimeS: Double) -> AnimationResult {
        let elapsedS = max(0, presentTimeS - beginTime)
        elapsed = elapsedS
        return evaluateElapsed(elapsedS)
    }

    func evaluateElapsed(_ elapsedS: Double) -> AnimationResult {
        let t: Float = duration > 0 ? Float(min(elapsedS / duration, 1.0)) : 1.0
        let eased = timingFunction.evaluate(t)
        return AnimationResult(value: .frame(Self.lerp(fromValue, toValue, eased)), done: t >= 1.0)
    }

    var currentValue: AnimationValue {
        let t: Float = duration > 0 ? Float(min(elapsed / duration, 1.0)) : 1.0
        return .frame(Self.lerp(fromValue, toValue, timingFunction.evaluate(t)))
    }

    static func lerp(_ a: Frame, _ b: Frame, _ eased: Float) -> Frame {
        Frame(
            left: a.left + (b.left - a.left) * eased,
            top: a.top + (b.top - a.top) * eased,
            right: a.right + (b.right - a.right) * eased,
            bottom: a.bottom + (b.bottom - a.bottom) * eased)
    }
}

/// Compound-frame counterpart of `SpringAnimation`: each edge runs an
/// independent oscillator with shared spring parameters and a shared settle
/// decision. Mirrors `animation.SpringFrameAnimation`.
public struct SpringFrameAnimation: Equatable, Sendable {
    public var keyPath: AnimationKeyPath
    public var fromValue: Frame
    public var toValue: Frame
    public var mass: Float = 1.0
    public var stiffness: Float = 784.0
    public var damping: Float = 56.0
    public var initialVelocity: Frame = Frame(left: 0, top: 0, right: 0, bottom: 0)
    public var beginTime: Double = 0
    public var currentValueFrame: Frame = Frame(left: 0, top: 0, right: 0, bottom: 0)
    public var velocity: Frame = Frame(left: 0, top: 0, right: 0, bottom: 0)
    public var initialized: Bool = false

    public init(
        keyPath: AnimationKeyPath, fromValue: Frame, toValue: Frame,
        mass: Float = 1.0, stiffness: Float = 784.0, damping: Float = 56.0,
        initialVelocity: Frame = Frame(left: 0, top: 0, right: 0, bottom: 0),
        beginTime: Double = 0
    ) {
        self.keyPath = keyPath
        self.fromValue = fromValue
        self.toValue = toValue
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
        self.initialVelocity = initialVelocity
        self.beginTime = beginTime
    }

    static func stepEdge(_ x: Float, _ v: Float, _ w0: Float, _ zeta: Float, _ dtF: Float) -> (x: Float, v: Float) {
        if zeta >= 1.0 {
            let expTerm = expf(-w0 * zeta * dtF)
            let c1 = x
            let c2 = v + w0 * zeta * x
            return (
                x: (c1 + c2 * dtF) * expTerm,
                v: (c2 - w0 * zeta * (c1 + c2 * dtF)) * expTerm)
        } else {
            let wd = w0 * (1.0 - zeta * zeta).squareRoot()
            let expTerm = expf(-w0 * zeta * dtF)
            let cosTerm = cosf(wd * dtF)
            let sinTerm = sinf(wd * dtF)
            return (
                x: expTerm * (x * cosTerm + ((v + w0 * zeta * x) / wd) * sinTerm),
                v: expTerm * ((v * cosTerm) - ((v * w0 * zeta + x * w0 * w0) / wd) * sinTerm))
        }
    }

    public mutating func step(_ dt: Double) -> AnimationResult {
        if !initialized {
            currentValueFrame = fromValue
            velocity = initialVelocity
            initialized = true
        }

        let dtF = Float(min(dt, 0.05))
        let w0 = (stiffness / mass).squareRoot()
        let zeta = damping / (2.0 * (stiffness * mass).squareRoot())

        let sl = Self.stepEdge(currentValueFrame.left - toValue.left, velocity.left, w0, zeta, dtF)
        let st = Self.stepEdge(currentValueFrame.top - toValue.top, velocity.top, w0, zeta, dtF)
        let sr = Self.stepEdge(currentValueFrame.right - toValue.right, velocity.right, w0, zeta, dtF)
        let sb = Self.stepEdge(currentValueFrame.bottom - toValue.bottom, velocity.bottom, w0, zeta, dtF)

        currentValueFrame = Frame(
            left: sl.x + toValue.left, top: st.x + toValue.top,
            right: sr.x + toValue.right, bottom: sb.x + toValue.bottom)
        velocity = Frame(left: sl.v, top: st.v, right: sr.v, bottom: sb.v)

        let travelL = abs(toValue.left - fromValue.left)
        let travelT = abs(toValue.top - fromValue.top)
        let travelR = abs(toValue.right - fromValue.right)
        let travelB = abs(toValue.bottom - fromValue.bottom)
        let maxTravel = max(max(travelL, travelT), max(travelR, travelB))
        let threshold = max(0.5, maxTravel * 0.005)

        let settled =
            abs(sl.x) < threshold && abs(st.x) < threshold && abs(sr.x) < threshold && abs(sb.x) < threshold &&
            abs(sl.v) < threshold && abs(st.v) < threshold && abs(sr.v) < threshold && abs(sb.v) < threshold

        if settled {
            currentValueFrame = toValue
            velocity = Frame(left: 0, top: 0, right: 0, bottom: 0)
        }
        return AnimationResult(value: .frame(currentValueFrame), done: settled)
    }

    mutating func evaluateAt(_ presentTimeS: Double, _ previousPresentTimeS: Double) -> AnimationResult {
        if !initialized {
            currentValueFrame = fromValue
            velocity = initialVelocity
            initialized = true
        }
        if presentTimeS <= beginTime {
            return AnimationResult(value: .frame(currentValueFrame), done: false)
        }
        let startS = previousPresentTimeS > beginTime ? previousPresentTimeS : beginTime
        let dt = max(0, presentTimeS - startS)
        return step(dt)
    }

    var currentValue: AnimationValue {
        .frame(initialized ? currentValueFrame : fromValue)
    }
}

// MARK: - Animation union

/// One of the four animation variants. Mirrors `animation.Animation`.
public enum Animation: Equatable, Sendable {
    case basic(BasicAnimation)
    case spring(SpringAnimation)
    case basicFrame(BasicFrameAnimation)
    case springFrame(SpringFrameAnimation)

    public var keyPath: AnimationKeyPath {
        switch self {
        case .basic(let a): return a.keyPath
        case .spring(let a): return a.keyPath
        case .basicFrame(let a): return a.keyPath
        case .springFrame(let a): return a.keyPath
        }
    }

    public mutating func evaluateAt(_ presentTimeS: Double, _ previousPresentTimeS: Double) -> AnimationResult {
        switch self {
        case .basic(var a):
            let r = a.evaluateAt(presentTimeS); self = .basic(a); return r
        case .basicFrame(var a):
            let r = a.evaluateAt(presentTimeS); self = .basicFrame(a); return r
        case .spring(var a):
            let r = a.evaluateAt(presentTimeS, previousPresentTimeS); self = .spring(a); return r
        case .springFrame(var a):
            let r = a.evaluateAt(presentTimeS, previousPresentTimeS); self = .springFrame(a); return r
        }
    }

    public mutating func setBeginTime(_ beginTimeS: Double) {
        switch self {
        case .basic(var a): a.beginTime = beginTimeS; self = .basic(a)
        case .spring(var a): a.beginTime = beginTimeS; self = .spring(a)
        case .basicFrame(var a): a.beginTime = beginTimeS; self = .basicFrame(a)
        case .springFrame(var a): a.beginTime = beginTimeS; self = .springFrame(a)
        }
    }

    var finalValue: AnimationValue {
        switch self {
        case .basic(let a): return .scalar(a.toValue)
        case .spring(let a): return .scalar(a.toValue)
        case .basicFrame(let a): return .frame(a.toValue)
        case .springFrame(let a): return .frame(a.toValue)
        }
    }

    var initialValue: AnimationValue {
        switch self {
        case .basic(let a): return .scalar(a.fromValue)
        case .spring(let a): return .scalar(a.fromValue)
        case .basicFrame(let a): return .frame(a.fromValue)
        case .springFrame(let a): return .frame(a.fromValue)
        }
    }

    /// The value the animation is currently displaying without advancing it.
    /// Mirrors `animationCurrentValue`.
    var currentValue: AnimationValue {
        switch self {
        case .basic(let a): return a.currentValue
        case .spring(let a): return a.currentValue
        case .basicFrame(let a): return a.currentValue
        case .springFrame(let a): return a.currentValue
        }
    }
}

// MARK: - Records + events

/// One in-flight animation bound to a layer slot. Mirrors
/// `animation.AnimationRecord`.
public struct AnimationRecord: Equatable, Sendable {
    public var id: AnimationID
    public var layerId: UInt64
    public var keyPath: AnimationKeyPath
    public var slotKey: AnimationSlotKey
    public var completionToken: CompletionToken
    public var transactionId: UInt64
    public var animation: Animation

    public init(
        id: AnimationID, layerId: UInt64, animation: Animation,
        completionToken: CompletionToken = .none, transactionId: UInt64 = 0,
        slotKey: AnimationSlotKey? = nil
    ) {
        let keyPath = animation.keyPath
        self.id = id
        self.layerId = layerId
        self.keyPath = keyPath
        self.slotKey = slotKey ?? keyPath
        self.completionToken = completionToken
        self.transactionId = transactionId
        self.animation = animation
    }
}

/// Why an animation stopped. Mirrors `animation.AnimationStopReason`.
public enum AnimationStopReason: Equatable, Sendable {
    case completed
    case replaced
    case removed
    case layerRemoved
    case targetMissing
    case cancelledBeforeStart
}

/// Lifecycle event emitted by the engine for transaction-completion matching.
/// Mirrors `animation.AnimationEvent`.
public enum AnimationEvent: Equatable, Sendable {
    case started(animationId: AnimationID, layerId: UInt64, keyPath: AnimationKeyPath,
                 completionToken: CompletionToken, transactionId: UInt64)
    case stopped(animationId: AnimationID, layerId: UInt64, keyPath: AnimationKeyPath,
                 completionToken: CompletionToken, transactionId: UInt64,
                 finished: Bool, reason: AnimationStopReason)
}

// MARK: - Content-reveal sink

/// Sink the `.contents` key path drives during a presentation transition. The
/// store wires its `PresentationOperationService` here; the null sink drops the
/// writes. Synchronous and single-threaded (the tick drives it on the compositor
/// main loop) — deliberately non-isolated so the nonisolated `Layer` mutators can
/// call it. Mirrors `RenderServer.OperationProgressSink` /
/// `NullPresentationTransitionSink`.
public protocol PresentationTransitionSink: AnyObject {
    func writeContentRevealProgress(layerId: UInt64, value: Float)
    func finishContentRevealProgress(layerId: UInt64, value: Float)
}

public final class NullPresentationTransitionSink: PresentationTransitionSink, @unchecked Sendable {
    public init() {}
    public func writeContentRevealProgress(layerId: UInt64, value: Float) {}
    public func finishContentRevealProgress(layerId: UInt64, value: Float) {}
}

// MARK: - Per-layer mutation (write / commit / clear / rebuild)

extension Layer {
    /// Add or replace (velocity-preserving) a record on its slot. Mirrors
    /// `addAnimationToLayer`.
    mutating func addAnimation(_ record: AnimationRecord, events: inout [AnimationEvent]) {
        for i in animations.indices where animations[i].slotKey == record.slotKey {
            var next = record
            copyVelocity(from: animations[i].animation, into: &next.animation)
            events.append(.stopped(
                animationId: animations[i].id, layerId: animations[i].layerId,
                keyPath: animations[i].keyPath, completionToken: animations[i].completionToken,
                transactionId: animations[i].transactionId, finished: false, reason: .replaced))
            animations[i] = next
            events.append(.started(
                animationId: next.id, layerId: next.layerId, keyPath: next.keyPath,
                completionToken: next.completionToken, transactionId: next.transactionId))
            return
        }
        animations.append(record)
        events.append(.started(
            animationId: record.id, layerId: record.layerId, keyPath: record.keyPath,
            completionToken: record.completionToken, transactionId: record.transactionId))
    }

    /// Seed the layer's override to the record's initial value (so a sample
    /// before the first tick already shows the animation's start). Mirrors
    /// `seedAnimationStartValueOnLayer`.
    mutating func seedAnimationStartValue(_ record: AnimationRecord, sink: PresentationTransitionSink) {
        if record.keyPath.isTransformComponent {
            rebuildTransformOverride()
        } else {
            writeAnimatedField(record.keyPath, record.animation.initialValue, sink: sink)
        }
    }

    /// Tick every record on this layer to `presentTimeS`, applying results and
    /// firing completion events. Returns true when any record is still active.
    /// Mirrors `tickLayerToPresentTimeAndApplyWithSink`.
    mutating func tickAnimations(
        previousPresentTimeS: Double, presentTimeS: Double,
        events: inout [AnimationEvent], sink: PresentationTransitionSink
    ) -> Bool {
        if animations.isEmpty { return false }

        var anyActive = false
        var transformTouched = false
        var i = 0
        while i < animations.count {
            let result = animations[i].animation.evaluateAt(presentTimeS, previousPresentTimeS)
            let keyPath = animations[i].keyPath
            let isTransform = keyPath.isTransformComponent
            if result.done {
                let record = animations[i]
                commitModelField(keyPath, record.animation.finalValue, sink: sink)
                if isTransform {
                    transformTouched = true
                } else {
                    clearOverrideField(keyPath)
                }
                animations.swapAt(i, animations.count - 1)
                animations.removeLast()
                events.append(.stopped(
                    animationId: record.id, layerId: record.layerId, keyPath: record.keyPath,
                    completionToken: record.completionToken, transactionId: record.transactionId,
                    finished: true, reason: .completed))
            } else {
                if isTransform {
                    transformTouched = true
                } else {
                    writeAnimatedField(keyPath, result.value, sink: sink)
                }
                anyActive = true
                i += 1
            }
        }
        if transformTouched { rebuildTransformOverride() }
        return anyActive
    }

    /// Write an active animation's value into the presentation override.
    /// Mirrors `writeAnimatedField`.
    private mutating func writeAnimatedField(
        _ keyPath: AnimationKeyPath, _ value: AnimationValue, sink: PresentationTransitionSink
    ) {
        switch keyPath {
        case .positionX:
            var ov = presentation.override_ ?? PresentationOverride()
            let cur = ov.position ?? model.properties.position
            ov.position = Point2D(x: value.scalarOrZero, y: cur.y)
            presentation.override_ = ov
        case .positionY:
            var ov = presentation.override_ ?? PresentationOverride()
            let cur = ov.position ?? model.properties.position
            ov.position = Point2D(x: cur.x, y: value.scalarOrZero)
            presentation.override_ = ov
        case .anchorPointX:
            var ov = presentation.override_ ?? PresentationOverride()
            let cur = ov.anchorPoint ?? model.properties.anchorPoint
            ov.anchorPoint = Point2D(x: value.scalarOrZero, y: cur.y)
            presentation.override_ = ov
        case .anchorPointY:
            var ov = presentation.override_ ?? PresentationOverride()
            let cur = ov.anchorPoint ?? model.properties.anchorPoint
            ov.anchorPoint = Point2D(x: cur.x, y: value.scalarOrZero)
            presentation.override_ = ov
        case .opacity:
            var ov = presentation.override_ ?? PresentationOverride()
            ov.opacity = value.scalarOrZero
            presentation.override_ = ov
        case .frame:
            if case .frame(let f) = value {
                var ov = presentation.override_ ?? PresentationOverride()
                ov.position = Point2D(x: f.left, y: f.top)
                ov.bounds = Bounds(w: f.right - f.left, h: f.bottom - f.top)
                presentation.override_ = ov
            }
        case .contents:
            // Drives the transition progress directly; no override field. If the
            // transition was torn down the sink silently drops the write.
            sink.writeContentRevealProgress(layerId: id, value: value.scalarOrZero)
        case .cornerRadius:
            var ov = presentation.override_ ?? PresentationOverride()
            ov.cornerRadiusUniform = value.scalarOrZero
            presentation.override_ = ov
        case .transformScaleX, .transformScaleY, .transformScaleZ,
             .transformRotationX, .transformRotationY, .transformRotationZ,
             .transformTranslationX, .transformTranslationY, .transformTranslationZ:
            break  // handled by rebuildTransformOverride
        }
    }

    /// Commit an animation's final value to the model on completion. Mirrors
    /// `commitModelField`.
    private mutating func commitModelField(
        _ keyPath: AnimationKeyPath, _ value: AnimationValue, sink: PresentationTransitionSink
    ) {
        switch keyPath {
        case .positionX: model.properties.position.x = value.scalarOrZero
        case .positionY: model.properties.position.y = value.scalarOrZero
        case .anchorPointX: model.properties.anchorPoint.x = value.scalarOrZero
        case .anchorPointY: model.properties.anchorPoint.y = value.scalarOrZero
        case .opacity: model.properties.opacity = value.scalarOrZero
        case .frame:
            if case .frame(let f) = value {
                model.properties.position = Point2D(x: f.left, y: f.top)
                let newBounds = Bounds(w: f.right - f.left, h: f.bottom - f.top)
                model.properties.bounds = newBounds
                if var clip = model.properties.clip {
                    clip.rect.2 = newBounds.w
                    clip.rect.3 = newBounds.h
                    model.properties.clip = clip
                }
            }
        case .contents:
            // Mark the transition done so the next tick (or the renderer) tears
            // it down. There is no model side for `.contents`.
            sink.finishContentRevealProgress(layerId: id, value: value.scalarOrZero)
        case .cornerRadius:
            // Commit the final radius uniformly to all four corners. Any prior
            // per-corner asymmetry is lost — the animation is scalar-uniform.
            let r = value.scalarOrZero
            var vs = model.visualStyle ?? VisualStyle(cornerRadii: (r, r, r, r))
            vs.cornerRadii = (r, r, r, r)
            model.visualStyle = vs
            model.visualRevision &+= 1
        case .transformScaleX, .transformScaleY, .transformScaleZ,
             .transformRotationX, .transformRotationY, .transformRotationZ,
             .transformTranslationX, .transformTranslationY, .transformTranslationZ:
            break
        }
    }

    /// Clear one override field on completion, collapsing the override to nil
    /// when fully empty. Mirrors `clearOverrideField`.
    private mutating func clearOverrideField(_ keyPath: AnimationKeyPath) {
        guard var ov = presentation.override_ else { return }
        switch keyPath {
        case .positionX, .positionY: ov.position = nil
        case .anchorPointX, .anchorPointY: ov.anchorPoint = nil
        case .opacity: ov.opacity = nil
        case .frame:
            ov.position = nil
            ov.bounds = nil
        case .cornerRadius: ov.cornerRadiusUniform = nil
        case .contents: break  // transition lives in PresentationState
        case .transformScaleX, .transformScaleY, .transformScaleZ,
             .transformRotationX, .transformRotationY, .transformRotationZ,
             .transformTranslationX, .transformTranslationY, .transformTranslationZ:
            break
        }
        if ov.transform == nil && ov.opacity == nil && ov.position == nil &&
            ov.bounds == nil && ov.anchorPoint == nil && ov.cornerRadiusUniform == nil {
            presentation.override_ = nil
        } else {
            presentation.override_ = ov
        }
    }

    /// Rebuild the combined transform override from all transform-component
    /// animations on this layer. Mirrors `rebuildTransformOverride`.
    private mutating func rebuildTransformOverride() {
        var tx: Float = 0, ty: Float = 0, tz: Float = 0
        var sx: Float = 1, sy: Float = 1, sz: Float = 1
        var rx: Float = 0, ry: Float = 0, rz: Float = 0
        var hasTransform = false

        for record in animations {
            let av = record.animation.currentValue
            guard case .scalar(let value) = av else { continue }
            switch record.keyPath {
            case .transformScaleX: sx = value; hasTransform = true
            case .transformScaleY: sy = value; hasTransform = true
            case .transformScaleZ: sz = value; hasTransform = true
            case .transformRotationX: rx = value; hasTransform = true
            case .transformRotationY: ry = value; hasTransform = true
            case .transformRotationZ: rz = value; hasTransform = true
            case .transformTranslationX: tx = value; hasTransform = true
            case .transformTranslationY: ty = value; hasTransform = true
            case .transformTranslationZ: tz = value; hasTransform = true
            default: break
            }
        }

        var ov = presentation.override_ ?? PresentationOverride()
        if hasTransform {
            ov.transform = M44.translate(tx, ty, tz)
                .concat(M44.rotateX(rx))
                .concat(M44.rotateY(ry))
                .concat(M44.rotateZ(rz))
                .concat(M44.scale(sx, sy, sz))
            presentation.override_ = ov
            return
        }
        ov.transform = nil
        if ov.opacity == nil && ov.position == nil && ov.bounds == nil && ov.anchorPoint == nil {
            presentation.override_ = nil
        } else {
            presentation.override_ = ov
        }
    }
}

/// Copy current velocity from an in-flight existing animation into a new one on
/// the same slot (velocity-preserving retarget). Variant types must match.
/// Mirrors `copyVelocityFromExisting`.
private func copyVelocity(from existing: Animation, into next: inout Animation) {
    switch next {
    case .spring(var newS):
        if case .spring(let old) = existing, old.initialized {
            newS.initialVelocity = old.velocity
            next = .spring(newS)
        }
    case .springFrame(var newSF):
        if case .springFrame(let old) = existing, old.initialized {
            newSF.initialVelocity = old.velocity
            next = .springFrame(newSF)
        }
    case .basic, .basicFrame:
        break
    }
}
