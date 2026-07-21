extension View {
    public func convert(_ point: Point, from view: View?) -> Point {
        convertFromWindowSpace(view?.convertToWindowSpace(point) ?? point)
    }

    public func convert(_ point: Point, to view: View?) -> Point {
        view?.convert(point, from: self) ?? convertToWindowSpace(point)
    }

    public func convert(_ rect: Rect, from view: View?) -> Rect {
        View.boundingBox(rect.corners.map { convert($0, from: view) })
    }

    public func convert(_ rect: Rect, to view: View?) -> Rect {
        View.boundingBox(rect.corners.map { convert($0, to: view) })
    }

    static func boundingBox(_ points: [Point]) -> Rect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return Rect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY)
    }

    func convertFromParent(_ point: Point) -> Point {
        let ownFrame = frame
        var local = Point(
            x: point.x - ownFrame.origin.x,
            y: point.y - ownFrame.origin.y)
        if let inverse = transformAboutAnchor()?.inverted() {
            local = inverse.apply(local)
        }
        return Point(
            x: local.x + boundsOrigin.x,
            y: local.y + boundsOrigin.y)
    }

    func convertToParent(_ point: Point) -> Point {
        var local = Point(
            x: point.x - boundsOrigin.x,
            y: point.y - boundsOrigin.y)
        if let transform = transformAboutAnchor() {
            local = transform.apply(local)
        }
        return Point(
            x: local.x + frame.origin.x,
            y: local.y + frame.origin.y)
    }

    private func transformAboutAnchor() -> AffineTransform? {
        guard storedTransform != .identity else { return nil }
        let size = frame.size
        let anchorX = size.width * 0.5
        let anchorY = size.height * 0.5
        return AffineTransform.translation(x: anchorX, y: anchorY)
            .concatenating(storedTransform.affine2D)
            .concatenating(
                AffineTransform.translation(x: -anchorX, y: -anchorY))
    }

    private func convertToWindowSpace(_ point: Point) -> Point {
        var result = point
        var node: View? = self
        while let current = node {
            result = current.convertToParent(result)
            node = current.parentView
        }
        return result
    }

    private func convertFromWindowSpace(_ point: Point) -> Point {
        var chain: [View] = []
        var node: View? = self
        while let current = node {
            chain.append(current)
            node = current.parentView
        }
        var result = point
        for current in chain.reversed() {
            result = current.convertFromParent(result)
        }
        return result
    }

    @discardableResult
    public func dispatchEvent(_ event: Event) -> EventHandling {
        guard let target = hitTest(event.location) else { return .notHandled }
        let localInSelf = convertFromParent(event.location)
        let local = target.convert(localInSelf, from: self)
        return target.deliverEvent(event.relocated(to: local))
    }

    package func semanticHitTest(_ point: Point) -> View? {
        guard !isHidden, isHitTestingEnabled else { return nil }
        if let transform = transformAboutAnchor(),
           transform.inverted() == nil
        {
            return nil
        }
        let localPoint = convertFromParent(point)
        guard bounds.contains(localPoint) else { return nil }
        for child in childViews.reversed() {
            if let hit = child.hitTest(localPoint) {
                return hit
            }
        }
        return self
    }
}
