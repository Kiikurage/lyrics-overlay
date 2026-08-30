import AppKit
import Combine
import SwiftUI

/// 常に最前面に浮かぶ、枠なし・透過のパネル。
/// フォーカスを奪わないよう .nonactivatingPanel を使う。
final class OverlayPanel: NSPanel {
    private static let anchorKey = "OverlayAnchorX"
    private static let topYKey = "OverlayTopY"

    /// 文字の周囲の余白。
    private static let padding = NSSize(width: 28, height: 16)

    private let model: OverlayModel
    private let spectrum: SpectrumModel
    private let style: OverlayStyle
    private var observers: Set<AnyCancellable> = []
    private var dragMonitor: Any?

    /// 揃え方向の端の x 座標。ここを固定したまま幅が伸び縮みする。
    private var anchorX: CGFloat = 0
    /// 上端の y 座標。歌詞の行数が変わっても曲情報の位置が動かないよう、下端ではなく上端を固定する。
    private var topY: CGFloat = 0
    private var lastAlignment: OverlayStyle.Alignment?
    /// これまでに必要だった最大の大きさ。曲や設定が変わるまで縮めない。
    private var held: NSSize = .zero

    init(model: OverlayModel, spectrum: SpectrumModel, style: OverlayStyle) {
        self.model = model
        self.spectrum = spectrum
        self.style = style
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // 全 Space と、他アプリのフルスクリーン上にも表示する。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        contentView = NSHostingView(
            rootView: OverlayView(model: model, spectrum: spectrum, style: style))
        restorePosition()

