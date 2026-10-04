# Pocket

helm's iPhone app (#625): a third client of benchd, over TCP, for steering agents away from the
desk. It works like a messaging app, with two tabs. The chats list holds each workspace's running
agents (● asking, ✓ finished, ○ working), a workspace with one asking first and, in each, the
asking ones, then the orchestrators; a row shows the last message, or the subject of mail it sent
you that you have not read, and a dot when a reply came past what you last read. A chat is the
agent's own transcript (`sessions/log`): your prompts on the right, its replies as markdown
(headings, lists, code, quotes, tables), each with its time under it, a tool call as one line. The
field below types into the agent with Return; while it asks, the prompt's choices are buttons.
`screen` shows its terminal live, with keys (⏎ esc ^c 1 2 3 ⇥ and arrows). Swipe left or right for
the next or previous chat of the workspace; the name opens a searchable switcher. The pages list
holds each workspace's plan and review pages (its prp store's `.html` files), last edited first,
searchable; a page opens as helm renders a canvas, with a reply box when an agent opened it. It is
never a remote for helm's window.

A document path in an agent's reply is tappable when it names an `.md` or `.html` file inside a
store benchd serves. Absolute paths, `~/.prp/...`, inline code and markdown links open in Pocket:
markdown uses the chat renderer, HTML uses the page viewer. Back returns to the same chat. The
phone reads the document through benchd; paths outside its stores stay plain text.

It shares helm's code rather than copying it:

| Code | Where | What |
| --- | --- | --- |
| HelmWire | `Sources/HelmWire` | the wire: verbs, documents, sessions, screens |
| BenchKit | `Sources/BenchKit` | benchd's client: the socket, a request per verb, the follower |
| CanvasKit | `Sources/CanvasKit` | a canvas page: its address, its files through benchd, its live file |
| PocketKit | `Sources/PocketKit` | what Pocket shows and sends; `swift test` runs its tests |
| the app | `Pocket/App` | SwiftUI views only |

Nothing macOS-only goes into the first four. The gate's `ios` part builds Pocket for the iOS
simulator, which is what proves it.

## Build it

```
xcodegen generate --spec Pocket/project.yml
open Pocket/Pocket.xcodeproj
```

or, as the gate does, `bash scripts/check.sh ios`.

## Install

Once, at the Mac, with nothing in flight on the bench: step 2 restarts benchd, which ends every
session (`just resume-all` brings the panes back).

1. **Tailscale on the Mac and the phone**, signed in to the same tailnet. The tailnet is the
   only lock on benchd's port: it has no login of its own.
2. **benchd listens on the tailnet.** From the helm repo:

   ```
   just benchd-install --listen tailscale
   ```

   It asks Tailscale for the Mac's tailnet address (`tailscale ip -4`) and has the login
   agent's benchd listen there on port 4519 (`--listen tailscale:<port>` for another). It stops,
   changing nothing, if Tailscale is not running, or runs in userspace mode (no interface carries
   the address, so benchd could not listen on it: use the Tailscale app); it never listens on
   every interface, a LAN address or one typed by hand instead. Installing again with no flags,
   as the release steps do (`just benchd-install`), keeps it listening; `--no-listen` stops it.
   Every install prints the URL Pocket dials:
   `benchd-agent: type tcp://100.x.y.z:4519 into Pocket's connect sheet`.
3. **Pocket on the phone, from Xcode with your personal team.** `xcodegen generate --spec
   Pocket/project.yml`, open `Pocket/Pocket.xcodeproj`, pick your team under the Pocket target's
   Signing & Capabilities, connect the phone, choose it as the destination and run. The first
   time, the phone wants Developer Mode on (Settings › Privacy & Security) and your developer
   profile trusted (Settings › General › VPN & Device Management). If Xcode says the bundle ID is
   taken, change `com.wirasm.pocket` there to one of your own.
4. **The URL.** Pocket opens on its connect sheet: type the `tcp://100.x.y.z:4519` URL step 2
   printed, the Mac's tailnet address. Pocket keeps that URL, and per chat an unsent draft and how far you have read; tap the state at the top right to change
   it. iOS may ask once for Local Network access.

**A free personal team's install lasts seven days.** After that Pocket will not open: connect the
phone and run it from Xcode again. Nothing on the phone is lost; the URL is still there.

## Away from the desk

Pocket follows benchd over one long connection and reconnects by itself, quickly at first and
then every few seconds, when it drops: the phone slept, Pocket went to the background, the
network changed, benchd restarted. Coming back to the foreground it reconnects at once. The state
is at the top of every screen.

**Nothing is sent twice.** A message, a key, a reply or a start that benchd never received stays
where you typed it, to send again. One benchd received but did not answer may have gone through,
so Pocket clears it and says so: look at the screen before sending it again.

## Try it in the simulator

Against a benchd of its own, never the operator's (AGENTS.md):

```
env -u BENCH_SESSION -u BENCH_HANDLE -u BENCH_ASKED -u HELM_PANE -u BENCH_URL \
  BENCH_DIR=$(mktemp -d /tmp/pk.XXXX) BENCH_SUITE=pocket-try BENCH_LISTEN=127.0.0.1:52230 \
  timeout 3600 daemon/target/debug/benchd
xcrun simctl launch <udid> com.wirasm.pocket -benchURL tcp://127.0.0.1:52230
```

To test chat document links, install the iPhone 17 / iOS 26.3 simulator runtime, then run:

```
timeout 1200 cargo build --manifest-path daemon/Cargo.toml -p benchd
timeout 900 python3 Pocket/test-store-links.py /tmp/pocket-links-proof.xcresult
```

The fixture uses port 52247, a temporary home and a stub Claude session. It opens markdown and
HTML, checks an HTML sibling script, and returns to the chat after both. It also checks keyboard
dismissal, selection and the copy menu. Screenshots are attached to the result bundle. On exit,
it removes its simulator, temporary files and UI DerivedData.
