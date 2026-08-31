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

    /// 拍の瞬間の山を写し取っておく入れ物。余韻を描くのに使う。
    @State private var echo = BeatEcho()

    /// バンドごとのレベル(0〜1)。低域から高域の順。
    private var levels: [Double] { spectrum.levels }
    /// 残光。levels より長く尾を引く値。光が消え残る表現に使う。
    private var afterglow: [Double] { spectrum.afterglow }

    /// 拍の脈。
    ///
    /// 拍の頭で弾けて減衰するのに加えて、**次の拍が来る手前から膨らみ始める**。
    /// グリッドは予測で刻んでいるので、次の拍がいつ来るかが分かっている。
    /// 反応するだけでは作れない「溜め」を入れられる。
    private var beatPulse: Double {
        let since = Date().timeIntervalSince(spectrum.beatAt)
        guard since >= 0, spectrum.bpm > 0 else { return 0 }
        let period = 60 / spectrum.bpm
        guard since < period * 2 else { return 0 }

        // 拍の頭からの減衰。
        let decay = exp(-since / Self.beatDecay)
        // 次の拍へ向けた溜め。周期の終盤で持ち上がる。
        let phase = min(1, since / period)
        let anticipation = smoothstep((phase - Self.anticipation) / (1 - Self.anticipation))
        return max(decay, anticipation * Self.anticipationDepth)
    }

    /// 拍の頭にどれだけ近いか(0〜1)。前後に少し幅を持たせる。
    private var beatNearness: Double {
        guard spectrum.bpm > 0 else { return 0 }
        let since = Date().timeIntervalSince(spectrum.beatAt)
        guard since >= 0 else { return 0 }
        let period = 60 / spectrum.bpm
        guard since < period * 2 else { return 0 }
        // 直前の拍からの距離と、次の拍までの距離の近いほう。
        let distance = min(since, max(0, period - since))
        return 1 - smoothstep(distance / Self.beatWindow)
    }

    private func smoothstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 表示の高さ。光の放射ぶんも含む。歌詞の背後に回すので大きく取る。
    static let height: Double = 320
    /// 表示の幅。曲名の長さに合わせると短い曲で詰まるので固定にする。
    static let width: Double = 420
    /// 波形の左右に確保する余白。ここが無いと端で光が切れる。
    /// 描画は外へ広げ、レイアウト上の幅は変えない(呼び出し側が負の余白で戻す)。
    static let margin: Double = 22

    /// この強さを下回ると消え始め、下限で完全に消える。
    private static let presenceLow: Double = 0.015
    private static let presenceHigh: Double = 0.09

    /// 白い芯の大きさ(光源に対する比)・濃さ・にじみ。
    private static let coreScale: Double = 0.55
    private static let coreOpacity: Double = 0.75
    private static let coreBlur: Double = 3
    /// 拍の閃光で使う輪郭の太さ。
    private static let coreGlowWidth: Double = 7

    /// 光源(白い波形)が使う高さの比。残りは光の放射に使う。
    private static let sourceScale: Double = 0.78
    /// 拍の脈の減衰時間(秒)と、そのときの膨らみ・明るさ。
    private static let beatDecay: Double = 0.16
    private static let beatSwell: Double = 0.12
    private static let beatFlash: Double = 0.25
    /// 拍の頭とみなす時間の幅(秒)。ぴったり合うことはないので、少し持たせる。
    private static let beatWindow: Double = 0.11
    /// 拍で波形に加えるひずみの深さと、その減衰(秒)。
    private static let distortDepth: Double = 0.55
    private static let distortDecay: Double = 0.13
    /// 余韻の長さ(秒)。棘・波紋・光の粒はこの時間をかけて消える。
    private static let echoLife: Double = 1.4
    /// 打った瞬間の閃光の減衰(秒)と大きさ。
    private static let burstDecay: Double = 0.07
    private static let burstRadius: Double = 46
    /// 溜めを始める位置(周期に対する比)と、その深さ。
    private static let anticipation: Double = 0.58
    private static let anticipationDepth: Double = 0.55

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
    ///
    /// 曲ごとにアルバムカバーから色相を借りる案も試したが、
    /// ネオン管の質感はこのマゼンタ〜シアンの並びが一番出るので固定する。
    private var hues: [Color] {
        Self.hues
    }

    static let hues: [Color] = [
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

    /// 描画に使う値。弱い帯域を沈めて、山と谷の差を広げ、拍でひずませる。
    private var values: [Double] {
        var result = levels.map { pow(min(max($0, 0), 1), Self.contrast) }
        if Self.debugPinTop, !result.isEmpty { result[result.count - 1] = 0.9 }

        // 拍の瞬間、波形にひずみを乗せる。
        //
        // 全体を一様に大きくしても、大きくなったことしか伝わらない。
        // 場所によって伸びたり縮んだりさせると、形そのものが暴れて
        // 一瞬だけ別のものになる。そのほうが衝撃として伝わる。
        let strain = distortion
        guard strain.amount > 0.001, result.count > 1 else { return result }
        let last = Double(result.count - 1)
        return result.enumerated().map { index, value in
            let x = Double(index) / last
            // 周期の違う波を重ねて、規則的な模様に見えないようにする。
            let noise = sin(x * 9 + strain.seed) * 0.6
                + sin(x * 17 + strain.seed * 2.3) * 0.3
                + sin(x * 31 + strain.seed * 4.1) * 0.2
            return max(0, value * (1 + noise * strain.amount))
        }
    }

    /// 拍で加えるひずみの強さと、その拍ごとの形。
    private var distortion: (amount: Double, seed: Double) {
        let since = Date().timeIntervalSince(spectrum.beatAt)
        guard since >= 0, since < 1 else { return (0, 0) }
        let amount = exp(-since / Self.distortDecay)
            * spectrum.beatStrength * Self.distortDepth
        // 拍ごとに違うひずみ方にする。
        return (amount, Double(spectrum.beatCount % 89) * 0.7)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        if Self.debugBackground {
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.red.opacity(0.18)))
        }
        guard values.count > 1 else { return }

        // 音が無ければ何も描かない。
        //
        // 輪郭だけを描く作りなので、振幅が 0 になると上下の輪郭が中心線で
        // 重なり、白い横線として残ってしまう。曲の終わりは光がすっと消えて
        // 何も残らないのが正しいので、全体の強さで濃さを落とす。
        let presence = smoothstep((values.max() ?? 0 - Self.presenceLow)
            / (Self.presenceHigh - Self.presenceLow))
        guard presence > 0.01 else { return }

        context.blendMode = .plusLighter
        context.opacity = presence

        let gradient = Gradient(colors: hues)
        let pulse = beatPulse

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
                    shape(in: size, scale: layer.scale * (1 + pulse * Self.beatSwell),
                          values: values),
                    with: .linearGradient(
                        gradient,
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)))
                inner.opacity = layer.opacity
            }
        }

        // 白い芯。
        //
        // 輪郭線ではなく塗りで描く。線だと振幅が 0 になったときに上下が
        // 中心で重なり、白い横線が残り続けてしまう。塗りなら面積が 0 に
        // なって消えるので、曲が終われば何も残らない。
        context.drawLayer { inner in
            inner.addFilter(.blur(radius: Self.coreBlur))
            inner.fill(
                shape(in: size, scale: Self.coreScale, values: values),
                with: .color(.white.opacity(Self.coreOpacity)))
        }


        // 拍の頭の近くでは、そのとき立っている山を強調する。
        drawBeatAccents(in: &context, size: size)
    }

    /// 横位置(0〜1)に対応する色。低域から高域へ滑らかに移る。
    private func hue(at ratio: Double) -> Color {
        let hues = self.hues
        let position = min(max(ratio, 0), 1) * Double(hues.count - 1)
        let index = min(Int(position), hues.count - 2)
        let fraction = CGFloat(position - Double(index))
        let a = NSColor(hues[index]).usingColorSpace(.deviceRGB) ?? .white
        let b = NSColor(hues[index + 1]).usingColorSpace(.deviceRGB) ?? .white
        return Color(nsColor: NSColor(
            red: a.redComponent + (b.redComponent - a.redComponent) * fraction,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * fraction,
            alpha: 1))
    }

    /// 拍を、波形全体の衝撃として描く。
    ///
    /// 拍は特定の帯域ではなく波形全体として現れるので、山を選んで飾るのではなく
    /// **その瞬間の波形そのもの** を広げて光らせる。
    /// 稜線の上に白を重ねても、加算合成では既に飽和していて見えないため、
    /// 外側へ広がる形にして背景の上で光らせる。
    private func drawBeatAccents(in context: inout GraphicsContext, size: CGSize) {
        guard values.count > 2 else { return }
        echo.capture(
            at: spectrum.beatAt, strength: spectrum.beatStrength,
            life: Self.echoLife, values: values)
        guard !echo.impacts.isEmpty else { return }

        let now = Date()
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            for impact in echo.impacts {
                let age = max(0, now.timeIntervalSince(impact.at))
                guard age < Self.echoLife else { continue }
                let fade = pow(1 - age / Self.echoLife, 1.6) * impact.strength

                flash(&layer, in: size, impact: impact, age: age)
                shockwave(&layer, in: size, impact: impact, age: age, fade: fade)
            }
        }
    }

    /// 打った瞬間の閃光。波形そのものを白く飛ばし、すぐ引く。
    private func flash(
        _ context: inout GraphicsContext, in size: CGSize,
        impact: BeatEcho.Impact, age: Double
    ) {
        let intensity = exp(-age / Self.burstDecay) * impact.strength
        guard intensity > 0.01 else { return }
        context.stroke(
            shape(in: size, scale: 1 + age * 1.5, values: impact.values),
            with: .color(.white.opacity(intensity * 0.9)),
            style: StrokeStyle(lineWidth: Self.coreGlowWidth * 1.4, lineJoin: .round))
    }

    /// 波形の輪郭が、外へ向かって広がっていく衝撃波。
    private func shockwave(
        _ context: inout GraphicsContext, in size: CGSize,
        impact: BeatEcho.Impact, age: Double, fade: Double
    ) {
        // 勢いよく広がって失速する。等速だと機械的に見える。
        let expansion = 1 - exp(-age * 4)
        for (reach, weight) in [(1.9, 1.0), (1.4, 0.6)] {
            let scale = 1 + expansion * (reach - 1)
            context.stroke(
                shape(in: size, scale: scale, values: impact.values),
                with: .linearGradient(
                    Gradient(colors: hues.map { $0.opacity(fade * weight) }),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)),
                lineWidth: max(0.6, 3.5 * (1 - age / Self.echoLife)))
        }
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
        let strain = distortion

        // 上下で違う歪ませ方をする。左右対称のまま高さだけ変えても、
        // 大きくなったことしか伝わらない。中心線を波打たせ、上下の伸びを
        // 変え、横にもずらすことで、**概形そのもの** が一瞬別の形になる。
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        for index in 0..<count {
            let x = Double(index) / Double(count - 1)
            let value = index == 0 || index == count - 1 ? 0 : min(1.5, all[index - 1])
            let height = value * amplitude

            guard strain.amount > 0.001 else {
                let px = Self.margin + x * inner
                upper.append(CGPoint(x: px, y: midY - height))
                lower.append(CGPoint(x: px, y: midY + height))
                continue
            }

            // 端は動かさない。動かすと波が枠から外れて見える。
            let envelope = sin(x * .pi)
            let seed = strain.seed
            // 中心線のうねり。
            let spine = (sin(x * 6 + seed) * 0.6 + sin(x * 13 + seed * 1.7) * 0.4)
                * strain.amount * amplitude * 0.5 * envelope
            // 上下それぞれの伸び。位相をずらして対称を崩す。
            let top = 1 + (sin(x * 9 + seed * 2.1) * 0.7 + sin(x * 19 + seed * 3.3) * 0.3)
                * strain.amount * envelope
            let bottom = 1 + (sin(x * 11 + seed * 1.3) * 0.7 + sin(x * 23 + seed * 2.7) * 0.3)
                * strain.amount * envelope
            // 横へのずれ。縦だけだと「伸び縮み」に見えてしまう。
            let shift = sin(x * 8 + seed * 4.7) * strain.amount * inner * 0.03 * envelope

            let px = Self.margin + x * inner + shift
            upper.append(CGPoint(x: px, y: midY + spine - height * max(0, top)))
            lower.append(CGPoint(x: px, y: midY + spine + height * max(0, bottom)))
        }

        var path = Path()
        path.move(to: upper[0])
        spline(&path, through: upper)
        path.addLine(to: lower[count - 1])
        spline(&path, through: lower.reversed())
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
