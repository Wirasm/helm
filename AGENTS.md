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

**This gate needs only the Swift toolchain and xcodegen. Keep it that way.** It is the one
command a fresh worktree runs, and every dependency added to it is a dependency every
contributor now needs.

**If you touched `pi/`, run its gate too — it is separate on purpose:**

```
bash pi/test.sh
```

Only when `pi/` changed. It needs node, and `tsc` from an `npm install` in `pi/`, which is
why it is not part of the Swift gate: `swift test` cannot run TypeScript and should not
learn how, and a Swift contributor should never need a JS toolchain to go green. See
`pi/AGENTS.md`.

- **Never restart a running helm without warning the operator** — a live window may be
  hosting their session.
- **Never delete a test to make the gate green.** If its subject genuinely no longer
  exists, say which and why in the commit.
- **You may or may not be able to see the UI — test, don't assume.** Screen Recording is a
  TCC grant on the *invoking context*, not on agents as a category: some contexts have it,
  none can grant it to themselves. The test is `swift tools/winshot.swift helm <out.png>`,
  which exits nonzero when the grant is missing. `--list` needs no grant at all and
  separates a real window from a crash, a zero-sized one or an off-screen one — but says
  nothing about what is drawn. The accessibility tree is a dead end either way: helm's
  centre is a Metal-layer NSView with no child elements to enumerate (verified against a
  known-good build). A capture shows you pixels, not correctness — never report a surface
  as verified on appearance alone without the operator.
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
- **To start another agent in helm, use `swift tools/helm-spawn.swift <cwd> --prompt-file <p>`**
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
  persist?" is `defaults read com.wirasm.helm` whichever way it was started. `swift run helm`
  used to land in a `helm` domain of its own, and reading the wrong one is how #45 produced a
  confident, wrong diagnosis. A build with the fix drains `helm` on first launch and leaves a
  single `helmDefaultsMovedTo` key there saying so. The identity lives in `SPMInfo.plist`,
  `project.yml`'s `PRODUCT_BUNDLE_IDENTIFIER` and `DefaultsDomain.canonical` — keep all three
  in step, `DefaultsDomainTests` fails if you don't.
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
