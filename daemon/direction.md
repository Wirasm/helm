# direction — the bench daemon

An entry point, not a spec — the same posture as helm's `docs/direction.md`. The full
argument lives in `../docs/future-planning/workbench-audit-2026-08.md`; the milestone
sequence in `../docs/future-planning/bench-roadmap.md`. This file is what a session that
just opened `daemon/` needs to hold in its head.

## What this is

`benchd` is the headless Rust daemon helm grows into: it will own everything that must
survive — ptys, VT state, the workbench document, mail, tasks, the attention queue, the
event log — while the SwiftUI app thins into a face that renders daemon state. The
operator and the agents are equal owners; every verb exists in an addressed, non-seizing
form; both parties go through the same socket. Migration is strangler-style inside this
repo: one vertical at a time, old code unwired only when the new is proven.

**Where it stands: M0 + M5a + mail + the shared browser + the bench document's daemon half.** The daemon owns the mailroom (`bench-mail`:
files are the record, notices carry the path never the body, retire-never-delete,
metadata-only listings) and delivery by the recipient's own state (#358, below): nothing is
typed into a pty, and the loop cap is a per-recipient token bucket on the turns benchd starts —
where helm #320 proved it must live.

**Plus the shared browser (#350).** `browser/start|status|stop|setup`: the daemon starts
one browser per root — Google Chrome where installed (the operator's ruling: it runs the
Claude in Chrome and Codex extensions), else Playwright's Chrome for Testing;
`browser/config.json` swaps binary or flags — headless, persistent profile under
`<root>/browser/profile`, debugging port chosen by Chrome and read back from
`DevToolsActivePort`, endpoint published in `<root>/browser/endpoint.json`. `setup` opens
the same profile in a plain Chrome window for installing extensions and signing in: no
user-agent override, no debugging port, because Google refuses sign-in to a browser that
has them (#374). Quitting it returns to headless. The daemon never automates the browser: agents attach with
`playwright-cli attach --cdp=<cdp>`, and helm's pane asks `browser/connect`, after which benchd
carries the pane's CDP messages to the browser's websocket on its own machine, one JSON line each
way (`benchd/src/cdp.rs`, M5c). A crash is
restarted (at most 3 in 60s, then `browser/gave-up`), and the browser runs on a pipe
leash so it dies with the daemon even under SIGKILL. `just browser-proof` is the live check.

**And it runs at login (#407).** `just benchd-install` (root justfile) loads benchd as a user
LaunchAgent, `com.wirasm.benchd`: started at login, restarted by launchd after a crash or a kill,
left down after a clean `bench stop`, output in `~/Library/Logs/benchd.log`. benchd decides
whether the browser comes back: `<root>/browser/wanted` is written when a browser starts and
removed only by `browser/stop`, so a daemon that boots and finds it logs `browser/resuming` and
starts the browser again. Only the live instance is installed; `just launchd-proof` bootstraps a
suite-labelled agent from a temp plist, kills benchd with `-9`, requires both to come back, and
boots it out.

**And the bench document (M4, #354), daemon side.** `bench-doc` is helm's `Workbench` —
workspaces, columns, slots, panes, typed surfaces, placement as data — and benchd serves it:
the layout verbs (`workspace/*`, `pane/*`, `focus/*`, `layout/resize`, `drawer/toggle`, `drawer/place`,
`bench/get`), each logged as one `bench/changed` event that says who asked; `bench.json` as the
record it boots from; and `events --follow`, one line per event with the whole document attached when it
changed. The focus rule is the document's own: an agent's verb that would move the operator's
focus is refused unless it says `asked`. helm is its client and keeps no bench of its own: every
key and click is a verb, as is every agent's `bench` call, and helm draws the document it gets back. `just
bench-proof` drives a whole session through the socket and across a restart.

**Drawers are in the document (#356).** A drawer is a named holder of tabbed panes beside the
workspaces, shown over the bench rather than in it; one is open at a time. `drawer/toggle` opens
or closes one, and `pane/open` takes a `drawer` to put a pane in one. Which drawer is open is the
operator's focus, so an agent's toggle is refused without `asked`, and an agent's pane badges the
drawer instead of opening it. No drawer operation touches a workspace. `bench.json` is version 1
from here, so an older benchd quarantines it rather than dropping drawers on its next save.

**Where a drawer sits is in the document too (#178).** `drawer/place {drawer, edge}` puts a
drawer against the left, right or bottom edge; helm sends it when the operator drags the drawer
by its header. The document keeps `drawer_edges` by name, so the edge outlives the drawer, which
goes with its last pane. It moves no focus, so the document's focus guard would let it through;
`place_drawer` refuses an agent without `asked` itself. A drawer with no edge is drawn where
helm's keymap file (`[drawer.<name>] edge`) or its built-in table says, and the size is always
helm's. The record stays version 1: an older benchd reads the document and drops only the edges.

**A drop names its place (#178).** `pane/move`'s `to` is a step (the keyboard) or a place named by
ids, `{tab: {slot, before?}}` or `{beside: {slot, side}}` (a dragged tab); `pane/open` takes the
same place as `at` (a file dropped from Finder). Like a drawer, a place is outright and the rules
are not asked; a surface that bench already shows is moved there rather than opened twice. helm
works out which place the pointer means, and benchd what a move or an open there does.

**Placement is the operator's file (#356).** Where a new pane goes is a table, and the table is
TOML: the built-in one is `crates/bench-doc/rules/placement.default.toml`, embedded at build
time, and `<root>/rules/placement.toml` replaces it whole. benchd reads the file before each
`pane/open` and each `status` and adopts it only when its text changed, so an edit applies to
the next open with no restart and no watcher. A strategy can send a pane to a drawer
(`{ drawer = "browser" }`). A file that cannot be read, or holds no rules, changes nothing: the
last good table stays in force, `rules/rejected` names the file and why (with the line, for a
parse error) once per version, and `bench status` reports `rejected` until a good version
replaces it. Only a file that is gone means the built-in table. benchd never writes a rules
file. benchd never reads a key: helm's keymap is helm's own file (`~/.helm/bench/keymap.toml`).

**The just layer is two verbs: `just/run` (#356) runs a recipe, `just/list` (#500) names them.** A recipe from `<root>/rules/justfile` is a
composition of `bench` verbs, and benchd runs it rather than helm, so it is logged and dies with
the daemon: `just --justfile <root>/rules/justfile --working-directory <cwd> <recipe>`, with
`BENCH_DIR` (and `BENCH_SUITE`) pointing every `bench` inside it back here. The operator's run
works at the active workspace and gets `BENCH_ASKED=1`, which makes the CLI send `asked`; an
agent's (`bench just`) works where it was asked from and gets nothing, so its verbs are judged
as the agent's. `just/started` is logged before the answer, which does not wait; a reaper logs
`just/finished` with the exit code; output goes to `<root>/just/<run>.log`. The child is on the
browser's pipe leash. A name outside `[A-Za-z0-9_-]`, a missing justfile or a missing `just`
(looked for on `PATH`, then Homebrew's two prefixes) is refused by name. `just/list` answers
`just --summary --unsorted` filtered to names `just/run` accepts, which is every public recipe (a
private `_name` can still be bound to a key but is not offered); no justfile is an empty list,
since the palette asks every time it opens, and nothing is logged. A `just` that cannot start is
an error, as for `just/run`; a justfile it cannot parse is refused.

**And the session list (#384), daemon side.** `bench sessions --all` answers, per workspace,
every agent session helm or benchd hosts: agents in helm panes (matched by pid: the foreground
process of the session each terminal pane in the document shows, or by the pane their own hooks
report), benchd's own sessions, Claude Code `--bg` jobs, running subagents, and finished
sessions — the last only from `sessions/hosted.json`, benchd's record of what it and helm
hosted, because no harness file says where a session ran. `bench sessions dismiss` hides a
finished row. helm's drawer is the next step.

**And the sensor (#358, first half of M2 finish).** `bench hook <claude|codex|pi>` is one
command wired into an agent's own hooks. On every event it reports the agent's state over the
socket (the `hook` verb), and the reply carries the agent's unread mail as pointer lines, which
Claude and codex put in front of the model as hook context: a busy agent gets its mail at the
next tool call, with nothing typed into a pty. The first event of a session helm or benchd
declared (`HELM_PANE`, `BENCH_SESSION`) and that runs on a terminal claims its address, recorded
in `sessions/hosted.json` so it survives a restart. A session resumed in another pane keeps its
handle, and its record moves to the pane it reports from under the same rule (`mail/moved`); one
resumed outside helm keeps its handle and mail, and its old pane stops answering for it. An
idle agent is started through its own channel instead: benchd posts the notice to a Claude
session's inbox socket (which its hooks
report), and a push that starts no turn in 10 s goes back to the inbox. A spawn hands its prompt
over in argv as a pointer, so nothing waits for a TUI to draw. pi's channel is its `bench` extension
(`pi/extensions/bench`), which in pi's TUI reports through `bench hook pi`, watches the inbox benchd names
and starts its own turn when benchd agrees. An agent the operator starts himself
reports once its harness is wired to the one fixed command: `bench wiring` prints what to add
to the three files and `bench wiring --check` says what is missing. For codex that includes
trust: codex runs a hook only once the operator has trusted it ("Hooks need review" at startup,
"Trust all and continue"), so `--check` asks the `codex` on PATH (`hooks/list` on a stdio
app-server of its own) and names each event codex will run no bench hook for: untrusted or
changed since trusted, disabled, or not listed at all. codex 0.159.3 saves the trust a
`codex -p <name>` session accepts in `~/.codex/<name>.config.toml`, which `hooks/list` never reads
and which covers only that profile, so the trust step is plain `codex`; `--check` names a profile
that trusts the current hooks (`trusted_only_under_profile`). Every codex benchd starts is a
thread on one codex app-server benchd runs for its root (#466): started on first use with a
scrubbed environment, leashed like a `just` run so it ends with benchd, at `<root>/codex.sock`.
benchd creates each thread itself (`thread/start`, `thread/fork`, `thread/resume`) with the
agent's cwd, model, effort and posture, and its environment (`BENCH_SESSION`, `BENCH_HANDLE`,
`BENCH_DIR`) as the thread's `shell_environment_policy`, sends its first message as a turn (a
TUI cannot attach to a thread with no turn yet), and the pane runs `codex resume <thread>
--remote unix://<root>/codex.sock`. codex runs every hook with the server's environment, so a
hook names its agent only by its thread, and benchd knows every thread it made. benchd holds one
connection to the server, the one that made every thread, so codex sends it every thread's
status; mail wakes an idle codex with `turn/start` there, and a turn that ends without a `Stop`
(a usage limit) is seen in its `thread/status/changed`. A TUI that resumes against a remote
server reviews hooks at startup whatever `--dangerously-bypass-hook-trust` says, so the server
starts with the trust: benchd asks `hooks/list` which hooks need review and passes their current
hashes as a `-c hooks.state=…` override, the form codex's own `/hooks` saves, without saving it;
each thread itself runs its hooks with `bypass_hook_trust`. The TUI gets no `-C`: against a
remote server it would ask "Trust this folder?" for any folder without its own exact entry, a
worktree of a trusted repository included. Trust stays the operator's call: benchd refuses a
codex in a folder plain codex would have asked about (its own `[projects]` entry, else its git
main repository's). Two limits follow: `/new` in a benchd codex pane starts a thread in the
server's directory that no session owns, so spawn a new agent instead; and the hook trust is
computed when the server starts, so a `hooks.json` changed later shows "Hooks need review" until
benchd restarts. A codex the operator starts himself runs on codex's own app-server, so its mail
waits for its next prompt or tool call. `just mail-ring` is the proof: claude, codex and pi pass a number around through
benchd, idle and busy, with per-hop latency from the log. helm
keeps no mailroom of its own since: it asks benchd who is in a pane (`mail/who`) and sends a
canvas note through `mail/send`.

**Plus each plan's limits (#143).** benchd holds how close the operator's Claude and codex
plans are to their limits, as each harness publishes it on benchd's machine, and answers it as
`usage` in `sessions`, which helm shows as one status-bar capsule. Nothing asks a provider and
nothing holds a credential. codex writes `rate_limits` into its rollout, which every hook payload
names (`transcript_path`), so `bench hook codex` reads the newest record of the plan's own limit
(`limit_id: codex`; per-model limits are not the plan) on `SessionStart`, `PostToolUse` and `Stop`.
Claude Code publishes `rate_limits` only to its statusline command (no hook payload carries it,
measured on 2.1.286), so `bench statusline [command...]` is that command: it runs the operator's
own statusline on the same input, prints what it prints, and sends `usage/report`. **That is a
one-line change the operator makes himself**, and nothing here makes it for him:

```json
"statusLine": { "type": "command", "command": "<bench> statusline ~/.claude/statusline.py" }
```

with `<bench>` the absolute path `bench wiring` prints (it prints this line too, and `--check`
reports `statusline_reports_limits` without making it a requirement). Leave `refreshInterval` unset: the payload
carries no fetch time, so each run is stamped when it ran, and a timer would keep restamping an idle
session's figure as current. benchd keeps one figure per harness and window, merged so that a
window that resets later wins and, within one window, the higher reading wins (usage in a window
only rises), and a held window that had already reset gives way to any later report. An idle session repeating an old figure, or a resumed codex session's old record,
never replaces a newer one; two accounts on one benchd are not told apart. It is memory only: a
restarted benchd shows nothing until the next turn reports. helm greys a figure older than 15
minutes and drops a window whose reset time has passed.

**And the wire front (M3, #355): `bench` is the agent's whole surface.** The CLI speaks the
pane verbs — `open`, `split`, `show`, `focus`, `move`, `name`, `close <pane>`, `get pane` — and
`workspace close <path>` as the socket's own layout verbs, carrying who asked (`HELM_PANE`,
`BENCH_HANDLE`) and `asked` only from `--asked`. benchd adds the rules the spool kept at the verb
boundary: an agent's close of a terminal where something runs needs `force` (the refusal names the
live session, or the job a shell is running), and so does its close of a workspace holding such a
pane (#608), a chosen name needs `rename`, and an agent's pane opens in its own workspace. `spawn`
now puts the agent in a pane: the document's terminal surface names the session
(`term:<session>`), and helm shows it by running `bench attach` in that pane, which follows the
pane's size and ends when the session does. After the attach answer the viewer's side of the
stream is framed (`bench_wire::attach`): keys and sizes in one ordered stream, sizes coalesced to
one per 16 ms plus a trailing one, because each is a SIGWINCH and a redraw (M5b, #359). No session outlives its daemon, so boot
clears every pane's `session` (`bench/sessions-ended`).

**Every terminal pane is a session (M5b, #359).** Where every change is committed
(`layout::commit`), a terminal pane that is new and names no session gets the operator's login
shell (`shells.rs`), with the environment helm's panes gave their shells and Ghostty's shell
integration built in (`shell_env.rs`); and a session no pane shows any more ends. After a restart
the panes keep their records, and `restore` (`bench restore --all`, `just resume-all`) gives
each a session again from that record alone: the agent's conversation resumed, else a shell in the
pane's last directory. Every resume benchd starts (`restore`, `bench resume`, `spawn --resume` with
no prompt) sends the agent a fresh notice as its first message (`spawn::wire`): its last turn was
interrupted, carry on and re-arm what it had running. It never sends an earlier spawn's prompt.
Each of them asks `resume_dir::start` where the conversation runs first (#621): a folder that is
gone (the merge queue prunes a worktree after its merge) comes back as a worktree on the local
branch the harness last recorded, when git ignores that folder (`.worktrees/`) and its parent is
still there; else a claude or codex starts in the repository root, and the notice
says which; pi re-enters a conversation only where it ran, so its resume is refused instead. The
sessions drawer resumes a finished row through `spawn --resume` for the same reason. None of
them re-enters a conversation a live process holds, since two processes on one conversation fork
it (`restore::holder`): a benchd session, an agent whose hook reported since benchd started, or a
claude anywhere by Claude's registry (`~/.claude/sessions/<pid>.json`), which is what catches one
in another terminal after a restart. codex refuses a thread another process writes by itself; pi
records no holder, so a pi outside benchd is seen only once its hook reports. `restore` gives that
pane a shell that says why, `spawn --resume` and `bench resume` refuse. benchd writes both: which agent is in a pane from that agent's own hook
(claude, codex and pi alike; cleared at its `SessionEnd`, except while benchd itself is stopping),
and the shell's directory read off its process (`Surface::Terminal::cwd`). Sessions do not outlive benchd: ruled 2026-09-27, resume instead.

**The terminal state is benchd's (M5b PR 4).** Each session runs libghostty-vt, built from the
Ghostty commit helm's GhosttyKit is (`bench-vt`, archives vendored per target in
`daemon/vendor/libghostty-vt/`), on a thread of its own (`bench-session/src/engine.rs`) that sees
every byte before the viewer does. A viewer that attaches is shown the screen formatted as the
sequences that redraw it, plus any sequence the program left half-written; the terminal queries
in its history are not replayed into the new Ghostty. While no viewer is attached the engine
answers queries as Ghostty would; while one is, the viewer's Ghostty does. An attach or a screen
read inside a synchronized update (mode 2026) waits for it to end, at most a second. The same
engine answers `screen/get` and takes `screen/send`, so an agent reads and types into any
terminal (`bench get screen`, `bench watch screen`, `bench send`). What only helm can do — drawing its window
— benchd asks for: `helm/ask` logs `helm/asked` to the followers, helm answers with `helm/answer`,
and the caller waits at most `HELM_ASK_WAIT`. A capture's PNG comes back in the answer and benchd
writes the file, since helm may be on another machine. The `bench-panes` skill is the agent's guide.

**A benchd by address (M5c, #459, first slice).** `BENCH_LISTEN=<host>:<port>` makes benchd
listen on TCP beside its unix socket, and each connection goes to the same handler: the protocol
is bytes on a stream and reads no peer credentials. `BENCH_URL=tcp://<host>:<port>` points
`bench` and helm at it instead of `<root>/benchd.sock` (`bench_wire::Endpoint`, helm's
`BenchEndpoint`, one table for both in `fixtures/bench-url.json`); unset or empty is the socket.
Both clients set `TCP_NODELAY` and a short keepalive, so a link that died in a sleep is noticed
in seconds. There is no auth: bind a tailnet address, never a public one. With `BENCH_URL` set
helm runs its own `bench` for a pane, since the one `status` names is on benchd's machine. And
`bench attach --in-pane` no longer reads "no answer" as "the session ended": it says it cannot
reach benchd and asks again with a capped backoff until benchd answers, then attaches and
redraws from benchd's screen, or ends if benchd says the session did. That holds on one machine
too, across a benchd restart.

**A canvas's files are benchd's too (M5c, second slice).** helm reads, writes and appends a
canvas's files only through `file/read`, `file/write` and `file/append` (`bench_wire::files`,
pinned by `fixtures/file-verbs.json`), and hears that one changed from `file/changed`: a thread
(`benchd/src/files.rs`) stats every canvas file in the document and its notes sidecar every
100 ms and reports a path once its size, time or inode moved and then held still for one look.
A path it has just started watching is reported once too, so a write between helm's read at
open and benchd's first look, or made while benchd was down, still reaches the pane; and helm
reads every open canvas again whenever its follower connects.
The verbs carry the canvas's rules, because benchd is the side with the disk: a sibling read is
confined to the page's folder with symlinks followed, `file/write` compares against the bytes the
writer names (`unchanged`) and answers `changed` with what is there instead of writing, and a
`.notes.md` sidecar is never written whole. Their text is never logged, so `file/write` and
`file/append` get a 16 MiB request line where every other verb keeps 64 KB.

**And the drawers' git and archon (M5c, third slice).** helm runs no `git` or `archon` and reads
no repository itself: the Worktrees drawer, the Archon drawer and each workspace tab's branch ask
benchd through three verbs (`bench_wire::commands`, pinned by `fixtures/command-verbs.json`,
`benchd/src/commands.rs`). `command/run` runs `git` or `archon` on this machine and answers the
exit status and both streams, base64, or `timed_out` past the caller's deadline; a nonzero exit is
an answer, since helm's delete rules read git's "no" (`merge-base --is-ancestor`). The program is
a tagged enum rather than an argv because benchd resolves each here: `archon` from its own
`~/.bun/bin`, which also goes first on the child's `PATH`, with `ARCHON_HOME` when asked. Output
goes to unlinked files, never pipes, so a `--detach` run's background child cannot hold the
answer. `path/exists` answers which paths exist and refuses rather than say "absent" when it
could not look, because helm prunes a worktree it reads as missing. `git/repositories` is the
drawer's discovery walk over benchd's `HOME`. **`command/run` is not a boundary**: `git -c
alias.x='!cmd' x` runs anything, so the verb is a shell for whoever reaches the socket, as
`spawn` and `just/run` already are. The socket and the tailnet are the boundary. helm keeps all
of its git and Archon logic and moves only the process, so what a delete checks is unchanged.

**Nothing crosses the link by file (M5c, third slice).** benchd no longer reads helm's
`snapshot.json`: the session list places a pane's agent by the foreground process of the session
the pane shows and the agent recorded on the pane, both benchd's own. The other way, `sessions`
carries `report` for each session, what its agent says it is doing (`bench_wire::AgentReport`):
Claude Code's registry row for the foreground process, read from benchd's HOME, else the agent's
last hook. helm's presence dots and its snapshot's `agent` read that, and helm reads no registry.
`bench open <file>` makes the path absolute and checks the extension on the caller's side;
whether the file exists benchd checks on its own disk, since the caller may be on another
machine. `bench --version` prints the version `status.version` answers, and helm compares the two
before a pane runs helm's own `bench` against a benchd over TCP.

**And the browser pane and screenshots (M5c).** The pane never reads
`<root>/browser/endpoint.json` or dials the port it names: `browser/connect` opens the browser's
websocket from benchd and relays CDP messages as lines on the pane's own connection, with nothing
of what they say logged (only `browser/viewer-connected` and `browser/viewer-left`). A message is
JSON, which holds a raw newline only as whitespace, so benchd turns one into a space. And helm
answers a capture with the PNG itself (`png`, base64); benchd writes it where the caller asked, or
under its own `captures/`, and hands back helm's report with `path` in its place, so `helm/answer`
gets the 16 MiB line too. Both are the route on one machine as well.

**And prp's stores and the paths the operator types (M5c).** `~/.prp` lives on the agents'
machine, so helm asks benchd about it (`bench_wire::prp`, pinned by `fixtures/prp-verbs.json`).
`prp/note` starts ⌘⇧N's note: benchd runs prp's canonical store resolver in the workspace
(`benchd/src/prp.rs`, a port of the block every prp skill carries, checked by a conformance test
against a verbatim copy of it), registers a store nothing has touched with prp's exact `project.json` bytes,
and creates `notes/<day>-note[-n].md` without overwriting. A git that has not answered within 3 s
(`PRP_RESOLVE_WAIT`, for the whole resolve) is a refusal, never a fallback to the folder. `prp/stores` and `prp/artifacts` are the artifact
browser's listing, and the workspace's store is the resolver's answer, so a worktree finds its
main checkout's. `path/resolve` turns what the operator typed into benchd's absolute path, `~`
expanded against benchd's `HOME`, and says whether a file or a folder is there: ⇧⌘O and the
browser's path field use it where helm used Finder's panel.

**And a canvas's live file (helm #532).** An HTML canvas has one JSON file beside it,
`<stem>.data.json` (`bench_wire::live_file`), that the page and an agent both edit, and every
write to it names the bytes its writer saw: `file/write` has no blind kind any more, so `unchanged`
is the only one. The page writes through helm; an agent through `bench file write <path> --expect
<file>` (and reads with `bench file read`), where exit 3 means somebody wrote since. The watcher
covers the live file of each canvas, so helm offers an agent's write to the page. A page's write
says `notify`, and benchd mails the canvas's opener itself (`benchd/src/live.rs`): the opener is
on the pane in the document (`Pane::opener`, written from an agent's `pane/open`, newest wins), so
the route needs no helm and survives its relaunch. Mail is batched per file for a second, names the
changed JSON pointers and nothing else, comes from `operator`, and a mail that cannot go is logged
as `live/unmailed` with why.

The same open copies the conversation the opener's pane holds onto the canvas pane as `author`
(helm #535). Mail stays late-bound to whoever is in the pane; a fork is bound to the conversation
that wrote the file, which a `/clear`, a restart or an exit in that pane would otherwise lose. helm's
"Ask a fork" sends `spawn` with `fork: author.session` and the prompt as text (`prompt`), which
benchd writes under `<root>/prompts/` because helm may not share its disk.

**And benchd sees an agent waiting on the operator (M1, #357).** #283's failure was an agent parked
at a prompt its hooks never reported, and nobody knew for hours. Each session's engine says when
its output settles (500 ms of quiet, or 2 s into output that never stops: at a real permission
prompt Claude Code kept writing ~100 bytes a second and codex ~65), and benchd then reads the
screen and matches the prompt rules (`crates/benchd/src/prompts.rs`), each pinned by a screen
captured from the real CLI in `crates/benchd/screens/`. A shell at its prompt is never read. The
agent's own report outranks its screen: a hook that says it is waiting keeps its words, and a
report newer than the screen reading says the prompt is gone; a screen match wins only over an
older report (`busy` at the tool call, then a prompt, then nothing). A Claude wait ended by Esc,
which fires no hook, is reconciled against Claude's registry, and at each settle benchd also reads
the registry row of the session's foreground process: a `waiting` there is Claude's own report,
taken before the screen, so a Claude whose hooks are not wired is still seen waiting in its own
words. The one answer per session is `waiting` in `sessions`, and a running row in `sessions/all`
says `waiting` with it; `session/waiting` logs each change the screen shows. `focus/waiting` is the
operator's jump (helm's ⌘⇧J) over everything that needs him: asking, then a finished turn of his he
has not seen, then mail to him, the oldest first in each, the one after the focused pane on each
press, round again (a finished turn leaves the list as he arrives, and the walk goes on from its
place); it moves his focus, so an agent needs `asked`.

**And what else needs someone: a finished turn, and mail to the operator (M1, #357).** Each session
in `sessions` and each running row in `sessions/all` also carries `done` when its agent's turn
ended (a typed signal: Claude's and codex's `Stop`, pi's `agent_settled`; never the last message
read as prose) and it has not started another, and `operator_mail` when its mailbox sent the
operator mail he has not read. `done.to` is whose it is: the agent that spawned it (benchd resolves
the spawner from who asked: `BENCH_HANDLE`, else the mailbox in the asking pane; a `--resume` by
another agent makes it that agent's), or `operator`; each `sessions/all` row also names its
`spawner`, tagged `operator` or `agent`, `null` when unrecorded. Waiting is always his. `done.seen`
turns true when focus arrives at its pane, when the turn ends in the focused pane, or on
`sessions/seen` (his, or an agent's he asked); nothing else clears it, and nothing closes: a mark
never closes a pane, ends a session or removes a worktree. The only state is three fields on the
conversation's hosted-sessions entry (`spawner`, `turn_ended_ms`, `seen_ms`), so an unseen finish
survives a restart; the rest is projected at answer time. `bench watch <handle>` is the agents'
wait: it follows benchd's events client-side (`events --follow`) and reads `sessions` when one is
about that agent and once a second besides (Claude's registry row can change with no hook, as on
Esc), judging work and idle from that report alone, until the agent waits, finishes a turn (after
`--after`), goes idle without finishing one after the watch saw it working (a failed or interrupted
turn, which ends with no `Stop`), or its session ends, with no model turn spent; an idle report
counts only when it is newer than the work it follows, so a report with no time waits for the
timeout.

**Where it stood before mail: M0 + M5a.** A suite-aware record root, an append-only event log, one
unix socket, eight verbs, a CLI speaking helm's exit-code discipline, and a conformance
gate that runs the real binaries. M5a is the pty core: `spawn` puts a real interactive
agent (claude, codex, pi — the allowlist) into a daemon-owned pty with posture, model
and effort flags spelled once in `bench-session`, prompt by file, runtime session id
minted at spawn; `attach` is a dtach-grade raw relay with ring replay and Ctrl-\ detach;
`close` is drain-then-die; `resume` re-enters an exited session where the runtime mints
its id (claude, pi — codex refuses with the reason). Nothing helm does today is owned
here yet; mail is next, waking agents by pasting into ptys this daemon now owns.

## The spine

Three commitments, made now, that every later milestone builds on rather than beside:

**1. Bench-visible means logged.** The append-only event log (`events.jsonl` under the
record root) is the single source of truth. Every mutation appends its event *before*
the response that reports it; snapshots, queues, and "what happened overnight" are
projections of the stream, never a second store. helm's `snapshot.json` becomes a
projection at M4; the silent parked-workspace canvas drop (found 2026-08-17) is the
class of bug this rule deletes — an offer in the log with no consumer is a visible fact,
not a `return` in a guard.

**2. One door.** The socket is the only way in. The CLI, the face, every agent, and the
operator's own keystrokes (from M4) use the same verbs through the same gateway — so
"equal owners" is mechanically true, not aspirational, and there is no privileged
in-process path for a capability to grow attached to. helm accreted six spool kinds, an
OSC push channel, mail hooks in two runtimes, and a snapshot file — each individually
argued, collectively sixteen ropes and no spine. The seventh capability here is a verb
and an event kind, not a new channel.

**3. One spelling of every shared rule.** `bench-wire` holds the wire types AND the
resolution rules (suite names, record roots, request ids, caps). Both binaries compile
against it, so they cannot drift; anything outside the workspace that later needs these
types — the Swift face — gets a generated copy or a conformance-pinned duplicate under
the repo's honest-duplicate rule, never a hand-written one.

## Learned from the field, on purpose

DeepSeek Harness (dsh, studied 2026-08-17 — canvas in the helm prp store) is the most
complete existing implementation of a log-first agent daemon, and three of its ideas are
adopted here deliberately:

- **The logged-envelope invariant.** dsh logs the full model request before dispatch, so
  every request is a pure function of the log, and an independent checker rebuilds and
  compares. Ours is the bench-shaped analog: every response's claim must be derivable
  from the record — `stop` is logged before it is answered, and the conformance suite
  reads the file, not the daemon, to verify history.
- **Caps are reported, never silent.** dsh documents every truncation; `events` returns
  `total`/`returned`/`truncated` from day one, because a capped read that looks complete
  is how "covered everything" gets believed.
- **Refusals name the route.** helm's spool refusals already point at the tool to use
  instead; dsh's tool errors are typed and self-describing. Every refusal here names the
  rule it applied and, where one exists, what to do about it.

And one of dsh's ideas is **rejected** with equal deliberation: the plugin kernel.
benchd serves one operator whose gate is the pull request; composability-as-product
(profiles, patch layers, realm isolation) is generality this estate does not need and a
complexity bill dsh's own five-day-old ecosystem is already paying. Capabilities land as
code in this workspace, reviewed, behind the one door.

## Posture: the agents are smart

Adopted 2026-08-18, the operator's words made a rule. **We expose capabilities; we do
not parse prose.** Nothing in the bench regexes, keyword-matches, or otherwise
reconstructs meaning from human- or agent-written text — a reply is read by an agent,
not by a parser. Interpretation belongs to the model; determinism belongs at the tool
boundary (validated verbs, newtypes, exit codes), which is where `SuiteName` and
`RequestId` already sit. Concretely: the daemon never parses a mail body; notices point
rather than quote; status comes from taps — the runtimes' own typed hook and event
channels — and a capability that seems to need output-scraping is a missing tap or a
missing verb, not a regex waiting to be written. The one deliberate exception the
roadmap names: a last-resort output-classification fallback for a runtime with no tap
at all (M1, codex) — status inference only, never intent, retired the day the tap
exists. The spike harnesses' READY/NOOP markers were test instrumentation, not a
pattern to copy into the product.

## Rules that bind every milestone

The checklist form is bench-roadmap.md's invariants; the ones already load-bearing in
this workspace:

- **Suites isolate or refuse.** `BENCH_SUITE=<name>` moves socket, root, and every byte
  of state; a name that cannot isolate stops the launch — never a fallback to the
  operator's live `~/.bench` (helm #86/#285, ported as `SuiteName`).
- **Files are the record.** Everything persistent is a file a plain `cat` can read;
  sockets are transport, never the only copy.
- **Exit codes are the contract**: 0 ok · 2 no daemon · 3 refused · 4 daemon failed —
  helm's spool codes, kept, because every agent skill in this repo already reads them.
- **Validated newtypes at the edges** (`SuiteName`, `RequestId`), with the standing
  carve-out: a request is decoded permissively in shape and judged strictly afterwards,
  so malformed input earns a refusal naming the reason, not a dropped connection.
- **No orchestrator concept, ever** — no role, rank, or team field in the daemon, the
  wire, or the CLI (roadmap invariant 2). Hierarchy is prompts and skills, run *on* the
  bench.
- **Conformance over trust**: every wire contract gets a test that runs the real binary
  as a subprocess and checks both directions, every status case.

## How it grows

Landed: M0 skeleton, M5a daemon ptys, mail, the shared browser (#350), and M4 (the bench
document in benchd, and helm as its only client: #354). Next, in order (tracking issue #362):
M2 finish, one mailroom (helm's mail hooks become sensors) →
M3 `bench` as the whole agent surface → drawers, keymap and rules → M1 attention → M5b every pane a benchd session
→ M5c helm reaches benchd over the tailnet → M7 the agents' own machine. Each milestone: new event
kinds, new verbs, same spine. The roadmap is the sequence; the operator names the milestone
that starts.
