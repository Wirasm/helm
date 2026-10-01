---
name: bench-panes
description: Drive the operator's bench with `bench` — put an artifact on it, open the browser or a terminal, spawn another agent into a pane, show, move, name or close a pane, read where a pane is, and capture helm's window. Use when you want the operator to see something, when you start another agent, when you tidy up panes you made, or when you need to know what is on screen.
---

# Driving the bench

The bench is the operator's window: workspaces of columns of tabbed panes, owned by `benchd` and
drawn by helm. You change it with the `bench` CLI, the same door his own keys go through. The
`bench` CLI is on your PATH or named by `$BENCH`.

## The one rule: background unless he asked

Every verb lands **in the background**: a new tab, a new column, a badge. It never takes his
keyboard. Add `--asked` only when the operator asked you to bring something forward or focus
it, in this conversation. benchd cannot know what he said, so this rule is yours to keep; the
flag is you saying he asked. Without it, a verb that would move his focus is refused (exit 3)
and the refusal says so.

Exit codes: `0` ok (the answer is JSON on stdout) · `2` no benchd · `3` refused, and stderr
names the rule and the way through · `4` failed.

## Put an artifact in front of him

```bash
BENCH="${BENCH:-bench}"
OUT=$("$BENCH" open "$ARTIFACT") || exit
PANE=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pane"])')
echo "$PANE"
```

- `$ARTIFACT` is a markdown or HTML file (`.md`, `.markdown`, `.mdown`, `.html`, `.htm`). A
  relative path is your cwd's. Anything else is refused before it reaches the bench.
- It opens in **your** workspace (the one your pane is in), not whichever one he is looking at,
  and it reuses the pane already showing that file. Write the file again and helm re-renders it.
- A mark he makes on it is mailed to you (the `bench-mail` skill reads it).
- `bench open browser` shows the shared browser (the `bench-browser` skill drives it);
  `bench open terminal` opens a shell. `--drawer <name>` puts it in a drawer instead. Every
  terminal pane is a benchd session, his own shells included (`bench sessions` lists them).

## Where is a pane, and can he see it

```bash
BENCH="${BENCH:-bench}"
"$BENCH" get pane "$PANE"
```

The answer has the pane, its `workspace` and `slot` (or `drawer`), `visible` (on screen now) and
`focused` (holds his keyboard). `bench get` prints the whole bench, every slot's id among it. Both
cover hidden and parked panes.

## Start another agent

```bash
BENCH="${BENCH:-bench}"
OUT=$("$BENCH" spawn --agent "$AGENT" --cwd "$WORKTREE" --name "$HANDLE" --prompt-file "$BRIEF") || exit
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["handle"], d["pane"])'
```

- `--agent` is `claude`, `codex` or `pi`. It runs in a pty benchd owns, in a pane of
  `--cwd`'s workspace, in the background. It keeps running while the pane is hidden, the screen
  is locked, or helm restarts. The answer has its `handle` (mail it with `bench mail send --to`),
  `session`, `pid` and `pane`.
- The brief is a **file**, and the file must outlive the spawn: the agent reads it as its first
  act, and `ps` shows the path, not the brief. Its role arrives in the brief; nothing else tells
  it where it stands.
- Each agent runs unattended: claude with `--dangerously-skip-permissions`, codex with
  `--dangerously-bypass-approvals-and-sandbox`, pi with `--approve`. `--model` and `--effort`
  pick the model. `--arg <flag>` adds a flag after the posture; it never replaces it.
