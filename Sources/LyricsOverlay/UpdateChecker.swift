import AppKit

/// GitHub の Releases を見て、新しい版があれば入れ替える。
///
/// 起動中の自分自身を置き換えることはできないので、差し替えは外部のスクリプトに任せる。
/// こちらが終了するのを待ってから、古いバンドルを消して新しいものを置き、開き直す。
enum UpdateChecker {
    private static let repository = "Kiikurage/lyrics-overlay"
    private static let releasesURL = URL(
        string: "https://github.com/\(repository)/releases/latest")!

    /// 動いているアプリの版。
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private struct Release {
        let version: String
        let asset: URL
    }

    enum Failure: LocalizedError {
        case network
        case noAsset
        case extraction
        case signature
        case notWritable

        var errorDescription: String? {
            switch self {
            case .network: return "GitHub に接続できませんでした。"
            case .noAsset: return "リリースに配布物が見つかりませんでした。"
            case .extraction: return "ダウンロードしたファイルを展開できませんでした。"
            case .signature:
                return "ダウンロードしたアプリの署名が、いま動いているものと一致しません。"
            case .notWritable:
                return "アプリのある場所に書き込めません。手動で置き換えてください。"
            }
        }
    }

    // MARK: - 入口

    @MainActor
    static func check() async {
        guard let release = await fetchLatest() else {
            present(title: "確認できませんでした", message: Failure.network.errorDescription ?? "")
            return
        }

        let current = currentVersion
        guard compare(release.version, isNewerThan: current) else {
            present(title: "最新版です", message: "お使いのバージョン \(current) が最新です。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "新しいバージョンがあります"
        alert.informativeText =
            "バージョン \(release.version) が公開されています(お使いのものは \(current))。\n"
            + "更新するとアプリを開き直します。"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "あとで")
        alert.addButton(withTitle: "リリースページを開く")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await install(release)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(releasesURL)
        default:
            break
        }
    }

    // MARK: - 取得

    private static func fetchLatest() async -> Release? {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        guard let urlString = zip?["browser_download_url"] as? String,
              let url = URL(string: urlString)
        else { return nil }
        return Release(version: version, asset: url)
    }

    /// 版を数値の並びとして比べる(1.10 が 1.9 より新しいと判定するため)。
    private static func compare(_ candidate: String, isNewerThan current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - 入れ替え

    @MainActor
    private static func install(_ release: Release) async {
        do {
            let staged = try await download(release)
            let script = try prepare(replacementFrom: staged)
            // ここから先は戻れない。スクリプトを起こしてから自分を終わらせる。
            try run(script)
            NSApp.terminate(nil)
        } catch {
            present(
                title: "更新できませんでした",
                message: (error as? Failure)?.errorDescription ?? error.localizedDescription,
                openReleases: true)
        }
    }

    /// zip を落として展開し、中のアプリを確かめる。
    private static func download(_ release: Release) async throws -> URL {
        guard let (file, response) = try? await URLSession.shared.download(from: release.asset),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { throw Failure.network }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsOverlayUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // zip コマンドではなく ditto を使う。バンドル内のシンボリックリンクや
        // 実行権限が保たれないと、展開しただけで署名が壊れる。
        let archive = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: file, to: archive)
        let extracted = work.appendingPathComponent("extracted")
        guard shell("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]).status == 0,
              let app = try FileManager.default
                .contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
        else { throw Failure.extraction }

        try verify(app)
        return app
    }

    /// 落としてきたアプリが、いま動いているものと同じ署名かを確かめる。
    ///
    /// 経路は HTTPS だが、それだけでは「GitHub 上の成果物が正しい」ことしか言えない。
    /// 署名まで見れば、別の鍵で作られたものを掴まされていないことまで確かめられる。
    private static func verify(_ app: URL) throws {
        guard shell("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0 else {
            throw Failure.signature
        }
        // 署名者が同じであること。ad-hoc 同士の場合はどちらも空になる。
        guard authority(of: app) == authority(of: Bundle.main.bundleURL) else {
            throw Failure.signature
        }
        // 別のアプリを掴まされていないこと。
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw Failure.signature
        }
    }

    private static func authority(of app: URL) -> String? {
        let output = shell("/usr/bin/codesign", ["-dv", app.path]).output
        return output
            .split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }
            .map(String.init)
    }

    /// 差し替えを行うスクリプトを用意する。
    private static func prepare(replacementFrom staged: URL) throws -> URL {
        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw Failure.notWritable
        }

        let script = staged.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("replace.sh")
        // 自分が終わるのを待ってから入れ替える。起動中のバンドルは置き換えられない。
        let body = """
            #!/bin/sh
            set -e
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do
                sleep 0.2
            done
            rm -rf '\(destination.path)'
            /usr/bin/ditto '\(staged.path)' '\(destination.path)'
            /usr/bin/open '\(destination.path)'
            rm -rf '\(script.deletingLastPathComponent().path)'
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private static func run(_ script: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        try process.run()
    }

    @discardableResult
    private static func shell(_ command: String, _ arguments: [String])
        -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - 表示

    @MainActor
    private static func present(title: String, message: String, openReleases: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: openReleases ? "リリースページを開く" : "OK")
        if openReleases { alert.addButton(withTitle: "閉じる") }

        // アクセサリアプリなので、明示的に前面へ出さないとダイアログが埋もれる。
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, openReleases else { return }
        NSWorkspace.shared.open(releasesURL)
    }
}
