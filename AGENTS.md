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

So before suspecting your diff, or the load, ask ghostty:

```
log show --last 30m --style compact --predicate 'subsystem == "com.mitchellh.ghostty"'
```

`embedded_window: error initializing surface` means `ghostty_surface_new` refused, so **no
terminal exists to type into** and every keystroke assertion in `TerminalKeyboardTests` and
`WorkbenchFocusRoutingTests` fails for that reason alone, on any tree. Those two suites now
say so themselves rather than reporting `pty saw <nothing>` — the sentence that reads as a
focus bug and is not one. Everything in them that does *not* need a surface still runs and
still fails on a real regression: proved by reinstating #96's contract (seven tests then also
fail on the first-responder assertion) and #152's click routing (five more, on the bench).
A surface failure is an **environment** report, not a verdict on the diff, and the log line is
the evidence to bring.

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
`.ts` extension and a hook is a standalone script, so any change to the address scheme, the notice
or the on-disk shape has to be made in both. Needs node, which is why it is not in the Swift gate.

Only when `pi/` changed. It needs node, and `tsc` from an `npm install` in `pi/`, which is
why it is not part of the Swift gate: `swift test` cannot run TypeScript and should not
learn how, and a Swift contributor should never need a JS toolchain to go green. See
`pi/AGENTS.md`.

- **Never restart a running helm without warning the operator** — a live window may be
  hosting their session.
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
  against a real `SpoolResult` for **every** `Status` case, not a sample — plus the
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
- **To close a pane again, `swift tools/helm-close.swift <terminal-uuid> [--force]`.** The
  inverse of `helm-spool`, needing what it needs — nothing: a file appears, helm acts, helm
  writes a file back (#176). The uuid is a spawn result's `terminalId`, or the `HELM_PANE` of
  the pane you are running in; those are the two ways to know one, and **knowing it is the
  scoping**. helm deliberately does *not* check that it spawned the pane for you: that would
  buy no safety (anything that can write into the spool is already inside the trust boundary),
  would not survive a restart (the pane is persisted, an in-process memory of spawning it is
  not), and would forbid the two legitimate cases — an agent closing the pane it is itself in,
  and a coordinator tidying up a teammate. `CloseRequest` argues it in full.
  - **Two refusals, and they are not the same refusal.** A pane with a **live process** refuses
    unless you pass `--force`, because closing it kills whatever was running and loses what it
    had not written down — "is anything running" is `getsid(foreground) == foreground`, the
    pty's session leader being its own foreground meaning an idle prompt. The pane the
    **operator is working in** refuses *and `--force` does not override it*: force is a caller
    asserting about work it owns, and where the operator's eyes are is not something a file on
    disk gets a say in. Both are `refused` results with a reason, exit 3.
  - **It stops at the pane — no worktree, no branch, no git at all.** #141's rail already owns
    that, and its safety *is* an operator confirming a modal against eligibility rules; a spool
    request has nobody at the pane by construction, so reaching that rail from here could only
    mean a dialog no one will answer or a confirmation skipped. That is the strongest possible
    guarantee that unmerged work is never destroyed. `SpoolClosePolicy`'s header has the
    argument and the shape a later worktree kind would have to take.
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
  splitting: it is staged in a 0600 temp file and read back with `"$(cat …)"`, so multi-line
  prompts, quotes, and a leading `/` are all ordinary.
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
`helm-capture.swift`, on purpose. A duplicate is honest only when a runtime boundary makes
sharing impossible, and two wire formats now earn that carve-out: the mailbox's, written twice
— in Swift (`hooks/`) and TypeScript/JavaScript (`pi/`), both separate processes `HelmWire`
cannot reach — and the spool's own, written twice — once in `HelmWire`, once by hand across the
three scripts, for the reasons just given. Neither is left to drift unnoticed by nothing at all
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
the unstandardized value unconstructable. The same invariant is still loose elsewhere.
`workspacePath` is a raw `String` in 48 places across Archon, Terminals, Workbench, Worktrees and
Canvas, and it is the key a push is routed on (`WorkbenchModel.swift`). `MailboxDirectory` spends
twenty lines arguing that a handle is *read, never derived* — and a handle is a `String`. A
`terminalId` is a `UUID` in the app, a `String` across the spool, and a `UUID` again on the way
back. Prefer a newtype the day the comment gets written, not the day it is disbelieved.

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
