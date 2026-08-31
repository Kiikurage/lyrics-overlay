import Accelerate
import CoreAudio

/// 解析の結果。
struct AudioSnapshot {
    /// バンドごとのレベル(0〜1)。
    let levels: [Double]
    /// 残光。levels より長く尾を引く。
    let afterglow: [Double]
    /// 全体の大きさ(0〜1)。
    let loudness: Double
    /// この解析で音の立ち上がりを検出したか(オンセット)。
    let beat: Bool
    /// 拍の頭に当たるか。テンポから予測した拍のグリッド上の点。
    let tick: Bool
    /// その拍の強さ(0〜1)。直前の平均に対して、どれだけ音が立っているか。
    let tickStrength: Double
    /// 推定 BPM。取れていなければ 0。
    let bpm: Double
}

/// PCM を溜めて FFT にかけ、対数間隔のバンドごとのレベルにする。
/// オーディオスレッドから呼ばれるので、確保や同期は避けている。
final class SpectrumAnalyzer {
    /// FFT の点数。48kHz なら 2048 点で約 43ms ぶん。
    /// 低域の分解能(1 ビン ≒ 23Hz)を確保するためにこの大きさにしている。
    private static let size = 2048
    private static let log2n = vDSP_Length(11)
    /// 解析の間隔(サンプル数)。窓の 1/8 ずつずらして重ねて解析する。
    ///
    /// 窓ぶん(43ms)溜まるまで待つと、その間に起きた立ち上がりは
    /// 最大 43ms 遅れて出る。窓は重ねたまま間隔だけ詰めることで、
    /// 周波数の分解能を落とさずに反応を速くする。48kHz で約 5.3ms。
    private static let hop = 256

    private let bandCount: Int
    private var setup: FFTSetup?
    private var window = [Float](repeating: 0, count: size)
    private var ring = [Float](repeating: 0, count: size)
    /// 前回の解析以降に溜まったサンプル数。
    private var pending = 0
    private var writeIndex = 0

    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var magnitudes = [Float](repeating: 0, count: size / 2)
    /// バンドごとの重み(三角窓)。隣のバンドと半分ずつ重なる。
    private var filters: [(start: Int, weights: [Float])] = []
    /// 直前の値。跳ねを抑えるために鈍らせる。
    private var smoothed: [Double]
    /// 残光。同じ値を、より長い時定数で減衰させたもの。
    private var afterglow: [Double]
    /// バンドごとの持ち上げ量(dB)。中心周波数から決まる固定値。
    private var tilts: [Double] = []

