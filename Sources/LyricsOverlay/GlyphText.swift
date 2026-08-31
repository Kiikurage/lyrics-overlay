import AppKit
import CoreText
import SwiftUI

/// 組版済みの 1 まとまりの文字。
///
/// `CTLine` は文字と書体が決まれば内容が変わらないので、作り直さずに使い回す。
/// 色を変えるだけの演出のたびに `NSAttributedString` を作り直すと、
/// そのつど字送りや行分割をやり直すことになり、そこが実測で最も重かった。
final class TextLayout {
    /// 1 行ぶんの組版結果と、その行の描画位置(左上原点)。
    private struct Line {
        let line: CTLine
        let origin: CGPoint
        let width: Double
    }

    private let lines: [Line]
    /// 縁取りのはみ出しを含まない、文字の占める大きさ。
    let size: CGSize
    /// 実際にインクが乗る範囲(上端・下端)。組版上の高さ(ascent + descent)とは違い、
    /// その文字が本当に描かれる範囲を指す。数字だけの行なら下端はベースライン付近になる。
    let inkTop: Double
    let inkBottom: Double

    private static var cache: [String: TextLayout] = [:]

    /// 折り返さない指定(無限大や greatestFiniteMagnitude)を、扱える幅に丸める。
    /// greatestFiniteMagnitude は isFinite が true なので、
    /// 有限かどうかの判定だけでは弾けない。
    private static func clamp(_ width: Double) -> Double {
        width.isFinite ? min(max(width, 1), 100_000) : 100_000
    }

    /// 同じ文字・書体・折り返し幅なら作り直さない。
    static func make(
        text: String, font: NSFont, maxWidth: Double, maxLines: Int
    ) -> TextLayout {
        let width = clamp(maxWidth)
        let key = "\(text)|\(font.fontName)|\(font.pointSize)|\(Int(width))|\(maxLines)"
        if let cached = cache[key] { return cached }
        let layout = TextLayout(text: text, font: font, maxWidth: width, maxLines: maxLines)
        // 曲が変われば歌詞も変わる。際限なく溜めない。
        if cache.count > 128 { cache.removeAll() }
        cache[key] = layout
        return layout
    }

    private init(text: String, font: NSFont, maxWidth: Double, maxLines: Int) {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length

        var built: [Line] = []
        var start = 0
        var y = 0.0
        var maxLineWidth = 0.0

        while start < length, built.count < maxLines {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, maxWidth)
            if count <= 0 { break }

            var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            // 最後に許された行に収まらない残りは、末尾を省略記号にまとめる。
            if built.count == maxLines - 1, start + count < length {
                let rest = CTTypesetterCreateLine(
                    typesetter, CFRange(location: start, length: length - start))
                let token = CTLineCreateWithAttributedString(
                    NSAttributedString(string: "…", attributes: [.font: font]))
                if let truncated = CTLineCreateTruncatedLine(rest, maxWidth, .end, token) {
                    line = truncated
                    count = length - start
                }
            }

            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            // 行送り(leading)は足さない。1 行のときに下へ余白が付いてしまうため。
            built.append(Line(line: line, origin: CGPoint(x: 0, y: y + ascent), width: width))
            y += ascent + descent
            maxLineWidth = max(maxLineWidth, width)
            start += count
        }

        lines = built
        size = CGSize(width: ceil(maxLineWidth), height: ceil(y))

