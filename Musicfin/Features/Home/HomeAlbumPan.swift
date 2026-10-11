import UIKit
import UIKit.UIGestureRecognizerSubclass

final class HomeAlbumPan: UIPanGestureRecognizer {
    private var start: CGPoint?
    private var latched = false
    private(set) weak var scroll: UIScrollView?
    private(set) var startedAtTop = true
    private(set) var displacement = CGPoint.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        latchIfNeeded()
        if let touch = touches.first, let view { start = touch.location(in: view) }
    }

    func latchIfNeeded() {
        guard !latched, let view, numberOfTouches > 0 else { return }
        latched = true
        var touched = view.hitTest(location(in: view), with: nil)
        while let current = touched, current !== view {
            if let candidate = current as? UIScrollView {
                scroll = candidate
                startedAtTop = candidate.contentOffset.y <= -candidate.adjustedContentInset.top + 0.5
                break
            }
            touched = current.superview
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let touch = touches.first, let view else {
            state = .failed
            return
        }
        let point = touch.location(in: view)
        displacement = CGPoint(x: point.x - start.x, y: point.y - start.y)
        // 最初の数 pt の横ぶれで判定せず、List の top は接触開始時の値に固定する。
        if state == .possible {
            if hypot(displacement.x, displacement.y) < 10 { return }
            // 終了操作にならない接触は先に失敗させ、List に同じ指の動きを渡す。
            if !startedAtTop || displacement.y <= abs(displacement.x) {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, let touch = touches.first, let view {
            let point = touch.location(in: view)
            displacement = CGPoint(x: point.x - start.x, y: point.y - start.y)
        }
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        start = nil
        scroll = nil
        latched = false
        startedAtTop = true
        displacement = .zero
    }
}
