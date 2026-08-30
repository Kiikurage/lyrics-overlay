# Lyrics Overlay — エージェント向けコンテキスト

macOS 常駐アプリ。Spotify.app で再生中の曲の同期歌詞を、最前面の透過ウィンドウに表示する。
現状は **PoC**(最小限で動くところまで)。

## 決定済みの方針(覆さないこと)

これらはユーザーとの打ち合わせで確定した。理由なく変更しない。

- **Swift / SwiftUI ネイティブで実装する。Electron は使わない。**
  常駐アプリなのでメモリ消費を嫌ったため。Electron 150〜250MB に対し本実装は 30〜50MB 程度。
  「Web 技術のほうが速く書ける」は理由にならない。
- **歌詞ソースは LRCLIB。Spotify 内部 API(`sp_dc` cookie 方式)は使わない。**
  内部 API は Spotify の利用規約が明示的に禁じている領域で、仕様変更で頻繁に壊れる。
  カバー率を上げたくなっても、この方式には手を出さない。
- **再生状態の取得は AppleScript(Spotify.app の公式 Scripting インターフェース)。**
  Spotify Web API(OAuth)は認証実装が必要で位置精度も落ちるため PoC では採用しない。
  Web Player やスマホ再生にも対応したくなった場合に限り、再検討の余地がある。
- **歌詞の取得元は `LyricsProvider` protocol の裏に隠す。**
  将来 Musixmatch 等の正規ライセンス提供元へ差し替えられるようにするため。
  この抽象は意図的なもので、「実装が1つしかないから」と剥がさない。
- **オーバーレイはドラッグで自由配置。** 位置は `UserDefaults` に永続化する。

## アーキテクチャ

```
SpotifyMonitor.swift    AppleScript(NSAppleScript)で Spotify.app を 1 秒ポーリング
      ↓                 PlaybackState{trackId,title,artist,album,duration,position,isPlaying}
LyricsController.swift  曲 ID の変化を検知 → 変わったときだけ歌詞を取得
      ↓
Lyrics.swift            LyricsProvider protocol / LRC パーサ / LRCLIBProvider
      ↓                 Lyrics{[LyricLine{time,text}]}
SyncEngine.swift        ポーリング結果を「基準点」に、ローカル時計で再生位置を外挿
      ↓
OverlayPanel.swift      透過 NSPanel + SwiftUI(前行 / 現在行 / 次行)
main.swift              AppDelegate、メニューバー常駐(LSUIElement)
```

### 同期の仕組み(重要)

ポーリングは 1 秒間隔だが、そのまま使うと行送りがカクつく。そのため `SyncEngine` が
「取得時刻と再生位置」の組を基準点として保持し、以降は `systemUptime` の差分で
現在位置を外挿する。`LyricsController` は 100ms 周期のタイマで外挿位置から表示行を決める。

ポーリング結果と外挿値のズレが `driftThreshold`(0.75秒)を超えたらシーク/一時停止と
みなして基準点を打ち直す。閾値内のズレは無視する — これを補正すると行が前後に揺れる。

### LRCLIB へのアクセス

1. `/api/get` に track_name / artist_name / album_name / duration を渡して完全一致を狙う
2. 外れる(404)場合は `/api/search` に落として、duration が最も近く同期歌詞を持つ候補を採る。
   duration 差が 5 秒以上なら別曲とみなして諦める

`syncedLyrics`(LRC 形式)のみ使う。`plainLyrics` は時間情報がないので採用していない。

## ビルドと実行

```bash
./build-app.sh          # release ビルド + .app 組み立て + ad-hoc 署名
./build-app.sh --run    # 上記に加えて、起動中のアプリを終了して開き直す
open LyricsOverlay.app
swift build             # 開発中の型チェックだけならこれで十分
```

- `.app` バンドルにして ad-hoc 署名しているのは、**TCC(オートメーション許可)を
  バンドル単位で安定して記憶させるため**。素の実行ファイルを直接叩くと許可が
  ターミナルに紐づいてしまい、挙動が不安定になる。この手順を省かない
- Swift 6 ツールチェインだが `swiftLanguageMode(.v5)` を指定している。
  strict concurrency に付き合うコストが PoC に見合わないため
- **ソースを変更したら、依頼されなくても最後に `./build-app.sh` まで走らせること。**
  `swift build` で型チェックが通っただけでは `.app` は古いままで、ユーザーが
  `open LyricsOverlay.app` しても変更が反映されない。「ビルドしてください」と
  ユーザーに促すのではなく、こちらで `.app` の更新まで済ませて完了とする。
  **開発中は `./build-app.sh --run` を使い、アプリの再起動まで自動で行うこと。**
  ユーザーは目視で確認したいので、変更のたびに手で終了・再起動させない
  (バンドル ID は変わらないので、再起動しても TCC の許可は取り直しにならない)

## 動作確認の状況

- ビルド:通っている
- LRCLIB API:`curl` で応答形状を確認済み
- **エンドツーエンド(Spotify 再生 → 歌詞取得 → オーバーレイ表示・同期)はユーザーが
  実機で確認済み。想定どおり動作している。** ここは動く状態が既知なので、
  変更を入れたときはこの経路が壊れていないかを確認すること

初回起動時にオートメーション許可のダイアログが出る。許可しないと
`NSAppleScript` が -1743 エラーを返し、再生状態が取れない(stderr にログが出る)。

## 権利関係について(ユーザーと合意済みの認識)

- Spotify の AppleScript 制御は公式インターフェースなので問題ない
- **歌詞データはグレー。** LRCLIB の CC0 表示は LRCLIB 自身の権利放棄であって、
  作詞家・音楽出版社の原著作権を処理したものではない。ユーザー投稿型で権利処理はされていない
- 現状は**ユーザー個人が自分の画面で見る用途**であり、私的使用の範囲として進めている。
  「権利がクリア」なのではなく「私的利用だから問題化しない」状態、という認識で一致している
- したがって、**配布・公開・商用化を前提とした機能提案や、そちらへ誘導する変更は行わない。**
  ユーザーからその意向が示された場合は、正規ライセンス提供元への差し替えが前提になることを伝える

## 未実装(PoC のため意図的に落としたもの)

スコープは「最小限で動くもの」とユーザーが選択した。以下は未着手だが、
勝手に作らず、依頼されてから着手すること。

- 歌詞のディスクキャッシュ(現状はプロセス内 `[String: Lyrics?]` のみ)
- 設定 UI、フォントサイズ・不透明度の調整
- 表示オン/オフのグローバルホットキー
- 複数ディスプレイの扱い(現状は保存された座標を復元するだけ)
- ログイン項目への登録
- テスト(`LRCParser` と `SyncEngine` は純粋なロジックなので、書くならここから)
