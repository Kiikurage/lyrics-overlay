import AppKit
import SwiftUI

/// オーバーレイの見た目。設定ウィンドウから変更され、UserDefaults に永続化する。
/// 表示側(OverlayView / プレビュー)はこれを監視して即座に追従する。
@MainActor
final class OverlayStyle: ObservableObject {
    /// フォントの太さ。NSFontManager の 0〜15 スケールで指定する。
    /// ファミリごとに用意されているウェイトが違うため、名前ではなく数値で近いものを引く。
    enum Weight: String, CaseIterable, Identifiable {
        case regular, medium, bold, heavy, black

        var id: String { rawValue }

        var label: String {
            switch self {
            case .regular: return "標準"
            case .medium: return "中太"
            case .bold: return "太字"
            case .heavy: return "極太"
            case .black: return "最太"
            }
        }

        /// NSFontManager のウェイト値。
        var managerValue: Int {
            switch self {
            case .regular: return 5
            case .medium: return 6
            case .bold: return 9
            case .heavy: return 11
            case .black: return 14
            }
        }

        /// ファミリ指定が効かないときのシステムフォント用。
        var system: NSFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .bold: return .bold
            case .heavy: return .heavy
            case .black: return .black
            }
        }
    }

    /// 歌詞をどちら側に揃えるか。ウィンドウが伸び縮みする際の固定端(アンカー)も兼ねる。
    enum Alignment: String, CaseIterable, Identifiable {
        case left, center, right

        var id: String { rawValue }

        var label: String {
            switch self {
            case .left: return "左寄せ"
            case .center: return "中央寄せ"
            case .right: return "右寄せ"
            }
        }

        /// 曲情報と歌詞で長さが違うとき、どちら側の端で揃えるか。
        var horizontal: HorizontalAlignment {
            switch self {
            case .left: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }

        var frameAlignment: SwiftUI.Alignment {
            switch self {
            case .left: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }

        var textAlignment: NSTextAlignment {
            switch self {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
    }

    /// 行が切り替わるときの見せ方。
    enum Transition: String, CaseIterable, Identifiable {
        case fade, wipe, slide, dissolve, none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fade: return "フェード"
            case .wipe: return "左から順に"
            case .slide: return "せり上がり"
            case .dissolve: return "ディゾルブ"
            case .none: return "なし"
            }
        }

        /// 消えるとき / 現れるときの秒数。
        var timing: (out: Double, in: Double) {
            switch self {
            case .fade: return (0.22, 0.18)
            case .wipe: return (0.34, 0.28)
            case .slide: return (0.22, 0.20)
            case .dissolve: return (0.38, 0.32)
            case .none: return (0, 0)
            }
        }
    }

    @Published var transition: Transition { didSet { defaults.set(transition.rawValue, forKey: "style.transition") } }
    @Published var alignment: Alignment { didSet { defaults.set(alignment.rawValue, forKey: "style.alignment") } }
    @Published var fontFamily: String { didSet { defaults.set(fontFamily, forKey: "style.fontFamily") } }
    @Published var weight: Weight { didSet { defaults.set(weight.rawValue, forKey: "style.weight") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "style.fontSize") } }
    /// 音声を解析してスペクトルを表示するか。
    @Published var showSpectrum: Bool { didSet { defaults.set(showSpectrum, forKey: "style.showSpectrum") } }

    /// 設定ウィンドウでホバー中のファミリ。プレビュー専用で、保存も確定もしない。
    @Published var previewFamily: String?

    /// 白い文字に黒い縁取り。ここは設定させない。
    static let textColor = Color.white
    static let strokeColor = Color.black

    /// 縁取りの太さ。
    ///
    /// ストロークはグリフの輪郭を中心に内外へ半分ずつかかり、内側は塗りが覆う。
    /// つまり外に見える太さは指定値の半分になる。
    ///
    /// 文字サイズの 1/4 を指定して、見た目の縁を文字サイズの 1/8 に揃える。
    /// この比率なら、小さな文字でも潰れず、大きな文字でも太くなりすぎない。
    nonisolated static func strokeWidth(for size: Double) -> Double { size / 4 }

    private let defaults = UserDefaults.standard

    /// 丸ゴシックがあれば初期値に使う。無い環境ではシステムフォント。
    private static var defaultFamily: String {
        let families = NSFontManager.shared.availableFontFamilies
        for candidate in ["Rounded M+ 1c", "Hiragino Maru Gothic ProN"] where families.contains(candidate) {
            return candidate
        }
        return NSFont.systemFont(ofSize: 27).familyName ?? "Helvetica"
    }

    init() {
        transition = defaults.string(forKey: "style.transition").flatMap(Transition.init(rawValue:)) ?? .fade
        alignment = defaults.string(forKey: "style.alignment").flatMap(Alignment.init(rawValue:)) ?? .center
        fontFamily = defaults.string(forKey: "style.fontFamily") ?? Self.defaultFamily
        weight = defaults.string(forKey: "style.weight").flatMap(Weight.init(rawValue:)) ?? .black
        fontSize = defaults.object(forKey: "style.fontSize") as? Double ?? 27
        showSpectrum = defaults.object(forKey: "style.showSpectrum") as? Bool ?? true
    }

    /// 指定サイズのフォント。省略時は設定中の文字サイズ。
    func font(size: Double? = nil) -> NSFont {
        let size = size ?? fontSize
        let resolved = NSFontManager.shared.font(
            withFamily: previewFamily ?? fontFamily, traits: [], weight: weight.managerValue,
            size: size)
        return resolved ?? NSFont.systemFont(ofSize: size, weight: weight.system)
    }

    /// 描画用の属性付き文字列。パネルの幅の実測にも同じものを使う。
    /// - Parameter alphaAt: 文字ごとの不透明度。時間差の演出で使う。
    func attributed(_ text: String, size: Double? = nil, stroke: Bool, opacity: Double = 1,
                    alphaAt: ((Int) -> Double)? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.textAlignment
        paragraph.lineBreakMode = .byTruncatingTail

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(size: size),
            .paragraphStyle: paragraph,
        ]
        if stroke {
            // NSAttributedString の strokeWidth は文字サイズに対する百分率。
            attrs[.strokeWidth] = Self.strokeWidth(for: size ?? fontSize) / (size ?? fontSize) * 100
            attrs[.strokeColor] = NSColor(Self.strokeColor).withAlphaComponent(opacity)
            attrs[.foregroundColor] = NSColor.clear
        } else {
            attrs[.foregroundColor] = NSColor(Self.textColor).withAlphaComponent(opacity)
        }
        guard let alphaAt else { return NSAttributedString(string: text, attributes: attrs) }

        // 文字ごとに色の alpha だけ差し替える。組版そのものは 1 つの文字列のままなので、
        // 字送りも合字も通常どおりに保たれる。
        let result = NSMutableAttributedString(string: text, attributes: attrs)
        let key: NSAttributedString.Key = stroke ? .strokeColor : .foregroundColor
        let base = stroke ? NSColor(Self.strokeColor) : NSColor(Self.textColor)
        var index = 0
        (text as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: (text as NSString).length),
            options: .byComposedCharacterSequences
        ) { _, range, _, _ in
            let alpha = CGFloat(min(max(alphaAt(index), 0), 1) * opacity)
            // 縁取りは読みやすさのために色を変えず、alpha だけ下げる。
            let color = stroke
                ? base.withAlphaComponent(alpha)
                : self.dimmed(base, alpha: alpha)
            result.addAttribute(key, value: color, range: range)
            index += 1
        }
        return result
    }

    /// 消えかけの文字が向かう色相(青)。
    private static let dimHue: Double = 0.62

    /// 消えていく途中の色。単に alpha を下げると灰色に沈むだけなので、
    /// 暗くなるにつれて青へ寄せる。
    ///
    /// 由来は視覚のプルキンエ現象。暗所では網膜の主役が錐体から桿体に移り、
    /// 感度のピークが 555nm(黄緑)から 507nm(青緑)へ短波長側にずれるため、
    /// 暗い対象ほど青みがかって見える。薄暮の風景が青く沈むのと同じ理屈で、
    /// 「暗くなる = 青へ寄る」は物理的にも辻褄が合う。
    ///
    /// 色相を青へ回すので、白以外の文字色でも同じように働く。
    func dimmed(_ color: NSColor, alpha: Double) -> NSColor {
        // 色の変化を alpha より先行させる。両者を同じ速さで進めると、
        // 青くなる前に薄くなってしまって色の変化が見えない。
        let t = pow(1 - min(max(alpha, 0), 1), 0.45)
        guard t > 0, let rgb = color.usingColorSpace(.deviceRGB) else {
            return color.withAlphaComponent(color.alphaComponent * alpha)
        }

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, base: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &base)

        // 白や黒は色相を持たないので、回さずに青から始める。
        if saturation < 0.05 {
            hue = CGFloat(Self.dimHue)
        } else {
            // 色相環の近いほうに回す。
            var delta = CGFloat(Self.dimHue) - hue
            if delta > 0.5 { delta -= 1 }
            if delta < -0.5 { delta += 1 }
            hue = (hue + delta * CGFloat(t) * 0.9).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
        }

        return NSColor(
            hue: hue,
            saturation: saturation + (0.8 - saturation) * CGFloat(t),
            brightness: brightness * (1 - 0.45 * CGFloat(t)),
            alpha: base * CGFloat(alpha))
    }

    /// 折り返しを考慮した描画サイズ。
    /// 1 行に収まるなら行送りではなく字面の高さを使う(下に余白が付かないように)。
    func measure(_ text: String, size: Double? = nil, within width: Double) -> NSSize {
        let attributed = attributed(text, size: size, stroke: true)
        let intrinsic = attributed.size()
        if intrinsic.width <= width {
            return NSSize(width: ceil(intrinsic.width), height: ceil(intrinsic.height))
        }
        let bounds = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]).size
        return NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// 1 行に収まる前提での幅。
    func width(of text: String, size: Double? = nil) -> Double {
        attributed(text, size: size, stroke: true).size().width
    }

    func reset() {
        transition = .fade
        alignment = .center
        fontFamily = Self.defaultFamily
        weight = .black
        fontSize = 27
        showSpectrum = true
    }

}
