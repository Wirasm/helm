# Pocket

helm's iPhone app (#625): a third client of benchd, over TCP, for steering agents away from the
desk. It lists each workspace's agents (● asking, ✓ finished, ○ working), and opens one agent's
screen live, with a message box and keys (⏎ esc ^c 1 2 3 ⇥ and arrows) that reach it as keys.
It is never a remote for helm's window.

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

   It asks Tailscale for the Mac's tailnet address (`tailscale ip -4`, through
   `~/.tailscale/tailscaled.sock` when tailscaled runs as your own agent) and has the login
   agent's benchd listen on port 4519 (`--listen tailscale:<port>` for another). It stops,
   changing nothing, if Tailscale is not running; it never listens on every interface or a LAN
   address instead. (`--listen <host>:<port>` takes an address as you give it, except one that is
   every interface: that one is yours to choose.) Installing again without `--listen` stops
   benchd listening, and says so. It prints the URL Pocket dials:
   `benchd-agent: type tcp://100.x.y.z:4519 into Pocket's connect sheet`.

   **In userspace mode** (tailscaled run as your own agent with `--tun=userspace-networking`) no network
   interface carries the tailnet address; tailscaled takes tailnet connections itself and hands
   each to `127.0.0.1` on the same port. So benchd listens on `127.0.0.1:4519`, the installer says
   so, and Pocket still dials the tailnet address. Know what that means: in this mode **every port
   the Mac serves on 127.0.0.1 is reachable from your tailnet devices**, not only benchd's.
3. **Pocket on the phone, from Xcode with your personal team.** `xcodegen generate --spec
   Pocket/project.yml`, open `Pocket/Pocket.xcodeproj`, pick your team under the Pocket target's
   Signing & Capabilities, connect the phone, choose it as the destination and run. The first
   time, the phone wants Developer Mode on (Settings › Privacy & Security) and your developer
   profile trusted (Settings › General › VPN & Device Management). If Xcode says the bundle ID is
   taken, change `com.wirasm.pocket` there to one of your own.
4. **The URL.** Pocket opens on its connect sheet: type the `tcp://100.x.y.z:4519` URL step 2
   printed, the Mac's tailnet address in either mode. Pocket keeps that URL and nothing else; tap the state at the top right to change
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