        // 歌詞が変わればウィンドウ幅も変わる。設定変更(書体・サイズ・揃え)も同じ。
        model.$current.sink { [weak self] _ in self?.scheduleLayout() }.store(in: &observers)
        model.$trackInfo.sink { [weak self] _ in
            self?.held = .zero
            self?.scheduleLayout()
        }.store(in: &observers)
        model.$timeText.sink { [weak self] _ in self?.scheduleLayout() }.store(in: &observers)
        model.$artwork.sink { [weak self] _ in self?.scheduleLayout() }.store(in: &observers)
        // スペクトラムは毎フレーム変わるので、有無だけを見る。
        spectrum.$levels.map(\.isEmpty).removeDuplicates()
            .sink { [weak self] _ in self?.scheduleLayout() }.store(in: &observers)
        model.$reservesArtwork.sink { [weak self] _ in self?.scheduleLayout() }.store(in: &observers)
        style.objectWillChange.sink { [weak self] in
            self?.held = .zero
            self?.scheduleLayout()
        }.store(in: &observers)
        layout()
        watchDragging()
    }

    /// ダブルクリックを拾う。isMovableByWindowBackground による移動は
    /// AppKit が処理してしまうので、イベントモニタで見る。
    private func watchDragging() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            guard let self, event.window === self else { return event }
            if event.type == .leftMouseDown, event.clickCount == 2 {
                activateSpotify()
                return event
            }
            return event
        }
    }

    /// ダブルクリックで Spotify を前面に出す。
    /// 起動していなければ起動し、ウィンドウを閉じている状態でも開き直させる。
    private func activateSpotify() {
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: "com.spotify.client")
        else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration)
    }

    deinit {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
    }

    /// @Published も objectWillChange も「変わる直前」に届くので、
    /// 新しい値でレイアウトするために 1 回まわしてから実行する。
    private func scheduleLayout() {
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    /// 表示中の文字列に合わせて大きさを決め、アンカー側の端を固定して配置する。
    private func layout() {
        // 自分がいまどの画面に載っているかで判定すると、リサイズ →
        // 画面をまたぐ → 別画面基準でまた補正、と連鎖して隣のディスプレイへ飛ぶ。
        // 基準はあくまでユーザーが置いたアンカーの位置にする。
        let visible = anchorScreen().visibleFrame
        let maxWidth = max(240, visible.width - 40)

        // 揃えを変えた直後は、いま見えている位置の該当端を新しいアンカーにする
        // (ウィンドウが飛ばないように)。
        if let last = lastAlignment, last != style.alignment {
            anchorX = anchor(of: frame, for: style.alignment)
            held = .zero
        }
        lastAlignment = style.alignment

        let inner = maxWidth - Self.padding.width * 2
        if model.contentWidthLimit != inner { model.contentWidthLimit = inner }
        // 縁取りは字面からはみ出すので、塗りではなく縁取り側の層で測る。
        var size = measure(model.current, size: nil, within: inner)
        if !model.trackInfo.isEmpty {
            let info = measure(model.trackInfo, size: OverlayView.infoSize,
                               within: .greatestFiniteMagnitude)
            var headerWidth = info.width
            var headerHeight = info.height
            if !model.timeText.isEmpty {
                let time = measure(model.timeText, size: OverlayView.infoSize,
                                   within: .greatestFiniteMagnitude)
                headerWidth = max(headerWidth, OverlayView.timeWidth(model.timeText, style: style))
                headerHeight += time.height + OverlayView.infoLineSpacing
            }
            if model.artwork != nil || model.reservesArtwork {
                let art = OverlayView.artFrame(
                    style, title: model.trackInfo,
                    time: model.timeText.isEmpty ? "0:00 / 0:00" : model.timeText)
                headerWidth += art.size + OverlayView.artGap
                headerHeight = max(headerHeight, art.size + art.offset)
            }
            size.width = max(size.width, headerWidth)
            size.height += headerHeight + OverlayView.spacing
        }
        // 波は固定幅。ウィンドウがそれより狭いと切れるので、下限として効かせる。
        if !spectrum.levels.isEmpty {
            size.width = max(size.width, SpectrumWave.width)
        }

        // 行ごとに縮めると、短い行のたびにウィンドウが動いて落ち着かない。
        // 曲や設定が変わるまでは、いちばん大きかったところに合わせたままにする。
        held.width = max(held.width, ceil(size.width) + Self.padding.width * 2 + 4)
        let width = min(maxWidth, held.width)
        // 高さは上端固定なので、縮んでも情報行の位置は動かない。素直に内容に合わせる。
        let height = min(max(120, visible.height - 40),
                         ceil(size.height) + Self.padding.height * 2)

        // 波は歌詞より背が高い。ウィンドウの上下にその場所を確保する。
        // 文字の位置を動かしたくないので、余白はウィンドウの外側へ足す。
        let top = spectrum.levels.isEmpty ? 0 : OverlayView.waveMarginTop
        let bottom = spectrum.levels.isEmpty ? 0 : OverlayView.waveMarginBottom
        let outerHeight = height + top + bottom
        var origin = NSPoint(x: anchorX, y: topY + top - outerHeight)
        switch style.alignment {
        case .left: break                             // 左端を固定して右へ伸びる
        case .center: origin.x = anchorX - width / 2  // 中心を固定して両側へ伸びる
        case .right: origin.x = anchorX - width       // 右端を固定して左へ伸びる
        }
        // アンカーのある画面からはみ出さないように寄せる。
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - outerHeight))
        setFrame(
            NSRect(origin: origin, size: NSSize(width: width, height: outerHeight)),
            display: true)
    }

    /// アンカー(ユーザーが置いた位置)が載っている画面。無ければメイン画面。
    private func anchorScreen() -> NSScreen {
        let point = NSPoint(x: anchorX, y: topY - 1)
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func measure(_ text: String, size: Double?, within width: CGFloat) -> NSSize {
        OverlayView.usesCoreText
            ? GlyphText.size(
                of: text, style: style, size: size,
                maxLines: 2, maxWidth: width.isFinite ? width : .greatestFiniteMagnitude)
            : style.measure(text, size: size, within: width)
    }

    private func anchor(of frame: NSRect, for alignment: OverlayStyle.Alignment) -> CGFloat {
        switch alignment {
        case .left: return frame.minX
        case .center: return frame.midX
        case .right: return frame.maxX
        }
    }

    private func restorePosition() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.anchorKey) != nil {
            anchorX = CGFloat(defaults.double(forKey: Self.anchorKey))
            topY = CGFloat(defaults.double(forKey: Self.topYKey))
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            anchorX = v.midX
            topY = v.minY + 200
        }
    }

    /// ドラッグ後に、揃え方向の端をアンカーとして覚え直す。
    func savePosition() {
        anchorX = anchor(of: frame, for: style.alignment)
        topY = frame.maxY - (spectrum.levels.isEmpty ? 0 : OverlayView.waveMarginTop)
        UserDefaults.standard.set(Double(anchorX), forKey: Self.anchorKey)
        UserDefaults.standard.set(Double(topY), forKey: Self.topYKey)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// クリック透過。有効な間はドラッグで動かせなくなる。
    var isClickThrough: Bool = false {
        didSet { ignoresMouseEvents = isClickThrough }
    }

}

