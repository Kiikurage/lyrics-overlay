import AppKit
import Combine
import Foundation
import SwiftUI

/// オーバーレイに表示する内容。
@MainActor
final class OverlayModel: ObservableObject {
    /// 再生中の曲名とアーティスト。歌詞の有無にかかわらず常に出す。
    @Published var trackInfo: String = ""
    /// メニュー用に分けて持つ(オーバーレイと違い 2 行に分けて出すため)。
    @Published var title: String = ""
    @Published var artist: String = ""
    /// 取得状況などの案内。オーバーレイには出さず、メニューにだけ表示する。
    @Published var status: String = "Spotify を待っています"
    /// 歌詞を折り返す幅。パネルが決めてビューへ渡す。
    @Published var contentWidthLimit: Double = 600
    /// アルバムカバー。取得できるまで、また取得できない曲では nil。
    @Published var artwork: NSImage?
    /// カバーの場所は分かっている。取得が終わる前から場所を空けておき、
    /// ダウンロード完了時にレイアウトがずれないようにする。
    @Published var reservesArtwork: Bool = false
    /// "1:23 / 4:56" 形式の再生位置。
    @Published var timeText: String = ""
    /// 現在行。歌詞がない/取得中のときは空。
    @Published var current: String = ""
    /// いま「現れる」側か「消える」側か。左から順に消す演出で向きを決めるのに使う。
    @Published var entering: Bool = true
    /// 行の切り替えの最中か。終わったらタイマーを止めるために見る。
    @Published var isTransitioning: Bool = false
    /// 演出は SwiftUI のアニメーションではなく、この時刻からの経過で進める。
    /// withAnimation は NSView の中身までは補間してくれないため。
    @Published var transitionStart: Date = .distantPast
    @Published var transitionDuration: Double = 0.2

    /// 演出を挟まずに完全表示へ戻す。
    func showInstantly() {
        isTransitioning = false
        entering = true
        transitionDuration = 0.01
        transitionStart = .distantPast
    }
}

/// スペクトルだけを持つ。
///
/// 60fps で更新されるので、歌詞や曲情報と同じオブジェクトに入れてはいけない。
/// ObservableObject の無効化はプロパティ単位ではなくオブジェクト単位なので、
/// 同居させると更新のたびにビュー全体が作り直され、文字の寸法計算まで
/// 毎フレーム走ってしまう(実測で CPU 1 コアを使い切っていた)。
@MainActor
final class SpectrumModel: ObservableObject {
    /// 周波数バンドごとのレベル(0〜1)。空なら音声を取れていない。
    @Published var levels: [Double] = []
    /// 残光。levels より長く尾を引く。
    @Published var afterglow: [Double] = []
    /// 直近の拍の時刻と、推定 BPM(取れていなければ 0)。
    /// 60fps で更新される側に置く。歌詞のビューを巻き込まないため。
    @Published var beatAt: Date = .distantPast
    @Published var bpm: Double = 0
    /// 拍を刻んだ回数。検出できているかの確認用。
    @Published var beatCount: Int = 0
    /// 直近の拍の強さ(0〜1)。
    @Published var beatStrength: Double = 0
}

/// 音声を取り込めているかどうかだけを持つ。
///
/// 設定ウィンドウはこれだけを監視する。曲情報(1 秒ごとに更新)や
/// スペクトル(60fps)と同居させると、その更新のたびに設定画面が
/// 丸ごと作り直され、フォントの一覧まで組み直すことになる。
@MainActor
final class AudioStatus: ObservableObject {
    @Published var isActive: Bool = false
}

/// ポーリング → 歌詞取得 → 同期 → 表示 を束ねる。
@MainActor
final class LyricsController {
    let model = OverlayModel()
    let spectrum = SpectrumModel()
    let audioStatus = AudioStatus()

    private let style: OverlayStyle
    private let monitor = SpotifyMonitor(interval: 1.0)
    private let provider: LyricsProvider = LRCLIBProvider()
    private let sync = SyncEngine()

    /// trackId -> 歌詞。nil は「取得したが歌詞なし」を意味し、再取得を防ぐ。
    private var cache: [String: Lyrics?] = [:]
    private var currentTrackId: String?
    private var lyrics: Lyrics?
    private var duration: Double = 0
    private var artworkTask: Task<Void, Never>?
    private var audioTap: AudioTap?
    private var displayedIndex: Int?
    private var ticker: Timer?
    private var transition: Task<Void, Never>?

    init(style: OverlayStyle) {
        self.style = style
    }

    func start() {
        monitor.onUpdate = { [weak self] state in self?.handle(state) }
        monitor.start()

        // 100ms 周期で外挿位置から表示行を更新する。
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLine() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        startAudioTap()
    }

    /// 音声のタップは失敗しうる(権限拒否、Spotify 未起動)。
    /// 取れなければスペクトルが出ないだけで、歌詞表示には影響させない。
    ///
    /// タップは Spotify のプロセスに結び付くので、こちらが先に起動していると
    /// 開始できない。失敗しても諦めず、曲の状態が取れたときに繋ぎ直す。
    private func startAudioTap() {
        guard style.showSpectrum, audioTap == nil else { return }
        let tap = AudioTap()
        tap.onAnalysis = { [weak self] snapshot in
            guard let self else { return }
            spectrum.levels = snapshot.levels
            spectrum.afterglow = snapshot.afterglow
            if snapshot.tick {
                spectrum.beatAt = Date()
                spectrum.beatStrength = snapshot.tickStrength
                spectrum.beatCount += 1
            }
            if snapshot.bpm > 0, spectrum.bpm != snapshot.bpm { spectrum.bpm = snapshot.bpm }
        }
        guard tap.start() else { return }
        audioTap = tap
    }

