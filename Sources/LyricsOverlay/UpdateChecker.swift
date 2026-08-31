import AppKit

/// GitHub の Releases を見て、新しい版が出ていないか調べる。
///
/// 自動更新はしない。知らせてリリースページを開くところまで。
/// 自分自身を差し替える処理は、失敗したときに起動しなくなる類の壊れ方をするので、
/// 利用者が実質的に限られているうちは手動で足りる。
enum UpdateChecker {
    private static let repository = "Kiikurage/lyrics-overlay"
    private static let releasesURL = URL(
        string: "https://github.com/\(repository)/releases/latest")!

    /// 動いているアプリの版。
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 最新版を調べて結果を知らせる。
    @MainActor
    static func check() async {
        guard let latest = await fetchLatestTag() else {
            present(
                title: "確認できませんでした",
                message: "GitHub に接続できませんでした。時間をおいて試してください。")
            return
        }

        let current = currentVersion
        guard compare(latest, isNewerThan: current) else {
            present(
                title: "最新版です",
                message: "お使いのバージョン \(current) が最新です。")
            return
        }

        present(
            title: "新しいバージョンがあります",
            message: "バージョン \(latest) が公開されています(お使いのものは \(current))。",
            openReleases: true)
    }

    /// - Returns: 最新リリースのタグから先頭の "v" を除いたもの。
    private static func fetchLatestTag() async -> String? {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
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

    @MainActor
    private static func present(title: String, message: String, openReleases: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: openReleases ? "ダウンロード" : "OK")
        if openReleases { alert.addButton(withTitle: "あとで") }

        // アクセサリアプリなので、明示的に前面へ出さないとダイアログが埋もれる。
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, openReleases else { return }
        NSWorkspace.shared.open(releasesURL)
    }
}
