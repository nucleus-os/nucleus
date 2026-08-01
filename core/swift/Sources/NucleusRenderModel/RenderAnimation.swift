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
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Key paths + values

/// The animatable property a record drives. Mirrors `animation.RenderAnimationKeyPath`.
package enum RenderAnimationKeyPath: Hashable, Sendable {
    case positionX
    case positionY
    case opacity
    /// Complete producer-authored 4×4 transform. Kept distinct from the
    /// component slots used by compositor-owned effects so a view transform is
    /// replaced atomically.
    case transform
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
    case boundsWidth
    case boundsHeight
    case scrollOffsetX
    case scrollOffsetY
    /// Compound rect of (left, top, right, bottom). Drives `position` and
    /// `bounds` overrides together as one retargetable record.
    case frame

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

package typealias AnimationSlotKey = RenderAnimationKeyPath

/// Tagged value returned by an animation step. Frame-typed animations return
/// `.frame`; everything else `.scalar`. Mirrors `animation.AnimationValue`.
package enum AnimationValue: Equatable, Sendable {
    case scalar(Float)
    case frame(Frame)
    case transform(M44)

    var scalarOrZero: Float {
        switch self {
        case .scalar(let s): return s
        case .frame, .transform: return 0
        }
    }
}

/// One step's evaluation: the interpolated value + whether the animation is
/// complete. Mirrors `animation.AnimationResult`.
package struct AnimationResult: Equatable, Sendable {
    package var value: AnimationValue
    package var done: Bool

    package init(value: AnimationValue, done: Bool) {
        self.value = value
        self.done = done
    }
}

/// Opaque animation identity (0 = none). Mirrors `animation.AnimationID`.
package struct AnimationID: Equatable, Hashable, Sendable {
    package var raw: UInt64 = 0
    package init(raw: UInt64 = 0) { self.raw = raw }
    package static let none = AnimationID(raw: 0)
}

/// Opaque completion token (0 = none). Mirrors `animation.CompletionToken`.
package struct CompletionToken: Equatable, Hashable, Sendable {
    package var raw: UInt64 = 0
    package init(raw: UInt64 = 0) { self.raw = raw }
    package static let none = CompletionToken(raw: 0)
}

// MARK: - Basic (timed bezier) animations

/// Timed cubic-bezier scalar interpolation. Mirrors `animation.BasicAnimation`.
package struct BasicAnimation: Equatable, Sendable {
    package var keyPath: RenderAnimationKeyPath
    package var fromValue: Float
    package var toValue: Float
    package var duration: Double = 0.25
    package var timingFunction: TimingFunction = .default
    package var beginTime: Double = 0
    package var elapsed: Double = 0

    package init(
        keyPath: RenderAnimationKeyPath, fromValue: Float, toValue: Float,
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

    package mutating func evaluateAt(_ presentTimeS: Double) -> AnimationResult {
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
package struct SpringAnimation: Equatable, Sendable {
    package var keyPath: RenderAnimationKeyPath
    package var fromValue: Float
    package var toValue: Float
    package var mass: Float = 1.0
    package var stiffness: Float = 100.0
    package var damping: Float = 10.0
    package var initialVelocity: Float = 0.0
    package var beginTime: Double = 0
    package var currentValueScalar: Float = 0
    package var velocity: Float = 0
    package var initialized: Bool = false

    package init(
        keyPath: RenderAnimationKeyPath, fromValue: Float, toValue: Float,
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

    mutating func evaluateAt(_ presentTimeS: Double, _ previousPresentTimeS: Double)
        -> AnimationResult
    {
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
package struct BasicFrameAnimation: Equatable, Sendable {
    package var keyPath: RenderAnimationKeyPath
    package var fromValue: Frame
    package var toValue: Frame
    package var duration: Double = 0.25
    package var timingFunction: TimingFunction = .default
    package var beginTime: Double = 0
    package var elapsed: Double = 0

    package init(
        keyPath: RenderAnimationKeyPath, fromValue: Frame, toValue: Frame,
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

    package mutating func evaluateAt(_ presentTimeS: Double) -> AnimationResult {
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

/// Timed interpolation of one complete 4×4 transform.
///
/// Matrix interpolation deliberately preserves arbitrary affine, perspective,
/// reflection, and shear values. Higher-level component animations continue to
/// use their dedicated slots when decomposition semantics are required.
package struct BasicTransformAnimation: Equatable, Sendable {
    package var keyPath: RenderAnimationKeyPath
    package var fromValue: M44
    package var toValue: M44
    package var duration: Double = 0.25
    package var timingFunction: TimingFunction = .default
    package var beginTime: Double = 0
    package var elapsed: Double = 0

    package init(
        keyPath: RenderAnimationKeyPath = .transform,
        fromValue: M44,
        toValue: M44,
        duration: Double = 0.25,
        timingFunction: TimingFunction = .default,
        beginTime: Double = 0
    ) {
        self.keyPath = keyPath
        self.fromValue = fromValue
        self.toValue = toValue
        self.duration = duration
        self.timingFunction = timingFunction
        self.beginTime = beginTime
    }

    package mutating func evaluateAt(_ presentTimeS: Double) -> AnimationResult {
        let elapsedS = max(0, presentTimeS - beginTime)
        elapsed = elapsedS
        return evaluateElapsed(elapsedS)
    }

    func evaluateElapsed(_ elapsedS: Double) -> AnimationResult {
        let t: Float = duration > 0 ? Float(min(elapsedS / duration, 1)) : 1
        let eased = timingFunction.evaluate(t)
        return AnimationResult(
            value: .transform(Self.interpolate(fromValue, toValue, eased)),
            done: t >= 1
        )
    }

    var currentValue: AnimationValue {
        let t: Float = duration > 0 ? Float(min(elapsed / duration, 1)) : 1
        return .transform(
            Self.interpolate(
                fromValue,
                toValue,
                timingFunction.evaluate(t)
            ))
    }

    private static func interpolate(_ from: M44, _ to: M44, _ t: Float) -> M44 {
        M44(
            m: zip(from.m, to.m).map { start, end in
                start + (end - start) * t
            })
    }
}

/// Spring interpolation for a complete 4×4 transform. Each matrix component
/// follows the same oscillator and the record settles only when every component
/// has converged.
package struct SpringTransformAnimation: Equatable, Sendable {
    package var keyPath: RenderAnimationKeyPath
    package var fromValue: M44
    package var toValue: M44
    package var mass: Float = 1
    package var stiffness: Float = 100
    package var damping: Float = 10
    package var beginTime: Double = 0
    package var currentValue: M44
    package var velocity: [Float]
    package var initialized: Bool = false

    package init(
        keyPath: RenderAnimationKeyPath = .transform,
        fromValue: M44,
        toValue: M44,
        mass: Float = 1,
        stiffness: Float = 100,
        damping: Float = 10,
        beginTime: Double = 0
    ) {
        self.keyPath = keyPath
        self.fromValue = fromValue
        self.toValue = toValue
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
        self.beginTime = beginTime
        self.currentValue = fromValue
        self.velocity = Array(repeating: 0, count: 16)
    }

    mutating func evaluateAt(
        _ presentTimeS: Double,
        _ previousPresentTimeS: Double
    ) -> AnimationResult {
        if !initialized {
            currentValue = fromValue
            velocity = Array(repeating: 0, count: 16)
            initialized = true
        }
        guard presentTimeS > beginTime else {
            return AnimationResult(value: .transform(currentValue), done: false)
        }

        let startS =
            previousPresentTimeS > beginTime
            ? previousPresentTimeS
            : beginTime
        let dt = Float(min(max(0, presentTimeS - startS), 0.05))
        let w0 = (stiffness / mass).squareRoot()
        let zeta = damping / (2 * (stiffness * mass).squareRoot())
        var next = currentValue.m
        var allSettled = true

        for index in next.indices {
            let displacement = currentValue.m[index] - toValue.m[index]
            let oldVelocity = velocity[index]
            let newDisplacement: Float
            let newVelocity: Float
            if zeta >= 1 {
                let decay = expf(-w0 * zeta * dt)
                let c1 = displacement
                let c2 = oldVelocity + w0 * zeta * displacement
                newDisplacement = (c1 + c2 * dt) * decay
                newVelocity =
                    (c2 - w0 * zeta * (c1 + c2 * dt)) * decay
            } else {
                let wd = w0 * (1 - zeta * zeta).squareRoot()
                let decay = expf(-w0 * zeta * dt)
                let cosine = cosf(wd * dt)
                let sine = sinf(wd * dt)
                newDisplacement =
                    decay
                    * (displacement * cosine + ((oldVelocity + w0 * zeta * displacement) / wd)
                        * sine)
                newVelocity =
                    decay
                    * (oldVelocity * cosine
                        - ((oldVelocity * w0 * zeta + displacement * w0 * w0) / wd) * sine)
            }
            next[index] = newDisplacement + toValue.m[index]
            velocity[index] = newVelocity
            let travel = abs(toValue.m[index] - fromValue.m[index])
            let threshold = max(0.0001, travel * 0.005)
            allSettled =
                allSettled && abs(newDisplacement) < threshold && abs(newVelocity) < threshold
        }

        currentValue = allSettled ? toValue : M44(m: next)
        if allSettled {
            velocity = Array(repeating: 0, count: 16)
        }
        return AnimationResult(value: .transform(currentValue), done: allSettled)
    }
}

/// Compound-frame counterpart of `SpringAnimation`: each edge runs an
/// independent oscillator with shared spring parameters and a shared settle
/// decision. Mirrors `animation.SpringFrameAnimation`.
package struct SpringFrameAnimation: Equatable, Sendable {
    package var keyPath: RenderAnimationKeyPath
    package var fromValue: Frame
    package var toValue: Frame
    package var mass: Float = 1.0
    package var stiffness: Float = 784.0
    package var damping: Float = 56.0
    package var initialVelocity: Frame = Frame(left: 0, top: 0, right: 0, bottom: 0)
    package var beginTime: Double = 0
    package var currentValueFrame: Frame = Frame(left: 0, top: 0, right: 0, bottom: 0)
    package var velocity: Frame = Frame(left: 0, top: 0, right: 0, bottom: 0)
    package var initialized: Bool = false

    package init(
        keyPath: RenderAnimationKeyPath, fromValue: Frame, toValue: Frame,
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

    static func stepEdge(_ x: Float, _ v: Float, _ w0: Float, _ zeta: Float, _ dtF: Float) -> (
        x: Float, v: Float
    ) {
        if zeta >= 1.0 {
            let expTerm = expf(-w0 * zeta * dtF)
            let c1 = x
            let c2 = v + w0 * zeta * x
            return (
                x: (c1 + c2 * dtF) * expTerm,
                v: (c2 - w0 * zeta * (c1 + c2 * dtF)) * expTerm
            )
        } else {
            let wd = w0 * (1.0 - zeta * zeta).squareRoot()
            let expTerm = expf(-w0 * zeta * dtF)
            let cosTerm = cosf(wd * dtF)
            let sinTerm = sinf(wd * dtF)
            return (
                x: expTerm * (x * cosTerm + ((v + w0 * zeta * x) / wd) * sinTerm),
                v: expTerm * ((v * cosTerm) - ((v * w0 * zeta + x * w0 * w0) / wd) * sinTerm)
            )
        }
    }

    package mutating func step(_ dt: Double) -> AnimationResult {
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
        let sr = Self.stepEdge(
            currentValueFrame.right - toValue.right, velocity.right, w0, zeta, dtF)
        let sb = Self.stepEdge(
            currentValueFrame.bottom - toValue.bottom, velocity.bottom, w0, zeta, dtF)

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
            abs(sl.x) < threshold && abs(st.x) < threshold && abs(sr.x) < threshold
            && abs(sb.x) < threshold && abs(sl.v) < threshold && abs(st.v) < threshold
            && abs(sr.v) < threshold && abs(sb.v) < threshold

        if settled {
            currentValueFrame = toValue
            velocity = Frame(left: 0, top: 0, right: 0, bottom: 0)
        }
        return AnimationResult(value: .frame(currentValueFrame), done: settled)
    }

    mutating func evaluateAt(_ presentTimeS: Double, _ previousPresentTimeS: Double)
        -> AnimationResult
    {
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
package enum Animation: Equatable, Sendable {
    case basic(BasicAnimation)
    case spring(SpringAnimation)
    case basicFrame(BasicFrameAnimation)
    case springFrame(SpringFrameAnimation)
    case basicTransform(BasicTransformAnimation)
    case springTransform(SpringTransformAnimation)

    package var keyPath: RenderAnimationKeyPath {
        switch self {
        case .basic(let a): return a.keyPath
        case .spring(let a): return a.keyPath
        case .basicFrame(let a): return a.keyPath
        case .springFrame(let a): return a.keyPath
        case .basicTransform(let a): return a.keyPath
        case .springTransform(let a): return a.keyPath
        }
    }

    package mutating func evaluateAt(_ presentTimeS: Double, _ previousPresentTimeS: Double)
        -> AnimationResult
    {
        switch self {
        case .basic(var a):
            let r = a.evaluateAt(presentTimeS)
            self = .basic(a)
            return r
        case .basicFrame(var a):
            let r = a.evaluateAt(presentTimeS)
            self = .basicFrame(a)
            return r
        case .spring(var a):
            let r = a.evaluateAt(presentTimeS, previousPresentTimeS)
            self = .spring(a)
            return r
        case .springFrame(var a):
            let r = a.evaluateAt(presentTimeS, previousPresentTimeS)
            self = .springFrame(a)
            return r
        case .basicTransform(var a):
            let r = a.evaluateAt(presentTimeS)
            self = .basicTransform(a)
            return r
        case .springTransform(var a):
            let r = a.evaluateAt(presentTimeS, previousPresentTimeS)
            self = .springTransform(a)
            return r
        }
    }

    package mutating func setBeginTime(_ beginTimeS: Double) {
        switch self {
        case .basic(var a):
            a.beginTime = beginTimeS
            self = .basic(a)
        case .spring(var a):
            a.beginTime = beginTimeS
            self = .spring(a)
        case .basicFrame(var a):
            a.beginTime = beginTimeS
            self = .basicFrame(a)
        case .springFrame(var a):
            a.beginTime = beginTimeS
            self = .springFrame(a)
        case .basicTransform(var a):
            a.beginTime = beginTimeS
            self = .basicTransform(a)
        case .springTransform(var a):
            a.beginTime = beginTimeS
            self = .springTransform(a)
        }
    }

    var finalValue: AnimationValue {
        switch self {
        case .basic(let a): return .scalar(a.toValue)
        case .spring(let a): return .scalar(a.toValue)
        case .basicFrame(let a): return .frame(a.toValue)
        case .springFrame(let a): return .frame(a.toValue)
        case .basicTransform(let a): return .transform(a.toValue)
        case .springTransform(let a): return .transform(a.toValue)
        }
    }

    var initialValue: AnimationValue {
        switch self {
        case .basic(let a): return .scalar(a.fromValue)
        case .spring(let a): return .scalar(a.fromValue)
        case .basicFrame(let a): return .frame(a.fromValue)
        case .springFrame(let a): return .frame(a.fromValue)
        case .basicTransform(let a): return .transform(a.fromValue)
        case .springTransform(let a): return .transform(a.fromValue)
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
        case .basicTransform(let a): return a.currentValue
        case .springTransform(let a): return .transform(a.currentValue)
        }
    }
}

// MARK: - Records + events

/// One in-flight animation bound to a layer slot. Mirrors
/// `animation.AnimationRecord`.
package struct AnimationRecord: Equatable, Sendable {
    package var id: AnimationID
    package var layerId: UInt64
    package var keyPath: RenderAnimationKeyPath
    package var slotKey: AnimationSlotKey
    package var completionToken: CompletionToken
    package var transactionId: UInt64
    /// A zero presentation timestamp defers the animation start until the
    /// renderer's first predicted-presentation tick.
    package var beginTimePending: Bool
    package var animation: Animation

    package init(
        id: AnimationID, layerId: UInt64, animation: Animation,
        completionToken: CompletionToken = .none, transactionId: UInt64 = 0,
        slotKey: AnimationSlotKey? = nil,
        beginTimePending: Bool = false
    ) {
        let keyPath = animation.keyPath
        self.id = id
        self.layerId = layerId
        self.keyPath = keyPath
        self.slotKey = slotKey ?? keyPath
        self.completionToken = completionToken
        self.transactionId = transactionId
        self.beginTimePending = beginTimePending
        self.animation = animation
    }
}

/// Why an animation stopped. Mirrors `animation.AnimationStopReason`.
package enum AnimationStopReason: Equatable, Sendable {
    case completed
    case replaced
    case removed
    case layerRemoved
    case targetMissing
    case cancelledBeforeStart
}

/// Lifecycle event emitted by the engine for transaction-completion matching.
/// Mirrors `animation.AnimationEvent`.
package enum AnimationEvent: Equatable, Sendable {
    case started(
        animationId: AnimationID, layerId: UInt64, keyPath: RenderAnimationKeyPath,
        completionToken: CompletionToken, transactionId: UInt64)
    case stopped(
        animationId: AnimationID, layerId: UInt64, keyPath: RenderAnimationKeyPath,
        completionToken: CompletionToken, transactionId: UInt64,
        finished: Bool, reason: AnimationStopReason)
}

/// Renderer-side request to remove one property animation.
package struct AnimationRemoval: Equatable, Sendable {
    package var layerId: UInt64
    package var keyPath: RenderAnimationKeyPath

    package init(layerId: UInt64, keyPath: RenderAnimationKeyPath) {
        self.layerId = layerId
        self.keyPath = keyPath
    }
}

package enum PresentationCompletionOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case superseded
    case failed
}

package struct PresentationCompletionEvent: Equatable, Sendable {
    package var token: UInt64
    package var outcome: PresentationCompletionOutcome

    package init(token: UInt64, outcome: PresentationCompletionOutcome) {
        self.token = token
        self.outcome = outcome
    }
}

// MARK: - Per-layer mutation (write / commit / clear / rebuild)

extension Layer {
    /// Add or replace (velocity-preserving) a record on its slot. Mirrors
    /// `addAnimationToLayer`.
    mutating func addAnimation(_ record: AnimationRecord, events: inout [AnimationEvent]) {
        for i in animations.indices where animations[i].slotKey == record.slotKey {
            var next = record
            copyVelocity(from: animations[i].animation, into: &next.animation)
            events.append(
                .stopped(
                    animationId: animations[i].id, layerId: animations[i].layerId,
                    keyPath: animations[i].keyPath, completionToken: animations[i].completionToken,
                    transactionId: animations[i].transactionId, finished: false, reason: .replaced))
            animations[i] = next
            events.append(
                .started(
                    animationId: next.id, layerId: next.layerId, keyPath: next.keyPath,
                    completionToken: next.completionToken, transactionId: next.transactionId))
            return
        }
        animations.append(record)
        events.append(
            .started(
                animationId: record.id, layerId: record.layerId, keyPath: record.keyPath,
                completionToken: record.completionToken, transactionId: record.transactionId))
    }

    mutating func removeAnimation(
        for keyPath: RenderAnimationKeyPath,
        reason: AnimationStopReason = .removed,
        events: inout [AnimationEvent]
    ) {
        var removedTransform = false
        var index = animations.count
        while index > 0 {
            index -= 1
            guard animations[index].slotKey == keyPath else { continue }
            let record = animations.remove(at: index)
            removedTransform = removedTransform || record.keyPath.isTransformComponent
            events.append(
                .stopped(
                    animationId: record.id,
                    layerId: record.layerId,
                    keyPath: record.keyPath,
                    completionToken: record.completionToken,
                    transactionId: record.transactionId,
                    finished: false,
                    reason: reason
                ))
        }
        if removedTransform {
            rebuildTransformOverride()
        } else {
            clearOverrideField(keyPath)
        }
    }

    /// Seed the layer's override to the record's initial value (so a sample
    /// before the first tick already shows the animation's start). Mirrors
    /// `seedAnimationStartValueOnLayer`.
    mutating func seedAnimationStartValue(_ record: AnimationRecord) {
        if record.keyPath.isTransformComponent {
            rebuildTransformOverride()
        } else {
            writeAnimatedField(record.keyPath, record.animation.initialValue)
        }
    }

    /// Tick every record on this layer to `presentTimeS`, applying results and
    /// firing completion events. Returns true when any record is still active.
    /// Mirrors `tickLayerToPresentTimeAndApplyWithSink`.
    mutating func tickAnimations(
        previousPresentTimeS: Double, presentTimeS: Double,
        events: inout [AnimationEvent]
    ) -> Bool {
        if animations.isEmpty { return false }

        var anyActive = false
        var transformTouched = false
        var i = 0
        while i < animations.count {
            if animations[i].beginTimePending {
                animations[i].animation.setBeginTime(presentTimeS)
                animations[i].beginTimePending = false
            }
            let result = animations[i].animation.evaluateAt(presentTimeS, previousPresentTimeS)
            let keyPath = animations[i].keyPath
            let isTransform = keyPath.isTransformComponent
            if result.done {
                let record = animations[i]
                commitModelField(keyPath, record.animation.finalValue)
                if isTransform {
                    transformTouched = true
                } else {
                    clearOverrideField(keyPath)
                }
                animations.swapAt(i, animations.count - 1)
                animations.removeLast()
                events.append(
                    .stopped(
                        animationId: record.id, layerId: record.layerId, keyPath: record.keyPath,
                        completionToken: record.completionToken,
                        transactionId: record.transactionId,
                        finished: true, reason: .completed))
            } else {
                if isTransform {
                    transformTouched = true
                } else {
                    writeAnimatedField(keyPath, result.value)
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
        _ keyPath: RenderAnimationKeyPath, _ value: AnimationValue
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
        case .transform:
            guard case .transform(let transform) = value else { break }
            var ov = presentation.override_ ?? PresentationOverride()
            ov.transform = transform
            presentation.override_ = ov
        case .boundsWidth:
            var ov = presentation.override_ ?? PresentationOverride()
            let current = ov.bounds ?? model.properties.bounds
            ov.bounds = Bounds(w: value.scalarOrZero, h: current.h)
            presentation.override_ = ov
        case .boundsHeight:
            var ov = presentation.override_ ?? PresentationOverride()
            let current = ov.bounds ?? model.properties.bounds
            ov.bounds = Bounds(w: current.w, h: value.scalarOrZero)
            presentation.override_ = ov
        case .scrollOffsetX:
            var ov = presentation.override_ ?? PresentationOverride()
            let current = ov.scrollOffset ?? model.properties.scrollOffset
            ov.scrollOffset = Point2D(x: value.scalarOrZero, y: current.y)
            presentation.override_ = ov
        case .scrollOffsetY:
            var ov = presentation.override_ ?? PresentationOverride()
            let current = ov.scrollOffset ?? model.properties.scrollOffset
            ov.scrollOffset = Point2D(x: current.x, y: value.scalarOrZero)
            presentation.override_ = ov
        case .frame:
            if case .frame(let f) = value {
                var ov = presentation.override_ ?? PresentationOverride()
                ov.position = Point2D(x: f.left, y: f.top)
                ov.bounds = Bounds(w: f.right - f.left, h: f.bottom - f.top)
                presentation.override_ = ov
            }
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
        _ keyPath: RenderAnimationKeyPath, _ value: AnimationValue
    ) {
        switch keyPath {
        case .positionX: model.properties.position.x = value.scalarOrZero
        case .positionY: model.properties.position.y = value.scalarOrZero
        case .anchorPointX: model.properties.anchorPoint.x = value.scalarOrZero
        case .anchorPointY: model.properties.anchorPoint.y = value.scalarOrZero
        case .opacity: model.properties.opacity = value.scalarOrZero
        case .transform:
            if case .transform(let transform) = value {
                model.properties.transform = transform
            }
        case .boundsWidth: model.properties.bounds.w = value.scalarOrZero
        case .boundsHeight: model.properties.bounds.h = value.scalarOrZero
        case .scrollOffsetX: model.properties.scrollOffset.x = value.scalarOrZero
        case .scrollOffsetY: model.properties.scrollOffset.y = value.scalarOrZero
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
        case .cornerRadius:
            // Commit the final radius uniformly to all four corners. Any prior
            // per-corner asymmetry is lost — the animation is scalar-uniform.
            let r = value.scalarOrZero
            var vs = model.visualStyle ?? VisualStyle(cornerRadii: (r, r, r, r))
            vs.cornerRadii = (r, r, r, r)
            model.visualStyle = vs
            model.visualRevision &+= 1
            model.compositeRevision &+= 1
        case .transformScaleX, .transformScaleY, .transformScaleZ,
            .transformRotationX, .transformRotationY, .transformRotationZ,
            .transformTranslationX, .transformTranslationY, .transformTranslationZ:
            break
        }
    }

    /// Clear one override field on completion, collapsing the override to nil
    /// when fully empty. Mirrors `clearOverrideField`.
    private mutating func clearOverrideField(_ keyPath: RenderAnimationKeyPath) {
        guard var ov = presentation.override_ else { return }
        switch keyPath {
        case .positionX, .positionY: ov.position = nil
        case .anchorPointX, .anchorPointY: ov.anchorPoint = nil
        case .opacity: ov.opacity = nil
        case .transform: ov.transform = nil
        case .boundsWidth, .boundsHeight: ov.bounds = nil
        case .scrollOffsetX, .scrollOffsetY: ov.scrollOffset = nil
        case .frame:
            ov.position = nil
            ov.bounds = nil
        case .cornerRadius: ov.cornerRadiusUniform = nil
        case .transformScaleX, .transformScaleY, .transformScaleZ,
            .transformRotationX, .transformRotationY, .transformRotationZ,
            .transformTranslationX, .transformTranslationY, .transformTranslationZ:
            break
        }
        if ov.transform == nil && ov.opacity == nil && ov.position == nil && ov.bounds == nil
            && ov.anchorPoint == nil && ov.scrollOffset == nil && ov.cornerRadiusUniform == nil
        {
            presentation.override_ = nil
        } else {
            presentation.override_ = ov
        }
    }

    /// Rebuild the combined transform override from all transform-component
    /// animations on this layer. Mirrors `rebuildTransformOverride`.
    private mutating func rebuildTransformOverride() {
        var tx: Float = 0
        var ty: Float = 0
        var tz: Float = 0
        var sx: Float = 1
        var sy: Float = 1
        var sz: Float = 1
        var rx: Float = 0
        var ry: Float = 0
        var rz: Float = 0
        var hasTransform = false

        for record in animations {
            let av = record.animation.currentValue
            guard case .scalar(let value) = av else { continue }
            switch record.keyPath {
            case .transformScaleX:
                sx = value
                hasTransform = true
            case .transformScaleY:
                sy = value
                hasTransform = true
            case .transformScaleZ:
                sz = value
                hasTransform = true
            case .transformRotationX:
                rx = value
                hasTransform = true
            case .transformRotationY:
                ry = value
                hasTransform = true
            case .transformRotationZ:
                rz = value
                hasTransform = true
            case .transformTranslationX:
                tx = value
                hasTransform = true
            case .transformTranslationY:
                ty = value
                hasTransform = true
            case .transformTranslationZ:
                tz = value
                hasTransform = true
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
        if ov.opacity == nil && ov.position == nil && ov.bounds == nil && ov.anchorPoint == nil
            && ov.scrollOffset == nil && ov.cornerRadiusUniform == nil
        {
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
    case .springTransform(var newTransform):
        if case .springTransform(let old) = existing, old.initialized {
            newTransform.velocity = old.velocity
            next = .springTransform(newTransform)
        }
    case .basic, .basicFrame, .basicTransform:
        break
    }
}
