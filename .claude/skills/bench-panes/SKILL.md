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
  `bench open terminal` opens a shell. `--drawer <name>` puts it in a drawer instead.

## Where is a pane, and can he see it

```bash
BENCH="${BENCH:-bench}"
"$BENCH" get pane "$PANE"
```

The answer has the pane, its `workspace` (or `drawer`), `visible` (on screen now) and `focused`
(holds his keyboard). `bench get` prints the whole bench. Both cover hidden and parked panes.

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
- Claude Code must already trust `--cwd` (a parent directory it trusts counts), or it stops at
  the trust question before it starts.
- **A quiet agent may be blocked on a prompt no flag removes.** Claude Code keeps some guardrails
  under any posture, a dangerous `rm` among them (#283). Do not reach for a new flag: read its
  state with `bench sessions --all` (the `bench-sessions` skill) or watch its pane.

## Tidy up, move and name

```bash
BENCH="${BENCH:-bench}"
"$BENCH" name "$PANE" "review of the plan"
"$BENCH" close "$PANE"
```

- `bench show <pane>` makes it its slot's visible tab, in a slot he is not typing in.
  `bench focus <pane> --asked` also gives it the keyboard.
- `bench move <pane> <left|right|up|down>` and `bench split <right|down>` rearrange around him.
  A split still halves the column he is in; that is a layout change, not a focus change.
- `bench name` names a pane nobody has named, or one only the bench named. A name he chose needs
  `--rename`, which says he asked.
- `bench close` closes a canvas or the browser outright. A terminal needs `--force`, because
  closing it ends what runs there: a spawned agent's session ends with its pane. The pane holding
  his keyboard also needs `--asked`, and a workspace's last pane is never closed. Closing a canvas
  destroys nothing: the file and his notes beside it stay.

## See what he sees

```text
bench get screenshot [--out <file.png>] [--window <title substring>]
```

helm draws its own window into a PNG, with no display grant and with the screen locked. The
answer is helm's report: read `terminalContent` (`included`, `excluded`, `partial`, `absent`)
rather than assuming terminals are in the picture, and `windowVisible: false` means web content
may be blank. With two helms running, `--window` names one. No helm following this bench is exit 4
after ten seconds, naming the cause.
