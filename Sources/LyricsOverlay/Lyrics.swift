import Foundation

struct LyricLine {
    /// 曲頭からの秒数
    let time: Double
    let text: String
}

struct Lyrics {
    let lines: [LyricLine]
    var isEmpty: Bool { lines.isEmpty }

    /// 指定位置(秒)で表示すべき行の index。まだ最初の行に達していなければ nil。
    func index(at position: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }
}

/// 歌詞の取得元。LRCLIB 以外に差し替えられるようにしておく。
protocol LyricsProvider {
    func fetch(for state: PlaybackState) async throws -> Lyrics?
}

enum LRCParser {
    private static let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)

    /// LRC テキストをパースする。1行に複数タイムタグが付く形式にも対応。
    static func parse(_ text: String) -> Lyrics {
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }

            let body = ns.substring(from: last.range.upperBound)
                .trimmingCharacters(in: .whitespaces)

            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let s = ns.substring(with: m.range(at: 3))
                    frac = (Double(s) ?? 0) / pow(10, Double(s.count))
                }
                lines.append(LyricLine(time: min * 60 + sec + frac, text: body))
            }
        }
        return Lyrics(lines: lines.sorted { $0.time < $1.time })
    }
}

/// https://lrclib.net の公開 API から同期歌詞を取得する。
struct LRCLIBProvider: LyricsProvider {
    private let session = URLSession(configuration: .ephemeral)
    private let userAgent = "LyricsOverlay/0.1 (https://github.com/local/lyrics-overlay)"

    func fetch(for state: PlaybackState) async throws -> Lyrics? {
        if let exact = try await get(state) { return exact }
        return try await search(state)
    }

    /// duration 込みの完全一致検索。ヒットすれば最も確実。
    private func get(_ s: PlaybackState) async throws -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [
            .init(name: "track_name", value: s.title),
            .init(name: "artist_name", value: s.artist),
            .init(name: "album_name", value: s.album),
            .init(name: "duration", value: String(Int(s.duration.rounded()))),
        ]
        guard let data = try await body(c.url!) else { return nil }
        return lyrics(from: try JSONDecoder().decode(Record.self, from: data))
    }

    /// 完全一致で取れなかったときのフォールバック。duration が近い候補を選ぶ。
    private func search(_ s: PlaybackState) async throws -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [
            .init(name: "track_name", value: s.title),
            .init(name: "artist_name", value: s.artist),
        ]
        guard let data = try await body(c.url!) else { return nil }
        let records = try JSONDecoder().decode([Record].self, from: data)
        let best = records
            .filter { $0.syncedLyrics?.isEmpty == false }
            .min { abs(($0.duration ?? 0) - s.duration) < abs(($1.duration ?? 0) - s.duration) }
        guard let best, abs((best.duration ?? 0) - s.duration) < 5 else { return nil }
        return lyrics(from: best)
    }

    private func body(_ url: URL) async throws -> Data? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    private func lyrics(from r: Record) -> Lyrics? {
        guard let synced = r.syncedLyrics, !synced.isEmpty else { return nil }
        let parsed = LRCParser.parse(synced)
        return parsed.isEmpty ? nil : parsed
    }

    private struct Record: Decodable {
        let duration: Double?
        let syncedLyrics: String?
    }
}