        // CTLineGetImageBounds はベースライン基準(上が正)で返る。
        // 上からの距離に直しておく。
        if let first = built.first, let last = built.last {
            let head = CTLineGetImageBounds(first.line, nil)
            let tail = CTLineGetImageBounds(last.line, nil)
            inkTop = first.origin.y - head.maxY
            inkBottom = last.origin.y - tail.minY
        } else {
            inkTop = 0
            inkBottom = 0
        }
    }

    /// - Parameters:
    ///   - alphaAt: 文字ごとの不透明度。nil なら一律。
    ///   - alignment: 行の長さが違うときに、どちら側で揃えるか。
    ///   - sinkAt: 文字ごとの沈み込み(下方向の移動量)。
    ///   - slack: 下側に余分に確保してある高さ。文字はそのぶん下へ動ける。
    func draw(
        in context: CGContext, size canvas: CGSize, alignment: NSTextAlignment,
        fill: (Int) -> NSColor, stroke: (Int) -> NSColor, strokeWidth: Double,
        sinkAt: (Int) -> Double, slack: Double
    ) {
        // 縁取りのはみ出しぶんを上下に振り分ける。
        // 下側の余白(沈み込みのための場所)はここには含めない。
        let inset = (canvas.height - size.height - slack) / 2
        context.saveGState()
        // Core Text は y 軸が上向き。描画先は下向きなので反転させる。
        context.textMatrix = .identity
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        context.setLineJoin(.round)
        context.setLineWidth(strokeWidth)
        context.translateBy(x: 0, y: -inset)

        // 縁取りは全文字ぶんを先に描く。1 文字ずつ縁 → 塗りの順で描くと、
        // 隣の文字の縁が手前の文字の塗りに重なってしまう。
        if strokeWidth > 0 {
            context.setTextDrawingMode(.stroke)
            render(in: context, canvas: canvas, alignment: alignment, color: stroke, sink: sinkAt)
        }
        context.setTextDrawingMode(.fill)
        render(in: context, canvas: canvas, alignment: alignment, color: fill, sink: sinkAt)
        context.restoreGState()
    }

    private func render(
        in context: CGContext, canvas: CGSize, alignment: NSTextAlignment,
        color: (Int) -> NSColor, sink: (Int) -> Double
    ) {
        for line in lines {
            let slack = canvas.width - line.width
            let offsetX: Double
            switch alignment {
            case .right: offsetX = slack
            case .center: offsetX = slack / 2
            default: offsetX = 0
            }
            // 反転後の座標系なので、上からの距離を下からの距離に読み替える。
            let baseline = canvas.height - line.origin.y

            for run in CTLineGetGlyphRuns(line.line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let font = unsafeBitCast(
                    CFDictionaryGetValue(
                        CTRunGetAttributes(run),
                        Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()),
                    to: CTFont.self)

                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                let range = CFRange(location: 0, length: count)
                CTRunGetGlyphs(run, range, &glyphs)
                CTRunGetPositions(run, range, &positions)
                CTRunGetStringIndices(run, range, &indices)

                for i in 0..<count {
                    context.setFillColor(color(indices[i]).cgColor)
                    context.setStrokeColor(color(indices[i]).cgColor)
                    // 反転した座標系なので、下へ動かすには y を引く。
                    var position = CGPoint(
                        x: positions[i].x + offsetX,
                        y: positions[i].y + baseline - sink(indices[i]))
                    CTFontDrawGlyphs(font, &glyphs[i], &position, 1, context)
                }
            }
        }
    }
}

/// 縁取り付きの文字。組版は `TextLayout` に任せ、描画だけを毎フレーム行う。
///
/// 文字ごとに不透明度を変えられるので、時間差の演出もこれ 1 つで足りる。
/// 描画は `CTFontDrawGlyphs` で、通常の文字表示とまったく同じ経路を通る
/// (グリフのアウトラインを自前で塗るのとは違い、品質は変わらない)。
struct GlyphText: View {
    let text: String
    @ObservedObject var style: OverlayStyle
    /// 設定の文字サイズを使わず固定したいときだけ指定する。
    var size: Double?
    var opacity: Double = 1
    var maxLines: Int = 2
    var maxWidth: Double = .greatestFiniteMagnitude
    /// 文字ごとの不透明度。演出のときだけ渡す。
    var alphaAt: ((Int) -> Double)?
    /// 文字ごとの沈み込み。消えていく文字を下へ流すのに使う。
    var sinkAt: ((Int) -> Double)?
    /// 下側に余分に確保する高さ。
    /// Canvas は枠で切り取るので、沈み込むぶんの場所が無いと文字が見切れる。
    var slack: Double = 0
    /// 崩れ具合(0 でそのまま、1 で消滅)。
    var dissolve: Double = 0

