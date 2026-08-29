import Foundation

/// ポーリング結果を基準点(anchor)として保持し、
/// その間の再生位置をローカル時計で外挿する。
/// これにより 1 秒ポーリングでも行送りが滑らかになる。
final class SyncEngine {
    private struct Anchor {
        let position: Double
        let at: TimeInterval
        let isPlaying: Bool
    }

    /// この差(秒)を超えたらシーク扱いとみなし、基準点を打ち直す。
    private static let driftThreshold = 0.75

    private var anchor: Anchor?

    /// ポーリング結果を反映する。再生中に限り、小さなズレは無視して滑らかさを優先する。
    func update(position: Double, isPlaying: Bool) {
        if let a = anchor, a.isPlaying, isPlaying,
           abs(estimatedPosition() - position) < Self.driftThreshold {
            return
        }
        anchor = Anchor(position: position, at: now(), isPlaying: isPlaying)
    }

    func reset() { anchor = nil }

    /// 現在の推定再生位置(秒)。基準点がなければ nil。
    func estimatedPosition() -> Double {
        guard let a = anchor else { return 0 }
        guard a.isPlaying else { return a.position }
        return a.position + (now() - a.at)
    }

    var hasAnchor: Bool { anchor != nil }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
