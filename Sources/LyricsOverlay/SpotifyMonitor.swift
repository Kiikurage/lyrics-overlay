import Foundation

/// Spotify.app から取得した再生状態のスナップショット。
struct PlaybackState: Equatable {
    let trackId: String
    let title: String
    let artist: String
    let album: String
    /// 曲全体の長さ(秒)
    let duration: Double
    /// 取得時点の再生位置(秒)
    let position: Double
    let isPlaying: Bool
    /// アルバムカバーの URL(Spotify の CDN)。
    let artworkURL: String
    /// Spotify 内の音量(0〜100)。音声解析の補正に使う。
    let volume: Double
}

/// Spotify.app を AppleScript でポーリングし、再生状態の変化を通知する。
final class SpotifyMonitor {
    /// 再生状態が取れたときに毎回呼ばれる。Spotify が停止中は nil。
    var onUpdate: ((PlaybackState?) -> Void)?

    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "spotify.monitor")
    private var timer: DispatchSourceTimer?
    private let script: NSAppleScript?

    private static let source = """
    tell application "Spotify"
        if it is not running then return "NOTRUNNING"
        try
            set t to current track
            return (id of t) & "\\t" & (name of t) & "\\t" & (artist of t) & "\\t" \
                & (album of t) & "\\t" & (duration of t) & "\\t" & (player position) & "\\t" \
                & (player state as text) & "\\t" & (artwork url of t) & "\\t" \
                & (sound volume)
        on error
            return "NOTRUNNING"
        end try
    end tell
    """

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
        self.script = NSAppleScript(source: Self.source)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let state = fetch()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(state) }
    }

    private func fetch() -> PlaybackState? {
        guard let script else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // 権限未許可(-1743)などはここに来る。ログだけ残して静かに諦める。
            FileHandle.standardError.write("AppleScript error: \(error)\n".data(using: .utf8)!)
            return nil
        }
        guard let raw = result.stringValue, raw != "NOTRUNNING" else { return nil }

        let f = raw.components(separatedBy: "\t")
        guard f.count >= 9,
              let durationMs = Double(f[4]),
              let position = Double(f[5]) else { return nil }

        return PlaybackState(
            trackId: f[0],
            title: f[1],
            artist: f[2],
            album: f[3],
            duration: durationMs / 1000.0,
            position: position,
            isPlaying: f[6] == "playing",
            artworkURL: f[7],
            volume: Double(f[8]) ?? 100
        )
    }
}
