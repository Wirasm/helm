# AGENTS.md — helm

Native macOS surface: SwiftUI + GhosttyKit. Workspaces above a **workbench** — columns of
tabbed slots holding terminal, canvas and browser panes. **No backend of helm's own**: benchd
(`daemon/`) owns the bench, the sessions and the files, and helm draws them. Vocabulary is
canonical in `CONTEXT.md`.

**"Agent" means a CLI agent already in use — Claude Code, pi, codex.** helm hosts one in a
terminal and renders what it writes. It never builds or hosts an agent of its own.

Direction: `docs/direction.md` and `daemon/direction.md` (entry points, not specs).
`docs/future-planning/` is a proposal, not the tree. Its roadmap reads like a work order and is
not one: work there starts only when the operator names a milestone.

## The gate

All green before a PR to `development`:

```
just check              # or, with no `just` installed: bash scripts/check.sh
```

`scripts/check.sh` is the one definition of the gate, and CI calls it. It ends with one line per
part: `PASS`, `FAIL (rerun: <command>)` or `SKIP (<why>)`. `just check swift` runs only the parts
named.

| Part | Runs | Needs |
| --- | --- | --- |
| `lint` | `make lint`: formatting and the size limits below | Swift toolchain |
| `swift` | `swift build`, `swift test`, `xcodegen generate`, unless every change is one no Swift build or test reads | Swift toolchain, xcodegen |
| `skills` | the `helm-board` and `post-canvas` skill gates | node, zsh, python3, git, lsof |
| `daemon` | `daemon/test.sh`, when `daemon/`, `daemon.yml`, a `bench-*`, the `helm-canvas` or the `helm-orchestrate` skill, `RenderableFile.swift`, the shell integration or GhosttyTerminal's `Package.swift` changed | cargo, lsof |
| `pi` | the `pi-extensions` gate, when `pi/` changed | node, `npm install` in `pi/`, lsof |

"Changed" means against `origin/development`, committed or not. The path rules live only in
`scripts/check.sh` (`--needs <part> [base]` asks one). A missing tool is a `FAIL`, never a skip.
**`lint` and `swift` need only the Swift toolchain and xcodegen. Keep it that way**: they are what
every contributor's fresh worktree has to pass.