    /// テンポ推定用。低域の刻みを間引いて溜めた時系列。
    private var envelope = [Double](repeating: 0, count: 256)
    private var envelopeIndex = 0
    private var envelopeTime: Double = 0
    private var decimateSum: Double = 0
    private var decimateCount = 0
    private var framesUntilEstimate = 0
    private var previousLow: Double = 0
    private var bpm: Double = 0
    /// いまのテンポを保っている期間と、乗り換え候補の継続回数。
    private var bpmSince: Double = 0
    /// 拍の間隔。位相を合わせた時点で固定する。
    private var gridPeriod: Double = 0
    /// 帯域ごとの平常時の値(長い窓)。鳴っている帯域かどうかの判断に使う。
    private var baseline: [Double]
    /// 帯域ごとの直前の水準(短い窓)。拍の立ち上がりはこれとの差で見る。
    private var recent: [Double]
    /// 帯域ごとの直近の山。拍の前後をまとめて見るために、ゆっくり減衰させる。
    private var bandPeak: [Double]
    /// 拍の判定を待っているグリッド上の時刻。
    /// 拍の瞬間ではなく、その前後をまとめて見てから強さを決める。
    private var pendingTick: Double = 0
    private var pendingBPM: Double = 0
    private var pendingCount = 0
    /// 予測している次の拍の時刻(elapsed 基準)。
    private var nextTick: Double = 0
    private var elapsed: Double = 0
    private var frameDuration: Double = 0.043
    /// 残光の時定数(秒)。短いほうが表示本体、長いほうが尾。
    private static let persistence = 0.22
    private static let slowPersistence = 0.9
    /// 小さな変化を追うときの時定数(秒)。大きな変化はこれを通さず即座に反映する。
    private static let attack = 0.06
    /// この幅を超える立ち上がりは、鈍らせずそのまま採る。
    private static let jumpLow = 0.04
    private static let jumpHigh = 0.13
    /// 全体が静かになったときに閉じるゲートの範囲。
    private static let gateLow = 0.05
    private static let gateHigh = 0.13
    /// ゲートが開くとき / 閉じるときの時定数(秒)。閉じるのはゆっくり。
    private static let gateOpen = 0.04
    private static let gateClose = 0.7
    /// テンポの探索範囲と刻み。
    private static let minBPM = 60.0
    private static let maxBPM = 200.0
    private static let bpmStep = 0.5
    /// 刻みの時系列をどれだけ間引くか(4 で約 47Hz)。
    private static let decimation = 4
    /// 推定を回す間隔(間引き後のサンプル数)。約 0.25 秒ごと。
    private static let estimateInterval = 12
    /// 候補の平均に対して、これだけ突出していれば採用する。
    private static let minConfidence = 1.8
    /// 拍の階層と、その重み。1 が拍そのもの。
    private static let metricalLevels: [(Double, Double)] = [
        (0.25, 0.25),  // 全音符
        (0.5, 0.5),    // 2 分音符
        (1, 1.0),      // 拍
        (2, 0.6),      // 8 分音符
        (4, 0.3),      // 16 分音符
    ]
    /// 乗り換えの前に、同じ候補が何回続けば良いか(1 回 ≒ 0.25 秒)。
    private static let pendingRequired = 8
    /// 拍の前後をどれだけ見るか(秒)。
    /// この時間ぶん判定を遅らせるが、そのぶん取りこぼさない。
    private static let beatWindow: Double = 0.06
    /// 帯域ごとの平常時を測る時定数(秒)。鳴っている帯域かどうかの判断用。
    private static let baselineWindow: Double = 1.6
    /// 直前の水準を測る時定数(秒)。一撃そのものに引きずられない程度に短く。
    private static let recentWindow: Double = 0.28
    /// 直前の水準からの増分が、これを超えれば立ったとみなす。
    /// 音圧の高いところでは比が効かないので、こちらが効く。
    private static let riseThreshold: Double = 0.045
    /// 帯域ごとの山を保つ時定数(秒)。拍の前後をまとめて見るため。
    private static let peakHold: Double = 0.07
    /// 立ち上がったとみなす、平常時に対する比。
    private static let bandRatio: Double = 1.25
    /// 比を取る対象とする、平常時の下限。
    private static let bandFloor: Double = 0.05
    /// 立ち上がった帯域の割合が、これだけあれば拍とみなす。
    private static let hitFractionLow: Double = 0.1
    private static let hitFractionHigh: Double = 0.45

    /// Spotify 内の音量(0〜100)。これを打ち消して、音量設定に依存しないようにする。
    ///
    /// プロセスタップが拾うのは、Spotify がアプリ内の音量を適用した後の信号。
    /// 自動ゲインで後追いすると、曲の頭やブレイクで基準がずれて破綻するが、
    /// 音量そのものが分かるなら、その場で正確に打ち消せる。
    var volume: Double = 100