private struct OverlayView: View {
    /// 文字の描画を Core Text で自前に行うか。
    /// false にすると NSTextField を使う従来の経路に戻る(比較用)。
    static let usesCoreText = true
    /// 曲名・アーティストの文字サイズ。歌詞より控えめに、設定には追従させない。
    static let infoSize: Double = 13
    /// 曲情報と歌詞の間隔。
    static let spacing: Double = 4
    /// 波は歌詞より下に置く。その中心をどれだけ下げるか。
    /// 振幅が大きいときは歌詞に届く程度に留める。
    static let waveOffset: Double = 24
    /// 波が上下へ広がるための余白。下へずらすぶん、下側を多く取る。
    ///
    /// 波が振り切れたときの高さぶんは取らない。現実の曲でそこまで振れることは
    /// まずなく、常時その余白があるとウィンドウが無駄に大きくなるため。
    /// まれに振り切れたときは上下が切れるが、そのぶんを許容している。
    static let waveMarginTop: Double = 20
    static let waveMarginBottom: Double = 92
    /// アルバムカバーと文字の間隔。
    static let artGap: Double = 8
    /// タイトル行と時間行の間隔。ひとまとまりに見せたいので詰める。
    static let infoLineSpacing: Double = 1
    /// アルバムカバーの一辺。
    ///
    /// タイトル行の「文字の上端」から時間行の「文字の下端」までに合わせる。
    /// 行の高さ(ascent + descent)で測ると、数字のようにディセンダを持たない
    /// 文字では下に余りが出て、見た目の下端が揃わない。
    /// 文字の上下からわずかにはみ出させる量。
    /// 文字とぴったり同じ高さだと、面で埋まっているカバーのほうが小さく見えるため。
    static let artOvershoot: Double = 3

    static func artFrame(_ style: OverlayStyle, title: String, time: String)
        -> (size: Double, offset: Double) {
        let titleInk = GlyphText.ink(of: title, style: style, size: infoSize)
        let timeInk = GlyphText.ink(of: time, style: style, size: infoSize)
        let titleHeight = GlyphText.size(of: title, style: style, size: infoSize, maxLines: 1).height
        let bottom = titleHeight + infoLineSpacing + timeInk.bottom
        let top = titleInk.top - artOvershoot
        return (max(1, bottom + artOvershoot - top), top)
    }

    @ObservedObject var model: OverlayModel
    /// 波だけが見る。ここを OverlayModel に同居させると、
    /// 毎フレームの更新でビュー全体が作り直される。
    let spectrum: SpectrumModel
    @ObservedObject var style: OverlayStyle

    var body: some View {
        // 曲情報と歌詞は長さが違う。中央で揃えると歌詞が変わるたびに曲情報が
        // 左右に動いてちらつくので、揃えた側の端で縦に揃える。
        VStack(alignment: style.alignment.horizontal, spacing: OverlayView.spacing) {
            if !model.trackInfo.isEmpty {
                header
            }
            lyric
                // 波は歌詞の背後。歌詞は行ごとに幅も行数も変わるので、
                // その中央ではなく「揃えた側の上端」を基準に置く。
                // 中央を基準にすると、1 行と 2 行で位置が動いてしまう。
                .background(alignment: waveAnchor) { wave }
        }
        .frame(maxWidth: .infinity, alignment: style.alignment.frameAlignment)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        // 波がはみ出すぶんの場所。文字の位置は変わらない。
        .padding(.top, OverlayView.waveMarginTop)
        .padding(.bottom, OverlayView.waveMarginBottom)
        // 歌詞の行数が変わっても上端から積む。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 音に同期した光。背景なのでウィンドウの大きさには影響しない。
    }

    /// アルバムカバーと、その横に積んだタイトル行・時間行。
    /// カバーは揃えた側(右寄せなら右、それ以外は左)に置く。
    private var header: some View {
        // 上端を基準に並べる。カバーの位置は文字のインク上端に合わせて
        // ここから下げるので、中央揃えだとその計算が狂う。
        HStack(alignment: .top, spacing: OverlayView.artGap) {
            if style.alignment == .right {
                infoColumn
                artwork
            } else {
                artwork
                infoColumn
            }
        }
    }

