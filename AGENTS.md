# AGENTS.md — helm

Native macOS surface: SwiftUI + GhosttyKit. Workspaces above a **workbench** — columns of
tabbed slots holding terminal and canvas panes, several on screen at once. **No backend** —
artifacts are files. Vocabulary is canonical in `CONTEXT.md`.

**"Agent" means a CLI agent already in use — Claude Code, pi, codex.** helm hosts one in a
terminal it owns and renders what it writes. It never builds or hosts an agent of its own.

Direction: `docs/direction.md` (an entry point, not a spec).

## Working here

Gate, all green before a PR to `development`:

```
bash scripts/patch-libghostty.sh && swift build && swift test && make lint && xcodegen generate
```

The patch script is first and not optional — the patched libghostty is gitignored, so a
fresh worktree has nothing to link against. Never borrow another checkout's `vendor/`;
that proves the other checkout builds.

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
state here, not the exception.** `swift test` is *not* load-sensitive and a red keyboard test
is *not* evidence that the machine is busy. That was assumed once, cost two confident wrong
diagnoses in an afternoon, and #192 is the measurement that disproved it: a test bundle built
at 13:19 and never rebuilt was green at 13:19 and red at 19:00, and every worktree on the
machine went red within the same second (17:17:19). Concurrency did not do that; nothing in
any diff did.

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

**This gate needs only the Swift toolchain and xcodegen. Keep it that way.** It is the one
command a fresh worktree runs, and every dependency added to it is a dependency every
contributor now needs.

**If you touched `pi/`, run its gate too — it is separate on purpose:**

```
bash .claude/skills/pi-extensions/scripts/test.sh
```

**If you touched `hooks/`, run its gate:**

```
bash hooks/test.sh
```

**If you touched `.claude/skills/helm-canvas/`, run its gate:**

```
bash .claude/skills/helm-canvas/test.sh
```

**If you touched `.claude/skills/helm-board/`, run its gate:**

```
bash .claude/skills/helm-board/test.sh
```

