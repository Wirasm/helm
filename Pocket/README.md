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

## Point it at benchd

benchd listens on TCP only when started with `BENCH_LISTEN=<host>:<port>`. Over Tailscale, use the
Mac's tailnet address, and type `tcp://<host>:<port>` into Pocket's connect sheet (tap the state at
the top right). Pocket keeps that URL and nothing else.

To try it in the simulator against a benchd of its own, never the operator's (AGENTS.md):

```
BENCH_DIR=$(mktemp -d /tmp/pk.XXXX) BENCH_SUITE=pocket-try BENCH_LISTEN=127.0.0.1:52230 \
  env -u BENCH_SESSION -u BENCH_HANDLE -u BENCH_ASKED -u HELM_PANE -u BENCH_URL \
  timeout 3600 daemon/target/debug/benchd
xcrun simctl launch <udid> com.wirasm.pocket -benchURL tcp://127.0.0.1:52230
```

## Put it on the phone

With a free Apple account: open the project in Xcode, pick your team under the Pocket target's
Signing & Capabilities, choose the phone as the destination and run. A free account's install
lasts seven days; run it again to renew. The first connection to the Mac may ask for Local
Network access.
