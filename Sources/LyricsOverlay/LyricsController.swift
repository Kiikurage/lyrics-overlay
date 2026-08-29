import Foundation
import Combine

/// オーバーレイに表示する内容。
@MainActor
final class OverlayModel: ObservableObject {
    /// 現在行。歌詞がない/取得中のときは status に理由が入る。
    @Published var previous: String = ""
    @Published var current: String = ""
    @Published var next: String = ""
    @Published var status: String? = "Spotify を待っています…"
}

/// ポーリング → 歌詞取得 → 同期 → 表示 を束ねる。
@MainActor
final class LyricsController {
    let model = OverlayModel()

    private let monitor = SpotifyMonitor(interval: 1.0)
    private let provider: LyricsProvider = LRCLIBProvider()
    private let sync = SyncEngine()

    /// trackId -> 歌詞。nil は「取得したが歌詞なし」を意味し、再取得を防ぐ。
    private var cache: [String: Lyrics?] = [:]
    private var currentTrackId: String?
    private var lyrics: Lyrics?
    private var displayedIndex: Int?
    private var ticker: Timer?

    func start() {
        monitor.onUpdate = { [weak self] state in self?.handle(state) }
        monitor.start()

        // 100ms 周期で外挿位置から表示行を更新する。
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLine() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func handle(_ state: PlaybackState?) {
        guard let state else {
            currentTrackId = nil
            lyrics = nil
            sync.reset()
            clear(status: "Spotify が再生していません")
            return
        }

        if state.trackId != currentTrackId {
            currentTrackId = state.trackId
            lyrics = nil
            displayedIndex = nil
            sync.reset()
            clear(status: "\(state.title) — 歌詞を探しています…")
            load(state)
        }

        sync.update(position: state.position, isPlaying: state.isPlaying)
    }

    private func load(_ state: PlaybackState) {
        if let cached = cache[state.trackId] {
            apply(cached, for: state)
            return
        }
        Task { [provider] in
            let found = try? await provider.fetch(for: state)
            await MainActor.run {
                self.cache[state.trackId] = found
                self.apply(found, for: state)
            }
        }
    }

    private func apply(_ found: Lyrics?, for state: PlaybackState) {
        // 取得中に曲が変わっていたら破棄する。
        guard state.trackId == currentTrackId else { return }
        lyrics = found
        displayedIndex = nil
        if found == nil {
            clear(status: "歌詞が見つかりません — \(state.title)")
        }
    }

    private func refreshLine() {
        guard let lyrics, sync.hasAnchor else { return }
        let index = lyrics.index(at: sync.estimatedPosition())
        guard index != displayedIndex else { return }
        displayedIndex = index

        guard let i = index else {
            model.status = nil
            model.previous = ""
            model.current = "♪"
            model.next = lyrics.lines.first?.text ?? ""
            return
        }
        model.status = nil
        model.previous = i > 0 ? lyrics.lines[i - 1].text : ""
        model.current = lyrics.lines[i].text
        model.next = i + 1 < lyrics.lines.count ? lyrics.lines[i + 1].text : ""
    }

    private func clear(status: String) {
        model.status = status
        model.previous = ""
        model.current = ""
        model.next = ""
    }
}
