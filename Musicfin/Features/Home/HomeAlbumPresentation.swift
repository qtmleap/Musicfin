import Observation
import SwiftUI
import UIKit

@Observable
final class HomeAlbumPresentation {
    var selection: HomeAlbumSession?
    private(set) var generation = 0
    @ObservationIgnored private var sources: [String: HomeAlbumSourceBox] = [:]

    func source(for entry: String) -> HomeAlbumSourceBox {
        if let source = sources[entry] { return source }
        let source = HomeAlbumSourceBox()
        sources[entry] = source
        return source
    }

    func open(_ album: MediaItem, entry: String, source: HomeAlbumSourceBox) {
        generation += 1
        selection = HomeAlbumSession(
            generation: generation, album: album, entry: entry, source: source, image: source.image)
    }

    func clear(_ session: HomeAlbumSession? = nil) {
        // 選択が無いときの再呼び出しで世代だけ進めない。進めると遅れて届いた旧 session の後始末が
        // 次の open と取り違えられる。
        guard selection != nil else { return }
        if let session, selection !== session { return }
        generation += 1
        selection = nil
    }
}

final class HomeAlbumSession {
    let generation: Int
    let album: MediaItem
    let entry: String
    let source: HomeAlbumSourceBox
    let image: UIImage?

    init(generation: Int, album: MediaItem, entry: String, source: HomeAlbumSourceBox, image: UIImage?) {
        self.generation = generation
        self.album = album
        self.entry = entry
        self.source = source
        self.image = image
    }
}

@Observable
final class HomeAlbumArtwork {
    var hidden: Bool
    init(hidden: Bool) { self.hidden = hidden }
}

final class HomeAlbumSourceBox {
    weak var image: UIImage?
    weak var marker: UIView?

    func rect(in canvas: UIView) -> CGRect? {
        guard let marker, let window = marker.window, window === canvas.window,
            marker.bounds.width > 0
        else { return nil }
        let rect = marker.convert(marker.bounds, to: canvas)
        var ancestor = marker.superview
        while let view = ancestor {
            if view is UIScrollView || view.clipsToBounds {
                let viewport = view.convert(view.bounds, to: canvas)
                if !viewport.insetBy(dx: -1, dy: -1).contains(rect) { return nil }
            }
            ancestor = view.superview
        }
        return canvas.bounds.contains(rect) ? rect : nil
    }
}

struct HomeAlbumSource {
    let box: HomeAlbumSourceBox
    let hidden: Bool
}

struct HomeAlbumMarker: UIViewRepresentable {
    let attach: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        attach(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { attach(uiView) }
}

extension View {
    @ViewBuilder
    func homeAlbumSource(_ source: HomeAlbumSource?) -> some View {
        if let source {
            // 画像だけ隠して寸法を残すため、帰着先はタイトルやカード余白を含まない。
            opacity(source.hidden ? 0 : 1)
                .background { HomeAlbumMarker { source.box.marker = $0 } }
        } else {
            self
        }
    }
}
