import SwiftUI
import UIKit

struct HomeAlbumCanvas: UIViewControllerRepresentable {
    let session: HomeAlbumSession
    let presentation: HomeAlbumPresentation
    let interrupted: Bool
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @Environment(AlbumCatalog.self) private var catalog

    func makeUIViewController(context: Context) -> HomeAlbumCanvasController {
        let controller = HomeAlbumCanvasController(session: session, presentation: presentation)
        let artwork = controller.artwork
        let content = NavigationStack {
            AlbumDetailView(
                album: session.album, overlayArtworkHidden: artwork.hidden,
                overlayMarker: { [weak controller] in controller?.marker = $0 },
                overlayClose: { [weak controller] in controller?.close() }
            )
        }
        .tint(.pink)
        .environment(auth)
        .environment(library)
        .environment(player)
        .environment(catalog)
        controller.install(AnyView(content))
        return controller
    }

    func updateUIViewController(_ controller: HomeAlbumCanvasController, context: Context) {
        if interrupted { controller.restoreDrag() }
    }

    static func dismantleUIViewController(_ controller: HomeAlbumCanvasController, coordinator: ()) {
        controller.tearDown()
    }
}

final class HomeAlbumCanvasController: UIViewController, UIGestureRecognizerDelegate {
    private enum Phase: String {
        case preparing, opening, presented, dragging, restoring, closing, removed
    }

    let artwork: HomeAlbumArtwork
    private let session: HomeAlbumSession
    private let presentation: HomeAlbumPresentation
    private let content = UIView()
    private let hero = UIImageView()
    private let heroMask = CAShapeLayer()
    private var host: UIHostingController<AnyView>?
    weak var marker: UIView?
    private var phase = Phase.preparing
    private var operation = 0
    private var animator: UIViewPropertyAnimator?
    private var displayLink: CADisplayLink?
    private var displayTarget: HomeAlbumDisplayTarget?
    private var pan: HomeAlbumPan?
    private var destination = CGRect.zero
    private var destinationLive = false
    private var previousSize = CGSize.zero
    private var preparationFrames = 0
    private var sourceFloor: CGFloat = 0
    private var released: CGRect?
    private var frozenSource: CGRect?
    private var fallback: String?
    private var traceURL: URL?

