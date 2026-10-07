# spotify-mod

Listen to Spotify inside Claude Code with an **Inline Mini Status Bar**, a **Minimal Sidebar Player** (rendering real PNG album cover artwork), or a **Popup Window**, plus **Spotify Login** and **Voice-Enabled Search**.

## Install

```
/plugin marketplace add hemanth/spotify-mod
/plugin install spotify-mod@spotify-mod
```

Or from a clone:

```sh
git clone https://github.com/hemanth/spotify-mod
claude --plugin-dir ./spotify-mod
```

Needs Claude Code `2.1.287+` and macOS.

## Usage

```
/spotify daft punk veridis quo
```

Searches and starts playback in the default **Inline Mini Status Bar** (right above your prompt — nothing pops out).

```
/spotify                         show the inline mini status bar (▶, ⏸, ⏭, Search, Voice, Login)
/spotify <url | uri | search>    search and play track, album, or playlist inline
/spotify login | logout          sign in to your Spotify account to unlock full-length tracks
/spotify voice [spoken query]    voice-enabled search via microphone or spoken phrase
/spotify mini                    use the Inline Mini Status Bar only (no sidebar, no popup)
/spotify panel                   open the Claude Code Sidebar only (real PNG album cover + minimal controls, no popup)
/spotify popup                   open the floating macOS Popup Window only (closes sidebar)
/spotify pause | resume
/spotify next | prev
/spotify hide | show             hide the UI, keep listening
/spotify stop                    stop playback and close player
/spotify status
```

## Display Modes (Mutually Exclusive)

Only one surface is active at a time (Sidebar and Popup Window never open together):

1. **Inline Mini Status Bar (`mini`, default)** — Inline `AbovePrompt` bar (`SPOTIFY [MINI] Track - Artist [▶] [⏸] [⏭] [Voice] [Sidebar] [Popup] [Login]` + inline `Search` input). Background audio runs headlessly with zero popout windows.
2. **Sidebar (`side-panel`)** — Opens only the Claude Code sidebar (`Pane`) rendering the actual high-resolution album cover PNG image (`/tmp/claude-spotify-mod-cover.png`) via Claude Code's `Image` component, track title/artist, `⏮ / ▶ / ⏸ / ⏭ / Voice / Login`, and a `Search` input. No floating popup window is shown.
3. **Popup Window (`popup`)** — Opens only the compact floating macOS window and closes the Claude Code sidebar.

## Spotify Login

Run `/spotify login` or click **`Login`** in the Mini Status Bar, Sidebar, or Popup Window to sign in to your Spotify account. Your session cookies (`sp_dc` / `sp_key`) persist in the native `WKWebsiteDataStore`, allowing Spotify Web embeds to play full-length songs instead of 30-second previews. Once login finishes, the auth sheet closes automatically and returns to your active mode. Run `/spotify logout` anytime to clear cookies.

## Voice-Enabled Search

Trigger voice search in three ways:

- Click **`Voice`** in the Inline Mini Status Bar or Sidebar (uses native on-device `SFSpeechRecognizer` + `AVAudioEngine` microphone transcription)
- Click **`Voice`** in the Popup Window header
- Run `/spotify voice` (or `/spotify voice play midnight city`)

## Development

```sh
claude plugin validate --strict .
claude plugin test .
swiftc -O native/SpotifyMiniPlayer.swift -o bin/spotify-pip -framework Cocoa -framework WebKit -framework Speech -framework AVFoundation
```

## License

MIT (c) [Hemanth.HM](https://h3manth.com)
