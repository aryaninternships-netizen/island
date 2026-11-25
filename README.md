# Island

**Your MacBook notch, made useful.** Island turns the camera notch into a live strip for music,
meetings, timers, files and quick toggles, and adds a few things no other notch app does:
meeting notes with an on-device Whisper transcript, a heads-up before every calendar event,
a face-aware away lock, a teleprompter that hangs under the camera, and a tiny dalmatian named Bruno.

Everything runs on your Mac. No account, no server, no analytics.

> Beta 0.9. Built by Aryan Singh. Free and open source (MIT).

---

## Contents
- [Install](#install)
- [First run: what Island asks for, and why](#first-run-what-island-asks-for-and-why)
- [Everything it does](#everything-it-does)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Settings](#settings)
- [Privacy](#privacy)
- [Scripting: the `island` CLI and `island://` links](#scripting-the-island-cli-and-island-links)
- [Build from source](#build-from-source)
- [Known limits](#known-limits)
- [Credits](#credits)

---

## Install

**Needs:** a Mac with Apple silicon (M1 or later), macOS 14.4 or newer. A notch is nice but not
required (on other screens Island sits at the top centre). Smart meeting summaries need
macOS 26 with Apple Intelligence on; everything else works without it.

1. Download `Island-0.9.0.dmg` from [Releases](https://github.com/aryaninternships-netizen/island/releases).
2. Open it and drag **Island** into **Applications**.
3. Open Island from Applications.

**"Apple could not verify Island…"** This beta is not notarized by Apple yet, so macOS blocks the
first launch. Open **System Settings › Privacy & Security**, scroll down, click **Open Anyway** next
to Island, and confirm. You only do this once per version.

Island then starts at login and keeps itself running. Quit it any time from its menu bar icon
(the small capsule) › **Quit Island**, or switch off **Settings › General › Start at login**.

**Uninstall:** quit Island, delete it from Applications, and remove
`~/Library/LaunchAgents/app.island.notch.plist` and `~/Library/Application Support/Island`.

## First run: what Island asks for, and why

A four-card welcome tour opens from the notch. Nothing asks for a permission until the card that
needs it, and every card can be skipped. You can replay it from **Settings › General › Welcome tour**.

| Permission | Asked when | Used for |
|---|---|---|
| Calendars | Welcome card 2, or Settings › Meetings | Next meeting, Join button, the heads-up before each event |
| Camera | Registering your face | Away lock, Guard, lock-screen face unlock. Off until you register |
| Microphone | First meeting recording | The Room track of meeting notes |
| System Audio Recording | First meeting recording | The Call track (Zoom, Meet, Teams voices) |
| Speech Recognition | First meeting recording | The live transcript while you record |
| Accessibility | Optional, menu bar tidy-up / tray | Reading and clicking folded menu bar icons |
| Downloads folder | Optional | The download-progress pill |

Skip any of them and the rest of Island still works; the feature that needs it says so and links
to the right System Settings pane.

## Everything it does

### In the notch (closed)
- **Now Playing** from any player (Chrome, Safari, Spotify, Music, YouTube): artwork on the left, an
  artwork-tinted equaliser on the right. A banner drops down when the track changes.
- **Volume and brightness** HUD replaces the system one. **Two-finger scroll** on the notch changes the volume.
- **Battery**: plug, unplug, 20% and 10% alerts, time to full.
- **Live pills**: running timer countdown, download progress, recording time, Claude Code status.
- **Hover** to open, move away to close. Click to open. Drag a file toward the notch to open the shelf.

### Now (home tab)
Ranks what matters this minute: a meeting starting within 15 minutes takes the stage with a countdown
and **Join**; otherwise the player (scrub to seek); otherwise a big quiet clock.
The right column lists only live things (timer, face unlock session, recording, charging, weather,
next event), and the **dock** under it holds one-tap toggles: Guard, Away lock, Keep Awake, Quiet.
Hover a dock button to see its name.

### Desk tab
- One row of actions: **Record** a meeting, **Prompter**, **5m / 15m** timers (scroll on them to change
  the minutes), **Focus** (25 min, then a 5 min break; Quiet turns on by itself), **Stopwatch**.
- **Quick note**: type and press ⌘↩ to append a timestamped line to today's notes file
  (Documents › Island Notes), or to the meeting notes while recording.
- **Clipboard history**: the last 25 things you copied, in memory only. Password-manager items are
  skipped. Click to copy back, pin up to 5 to keep them across restarts.

### Calendar and meeting heads-up
- Reads every calendar on your Mac: iCloud, **Google** (add your Gmail in
  System Settings › Internet Accounts, or from Settings › Meetings › Add Google), Exchange, subscribed.
  Hide individual calendars in Settings › Meetings › Show.
- **5, 10 or 15 minutes before every timed meeting**, Bruno runs out with a banner and a
  shockwave from the notch. At start time Island opens with **Join** one click away
  (Meet, Zoom, Teams, Webex links are found in the event's URL, location or notes).

### Meeting notes
- **Record** from the Desk, the meeting card, ⌃⌥R, or accept the offer when Zoom/Meet/Teams takes the mic.
- Two tracks: **Room** (your mic, with a far-field voice chain: high-pass, boom cut, presence lift,
  leveller, soft gate, limiter; or **Near** mode with Apple voice processing) and **Call** (what your
  Mac plays, via a Core Audio process tap). Labelled separately in the transcript.
- **Live transcript** on device while you record. **Mark** moments with ⌃⌥M.
- On stop: **smart notes** (summary, decisions, action items) from Apple's on-device model, saved to
  `~/Documents/Island Meetings/<date title>/` as `notes.md` + `recording.m4a`, and a recap card on Home.
  Action items can be sent to Reminders.
- **Accurate transcript (Whisper)**: Settings › Meetings › Download (550 MB, once). After each meeting
  Island transcribes both tracks again with whisper.cpp large-v3-turbo on your Mac's GPU (about 8× real
  time on an M2), removes the lines your mic picked up from the speakers, and rewrites the notes.
  The first version is kept as `notes.live.md`.
- Crash-safe: the transcript is written line by line as it happens; if Island or the Mac stops
  mid-meeting, it offers **Recover** on next launch and rebuilds the recording and notes.
- Survives device changes: AirPods connecting, a USB mic unplugged, or sleep and wake reconnect the
  audio and keep writing the same files.
- **Consent**: a short banner says the meeting is being recorded when you start. Recording other
  people may need their consent where you live; tell them.

### Teleprompter
A black pane hangs from the notch, right under the camera, so you read while looking at the lens.
⌃⌥P on/off, ⌃⌥O roll or pause, ⌃⌥↓/↑ speed, click to pause, scroll to move by hand. Paste a script
from Desk › Prompter. Hidden from screen sharing, always.

### Away lock and Guard (camera)
- **Register your face** once (Settings › Away & lock, about 20 s, slowly turn your head).
  Stored as numbers (Apple Vision faceprints) in `~/Library/Application Support/Island/face.json`,
  never as a photo.
- **Away lock**: typing or using the trackpad means you are there, so the camera stays off. After
  15 s idle Island takes a one-second look. If you are gone, the screen blurs to a quiet clock;
  look at the camera and blink to open it, no password. Anyone else, or 3 minutes passing, hands
  over to the real macOS lock screen (Touch ID works there).
- **Guard** (⌃⌥G or the shield): for leaving the Mac in a room. Someone else facing the screen or
  touching the keyboard is photographed and the Mac locks. Back at the Mac you see "N people were
  at your Mac" with their faces; the eye tab lists every incident.
  Photos are saved in `~/Pictures/Island Guard`.
- **Face unlock at the lock screen** (optional, off by default): Island types your Mac password when
  it sees your live face after a lock. You type the password into Island once (kept in your login
  keychain, readable only by Island) and start an 8-24 h session with Touch ID. Restart or log out
  always needs the password.
  **Convenience, not security**: a 2D webcam can be fooled by a good video of you.

### Bruno
A small black-and-white dalmatian who lives in the notch: greets you in the morning, brings the
meeting heads-up, dances to music, asks for food at lunch, tells you to go home in the evening,
naps when you are away. Click him for his tab: feed, play, pet, or chat.
His lines come from his own ~10M-parameter model that runs inside Island on the CPU in milliseconds
(see `pup/`). **Settings › Focus & breaks › Pup** turns him off.

### Also
- **Shelf**: drop files on the notch, drag them out later, AirDrop them all. Kept across launches.
- **Tidy menu bar**: fold extra menu bar icons behind a divider; the tray tab shows and clicks them.
- **Keep Awake** for 1-24 h, **Quiet** (mutes the chatty extras, never alerts), **Sit reminder**.
- **Command bar** (⌃⌥Space): type `25` for a timer, `q` for Quiet, `g` for Guard, `> text` for a note,
  or a tab name.
- **Screen sharing**: Island hides itself from screen shares by default; turn **Show in screen share**
  on if you want people to see it.
- **Claude Code**: optional hooks show "Claude is working / done / needs you" in the notch
  (see `bin/claude-hook`).
- **Accessibility**: VoiceOver labels throughout, Reduce Motion respected, Increase Contrast lifts
  dim text, Differentiate Without Colour adds shapes.

## Keyboard shortcuts

| Keys | Does |
|---|---|
| ⌃⌥Space | Open Island and the command bar |
| ⌃⌥R | Record a meeting / stop and write notes |
| ⌃⌥M | Mark this moment while recording |
| ⌃⌥P | Teleprompter on/off |
| ⌃⌥O | Teleprompter roll / pause |
| ⌃⌥↓ ⌃⌥↑ | Teleprompter slower / faster (while on) |
| ⌃⌥H | Hide Island (panic hide) |
| ⌃⌥T | Hold to peek |
| ⌃⌥G | Guard now |
| Esc | Close |

## Settings

Gear tab in the open island, six sections:
- **General**: open on hover, start at login, show in screen share, tidy menu bar, weather, clipboard
  history, welcome tour, quit.
- **Meetings**: calendar accounts and **Add Google**, which calendars to show, heads-up time
  (5/10/15 min), Bruno brings it, offer to take call notes, accurate transcript (Whisper).
- **Look & alerts**: sounds, volume and brightness HUD, battery alerts, song banner, starry
  background, the effect when a mode turns on (Burst, Border, Off) and burst style.
- **Away & lock**: Off / Lock / Guard, lock-after time, your face, face unlock.
- **Focus & breaks**: focus and break length, sit reminder, Bruno.
- **Shortcuts**: the list above.

## Privacy

Nothing about you leaves your Mac. What does touch the network, and when:

| What | When | Sends |
|---|---|---|
| Weather | Every 30 min if **Settings › General › Weather** is on | A request to wttr.in, which places you by IP address |
| Whisper model | Once, when you press **Download** | A download from Hugging Face |
| Join | When you click it | Opens the meeting link in your browser |

Recordings, transcripts, notes, face data, Guard photos, clipboard history and your password stay
on this Mac. Speech recognition is forced on device (no Apple servers). Smart notes use Apple's
on-device model. There is no telemetry.

## Scripting: the `island` CLI and `island://` links

Push your own live activities from any script:

```bash
island notify "Build done" "47s, 0 warnings" --icon hammer.fill --color orange
island notify "Scraping" --id job --sticky --progress 0.42 --icon arrow.down.circle --color teal
island dismiss --id job
island open
```

Link `bin/island` onto your PATH (`ln -s "$PWD/bin/island" /opt/homebrew/bin/island`).
Under the hood these are `island://notify?title=..&body=..&icon=..&color=..&id=..&sticky=1&progress=0.4`.
Safe verbs (`notify`, `dismiss`, `open?tab=desk`, `timer?min=10`, `focus`, `stopwatch`, `awake?hours=2`,
`hush`) work from anywhere. Verbs that change security, record or show private data
(`guard`, `meeting`, `share`, `away`, `lockface`, …) need the local key in
`~/Library/Application Support/Island/url.key`; the CLI adds it for you, a web page cannot.

## Build from source

Needs Xcode Command Line Tools (`xcode-select --install`), `cmake` (`brew install cmake`), git.
Xcode itself is not needed.

```bash
git clone https://github.com/aryaninternships-netizen/island && cd island
./build.sh                                  # -> build/Island.app
cp -R build/Island.app /Applications/
scripts/make-dmg.sh                         # -> dist/Island-<version>.dmg
```

The first build fetches and compiles mediaremote-adapter (Now Playing) and whisper.cpp (v1.9.6,
static, Metal). Bruno's model `pup/pup.bin` is attached to each release (it is too big for git);
put it in `pup/` before building, or rebuild it with `pup/train.py`.

**Local overrides** go in an untracked `.local.env` next to `build.sh`:

```bash
BUNDLE_ID=com.you.island                        # default app.island.notch
SIGN_ID="Developer ID Application: You (TEAMID)"  # default: ad-hoc
SIGN_KEYCHAIN=~/Library/Keychains/your.keychain-db  # optional
```

With an ad-hoc signature macOS forgets the camera and microphone grants on every rebuild; any
stable identity (even a self-signed one) avoids that. A Developer ID build also gets the hardened
runtime and `Resources/Island.entitlements`.

Handy tools: `tools/facecal` checks face photos against your profile, `tools/attntest` runs the Guard
scenarios, `tools/gptcheck` checks Bruno's Swift engine against the MLX one.

## Known limits

- Not notarized yet (needs an Apple Developer ID), hence the **Open Anyway** step.
- Face features use a 2D webcam: good for convenience, not proof against a video of you.
- Now Playing uses a small helper around Apple's private MediaRemote framework; a future macOS
  update can break it.
- Apple's live transcript catches roughly 40% of the words in a noisy call; the Whisper pass after
  the meeting is the accurate one.
- Smart summaries need Apple Intelligence (macOS 26). Without it the notes fall back to a simple
  rules-based summary; the transcript is still complete.
- The process tap records call audio from the meeting app's own process; a few apps that play
  audio from helper processes may need **Call** to be checked after the first try.

## Credits

Made by **Aryan Singh**.

Built on ideas and code from:
- [Lakr233/NotchDrop](https://github.com/Lakr233/NotchDrop) (MIT): notch window and file shelf.
- [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3): Now Playing on macOS 15.4+.
- [jonnyoo/glance](https://github.com/jonnyoo/glance) (MIT): liveness cues and the lock-screen unlock approach.
- [Lakr233/SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) (MIT): window over the lock screen.
- [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) and OpenAI Whisper (MIT): accurate transcripts.
- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) (GPL-3): inspiration only, no code copied.

Full licence texts in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Island itself is MIT ([LICENSE](LICENSE)).
