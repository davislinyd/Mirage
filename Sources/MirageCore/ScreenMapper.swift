/// 把正規化影像座標映射到螢幕座標（pt，原點左下）：取畫面中央 `boxFraction` 的區域作為感應區，並水平鏡像，
/// 讓手往右移時游標也往右。M0 用固定感應區換算抖動在螢幕上的實際大小；M1 會改用校準結果。
public struct ScreenMapper: Sendable {
    public var screenWidth: Double
    public var screenHeight: Double
    public var boxFraction: Double

    public init(screenWidth: Double, screenHeight: Double, boxFraction: Double = 0.5) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.boxFraction = boxFraction
    }

    private var boxOrigin: Double {
        (1 - boxFraction) / 2
    }

    public func map(_ point: Vec2) -> Vec2 {
        Vec2(
            x: ((1 - point.x) - boxOrigin) / boxFraction * screenWidth,
            y: (point.y - boxOrigin) / boxFraction * screenHeight
        )
    }

    /// `map` 的反函數，但保留鏡像，供繪製在鏡像畫面上。
    public func mirroredNormalized(fromScreen point: Vec2) -> Vec2 {
        Vec2(
            x: point.x / screenWidth * boxFraction + boxOrigin,
            y: point.y / screenHeight * boxFraction + boxOrigin
        )
    }
}