    /// 設定で切り替えたときに開始/停止する。
    func setSpectrumEnabled(_ enabled: Bool) {
        if enabled {
            guard audioTap == nil else { return }
            startAudioTap()
        } else {
            audioTap?.stop()
            audioTap = nil
            spectrum.levels = []
        }
    }

    private func handle(_ state: PlaybackState?) {
        guard let state else {
            currentTrackId = nil
            lyrics = nil
            sync.reset()
            model.trackInfo = ""
            model.title = ""
            model.artist = ""
            model.status = "Spotify が再生していません"
            model.timeText = ""
            model.artwork = nil
            model.reservesArtwork = false
            duration = 0
            clear()
            return
        }

        if state.trackId != currentTrackId {
            currentTrackId = state.trackId
            model.trackInfo = "\(state.title) — \(state.artist)"
            // テンポと位相は曲ごとに取り直す。
            audioTap?.resetTempo()
            spectrum.bpm = 0
            spectrum.beatCount = 0
            model.title = state.title
            model.artist = state.artist
            model.status = "歌詞を探しています"
            loadArtwork(state.artworkURL)
            lyrics = nil
            displayedIndex = nil
            sync.reset()
            clear()
            load(state)
        }

        // Spotify を後から起動した場合はここで繋がる。
        startAudioTap()
        audioTap?.setVolume(state.volume)
        duration = state.duration
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
        guard found != nil else {
            model.status = "歌詞が見つかりません"
            clear()
            return
        }
        // 見つかった時点でステータスを消す。最初の行が来るまで
        // 「探しています」を出したままにしない(前奏なので音符を出す)。
        transition?.cancel()
        model.showInstantly()
        model.status = ""
        model.current = "♪"
    }

    private func refreshLine() {
        refreshTime()
        let active = audioTap?.isReceivingAudio ?? false
        if audioStatus.isActive != active { audioStatus.isActive = active }
        guard let lyrics, sync.hasAnchor else { return }

        // 演出にかかる時間ぶん先読みする。行が変わってから演出を始めると、
        // 新しい行が出そろうのはその秒数だけ後になり、歌より遅れて見える。
        // 少し早めに始めて、歌のタイミングちょうどに表示が完了するようにする。
        let timing = style.transition.timing
        let index = lyrics.index(at: sync.estimatedPosition() + timing.out + timing.in)
        guard index != displayedIndex else { return }
        displayedIndex = index

        // まだ最初の行に達していない(前奏)。
        show(index.map { lyrics.lines[$0].text } ?? "♪")
    }

    /// 演出を打ち切って、すぐ完全表示にする。
    /// 音声録音の許可を求め直す。
    ///
    /// 一度拒否すると macOS は同じダイアログを二度と出さない。`tccutil` で
    /// このアプリぶんの記録を消すと、次にタップを開始したときに再び確認が出る。
    func resetAudioPermission() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "AudioCapture", bundleID]
        try? process.run()
        process.waitUntilExit()

        // 消したうえで繋ぎ直すと、そこで確認ダイアログが出る。
        setSpectrumEnabled(false)
        setSpectrumEnabled(true)
    }

    /// アルバムカバーを取得する。取れなくても歌詞表示には影響させない。
    private func loadArtwork(_ urlString: String) {
        artworkTask?.cancel()
        model.artwork = nil
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            model.reservesArtwork = false
            return
        }
        // 取得に失敗しても場所は空けたままにする。あとから詰めると結局ずれるため。
        model.reservesArtwork = true

        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), !Task.isCancelled
            else { return }
            await MainActor.run { self?.model.artwork = image }
        }
    }

    /// 再生位置の表示を更新する。秒が変わったときだけ書き換える。
    private func refreshTime() {
        guard duration > 0, sync.hasAnchor else {
            model.timeText = ""
            return
        }
        let position = min(max(sync.estimatedPosition(), 0), duration)
        let text = "\(Self.clock(position)) / \(Self.clock(duration))"
        if text != model.timeText { model.timeText = text }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 行を差し替える。
    ///
    /// ウィンドウの幅は表示中の文字列に合わせて変わるため、クロスフェードで新旧の行が
    /// 重なっていると「古い行が出ている最中に新しい行の幅へリサイズされる」ことになり、
    /// 表示がずれて見える。そこで重ねずに、いったん消してから差し替える。
    /// リサイズは何も見えていない間に済むので、ずれが目に見えない。
    private func show(_ text: String) {
        transition?.cancel()
        let timing = style.transition.timing
        guard timing.out > 0 || timing.in > 0 else {
            model.current = text
            return
        }

        transition = Task { @MainActor in
            model.isTransitioning = true
            model.entering = false
            model.transitionDuration = timing.out
            model.transitionStart = Date()
            try? await Task.sleep(nanoseconds: UInt64(timing.out * 1_000_000_000))
            guard !Task.isCancelled else { return }

            model.current = text
            // 幅の再計算は次のループで走るので、それを待ってから現す。
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            model.entering = true
            model.transitionDuration = timing.in
            model.transitionStart = Date()

            // 演出が終わったらタイマーを止める。回しっぱなしにすると、
            // 毎フレーム文字列を作り直して寸法計算まで走ってしまう。
            try? await Task.sleep(nanoseconds: UInt64(timing.in * 1_000_000_000))
            guard !Task.isCancelled else { return }
            model.isTransitioning = false
        }
    }

    /// 歌詞以外は出さない方針なので、表示できるものが無ければ黙って空にする。
    private func clear() {
        transition?.cancel()
        model.showInstantly()
        model.current = ""
    }
}