**Size limits (#418).** `lint` fails any new Swift function over cyclomatic complexity 15 or 60
body lines, a closure over 50, a type over 350 or a file over 600 code lines; `daemon` fails any
new Rust function over cognitive complexity 25 or 100 lines. **Split the code; never add a marker
to new code.** Legacy code carries a marker recording its value (`legacy (#418): 24, limit 15`),
and a marker on code back under its limit fails the gate until you delete it.

**A green CI is not a green local gate, and the reverse.** CI skips `TerminalKeyboardTests` and
`WorkbenchFocusRoutingTests` (no display on a runner), so only `just check` catches a regression
there. CI tests the merge commit, not your branch tip.

**To run one suite, set `INJECTION_NOGENERICS=1`**, or `--filter` dies with `signalled(10)`:

```
INJECTION_NOGENERICS=1 swift test --filter TerminalKeyboardTests
```

**Read the system log as `/usr/bin/log`, never bare `log`.** `log` is a zsh builtin, and zsh is
what Claude Code's Bash tool runs; piped into `grep` or `head`, the bare form exits 0 with no
output, which reads as an empty log.

**A red keyboard or focus test is usually no terminal, not your diff.** With every display asleep
ghostty cannot create a surface. The evidence is the CoreVideo `-6661` / ghostty `OutOfMemory`
pair in the log, or a control run on `origin/development` showing the same failures, or both.
`docs/testing.md` has the predicate, the control run, ghostty crash reports, the sleep-inside-a-
deadline flake and how to run each gate alone.

A `.build` from before the official-Ghostty move fails with `missing required module
'libghostty'`: `rm -rf .build` once. Bumping Ghostty is `scripts/bump-ghostty.sh`
(`docs/VENDORED.md`).

## Safety

Several agents share this machine and the operator's live helm. These rules are not optional.

- **Never restart a running helm without warning the operator.** A live window may be hosting his
  session. **Never restart benchd unless he has said nothing is in flight**: it ends every session
  (`just resume-all` brings the panes back).
- **Kill only a pid you have verified is yours, never a pattern.** `pkill -f` cannot tell the
  operator's helm from a worktree build.
- **Anything you spawn must die without you.** Bound its lifetime: `timeout <n> <cmd>`, or a loop
  with its own deadline, or `trap … EXIT`, in that order (the first two survive `SIGKILL` on the
  parent). Cleanup on the last line is not that: twelve CPU burners once outlived their script by
  nine hours and poisoned every measurement after. **Then check** with
  `ps -Ao pcpu,etime,pid,command -r | head`, and say what you left running.
- **Before blaming the machine, look at what is on it.** Load has an owner; name it.
- **A test leaves nothing behind**: no file, no process (`just check` fails a part that does), no
  child ended with SIGQUIT or SIGABRT (each writes a crash report).
- **A test never reaches the operator's benchd.** A pane inherits `BENCH_DIR=~/.bench`,
  `BENCH_SESSION`, `BENCH_HANDLE`, `HELM_PANE` and maybe `BENCH_URL`. Point a test at a temp
  `BENCH_DIR` with those removed, or at `FakeBenchd`; never `BenchClient.live()`. One test that
  did took the operator's terminal sessions (#493).
- **A second helm runs under `HELM_DEFAULTS_SUITE=<name>`**, beside its own `BENCH_SUITE=<name>`
  benchd, so it has no path to the operator's defaults, snapshot, bench or browser
  (`docs/running-helm.md`). Never hand-roll a bundle identifier for it.
- **Never copy an Apple system binary (`/bin`, `/usr/bin`, `/System`) to use as a fake app or
  executable in a test.** Use a shell script or a compiled stub. A killed copy was the last event
  before `syspolicyd` hung and took WindowServer down 58 times overnight. A test never runs a
  binary inside a `.app` it assembled, and any directory with `Contents/Info.plist` is a bundle:
  seal it with `codesign -s - --force` first (#439).
- **If a freshly compiled binary won't start, or `git`/`grep` hang for no reason, stop launching
  processes and tell the operator.** A macOS security daemon is stuck; only a reboot clears it,
  and every new launch queues behind it.
- **Never hard-code click coordinates.** Read the window's bounds every time. A stale click
  activates whatever is underneath and types into it.

## Proving a change

- **Never delete a test to make the gate green.** If its subject no longer exists, say which and
  why in the commit.
- **Watch a test fail before you trust it passing.** Take the fix out, run it, name which tests
  went red and on what assertion; put it back and confirm green. Report both runs.
- **Revert with `git checkout <base> -- <file>`, and grep the file before believing the run.**
  `git stash` after committing leaves the fix in place.
- **Some tests must pass either way — say which, and why.** Keep the ones that fail if the change
  overshoots, and name them as that.
- **A test that sleeps says which way.** A sleep that must stay inside a deadline flakes under
  load; one that lets a window elapse does not. Reproduce a timing failure by inverting its
  parameters, not by adding load.
- **Review the tree you are shipping.** A rebase invalidates every review of the files it
  rewrote; post against the final sha.
- **A capture shows pixels, not correctness.** Never report a surface as verified on appearance
  alone without the operator.

## Seeing helm

`bench get screenshot [--out <p.png>] [--window <title>]` makes helm draw its own window: no
grant, no display, works locked. Read `terminalContent` rather than assuming terminals are in the
picture; `windowVisible: false` means a blank web page is WebKit's suspension, not a bug. With two
helms, `--window` picks one. `tools/winshot.swift` captures from outside, needs a Screen Recording
grant you probably lack, and matches by substring: capture by pid. The accessibility tree is a
dead end. Details: `docs/running-helm.md`.

To read the bench without a display, read helm's snapshot: `~/.helm/bench/snapshot.json`
(`~/.helm/bench-<suite>/` under a suite, `HELM_BENCH_DIR` to override). Check `format ==
"helm.bench-snapshot"` and its `version`, and check `writtenAt` before acting; match your `HELM_PANE` or a spawn's `pane`
to a pane's `id`. A terminal pane's `agent` is `{status, waitingFor, statusUpdatedAt}` from
benchd. `waiting` alone is healthy; `waitingFor: "permission prompt"` on a pane nobody is at, aged
from `statusUpdatedAt`, is a stall. Read on demand; the file is replaced, not rewritten.

## Driving the bench

An agent's whole surface onto the bench is the `bench` CLI, the same door the operator's keys go
through: `open <file|browser|terminal>`, `split`, `show`, `focus`, `move`, `name`, `close`, `get`,
`get pane`, `get screen`, `watch screen`, `send`, `spawn`, `sessions`, `file read|write`, `mail`.
The skills are the guides: `bench-panes`, `bench-mail`, `bench-browser`, `bench-sessions`,
`helm-canvas`, and `helm-orchestrate` for running a fleet of agents through them.

- **Appear, don't seize (#125).** Every verb lands in the background. `--asked` means the operator
  asked, and only then may a verb bring something forward or move his keyboard. benchd cannot know
  what he said, so the rule is yours.
- **Closing a terminal where something runs needs `--force`**; the pane holding his keyboard needs
  `--asked`. A close stops at the pane: worktrees and branches are the Worktrees drawer's.
- **A spawned agent runs unattended, but some prompts no flag removes** (#283: a bypass-immune
  `rm` guard sat for six and a half hours). When one goes quiet, read its report
  (`bench sessions --all`) rather than adding a flag. A fork (`--fork`) is read-only on purpose.
- **A spawn's prompt is a file that outlives the spawn**: `ps` shows its path, never its text
  (#93). Claude Code must already trust `--cwd`; run `cd <dir> && claude` once by hand. codex
  must trust `--cwd` itself (a trusted parent does not count) or it stops at "Trust this
  folder?"; run `cd <dir> && codex` once. Trust is the operator's call either way.
  `bench status` names the binary and version each agent spawns with (`agents`).
- **Artifacts go to the project's `~/.prp/<key>/` store, never the repo**, and reach the bench
  through `bench open`. `notes/` is the operator's directory: never write there. He can edit any
  markdown canvas, and nothing tells you he did, so **read a file again before you rewrite it.**
- **An HTML canvas's live file** (`<name>.data.json`) is written with `bench file write --expect`,
  never a plain write. A mark he makes reaches you as mail, through benchd.
- **Mail is benchd's.** An agent reports through `bench hook <claude|codex|pi>` in its own hooks
  (`bench wiring --check` says whether a harness is wired). Which agent is in a pane has one
  answer, benchd's `mail/who`: do not add a second join. With no benchd, nothing is addressable,
  and each caller says so rather than guessing.

## Architecture: where code goes

**Vertical slices by feature, not layers.** `Sources/Helm/<Feature>/` holds that feature's model,
views, keys and commands. Only work that genuinely spans features goes in `App/`, which is
composition and nothing else. Two people building two features should not edit the same file.
The largest slices are `Canvas/`, `Workbench/` (drawing benchd's bench), `Terminals/` (the
libghostty seam; a terminal pane shows a benchd session through `bench attach`), `Keymap/`,
`Bench/` (helm as benchd's client) and the drawers' own slices. **`Board/` is agent presence and
the bench snapshot, not the drawable board** (that is the `helm-board` skill). Read
`ArchonModel`'s header before adding to the Archon drawer: several obvious additions were removed.

**benchd owns the bench; helm draws it** (#354).

- Every change is a `BenchVerb` sent through one door, `WorkbenchModel.send(_:by:asked:)`, saying
  who asked. `Workbench` has no mutating method; nothing is drawn until benchd's follower delivers
  the document the verb made. helm keeps no bench of its own and asks nothing at launch.
- **helm reaches benchd's machine only through benchd** (M5c): the socket or
  `BENCH_URL=tcp://<host>:<port>`. Canvas files are `file/*` verbs, the drawers' `git` and `archon`
  are `command/run`, notes and stores are `prp/*`, presence is benchd's session report. Do not add
  a direct file read or process launch for something that lives on benchd's side.
  `daemon/direction.md` has each slice.
- benchd unreachable is a status-bar capsule; the last document stays and a verb fails visibly.
  helm never starts benchd (`just benchd-install` makes it a login agent).
- Tests draw from `FakeBenchd` and `ToyBench`, whose toy rules are not benchd's. A Swift test
  asserts what helm sent or what it drew; placement and focus rules are tested in Rust.

**Keys are rows of one table** (`Keymap.table`): the built-in `KeyBindings.all` overlaid by the
operator's `~/.helm/bench/keymap.toml`, which helm reads every second and nothing writes. A row's
action is a `VerbTemplate` or a `LocalAction`, and may carry a `when` (browser keys fire only while
a browser pane holds the keyboard). After changing a built-in key, regenerate
`docs/keymap.default.toml`; `KeymapFileTests` fails until you do. There is no NotificationCenter
command bus: do not add one.

**Drawers are drawn over the bench, never in it** (#356). An agent puts a pane in a drawer, which
badges it, and never opens or moves one: `drawer/toggle` and `drawer/place` without *asked* are
refused. The edge the operator drags a drawer to lives in benchd's document. A key with
`action = "just"` runs a recipe from the operator's bench justfile through benchd.

**Put a handler where its lifetime is right.** A subscription that must work while its view is
closed belongs on the model.

**Prefer values over live objects at a seam**: a small `Codable` value, resolved to the live
object at the edge.

**The value must live where both sides of the seam can reach it.** The bench's wire has one
spelling: the Rust types in `daemon/crates/bench-wire` and `bench-doc`, with helm's Swift copies
in `HelmWire` pinned by the shared fixtures in `daemon/fixtures/`. Both gates read the same files,
so a field renamed on one side turns the other red. Change a wire shape on both sides and in its
fixture, in one PR. A duplicate is honest only across a runtime boundary, and only with a test
that catches drift.

**A payload that can grow a second kind carries a discriminator from the first**, and a decoder
refuses a kind it does not know. Anything read outside the process carries `format`, `version`
and `writtenAt` (`BenchSnapshot`).

**An invariant with a comment explaining it wants a type carrying it.** `StandardizedPath` and
`WorkspacePath` make the unnormalized value unconstructable. Prefer a newtype the day the comment
gets written.

**Colour is a palette token, never a literal and never a system default.** Spend
`Design/Palette.swift`; if a surface needs a colour that is not there, add a token.

**Let Swift's access control show the seam.** An extension that has to mutate another file's
`private(set)` state is the same module in two files; the split was wrong.

**pi extensions are TypeScript in `pi/`**, symlinked into `~/.pi/agent/extensions/`. Read the
`pi-extensions` skill and `pi/AGENTS.md` first. **`daemon/`** is Rust; read `daemon/AGENTS.md`.

Conventional commits, written as a human, with no AI attribution.

## Agent skills and helpers

- Issue tracker: GitHub issues on `Wirasm/helm` via `gh` (`docs/agents/issue-tracker.md`).
- Domain docs: `CONTEXT.md`, and `../GLOSSARY.md` for terms shared with kild and prp
  (`docs/agents/domain.md`).
- `.claude/skills/`: the seven listed in `skills-lock.json` are vendored from
  `mattpocock/skills` and pinned by hash, so do not hand-edit them. helm's own are `helm-canvas`
  (what a canvas can do), `helm-board` (the drawable board), `post-canvas`, `pi-extensions` and
  `helm-orchestrate` (running a fleet of agents on the bench); benchd's are `bench-panes`,
  `bench-mail`, `bench-browser` and `bench-sessions`.
- `.claude/agents/`: `house-rules-auditor` checks a change against this project's written rules,
  quoting each one; `seam-analyzer` hunts a missing type at a seam.
