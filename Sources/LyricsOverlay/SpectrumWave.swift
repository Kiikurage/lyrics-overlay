import SwiftUI

/// 周波数スペクトルを、中心線に対して上下対称に繋いだ波形として描く。
/// 横軸が周波数(対数)、縦軸が強さ。
///
/// 白く塗った波形そのものを光源とみなし、同じ形を大きく・強くぼかしたものを
/// その背後に重ねて光の放射を作る。合成は加算なので、光源の近くほど白く飛び、
/// 外側へ向かうほど周波数に応じた色が残る。
///
/// 幅は呼び出し側が決めた固定値を使う。歌詞の長さでウィンドウが伸び縮みしても
/// 描画そのものは変わらない。
struct SpectrumWave: View {
    @ObservedObject var spectrum: SpectrumModel
    @ObservedObject var style: OverlayStyle

    /// バンドごとのレベル(0〜1)。低域から高域の順。
    private var levels: [Double] { spectrum.levels }
    /// 残光。levels より長く尾を引く値。光が消え残る表現に使う。
    private var afterglow: [Double] { spectrum.afterglow }

    /// 表示の高さ。光の放射ぶんも含む。歌詞の背後に回すので大きく取る。
    static let height: Double = 320
    /// 表示の幅。曲名の長さに合わせると短い曲で詰まるので固定にする。
    static let width: Double = 420
    /// 波形の左右に確保する余白。ここが無いと端で光が切れる。
    /// 描画は外へ広げ、レイアウト上の幅は変えない(呼び出し側が負の余白で戻す)。
    static let margin: Double = 22

    /// 光源(白い波形)が使う高さの比。残りは光の放射に使う。
    private static let sourceScale: Double = 0.78
    /// 表示のコントラスト。1 より大きいほど、弱い帯域が沈んで山が際立つ。
    private static let contrast: Double = 1.5
    /// 放射の広がり。光源の何倍まで膨らませるか。
    /// 放射は光源のすぐ外側に留める。大きく広げると白い面が相対的に痩せて見える。
    private static let spread: [(scale: Double, blur: Double, opacity: Double)] = [
        (1.34, 13, 0.45),
        (1.18, 7, 0.4),
        (1.06, 3, 0.4),
    ]

    /// 描画範囲の確認用。実際にどこへ描いているかを見るための一時的な色。
    private static let debugBackground = false
    /// 確認用。最高域のバンドを固定値にして、右端がどこに描かれるか見る。
    private static let debugPinTop = false

    /// 周波数に対応する色。左(低域)から右(高域)へ。
    private static let hues: [Color] = [
        Color(red: 1.00, green: 0.30, blue: 0.50),
        Color(red: 0.75, green: 0.35, blue: 1.00),
        Color(red: 0.35, green: 0.55, blue: 1.00),
        Color(red: 0.25, green: 0.95, blue: 0.90),
    ]

    var body: some View {
        // 解析が届いたぶんだけ描き直す。補間や慣性は挟まない。
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: Self.height)
        .allowsHitTesting(false)
    }

    /// 描画に使う値。弱い帯域を沈めて、山と谷の差を広げる。
    private var values: [Double] {
        var result = levels.map { pow(min(max($0, 0), 1), Self.contrast) }
        if Self.debugPinTop, !result.isEmpty { result[result.count - 1] = 0.9 }
        return result
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        if Self.debugBackground {
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.red.opacity(0.18)))
        }
        guard values.count > 1 else { return }
        context.blendMode = .plusLighter

        let gradient = Gradient(colors: Self.hues)

        // 残光。本体より遅れて消えるので、動きの尾として残る。
        if afterglow.count == levels.count {
            context.drawLayer { inner in
                inner.addFilter(.blur(radius: 18))
                inner.fill(
                    shape(in: size, scale: 1.3,
                          values: afterglow.map { pow(min(max($0, 0), 1), Self.contrast) }),
                    with: .linearGradient(
                        gradient,
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)))
                inner.opacity = 0.22
            }
        }

        // 外側の広い光から順に重ね、最後に光源を置く。
        for layer in Self.spread {
            context.drawLayer { inner in
                inner.addFilter(.blur(radius: layer.blur))
                inner.fill(
                    shape(in: size, scale: layer.scale, values: values),
                    with: .linearGradient(
                        gradient,
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)))
                inner.opacity = layer.opacity
            }
        }

        // 光源そのもの。ここは白のまま、ぼかさずに置く。
        context.fill(shape(in: size, scale: 1, values: values), with: .color(.white.opacity(0.85)))
    }

    /// 中心線に対して上下対称の波形。scale は光源に対する膨らみ。
    ///
    /// 波形自体は左右の余白を除いた内側に描く。余白は光が滲むための場所で、
    /// ここが無いと端の光が四角く切り落とされる。
    private func shape(in size: CGSize, scale: Double, values all: [Double]) -> Path {
        let midY = size.height / 2
        let amplitude = size.height / 2 * Self.sourceScale * scale
        let inner = max(size.width - Self.margin * 2, 1)

        // 端点(直流とナイキスト超)を足した点列。どちらも振幅 0。
        let count = all.count + 2
        let upper: [CGPoint] = (0..<count).map { index in
            let value = index == 0 || index == count - 1 ? 0 : min(1, all[index - 1])
            return CGPoint(
                x: Self.margin + Double(index) / Double(count - 1) * inner,
                y: midY - value * amplitude)
        }

        var path = Path()
        path.move(to: upper[0])
        spline(&path, through: upper)
        // 下側は上側を中心線で折り返す。
        let lower = upper.reversed().map { CGPoint(x: $0.x, y: midY + (midY - $0.y)) }
        path.addLine(to: lower[0])
        spline(&path, through: Array(lower))
        path.closeSubpath()
        return path
    }

    /// 点列を三次曲線(Catmull-Rom)で繋ぐ。
    ///
    /// 直線や、値だけを合わせるコサイン補間だと、代表点のところで曲率が
    /// 不連続になり、折れて見える。両隣の点から接線を決めて繋ぐことで、
    /// 代表点を通りながら傾きが連続した曲線になる。
    private func spline(_ path: inout Path, through points: [CGPoint]) {
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            path.addCurve(
                to: p2,
                control1: CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
    }

}
