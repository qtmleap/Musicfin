import CoreGraphics

@main
struct PlayerDismissRegionTests {
    static func main() {
        let wide = CGSize(width: 1366, height: 1024)
        let narrow = CGSize(width: 820, height: 1180)
        let boundary = PlayerWideColumnGeometry(width: wide.width).detailLeading
        func allows(
            _ x: CGFloat, _ y: CGFloat, detail: Bool = true, size: CGSize = CGSize(width: 1366, height: 1024),
            excluded: [CGRect] = []
        ) -> Bool {
            PlayerDismissRegion.allows(
                start: CGPoint(x: x, y: y), size: size, detailIsVisible: detail, excluded: excluded)
        }
        precondition(allows(boundary - 1, 300), "left control column dismisses details")
        precondition(!allows(boundary, 300), "right detail boundary belongs to scrolling")
        precondition(!allows(1250, 400), "right lyrics and queue must remain scrollable")
        precondition(allows(1250, 400, detail: false), "artwork mode dismisses from the right")
        precondition(allows(700, 400, detail: false, size: narrow), "narrow artwork also dismisses anywhere")
        precondition(!allows(1250, 20), "wide details keep the right header outside dismissal")
        precondition(allows(700, 20, size: narrow), "narrow details retain their header escape")
        precondition(!allows(200, 500, size: narrow), "narrow full-width lyrics keep scrolling")
        let slider = CGRect(x: 200, y: 600, width: 300, height: 50)
        precondition(!allows(250, 620, detail: false, excluded: [slider]), "seek and volume touches never dismiss")
        precondition(allows(250, 580, detail: false, excluded: [slider]), "slider exclusion does not block the column")
        print("PlayerDismissRegion: artwork, detail boundary, narrow fallback and slider exclusion passed")
    }
}