    /// 揃える先の音量。この音量で再生したときの見た目に、他の音量を合わせる。
    private static let volumeReference = 50.0
    /// 音量スライダーと実際の振幅の関係(振幅 ∝ 音量^curve)。
    ///
    /// スライダーは線形ではない。音量を変えながら最大バンドの値を測ったところ、
    /// 100 → 49 で -9.9dB、100 → 24 で -20.8dB だった(線形なら -6.0 / -12.4dB)。
    /// どちらからも指数はおよそ 2.6 になるが、実際に見ると大音量側がまだ
    /// 大きかったので、見た目に合わせて 3.2 にしている。
    /// 平均ではなく最大バンドで測るのは、弱いバンドが下限に張り付いて
    /// 平均を余分に下げるため。
    private static let volumeCurve = 3.2
    /// 持ち上げの上限(dB)。音量を絞りきったときに雑音まで増幅しないように。
    private static let volumeCeiling = 20.0

    /// 音量ぶんの補正(dB)。基準より大きければ下げ、小さければ持ち上げる。

    private var volumeCompensation: Double {
        let compensation = 20 * Self.volumeCurve * log10(Self.volumeReference / max(volume, 1))
        return min(compensation, Self.volumeCeiling)
    }


    /// 高域の持ち上げ(dB / オクターブ)。
    ///
    /// 自然な音のスペクトルは高域へ向かって概ね一定の傾きで下がる
    /// (ピンクノイズで -3dB/oct)。その傾きを打ち消すぶんだけ、
    /// 周波数に応じて縦方向の倍率を上げる。
    /// 各帯域の相対関係は保たれるので、実際の山がぼけることはない。
    private static let tiltPerOctave = 4.5

    private var decay: Double { exp(-frameDuration / Self.persistence) }
    private var slowDecay: Double { exp(-frameDuration / Self.slowPersistence) }
    private var rise: Double { 1 - exp(-frameDuration / Self.attack) }

    /// 無音に近づいたときに全体を滑らかに閉じるための係数。
    private var gate: Double = 0

    init(bandCount: Int) {
        self.bandCount = bandCount
        smoothed = [Double](repeating: 0, count: bandCount)
        baseline = [Double](repeating: 0, count: bandCount)
        recent = [Double](repeating: 0, count: bandCount)
        bandPeak = [Double](repeating: 0, count: bandCount)
        afterglow = [Double](repeating: 0, count: bandCount)
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    /// バンドごとの重みを、対数間隔の三角窓として用意する。
    ///
    /// 帯域内の最大値を代表値にすると、山のビンが隣の帯域へ移った瞬間に
    /// 値が飛び、グラフが折れ線状に見える。隣のバンドと半分ずつ重なる
    /// 三角窓で重み付き平均を取ると、周波数方向に連続した値になる。
    func prepare(sampleRate: Double) {
        // 減衰などの時定数は「解析の間隔」で決まる。窓の長さではない。
        frameDuration = Double(Self.hop) / sampleRate
        // 音楽が実際に鳴っている範囲に絞る。ナイキスト周波数まで取ると、
        // 右半分がほぼ無音の領域になって波形が左に寄って見えるため。
        let low = 60.0, high = min(6_000.0, sampleRate / 2 - 1)
        let binWidth = sampleRate / Double(Self.size)
        let maxBin = Self.size / 2 - 1

        // 中心周波数は対数等間隔。両隣の中心までを裾とする。
        func center(_ index: Double) -> Double {
            let ratio = index / Double(bandCount - 1)
            return low * pow(high / low, ratio)
        }

        // 窓の裾をどこまで伸ばすか(隣のバンド何個ぶんか)。
        // 広げるほど値は連続的になるが、山の位置がぼける。
        // 隣とわずかに重なる程度に留めて、ピークの位置を残す。
        let overlap = 1.15
        // 中心周波数が低域から何オクターブ上かで持ち上げ量を決める。
        tilts = (0..<bandCount).map { band in
            let octaves = log2(center(Double(band)) / low)
            return Self.tiltPerOctave * octaves
        }

        filters = (0..<bandCount).map { band in
            let lower = center(Double(band) - overlap), upper = center(Double(band) + overlap)
            let start = max(1, min(maxBin, Int(lower / binWidth)))
            let end = max(start + 1, min(maxBin, Int(ceil(upper / binWidth))))
            let peak = center(Double(band))

            let weights: [Float] = (start...end).map { bin in
                let frequency = Double(bin) * binWidth
                // 対数軸上での距離から三角窓を作る。
                let distance = abs(log(frequency / peak)) / log(upper / peak)
                return Float(max(0, 1 - distance))
            }
            return (start, weights)
        }
    }

    /// バッファを取り込み、FFT 1 回ぶん溜まったらレベルを返す。
    func consume(_ buffers: UnsafeMutableAudioBufferListPointer) -> AudioSnapshot? {
        guard setup != nil, !filters.isEmpty else { return nil }

        // ステレオでも 1ch に混ぜてしまう。表示に使うだけなので十分。
        var result: AudioSnapshot?
        // 1 回の呼び出しで複数回解析することがある。返せるのは最後の 1 つだけなので、
        // 途中で立った拍を落とさないよう、フラグはまとめて持ち越す。
        var tickSeen = false
        var pendingStrength = 0.0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.bindMemory(to: Float.self, capacity: count)
            for index in stride(from: 0, to: count, by: Int(max(buffer.mNumberChannels, 1))) {
                // 直近 size サンプルを常に保持する環状バッファ。
                ring[writeIndex] = samples[index]
                writeIndex = (writeIndex + 1) % Self.size
                pending += 1
                if pending >= Self.hop {
                    pending = 0
                    if let snapshot = analyze() {
                        if snapshot.tick {
                            tickSeen = true
                            pendingStrength = max(pendingStrength, snapshot.tickStrength)
                        }
                        result = snapshot
                    }
                }
            }
            // 1 つ目のバッファ(または 1 つ目のチャンネル)だけで足りる。
            break
        }

        guard let snapshot = result else { return nil }
        guard tickSeen, !snapshot.tick else { return snapshot }
        return AudioSnapshot(
            levels: snapshot.levels, afterglow: snapshot.afterglow,
            loudness: snapshot.loudness, beat: true, tick: true,
            tickStrength: pendingStrength, bpm: snapshot.bpm)
    }