    private var infoColumn: some View {
        VStack(alignment: style.alignment.horizontal, spacing: OverlayView.infoLineSpacing) {
            info
            time
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = model.artwork {
            // 文字には縁取りが付くのにカバーだけ素のままだと、背景に沈んで見える。
            // 同じ色で縁と影を足して、文字と同じ「浮いている」見え方に揃える。
            let frame = artworkFrame
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: frame.size, height: frame.size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                // 枠の上端ではなく、文字の上端に合わせる。
                .offset(y: frame.offset)
        } else if model.reservesArtwork {
            // 取得が終わるまでの場所取り。見えないが幅は占める。
            Color.clear.frame(width: artworkFrame.size, height: artworkFrame.size)
        }
    }

    /// 歌詞行。切り替えの見せ方は設定に従う。
    ///
    /// 演出していない間は素の描画にする。StaggeredText はタイマーを回し続けるので、
    /// 出しっぱなしにすると毎フレーム文字列を作り直すことになる。
    /// 歌詞行。演出中だけ TimelineView で描き直す。
    ///
    /// タイマーを body の中で作ると、body の再評価のたびに新しいタイマーを
    /// 購読してしまい、際限なく増えて暴走する。分岐ごと切り替えれば、
    /// 演出が終わった時点で TimelineView そのものが消える。
    @ViewBuilder
    private var lyric: some View {
        if !OverlayView.usesCoreText {
            legacyLyric
        } else if model.isTransitioning, style.transition != .none {
            TimelineView(.animation) { timeline in
                lyricText(progress: progress(at: timeline.date))
            }
        } else {
            lyricText(progress: nil)
        }
    }

    /// - Parameter progress: 演出の進み具合(0〜1)。nil なら演出なし。
    private func lyricText(progress: Double?) -> some View {
        GlyphText(
            text: model.current, style: style,
            maxWidth: model.contentWidthLimit,
            alphaAt: progress.map { value in { charAlpha($0, progress: value) } },
            sinkAt: progress.map { value in { charSink($0, progress: value) } })
    }

    private func progress(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(model.transitionStart)
        return min(max(elapsed / max(model.transitionDuration, 0.01), 0), 1)
    }

    /// 文字ごとの不透明度。ワイプのときだけ行頭から時間差を付ける。
    private func charAlpha(_ index: Int, progress: Double) -> Double {
        let stagger = style.transition == .wipe ? 0.7 : 0
        let count = max(model.current.count - 1, 1)
        let position = Double(min(index, count)) / Double(count)
        let local = min(max(progress * (1 + stagger) - stagger * position, 0), 1)
        return model.entering ? local : 1 - local
    }

    /// 文字ごとの縦の移動量(下が正)。
    ///
    /// 消えるときは、その文字自身の消え具合に合わせて沈ませる。文字ごとに
    /// 時間差がある演出でも、消えかけの文字だけが落ちていく。
    private func charSink(_ index: Int, progress: Double) -> Double {
        let alpha = charAlpha(index, progress: progress)
        if model.entering {
            // せり上がりのときだけ、下から現れる。
            return style.transition == .slide ? -10 * (1 - alpha) : 0
        }
        return 9 * (1 - alpha)
    }

    /// NSTextField を使う従来の経路(比較用)。
    @ViewBuilder
    private var legacyLyric: some View {
        if style.transition == .none || !model.isTransitioning {
            OutlinedText(model.current, style: style)
        } else {
            StaggeredText(
                text: model.current, style: style, start: model.transitionStart,
                duration: model.transitionDuration, entering: model.entering,
                stagger: style.transition == .wipe ? 0.7 : 0,
                rise: style.transition == .slide ? 10 : 0)
        }
    }

    /// 波を置く基準。横は揃え設定、縦は歌詞行の上端。
    private var waveAnchor: Alignment {
        Alignment(horizontal: style.alignment.horizontal, vertical: .top)
    }

    /// 歌詞行の上端から、波の中心までの距離。
    ///
    /// 上端を基準にしているので、歌詞が 1 行でも 2 行でも波は動かない。
    /// 見た目上は「1 行目の中心から waveOffset だけ下」に来るように合わせる。
    private var waveTopOffset: Double {
        let firstLineHalf = style.fontSize * 0.675
        return firstLineHalf + OverlayView.waveOffset - SpectrumWave.height / 2
    }

    /// 余白ぶんの押し戻し量。中央寄せのときは左右対称なのでずれない。
    private var waveShift: Double {
        switch style.alignment {
        case .left: return -SpectrumWave.margin
        case .center: return 0
        case .right: return SpectrumWave.margin
        }
    }

    /// 音の波。歌詞と重ねてよいので、背景として中央に敷く。
    private var wave: some View {
        SpectrumWave(spectrum: spectrum, style: style)
            .frame(width: SpectrumWave.width + SpectrumWave.margin * 2)
            // 波の左右の余白はフレームの内側にある。そのまま端を揃えると
            // 描画がその余白ぶん内側にずれるので、寄せた向きへ押し戻す。
            // 縦は歌詞と中央を揃えず、明確に下へ置く。
            // 振幅が大きいときに歌詞と重なるのは構わない。
            .offset(x: waveShift, y: waveTopOffset)
    }

    private var artworkFrame: (size: Double, offset: Double) {
        OverlayView.artFrame(
            style, title: model.trackInfo,
            time: model.timeText.isEmpty ? "0:00 / 0:00" : model.timeText)
    }

    @ViewBuilder
    private var info: some View {
        if OverlayView.usesCoreText {
            GlyphText(
                text: model.trackInfo, style: style, size: OverlayView.infoSize,
                opacity: 0.75, maxLines: 1)
        } else {
            OutlinedText(model.trackInfo, style: style, size: OverlayView.infoSize, opacity: 0.75,
                         lines: 1)
        }
    }

    /// 数字の字幅が一定とは限らないので、桁を 8 で埋めた文字列の幅を確保しておく。
    /// こうしないと 1 秒ごとに曲名の位置がわずかに動く。
    @ViewBuilder
    private var time: some View {
        if !model.timeText.isEmpty {
            Group {
                if OverlayView.usesCoreText {
                    GlyphText(
                        text: model.timeText, style: style, size: OverlayView.infoSize,
                        opacity: 0.6, maxLines: 1)
                } else {
                    OutlinedText(model.timeText, style: style, size: OverlayView.infoSize,
                                 opacity: 0.6, lines: 1)
                }
            }
            .frame(width: OverlayView.timeWidth(model.timeText, style: style))
        }
    }

    /// 時間表示に確保する幅。
    static func timeWidth(_ text: String, style: OverlayStyle) -> Double {
        guard !text.isEmpty else { return 0 }
        let widest = String(text.map { $0.isNumber ? "8" : $0 })
        return usesCoreText
            ? ceil(GlyphText.size(of: widest, style: style, size: infoSize, maxLines: 1).width)
            : ceil(style.width(of: widest, size: infoSize))
    }
}

/// 縁取り付きの文字を表示する。書体・色・縁の太さは `OverlayStyle` に従う。
///
/// 縁取りは Core Text にグリフのアウトラインをストロークさせる(文字をずらして
/// 重ねる擬似縁取りではない)。ただし `.strokeWidth` のストロークはパスの
/// **内側と外側に半分ずつ** かかるため、1 パスで描くと太さの半分が塗りを
/// 食い潰してしまう。そこで縁取りだけの層を後ろに、塗りだけの層を手前に重ねて
/// 描き、内側にはみ出した分を塗りで覆い隠している。2 つの層は同じ文字・同じ
/// レイアウトなのでグリフは完全に一致する。
struct OutlinedText: View {
    private let text: String
    @ObservedObject private var style: OverlayStyle
    /// 設定の文字サイズを使わず固定したいときだけ指定する。
    private let size: Double?
    private let opacity: Double
    private let lines: Int

