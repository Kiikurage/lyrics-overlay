# Lyrics Overlay

macOS の Spotify.app で再生中の曲の同期歌詞を、常に最前面の透過ウィンドウに表示する常駐アプリ。
再生中の音を解析して、歌詞の背後に音と同期した光の波を出す。

![スクリーンショット](docs/screenshot.png)

## できること

- **同期歌詞の表示** — LRCLIB から取得した LRC を、再生位置に合わせて 1 行ずつ表示する
- **曲情報** — 曲名 / アーティスト、再生時間、アルバムカバー
- **音に同期した演出** — Spotify の音声を解析し、スペクトルを光の波として描く。
  テンポを推定して拍を刻み、拍の瞬間に波形をひずませる
- **自由配置** — ドラッグで好きな位置へ。位置は記憶される
- **設定** — 書体・太さ・文字サイズ、揃え(左 / 中央 / 右)、行の切り替えの演出、
  スペクトルのオン / オフ

## 必要なもの

- **macOS 14.2 以降** — 音声の取り込みに Core Audio のプロセスタップを使うため
- Spotify デスクトップアプリ(Web Player やスマホ再生からは取得できない)
- ビルドする場合は Swift 6 系ツールチェイン(Xcode Command Line Tools)

## 入手

[Releases](https://github.com/Kiikurage/lyrics-overlay/releases) から `LyricsOverlay.zip` を
ダウンロードして展開する。

Apple の公証(notarization)を受けていないため、そのままでは Gatekeeper に止められる。
初回だけ **右クリック →「開く」** で起動するか、次を実行する。

```bash
xattr -dr com.apple.quarantine /path/to/LyricsOverlay.app
```

公証には Apple Developer Program(有償)が必要なため、この配布物では対応していない。
自分でビルドした場合は隔離属性が付かないので、この操作は要らない。

## ビルド

```bash
./build-app.sh          # release ビルド + .app 組み立て + ad-hoc 署名
./build-app.sh --run    # 上記に加えて、起動中のアプリを終了して開き直す
open LyricsOverlay.app
```

`.app` にして署名しているのは、TCC(各種許可)をバンドル単位で記憶させるため。
開発中の型チェックだけなら `swift build` で足りる。

## 許可

初回起動時に 2 つ求められる。

- **オートメーション** — 再生中の曲と再生位置を Spotify.app から取得する。
  拒否すると何も表示されない
- **音声の録音** — スペクトル表示のために Spotify の音声だけを解析する。
  拒否しても歌詞表示は動く

音声の許可は、一度拒否すると macOS が同じダイアログを二度と出さない。
設定ウィンドウの「スペクトラム」から求め直せる。

## 操作

- **移動** — ウィンドウをドラッグする
- **Spotify を前面に** — オーバーレイをダブルクリックする
- **設定 / クリック透過 / 終了** — メニューバーの `💬` アイコンから。
  クリック透過が有効な間は背面のアプリにクリックが通る(そのぶんドラッグで
  動かせなくなるので、動かすときは一度オフにする)

## 仕組み

```
SpotifyMonitor     AppleScript で Spotify.app を 1 秒ポーリング
      ↓            曲名 / アーティスト / 長さ / 再生位置 / カバーの URL
LyricsController   曲が変わったときだけ歌詞を取得する
      ↓
LRCLIBProvider     lrclib.net から同期歌詞(LRC 形式)を取得
      ↓            LyricsProvider protocol 経由なので取得元は差し替えられる
SyncEngine         ポーリング結果を基準点に、ローカル時計で再生位置を外挿(100ms 更新)
      ↓            1 秒ポーリングでも行送りが滑らかになる
OverlayPanel       透過 NSPanel + SwiftUI。内容に合わせて伸縮し、揃えた側の端を固定する
GlyphText          Core Text で組んだ行をキャッシュし、CTFontDrawGlyphs で描画。
                   文字ごとに不透明度と位置を変えられるので、行の切り替えの演出に使う

AudioTap           Core Audio のプロセスタップで Spotify の出力だけを取り込む。
      ↓            仮想オーディオデバイスは不要で、出力先の設定も変わらない
SpectrumAnalyzer   FFT(2048 点 / 5.3ms ごと)、対数間隔の三角窓フィルタバンク、
      ↓            残光による減衰、低域の刻みからのテンポ推定と拍のグリッド
SpectrumWave       スペクトルを上下対称の光の波として描く。拍で歪みと閃光を出す
```

Electron ではなくネイティブで書いてあるのは、常駐させるため。
メモリは 80MB 前後(スペクトルを切ると 50MB 前後)、CPU は再生中で 15% 前後。

## 制約

- 歌詞は LRCLIB にあるものだけ。同期歌詞がない曲は何も表示しない
- 歌詞キャッシュはプロセス内のみ。再起動すると取り直す
- Spotify デスクトップアプリ限定
- 表示のオン / オフのホットキーはなし
- 複数ディスプレイは、保存された座標を復元するだけ

## 歌詞データの扱いについて

Spotify の制御には公式の AppleScript インターフェースを使っており、ここは問題ない。

一方 **歌詞データそのものは権利がクリアではない**。LRCLIB のライセンス表示は LRCLIB 自身の
権利放棄であって、作詞家・音楽出版社の原著作権を処理したものではなく、実態としては
ユーザー投稿型で権利処理はされていない。

このアプリに歌詞データは含まれていない(公開 API を叩くクライアントでしかない)。
取得した歌詞を自分の画面で見る、という範囲での利用を想定している。
配信画面に映す、共有する、商用化するといった用途に進める場合は、
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
├── OverlayPanel.swift          透過 NSPanel と、その中のビュー
├── GlyphText.swift             Core Text による文字の組版と描画
├── OverlayStyle.swift          表示の設定(書体・サイズ・揃え・演出)
├── SettingsWindow.swift        設定ウィンドウ
├── FontFamilyPicker.swift      書体の選択(その書体自身で名前を描く)
├── MenuHeader.swift            メニューバーのメニューに出す曲情報
├── AudioTap.swift              Core Audio のプロセスタップ
├── SpectrumAnalyzer.swift      FFT・テンポ推定・拍の検出
├── SpectrumWave.swift          光の波の描画
└── BeatEcho.swift              拍の瞬間の波形を保持し、余韻に使う
```
