# Lyrics Overlay

A menu bar app for macOS that shows time-synced lyrics for whatever is playing in Spotify.app,
in a transparent window that floats above everything else. It taps the audio and draws a wave of
light behind the lyrics, in sync with the music.

![Screenshot](docs/screenshot.png)

## Features

- **Synced lyrics** — LRC files from LRCLIB, advanced line by line as the track plays
- **Track info** — title / artist, elapsed time, album artwork
- **Audio-reactive visuals** — the spectrum of Spotify's own output, drawn as a wave of light.
  The tempo is estimated from the low end, and the wave is distorted on every beat
- **Place it anywhere** — drag the overlay; the position is remembered
- **Settings** — typeface, weight and size, alignment (left / center / right),
  the transition between lines, and whether to show the spectrum

## Requirements

- **macOS 14.2 or later** — audio is captured through a Core Audio process tap
- The Spotify desktop app (the Web Player and phone playback cannot be read)
- A Swift 6 toolchain (Xcode Command Line Tools), if you build it yourself

## Install

Download `LyricsOverlay.zip` from
[Releases](https://github.com/Kiikurage/lyrics-overlay/releases) and unzip it.

The app is not notarized, so Gatekeeper will refuse to open it on the first try.
Either **right-click → Open** once, or run:

```bash
xattr -dr com.apple.quarantine /path/to/LyricsOverlay.app
```

Notarization requires a paid Apple Developer Program membership, which this build does not use.
If you build the app yourself it is never quarantined, so none of this applies.

## Build

```bash
./build-app.sh          # release build + .app bundle + ad-hoc signature
./build-app.sh --run    # the above, then quit the running app and open it again
open LyricsOverlay.app
```

The app is bundled and signed so that macOS remembers its permissions per bundle rather than
per binary. `swift build` is enough if you only want to type-check while developing.

## Permissions

Two prompts appear the first time you run it.

- **Automation** — reads the current track and playback position from Spotify.app.
  Nothing is shown if you decline
- **Audio recording** — analyzes Spotify's audio for the spectrum display.
  Lyrics still work if you decline

macOS never shows the audio prompt twice, so if you decline it by accident, use
"Ask again" in the Spectrum section of the settings window.

## Usage

- **Move** — drag the overlay
- **Bring Spotify to the front** — double-click the overlay
- **Settings / click-through / quit** — from the `💬` menu bar icon.
  While click-through is on, clicks pass to whatever is behind the overlay
  (which also means you cannot drag it, so turn it off to move the window)

## How it works

```
SpotifyMonitor     Polls Spotify.app once a second over AppleScript
      ↓            title / artist / duration / position / artwork URL
LyricsController   Fetches lyrics only when the track changes
      ↓
LRCLIBProvider     Gets synced lyrics (LRC) from lrclib.net
      ↓            Behind a LyricsProvider protocol, so the source can be swapped
SyncEngine         Anchors on each poll and extrapolates the position locally (100 ms ticks),
      ↓            which keeps lines advancing smoothly despite the one-second polling
OverlayPanel       Transparent NSPanel + SwiftUI. Resizes to its contents while keeping
                   the aligned edge pinned
GlyphText          Caches Core Text line layout and draws it with CTFontDrawGlyphs, so each
                   character can carry its own opacity and offset during a transition

AudioTap           A Core Audio process tap captures only Spotify's output. No virtual audio
      ↓            device is involved and your output device setting is left alone
SpectrumAnalyzer   FFT (2048 points every 5.3 ms), a log-spaced triangular filter bank,
      ↓            phosphor-like decay, and tempo estimation from the low-end pulse
SpectrumWave       Draws the spectrum as a wave of light, mirrored about its center line
```

It is written natively rather than in Electron because it runs all day: around 80 MB of memory
(about 50 MB with the spectrum off) and roughly 15% of one CPU core while playing.

## Limitations

- Only what LRCLIB has. Tracks without synced lyrics show nothing
- Lyrics are cached in memory only, so they are fetched again after a restart
- Spotify desktop app only
- No hotkey to show or hide the overlay
- Multiple displays are handled by restoring the saved coordinates, nothing more

## About the lyrics data

Controlling Spotify through AppleScript uses its official scripting interface, which is fine.

**The lyrics themselves are not rights-cleared.** LRCLIB's CC0 notice is LRCLIB waiving its own
rights; it does not clear the underlying copyright held by lyricists and music publishers.
The database is user-submitted and no rights have been processed.

No lyrics data ships with this app — it is only a client for a public API. It is meant for
reading lyrics on your own screen. Putting them on a stream, redistributing them or building a
product on top would first require switching to a properly licensed provider such as Musixmatch
(the `LyricsProvider` protocol exists for exactly that).

## Repository layout

```
Package.swift
build-app.sh                    release build + .app bundle + ad-hoc signature
CLAUDE.md                       Design decisions and context, written for coding agents
Sources/LyricsOverlay/
├── main.swift                  AppDelegate, menu bar residency
├── SpotifyMonitor.swift        AppleScript polling
├── Lyrics.swift                LyricsProvider protocol / LRC parser / LRCLIBProvider
├── SyncEngine.swift            Position extrapolation and drift correction
├── LyricsController.swift      Ties fetching, syncing and display together
├── OverlayPanel.swift          The transparent NSPanel and the views inside it
├── GlyphText.swift             Core Text layout and glyph drawing
├── OverlayStyle.swift          Display settings (typeface, size, alignment, transition)
├── SettingsWindow.swift        Settings window
├── FontFamilyPicker.swift      Typeface picker that renders each name in its own face
├── MenuHeader.swift            Track info shown in the menu bar menu
├── AudioTap.swift              Core Audio process tap
├── SpectrumAnalyzer.swift      FFT, tempo estimation, beat detection
├── SpectrumWave.swift          Drawing of the wave of light
└── BeatEcho.swift              Holds the waveform at each beat, used for the afterglow
```