- `--resume <session-id>` re-enters a claude or pi conversation instead of starting one.
- `--fork <session-id>` starts a new claude conversation that begins as a copy of that one, to
  ask about its work while the original carries on untouched. The fork gets its own id (the
  answer's `runtime_session`; `forked_from` names the original) and runs **read-only**, in
  Claude's plan mode rather than the unattended posture: it shares the original's worktree, and
  an edit there collides with the original's work. Put the question in `--prompt-file`. A fork
  resumed later, by `--resume`, `bench resume` or `bench restore`, is read-only too. `--arg`
  still adds flags after the posture, so a permission flag there is your explicit override of
  it: do not pass one unless the operator asked. codex and pi refuse `--fork`.
- Claude Code must already trust `--cwd` (a parent directory it trusts counts), or it stops at
  the trust question before it starts.
- codex must already trust `--cwd` itself, or it stops at "Trust this folder?". A trusted parent
  does not count, and `--arg` cannot skip it. `bench sessions` shows the stop as `waiting_for:
  "trust prompt"`. Trusting a folder is the operator's call: ask him to run `cd <dir> && codex`
  once, or to choose "Trust and continue" in the spawned pane.
- `bench status` shows which `claude`, `codex` and `pi` a spawn runs (`agents`: path, the file it
  links to, version). That is benchd's `PATH`, not yours, so it can differ from `codex --version`
  in your shell.
- **A quiet agent may be blocked on a prompt no flag removes.** Claude Code keeps some guardrails
  under any posture, a dangerous `rm` among them (#283). Do not reach for a new flag: read its
  state with `bench sessions --all` (the `bench-sessions` skill) or watch its pane.

## Tidy up, move and name

```bash
BENCH="${BENCH:-bench}"
SLOT=$("$BENCH" get pane "$PANE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["slot"])')
"$BENCH" move "$PANE" --beside "$SLOT" --side right
"$BENCH" name "$PANE" "review of the plan"
"$BENCH" close "$PANE"
```

- `bench show <pane>` makes it its slot's visible tab, in a slot he is not typing in.
  `bench focus <pane> --asked` also gives it the keyboard.
- `bench move` puts a pane anywhere a drag in helm can, one destination at a time:
  - `bench move <pane> <left|right|up|down>`: one step, the way his move keys go.
  - `--tab <slot> [--before <pane>]`: into that slot as a tab, before the pane named or last.
  - `--beside <slot> --side <left|right|up|down>`: a slot of its own above or below that slot,
    or a column left or right of its column. Against the pane's own slot, a tab becomes a pane.
  - `--workspace <path>`: into that workspace, as a tab of its focused slot. A workspace's last
    pane cannot leave it, and a workspace already showing that file (or the browser) refuses it:
    `bench show` the pane it names instead.
- `bench split <right|down>` opens a new column or row. A split still halves the column he is in;
  that is a layout change, not a focus change. Moving the pane that holds his keyboard needs
  `--asked`.
- `bench name` names a pane nobody has named, or one only the bench named. A name he chose needs
  `--rename`, which says he asked.
- `bench close` closes a canvas or the browser outright, and a shell sitting at its prompt. A
  terminal where something runs needs `--force`, because closing it ends what runs there: a
  spawned agent's session, or the command a shell is running (the refusal names it). The pane
  holding his keyboard also needs `--asked`, and a workspace's last pane is never closed. Closing
  a canvas destroys nothing: the file and his notes beside it stay.
- A benchd restart ends every session. The panes stay; `just resume-all` (`bench restore --all`)
  gives each a session again: the agent recorded there resumed (claude, codex or pi, recorded from
  its own hook), else a shell in the directory the pane's shell was last working in.

## See what he sees

```text
bench get screenshot [--out <file.png>] [--window <title substring>]
```

helm draws its own window into a PNG, with no display grant and with the screen locked, and
benchd writes it: at `--out`, or under the bench root's `captures/` when you name none, on
benchd's machine even when helm is on another. The answer is helm's report with `path`: read `terminalContent` (`included`, `excluded`, `partial`, `absent`)
rather than assuming terminals are in the picture, and `windowVisible: false` means web content
may be blank. With two helms running, `--window` names one. No helm following this bench is exit 4
after ten seconds, naming the cause.

## Read and type into any terminal

```bash
BENCH="${BENCH:-bench}"
SHELL_PANE=$("$BENCH" open terminal | python3 -c 'import json,sys; print(json.load(sys.stdin)["pane"])')
"$BENCH" send "$SHELL_PANE" 'echo ready' --enter
for _ in 1 2 3 4 5 6 7 8 9 10; do
  "$BENCH" get screen "$SHELL_PANE" | grep -q '"ready"' && break
  sleep 0.5
done
"$BENCH" get screen "$SHELL_PANE" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["lines"]).rstrip())'
```

Every terminal pane is a benchd session, so any of them can be read and typed into by pane id or
session id: his shells, a spawned agent's pane, one you opened.

- `bench get screen <pane|session>` answers what his Ghostty shows there: `lines` (one per row),
  `cursor` as `[column, row]`, `title`, `pwd`, `alt_screen` (a full-screen program is running)
  and `bracketed_paste`. It waits for a frame the program has finished drawing, at most a
  second. `--history` puts the rows above the screen first.
- `bench send <pane|session> <text> --enter` types the text as one paste (bracketed when the
  program asked for that), then Return on its own. Without `--enter` it only types. The log
  records who sent how many bytes, never the text.
- `bench watch screen <pane|session>` prints one JSON line, the same shape, each time the screen
  changes, at most ten a second and never from inside a frame being drawn. It runs until the
  session ends or you stop it.
- Typing into his shell is typing at his prompt. Do it when he asked, or into a pane you opened.