    init(_ text: String, style: OverlayStyle, size: Double? = nil, opacity: Double = 1,
         lines: Int = 2) {
        self.text = text
        self.style = style
        self.size = size
        self.opacity = opacity
        self.lines = lines
    }

    var body: some View {
        ZStack {
            AttributedLabel(string: layer(stroke: true), lines: lines, sizeKey: key)
            AttributedLabel(string: layer(stroke: false), lines: lines, sizeKey: key)
        }
    }

    private func layer(stroke: Bool) -> NSAttributedString {
        style.attributed(text, size: size, stroke: stroke, opacity: opacity)
    }

    /// 大きさが決まる要素だけを並べた鍵。色や不透明度は含めない。
    private var key: String {
        "\(text)|\(size ?? style.fontSize)|\(style.fontFamily)|\(style.weight.rawValue)|\(lines)"
    }
}

/// 左から順に消え、左から順に現れる歌詞。
///
/// 文字を分割して並べたり自前でグリフを描いたりすると、字送りや描画品質が変わってしまう。
/// ここでは組版も描画も通常どおり Core Text に任せたまま、
/// **文字ごとの色の alpha だけ** を毎フレーム差し替えている。
///
/// SwiftUI の `.mask` は AppKit がホストするビューには効かず、
/// `withAnimation` も NSView の中身までは補間してくれないため、
/// 進行は開始時刻からの経過時間で自前に進める。
struct StaggeredText: View {
    let text: String
    @ObservedObject var style: OverlayStyle
    let start: Date
    let duration: Double
    let entering: Bool
    /// 行頭と行末の時間差。0 なら全文字が同時に動く。
    let stagger: Double
    /// 現れるときにせり上がる距離。0 なら動かさない。
    let rise: Double

