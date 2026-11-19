import ApplicationServices
import Foundation

package enum Scrolling {
    package static func pages(_ requested: Int) -> Int { max(-10, min(10, requested)) }

    package static func distance(pages: Int, viewport: CGRect) -> Int32 {
        let distance = CGFloat(self.pages(pages)) * viewport.height
        return Int32(clamping: Int(distance.rounded()))
    }

    package enum Movement: Equatable {
        case points(CGFloat)
        case fraction(Double)
        case still
        case unknown

        var report: String {
            switch self {
            case .points(let delta):
                return "Moved \(delta > 0 ? "down" : "up") \(Int(abs(delta).rounded())) points."
            case .fraction(let delta):
                let percent = (abs(delta) * 100).formatted(.number.precision(.fractionLength(0...2)))
                return "Moved \(delta > 0 ? "down" : "up") \(percent)% of the scroll range; the distance in points could not be measured."
            case .still: return "No scroll movement was observed. The view may be at its limit or may have ignored the event."
            case .unknown: return "The scroll distance could not be measured in this view."
            }
        }
    }

    /// Compare the same content elements, not whichever happen to be visible afterwards. If only the scrollbar
    /// reports a change, that is a fraction of the scroll range, not a fraction of a page.
    package static func movement(before: [CGRect], after: [CGRect?], oldValue: Double?, newValue: Double?) -> Movement {
        let deltas = zip(before, after).compactMap { old, new -> CGFloat? in
            guard let new, abs(old.height - new.height) < 1, abs(old.minX - new.minX) < 1,
                  abs(old.width - new.width) < 1, abs(old.minY - new.minY) >= 1 else { return nil }
            return old.minY - new.minY
        }
        let fraction = oldValue.flatMap { old in newValue.map { $0 - old } }
        let consistent = deltas.filter { d in
            guard let fraction, abs(fraction) >= 0.00001 else { return true }
            return d.sign == fraction.sign
        }
        // Ignore a disappearing element or one that relaid itself; prefer displacement corroborated by another anchor.
        if let delta = consistent.first(where: { d in consistent.filter { abs($0 - d) < 2 }.count >= 2 }) { return .points(delta) }
        if let fraction, abs(fraction) >= 0.00001 { return .fraction(fraction) }
        return fraction == nil ? .unknown : .still
    }

    static func area(containing element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard let candidate = current else { break }
            if AX.role(candidate) == "AXScrollArea" { return candidate }
            current = AX.parent(candidate)
        }
        return nil
    }

    /// Find a visible viewport, not the size of its document. A nested web scroller can be as big as its wrapper.
    static func area(in window: AXUIElement, frame: CGRect, at point: CGPoint? = nil) -> AXUIElement? {
        var queue = [(window, 0)]
        var best: (element: AXUIElement, size: CGFloat, depth: Int)?
        var visited = 0
        while visited < queue.count, visited < 800 {
            let (element, depth) = queue[visited]
            visited += 1
            let role = AX.role(element)
            if role == "AXScrollArea", let bounds = AX.frame(element) {
                let rect = bounds.intersection(frame)
                if rect.isEmpty || point.map({ !rect.contains($0) }) == true { continue }
                let size = rect.width * rect.height
                let betterSize = point == nil ? size > (best?.size ?? 0) : size < (best?.size ?? .infinity)
                if betterSize || (size == best?.size && depth > (best?.depth ?? 0)) { best = (element, size, depth) }
            }
            if depth < 25 { queue += AX.children(element).prefix(100).map { ($0, depth + 1) } }
        }
        return best?.element
    }

    struct Position {
        let bar: AXUIElement?
        let value: Double?
        let anchors: [(AXUIElement, CGRect)]

        init(area: AXUIElement?, viewport: CGRect) {
            bar = area.flatMap { AX.element($0, kAXVerticalScrollBarAttribute) }
            value = Self.value(of: bar)
            var anchors: [(AXUIElement, CGRect)] = []
            if let area {
                let contents = AX.children(area, kAXContentsAttribute)
                var queue = contents.isEmpty ? AX.children(area) : contents
                var visited = 0
                while visited < queue.count, visited < 80, anchors.count < 12 {
                    let child = queue[visited]
                    visited += 1
                    let role = AX.role(child)
                    if ["AXScrollBar", "AXScrollArea", "AXSplitter"].contains(role) { continue }
                    if let rect = AX.frame(child), rect.width > 1, rect.height > 1, rect.intersects(viewport), rect.height < viewport.height {
                        if !anchors.contains(where: { abs($0.1.minY - rect.minY) < 1 }) { anchors.append((child, rect)) }
                    }
                    queue += AX.children(child).prefix(40)
                }
            }
            self.anchors = anchors
        }

        private static func value(of bar: AXUIElement?) -> Double? {
            guard let bar, let value = (AX.value(bar, kAXValueAttribute) as? NSNumber)?.doubleValue,
                  (0...1).contains(value) else { return nil }
            return value
        }

        func movement() -> Movement {
            Scrolling.movement(before: anchors.map(\.1), after: anchors.map { AX.frame($0.0) }, oldValue: value, newValue: Self.value(of: bar))
        }

        func pageButton(pages: Int) -> AXUIElement? {
            guard let bar, let value, pages > 0 ? value < 1 : value > 0 else { return nil }
            let wanted = pages > 0 ? "AXIncrementPage" : "AXDecrementPage"
            return AX.children(bar).first { (AX.value($0, kAXSubroleAttribute) as? String) == wanted }
        }
    }
}
