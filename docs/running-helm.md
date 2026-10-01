# Running helm: builds, a second instance, and seeing the window

`AGENTS.md` has the rules. This page has the detail: how a build reaches the operator, how to run
a helm that cannot touch his state, and how to look at a window without a display grant.

## Builds

`swift run helm` to iterate, `make app` for the real bundle.

**`make release` builds the bundle and tells a running helm about it; `make install` is that plus
the copy.** `install` refuses while helm runs, because replacing a live bundle leaves the process
on its old code. So the build leaves a note, `~/.helm/build/latest.json` (`HELM_BUILD_DIR`
redirects it), a running helm polls it, and a status-bar capsule offers the swap. Clicking quits
helm, installs and reopens; every terminal pane is a benchd session, so shells and agents keep
running. Watching `/Applications/Helm.app` instead cannot work: it only changes after the quit
the badge asks for.

- `scripts/stamp-build.sh` writes the commit into the source Info.plist as `HelmBuildSHA` before
  Xcode processes it, so CodeSign sees it (#526). `make release` runs `codesign --verify` and fails
  on a product without the key. Bundle mtime is no substitute: `cp -R` does not keep mtimes.
- The comparison is "different", never "newer": helm cannot order two shas without a checkout,
  and an older branch's build is still worth offering.
- An unstamped helm (the SwiftPM path) never badges (`testUnstampedBuildNeverBadges`). An
  isolated instance never polls (`BuildUpdateModel`). Two dirty builds of one commit share
  `<sha>-dirty` and do not badge each other.
- The stamp is written by shell and read by Swift; `BuildStampScriptTests` runs the scripts and
  decodes their output with the real types.

**`just release-resume <session-id> [cwd]` swaps everything for an operator who is away (#404).**
It builds (`make release`, `cargo install` of `bench` and `benchd`), quits helm by pid, restarts
benchd (`launchctl kickstart -k` when the login agent from `just benchd-install` is loaded), swaps
the bundle with `BundleSwap.script`, resumes that Claude Code session with `bench spawn --resume
--remote-control` in a pane of the new helm, then runs `bench restore --all` for the other panes.
It detaches first, since the caller is normally in a pane the quit closes. Once helm is quit the
session always comes back: a later failure resumes it outside helm with `claude --bg --resume`.
The log is `~/.helm/build/release-resume.log`, last line `RESULT:`. Every target is a flag
(`--bundle`, `--pid`, `--suite`, `--bench-suite`, `--cargo-root`, `--env`, `--no-remote-control`),
which is how it is tested. Two things are easy to undo by accident: it relaunches through `env -i`,
because `open` hands the app the caller's environment (`CLAUDECODE`, the session id) and every pane
would inherit it; and it holds `caffeinate -d -u`, because with every display asleep the new helm
cannot create a terminal. Restarting benchd ends every session, so run it for real only when the
operator says nothing is in flight.

## Where helm keeps state

helm persists to one defaults domain, `com.wirasm.helm`, from both launch paths, so "did it
persist?" is `defaults read com.wirasm.helm`. The identity is spelled in `SPMInfo.plist`,
`project.yml`'s `PRODUCT_BUNDLE_IDENTIFIER` and `DefaultsDomain.canonical`; `DefaultsDomainTests`
fails if they drift.

helm's own directory is `~/.helm/bench` (`HelmBenchDirectory`): the bench snapshot and the
operator's `keymap.toml`. It stays on helm's machine when benchd is on another.

## A second helm

```
BENCH_SUITE=helm-bench benchd &    # its own benchd first: the suite moves benchd's root too
HELM_DEFAULTS_SUITE=helm-bench swift run helm
```

`HELM_DEFAULTS_SUITE=<name>` moves three things: the defaults (`UserDefaults(suiteName:)` does not
read through to the app's domain), helm's directory (`~/.helm/bench-<name>`), and benchd's root
(`~/.bench-<name>`, unless `BENCH_DIR` or `BENCH_SUITE` names another; `BENCH_URL` replaces the
socket outright). Panes export
`BENCH_SUITE=<name>` (`PaneEnvironment.suiteDeclaration`), so `bench` inside them reaches the same
daemon. Prove isolation with `defaults read <name>` and the negative with `defaults read
com.wirasm.helm`.

Two helms are otherwise indistinguishable by name, to `winshot` and to a reader. Refusals are
loud: the legacy `helm` domain, a path, `NSGlobalDomain`, and a name benchd's
`SuiteName` cannot take (such as `Helm-Bench`) stop the launch or the pane rather than fall back to
the operator's state. An isolated instance shows its suite on a status-bar capsule and is titled
`helm — <name>`. The window frame is AppKit's autosave and is not moved by the suite. Do not
hand-roll a throwaway `PRODUCT_BUNDLE_IDENTIFIER`.

Before the root moved with the suite (#378), an isolated helm opened the operator's shared browser
and forwarded its clicks into his signed-in Chrome.

## Seeing the window

**`bench get screenshot [--out <p.png>] [--window <title>]`**: helm draws its own view hierarchy,
which TCC does not gate, so it needs no grant, no display and no Accessibility, and works with the
screen locked. benchd asks the helm following it (`helm/asked`, answered by `HelmAsks`) and writes
the PNG on benchd's machine. Exit 4 names the cause when no helm answers in ten seconds.

- Read `terminalContent`: `included`, `excluded` (regions carry a printed marker), `partial` or
  `absent`. Ghostty's layer is swapped for an IOSurface-backed one once compositing starts
  (`AppTerminalView.updateMetalLayerMetrics`), and that one draws, so do not assume either way.
- `windowVisible: false` means WebKit suspended an occluded page, and a blank canvas in the PNG
  is not a bug (#408).
- With two helms running, `--window` takes a title substring. Ambiguity is refused.
- `scale` is the display's backing scale; divide `pixelWidth` by it for points.

**`swift tools/winshot.swift helm <out.png>`** captures from outside and needs Screen Recording on
the invoking context, which an agent's fresh, ad-hoc-signed binary usually does not have; it exits
nonzero without it. `--list` needs no grant and tells a real window from a crash or a zero-sized
one, but it only sees the current Space, so absence is not evidence the app is gone: check the
process. It matches owner names and window titles by substring, so a worktree helm and an editor
with `helm` open both match. Capture by pid when it matters. Use it for what helm cannot draw,
such as another app.

The accessibility tree is a dead end: helm's centre is a Metal-layer view with no children.
