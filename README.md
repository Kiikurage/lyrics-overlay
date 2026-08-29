# Lyrics Overlay

macOS の Spotify.app で再生中の曲の歌詞を、常に最前面の透過ウィンドウに表示する常駐アプリ。
作業 BGM を流しながら、歌詞を画面の好きな位置に置いておくためのもの。

現状は **PoC**。動作は最小限で、設定 UI などはない。

## 必要なもの

- macOS 13 以降
- Swift 6 系ツールチェイン(Xcode Command Line Tools)
- Spotify デスクトップアプリ(Web Player やスマホ再生からは取得できない)

## ビルドと起動

```bash
./build-app.sh
open LyricsOverlay.app
```

初回起動時に **Spotify を操作する許可**を求められる。許可しないと再生状態を取得できない。
あとから変更する場合は システム設定 → プライバシーとセキュリティ → オートメーション。

開発中の型チェックだけなら `swift build` で足りる。

## 操作

- **移動** — ウィンドウをドラッグする。位置は保存され、次回起動時に復元される
- **クリック透過** — メニューバーの `💬` アイコンから切り替える。有効な間は背面のアプリに
  クリックが通る(そのぶんドラッグで動かせなくなるので、動かすときは一度オフにする)
- **終了** — 同じメニューから

## 仕組み

```
SpotifyMonitor    AppleScript で Spotify.app を 1 秒ポーリング
      ↓           曲名 / アーティスト / 長さ / 再生位置 / 再生中か
LyricsController  曲が変わったときだけ歌詞を取得する
      ↓
LRCLIBProvider    lrclib.net から同期歌詞(LRC 形式)を取得
      ↓           LyricsProvider protocol 経由なので取得元は差し替えられる
SyncEngine        ポーリング結果を基準点に、ローカル時計で再生位置を外挿(100ms 更新)
      ↓           1 秒ポーリングでも行送りが滑らかになる
OverlayPanel      透過 NSPanel + SwiftUI。前の行 / 現在の行 / 次の行 を表示
```

Electron ではなくネイティブで書いてあるのは、常駐させるため。メモリ消費は 30〜50MB 程度。

## 制約

- 歌詞は LRCLIB にあるものだけ。同期歌詞がない曲は「歌詞が見つかりません」と表示される
- 歌詞キャッシュはプロセス内のみ。再起動すると取り直す
- Spotify デスクトップアプリ限定
- 設定 UI、フォントサイズ変更、ホットキーはなし

## 歌詞データの扱いについて

Spotify の制御には公式の AppleScript インターフェースを使っており、ここは問題ない。

一方 **歌詞データそのものは権利がクリアではない**。LRCLIB のライセンス表示は LRCLIB 自身の
権利放棄であって、作詞家・音楽出版社の原著作権を処理したものではなく、実態としては
ユーザー投稿型で権利処理はされていない。

したがってこれは **個人が自分の画面で見るためのツール**である。配信画面に映す、共有する、
配布する、商用化するといった用途は想定していない。そうした用途に進める場合は
Musixmatch 等の正規ライセンス提供元への差し替えが前提になる
(`LyricsProvider` protocol はそのために切ってある)。

## リポジトリ構成

```
Package.swift
build-app.sh                    release ビルド + .app 組み立て + ad-hoc 署名
CLAUDE.md                       エージェント向けの設計意図・決定事項
Sources/LyricsOverlay/
├── main.swift                  AppDelegate、メニューバー常駐
├── SpotifyMonitor.swift        AppleScript ポーリング
├── Lyrics.swift                LyricsProvider protocol / LRC パーサ / LRCLIBProvider
├── SyncEngine.swift            再生位置の外挿とドリフト補正
├── LyricsController.swift      取得・同期・表示の統合
└── OverlayPanel.swift          透過 NSPanel + SwiftUI ビュー
```