That skill is the drawable canvas (#111): `@quickdrawjs/core` 0.2.0 vendored, copied *beside*
an artifact rather than injected, so it is a skill asset and not a bundle resource. Its gate
**executes** `board-core.js` in node — the ownership diff, the overlap resolution and the state
report all live there rather than in the DOM glue, precisely so a browser is not needed to test
them — checks `new-board.sh`'s refusals, and re-hashes the vendored bytes against their pin.
Needs node, which is why it is not in the Swift gate. **The one thing in that seam the Swift
gate does own is `data-helm-surface`**, because three files spell it and one of them is Swift —
see `CanvasSurface` and `CanvasSurfaceTests`.

**If you touched either mail skill, run its gate:**

```
bash .claude/skills/helm-mail-cc/test.sh
```

It covers both `helm-mail-cc/` and `helm-mail-pi/`, because the send and the mailbox listing are
documented identically in each. It **extracts** the snippets from `SKILL.md` and runs them rather
than restating them — a test that retypes a documented snippet is a second copy that drifts, and
would keep passing while the doc said something else. It runs them under **zsh** specifically: #237
is a documented loop that was correct in bash and fatal in zsh, which is the shell Claude Code's own
Bash tool runs, and no gate read a skill file at all until this one. Needs bash, zsh and python3,
which is why it is not in the Swift gate.

**Since #285 it also executes the root those snippets resolve**, and that is a fifth copy of the
mailbox's directory rule rather than a fourth. Every snippet in both skills opens with a three-line
preamble that resolves `$ROOT`, because a documented literal is not merely stale inside an isolated
instance — it is an agent in a throwaway helm **listing and sending into the operator's own
mailroom**, successfully and silently, which is the cross-talk the code fix closes. Prose asking the
reader to substitute the suite themselves was the first attempt and is not a mechanism.

**The line of that preamble that matters is the one it is tempting to drop.** The first cut was a
single `${HELM_DEFAULTS_SUITE:+-$HELM_DEFAULTS_SUITE}`, which honours **every** value — and the
three the real writers refuse are exactly the reachable ones: `com.wirasm.helm` is the canonical
domain, which `DefaultsSuite.override` maps to `.none` so **helm launches perfectly normally under
it**, it is the literal this file tells you to `defaults read`, and `claude-session-start` fires for
every Claude Code session on the machine rather than only those in a helm pane; `helm` is the legacy
domain and the obvious guess at a suite name; a `/` makes a path. All three sent the reader to an
empty `~/.helm/mail-<name>` while the real hook had claimed their mailbox in the shared root — sends
that succeed into a directory nobody reads, and a box that never receives. **The escape hatch the
first version wrote for itself — *"simpler only in the cases helm refuses to launch under"* — was
false for the case that needed it most.** So the preamble carries the same four textual guards the
writers do, and the gate runs the doc's own expression against all six fixtures. The one rule it
does not copy is the whitespace trim, which cannot bite what helm publishes: `PaneEnvironment`
declares the *decided* name.

The gate also requires both skills to state one preamble and **every snippet to repeat all of it** —
a block that kept `ROOT=` and dropped the `case` line is the leak, sitting in a file whose stated
preamble is still correct — and it runs every other snippet with both variables taken **out** of the
environment, because this gate is very often run by an agent hosted in an isolated helm, which
exports the second one.

`push.sh` is how an agent puts an artifact on the bench, and it is the third mechanism to hold
that job — the first two shipped broken. Both were verified from a shell the operator typed into,
where they worked, and both were silent from an agent's tool call, where they did not: a ⌘-click
the TUI eats before helm sees it (#124), then a bare `printf` whose stdout the harness captures
(#184). Its gate needs bash and `ps`, which is why it is not in the Swift gate. **What no gate can
prove is that a pane appeared — run it against a live helm before believing it.**

`hooks/` is the **Claude Code** half of the mailbox — `claude-session-start` claims a mailbox so
a session can be addressed, `claude-user-prompt-submit` delivers waiting mail by writing the notice
to **stdout**, which Claude Code feeds to the model as context for the turn about to run. Delivery
is deliberately **before** a turn rather than after one: an agent that learns its mail on `Stop` has
already carried out the instruction it should have read the mail first. pi does the same thing
through its `context` event.

**An idle agent is woken, and the two runtimes get there differently.** pi's extension is a live
event loop inside the session, so it watches its own mailbox and calls `sendUserMessage` — a turn
starts from nothing. Nothing outside a Claude Code session can do that, so the notice instead
**tells the agent to arm its own watch**; being notified is the wake. Both are capped at 3
consecutive wakes, because waking spends a turn and two agents replying to each other would
otherwise burn until the money ran out. Both are wired by hand into `~/.claude/settings.json` and
never write themselves there; `hooks/helm-mail.mjs` is the convention, and it is a **deliberate
duplicate** of `pi/extensions/helm-mail/index.ts` — there is no shared module because pi loads a
`.ts` extension and a hook is a standalone script, so any change to the address scheme, the notice,
the on-disk shape or **which mailroom it all happens in** (#285) has to be made in both — and
`hooks/mailbox-conformance.mjs` is what makes that detectable rather than trusted. Needs node,
which is why it is not in the Swift gate.

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
  later measurement is suspect: `FileWatcherTests` and `SpoolWireConformanceTests` were both put
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
- **To see the UI, ask helm to draw itself: `swift tools/helm-capture.swift --out <p.png>`.**
  **No TCC grant, no display, no keystrokes, no Accessibility** — an app rendering its own view
  hierarchy is *drawing*, and TCC does not gate it. It is a spool request (`kind: "capture"`),
  so it works with the screen locked and over ssh, exactly like `helm-spool`. The result names
  the PNG and says what is in it; exit codes are 2 no answer, 3 refused, 4 could not draw.
  **`terminalContent` is the field to read.** It is computed per capture, never assumed:
  `included` (every terminal pane's cells are in the image), `excluded` (none are — their
  regions carry a printed marker in the PNG itself), `partial`, or `absent` (no terminal in the
  window). #174 was scoped expecting `excluded` always, because ghostty's surface is a
  `CAMetalLayer` and Metal content does not come out of the layer tree — but the vendored
  wrapper swaps that layer for an IOSurface-backed one once compositing starts
  (`AppTerminalView+Lifecycle.swift:176`), and **that one does draw**. Measured, both ways: the
  first build asked "is it a `CAMetalLayer`?" and reported `absent` about a capture full of
  legible terminal text. So read the field rather than either assumption.
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
  `helm-capture` for anything about helm's own surfaces; `winshot` is for what helm cannot
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
- **Frontmost is not focused.** An app can be frontmost with *no key window*, and then every
  keystroke sent at it vanishes with no error at all. That is what an app on another macOS
  desktop looks like from outside: `AXFrontmost: true`, `AXWindows count: 0`,
  `AXFocusedWindow: NONE (-25212)`. Only the ⌘N before it landed, because a menu command routes
  to the app rather than to a first responder — so the run looks half-successful and tempts you
  to type the next thing. `focus.swift` now proves the key window too and exits **5** when
  there is none, **6** when it cannot ask (no Accessibility grant, or the app not answering —
  told apart, because blaming a grant the operator does have is its own wasted hour).
  `helm-spawn` checks before ⌘N, so it refuses for free instead of after a 90s timeout with a
  stray terminal left open. Verified 2026-08-02 against windowless Terminal and Safari.
- **To start another agent in helm, prefer the spool: `swift tools/helm-spool.swift <cwd> --prompt-file <p>`.**
  It writes `{id, cwd, command, args, prompt}` into `~/.helm/spool` and waits on
  `results/<id>.json`. **No display, no focused window, no Accessibility grant, no keystrokes**
  — so it works with the screen locked, headless and over ssh, which is the ceiling
  `helm-spawn` cannot get past. The result carries the new agent's `terminalId`, `pid`,
  `sessionId` and **`handle`**, so the next move — sending it mail — needs no lookup: helm
  created the terminal, so it knows the pid, and it *reads* the handle out of
  `~/.helm/mail/*/owner.json` rather than deriving it (a derivation is silently wrong whenever
  `deriveHandle` widened or `HELM_MAIL_HANDLE` was pinned). Exit codes say what happened —
  3 refused, 4 failed, 5 started-but-unaddressable, 6 abandoned by a restart. Only the agents
  in `SpoolPolicy.allowedCommands` may be named: a request is a file, so `sh` in a login shell
  is what an ungated spool would actually be. `HELM_SPOOL_OFF=1` turns the watcher off, which
  is the negative control for any claim about it. A second instance gets its own spool
  automatically under `HELM_DEFAULTS_SUITE`.
  - **helm answers the "nobody is at the pane" question for you, per agent, in
    `SpoolUnattendedPolicy`.** A bare `claude` stops at a permission prompt, and a prompt in a
    pane nobody is watching is indistinguishable from an agent that never started — measured on
    the first real use of the spool (#179). Each agent gets the operator's own standing choice:
    `claude` → `--dangerously-skip-permissions` (what `cls` is, and what `helm-spawn` already
    types, so the two spawn paths now agree), `codex` → `-p yolo` (what `cdxy` is), `pi` →
    `--approve`. A request that names a flag from the same family gets exactly what it asked for
    and nothing added. **A posture removes a prompt; it never withholds capability.** Blocking
    belongs in hooks and sandboxes — the operator's gate is the pull request — and a spawn that
    quietly hobbles an agent produces failures nobody is watching, which is the whole of #179.
    `allowedCommands` is untouched: `cls` is a script on `PATH` this repo cannot pin, and naming
    the flag buys the same behaviour without handing the allowlist's meaning away. The full
    argument, including the costs that were weighed and overruled, is in
    `Sources/HelmWire/Spool/SpoolRequest.swift`; read it before changing a posture.
  - **The launch line is pasted and then submitted separately, and it has to be.** libghostty
    wraps *every* `sendText` in bracketed-paste markers when the shell has enabled mode 2004 —
    fish, zsh and bash all do — so a line ending in `\r` lands on the command line and simply
    sits there. Measured, and it cost the first live run: a terminal opened, a shell ran, and
    no agent ever started. `WorkbenchSpoolSpawner.send` pastes, then sends Return as a
    `text:` binding action.
- **Why the spool is a script, and must stay one.** It exists because `helm-spawn` cannot work
  headless: that path needs an unlocked screen, a visible helm window and an Accessibility grant
  on the invoking context, and no agent can grant itself any of them. #51's rung 2 is a channel
  needing none — a file appears, helm acts, helm writes a file back.

  That buys nothing unless the **caller** is equally unencumbered, and three properties are what
  make it so. All three were measured when #221 tried converting these scripts into SPM
  executable targets, and all three broke:
  - **No build.** `swift tools/helm-spool.swift` compiles one file and does not resolve
    `Package.swift`. An SPM target does — and SPM resolves the **whole** manifest before
    building anything, so `swift run helm-spool` demands the gitignored `vendor/libghostty-spm`
    and fails on a fresh checkout with `error: the package at '…/vendor/libghostty-spm' cannot
    be accessed`. The spool would need `patch-libghostty.sh` and a build before an agent could
    spawn anything.
  - **No cwd.** `swift ~/…/helm/tools/helm-spool.swift` is a path any working directory can
    name. `swift run helm-spool` requires the cwd to be inside the package; from anywhere else
    it is `error: Could not find Package.swift in this directory or any of its parent
    directories.` **This is the one that matters most** — hosting an agent in whatever repo the
    operator is working in is the normal case, not an edge one.
  - **No toolchain state.** No resolved dependencies, no `.build/`, no vendored framework. A
    machine that has never built helm can still drive it.

  **So the spool's wire format and its directory-resolution rules are both duplicated between
  `tools/*.swift` and `HelmWire`, and that duplication is honest** — the same carve-out as
  `pi/` and `hooks/`, for the same reason: a runtime boundary makes sharing impossible. What is
  *not* optional is that it be **detectable**, which is what `SpoolWireConformanceTests`
  (`Tests/HelmTests/Spool/`) is for: it runs each real script as a subprocess and checks both
  directions — the request it writes, decoded with the real type, and its exit code and stderr
  against a real `SpoolResult` for **every** `Status` case, not a sample — plus `helm-command`'s
  hand-copied allowlist against `SpoolCommandPolicy` itself, plus the
  `HELM_DEFAULTS_SUITE` half of directory resolution against a real, disposable suite. The one
  branch it cannot reach is the bare default (no override, no suite), which resolves to the
  operator's actual `~/.helm/spool` and cannot be redirected — the test file's own header has
  the measurement. Everything else it does reach fails a test rather than shipping silently.
- **To read the bench without a display, read helm's snapshot** —
  `~/.helm/bench/snapshot.json`, or `~/.helm/bench-<suite>/snapshot.json` under
  `HELM_DEFAULTS_SUITE`; `HELM_BENCH_DIR` explicitly overrides that root. It is private
  (`0700` directory, `0600` file), atomically replaced JSON *report*, never a restore format.
  Check `format == "helm.bench-snapshot"`, support its advertised `version`, and check
  `writtenAt` before acting. Match a spool result's `terminalId` to a terminal pane's `id`;
  `isVisible` says it is on screen and `isFocused` says it has the keyboard. Parked workspaces
  preserve arrangement and terminal identity but cannot claim visibility or focus. Read on
  demand—do not watch the file inode across replacements.
- **To close a pane again, `swift tools/helm-close.swift <pane-uuid> [--force]`.** The
  inverse of `helm-spool`, needing what it needs — nothing: a file appears, helm acts, helm
  writes a file back (#176). **It names a pane, and a pane holds a terminal or a canvas** — one
  uuid namespace (`Pane.id`), so the request carries no discriminator and a canvas close is
  byte-identical to a terminal one (#284). Three ways to know a uuid, and **knowing it is the
  scoping**: a spawn or command result's `terminalId`, the `HELM_PANE` of the pane you are
  running in, or — for an artifact you pushed, since `push.sh` hands back no id — the `id` of the
  `"kind": "canvas"` record in `~/.helm/bench/snapshot.json`. helm deliberately does *not* check
  that it spawned the pane for you: that would buy no safety (anything that can write into the
  spool is already inside the trust boundary), would not survive a restart (the pane is
  persisted, an in-process memory of spawning it is not), and would forbid the two legitimate
  cases — an agent closing the pane it is itself in, and a coordinator tidying up a teammate.
  `CloseRequest` argues it in full.
  - **Two refusals, they are not the same refusal, and only one of them can fire on a canvas.**
    A pane with a **live process** refuses unless you pass `--force`, because closing it kills
    whatever was running and loses what it had not written down — "is anything running" is
    `getppid(foreground) == getsid(foreground)`, the foreground being a *child* of the pty's
    session leader meaning an idle prompt, because libghostty spawns one `/usr/bin/login` per
    pane and that is what leads the session. (`getsid(fg) == fg` is the rule that looks right and
    is not: it calls every idle pane busy, and `SpoolClosePolicyTests` pins that it stays gone.)
    A **canvas** has no pty at all, so it is never busy and never needs `--force`. The pane the
    **operator is working in** refuses *and `--force` does not override it*, whichever the pane
    holds: force is a caller asserting about work it owns, and where the operator's eyes are is
    not something a file on disk gets a say in. Both are `refused` results with a reason, exit 3.
  - **Closing a canvas destroys nothing, which is why this needed no ruling (#284).** A canvas
    pane is an address, not a document: the artifact is a file on disk helm only reads, and the
    operator's annotations are a `.notes.md` sidecar **beside** it (`CanvasNotes.sidecarURL`).
    Both outlive the tab, a re-push re-opens the same source, and a `closed` result for one
    carries **no `pid`** — the honest answer to "what did I just destroy". Before this,
    `push.sh` was add-only and a re-pushed artifact left orphan tabs only the operator could ⌘W.
    Bringing a canvas *forward* is the other half of #284, and it is `helm-select` below.
  - **It stops at the pane — no worktree, no branch, no git at all.** #141's rail already owns
    that, and its safety *is* an operator confirming a modal against eligibility rules; a spool
    request has nobody at the pane by construction, so reaching that rail from here could only
    mean a dialog no one will answer or a confirmation skipped. That is the strongest possible
    guarantee that unmerged work is never destroyed. `SpoolClosePolicy`'s header has the
    argument and the shape a later worktree kind would have to take.
- **To bring a pane forward, `swift tools/helm-select.swift <pane-uuid>`** — the fifth spool
  kind (#284), needing what the other four need: nothing. It makes the pane the one its slot is
  **showing**, which is what *visible* means, and leaves **focus** where the operator put it
  (`Workbench.select(offering:)`, the non-seizing twin of the tab click). Same uuid namespace and
  the same three ways to know one as `helm-close`.
  - **It exists because `push.sh` offers rather than inserts.** On a busy bench a pushed artifact
    lands as a background tab — `isSelected: false`, `isVisible: false` — so #272's re-push
    refresh was real and *unobservable to the agent that triggered it*. The `selected` result
    carries `select.isVisible`, read back off the bench, which is the answer that was missing.
  - **The rule is one sentence: an agent may show a pane in a slot the operator is not in**, and
    there is no override — `helm-select` has no `--force`, because `CloseRequest.force` is a
    caller asserting about work *it* owns and where the operator's eyes are was never that.
    Refused: the pane holding the keyboard, and — the case a close's rule cannot see — **a
    background tab of that same slot**, because the focused slot's *selection* is the focused
    pane, so showing one of its tabs takes the keyboard. `SpoolPaneState.keyboard` is three-valued
    for exactly that reason (`elsewhere` / `inItsSlot` / `here`), and `SpoolSelectPolicy` is
    exhaustive over it.
  - **The result proves the promise rather than asserting it**: `select.focusedPaneBefore` and
    `select.focusedPaneAfter` are two readings of `Workbench.focusedPane` taken either side of the
    mutation, and the script warns loudly if they differ. Exit codes are 2 no answer, 3 refused,
    4 helm could not act, 6 abandoned.
- **To drive the bench in between, `swift tools/helm-command.swift <command>`** — the fourth
  spool kind (#269), needing what the other three need: nothing. helm has twenty typed
  commands (`HelmCommand`, #219, #287 and #289) and **will take four of them from an agent**:
  `newTerminal`, `splitRight`, `splitDown`, `toggleRail`. `--list` names them without a running
  helm.
  - **The rule is one sentence: rearranging the bench is fine, taking focus is not.** It is
    #125's *appear, don't seize* on a channel that can now ask for anything the keymap can — an
    agent selecting your active tab mid-thought is the wrong-terminal click arriving through a
    supported API. The other sixteen are `refused` results **naming the reason and, where one
    exists, the route to use instead**: `closePane` points at `helm-close`, `selectTerminal` at
    `helm-select` (#284),
    `openCanvasFile` and `openArtifact` at `push.sh`, `openWorkspace` at `helm-spool` — a
    spawn's `cwd` is the workspace helm opens for it. The rest name no route because there
    isn't one yet, and say so by saying what an addressed version would have to carry.
  - **Every command that is still refused is one with no address**, and that is #176's rule
    extended rather than reinvented. `helm-close` names a pane and refuses the one holding the
    keyboard, and `helm-select` does the same for the other direction; `selectTerminal`
    (an *index* into the focused slot), `closePane`, `toggleChat`, `adjustFontSize` and
    `jumpToPrompt`
    name nothing, so they act on whichever pane the operator is in and there is nothing for a
    policy to check. An addressed version would carry a pane and refuse it when
    `SpoolPaneState.holdsKeyboard` — the shape is `CloseRequest`'s, and for `movePane` it is
    still not built.
  - **An allowed command routes to helm's own non-seizing twin**, which is a distinction helm
    has drawn since #125 and named both halves of: `Workbench.insert` is the operator asking,
    `Workbench.offer` is an agent offering. `newTerminal` → `WorkbenchModel.spawnTerminal()`
    (which predates this and is what a spawn already uses); the splits →
    `offerSplitRight()`/`offerSplitDown()`. The honest cost, recorded: an agent's split still
    **halves the column the operator is in**, because a bench command carries no address — a
    layout change around them, not a focus change to them, exactly as a pushed artifact already
    rebalances columns.
  - **The result says what happened**, so no caller has to re-read `snapshot.json` and race it:
    `command.paneCreated` (also copied to `terminalId`, so `helm-close <terminalId>` is the next
    move with no lookup), `command.focusedPaneBefore`/`After` — **equal, which is the focus rule
    made checkable by the caller rather than argued in a header** — and the bench's column and
    pane counts. Exit codes are 2 no answer, 3 refused, 4 helm could not act, 6 abandoned.
  - `SpoolCommandPolicy` (`Sources/HelmWire/Spool/SpoolRequest.swift`) is the allowlist and the
    argument; it is **exhaustive over `HelmCommandName`**, so a command cannot be added without
    a verdict — `movePane` (#287) and `newNote` (#289) are the two since, and both arrived
    refused because the compiler asked. Read it before widening the list.
- **The operator writes on the bench now, and every markdown canvas is a file he can write in**
  (#289). The header carries a **Write ⇄ Read** toggle; **Read is where it starts**, so an
  editable canvas is indistinguishable from a read-only one until he presses it. Write opens a
  `TextEditor` over the markdown **source** (not the rendered page — that would be an
  HTML→markdown round trip over a document nobody asked helm to reformat), autosaves 600ms after
  typing stops, and flushes on Read, on close, on the canvas being pointed elsewhere, on the last
  workspace closing (`WorkbenchModel.deactivate`, which drops the canvas cache without closing
  what is in it) and on ⌘Q. The path is on the editor's footer as a `CopyableLabel`; **it is not
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
  - **Two honest limits, and neither is silent while it is happening.** Closing the pane with a
    conflict unresolved takes the buffer with it — the strip has been up since the moment it
    happened, and making the close ask would put a modal on a path `helm-close` also reaches,
    where there is nobody at the pane to answer. And a file **deleted** under an open draft is not
    a conflict: it loads as a notice rather than markdown, the draft stays, and the next save
    recreates the file.
  - **Nothing tells an agent the operator edited, and that is the answer rather than an
    oversight.** He hands you a path; read it, and **read it again before you rewrite it** — the
    file's own mtime is the only fact, and it is the filesystem's rather than helm's. Nothing
    wakes you when a file changes, same as the state latch. `notes/` in particular is his
    directory: writing there is still wrong, for a reason about ownership rather than about what
    helm will let anyone type into. Artifacts go to `plans/`, `research/`, … and reach the bench
    through `push.sh`.
- **`helm-spawn` is the GUI path, and still there** — `swift tools/helm-spawn.swift <cwd> --prompt-file <p>`
  (also `<cwd> -` for stdin, or a prompt in argv). It is the five-step GUI dance — focus, ⌘N,
  type `cls`, wait, type the prompt, submit — with every step waiting on something observable
  instead of on a `sleep`: focus polled until helm really is frontmost, the new terminal
  confirmed by a new child of helm's pid, that terminal's shell required to have **no** child
  before anything is typed (every terminal already hosting an agent has a `claude` under its
  zsh, so this is what stops keystrokes landing in a live session), and the agent confirmed by
  its row appearing in `~/.claude/sessions/`. It prints the new agent's pid and session id.
  **A nonzero exit is the whole point** — each refusal has its own code and says on stderr
  whether anything was typed. The prompt never goes through the keyboard or the shell's word
  splitting: it is staged in a 0600 temp file and **argv carries that file's path**, so
  multi-line prompts, quotes, and a leading `/` are all ordinary.
- **What `ps` shows of a spawned agent, and what it does not (#93).** Both spawn paths hand the
  agent a **path**; neither hands it the prompt. The line used to be `cls "$(cat <file>)"`, which
  reads as private and is not — a shell resolves a command substitution *before* exec, so the
  whole prompt became an element of the agent's own `argv`. Measured live 2026-08-07:
  `ps -o command= -p <pid>` printed a running agent's entire multi-line prompt, and the disclosure
  #93 was filed over is an agent running `pgrep` and finding another agent's plan in its own
  output. **What is bought is that the prompt is out of incidental process-table output. It is not
  secret**: argv carries the path, the file is `0600` in a `0700` directory, and every agent here
  runs as the same user, so anything that goes looking can read it — the trust boundary this
  channel already assumes. **No agent has a flag for this**, measured against `claude --help`,
  `pi --help` and `codex --help`: all three take the first prompt as an argv element and none
  reads it from a file interactively, so delivery is the agent's own first act and **the prompt
  file must outlive the spawn** — `helm-spawn` no longer deletes it, and the spool keeps
  `prompts/<id>.txt`.
- **Do NOT click, type or switch tabs in helm while a spawn is in flight.** Every guard
  helm-spawn has is about the *app* — frontmost, key window, a new terminal, an idle shell —
  and none of them can see **which pane inside helm holds the keyboard**, because that is not
  observable from outside the process. Move focus mid-run and the launch line is typed into
  whatever pane you moved to. That is how #96 was filed, and it is a real precondition rather
  than advice. It is now *caught* rather than prevented: after Return, helm-spawn requires the
  target terminal's shell to gain a child within 10s and refuses with **20** if it does not
  (verified: 11s and exit 20 with focus stolen mid-spawn, against 90s before; an uninterrupted
  spawn still finishes in about 2s, because the check is charged against `--timeout`, not
  added to it).
- **helm-spawn needs the display, and refuses rather than typing into nothing.** Unlocked
  screen, a visible helm window, and an Accessibility grant on the invoking context — the
  same per-context TCC rule as winshot's Screen Recording grant, and one no agent can grant
  itself. A headless agent cannot use it at all; that ceiling is the argument for #51's rung 2.
  `--dry-run` answers "could I spawn right now?" without sending a keystroke.
- **With two helms running, pass `--helm-pid`.** Two is the *normal* state while building helm
  — the operator's, plus a worktree build under test — and they are identical by name, so
  helm-spawn used to refuse (`manyHelms`, 13) exactly when an agent was doing helm work. The
  refusal now lists the pids to choose from. `winshot --list` shows which is which, subject to
  the Space caveat above.
- **A spawn needs Claude Code to already trust the directory, and helm-spawn checks first.**
  An interactive `claude` in an untrusted directory stops at "Is this a project you trust?"
  *before* it registers a session, which from the outside is indistinguishable from an agent
  that is merely slow — it cost a full 90s timeout to find. Trust is **inherited from an
  ancestor**, so accepting it once at a project root covers every worktree under it; a fresh
  worktree under `~/Projects/mine/sild` needs nothing. There is no non-interactive way to grant
  it (`claude -p` skips the dialog but records nothing), so the refusal tells you to run
  `cd <dir> && claude` once by hand.
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
    boundary — the same carve-out as the spool scripts and the mailbox, and the same
    obligation. `BuildStampScriptTests` runs both scripts as real subprocesses and decodes what
    they write with the real types, so a renamed key or field fails a test instead of shipping
    a helm that can never see an update.
- **helm persists to one domain, `com.wirasm.helm`, from both launch paths** — so "did it
  persist?" is `defaults read com.wirasm.helm` whichever way it was started, unless
  `HELM_DEFAULTS_SUITE` overrides it (next bullet). `swift run helm`
  used to land in a `helm` domain of its own, and reading the wrong one is how #45 produced a
  confident, wrong diagnosis. A build with the fix drains `helm` on first launch and leaves a
  single `helmDefaultsMovedTo` key there saying so. The identity lives in `SPMInfo.plist`,
  `project.yml`'s `PRODUCT_BUNDLE_IDENTIFIER` and `DefaultsDomain.canonical` — keep all three
  in step, `DefaultsDomainTests` fails if you don't.
- **A second helm must run on its own defaults suite: `HELM_DEFAULTS_SUITE=<name>`.** Unset is the
  behaviour above to the letter — `com.wirasm.helm`, both launch paths, one answer to "did it
  persist?". Set, helm reads and writes that suite and nothing else, so a worktree instance can be
  filled, quit, relaunched and hand-corrupted with **no reachable path to the operator's state**
  (measured: `UserDefaults(suiteName:)` does not read through to the app's own domain). Verify with
  `defaults read <name>`, and prove the negative with `defaults read com.wirasm.helm`.

  ```
  HELM_DEFAULTS_SUITE=helm-bench swift run helm
  ```

  **Do not hand-roll a throwaway `PRODUCT_BUNDLE_IDENTIFIER` any more** — that is what PRs #97 and
  #100 each had to invent, and #86 is that made supported. Refusals are loud rather than silent:
  the legacy `helm` domain, a path, and `NSGlobalDomain` all stop the launch, because falling back
  to `com.wirasm.helm` under a variable that promised isolation is precisely the disaster. An
  isolated instance says so — the status bar carries the suite name on an accent capsule, and the
  window is titled `helm — <name>`, which is what `winshot --list` and `helm-spawn --helm-pid` see
  when two helms are running. The legacy-domain migration never fires under it, and the window
  frame is not autosaved: that last one is AppKit's write rather than helm's, and the only one a
  suite cannot catch by itself.
  - **"No reachable path" is a promise about four directories, not one, and the fourth was a
    lie until #285.** The suite moves the defaults, the spool (`~/.helm/spool-<name>`), the bench
    snapshot (`~/.helm/bench-<name>`) — and now the **mailbox**, `~/.helm/mail-<name>`. It did not
    move mail, so a capability test launched under `HELM_DEFAULTS_SUITE=drivetest` spawned an
    agent that claimed `helm-31b1` in the operator's live `~/.helm/mail` beside his real ones:
    addressable by them, listed to them, widening handles against them (#262) and sweeping their
    mailboxes with the reaper on every session start (#236). Isolation is the whole reason those
    tests are safe to run on a live machine, so the promise was fixed rather than narrowed.
  - **It could not be fixed in helm alone, and that shape recurs.** helm only *reads* the mailbox;
    it is **claimed** by `hooks/helm-mail.mjs` and `pi/extensions/helm-mail/index.ts`, two
    processes helm does not run and cannot import from. So helm **declares** the suite into every
    pty child (`PaneEnvironment.suiteDeclaration` — the decided name, never a raw value helm would
    itself refuse) and both writers resolve it with the same three rules `SpoolDirectory.resolve`
    follows: `HELM_MAIL_DIR` first, then the suite, then the shared root. That is one rule in three
    languages, which is the mailbox's standing carve-out and its standing obligation —
    `hooks/mailbox-conformance.mjs` now extracts `MailboxDirectory.resolve` and
    `DefaultsSuite.override` from the Swift and runs all three copies against one fixture set, so a
    divergence is a red gate rather than a helm that cannot see the agents it is hosting.
    **The writers' copy is deliberately narrower in one clause**: `UserDefaults(suiteName:) != nil`
    is a framework call JavaScript cannot make, and for a name refused on that ground alone helm
    refuses to *launch*, so no running helm can disagree. The harness asserts that clause is still
    the only one.
  - **The negative control, and it is what a claim here has to bring.** `hooks/test.sh` and
    `pi/tests/helm-mail.mjs` each claim under a suite with `HOME` redirected and then assert the
    shared `~/.helm/mail` **was never created** — not that it holds a different mailbox.
- Conventional commits, written as a human — no AI attribution.

## Architecture — how to think about where code goes

**Vertical slices by feature, not layers.** `Sources/Helm/<Feature>/` holds that feature's
model, views and commands together. If a thing can name a single feature, it belongs in that
feature's directory — including its keyboard shortcuts and notification handling. Only work
that genuinely spans features stays in `App/`, which is composition and nothing else. The
test is simple: two people building two features should not have to edit the same file.

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
`tools/helm-close.swift` hand-rolls the spool's JSON as `["id": id, "kind": "close", …]`, and
that is only half fixed. `HelmWire` (#221) is a library target holding `SpoolRequest`,
`SpoolResult` and the spool's directory-resolution rules, and `Helm` and its own tests compile
against it for one definition instead of each restating it. `tools/*.swift` cannot join them: a
single-file script needs no `Package.swift` resolved and no cwd inside this repo, which is the
whole reason the spool is a script rather than an SPM target — see "Why the spool is a script,
and must stay one", above, for what #221 measured when it tried the other way. So the format is
typed once in `HelmWire` and spelled out once more in `tools/helm-spool.swift`/`helm-close.swift`/
`helm-capture.swift`/`helm-command.swift`/`helm-select.swift`, on purpose. A duplicate is honest
only when a runtime boundary makes
sharing impossible, and two wire formats now earn that carve-out: the mailbox's, written twice
— in Swift (`hooks/`) and TypeScript/JavaScript (`pi/`), both separate processes `HelmWire`
cannot reach — and the spool's own, written twice — once in `HelmWire`, once by hand across the
five scripts, for the reasons just given. Neither is left to drift unnoticed by nothing at all
— `SpoolWireConformanceTests` (`Tests/HelmTests/Spool/`) runs each spool script as a real
subprocess and checks both directions of the spool format (the request it writes and, against
every `SpoolResult.Status`, its exit code and stderr) plus the `HELM_DEFAULTS_SUITE` branch of
directory resolution, so a drift anywhere in that surface fails a test rather than shipping
silently. The one branch it cannot reach is the bare default resolution, which the test file's
own header explains — it resolves to the operator's live spool, and a test does not get to write
there. `focus.swift`, `winshot.swift`, `ticklog.swift` and `helm-spawn.swift` stay
standalone scripts too, for a simpler reason — none of them touch the spool's wire format at all.

**A payload that can grow a second kind carries a discriminator from the first one.**
`SpoolRequest`'s `{id, kind}` envelope and `Pane.Content`'s string `kind` cost one field each and
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
pushed artifact is routed by comparing `request.workspacePath == model.workspacePath` **by value**,
so a path that reached that line un-normalized matched nothing and the artifact simply never
appeared — no error anywhere. `Handle` (#231, #233, #239): a handle *looks* derivable, and a
derived one is silently wrong whenever `deriveHandle` widened its suffix 4 → 6 → 8 to dodge a live
holder, which the caller cannot see. `TerminalID` (#231): a `UUID` in the app, `.uuidString` across
the spool and `UUID(uuidString:)` on the way back — a parse a caller could forget, answered with a
`nil` three calls downstream instead of a compile error. **All three were caught by a reviewer
reading a comment, none by a red test**, which is the reusable part: the rule fires while the
defect is still hypothetical, and by the time a gate can see it the newtype is a migration.

**A stored raw field behind a validating constructor is not a violation — it is the shape.**
`MailboxOwner.handle` stays a `String` precisely because `Handle(readingFrom:)` needs a raw field to
read *from*; wrapping it at the decode site would make the blessed path indistinguishable from any
other and therefore pointless. `CloseRequest.terminal` and `SpawnRequest.cwd` stay `String` because
a request is decoded permissively in shape and judged strictly afterwards — that is what makes a
malformed uuid a `refused` result naming the reason rather than unreadable JSON under the wrong id.
Each of those argues itself in its own header; do not "fix" them.

**What is still loose today is the spool request `id`.** It is gated as the filename it is — *"`..`
and `/` are the whole reason: an ungated id writes wherever the caller likes"*
(`Sources/HelmWire/Spool/SpoolRequest.swift:318`) — by a regex applied at exactly one edge,
`SpoolPolicy.accept` (`SpoolRequest.swift:338`), while the value itself stays a bare `String` in
seven declarations with open initializers (`SpoolRequest.swift:85`, `:129`, `:183`, `:236`, `:261`,
`:276`, `SpoolResult.swift:82`). So every site that needs the guarantee has to **ask again, by
hand** — which is the exact defect `SpoolWork`'s own header, in that same file, says its shape
exists to prevent: *"so that 'has this been checked?' is answered by the compiler at every call site
instead of by reading upwards"* (`SpoolRequest.swift:227`). `id` is the field in those structs that
is still answered by reading upwards.

Note what this is **not**: `SpoolPolicy.idPattern` is defined exactly once (`SpoolRequest.swift:320`)
and *referenced* by both sites, so `SpoolModel.refuse` (`Sources/Helm/Spool/SpoolModel.swift:232`) is
a second **guard**, not a second **spelling** — it is not the two-hand-maintained-copies defect
`Handle`'s header describes, and it is there for a real reason: `refuse` is also reached with
`fallbackID` (`SpoolModel.swift:195`), an id derived from the *filename* when the JSON would not
parse and `SpoolPolicy.accept` never ran.

The cost lands where nobody asked at all. `answerAbandoned` (`SpoolModel.swift:173`) takes an id
straight out of a claimed request's JSON via `SpoolDirectory.abandoned()` (`SpoolDirectory.swift:176`,
decoded with no pattern check) and hands it to the path builder at `SpoolDirectory.swift:132` — and
`appendingPathComponent` does not collapse `..` (measured: `results/../../../../tmp/pwned.json`).
The three scripts do not ask either: `tools/helm-close.swift:113` hand-validates the *terminal*
uuid, not the id, then interpolates the id into a path. Two sites ask, four do not — and a guard
that has to be remembered is what a type exists to stop being a memory test. The fix is the one this
file already made five lines below, in the same struct: `AcceptedCloseRequest.terminal` got
`TerminalID` for exactly the "a parse a caller could forget" argument, and `id` — the field whose own
comment says it writes wherever the caller likes — did not. Tracked as #260.

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

### pi extensions

How to build one without taking the pi CLI down, how to read the installed pi rather than guess
at its API, and how to test one without spending a model call. See
`.claude/skills/pi-extensions/`. Hand-written and helm-local — not vendored, so not in
`skills-lock.json`.
