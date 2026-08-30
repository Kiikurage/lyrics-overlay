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
    /// この解析で拍を検出したか。
    let beat: Bool
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

    /// 拍の検出用。前フレームの振幅と、スペクトル変化量(フラックス)の履歴。
    private var previousMagnitudes = [Float](repeating: 0, count: size / 2)
    private var fluxHistory = [Double](repeating: 0, count: 43)
    private var fluxIndex = 0
    private var lastBeat: Double = 0
    private var intervals: [Double] = []
    private var bpm: Double = 0
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
    /// 高域の持ち上げ(dB / オクターブ)。
    ///
    /// 自然な音のスペクトルは高域へ向かって概ね一定の傾きで下がる
    /// (ピンクノイズで -3dB/oct)。その傾きを打ち消すぶんだけ、
    /// 周波数に応じて縦方向の倍率を上げる。
    /// 各帯域の相対関係は保たれるので、実際の山がぼけることはない。
    private static let tiltPerOctave = 3.5

    private var decay: Double { exp(-frameDuration / Self.persistence) }
    private var slowDecay: Double { exp(-frameDuration / Self.slowPersistence) }
    private var rise: Double { 1 - exp(-frameDuration / Self.attack) }

    /// 無音に近づいたときに全体を滑らかに閉じるための係数。
    private var gate: Double = 0

    init(bandCount: Int) {
        self.bandCount = bandCount
        smoothed = [Double](repeating: 0, count: bandCount)
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
        // フラックスの基準は直近 1 秒ぶん。
        fluxHistory = [Double](repeating: 0, count: max(8, Int(1.0 / frameDuration)))
        fluxIndex = 0
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
                    result = analyze()
                }
            }
            // 1 つ目のバッファ(または 1 つ目のチャンネル)だけで足りる。
            break
        }
        return result
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
            let decibels = 20 * log10(Double(sum) / Double(Self.size) + 1e-9) + tilts[band]
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
        let beat = detectBeat()
        let loudness = levels.reduce(0, +) / Double(bandCount)
        return AudioSnapshot(
            levels: levels, afterglow: glow, loudness: loudness, beat: beat, bpm: bpm)
    }

    private func smoothstep(_ value: Double, from low: Double, to high: Double) -> Double {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// スペクトル変化量(スペクトルフラックス)の立ち上がりで拍を検出する。
    ///
    /// 音が増えた成分だけを足し合わせ、直近 1 秒ほどの平均を超えたところを打点とみなす。
    /// 打点の間隔の中央値から BPM を推定する。
    private func detectBeat() -> Bool {
        var flux = 0.0
        for index in 1..<(Self.size / 2) {
            let difference = Double(magnitudes[index] - previousMagnitudes[index])
            if difference > 0 { flux += difference }
        }
        previousMagnitudes = magnitudes

        let average = fluxHistory.reduce(0, +) / Double(fluxHistory.count)
        fluxHistory[fluxIndex] = flux
        fluxIndex = (fluxIndex + 1) % fluxHistory.count

        // 平均を明確に上回り、かつ直前の打点から十分離れているときだけ拍とする
        // (16 分音符まで刻まないように 0.25 秒の不応期を置く)。
        guard average > 0, flux > average * 1.6, elapsed - lastBeat > 0.25 else { return false }

        if lastBeat > 0 {
            let interval = elapsed - lastBeat
            if interval < 2.0 {
                intervals.append(interval)
                if intervals.count > 24 { intervals.removeFirst() }
                if intervals.count >= 6 {
                    let sorted = intervals.sorted()
                    bpm = 60 / sorted[sorted.count / 2]
                }
            }
        }
        lastBeat = elapsed
        return true
    }
}