    init(session: HomeAlbumSession, presentation: HomeAlbumPresentation) {
        artwork = HomeAlbumArtwork(hidden: session.image != nil)
        self.session = session
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(_ root: AnyView) { host = UIHostingController(rootView: root) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        content.backgroundColor = .black
        view.addSubview(content)
        if let host {
            addChild(host)
            content.addSubview(host.view)
            host.didMove(toParent: self)
        }
        hero.image = session.image
        hero.contentMode = .scaleAspectFill
        hero.clipsToBounds = true
        hero.layer.cornerRadius = 8
        hero.isUserInteractionEnabled = false
        hero.isAccessibilityElement = false
        view.addSubview(hero)
        content.alpha = 0
        // 開く操作が検証付きで完了するまで、固定中の終点に対する入力を受けない。
        content.isUserInteractionEnabled = false
        hero.alpha = 0
        let pan = HomeAlbumPan(target: self, action: #selector(drag(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        self.pan = pan
        let target = HomeAlbumDisplayTarget(owner: self)
        displayTarget = target
        let link = CADisplayLink(target: target, selector: #selector(HomeAlbumDisplayTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        NotificationCenter.default.addObserver(
            self, selector: #selector(interrupted), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(interrupted), name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil)
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["MUSICFIN_SHOT_DIR"] {
            traceURL = URL(fileURLWithPath: directory)
                .appendingPathComponent("album-overlay-\(session.generation)-\(UUID().uuidString).jsonl")
        }
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if previousSize != .zero, size != previousSize, phase != .preparing, phase != .removed {
            // 回転後に新しい終点へ飛ばさず、描画済みの姿勢を固定して退場する。
            close(forceFade: "resize")
            previousSize = size
            return
        }
        previousSize = size
        if phase == .closing || phase == .removed { return }
        content.bounds = CGRect(origin: .zero, size: size)
        if phase == .preparing || phase == .presented {
            content.center = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        host?.view.frame = content.bounds
    }

    fileprivate func tick() {
        guard phase != .removed, presentation.selection === session else { return }
        if phase == .preparing {
            host?.view.layoutIfNeeded()
            if let marker, marker.window != nil, marker.bounds.width > 0 {
                destination = marker.convert(marker.bounds, to: content)
                destinationLive = true
                open()
            } else {
                preparationFrames += 1
                if preparationFrames > 8 { open(fade: "missing-destination") }
            }
        } else if phase == .presented, let marker, let window = marker.window,
            window === view.window, marker.bounds.width > 0, marker.bounds.height > 0
        {
            destination = marker.convert(marker.bounds, to: content)
            destinationLive = true
            hero.frame = destination
            // 遅れて届いた寸法でも同じ画像を復帰させ、詳細側の画像には引き渡さない。
            hero.alpha = artwork.hidden ? 1 : 0
            clipHero()
        } else if phase == .presented {
            // 実在のマーカーが戻るまで、古い終点に画像を浮かせず、終了時もその姿勢から消す。
            destinationLive = false
            hero.alpha = 0
        } else if phase == .closing, let frozen = frozenSource {
            if let source = session.source.rect(in: view), Self.near(source, frozen) {
                // 同じ終点のまま進行を続ける。
            } else {
                // 追いかけ直さず、いま描かれている姿勢のまま明示的にフェードへ切り替える。
                freeze()
                fade(reason: "source-moved")
            }
        }
        trace()
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1
            && abs(a.height - b.height) <= 1
    }

    private func open(fade reason: String? = nil) {
        guard phase == .preparing else { return }
        var reason = reason
        let source = session.source.rect(in: view)
        if UIAccessibility.isReduceMotionEnabled { reason = "reduce-motion" }
        if session.image == nil { reason = "missing-image" }
        if source == nil { reason = "missing-source" }
        fallback = reason
        phase = .opening
        if reason == nil, let source {
            hero.frame = source
            hero.layer.cornerRadius = session.entry.hasPrefix("topPick.") ? 12 : 8
            hero.alpha = 1
            applyContentPose(art: source)
        } else {
            hero.frame = destination
            hero.alpha = 0
        }
        animate(
            duration: 0.38,
            changes: {
                self.hero.frame = self.destination
                self.hero.layer.cornerRadius = 8
                self.hero.alpha = self.artwork.hidden && self.destination.width > 0 ? 1 : 0
                self.content.transform = .identity
                self.content.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
                self.content.alpha = 1
            },
            completion: {
                // 入力を許す前に実マーカーの配置へ合わせ、操作開始時に画像が動かないようにする。
                self.host?.view.layoutIfNeeded()
                if let marker = self.marker, marker.window === self.view.window, marker.bounds.width > 0 {
                    self.destination = marker.convert(marker.bounds, to: self.content)
                    self.destinationLive = true
                    self.hero.frame = self.destination
                    self.hero.alpha = self.artwork.hidden ? 1 : 0
                }
                self.phase = .presented
                self.content.isUserInteractionEnabled = true
                self.clipHero()
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            })
    }

    private func applyContentPose(art: CGRect) {
        guard destination.width > 0 else { return }
        let scale = art.width / destination.width
        content.transform = CGAffineTransform(scaleX: scale, y: scale)
        content.center = CGPoint(
            x: art.midX + scale * (content.bounds.midX - destination.midX),
            y: art.midY + scale * (content.bounds.midY - destination.midY))
    }

    private func clipHero() {
        guard let marker else { return }
        var ancestor = marker.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView {
                var viewport = scroll.convert(scroll.bounds, to: hero)
                // 固定されたバーの下へ潜った画像が、戻る操作の上に描かれないようにする。
                viewport.origin.y += scroll.adjustedContentInset.top
                viewport.size.height = max(
                    0, viewport.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom)
                heroMask.path = UIBezierPath(rect: viewport).cgPath
                hero.layer.mask = heroMask
                return
            }
            ancestor = current.superview
        }
    }

    func close(forceFade: String? = nil) {
        guard phase != .removed, phase != .closing || forceFade != nil else { return }
        freeze()
        released = hero.frame
        let source = session.source.rect(in: view)
        var reason = forceFade
        if UIAccessibility.isReduceMotionEnabled { reason = "reduce-motion" }
        if session.image == nil { reason = "missing-image" }
        if destination.width <= 0 || !destinationLive { reason = "missing-destination" }
        if source == nil { reason = "missing-source" }
        if let source, source.width > hero.frame.width + 0.5 { reason = "source-larger-than-release" }
        if !view.bounds.contains(hero.frame) { reason = "offscreen-destination" }
        if let mask = hero.layer.mask as? CAShapeLayer,
            let path = mask.path, !path.boundingBoxOfPath.contains(hero.bounds)
        {
            reason = "clipped-destination"
        }
        if reason == nil { hero.layer.mask = nil }
        guard reason == nil, let source else {
            fade(reason: reason ?? "missing-source")
            return
        }
        fallback = nil
        frozenSource = source
        phase = .closing
        content.isUserInteractionEnabled = false
        animate(
            duration: 0.38,
            changes: {
                self.hero.frame = source
                self.applyContentPose(art: source)
                self.hero.layer.cornerRadius = self.session.entry.hasPrefix("topPick.") ? 12 : 8
                self.content.alpha = 0
            },
            completion: { self.finish() })
    }

    private func fade(reason: String) {
        fallback = reason
        frozenSource = nil
        phase = .closing
        content.isUserInteractionEnabled = false
        animate(
            duration: 0.22,
            changes: {
                self.hero.alpha = 0
                self.content.alpha = 0
            },
            completion: { self.finish() })
    }

    private func finish() {
        phase = .removed
        trace()
        presentation.clear(session)
    }

    private func freeze() {
        // model の終点ではなく presentation を引き継ぎ、指を離した瞬間の大きさを保存する。
        let frame = hero.layer.presentation()?.frame ?? hero.frame
        let heroAlpha = hero.layer.presentation()?.opacity ?? Float(hero.alpha)
        let alpha = content.layer.presentation()?.opacity ?? Float(content.alpha)
        let transform = content.layer.presentation()?.affineTransform() ?? content.transform
        let position = content.layer.presentation()?.position ?? content.center
        operation += 1
        animator?.stopAnimation(true)
        animator = nil
        hero.frame = frame
        hero.alpha = CGFloat(heroAlpha)
        content.transform = transform
        content.center = position
        content.alpha = CGFloat(alpha)
    }

    private func animate(duration: TimeInterval, changes: @escaping () -> Void, completion: @escaping () -> Void) {
        operation += 1
        let token = operation
        // 臨界減衰で帰着幅を下回る反動を避け、同じ画像を一度だけ縮める。
        let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1, animations: changes)
        self.animator = animator
        animator.addCompletion { [weak self] position in
            guard let self, self.operation == token, position == .end,
                self.presentation.selection === self.session, self.phase != .removed
            else { return }
            self.animator = nil
            completion()
        }
        animator.startAnimation()
    }

    @objc private func drag(_ pan: HomeAlbumPan) {
        switch pan.state {
        case .began:
            guard phase == .presented else { return }
            phase = .dragging
            hero.layer.mask = nil
            sourceFloor = session.source.rect(in: view)?.width ?? 0
            content.isUserInteractionEnabled = false
            // 動きを減らす設定では画像を指に追従させず、しきい値の判定だけを残す。
            if !UIAccessibility.isReduceMotionEnabled { updateDrag(pan) }
        case .changed:
            if phase == .dragging, !UIAccessibility.isReduceMotionEnabled { updateDrag(pan) }
        case .ended:
            guard phase == .dragging else { return }
            if !UIAccessibility.isReduceMotionEnabled { updateDrag(pan) }
            let distance = pan.displacement.y
            if distance >= max(100, view.bounds.height * 0.18)
                || (distance > 50 && pan.velocity(in: view).y > 900)
            {
                close()
            } else {
                restoreDrag()
            }
        case .cancelled, .failed:
            restoreDrag()
        default:
            break
        }
    }

    private func updateDrag(_ pan: HomeAlbumPan) {
        let delta = pan.displacement
        let scale = max(
            min(1, sourceFloor / max(1, destination.width)), 1 - max(0, delta.y) / (view.bounds.height * 1.5))
        let frame = CGRect(
            x: destination.midX + delta.x - destination.width * scale / 2,
            y: destination.midY + max(0, delta.y) - destination.height * scale / 2,
            width: destination.width * scale, height: destination.height * scale)
        hero.frame = frame
        applyContentPose(art: frame)
    }

    @objc private func interrupted() { restoreDrag() }

    func restoreDrag() {
        guard phase == .dragging else { return }
        freeze()
        if UIAccessibility.isReduceMotionEnabled {
            // 拡大縮小のアニメーションは使わず、静止したまま元の姿勢へ戻す。
            hero.frame = destination
            hero.alpha = artwork.hidden && destinationLive ? 1 : 0
            content.transform = .identity
            content.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            content.alpha = 1
            phase = .presented
            content.isUserInteractionEnabled = true
            clipHero()
            return
        }
        phase = .restoring
        animate(
            duration: 0.3,
            changes: {
                self.hero.frame = self.destination
                self.hero.alpha = self.artwork.hidden ? 1 : 0
                self.content.transform = .identity
                self.content.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
                self.content.alpha = 1
            },
            completion: {
                self.phase = .presented
                self.content.isUserInteractionEnabled = true
                self.clipHero()
            })
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? HomeAlbumPan else { return false }
        return phase == .presented && pan.startedAtTop && pan.displacement.y > abs(pan.displacement.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard let pan = gestureRecognizer as? HomeAlbumPan else { return false }
        pan.latchIfNeeded()
        return phase == .presented && pan.startedAtTop && pan.scroll?.panGestureRecognizer === other
    }

    func tearDown() {
        guard phase != .removed || displayLink != nil else { return }
        phase = .removed
        operation += 1
        animator?.stopAnimation(true)
        animator = nil
        displayLink?.invalidate()
        displayLink = nil
        displayTarget = nil
        if let pan { view.removeGestureRecognizer(pan) }
        NotificationCenter.default.removeObserver(self)
        presentation.clear(session)
    }

    private func trace() {
        #if DEBUG
        guard let traceURL else { return }
        let frame = hero.layer.presentation()?.frame ?? hero.frame
        func rect(_ value: CGRect?) -> Any {
            guard let value else { return NSNull() }
            return [value.origin.x, value.origin.y, value.width, value.height]
        }
        let row: [String: Any] = [
            "time": CACurrentMediaTime(), "phase": phase.rawValue,
            "session": session.generation,
            "image": session.image.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "heroImage": hero.image.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "frame": rect(frame), "released": rect(released), "source": rect(frozenSource),
            "fallback": fallback ?? "none",
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: row) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: traceURL.path) {
            FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: traceURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
        #endif
    }
}

private final class HomeAlbumDisplayTarget: NSObject {
    weak var owner: HomeAlbumCanvasController?
    init(owner: HomeAlbumCanvasController) { self.owner = owner }
    @objc func tick() { owner?.tick() }
}
