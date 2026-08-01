import NucleusTypes
import Testing

@Suite struct SharedValueTests {
    @Test func colorNormalizesEveryConstructionPath() {
        let color = Color(-1, .nan, .infinity, 2)
        #expect(color == Color(0, 0, 0, 1))
        #expect(Color(0.25, 0.5, 0.75, 1).opacity(-2) == Color(0.25, 0.5, 0.75, 0))
    }

    @Test func shadowRejectsInvalidScalarState() {
        let shadow = Shadow(
            offsetX: .nan,
            offsetY: .infinity,
            blurRadius: -4,
            cornerRadius: .nan,
            opacity: 5,
            color: Color(0.1, 0.2, 0.3, 0.4)
        )
        #expect(shadow.offsetX == 0)
        #expect(shadow.offsetY == 0)
        #expect(shadow.blurRadius == 0)
        #expect(shadow.cornerRadius == 0)
        #expect(shadow.opacity == 1)
        #expect(shadow.color == Color(0.1, 0.2, 0.3, 0.4))
        #expect(Shadow.none == Shadow())

        let replaced = Shadow(offsetX: 2, offsetY: 4, blurRadius: 6, opacity: 0.5)
            .withOffset(x: .nan, y: .infinity)
            .withBlurRadius(-1)
            .withOpacity(.nan)
        #expect(replaced.offsetX == 0)
        #expect(replaced.offsetY == 0)
        #expect(replaced.blurRadius == 0)
        #expect(replaced.opacity == 0)
        #expect(replaced.color == Color(0, 0, 0, 1))
    }

    @Test func rectangleSemanticsIgnoreInvalidAndEmptyInputs() {
        var rect = Rect(x: 10, y: 20, width: 30, height: 40)
        #expect(rect.insetBy(dx: 100, dy: 100) == Rect(x: 25, y: 40, width: 0, height: 0))
        #expect(rect.union(Rect(x: .nan, y: 0, width: 10, height: 10)) == rect)
        #expect(
            Rect.zero.union(Rect(x: 4, y: 5, width: 6, height: 7))
                == Rect(x: 4, y: 5, width: 6, height: 7))
        #expect(rect.contains(Point(x: 10, y: 20)))
        #expect(!rect.contains(Point(x: 40, y: 60)))
        #expect(Rect(x: 0, y: 0, width: -1, height: 2).isEmpty)

        rect.origin = Point(x: 1, y: 2)
        rect.size = Size(width: 3, height: 4)
        #expect(rect == Rect(origin: Point(x: 1, y: 2), size: Size(width: 3, height: 4)))
    }

    @Test func transformCompositionUsesColumnMajorApplicationOrder() {
        let translation = Transform.translation(x: 10, y: 20, z: 30)
        let scale = Transform.scale(x: 2, y: 3, z: 4)
        let composed = translation.concatenating(scale)

        #expect(composed.m00 == 2)
        #expect(composed.m11 == 3)
        #expect(composed.m22 == 4)
        #expect(composed.m30 == 10)
        #expect(composed.m31 == 20)
        #expect(composed.m32 == 30)
        #expect(
            composed.affineProjection
                == Transform.AffineProjection(a: 2, b: 0, c: 0, d: 3, tx: 10, ty: 20))
        #expect(composed.concatenating(.identity) == composed)
        #expect(composed.isFinite)
        #expect(!Transform.translation(x: .infinity, y: 0).isFinite)
    }

    @Test func imageHandleIdentityIsHashable() {
        let first = ImageHandle(id: 42)
        let same = ImageHandle(id: 42)
        let other = ImageHandle(id: 43)
        #expect(first == same)
        #expect(first != other)
        #expect(Set([first, same, other]).count == 2)
    }

    @Test func visualEffectUsesSemanticDefaultsAndNormalizesGeometry() {
        #expect(
            VisualEffect()
                == VisualEffect(
                    material: .none,
                    blendingMode: .behindWindow,
                    state: .active,
                    appearance: .auto))

        let effect = VisualEffect(
            cornerRadius: .nan,
            opacity: 2,
            shapeRect: SIMD4<Float>(.nan, .infinity, -3, 4),
            shapeRadius: SIMD4<Float>(-1, 2, .nan, .infinity))
        #expect(effect.cornerRadius == 0)
        #expect(effect.opacity == 1)
        #expect(effect.shapeRect == SIMD4<Float>(0, 0, 0, 4))
        #expect(effect.shapeRadius == SIMD4<Float>(0, 2, 0, 0))
        #expect(effect.withTint(Color(2, -1, .nan, 0.5)).tint == Color(1, 0, 0, 0.5))
    }
}