    /// 消えていくときに沈み込む距離。落ちながら消えると、消失感が出る。
    private static let sink: Double = 7

    var body: some View {
        TimelineView(.periodic(from: start, by: 1.0 / 30.0)) { timeline in
            let progress = min(
                max(timeline.date.timeIntervalSince(start) / max(duration, 0.01), 0), 1)
            let count = max(text.count - 1, 1)
            let alpha: (Int) -> Double = { index in
                let position = Double(index) / Double(count)
                let local = min(max(progress * (1 + stagger) - stagger * position, 0), 1)
                return entering ? local : 1 - local
            }
            ZStack {
                let key = "\(text)|\(style.fontSize)|\(style.fontFamily)|\(style.weight.rawValue)|2"
                AttributedLabel(
                    string: style.attributed(text, stroke: true, alphaAt: alpha), sizeKey: key)
                AttributedLabel(
                    string: style.attributed(text, stroke: false, alphaAt: alpha), sizeKey: key)
            }
            .offset(y: entering ? rise * (1 - progress) : Self.sink * progress)
        }
    }
}

/// `NSAttributedString` をそのまま描くラベル。SwiftUI の `Text` は
/// `.strokeWidth` を解釈しないため AppKit に降りている。
struct AttributedLabel: NSViewRepresentable {
    let string: NSAttributedString
    /// 最大行数。1 なら折り返さず、必要な幅をそのまま要求する。
    var lines: Int = 2
    /// 寸法を使い回すための鍵。文字と書体が同じなら大きさも同じなので、
    /// 色だけが変わる演出中に測り直さずに済む(CTLine の生成は高くつく)。
    var sizeKey: String = ""

    private static var sizes: [String: CGSize] = [:]

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.maximumNumberOfLines = lines
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.maximumNumberOfLines = lines
        field.attributedStringValue = string
    }

    /// SwiftUI から提案された幅で折り返させ、必要な高さを返す。
    ///
    /// 1 行ものは提案幅で測ってはいけない。HStack の中では実際に必要な幅より
    /// 狭い提案が来ることがあり、その幅で確定して三点リーダに省略されてしまう。
    /// 折り返さないのだから、素の文字幅をそのまま要求する。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let key = sizeKey.isEmpty ? nil : "\(sizeKey)|\(proposal.width ?? -1)"
        if let key, let cached = Self.sizes[key] { return cached }
        let size = measure(proposal, field: field)
        if let key {
            // 曲が変われば歌詞も変わる。際限なく溜めない。
            if Self.sizes.count > 256 { Self.sizes.removeAll() }
            Self.sizes[key] = size
        }
        return size
    }

    private func measure(_ proposal: ProposedViewSize, field: NSTextField) -> CGSize {
        guard lines != 1 else {
            field.preferredMaxLayoutWidth = 0
            let size = string.size()
            return CGSize(width: ceil(size.width) + 2, height: ceil(size.height))
        }
        let width = proposal.width ?? field.preferredMaxLayoutWidth
        field.preferredMaxLayoutWidth = width.isFinite ? width : 0
        return field.fittingSize
    }
}
