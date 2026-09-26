# AGENTS.md — helm

Native macOS surface: SwiftUI + GhosttyKit. Workspaces above a **workbench** — columns of
tabbed slots holding terminal and canvas panes, several on screen at once. **No backend** —
artifacts are files. Vocabulary is canonical in `CONTEXT.md`.

**"Agent" means a CLI agent already in use — Claude Code, pi, codex.** helm hosts one in a
terminal it owns and renders what it writes. It never builds or hosts an agent of its own.

Direction: `docs/direction.md` (an entry point, not a spec).

`docs/future-planning/` is a **proposal, not the tree** — an audit of helm plus a milestone plan for a headless-daemon successor. Its roadmap is written in the imperative and reads as a work order; it is not one. **Work there starts when the operator names a milestone, and only then.** Its audit's Part I is a real measurement of this tree and is safe to read for that; the rest describes something that does not exist. The directory's own `README.md` says the same thing to whoever opens it first.

## Working here

Gate, all green before a PR to `development`:

```
just check              # or, with no `just` installed: bash scripts/check.sh
```

`scripts/check.sh` is the one definition of the gate, and CI calls the same script. It runs
its parts in order and ends with one line per part: `PASS`, `FAIL (rerun: <command>)`, or
`SKIP (<why>)`. `just check swift` (or any other part names) runs only those.

