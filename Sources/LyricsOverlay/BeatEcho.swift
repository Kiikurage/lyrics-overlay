import Foundation

/// 拍の瞬間の波形を、しばらく覚えておく。
///
/// 余韻を描くには、その拍で波がどんな形だったかを保持する必要がある。
/// スペクトルは刻々と変わるので、あとから同じ形は得られない。
///
/// 保持するのは 1 拍ぶんでは足りない。余韻が拍の間隔より長いと、次の拍で
/// 上書きされた瞬間に前の余韻が消えてしまう。複数を並行して持ち、
/// それぞれが自分の時間で消えていくようにする。
final class BeatEcho {
    struct Impact {
        let at: Date
        /// その拍の強さ(0〜1)。
        let strength: Double
        /// そのときの波形。余韻はこの形に沿って広がる。
        let values: [Double]
    }

    private(set) var impacts: [Impact] = []
    private var latest: Date = .distantPast

    /// 拍が更新されていれば写し取り、寿命の切れたものを捨てる。
    func capture(at beat: Date, strength: Double, life: Double, values: @autoclosure () -> [Double]) {
        let now = Date()
        if beat > latest {
            latest = beat
            if strength > 0.05 {
                impacts.append(Impact(at: beat, strength: strength, values: values()))
            }
        }
        impacts.removeAll { now.timeIntervalSince($0.at) > life }
    }
}
