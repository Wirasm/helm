# Testing helm: running parts alone and reading a red run

`AGENTS.md` has the rules. This page has the detail behind them: how to run one suite or one
gate alone, and how to tell an environment failure from a regression.

## Running one suite

```
INJECTION_NOGENERICS=1 swift test --filter TerminalKeyboardTests
```

Without `INJECTION_NOGENERICS=1`, `--filter` (and `--skip`) dies with `error: signalled(10)` from
`swiftpm-xctest-helper`. It is not helm's bundle. The helper `dlopen`s the test bundle, that runs
`+[NSObject(InjectionBoot) load]`, and InjectionNext rebinds `swift_allocateGenericClassMetadata`
across every loaded image; `rebind_symbols_image` takes SIGBUS on a `KERN_PROTECTION_FAILURE` (the
`.ips` in `~/Library/Logs/DiagnosticReports` names every frame). A plain `swift test` survives
because InjectionNext skips the hook when `XCTestConfigurationFilePath` is set, which the real
`xctest` host does and the bare helper does not. `INJECTION_NOGENERICS=1` is the same off switch
by its other name and changes nothing else: the hook only exists to hot-swap generics in a running
app.

`xcrun xctest -XCTest HelmTests.TerminalKeyboardTests/testFoo <bundle>.xctest` is the other way
in and never involves the helper. It also runs a bundle you did not just build, including an old
one (that is how #192 was settled).

## Running one gate

| Gate | Alone | Notes |
| --- | --- | --- |
| `daemon` | `bash daemon/test.sh` | Rust only. Read `daemon/AGENTS.md` and `daemon/direction.md` first. It also runs the `bash` blocks in the `bench-*`, `helm-canvas` and `helm-orchestrate` skills' `SKILL.md` against a real benchd. |
| `pi` | `bash .claude/skills/pi-extensions/scripts/test.sh` | Needs node and `npm install` in `pi/`. See `pi/AGENTS.md`. |
| `ios` | `bash scripts/check.sh ios` | Builds Pocket for the iOS simulator. Needs Xcode with its iOS platform installed, and xcodegen. |
| `helm-board` (in `skills`) | `bash .claude/skills/helm-board/test.sh` | Executes `board-core.js` in node (ownership diff, overlap resolution, state report), checks `new-board.sh`'s refusals and re-hashes the vendored `@quickdrawjs/core` against its pin. |
| `post-canvas` (in `skills`) | `bash .claude/skills/post-canvas/test.sh` | Builds stored runs in a temp `ARCHON_HOME`, runs the driver with `--no-push`, and runs the `SKILL.md` snippet under zsh with `PRP_HOME` redirected. |
| merge queue | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .archon/workflows/helm/.shared` then `archon validate workflows helm-merge-queue` | Only when `.archon/workflows/helm/` changed. Its README says how to run the queue. The rest of `.archon/` is gitignored. |

The one piece of the board's seam the Swift gate owns is `data-helm-surface`: three files spell it
and one is Swift (`CanvasSurface`, `CanvasSurfaceTests`).

## CI and the local gate differ

CI's jobs are `build · test · format` (`lint`, then `swift`), `skill gates` (`skills`),
`fmt · clippy · build · test` (`daemon`) and `pocket · ios build` (`ios`). All but `skill gates`
pass without running when `scripts/check.sh --needs` says nothing they cover changed. `skills` runs on every PR. There is no
`pi` job.

- CI sets `HELM_CHECK_HEADLESS=1`, which skips `TerminalKeyboardTests` and
  `WorkbenchFocusRoutingTests`: a runner has no active display and those suites need a real
  ghostty surface. A regression in either passes CI, so run `just check` locally before the PR.
- CI sets `HELM_CHECK_MIN_FREE_GB=0`, which turns off the gate's free-space floor (20 GB on the
  repo's volume by default). A runner's disk is not ours to manage.
- CI tests the merge commit, not your branch tip. Two PRs merged 56 seconds apart on 2026-08-06,
  each green on its own branch, and `development` did not compile.

## A red keyboard or focus test

A red `TerminalKeyboardTests` or `WorkbenchFocusRoutingTests` run is not evidence that the machine
is busy. #192 measured it: a bundle built at 13:19 and never rebuilt was green at 13:19 and red at
19:00, and every worktree on the machine went red in the same second.

Ask the log, by absolute path (`log` is a zsh builtin; piped into `grep`, the bare form exits 0
with no output and reads as an empty log, #249):

```
/usr/bin/log show --last 30m --style compact \
  --predicate 'subsystem == "com.mitchellh.ghostty" OR subsystem == "com.apple.corevideo"'
```

Two lines matter, within a millisecond of each other:

```
[com.apple.corevideo:] CVDisplayLinkCreateWithCGDisplays error -6661 due to invalid display count (0)
[com.mitchellh.ghostty:embedded_window] embedded_window: error initializing surface err=error.OutOfMemory
```

The ghostty line says `ghostty_surface_new` refused, so no terminal exists to type into and every
keystroke assertion fails on any tree. The CoreVideo line names the cause: every display asleep
means zero active displays. It is not memory (#253 ruled that out, and reproduced `-6661` without
helm). Both suites name the surface failure themselves instead of reporting `pty saw <nothing>`,
and everything in them that does not need a surface still runs.

The control run stands on its own: `git checkout origin/development -- <files>`, grep the files to
confirm the revert landed, rebuild, and show the same failures on the base. Bring it with the log
lines, or alone when the log says nothing. A branch that touches no compiled code can say so: its
test binary is the base's.

A run that stops mid-test with exit 1 and no result line is a crash inside ghostty. Its log line is
`sentry: crash report written to disk path=…`, and the report in `~/.local/state/ghostty/crash/` is
a Sentry envelope with a minidump: read the stack before guessing. #462 was one (a test's
`unsetenv` left `ghostty_init`'s kept `environ` pointer reading NULL; the wrapper now copies
`environ` after init, so `setenv`/`unsetenv` are safe).

## Tests that sleep

`swift test` is not load-sensitive, with two documented exceptions whose assertions need a
`Task.sleep` to stay inside a deadline: `CanvasEditorTests.testARunOfTypingIsOneSave` (a 50×
margin) and `KeyPopupTests.testARenewedHoldRestartsTheDelay` (0.8 s against a 2 s delay). `Task.sleep(for:)` is a floor, so a loaded machine overshoots it, the behaviour
happens correctly, and the test calls that a failure. Each says so in its header. A test
that sleeps to let a window elapse is only made more certain by an overshoot. Say which direction
a new sleep goes before adding one.

Reproduce a timing failure by inverting its parameters, not by adding load. Setting the window
below the gap failed byte-identically to CI on the first try, twice (#305, #314); twelve burners
at load 43 did not. If you do start burners, bound each with `timeout`.

## Test hygiene

Whatever a test creates it removes (`Drop`, `addTeardownBlock`, `trap … EXIT`). The two things a
killed run can leave carry its pid and the next run removes them once the pid is gone:
`bcf-<pid>-<n>` in the daemon conformance suite and `helm-pty-<pid>-…` in the keyboard suites.
`just check` runs `daemon`, `skills` and `pi` with a private `TMPDIR` and fails a part that leaves a
file or a running process there. Do not end a test's child with SIGQUIT or SIGABRT: macOS writes a
crash report for each. `just prune-worktrees` removes merged worktrees and their builds
(`--dry-run` lists them).

A test never reaches the operator's benchd. An agent in a pane inherits `BENCH_DIR=~/.bench`,
`BENCH_SESSION`, `BENCH_HANDLE`, `HELM_PANE` and possibly `BENCH_URL`. The daemon conformance suite
starts every child through `isolated()`, which removes them. A Swift test draws from `FakeBenchd`,
or names its daemon explicitly: a temp `BENCH_DIR`, or an endpoint its own script started. #493: a test that built `RootView` with
`BenchClient.live()` drew the operator's bench and took his terminal sessions, which is why
`RootView` has no default client.

## Testing cross-origin browser pickers

With `timeout`, Node, `bench`, `benchd`, and Chrome installed, run:

```sh
scripts/test-browser-oopif.sh
```

The runner starts a private benchd, headless Chrome profile with mock keychain, and the HTTP
fixture in `Tests/BrowserFixtures/oopif.mjs`. It sets `HELM_BROWSER_LIVE_BENCH_DIR` and
`HELM_BROWSER_OOPIF_URL` for `BrowserOOPIFLiveTests`, which otherwise skip in the normal Swift
gate. The tests require two actual iframe targets: `localhost` → `127.0.0.1` → `localhost`.

The runner bounds every long-lived process, checks its recorded pids after cleanup, and removes
its temporary root and private defaults suite. It never opens a native browser window. Pass a
test filter as the first argument and further Swift test flags after it. Set `OOPIF_TEST_WT` to
run against another checkout; the runner uses that checkout's fixture and Swift tests.