| Part | Runs | Needs |
| --- | --- | --- |
| `lint` | `make lint`: formatting and the size limits below | Swift toolchain |
| `swift` | `swift build && swift test && xcodegen generate` (SwiftPM calls add `--disable-keychain`), unless every change is one no Swift build or test reads (`swift_ignores`: `docs/`, `pi/`, `daemon/` but not its fixtures, markdown outside `Sources/`, `Tests/` and skills) | Swift toolchain, xcodegen |
| `skills` | the canvas, board and post-canvas skill gates | node, zsh, python3, git |
| `daemon` | `daemon/test.sh`, only when `daemon/`, `daemon.yml`, a `bench-*` skill or `RenderableFile.swift` (the CLI's `bench open` checks its list) changed | cargo |
| `pi` | the `pi-extensions` gate, only when `pi/` changed | node, `npm install` in `pi/` |

"Changed" means against `origin/development`, committed or not. A missing tool is a `FAIL`
naming it, never a silent skip. The path rules live only in `scripts/check.sh`
(`scripts/check.sh --needs <part> [base]` asks one), and CI's daemon job asks the same function.

**Size limits (#418).** `lint` fails any new Swift function over cyclomatic complexity 15 or
60 body lines, a closure over 50, a type over 350 or a file over 600 code lines
(`.swiftlint.yml`, SwiftLint pinned in `tools/lint/`). `daemon` fails any new Rust function over
clippy's cognitive complexity 25 or 100 lines. Each finding names the file, the line, the
declaration and the number. **Split the code; never add a marker to new code.** Code that was
already over a limit carries a marker recording its value then
(`// swiftlint:disable:next … - legacy (#418): 24, limit 15`, or `#[expect(clippy::…, reason =
"legacy (#418): …")]`); once that code is back under the limit the marker fails the gate until
you delete it, so the markers only shrink.

**Ghostty is official Ghostty built by us** (`Packages/GhosttyTerminal/`: the GhosttyKit
binary pinned by commit and checksum, plus the Swift wrapper helm owns). A fresh worktree
downloads the binary on its first build and needs nothing else. Moving to a newer Ghostty is
`scripts/bump-ghostty.sh`, which needs zig; `docs/VENDORED.md` ("Ghostty") has the procedure.
A `.build` from before that move fails with `missing required module 'libghostty'`: the old
wrapper's `GhosttyKit.swiftmodule` shadows the official one. `rm -rf .build` once.

**To run one suite alone, set `INJECTION_NOGENERICS=1`:**

```
INJECTION_NOGENERICS=1 swift test --filter TerminalKeyboardTests
```

Without it `--filter` dies with `error: signalled(10)` from `swiftpm-xctest-helper`, and that
was read for months as "helm's bundle cannot be enumerated". It is not helm's bundle. The
helper `dlopen`s the test bundle, that runs `+[NSObject(InjectionBoot) load]`, and
InjectionNext rebinds `swift_allocateGenericClassMetadata` across every loaded image —
`rebind_symbols_image` takes SIGBUS on a `KERN_PROTECTION_FAILURE` (read the `.ips` in
`~/Library/Logs/DiagnosticReports`, it names every frame). A normal `swift test` survives it
because InjectionNext skips the hook when `XCTestConfigurationFilePath` is in the environment
and the real `xctest` host sets it; the bare helper sets nothing. `INJECTION_NOGENERICS=1` is
the same off switch by its other name, and it changes nothing else — the hook only exists to
hot-swap generics in a running app.

`xcrun xctest -XCTest HelmTests.TerminalKeyboardTests/testFoo <bundle>.xctest` is the other
way in, and it never involves the helper at all. Useful against a bundle you did not just
build — including an old one, which is how #192 was settled.

**What the gate guarantees when several agents share the machine — which is now the normal
state here, not the exception.** `swift test` is *broadly* not load-sensitive — the two
documented exceptions are named immediately below, and everything else in the suite is not one
— and a red keyboard test is *not* evidence that the machine is busy. That was assumed once, cost
two confident wrong diagnoses in an afternoon, and #192 is the measurement that disproved it: a
test bundle built
at 13:19 and never rebuilt was green at 13:19 and red at 19:00, and every worktree on the
machine went red within the same second (17:17:19). Concurrency did not do that; nothing in
any diff did.

**Two tests are the documented exceptions to that line, and the shape they share is the thing
to recognise rather than the list to memorise: an assertion whose truth depends on a
`Task.sleep` staying *inside* a deadline.** `Task.sleep(for:)` is a floor and not a promise, so
a contended machine overshoots it, the behaviour under test happens **correctly**, and the test
calls that a failure.

- `FileWatcherTests.testAWriteThatArrivesInChunksRendersOnceAndOnlyWhenItIsWhole` — chunks that
  must all land inside one debounce window (#305).
- `CanvasEditorTests.testARunOfTypingIsOneSave` — the same shape on the editor's autosave, and
  it went red in CI on #314 while every other test passed (#289).

Both now carry margins of 50× or more and say so in their own headers. **The direction is what
makes the rest of the suite safe**: a test that sleeps to let a window *elapse* is only made
more certain by an overshoot, which is why the sibling tests beside both of these have never
flaked — say which direction yours sleeps in before adding a third.

**Reproduce one by inverting its parameters, not by adding load.** Measured twice, on two
different tests: #305's six bounded burners reached load 7.68 and the old values passed three
times, and #314's twelve reached load 43 with the fixed values passing 6/6. Setting the window
*below* the gap failed byte-identically to CI, first time, on both. Load is the slowest way to
find out and the least conclusive; **if you do reach for burners, `timeout`-bound them** — the
rule further down is there because twelve of them once outlived their script by nine hours.

So before suspecting your diff, or the load, ask ghostty — **by absolute path, and asking
CoreVideo at the same time**:

```
/usr/bin/log show --last 30m --style compact \
  --predicate 'subsystem == "com.mitchellh.ghostty" OR subsystem == "com.apple.corevideo"'
```

**`/usr/bin/` is not decoration: `log` is a zsh builtin, and zsh is what Claude Code's Bash
tool runs.** A bare `log show …` never reaches `/usr/bin/log` at all — it hits the builtin,
which answers `(eval):log:1: too many arguments`. On its own that exits 1, but piped into
`grep` or `head`, which is how anyone actually reads a log, the pipeline reports the *last*
command's status and the whole thing exits **0 with no output**: a successful-looking query of
an empty log. Three agents read it exactly that way and concluded the log was empty. It was
not — 3562 lines in 90 minutes (#249). Measured, and it is the shell that decides: the bare
form dies under zsh and works under fish and bash, while the `/usr/bin/log` form above returns
the same output under all three.

**Two lines matter, and they land within a millisecond of each other in the same process:**

```
[com.apple.corevideo:] CVDisplayLinkCreateWithCGDisplays error -6661 due to invalid display count (0)
[com.mitchellh.ghostty:embedded_window] embedded_window: error initializing surface err=error.OutOfMemory
```

The **ghostty** line is what ties the failure to a surface: `ghostty_surface_new` refused, so
**no terminal exists to type into** and every keystroke assertion in `TerminalKeyboardTests`
and `WorkbenchFocusRoutingTests` fails for that reason alone, on any tree.

The **CoreVideo** line is the one that names the cause, and `err=error.OutOfMemory` is a
misleading name for it: every display asleep means zero *active* displays, so
`CVDisplayLinkCreateWithActiveCGDisplays` fails and ghostty reports the whole surface init as
out of memory. It is not memory — #253 ruled that out with numbers, and reproduced `-6661`
with no helm involved. An agent that finds the ghostty line and stops has been pointed at the
wrong subsystem, which is why the predicate names both: the old one, on ghostty alone, could
not have shown the cause even on the runs where it did execute.

**The control run is the other half of the evidence, and it stands on its own.** Revert to
`origin/development` with `git checkout origin/development -- <files>`, grep the files to
confirm the revert actually landed, rebuild, and show the same failures on the pristine base.
It needs no subsystem knowledge, it does not depend on a log window that may have rolled, and
it works when the log says nothing at all — three agents reached for it unprompted before
anyone sanctioned it. Bring it *with* the log lines when you have both; bring it alone when
you do not. A branch that touches no compiled code has a stronger version still: say so, and
the test binary is byte-identical to base.

Those two suites now name the surface failure themselves rather than reporting `pty saw
<nothing>` — the sentence that reads as a focus bug and is not one. Everything in them that
does *not* need a surface still runs and still fails on a real regression: proved by
reinstating #96's contract (seven tests then also fail on the first-responder assertion) and
#152's click routing (five more, on the bench). A surface failure is an **environment** report,
not a verdict on the diff — and the evidence to bring is the CoreVideo/ghostty pair, the
control run, or both.

**The `lint` and `swift` parts need only the Swift toolchain and xcodegen. Keep it that way.**
They are what a fresh worktree has to pass, and every dependency added to them is a dependency
every contributor now needs. The other parts need node or cargo, which is why they are separate
parts and separate CI jobs.

**CI runs the same parts, with two differences.** Its jobs are `build · test · format` (`lint`
then `swift`), `skill gates` (`skills`) and
`fmt · clippy · build · test` (`daemon`). The first and last report success without running when
nothing they cover changed, using the `swift` and `daemon` `--needs` rules (the Swift job skips
its `lint` step on the `swift` answer too). `skills` runs on every PR, whatever it touched, and so does `just check`:
*"a gate that exists, is documented in `AGENTS.md`, and runs only when somebody remembers is the
drift this workflow exists to stop."* There is no `pi` job: it needs an `npm install` in `pi/`,
so only `just check` runs it.

- **Narrower on the Swift job**, by exactly the two suites this section spends forty lines
  teaching you to diagnose. CI sets `HELM_CHECK_HEADLESS=1`, which makes the `swift` part run
  `INJECTION_NOGENERICS=1 swift test --disable-keychain --skip TerminalKeyboardTests --skip
  WorkbenchFocusRoutingTests`.
  A runner has no active display and those two need a real ghostty surface (#253) — excluded
  rather than tolerated, since a gate whose red is sometimes meaningless is a gate nobody reads.
  So **a green CI is not a green local gate**: a regression in either suite passes CI, and
  `just check` before the PR is the only thing that catches it.
- **And a green local gate is not a green CI either**: CI runs against the
  **merge commit** rather than your branch tip. That is why it exists — two PRs merged 56 seconds
  apart on 2026-08-06, both green on their own branches, both reviewed, touching different files,
  and `development` did not compile.

**`pi/`'s gate is separate on purpose; `just check` runs it when `pi/` changed. Alone:**

```
bash .claude/skills/pi-extensions/scripts/test.sh
```

**`daemon/`'s gate (the `daemon` part), alone:**

```
bash daemon/test.sh
```

`daemon/` is the bench daemon (`benchd`) — a self-contained Rust cargo workspace, the
same carve-out as `pi/`: its gate needs only the Rust toolchain, its CI job
runs only when `daemon/**`, a `.claude/skills/bench-*` skill (the gate executes those skills'
snippets) or `Sources/Helm/Shared/RenderableFile.swift` (the CLI's `bench open` checks its list
against it) changed, and the Swift gate never learns about it. Read
`daemon/direction.md` before working there; the milestone sequence is
`docs/future-planning/bench-roadmap.md` (target shape: `bench-architecture.md` beside it), and
M0 (skeleton), M5a (daemon-owned ptys), mail, the shared browser (#350) and the daemon half
of the bench document (M4, #354) are the parts that exist. helm renders the bench from that
document and keeps none of its own.

**If you touched `.archon/workflows/helm/`, run its gate:**

```
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .archon/workflows/helm/.shared
archon validate workflows helm-merge-queue
```

That is `helm-merge-queue` (#420), the prototype merge queue the orchestrator lands PRs with.
Its README says how to run it and what it is testing. The rest of `.archon/` stays gitignored
(#263).

**`.claude/skills/helm-board/`'s gate (part of `skills`), alone:**

```
bash .claude/skills/helm-board/test.sh
```

That skill is the drawable board (#111) — the word `CONTEXT.md` now defines against
`Sources/Helm/Board/`, which is a different thing: `@quickdrawjs/core` 0.2.0 vendored, copied *beside*
an artifact rather than injected, so it is a skill asset and not a bundle resource. Its gate
**executes** `board-core.js` in node — the ownership diff, the overlap resolution and the state
report all live there rather than in the DOM glue, precisely so a browser is not needed to test
them — checks `new-board.sh`'s refusals, and re-hashes the vendored bytes against their pin.
Needs node, which is why it is not in the Swift gate. **The one thing in that seam the Swift
gate does own is `data-helm-surface`**, because three files spell it and one of them is Swift —
see `CanvasSurface` and `CanvasSurfaceTests`.

**`.claude/skills/post-canvas/`'s gate (part of `skills`), alone:**

```
bash .claude/skills/post-canvas/test.sh
```

That skill previews a video stored by the archon-video workflow pack as a canvas. Its gate builds
stored runs in a temp `ARCHON_HOME` shaped like the pack's `store.py` output, runs the driver
against them with `--no-push` only, and executes the `SKILL.md` snippet under zsh with `PRP_HOME`
redirected. Needs node, git and zsh.

**The canvas skill has no gate of its own since `push.sh` retired (M3).** An agent puts an artifact
on the bench with `bench open`, a verb to benchd rather than an escape sequence into a terminal, so
it works from a tool call, a script and a benchd-spawned agent alike. `push.sh` was the third
mechanism to hold that job and each shipped silent somewhere: a ⌘-click the TUI ate (#124), a bare
`printf` the harness captured (#184), then a real OSC into a terminal helm did not own (#282). The
skill's snippets run in the daemon gate against a real benchd, as the `bench-*` skills' do.

**helm keeps no mailroom (#358). Mail is benchd's**, and helm is one of its clients. Until #358
helm had its own: `hooks/helm-mail.mjs` for Claude Code, `pi/extensions/helm-mail` for pi, one
convention written twice, a conformance harness to keep the copies honest, and helm reading
`~/.helm/mail` every two seconds to learn who was in which pane. All of that is deleted, and
`~/.helm/mail` is left on disk as history, read by nothing.

- **An agent reports itself through `bench hook <claude|codex|pi>`**, one fixed command in its
  own hooks (pi: `pi/extensions/bench`). The reply carries its unread mail as pointer lines, so a
  busy agent reads mail at its next tool call; an idle one is started through its own channel.
  `daemon/direction.md` has the whole design and `bench wiring --check` says whether a harness is
  wired. A session claims an address only when helm or benchd declared it (`HELM_PANE`,
  `BENCH_SESSION`) **and** it runs on a terminal: `HELM_PANE` is inherited by everything a pane's
  agent spawns, but tool calls run detached, so the terminal is what tells the pane's own agent
  from its children (#417).
- **Which agent is in a pane is one question with one answer: benchd's `mail/who` verb**
  (`BenchMailbox` in `Sources/Helm/Mail/`, the wire types in `Sources/HelmWire/Bench/BenchMail.swift`,
  both shapes pinned by `daemon/fixtures/mail-verbs.json`). `CanvasNoteCourier` asks it where a
  mark goes; for a pane showing a benchd session benchd answers from the session itself. Do not add a second join: helm has no
  record of its own to join against any more.
- **With no benchd, nothing is addressable, and each caller says so** rather than guessing: a
  canvas note goes to the clipboard with the reason on the pane.
- **`HELM_MAIL_DIR`, `HELM_MAIL_OFF` and `HELM_MAIL_HANDLE` mean nothing now.** Isolation is
  benchd's: `BENCH_DIR` or `BENCH_SUITE` points a test at its own daemon and record root.

Only when `pi/` changed. It needs node, and `tsc` from an `npm install` in `pi/`, which is
why it is not part of the Swift gate: `swift test` cannot run TypeScript and should not
learn how, and a Swift contributor should never need a JS toolchain to go green. See
`pi/AGENTS.md`.

- **Never restart a running helm without warning the operator** — a live window may be
  hosting their session.
- **Kill only a pid you have verified is yours, never a pattern.** `pkill -f "\.build/debug/helm"`
  cannot see a teammate's `swift run` binary path and cannot tell the operator's helm from a
  worktree build. An agent reached for exactly that this morning; nothing died that shouldn't
  have, and that was luck rather than design.
- **Anything you spawn must die without you, and cleanup on the last line is not that.** This is
  the half the rule above was missing, and it cost a day. #291's load measurement started twelve
  CPU burners on purpose — it is where that ticket's *"0.26s idle, 1.16s at load 9"* came from —
  and ended with `for p in $BURNERS; do kill $p; done`. The parent shell died before reaching it.
  All twelve reparented to `init` and spun at **~81% CPU each for nine and a half hours**, about
  970% of an eleven-core machine, until the operator noticed his fans.

  **The damage is not the heat.** A machine held at load ~111 all day is a machine where every
  later measurement is suspect: `FileWatcherTests` and the spool's conformance suite were both put
  under suspicion by it, and #291's own numbers were taken on a machine that then *stayed*
  loaded. A confound that outlives the experiment poisons everything measured after it.

  So: bound the child's own lifetime rather than promising to tidy up. `timeout <n> <cmd>`, or a
  loop with a deadline it checks itself, or a `trap ... EXIT` — in that order of preference,
  because the first two survive `SIGKILL` on the parent and the third does not. **Then check.**
  `ps -Ao pcpu,etime,pid,command -r | head` before you report, and say what you left running.
- **Before blaming the machine, look at what is on it.** *"The machine was busy"* is a real
  diagnosis — #291 is one — but it is also the easiest wrong one to reach for, and twice today it
  was true for a reason another agent had caused and could have found in one `ps`. Load has an
  owner; name it.
- **Never copy an Apple system binary (`/bin`, `/usr/bin`, `/System`) to use as a fake app or
  executable in a test.** Use a shell script or a compiled stub of your own. The kernel kills a
  copied system binary on launch, and on 2026-09-25 that was the last event before `syspolicyd`
  (Gatekeeper) hung. That is a correlation, not a proof. The hang cascaded: `tccd`, then
  WindowServer, which the watchdog killed 58 times overnight until a forced reboot.
  Tests never execute a binary from inside a `.app` they assembled, and any directory with a
  `Contents/Info.plist` counts as a bundle whatever its name, so seal it with
  `codesign -s - --force` before running from it or the operator gets a "damaged" dialog (#439).
- **If a freshly compiled binary won't start, or `git`/`grep` hang for no reason, stop launching
  processes and tell the operator.** A macOS security daemon is stuck, only a reboot clears it,
  and every new launch queues behind it. That night, agents saw exactly this at 00:42 and kept
  probing. An ad-hoc script that opened a window then likely tipped WindowServer over.
- **Never delete a test to make the gate green.** If its subject genuinely no longer
  exists, say which and why in the commit.
- **Watch a test fail before you trust it passing.** Take the fix out, run it, name which
  tests went red and on what assertion; put it back and confirm green. Report both runs.
  A test written after the fix passes for free, and a green suite is not evidence until
  you have seen the red one.
- **Revert with `git checkout <base> -- <file>`, and grep the file before believing the
  run.** `git stash` after committing reverts only uncommitted edits, leaves the fix in
  place, and the suite passes while measuring nothing.
- **Some tests must pass either way — say which, and why.** A control that only proves you
  select less is satisfied by selecting nothing. Keep the ones that fail if the change
  overshoots, and name them as that.
- **Review the tree you are shipping.** A rebase that rewrites a file invalidates every
  review of it — re-run them and post against the final sha, not the one you started from.
- **To see the UI, ask helm to draw itself: `bench get screenshot [--out <p.png>]`.**
  **No TCC grant, no display, no keystrokes, no Accessibility** — an app rendering its own view
  hierarchy is *drawing*, and TCC does not gate it. benchd asks the helm that follows it
  (`helm/asked`, answered by `HelmAsks`), so it works with the screen locked and over ssh. The
  answer is helm's report; exit 4 names the cause when no helm answers within ten seconds.
  **`terminalContent` is the field to read.** It is computed per capture, never assumed:
  `included` (every terminal pane's cells are in the image), `excluded` (none are — their
  regions carry a printed marker in the PNG itself), `partial`, or `absent` (no terminal in the
  window). #174 was scoped expecting `excluded` always, because ghostty's surface is a
  `CAMetalLayer` and Metal content does not come out of the layer tree — but the
  wrapper swaps that layer for an IOSurface-backed one once compositing starts
  (`AppTerminalView.updateMetalLayerMetrics`), and **that one does draw**. Measured, both ways: the
  first build asked "is it a `CAMetalLayer`?" and reported `absent` about a capture full of
  legible terminal text. So read the field rather than either assumption.
  - **`windowVisible: false` means a blank canvas in the PNG is not a bug (#408).** With the
    screen locked or the window covered, WebKit suspends an occluded page and the capture draws
    it as an empty rectangle under a normal header.
    It works locked, as above; it just cannot show web content that way.
  - **With two helms running, pass `--window <substring of the title>`.** An isolated instance
    is titled `helm — <suite>`. Ambiguity is refused and the refusal lists the titles, so a
    capture never quietly hands back a picture of the operator's session.
  - A capture takes the backing scale of the display the window is on, and `scale` in the
    result says which — 2 on the built-in retina panel, 1 on the ultrawide. Divide
    `pixelWidth` by it to get the points a layout assertion would be written against.
- **`winshot` is the outside-in path, and needs a grant you probably do not have.** Screen
  Recording is a TCC grant on the *invoking context*, not on agents as a category: some
  contexts have it, none can grant it to themselves, and helm is ad-hoc signed
  (`project.yml`, `CODE_SIGN_IDENTITY: "-"`) so the operator's own grant does not reach an
  agent's fresh binary. `swift tools/winshot.swift helm <out.png>` exits nonzero when it is
  missing. `--list` needs no grant at all and separates a real window from a crash, a
  zero-sized one or an off-screen one — but says nothing about what is drawn. Prefer
  `bench get screenshot` for anything about helm's own surfaces; `winshot` is for what helm cannot
  draw, such as another app.
- **The accessibility tree is a dead end either way**: helm's centre is a Metal-layer NSView
  with no child elements to enumerate (verified against a known-good build). And **a capture
  shows you pixels, not correctness** — never report a surface as verified on appearance alone
  without the operator.
- **`winshot` matches owner names by substring**, so a second helm instance — a worktree
  build, say — is indistinguishable from the operator's. Check `--list` for how many are
  running before trusting a capture. It also matches *window titles*: an editor with
  `helm` open shows up as a `helm` row. **Capture by pid when it matters.**
- **`--list` only sees the CURRENT Space.** `.optionOnScreenOnly` excludes windows on other
  macOS desktops, so a running helm with live ptys can report zero windows simply because the
  operator switched desktop. Verified 2026-08-02: two live helms, 22 windows listed, neither
  helm among them. Absence in `--list` is **not** evidence the app is gone — check the process.
- **Never hard-code click coordinates.** Read the window's bounds from `--list` and compute
  from them every time. A click at a stale coordinate does not miss harmlessly: it activates
  whatever app is underneath and types into it. That happened — a pane click landed in the
  operator's other terminal.
- **Drive the bench with `bench …`** (M3, #355). One CLI is an agent's whole surface onto the
  bench, the same door the operator's keys go through: `bench open <file|browser|terminal>`,
  `split`, `show`, `focus`, `move`, `name`, `close <pane>`, `get pane`, `get screenshot`, and
  `spawn`. The `bench-panes` skill is the guide; `daemon/direction.md` has the design. What an
  agent needs to hold in its head:
  - **Appear, don't seize (#125).** Every verb lands in the background: a tab, a column, a badge.
    `--asked` means the operator asked, and only then may a verb bring something forward or move
    his keyboard. benchd cannot know what he said, so "only when asked" is the agent's rule; the
    document refuses any unasked change that would move his focus, and names `--asked`.
  - **The rules the spool kept, now at benchd's verb boundary.** Closing a terminal needs
    `--force` (it ends what runs there; a helm-hosted shell is opaque to benchd until M5b), and the
    pane holding the keyboard also needs `--asked`. Closing a canvas destroys nothing: the file and
    its `.notes.md` sidecar outlive the tab. A close stops at the pane — no worktree, no branch, no
    git (#141's rail owns that, behind the operator's own confirmation). `show` only moves a tab in
    a slot he is not in (#284). A name somebody chose needs `--rename` (#313); benchd's own
    `<agent> · <folder>` label does not.
  - **`bench spawn` puts the agent in a benchd pty, shown in a pane** of `--cwd`'s workspace: the
    pane runs `bench attach <session>` (`SessionAttach`), so the agent keeps running while the
    pane is hidden, the display sleeps or helm restarts, and it needs no display, no shell and no
    launch line — which retired #253 and #324. The answer carries `handle`, `session`, `pid` and
    `pane`, so mailing it needs no lookup. A benchd restart ends its sessions; the pane keeps the
    `agent` record, and #85's resume offer brings it back.
  - **Unattended postures (#179): a posture removes a prompt; it never withholds capability.**
    `claude` → `--dangerously-skip-permissions` (what `cls` is), `codex` →
    `--dangerously-bypass-approvals-and-sandbox`, `pi` → `--approve`, spelled once in
    `bench_session::argv`. helm's copy (`UnattendedPosture`) serves only #85's resume line.
  - **A posture cannot remove every prompt, and no flag will fix that — #283 is the measurement.**
    Claude Code keeps some guardrails **bypass-immune** (`CIRCUIT_BREAKER_TRAITS.dangerousRemoval =
    { bypassImmune: true }` in 2.1.226): under `--dangerously-skip-permissions` a plain
    `rm "$d"/*.json` raised *"Dangerous rm operation on possibly-empty variable path"* and sat
    there for six and a half hours. When a spawned agent goes quiet, do **not** reach for a new
    flag: read its own report — `bench sessions --all` (a row `waiting` with its `waitingFor`
    words), or a helm pane's `agent` record in the snapshot below.
  - **The prompt is a file, and `ps` shows its path, never its text (#93).** A spawn's argv carries
    one sentence naming the file, which the agent reads as its first act, so the file must outlive
    the spawn. A command substitution would put the whole prompt in the agent's argv, which is the
    disclosure #93 was filed over.
  - **A spawn needs Claude Code to already trust the directory.** An untrusted directory stops at
    "Is this a project you trust?" before the session registers, which looks like a slow agent.
    Trust is inherited from an ancestor, and there is no non-interactive way to grant it: run
    `cd <dir> && claude` once by hand.
  - **A line helm types into a terminal is pasted, then submitted separately.** libghostty wraps
    every `sendText` in bracketed-paste markers when the shell has mode 2004 on, so a trailing
    `\r` sits on the command line unsubmitted. `TerminalLaunchLine.send` pastes, then sends Return
    as a binding action; #85's resume offer and the sessions drawer use it.
- **To read the bench without a display, read helm's snapshot** —
  `~/.helm/bench/snapshot.json`, or `~/.helm/bench-<suite>/snapshot.json` under
  `HELM_DEFAULTS_SUITE`; `HELM_BENCH_DIR` explicitly overrides that root. It is private
  (`0700` directory, `0600` file), atomically replaced JSON *report*, never a restore format.
  Check `format == "helm.bench-snapshot"`, support its advertised `version`, and check
  `writtenAt` before acting. Match a pane id (`bench spawn`'s `pane`, your `HELM_PANE`) to a pane's
  `id`; `isVisible` says it is on screen and `isFocused` says it has the keyboard. Parked workspaces
  preserve arrangement and terminal identity but cannot claim visibility or focus. Read on
  demand—do not watch the file inode across replacements.
  - **A terminal pane carries `agent`, which is how you find an agent that has stopped and is
    never going to start again (#283).** `{status, waitingFor, statusUpdatedAt}`, straight out of
    Claude Code's own registry row: `status` is `busy`/`shell`/`idle`/`waiting`, `waitingFor` is
    its own words for what it is blocked on — `"permission prompt"`, `"input needed"`,
    `"dialog open"` — and `statusUpdatedAt` is when **either of those two** last changed. A `-p`
    print-mode session publishes none of them and so carries no `agent` at all.
  - **`waiting` alone is not a stall; `waitingFor` plus age is.** An agent that finished its turn
    is also `waiting`, and that is healthy. `waitingFor: "permission prompt"` on a pane **nobody
    is sitting at** is the failure — subtract `statusUpdatedAt` from now and judge. Six and a half
    hours is what #283 cost.
  - **You do not have to poll `writtenAt` for this, and that is deliberate.** `statusUpdatedAt` is
    an absolute instant, so it keeps aging correctly in a snapshot nobody rewrote; a transition is
    content, so the last write of the file *is* the moment the stall began. A precomputed *"quiet
    for N minutes"* would have been wrong the instant it was written down. **It is a transition
    time and not a heartbeat, measured**: a forced non-status write (`/rename`) moved Claude Code's
    `updatedAt` and left `statusUpdatedAt` alone, and twelve minutes of a continuously working
    session moved it not at all. A prompt replaced by a *different* prompt does restart the age —
    which is what you want, since the question is *waiting for **this** since when*.
  - **Claude Code only, and absence is absence.** pi and codex publish no registry, so their panes
    carry no `agent` at all — never a false `idle`. A `status` this build does not model is absent
    too, and `waitingFor` still comes through.
  - **helm cannot answer this from the pty, which is why it asks the agent.** The ghostty
    wrapper surfaces parsed *actions* — title, bell, OSC 9;4 progress, OSC 133 command-finished,
    OSC 9/777 — and never bytes, so "this pane has produced nothing for N minutes" is not a
    question helm can ask at all, and *waiting at a prompt* versus *thinking hard* is not
    something it can see from outside. It does not need to: the agent says so itself.
- **The operator writes on the bench now, and every markdown canvas is a file he can write in**
  (#289). The header carries a **Write ⇄ Read** toggle; **Read is where it starts**, so an
  editable canvas is indistinguishable from a read-only one until he presses it. Write opens a
  `TextEditor` over the markdown **source** (not the rendered page — that would be an
  HTML→markdown round trip over a document nobody asked helm to reformat), autosaves 600ms after
  typing stops, and flushes on Read, on close (its pane or its workspace leaving benchd's
  document, which closes each canvas through its kind), on the canvas being pointed elsewhere and
  on ⌘Q. The path is on the editor's footer as a `CopyableLabel`; **it is not
  put on the clipboard** — a clipboard that changes under an act nobody asked for destroys
  whatever was in it.
  - **`EditableFile` is the scope line, carried as a type**, and it asks about the file rather
    than about where it lives: **markdown, and not a `.notes.md` sidecar**. An `.html` canvas is a
    page whose own scripts run, so an editor there is a web app rather than a text view; a sidecar
    is excluded because `CanvasNotes.append` only ever appends — it is the memory of every comment
    made on that canvas, and one keystroke through an overwriting editor would replace the lot.
  - **⌘⇧N still starts a dated note** in `~/.prp/<key>/notes/` of the workspace he is in — matched
    by `WorkspaceStore` where a store exists, keyed by prp's own derivation where none does yet,
    and registered with prp's own `project.json` when helm is the first thing to touch the store.
    `OperatorNote` is now **only** that: where a new note lands and what it is called. It stopped
    being the editability rule when the rule widened.
  - **What happens when an agent rewrites a file the operator is editing — the question #307
    deferred, and the reason it could.** helm cannot stop the write: an agent writes the file
    directly and nothing in helm is in that path. What helm guarantees is the other direction —
    **it never writes over bytes it has not shown the operator, and it never discards his buffer.**
    `CanvasModel.reconcile` runs on every `refresh()` (the `FileWatcher`'s call and `offer`'s, so
    neither route can miss it) and compares what is on disk against `draft.saved`, which is
    *helm's own belief about the file*:
    - **the same** — helm's own save firing its own watcher. Nothing happens, which is what lets
      autosave and a live watcher share one file at all.
    - **different, nothing typed since the last write** — adopted silently. Reading an agent's
      plan with the editor open is the ordinary case, and there is provably nothing to lose.
    - **different, with unsaved text** — a `CanvasConflict`. helm **stops saving** and raises a
      strip with two buttons, both the operator's: **Keep mine** writes his text over theirs,
      **Take theirs** adopts *exactly the version the strip was about* (the bytes are held for
      that reason — re-reading at the click would hand him a third version he never saw).
  - **Two honest limits, and neither is silent while it is happening.** Closing the pane **or
    quitting** with a conflict unresolved takes the buffer with it — the strip has been up since
    the moment it happened, and neither path can ask: an agent's `bench close --force` reaches the
    first with nobody at the pane, and the build-update badge quits helm on the second. **The tempting fix is worse than
    the limit**: treating those exits as an implicit *keep mine* would write what is usually a
    sentence over what is usually a whole rewrite, at the one moment nobody can be asked which — so
    helm keeps the copy another process can reproduce and loses the one it cannot, and
    `WorkbenchNoteTests` pins that so it stays a decision. And a file **deleted** under an open
    draft is not a conflict: it loads as a notice rather than markdown, the draft stays, and the
    next save recreates the file.
  - **Nothing tells an agent the operator edited, and that is the answer rather than an
    oversight.** He hands you a path; read it, and **read it again before you rewrite it** — the
    file's own mtime is the only fact, and it is the filesystem's rather than helm's. Nothing
    wakes you when a file changes, same as the state latch. `notes/` in particular is his
    directory: writing there is still wrong, for a reason about ownership rather than about what
    helm will let anyone type into. Artifacts go to `plans/`, `research/`, … and reach the bench
    through `bench open`.
- **A canvas talks back on three channels, and none of them is a notification.** `bench open` is
  the way out; these are the ways in, and an agent that pushed a page and then waited for something to
  happen has misread all three. **Nothing wakes you.** The skill (`.claude/skills/helm-canvas/`)
  is the capability surface; this is which mechanisms exist and where each is argued.
  - **The state latch — a page reporting on itself** (`Sources/Helm/Canvas/CanvasState.swift`,
    #110, and `CONTEXT.md`'s *canvas state latch*). The page posts `{kind: "canvas.state", state:
    {…}}` and helm writes it to `<name>.state.json` **beside the artifact** —
    `motions.html` → `motions.state.json`, the same placement rule as `CanvasNotes.sidecarURL`.
    **helm never reads what is in it**: the state is whatever the agent that wrote the page decided
    those words mean, carried verbatim. A top-level **object**, at most **64 KB**, latest-wins —
    the cap is about the reader, not the disk, because every byte lands in the next turn's context.
    An array, a scalar or an oversize body is refused, and the refusal is in `log show` rather
    than in the page.
  - **`window.helmCanvasUpdate` — helm telling a live page its file changed**
    (`CanvasUpdate.swift`). **The contract is one sentence: a page that defines it is never
    reloaded by helm.** Not "reloaded less often" — never. Defining the function is the page saying
    *I hold state; tell me instead of replacing me*, and returning `false` from it means "not now",
    which puts an **Updated — reload** affordance in front of the operator instead. It is a global
    in the **page** world on purpose: the annotation bridge lives in a named content world (#164)
    exactly so an artifact's own JavaScript cannot post to helm, and Swift is the only thing that
    can reach both worlds.
  - **A mark the operator makes is mailed to the agent that opened the canvas**
    (`CanvasNoteRoute.swift`, `CanvasNoteCourier.swift`, #205). This is the one channel where
    something arrives without you asking, and it arrives as **mail** — so it reaches you the way
    all mail does: through benchd. The route resolves **late**: helm records which *pane* opened the
    canvas (`CanvasOrigin`, read off the `bench/changed` event's `by`; benchd fills in the pane of
    an agent it spawned), never a pid or a handle, and asks benchd (`mail/who`) who is in that
    pane at the moment the mark is made — a handle read at push time is stale the moment that agent
    restarts, and mail to it is never read. Not persisted, for the same reason: a restored
    terminal pane is a fresh empty shell, so an origin surviving a relaunch could only name
    somebody else. **With no route
    the note goes to the clipboard and the pane says which of the two failures it was** — nobody
    pushed this canvas, or the agent that did is gone. A silent no-op is the worst outcome here,
    because the operator believes the note was sent.
- `swift run helm` to iterate, `make app` for the real bundle.
- **`make release` builds the real bundle and tells a running helm about it; `make install` is
  that plus the copy.** The split exists because `install` refuses against a live bundle —
  replacing one leaves the running process on its old code, and the swap is invisible until
  something behaves oddly an hour later — so an agent that only had `install` could never tell
  a working operator that a newer build was ready. **The obvious alternative, watching
  `/Applications/Helm.app`, is circular**: that path only changes *after* the quit the badge
  exists to ask for. So the **build** leaves the note — `~/.helm/build/latest.json`,
  `HELM_BUILD_DIR` to redirect it — and a running helm polls it and offers the swap on a
  capsule in the status bar's right-hand group. Clicking quits helm, installs and reopens;
  **every pane and its agent goes with it**, which the tooltip says before you press it. It is
  a badge rather than a dialog because #125's *appear, don't seize* applies to helm's own
  surfaces too.
  - **Identity is baked, not derived.** `scripts/stamp-build.sh` writes the commit into the
    built Info.plist as `HelmBuildSHA`, from a build phase that runs **before** Xcode's
    implicit codesign — `make release` runs `codesign --verify` afterwards rather than trusting
    that ordering holds. An installed helm has no checkout to ask, and the tempting proxy —
    bundle mtime against the stamp's `builtAt` — measures when it was **copied**, because
    `cp -R` does not preserve mtimes.
  - **The comparison is "different", never "newer".** helm cannot order two shas without the
    checkout, and different is also the useful question: an agent building an older branch to
    test something has produced a build worth offering.
  - **An unstamped helm never badges** — the SPM path, and every bundle built before this
    existed. A badge that cannot clear is worse than no badge, and it is the one rule in
    `BuildUpdate.decide` whose absence a test names (`testUnstampedBuildNeverBadges`).
  - **An isolated instance never polls at all** (`HELM_DEFAULTS_SUITE`): a worktree build under
    test does not get to offer to replace the operator's application. The stamp directory is
    deliberately *not* split per suite — a build is not per-instance — so that policy lives in
    `BuildUpdateModel` rather than being hidden in a path.
  - **Two dirty builds of one commit share `<sha>-dirty` and so do not badge each other.** The
    honest limit, and it lands on the iteration path where `swift run helm` is what anyone is
    actually using.
  - The format is written by shell and read by Swift, so it is a duplicate across a runtime
    boundary — a runtime boundary makes sharing impossible, and that carries an
    obligation. `BuildStampScriptTests` runs both scripts as real subprocesses and decodes what
    they write with the real types, so a renamed key or field fails a test instead of shipping
    a helm that can never see an update.
- **`just release-resume <session-id> [cwd]` is the swap for an operator who is away (#404).**
  It builds (`make release`, `cargo install` of `bench` and `benchd`), quits helm by pid, restarts
  benchd (with `launchctl kickstart -k` when the login agent from `just benchd-install` is loaded,
  so it never starts a second one), swaps the bundle with `BundleSwap.script` itself (read out of
  the Swift source, so there is one swap), and resumes that Claude Code session with `bench spawn
  --resume` and `--remote-control`, in a benchd pty shown in a pane of the new helm. It detaches first, because the caller is normally an
  agent in a pane the quit closes. **Once helm is quit the session always comes back**: any later
  failure resumes it outside helm with `claude --bg --resume`, and the log says which happened.
  Logs go to `~/.helm/build/release-resume.log`, last line `RESULT:`. Every target is a flag
  (`--bundle`, `--pid`, `--suite`, `--bench-suite`, `--cargo-root`, `--env`,
  `--no-remote-control`), which is how it is tested against a bundle copy under a suite. Two
  things it does that are easy to undo by accident: it relaunches helm through `env -i`, because
  `open` hands the app the caller's whole environment (`CLAUDECODE`, the caller's session id) and
  every pane would inherit it; and it holds `caffeinate -d -u` while relaunching, because with
  every display asleep the new helm cannot create a terminal (the CoreVideo `-6661` pair above).
  **Quitting helm kills every pane: run it for real only when the operator has said nothing is in
  flight.**
- **helm persists to one domain, `com.wirasm.helm`, from both launch paths** — so "did it
  persist?" is `defaults read com.wirasm.helm` whichever way it was started, unless
  `HELM_DEFAULTS_SUITE` overrides it (next bullet). `swift run helm`
  used to land in a `helm` domain of its own, and reading the wrong one is how #45 produced a
  confident, wrong diagnosis. The one-time move of that domain's contents ran once per machine
  and was deleted in #377. The identity lives in `SPMInfo.plist`,
  `project.yml`'s `PRODUCT_BUNDLE_IDENTIFIER` and `DefaultsDomain.canonical` — keep all three
  in step, `DefaultsDomainTests` fails if you don't.
- **A second helm must run on its own defaults suite: `HELM_DEFAULTS_SUITE=<name>`.** Unset is the
  behaviour above to the letter — `com.wirasm.helm`, both launch paths, one answer to "did it
  persist?". Set, helm reads and writes that suite and nothing else, so a worktree instance can be
  filled, quit, relaunched and hand-corrupted with **no reachable path to the operator's state**
  (measured: `UserDefaults(suiteName:)` does not read through to the app's own domain). Verify with
  `defaults read <name>`, and prove the negative with `defaults read com.wirasm.helm`.

  ```
  BENCH_SUITE=helm-bench benchd &    # its own benchd first: the suite moves benchd's root too
  HELM_DEFAULTS_SUITE=helm-bench swift run helm
  ```

  **Do not hand-roll a throwaway `PRODUCT_BUNDLE_IDENTIFIER` any more** — that is what PRs #97 and
  #100 each had to invent, and #86 is that made supported. Refusals are loud rather than silent:
  the legacy `helm` domain, a path, and `NSGlobalDomain` all stop the launch, because falling back
  to `com.wirasm.helm` under a variable that promised isolation is precisely the disaster. An
  isolated instance says so — the status bar carries the suite name on an accent capsule, and the
  window is titled `helm — <name>`, which is what `winshot --list` and `bench get screenshot --window` see
  when two helms are running. The window frame is not autosaved under it: that is AppKit's write
  rather than helm's, and the only one a suite cannot catch by itself.
  - **"No reachable path" is a promise about three directories, not one.** The suite moves the
    defaults, the bench snapshot (`~/.helm/bench-<name>`) and benchd's root (next bullet). A fifth, the mailbox, leaked until #285: a capability test under
    `HELM_DEFAULTS_SUITE=drivetest` spawned an agent that claimed an address in the operator's live
    `~/.helm/mail`. helm has no mailroom since #358; mail lives under benchd's root, so the bullet
    below now covers it.
  - **benchd's root is the third, and it leaked the same way until #378.**
    `BenchRoot` (`Sources/HelmWire/Bench/`) read only `BENCH_DIR` and `BENCH_SUITE`, so an
    isolated helm opened the operator's `~/.bench` browser and forwarded its clicks and keys into
    his signed-in Chrome. Now, with no `BENCH_*` set, the suite resolves `~/.bench-<name>`, the root
    `bench` uses under `BENCH_SUITE=<name>`. A helm suite benchd's `SuiteName` cannot take, such
    as `Helm-Bench`, is refused in the pane rather than mapped to something `bench` would disagree
    with. The agents in its panes follow the pane (#393): `PaneEnvironment.suiteDeclaration`
    also exports `BENCH_SUITE=<name>` unless helm's own environment already sets `BENCH_SUITE`
    or `BENCH_DIR`, so `bench` in a pane resolves the same root, or refuses the same name.
    `PaneEnvironmentTests` pins the two resolutions together.
- Conventional commits, written as a human — no AI attribution.

## Architecture — how to think about where code goes

**Vertical slices by feature, not layers.** `Sources/Helm/<Feature>/` holds that feature's
model, views and commands together. If a thing can name a single feature, it belongs in that
feature's directory — including its keyboard shortcuts and notification handling. Only work
that genuinely spans features stays in `App/`, which is composition and nothing else. The
test is simple: two people building two features should not have to edit the same file.

**The slices, largest first, so a stranger knows where to look**: `Canvas/` (6.1k lines) is the
document surface; `Workbench/` (2.6k) is drawing benchd's bench — columns, slots, panes — and
the door every change goes out through;
`Surfaces/` is `SurfaceKind` and the one registry every pane kind's live object is kept in;
`Keymap/` is the key table and its readers (below); `Bench/` is helm as benchd's client —
the socket, the follower and the one-time import (below);
`Archon/` + `Worktrees/` (2.5k + 0.8k) are the **rail's two tenants**; `Terminals/` (2.1k) is the
libghostty seam — sessions, the host view, the pane environment, and `SessionAttach` (a pane
that shows a benchd session); then `App/`, `Board/`, `Browser/`, `Workspaces/`, `Design/`, `Artifacts/`,
`StatusBar/`, `Build/`, `Shared/`, `Capture/`, `Mail/`. Two of those have no bullet anywhere
above and are the easiest to be surprised by:

- **`Archon/` and `Worktrees/` are the rail, and the rail is *somewhere to start work that is not
  your current work*.** Nothing docks there and nothing opens from it — run detail is read in
  Archon's own web UI. Archon's tenant is deliberately a **reduction** of one that was built, used
  and cut back on the operator's verdict *"too much bloat"*: three lists (gates, running,
  finished), one input field, and a dismissible line per finished run rather than a tally. Read
  `ArchonRailModel`'s header before adding anything to it — several of the obvious additions are
  things that were removed. Worktrees is `git worktree list --porcelain` and nothing else: helm
  reads no Archon database, and "merged" means Git reachability from a resolved remote default
  branch, never pull-request state. `CONTEXT.md` has both.
- **`Board/` is agent presence and the bench snapshot — it is not the drawable board.** The
  collision is real and worth knowing before a grep sends you to the wrong one. `Sources/Helm/Board/`
  is `BoardModel`, `AgentDot` and `BenchSnapshot`: which workspace tab has an agent that has
  stopped, plus the JSON report an agent reads the bench from. `AgentLocator` (a process's
  ancestors, up to helm) and `TranscriptLocator` (a session's transcript on disk) live here too. On the presence half helm holds
  **no state of its own** — the registry file's lifecycle *is* the mark's lifecycle, so nothing
  acknowledges, decays or expires, which is what makes it safe to poll and republish rather than
  accumulate. The **drawable** board is
  `.claude/skills/helm-board/`, a kind of canvas an agent authors and the operator draws on; no
  Swift in `Board/` knows it exists. `CONTEXT.md` now defines both senses.

**benchd owns the bench; helm draws it** (#354). Every change is a `BenchVerb` sent through
one door, `WorkbenchModel.send(_:by:asked:)` — a key, a click, a drag, a ⌘-clicked link —
and an agent's verbs come straight to benchd through `bench`; either way it says who asked, which is what benchd's focus rule reads. Keys are rows of one table, read by the key monitor, the menu and the status bar's hints;
a row's action is data, a `VerbTemplate` resolved against the bench when the key fires or a
`LocalAction` that never reaches the document. The table in force is `Keymap.table`
(`Sources/Helm/Keymap/`): the built-in `KeyBindings.all` overlaid by the operator's
`<bench root>/rules/keymap.toml`, reread every second. helm reads that file and nothing writes
it; a file that does not parse keeps the last good table and puts the line and reason on the
status bar. `docs/keymap.default.toml` is the built-in table in that format, and
`KeymapFileTests` fails until it is regenerated after a built-in key changes.
`LocalActions` in `App/` carries both out. There is no NotificationCenter command bus: do not
add one. `Workbench` has no mutating method and every field is a `let`, so no Swift changes a
bench: nothing is drawn until benchd's follower delivers the document the verb made
(`WorkbenchModel.apply`).

- **helm keeps no bench.** The workspace list follows the document, and nothing about the bench
  is in defaults. The benches helm used to save there go into benchd's first empty document
  once, as `workspace/import` (`BenchImport`), and are left where they were.
- **#85's question stays helm's** until M5b: its answer goes back as `workspace/reset` or
  `workspace/unshelve`. A pane showing a running benchd session is never asked about: the agent
  is right there.
- **benchd unreachable** is a status-bar capsule naming the socket; the last document stays on
  screen and a verb fails visibly. helm never starts benchd: `just benchd-install` makes it a
  login agent.
- **Tests draw from a stand-in** (`FakeBenchd`, `ToyBench` in `Tests/HelmTests/Bench/`), whose
  toy rules are not benchd's: where a pane lands and who gets the keyboard are `bench-doc`'s,
  tested in Rust. A Swift test asserts what helm sent, or what it drew from the document.

**Drawers are drawn over the bench, never in it** (#356, `Sources/Helm/Drawers/`). `DrawerHost`
is an overlay on the bench and the rail, so the layout under an open drawer is untouched; while
one is open its selected pane holds the keyboard and the bench's focused pane does not. A drawer
pane's live object belongs to no workspace, so it survives the drawer being hidden and a workspace
closing. The status bar has one capsule per drawer, dotted while badged. **An agent puts things
in a drawer and never opens one**: `pane/open` into a drawer badges it, and `drawer/toggle`
without *asked* is refused. The keymap's `drawer` action and the capsule are the operator's.

**A key can run a recipe from the operator's bench justfile** (#356, `Sources/Helm/Just/`):
`action = "just"`, `recipe = "<name>"` in the keymap file sends `just/run` to benchd as the
operator. benchd runs it (see `daemon/direction.md`); helm only hears `just/finished` on the
follower and shows a run of his that failed as a status-bar capsule that opens its log.

**Put a command handler where its lifetime is right, not where it looks tidy.** A subscription
that has to work while its view is closed belongs on the model, which outlives the
presentation. Attaching it to the view means it is dead in exactly the state it exists for.

**Prefer values over live objects at a seam.** Describe what a thing is with a small `Codable`
value and resolve it to the live object at the edge. Persistence, restore and equality then
come free, where a tree of protocol existentials would need a hand-rolled type registry.

**And the value must live where both sides of the seam can reach it.** A type on one side and a
comment on the other is not a contract — it is a contract plus a bug waiting for whoever writes
the far half from memory. #210 caught four of these in the canvas; they are not a canvas habit.
`Notification.object` is `Any?`, so the keymap and the menu posted different objects for the same
row and four View ▸ Focus commands were silent no-ops from the day they were split out (#152).
The bench's wire has one spelling: the Rust types in `daemon/crates/bench-wire` (and
`bench-doc`), with helm's Swift copies in `HelmWire` pinned by the shared fixtures in
`daemon/fixtures/` — both gates read the same files, so a field renamed on either side turns one
of them red. That is the honest duplicate: a runtime boundary makes sharing impossible, and a
fixture makes the drift detectable. The spool's six hand-written scripts were the last copy with a
weaker check; they retired with M3.

**A payload that can grow a second kind carries a discriminator from the first one.**
`HelmAsk`'s `kind` and `Pane.Content`'s string `kind` cost one field each and
buy a decoder that can refuse what it does not understand — `Pane.Content` throws on a `kind` this
build never heard of, and `Slot` drops that pane rather than guessing. The canvas bridge's
`{id, text, rect}` has no such field, and adding one once a second kind exists is a migration
rather than a field (#109). Anything read **outside** the process says so in its header too:
`BenchSnapshot` carries `format`, `version` and `writtenAt`, so a reader that predates a change
fails loudly instead of misreading it.

**An invariant with a comment explaining it wants a type carrying it.** `StandardizedPath` is the
worked example: "standardize every path on the way in" was a doc comment asking callers to prefer
a helper, and `WorkbenchTests` took the shortcut anyway (#88) — the explicit `init` is what made
the unstandardized value unconstructable.

**What the rule has bought since, and how each defect was found.** `WorkspacePath` (#226): a
pushed artifact was routed by comparing workspace paths **by value**, so a path that reached that
line un-normalized matched nothing and the artifact simply never appeared — no error anywhere.
`Handle` (#231, #233, #239): a handle *looks* derivable, and a derived one is silently wrong
whenever a live holder forced a longer suffix, which the caller cannot see. The spool's request id
(#260) was a bare `String` behind a regex at one edge, and a claimed request's id reached a path
builder unchecked: `results/../../../../tmp/pwned.json` was a real write. **Each was caught by a
reviewer reading a comment before a gate could see it**, which is the reusable part: the rule fires
while the defect is still hypothetical, and by the time a gate can see it the newtype is a
migration.

Prefer a newtype the day the comment gets written, not the day it is disbelieved.

**Colour is a palette token, never a literal and never a system default.** Every surface
spends `Design/Palette.swift` — views through `Color.surface`/`.textMuted`/…, the terminal
through the same tokens rendered as ghostty config lines. A `Color(nsColor:)`, a `.bar`, or a
hex in a view is the defect that slice exists to remove: helm had three unrelated colour
sources and did not read as one application. If a surface needs a colour that is not there,
add a token.

**Let Swift's access control tell you where the seam is.** `@Published private(set)` state is
only mutable from the type's own file, so an extension that has to mutate it is not a seam —
it is the same module wearing two filenames. Fighting that with looser access or wrapper
methods usually means the split was wrong.

**pi extensions are TypeScript and live in `pi/`, not `Sources/`.** helm's repo owns helm's pi
work. They are for the pi sessions helm *hosts*, in whatever repo the user is in — so they are
symlinked into `~/.pi/agent/extensions/` and never into helm's own `.pi/`. Before writing or
changing one, read the `pi-extensions` skill; `pi/AGENTS.md` covers the layout and its gate.

## Agent skills

### Issue tracker

GitHub issues on `Wirasm/helm`, via `gh`. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context; vocabulary is canonical in `CONTEXT.md`, with `../GLOSSARY.md` for the
cross-repo terms helm shares with kild and prp. See `docs/agents/domain.md`.

### The helm-local skills

`.claude/skills/` holds fifteen; **seven are vendored** from `mattpocock/skills` and pinned in
`skills-lock.json` by a `computedHash` — so a hand-edit to one of those is drift against its pin,
not a change. The other eight are hand-written. The first four below are helm's, the surface an
agent hosted in helm actually uses, and each has a gate listed in *Working here* above (the
canvas skill's snippets run in the daemon gate). The last
four, `bench-panes`, `bench-mail`, `bench-browser` and `bench-sessions`, are benchd's, and their
snippets run in the daemon gate's conformance suite.

- **`helm-canvas`** — what a canvas *is* and what it can do, and `bench open`, which is how an
  artifact gets onto the bench. Read it before writing one; it deliberately says nothing about
  *what* to put in a canvas.
- **`helm-board`** — the drawable board (#111): an agent authors labelled shapes, the operator
  draws on it by hand, and what they drew comes back as named records. Not `Sources/Helm/Board/`.
- **`post-canvas`** — a video stored by the archon-video pack, rendered as a post preview canvas:
  the video beside the copy that would ship with it. It puts the page on the bench with
  `bench open`.
- **`pi-extensions`** — how to build one without taking the pi CLI down, how to read the installed
  pi rather than guess at its API, and how to test one without spending a model call.
- **`bench-panes`** — driving the bench with `bench` (M3, #355): open an artifact, the browser or
  a terminal, spawn an agent into a pane, show, move, name and close panes, read where one is, and
  capture helm's window. Every verb lands in the background unless it carries `--asked`.
- **`bench-mail`** — sending and reading mail through benchd's mailroom, finding who can be mailed,
  and wiring an agent the operator starts himself (`bench wiring`). The only mail skill since #358.
- **`bench-browser`** — the operator's shared browser (#350): get its endpoint from `bench browser
  start`, drive it with `playwright-cli attach`, and badge his browser drawer with `bench open browser`.
- **`bench-sessions`** — who is working in a workspace (`bench sessions --all`), and what any of
  them did (`bench log <id>`, #421), read from the transcript without mailing the agent. The
  operator sees the same list in the `sessions` drawer (⌘⇧S, `Sources/Helm/Sessions/`).

### The two helm-local subagents

`.claude/agents/` holds two, and both exist because a general reviewer does not find what they
find. Neither modifies files.

- **`house-rules-auditor`** audits a change against **this project's own written rules** —
  `AGENTS.md`, `CLAUDE.md`, `CONTEXT.md` — and against nothing else. It reports only findings it
  can trace to a quoted line, which makes it the reviewer to reach for when the change *is* one of
  those documents, or when a diff is being judged against them rather than against taste.
- **`seam-analyzer`** hunts one defect: a **missing type at a seam** — structure flattened and
  rebuilt downstream, hand-maintained lists held together by KEEP IN SYNC comments, a second route
  that skips the validator, an invariant carried by a comment. That is the rule the architecture
  section above spends its longest passage on, and this is the reviewer that applies it.