    var body: some View {
        let layout = layout()
        let bleed = strokeWidth
        Canvas { context, canvasSize in
            context.withCGContext { cg in
                if dissolve > 0.001 {
                    // 文字を格子に切り、順に抜いていく。
                    // 抜く順番は場所から決めるので、同じ行なら毎回同じ崩れ方になり、
                    // フレームごとにちらつかない。
                    let cells = Self.survivingCells(
                        in: canvasSize, dissolve: dissolve, seed: text.count)
                    if cells.isEmpty { return }
                    cg.clip(to: cells)
                }
                layout.draw(
                    in: cg, size: canvasSize, alignment: style.alignment.textAlignment,
                    fill: { index in
                        // 青へ寄せるのは「消えていく途中」だけ。
                        // 曲情報のように常に薄く出しているだけの文字は、
                        // 色を変えずに不透明度だけ下げる。
                        let base = NSColor(OverlayStyle.textColor)
                        guard let alphaAt else {
                            return base.withAlphaComponent(
                                base.alphaComponent * CGFloat(opacity))
                        }
                        let color = style.dimmed(base, alpha: alphaAt(index))
                        return color.withAlphaComponent(
                            color.alphaComponent * CGFloat(opacity))
                    },
                    stroke: { index in
                        let alpha = (alphaAt?(index) ?? 1) * opacity
                        return NSColor(OverlayStyle.strokeColor).withAlphaComponent(CGFloat(alpha))
                    },
                    strokeWidth: bleed,
                    sinkAt: { sinkAt?($0) ?? 0 },
                    slack: slack)
            }
        }
        // 縁取りと沈み込みのぶん、描画の余地を足しておく。
        .frame(width: layout.size.width + bleed, height: layout.size.height + bleed + slack)
    }

    private var strokeWidth: Double {
        OverlayStyle.strokeWidth(for: size ?? style.fontSize)
    }

    /// 崩し残す升目。
    ///
    /// 文字を小さな升目に分け、升目ごとに決まった順番で消していく。
    /// 消える順番は位置から決める(乱数を持ち回らない)ので、同じ行なら
    /// 毎回同じ崩れ方になり、フレーム間でちらつかない。
    /// 左からの偏りを少し混ぜて、一様に散るより崩れて見えるようにしている。
    private static func survivingCells(
        in size: CGSize, dissolve: Double, seed: Int
    ) -> [CGRect] {
        // 升目が粗いと、崩れではなく市松模様に見えてしまう。
        let cell = 1.5
        let columns = max(1, Int(ceil(size.width / cell)))
        let rows = max(1, Int(ceil(size.height / cell)))
        var rects: [CGRect] = []
        rects.reserveCapacity(columns * rows / 2)

        for row in 0..<rows {
            for column in 0..<columns {
                // 升目が細かいぶん、規則が出ないよう桁を大きめに取る。
                let hash = Double((column &* 1_103 &+ row &* 2_657 &+ seed &* 7_919) % 9_973)
                    / 9_973
                let bias = Double(column) / Double(columns)
                let threshold = hash * 0.75 + bias * 0.25
                guard threshold > dissolve else { continue }
                rects.append(CGRect(
                    x: Double(column) * cell, y: Double(row) * cell,
                    width: cell, height: cell))
            }
        }
        return rects
    }

    private func layout() -> TextLayout {
        TextLayout.make(
            text: text, font: style.font(size: size), maxWidth: maxWidth, maxLines: maxLines)
    }

    /// 実際に文字が描かれる範囲(枠の上端からの距離)。
    /// 行の高さではなく見た目の上下端を合わせたいときに使う。
    static func ink(
        of text: String, style: OverlayStyle, size: Double? = nil,
        maxLines: Int = 1, maxWidth: Double = .greatestFiniteMagnitude
    ) -> (top: Double, bottom: Double) {
        let layout = TextLayout.make(
            text: text, font: style.font(size: size), maxWidth: maxWidth, maxLines: maxLines)
        let inset = OverlayStyle.strokeWidth(for: size ?? style.fontSize) / 2
        return (layout.inkTop + inset, layout.inkBottom + inset)
    }

    /// パネルが寸法を測るときにも同じ組版を使う。
    static func size(
        of text: String, style: OverlayStyle, size: Double? = nil,
        maxLines: Int = 2, maxWidth: Double = .greatestFiniteMagnitude, slack: Double = 0
    ) -> CGSize {
        let layout = TextLayout.make(
            text: text, font: style.font(size: size), maxWidth: maxWidth, maxLines: maxLines)
        let bleed = OverlayStyle.strokeWidth(for: size ?? style.fontSize)
        return CGSize(
            width: layout.size.width + bleed, height: layout.size.height + bleed + slack)
    }
}