    private func analyze() -> AudioSnapshot? {
        guard let setup else { return nil }

        // 環状バッファを古い順に並べ直してから窓を掛ける。
        var frame = [Float](repeating: 0, count: Self.size)
        let tail = Self.size - writeIndex
        frame.replaceSubrange(0..<tail, with: ring[writeIndex..<Self.size])
        frame.replaceSubrange(tail..<Self.size, with: ring[0..<writeIndex])

        var windowed = [Float](repeating: 0, count: Self.size)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))

        var levels = [Double](repeating: 0, count: bandCount)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: Self.size / 2
                    ) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(Self.size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(Self.size / 2))
            }
        }

        for band in 0..<bandCount {
            let filter = filters[band]
            var sum: Float = 0
            var total: Float = 0
            for (offset, weight) in filter.weights.enumerated() {
                let bin = filter.start + offset
                guard bin < magnitudes.count else { break }
                sum += magnitudes[bin] * weight
                total += weight
            }
            sum = total > 0 ? sum / total : 0

            // 振幅 → dB。おおよそ -60dB〜0dB を 0〜1 に写す。
            // 自然な音は高域ほどエネルギーが小さい(ピンクノイズ的な傾き)ので、
            // そのまま描くと右半分が死ぬ。帯域の位置に応じて持ち上げる。
            let decibels = 20 * log10(Double(sum) / Double(Self.size) + 1e-9)
                + tilts[band] + volumeCompensation
            let normalized = min(max((decibels + 60) / 60, 0), 1)

            // 帯域ごとに、最近のピークを基準にした倍率を掛ける。
            // 低域はエネルギーが大きく高域は小さいため、そのまま描くと
            // いつも左だけが高い形になる。各帯域が自分の直近の実績を
            // 基準に伸縮すれば、どの帯域も同じくらいの高さまで振れる。
            // 蛍光体の残光と同じ扱い。暗くなるときは指数的に尾を引く。
            //
            // 明るくなるときは変化の大きさで扱いを変える。音が立ち上がった
            // ような大きな変化はそのまま採り(遅延なし)、雑音による小さな
            // ゆらぎだけを鈍らせる。一律に鈍らせるとピークが遅れて感じられ、
            // 一律に即座だと 1 フレームの雑音が瞬きになる。
            let decayed = smoothed[band] * decay
            if normalized > decayed {
                let jump = normalized - decayed
                let immediacy = smoothstep(jump, from: Self.jumpLow, to: Self.jumpHigh)
                let follow = immediacy + (1 - immediacy) * rise
                smoothed[band] = decayed + jump * follow
            } else {
                smoothed[band] = decayed
            }
            let slowDecayed = afterglow[band] * slowDecay
            afterglow[band] = max(smoothed[band], slowDecayed)
            levels[band] = smoothed[band]
        }

        // 仕上げの平滑化。中心の重みを大きくして、山の高さと位置を残したまま
        // 隣との段差だけを取る(1-6-1 の重み)。
        var shaped = levels
        var shapedGlow = afterglow
        for band in 1..<(bandCount - 1) {
            shaped[band] = (levels[band - 1] + levels[band] * 6 + levels[band + 1]) / 8
            shapedGlow[band] =
                (afterglow[band - 1] + afterglow[band] * 6 + afterglow[band + 1]) / 8
        }
        levels = shaped
        var glow = shapedGlow

        // 無音に近いところでは、正規化のせいで雑音がそのまま形になって
        // 瞬いてしまう。全体の大きさでゲートを掛け、静かになったら
        // ゆっくり閉じる。曲の終わりはこれで滑らかに消える。
        let raw = levels.reduce(0, +) / Double(bandCount)
        let target = smoothstep(raw, from: Self.gateLow, to: Self.gateHigh)
        let constant = target > gate ? Self.gateOpen : Self.gateClose
        gate += (target - gate) * (1 - exp(-frameDuration / constant))
        for band in levels.indices {
            levels[band] *= gate
            glow[band] *= gate
        }

        elapsed += frameDuration
        updateTempo()

        let loudness = levels.reduce(0, +) / Double(bandCount)
        updateBandStatistics(levels)

        if advanceBeatGrid() { pendingTick = elapsed }
        let tick = pendingTick > 0 && elapsed - pendingTick >= Self.beatWindow
        let strength = tick ? beatStrength() : 0
        if tick { pendingTick = 0 }
        return AudioSnapshot(
            levels: levels, afterglow: glow, loudness: loudness,
            beat: tick, tick: tick, tickStrength: strength, bpm: bpm)
    }

    private func smoothstep(_ value: Double, from low: Double, to high: Double) -> Double {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 低域の刻みを溜めて、候補 BPM ごとの当てはまりを採点する。
    ///
    /// 打点の間隔から求める方法は、16 分のハイハットが刻む曲で破綻する。
    /// 個々の音が拍かどうかを判断せず、**低域の強さの時間変化そのものに
    /// どの周期が乗っているか** を見るほうが安定する。
    /// キックは拍の頭に置かれることが多いので、低域だけを見れば十分。
    private func updateTempo() {
        // 止まっている間は溜めない。無音を混ぜると周期が壊れる。
        guard gate > 0.3 else { return }

        // 低域(おおよそ 250Hz 以下)の増加ぶんを刻みとして溜める。
        let low = smoothed.prefix(bandCount / 3).reduce(0, +) / Double(bandCount / 3)
        decimateSum += max(0, low - previousLow)
        previousLow = low
        decimateCount += 1

        guard decimateCount >= Self.decimation else { return }
        envelope[envelopeIndex] = decimateSum / Double(Self.decimation)
        envelopeIndex = (envelopeIndex + 1) % envelope.count
        decimateSum = 0
        decimateCount = 0
        envelopeTime = elapsed

        framesUntilEstimate -= 1
        guard framesUntilEstimate <= 0 else { return }
        framesUntilEstimate = Self.estimateInterval
        estimateTempo()
    }

    /// 帯域ごとの平常時の値と、直近の山を更新する。
    private func updateBandStatistics(_ levels: [Double]) {
        let settle = 1 - exp(-frameDuration / Self.baselineWindow)
        let follow = 1 - exp(-frameDuration / Self.recentWindow)
        let release = exp(-frameDuration / Self.peakHold)
        for band in levels.indices {
            baseline[band] += (levels[band] - baseline[band]) * settle
            recent[band] += (levels[band] - recent[band]) * follow
            bandPeak[band] = max(levels[band], bandPeak[band] * release)
        }
    }

    /// その拍で、実際に音が来たかを測る。
    ///
    /// 全帯域の合計で見ると、拍に来ない楽器(持続するパッドや伸ばした声)の
    /// 音量変化まで判定に混ざる。そこで **帯域ごとに** 平常時と比べ、
    /// 立ち上がった帯域が全体の何割あるかで判断する。
    /// 打楽器の一撃は広い帯域を一斉に持ち上げるので、こちらのほうが素直に出る。
    ///
    /// 拍かどうかはテンポのグリッドが決める。ここで見るのは時間方向の突出で、
    /// どの帯域が目立つか(周波数方向の突出)ではない。
    private func beatStrength() -> Double {
        var hits = 0.0
        var counted = 0.0
        for band in bandPeak.indices {
            // ほとんど鳴っていない帯域は、比較しても雑音にしかならない。
            guard baseline[band] > Self.bandFloor else { continue }
            counted += 1

            // 立ち上がりは 2 通りで見る。
            //
            // 静かなところでは比がよく効く。一方、サビのように音圧の高い
            // ところでは各帯域が上限近くに張り付いていて、実際に一撃が来ても
            // 比はほとんど動かない(3dB 上がっても 0.05 程度)。そこで
            // 「直前の水準からの増分」も見て、どちらかを満たせば立ったとみなす。
            let rise = bandPeak[band] - recent[band]
            let ratio = recent[band] > 0.01 ? bandPeak[band] / recent[band] : 1
            if rise > Self.riseThreshold || ratio > Self.bandRatio { hits += 1 }
        }
        guard counted > 0 else { return 0 }

        let fraction = hits / counted
        return smoothstep(fraction, from: Self.hitFractionLow, to: Self.hitFractionHigh)
    }

    /// 曲が変わったときに、テンポの推定をやり直す。
    ///
    /// テンポも位相も曲ごとのものなので、前の曲の値を引き継いではいけない。
    /// 保持時間による乗り換えの抑制も、ここで解除しておく必要がある
    /// (前の曲のテンポを長く保持していると、新しい曲のテンポに移れなくなる)。
    func resetTempo() {
        bpm = 0
        bpmSince = 0
        pendingBPM = 0
        pendingCount = 0
        pendingTick = 0
        nextTick = 0
        gridPeriod = 0
        envelope = [Double](repeating: 0, count: envelope.count)
        envelopeIndex = 0
        decimateSum = 0
        decimateCount = 0
        previousLow = 0
    }

    /// 候補 BPM それぞれについて、低域の刻みとの当てはまりを測る。
    private func estimateTempo() {
        let rate = 1 / (frameDuration * Double(Self.decimation))
        let count = envelope.count

        // 古い順に並べ直し、平均を引いて直流成分を落とす。
        var samples = [Double](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = envelope[(envelopeIndex + i) % count]
        }
        let mean = samples.reduce(0, +) / Double(count)
        guard mean > 0 else { return }
        for i in 0..<count { samples[i] -= mean }

        var best = (bpm: 0.0, score: 0.0, phase: 0.0)
        var total = 0.0
        var candidates = 0

        var candidate = Self.minBPM
        while candidate <= Self.maxBPM {
            let result = score(bpm: candidate, samples: samples, rate: rate)
            total += result.score
            candidates += 1
            if result.score > best.score {
                best = (candidate, result.score, result.phase)
            }
            candidate += Self.bpmStep
        }

        guard candidates > 0, best.score > 0 else { return }
        let confidence = best.score / (total / Double(candidates))
        guard confidence > Self.minConfidence else { return }

        adopt(best: best, samples: samples, rate: rate)
        lockPhase(bpm: bpm, phase: bestPhase(for: bpm, samples: samples, rate: rate), rate: rate)
    }

    /// 候補 BPM の当てはまり。
    ///
    /// 拍そのものだけでなく、**拍の階層**(全音符・2分・8分・16分)にも
    /// エネルギーがあるかを見る。本物のテンポは、どの階層にもそれなりの
    /// 裏付けがある。一方、4つ打ちから PPPH のようにリズムが変わったときに
    /// 現れる 3/4 倍などの偽の候補は、その周期にしか山がなく、
    /// 階層に支持されないので分が悪くなる。
    private func score(bpm: Double, samples: [Double], rate: Double)
        -> (score: Double, phase: Double) {
        var sum = 0.0
        var beatPhase = 0.0
        for (ratio, weight) in Self.metricalLevels {
            let (magnitude, phase) = component(
                frequency: bpm / 60 * ratio, samples: samples, rate: rate)
            sum += magnitude * weight
            if ratio == 1 { beatPhase = phase }
        }
        // 極端に速い / 遅いテンポは、人が拍と感じにくいので少し割り引く。
        let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.6, 2))
        return (sum * prior, beatPhase)
    }

    private func bestPhase(for bpm: Double, samples: [Double], rate: Double) -> Double {
        component(frequency: bpm / 60, samples: samples, rate: rate).phase
    }

    /// 指定周波数の成分(離散フーリエ変換の 1 点)。
    ///
    /// 候補ごとに三角関数を呼ぶと高くつくので、1 サンプルぶんの回転を
    /// 掛け続けることで済ませる。
    private func component(frequency: Double, samples: [Double], rate: Double)
        -> (magnitude: Double, phase: Double) {
        let step = 2 * Double.pi * frequency / rate
        let stepCos = cos(step), stepSin = sin(step)
        var rotationCos = 1.0, rotationSin = 0.0
        var real = 0.0, imaginary = 0.0

        for sample in samples {
            real += sample * rotationCos
            imaginary -= sample * rotationSin
            let nextCos = rotationCos * stepCos - rotationSin * stepSin
            rotationSin = rotationCos * stepSin + rotationSin * stepCos
            rotationCos = nextCos
        }
        return (sqrt(real * real + imaginary * imaginary), atan2(imaginary, real))
    }

    /// 推定結果を採用するかどうかを決める。
    ///
    /// テンポは曲中でそう何度も変わらない。一方、リズムパターンの変化では
    /// 別の周期が一時的に強く出る。そこで、いまのテンポを保っている時間が
    /// 長いほど乗り換えに高い基準を課し、さらに同じ候補が数回続いたときだけ
    /// 乗り換える。こうすると、Bメロで一瞬 3/4 倍が強く出ても動じない。
    private func adopt(best: (bpm: Double, score: Double, phase: Double),
                       samples: [Double], rate: Double) {
        guard bpm > 0 else {
            bpm = best.bpm
            bpmSince = elapsed
            return
        }

        // ほぼ同じテンポなら、少しだけ寄せて精度を上げる。
        if abs(best.bpm - bpm) / bpm < 0.03 {
            bpm = bpm * 0.9 + best.bpm * 0.1
            pendingCount = 0
            return
        }

        let current = score(bpm: bpm, samples: samples, rate: rate).score
        let tenure = elapsed - bpmSince
        // 保持が長いほど、乗り換えに必要な差を大きくする。
        let margin = 1.2 + min(0.5, tenure / 60)
        guard best.score > current * margin else {
            pendingCount = max(0, pendingCount - 1)
            return
        }

        if pendingBPM > 0, abs(best.bpm - pendingBPM) / pendingBPM < 0.03 {
            pendingCount += 1
        } else {
            pendingBPM = best.bpm
            pendingCount = 1
        }

        guard pendingCount >= Self.pendingRequired else { return }
        bpm = best.bpm
        bpmSince = elapsed
        pendingCount = 0
        // テンポが変わったら位相も取り直す。
        nextTick = 0
    }

    /// 位相を合わせる。合わせるのは一度きり。
    ///
    /// テンポと位相が決まれば、拍は周期を足していくだけで求まる。あとから
    /// 推定し直して寄せる必要はないし、寄せてはいけない。位相の推定には
    /// 系統的な偏り(間引きの遅れ、5 秒窓の平均という性質)があり、
    /// 定期的に補正すると同じ向きへ引っ張られ続けてグリッドが遅れていく。
    /// 実際、それが拍の抜けとして見えていた。
    ///
    /// 位相を取り直すのはテンポが変わったときだけで、そのときは
    /// `adopt` がグリッドを捨てている。
    private func lockPhase(bpm: Double, phase: Double, rate: Double) {
        guard bpm > 0, nextTick <= 0 else { return }
        let frequency = bpm / 60
        let period = 1 / frequency
        let origin = envelopeTime - Double(envelope.count - 1) / rate
        var beatTime = origin - phase / (2 * .pi * frequency)
        beatTime += ceil((elapsed - beatTime) / period) * period
        nextTick = beatTime
        // グリッドの周期も、この時点の値で固定する。以降の BPM の微調整で
        // 拍の間隔が揺れないようにするため。
        gridPeriod = period
    }

    /// 拍のグリッドを進め、その頭に当たったかを返す。
    ///
    /// テンポと位相が決まったあとは、ここだけで拍が決まる。
    /// 音の解析結果は一切見ない。
    private func advanceBeatGrid() -> Bool {
        guard nextTick > 0, gridPeriod > 0 else { return false }
        let period = gridPeriod
        guard elapsed >= nextTick else { return false }
        // 一時停止などで大きく遅れたときだけ、現在位置から取り直す。
        nextTick = elapsed - nextTick > period * 4 ? elapsed + period : nextTick + period
        return true
    }

    /// 推定したテンポから拍のグリッドを進め、その頭に当たったかを返す。
    ///
    /// オンセット(音の立ち上がり)は、そのまま拍にはならない。裏拍やフィルでも
    /// 立つし、拍の頭でも音が薄ければ検出できない。そこでテンポから
    /// 次の拍の時刻を **予測** して刻み、オンセットは位相のずれを直すのに使う。
    /// 位相同期ループと同じ考え方で、音が抜ける区間でも拍を刻み続けられる。
    private func advanceBeatGrid(onset: Bool) -> Bool {
        guard bpm > 0 else { return false }
        let period = 60 / bpm

        // オンセットが予測の近くに来たら、そちらへ少しだけ引き寄せる。
        // 一度に合わせると、拍以外の音で位相が飛んでしまう。
        if onset, nextTick > 0 {
            let error = elapsed - (nextTick - period)
            if abs(error) < period * 0.3 {
                nextTick += error * 0.25
            }
        }

        if nextTick <= 0 {
            nextTick = elapsed + period
            return onset
        }
        guard elapsed >= nextTick else { return false }
        // 大きく遅れていたら、追いつくのではなく現在位置から取り直す。
        nextTick = elapsed - nextTick > period * 2 ? elapsed + period : nextTick + period
        return true
    }
}
