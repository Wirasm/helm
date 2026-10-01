//! bench — the CLI, the one agent-facing surface over the benchd socket (and, at M5a,
//! the operator's attach client).
//!
//! One connection, one JSON request line, one JSON response line — except `attach`,
//! which upgrades the same connection into a raw byte relay after the response: pty
//! output down, keystrokes up, Ctrl-\ to detach. The exit code IS the outcome:
//!
//!   0  ok            (the verb's data, pretty JSON, on stdout; attach: a clean detach)
//!   2  no daemon     (the socket could not be reached, or never answered — transport)
//!   3  refused       (the daemon said no and named why, on stderr)
//!   4  daemon failed (the daemon tried and could not, named why, on stderr)
//!
//! These are helm's spool codes, kept on purpose.

use bench_doc::{DrawerName, Surface};
use bench_wire::{
    Actor, BENCH_URL, CLIENT_READ_TIMEOUT, DAEMON_IO_TIMEOUT, EXIT_NO_DAEMON, Endpoint, Harness,
    HookArgs, HookReply, JustRunArgs, LayoutVerb, MailListArgs, MailReadArgs, MailSendArgs,
    OPERATOR_HANDLE, Request, RequestId, Response, SessionArgs, SessionKey, SessionsArgs, Status,
    SuiteName, resolve_root,
};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

mod attach;
mod files;
mod usage;
mod verbs;

fn main() {
    // `hook` is wired into an agent's own hooks and has its own contract (exit 0, always),
    // so it never reaches the verb parser, whose refusals exit 3.
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let code = match raw.first().map(String::as_str) {
        // What helm compares with benchd's `status.version` before a pane runs this `bench`.
        Some("--version") => {
            println!("{}", bench_wire::VERSION);
            0
        }
        Some("hook") => hook(raw.get(1).map(String::as_str)),
        Some("wiring") => wiring(raw.get(1).map(String::as_str)),
        // Claude Code's `statusLine` command, with the same exit-0-on-our-failure contract.
        Some("statusline") => usage::statusline(&raw[1..]),
        _ if files::owns(&raw) => files::run(&raw),
        _ if verbs::owns(&raw) => verbs::run(&raw),
        _ => run(),
    };
    process::exit(code);
}

fn usage() -> &'static str {
    "usage: bench [--suite <name>] <verb> [args]  (bench --version: this build)\n\
     verbs: status                              daemon identity, root, uptime, counts\n\
     \x20     events [--since N]                  read the record back from seq N\n\
     \x20     events --follow                     the bench document, then one line per event as it\n\
     \x20                                         happens (the document attached when it changed)\n\
     \x20     get                                 the bench document and the seq it reflects\n\
     \x20     stop                                log the stop, kill sessions, exit\n\
     \x20     spawn --agent <a> --cwd <dir>       an agent in a bench pty, shown in a pane of\n\
     \x20           [--name <handle>]             <dir>'s workspace; --resume <id> re-enters a\n\
     \x20           [--prompt-file <p>]           conversation, --fork <id> copies one to run\n\
     \x20           [--model <m>] [--effort <e>]  read-only (a harness that cannot says so),\n\
     \x20           [--resume <id> | --fork <id>] [--arg <flag>]... [--asked]\n\
     \x20                                         --arg adds a flag\n\
     \x20     open <file|browser|terminal>        a pane in your workspace (a .md/.html file is\n\
     \x20           [--workspace <dir> | --drawer <name>] [--asked]      a canvas)\n\
     \x20     split <right|down> [--surface <s>]  a new column or row beside the focused slot\n\
     \x20     show <pane> [--asked]               make it its slot's visible tab\n\
     \x20     focus <pane> --asked                give it the operator's keyboard\n\
     \x20     move <pane> <left|right|up|down>    move a pane on its bench\n\
     \x20     name <pane> <words> [--rename]      name a pane; a chosen name needs --rename\n\
     \x20     close <pane> [--force] [--asked]    close a pane; a terminal needs --force\n\
     \x20     get pane <pane>                     where a pane is, and whether it is seen\n\
     \x20     get screenshot [--out <p.png>]      helm draws its window (helm must follow the\n\
     \x20           [--window <title>]            bench)\n\
     \x20     get screen <pane|session>           a terminal's screen as text, cursor, title and\n\
     \x20           [--history]                   modes, at a finished frame; --history adds the\n\
     \x20                                         rows above it\n\
     \x20     watch screen <pane|session>         one JSON line per change of that screen\n\
     \x20     send <pane|session> <text>          type into a terminal (a bracketed paste when the\n\
     \x20           [--enter]                     program asked for one); --enter adds Return\n\
     \x20     (every pane verb lands in the background; --asked says the operator asked, and\n\
     \x20      only then may it bring something forward or move his focus)\n\
     \x20     sessions                            list bench sessions\n\
     \x20     sessions --all [--workspace <dir>]  every agent session in a workspace (default: the\n\
     \x20                                         cwd's): helm panes, bench sessions, --bg jobs,\n\
     \x20                                         running subagents, and finished hosted sessions\n\
     \x20     sessions dismiss <id> --harness <h> hide a finished row until it finishes again\n\
     \x20     log <session id | transcript path>  a Claude, pi or codex session's prompts, replies,\n\
     \x20         [-n N] [--since 30m|2h|1d|<time>] tool calls and errors, read from its transcript\n\
     \x20         [--json]                        with no daemon; the last 40 unless -n says so\n\
     \x20     attach <session> [--in-pane]        relay to a session's pty (Ctrl-\\ detaches); the\n\
     \x20                                         pty follows this terminal's size. --in-pane:\n\
     \x20                                         what a helm pane runs (quiet, no detach key)\n\
     \x20     restore <pane> | --all              a terminal pane whose session ended gets one:\n\
     \x20                                         its recorded agent resumed, else a shell\n\
     \x20                                         (`just resume-all` after a benchd restart)\n\
     \x20     close <session>                     drain-then-die the session (a pane id closes\n\
     \x20                                         the pane, above)\n\
     \x20     resume <session>                    re-enter an exited session's runtime state\n\
     \x20     file read <path>                    the file's bytes on stdout, exactly\n\
     \x20     file write <path> --expect <f>      stdin over <path>, only if it still holds what\n\
     \x20                                         <f> holds (what you read); exit 3 when it changed\n\
     \x20                                         since. A new file: --expect /dev/null\n\
     \x20     mail send --to <h> --body <text>    deliver mail; a live recipient is woken\n\
     \x20               [--body-file <p>] [--subject <s>] [--from <h>]\n\
     \x20     mail list [--handle <h>]            metadata only, unread first\n\
     \x20     mail read <id> [--handle <h>]       body + retirement (inbox -> read)\n\
     \x20     mail who --pane <uuid>              the mailbox of the agent in a helm pane\n\
     \x20     wiring [--check]                    what to add once so agents you start report to
     \x20                                         benchd; --check says what is missing (exit 3)
     \x20     hook <claude|codex|pi>              the sensor, wired into an agent's own hooks: reads\n\
     \x20                                         the hook payload on stdin, reports it, prints the\n\
     \x20                                         agent's mail as hook context; always exits 0\n\
     \x20     statusline [command...]             Claude Code's statusLine: reports its plan limits\n\
     \x20                                         and runs command (your own statusline) on the\n\
     \x20                                         same input; exits with its status\n\
     \x20     browser start                       start the shared browser, or find it running;\n\
     \x20                                         `cdp` in its answer is for playwright-cli attach\n\
     \x20     browser status                      the endpoint, or running: false\n\
     \x20     browser stop                        stop the shared browser\n\
     \x20     browser setup                       the same profile in a real window, to install\n\
     \x20                                         extensions and sign in; quit it to go headless\n\
     \x20     drawer toggle <name>                show a drawer over the bench, or hide it: the\n\
     \x20           [--surface <s>]               operator's focus, so refused from an agent. <s>\n\
     \x20                                         is what a new drawer starts with: browser,\n\
     \x20                                         sessions, archon, worktrees, terminal or\n\
     \x20                                         file:<path>\n\
     \x20     just <recipe> [args...]             run a recipe from <root>/rules/justfile here;\n\
     \x20                                         answers {run, log}, and just/finished says how\n\
     \x20                                         it ended\n\
     env:   BENCH_SUITE (flag wins) · BENCH_DIR (root override, wins over suite) ·\n\
     \x20     BENCH_URL=tcp://<host>:<port> (a benchd on another machine, started with\n\
     \x20     BENCH_LISTEN; unset, the root's benchd.sock) ·\n\
     \x20     BENCH_ASKED=1 (the operator asked: set by benchd on his own just runs)\n\
     exit:  0 ok · 2 no daemon · 3 refused · 4 daemon failed"
}

struct Cli {
    verb: String,
    args: Value,
    root: PathBuf,
    /// `--asked`: the caller says the operator asked, so the verb may move his focus.
    asked: bool,
}

#[expect(clippy::too_many_lines, reason = "legacy (#418): 250 lines, limit 100")]
fn run() -> i32 {
    let mut argv = std::env::args().skip(1).peekable();
    let mut suite_flag: Option<String> = None;
    let mut verb: Option<String> = None;
    let mut positional: Vec<String> = Vec::new();
    let mut flags: Vec<(String, String)> = Vec::new();
    let mut since: Option<String> = None;
    let mut count: Option<String> = None;
    let mut follow = false;
    let mut all = false;
    let mut json_out = false;
    let mut in_pane = false;

    while let Some(arg) = argv.next() {
        match arg.as_str() {
            "--suite" => match argv.next() {
                Some(v) => suite_flag = Some(v),
                None => return refuse("--suite needs a name"),
            },
            // `events` reads a sequence number here, `log` a duration or a time.
            "--since" => match argv.next() {
                Some(v) => since = Some(v),
                None => return refuse("--since needs a value"),
            },
            "-n" => match argv.next() {
                Some(v) => count = Some(v),
                None => return refuse("-n needs a count"),
            },
            "--json" => json_out = true,
            "--in-pane" => in_pane = true,
            "--follow" => follow = true,
            "--all" => all = true,
            "--to" | "--from" | "--subject" | "--body" | "--body-file" | "--handle"
            | "--workspace" | "--harness" | "--pane" | "--surface" => {
                let key = arg.trim_start_matches("--").replace('-', "_");
                match argv.next() {
                    Some(v) => flags.push((key, v)),
                    None => return refuse(&format!("{arg} needs a value")),
                }
            }
            "--help" | "-h" => {
                println!("{}", usage());
                return 0;
            }
            other if verb.is_none() && !other.starts_with('-') => verb = Some(other.to_string()),
            other if verb.is_some() && !other.starts_with('-') => {
                positional.push(other.to_string())
            }
            other => return refuse(&format!("unknown argument {other:?}\n{}", usage())),
        }
    }

    let Some(mut verb) = verb else {
        return refuse(usage());
    };
    if verb == "mail" {
        if positional.is_empty() {
            return refuse("mail needs a subcommand: send, list, read, who");
        }
        verb = format!("mail/{}", positional.remove(0));
    }
    if verb == "get" {
        verb = "bench/get".into();
    }
    if in_pane && verb != "attach" {
        return refuse("--in-pane is for `attach`");
    }
    if follow && verb != "events" {
        return refuse("--follow is for `events`");
    }
    if all && verb != "sessions" && verb != "restore" {
        return refuse("--all is for `sessions` and `restore`");
    }
    if (json_out || count.is_some()) && verb != "log" {
        return refuse("-n and --json are for `log`");
    }
    if verb == "log" {
        return log(
            positional.first(),
            since.as_deref(),
            count.as_deref(),
            json_out,
        );
    }
    let since: u64 = match since.as_deref().map(str::parse::<u64>) {
        None => 0,
        Some(Ok(n)) => n,
        Some(Err(_)) => return refuse("--since needs a sequence number"),
    };
    if verb == "sessions" && all && !positional.is_empty() {
        return refuse(
            "--all lists sessions; `bench sessions dismiss <id> --harness <h>` takes no --all",
        );
    }
    if verb == "sessions" && all {
        verb = "sessions/all".into();
    } else if verb == "sessions" && positional.first().map(String::as_str) == Some("dismiss") {
        positional.remove(0);
        verb = "sessions/dismiss".into();
    }
    if verb == "just" {
        verb = "just/run".into();
    }
    if verb == "drawer" {
        if positional.is_empty() {
            return refuse("drawer needs a subcommand: toggle");
        }
        verb = format!("drawer/{}", positional.remove(0));
    }
    if verb == "browser" {
        if positional.is_empty() {
            return refuse("browser needs a subcommand: start, status, stop, setup");
        }
        verb = format!("browser/{}", positional.remove(0));
    }

    // Suite validated before any socket is touched — a name that cannot isolate must
    // never resolve to the shared root by accident (#86). One spelling, two edges.
    let root = match record_root(suite_flag) {
        Ok(root) => root,
        Err(why) => return refuse(&why),
    };

    let flag = |name: &str| -> Option<String> {
        flags
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.clone())
    };
    // The default identity: the session's own declared handle, else the operator — the
    // same declare-don't-derive rule as the daemon setting BENCH_HANDLE at spawn.
    let own_handle =
        || std::env::var("BENCH_HANDLE").unwrap_or_else(|_| OPERATOR_HANDLE.to_string());

    // Payloads are the wire crate's own types (#341 R3, completed here — the daemon was
    // typed in that PR, the CLI half was not): the CLI cannot spell a key the daemon
    // does not read.
    let args: Value = match verb.as_str() {
        "events" if follow => json!({ "follow": true }),
        "events" if since > 0 => json!({ "since": since }),
        "attach" | "close" | "resume" => {
            let Some(sid) = positional.first() else {
                return refuse(&format!(
                    "{verb} needs a session id — `bench sessions` lists them"
                ));
            };
            let (rows, cols) = if verb == "attach" {
                // Tell the daemon the viewer's size so the pty matches before replay.
                match attach::terminal_size() {
                    Some((r, c)) => (Some(r), Some(c)),
                    None => (None, None),
                }
            } else {
                (None, None)
            };
            json!(SessionArgs {
                session: sid.clone(),
                rows,
                cols,
            })
        }
        "restore" => match (positional.first(), all) {
            (Some(pane), false) => json!(bench_wire::RestoreArgs {
                pane: Some(pane.clone())
            }),
            (None, true) => json!(bench_wire::RestoreArgs::default()),
            _ => {
                return refuse(
                    "restore needs a pane id, or --all for every terminal pane whose session ended",
                );
            }
        },
        "mail/send" => {
            let Some(to) = flag("to") else {
                return refuse("mail send needs --to <handle>");
            };
            let body = match (flag("body"), flag("body_file")) {
                (Some(b), None) => b,
                (None, Some(p)) => match std::fs::read_to_string(&p) {
                    Ok(b) => b,
                    Err(e) => return refuse(&format!("cannot read --body-file {p:?}: {e}")),
                },
                (Some(_), Some(_)) => {
                    return refuse("--body and --body-file are one or the other");
                }
                (None, None) => return refuse("mail send needs --body <text> or --body-file <p>"),
            };
            json!(MailSendArgs {
                to,
                from: flag("from").unwrap_or_else(own_handle),
                subject: flag("subject"),
                body,
            })
        }
        "sessions/all" => {
            // A relative path means the caller's cwd, which only the caller knows.
            let cwd = std::env::current_dir().unwrap_or_default();
            let workspace = flag("workspace").map_or(cwd.clone(), |w| cwd.join(w));
            json!(SessionsArgs {
                workspace: workspace.display().to_string(),
            })
        }
        "sessions/dismiss" => {
            let Some(id) = positional.first() else {
                return refuse(
                    "sessions dismiss needs a session id — `bench sessions --all` lists them",
                );
            };
            let Some(harness) = flag("harness").as_deref().and_then(Harness::parse) else {
                return refuse(
                    "sessions dismiss needs --harness <claude|codex|pi>, the row's own harness",
                );
            };
            json!(SessionKey {
                harness,
                id: id.clone(),
            })
        }
        "just/run" => {
            let Some((recipe, args)) = positional.split_first() else {
                return refuse("just needs a recipe: bench just <recipe> [args...]");
            };
            json!(JustRunArgs {
                recipe: recipe.clone(),
                args: args.to_vec(),
                // Where the agent is, so a recipe runs in the tree it was asked from.
                cwd: std::env::current_dir()
                    .ok()
                    .map(|d| d.display().to_string()),
            })
        }
        "drawer/toggle" => {
            let Some(name) = positional.first() else {
                return refuse("drawer toggle needs a drawer name");
            };
            let drawer = match DrawerName::new(name) {
                Ok(d) => d,
                Err(why) => return refuse(&why),
            };
            let surface = match flag("surface").as_deref().map(parse_surface).transpose() {
                Ok(s) => s,
                Err(why) => return refuse(&why),
            };
            // The wire type's own encoding, so the CLI cannot spell an argument benchd does
            // not read.
            serde_json::to_value(LayoutVerb::DrawerToggle { drawer, surface })
                .map(|v| v["args"].clone())
                .unwrap_or(Value::Null)
        }
        "mail/list" => json!(MailListArgs {
            handle: flag("handle").unwrap_or_else(own_handle),
        }),
        "mail/who" => {
            let Some(pane) = flag("pane") else {
                return refuse("mail who needs --pane <uuid>, a helm pane's HELM_PANE");
            };
            json!(bench_wire::MailWhoArgs { pane })
        }
        "mail/read" => {
            let Some(id) = positional.first() else {
                return refuse("mail read needs a message id — `bench mail list` shows them");
            };
            json!(MailReadArgs {
                handle: flag("handle").unwrap_or_else(own_handle),
                id: id.clone(),
            })
        }
        _ => Value::Null,
    };

    let cli = Cli {
        verb: verb.clone(),
        args,
        root,
        asked: false,
    };
    if verb == "attach" {
        attach::run(cli, in_pane)
    } else if follow {
        follow_events(cli)
    } else {
        simple(cli)
    }
}

/// `bench log`: reads the transcript file directly — no socket, so it works with the daemon
/// down. The readers and their fail-loudly contract live in `bench_sessions::transcript`.
fn log(arg: Option<&String>, since: Option<&str>, count: Option<&str>, json_out: bool) -> i32 {
    use bench_sessions::transcript;
    let Some(arg) = arg else {
        return refuse(
            "log needs a session id or transcript path — `bench sessions --all` lists them",
        );
    };
    let n = match count.map(str::parse::<usize>) {
        None => 40,
        Some(Ok(n)) => n,
        Some(Err(_)) => return refuse("-n needs a count"),
    };
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let since_ms = match since.map(|s| transcript::parse_since(s, now_ms)) {
        None => None,
        Some(Ok(ms)) => Some(ms),
        Some(Err(why)) => return refuse(&why),
    };
    let home = match std::env::var("HOME") {
        Ok(h) => PathBuf::from(h),
        Err(_) => return refuse("HOME is not set; bench log cannot find transcripts"),
    };
    // A relative path means the caller's cwd.
    let arg = if arg.contains('/') {
        std::env::current_dir()
            .unwrap_or_default()
            .join(arg)
            .display()
            .to_string()
    } else {
        arg.clone()
    };
    let located = match transcript::locate(&home, &arg) {
        Ok(l) => l,
        Err(why) => return refuse(&why),
    };
    let read = match transcript::read(&located) {
        Ok(t) => t,
        Err(why) => return fail(&why),
    };
    let (entries, total) = transcript::tail(read.entries, since_ms, n);
    let path = located.path.display().to_string();
    for p in &read.unreadable {
        eprintln!("bench: {path}:{}: skipped, {}", p.line, p.why);
    }
    if json_out {
        let out = json!({
            "harness": located.harness,
            "id": located.id,
            "path": path,
            "total": total,
            "returned": entries.len(),
            "entries": entries,
            "unreadable": read.unreadable,
        });
        println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
        return 0;
    }
    println!("{} {}  {path}", located.harness.name(), located.id);
    if total > entries.len() {
        println!(
            "… {} earlier entries (-n to see more)",
            total - entries.len()
        );
    }
    for e in &entries {
        let head = format!(
            "{}  {:<5}  ",
            transcript::display_time(e.at_ms),
            kind_name(e.kind)
        );
        let text = match &e.tool {
            Some(tool) => format!("{tool}  {}", e.text),
            None => e.text.clone(),
        };
        // A pasted report or a task notification can run to a hundred lines; the tail stays
        // readable by cutting each entry, and --json carries the whole text.
        const MAX_LINES: usize = 12;
        let lines: Vec<&str> = text.lines().collect();
        println!("{head}{}", lines.first().copied().unwrap_or(""));
        let pad = " ".repeat(head.chars().count());
        for line in lines.iter().skip(1).take(MAX_LINES - 1) {
            println!("{pad}{line}");
        }
        if lines.len() > MAX_LINES {
            println!(
                "{pad}… {} more lines (--json has them)",
                lines.len() - MAX_LINES
            );
        }
    }
    0
}

fn kind_name(kind: bench_sessions::transcript::Kind) -> &'static str {
    use bench_sessions::transcript::Kind;
    match kind {
        Kind::User => "user",
        Kind::Agent => "agent",
        Kind::Tool => "tool",
        Kind::Error => "error",
    }
}

/// `--surface`: `browser`, `terminal`, or `file:<path>`, a relative path meaning the caller's
/// cwd — which only the caller knows.
fn parse_surface(raw: &str) -> Result<Surface, String> {
    match raw {
        "browser" => Ok(Surface::Browser),
        "sessions" => Ok(Surface::Sessions),
        "archon" => Ok(Surface::Archon),
        "worktrees" => Ok(Surface::Worktrees),
        "terminal" => Ok(Surface::terminal()),
        _ => match raw.strip_prefix("file:") {
            Some(path) => {
                let cwd = std::env::current_dir().unwrap_or_default();
                Surface::file(&cwd.join(path).display().to_string())
            }
            None => Err(format!(
                "--surface is browser, sessions, archon, worktrees, terminal or file:<path>, not {raw:?}"
            )),
        },
    }
}

/// `bench wiring`: what to add, once per machine, so an agent the operator starts himself
/// reports to benchd — the settings and hooks files, and pi's extension. The command is always
/// this `bench`, by absolute path, so the wiring never changes and codex trusts it once.
/// benchd passes a Claude it spawns the same hooks itself (`--settings`); a codex or pi it
/// spawns reports only through these files, the operator's own.
///
/// `bench wiring --check` reads the files, and asks codex whether it trusts its hooks, and says
/// what is missing: exit 0 when all of it is there, 3 when something is not. It never writes
/// anything: trusting codex's hooks is the operator's step.
fn wiring(mode: Option<&str>) -> i32 {
    let bench = match std::env::current_exe() {
        Ok(exe) => bench_wire::hook::sibling_bench(&exe).display().to_string(),
        Err(e) => return fail(&format!("cannot find this bench: {e}")),
    };
    // The wiring names this file for good; a build directory goes away with its checkout.
    if bench.contains("/target/") || bench.contains("/.worktrees/") {
        eprintln!(
            "bench wiring: {bench} is a build, not an installed bench; run the installed one \
             (`cargo install --path crates/bench`) so the wiring outlives this checkout"
        );
    }
    let Ok(home) = std::env::var("HOME").map(PathBuf::from) else {
        return refuse("HOME is not set; bench cannot find the files to wire");
    };
    let claude_file = home.join(".claude/settings.json");
    let codex_file = home.join(".codex/hooks.json");
    let pi_link = home.join(".pi/agent/extensions/bench");
    match mode {
        None => {
            let plan = json!({
                "bench": bench,
                "claude": {
                    "file": claude_file,
                    "merge": bench_wire::hook::claude_settings(&bench),
                },
                "codex": {
                    "file": codex_file,
                    "merge": bench_wire::hook::codex_hooks(&bench),
                    "then": CODEX_TRUST_STEP,
                },
                "pi": { "link": pi_link, "to": "<helm checkout>/pi/extensions/bench" },
                // Claude's plan limits reach benchd only through its statusline (#143), so the
                // operator's own statusline command moves behind `statusline`, which runs it.
                "claude_statusline": {
                    "file": claude_file,
                    "statusLine": { "type": "command",
                        "command": format!("{bench} statusline <your current statusLine command>") },
                },
            });
            println!(
                "{}",
                serde_json::to_string_pretty(&plan).unwrap_or_default()
            );
            0
        }
        Some("--check") => wiring_check(&bench, &claude_file, &codex_file, &pi_link),
        Some(other) => refuse(&format!(
            "bench wiring takes no argument or --check, not {other:?}"
        )),
    }
}

/// What the operator does once so codex runs the bench's hooks, in the words its dialog uses.
/// Plain `codex`, because codex 0.159.3 saves the trust a `codex -p <name>` session accepts in
/// that profile's file, where only that profile reads it.
const CODEX_TRUST_STEP: &str = "open plain `codex` (no `-p`) once and choose \"Trust all and \
     continue\"; trust accepted under `codex -p <name>` is saved in ~/.codex/<name>.config.toml \
     and covers only that profile";

/// Why an event can still need review after that step: nothing in codex's dialog fixes these.
const CODEX_TRUST_ELSE: &str = "an event still listed after that has its hook disabled in \
     codex's /hooks, or codex reads another CODEX_HOME than ~/.codex";

/// `bench wiring --check`: what is missing, and exit 3 if anything required is.
fn wiring_check(bench: &str, claude_file: &PathBuf, codex_file: &PathBuf, pi_link: &Path) -> i32 {
    let read = |path: &PathBuf| -> Value {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null)
    };
    let claude = read(claude_file);
    let claude_missing = bench_wire::hook::unwired(Harness::Claude, &claude, bench);
    let codex_missing = bench_wire::hook::unwired(Harness::Codex, &read(codex_file), bench);
    let inbound = claude["crossSessionInbound"] == "accept";
    // Optional (#143), so reported but never part of the exit status.
    let statusline = claude["statusLine"]["command"]
        .as_str()
        .is_some_and(|c| c.starts_with(&format!("{bench} statusline")));
    let pi = pi_link.join("index.ts").is_file();
    let exists = PathBuf::from(bench).is_file();
    // A hook in the file runs only once codex trusts it, and only codex can say whether it
    // does: the trust record is a hash of codex's own normalized form of the hook.
    let codex_home = codex_file.parent().unwrap_or(Path::new("."));
    let review = codex_hooks_list().map(|list| {
        let events = bench_wire::hook::codex_needs_review(&list, bench);
        let profiles = codex_profile_trust(codex_home, &list, bench, &events);
        (events, profiles)
    });
    let trusted = review.as_ref().is_ok_and(|(events, _)| events.is_empty());
    let mut codex = json!({ "file": codex_file, "missing_events": codex_missing });
    match review {
        Ok((events, profiles)) => {
            codex["needs_review"] = json!(events);
            if !profiles.is_empty() {
                codex["trusted_only_under_profile"] = json!(profiles);
            }
        }
        Err(why) => codex["trust_unverified"] = json!(why),
    }
    if !trusted {
        codex["then"] = json!(format!("{CODEX_TRUST_STEP}; {CODEX_TRUST_ELSE}"));
    }
    let report = json!({
        "bench": bench,
        "bench_exists": exists,
        "claude": { "file": claude_file, "missing_events": claude_missing,
                    "cross_session_inbound_accept": inbound,
                    "statusline_reports_limits": statusline },
        "codex": codex,
        "pi": { "link": pi_link, "installed": pi },
    });
    println!(
        "{}",
        serde_json::to_string_pretty(&report).unwrap_or_default()
    );
    let all = exists && claude_missing.is_empty() && codex_missing.is_empty();
    if all && trusted && inbound && pi {
        0
    } else {
        Status::Refused.exit_code()
    }
}

/// Of `needs_review`, the events each codex profile trusts (`<codex_home>/<name>.config.toml`),
/// by profile name: the trust a `codex -p <name>` session saved where `hooks/list` cannot see
/// it. Read-only; a file that does not parse counts as trusting nothing.
fn codex_profile_trust(
    codex_home: &Path,
    hooks_list: &Value,
    bench: &str,
    needs_review: &[String],
) -> serde_json::Map<String, Value> {
    let mut files: Vec<(String, PathBuf)> = std::fs::read_dir(codex_home)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry
                .file_name()
                .to_str()?
                .strip_suffix(".config.toml")?
                .to_owned();
            Some((name, entry.path()))
        })
        .collect();
    files.sort();
    files
        .into_iter()
        .filter_map(|(name, path)| {
            let config: toml::Table = std::fs::read_to_string(path).ok()?.parse().ok()?;
            let state = config.get("hooks")?.get("state")?;
            let events: Vec<String> =
                bench_wire::hook::codex_trusted_by(hooks_list, bench, |key| {
                    Some(state.get(key)?.get("trusted_hash")?.as_str()?.to_owned())
                })
                .into_iter()
                .filter(|event| needs_review.contains(event))
                .collect();
            (!events.is_empty()).then(|| (name, json!(events)))
        })
        .collect()
}

/// How long `wiring --check` waits for codex's answer. Measured: 60 ms on 0.159.3, 250 ms on
/// 0.157.0, both from a cold start.
const CODEX_ANSWER_WAIT: Duration = Duration::from_secs(10);

/// codex's own `hooks/list` for this directory, from the `codex` on PATH (the one a shell
/// starts), through a stdio app-server of its own that is killed once it answers. It reads the
/// operator's codex config and writes nothing. stdin stays open until the answer: an
/// app-server whose stdin closes exits before answering.
fn codex_hooks_list() -> Result<Value, String> {
    use std::io::BufRead;
    let cwd = std::env::current_dir().map_err(|e| format!("no current directory: {e}"))?;
    let mut child = process::Command::new("codex")
        .arg("app-server")
        .stdin(process::Stdio::piped())
        .stdout(process::Stdio::piped())
        .stderr(process::Stdio::null())
        .spawn()
        .map_err(|e| format!("cannot start `codex app-server`: {e}"))?;
    let (Some(mut stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        let _ = child.kill();
        let _ = child.wait();
        return Err("`codex app-server` has no stdio".into());
    };
    let requests = [
        json!({ "id": 1, "method": "initialize",
                "params": { "clientInfo": { "name": "bench-wiring",
                                            "version": env!("CARGO_PKG_VERSION") } } }),
        json!({ "method": "initialized" }),
        json!({ "id": 2, "method": "hooks/list", "params": { "cwds": [cwd] } }),
    ];
    let wrote = requests.iter().try_for_each(|r| writeln!(stdin, "{r}"));
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
        {
            if let Ok(message) = serde_json::from_str::<Value>(&line)
                && message["id"] == 2
            {
                let _ = tx.send(message);
                return;
            }
        }
    });
    let answer = wrote
        .map_err(|e| format!("cannot write to `codex app-server`: {e}"))
        .and_then(|()| {
            rx.recv_timeout(CODEX_ANSWER_WAIT).map_err(|e| match e {
                std::sync::mpsc::RecvTimeoutError::Timeout => format!(
                    "`codex app-server` did not answer hooks/list within {}s",
                    CODEX_ANSWER_WAIT.as_secs()
                ),
                std::sync::mpsc::RecvTimeoutError::Disconnected => {
                    "`codex app-server` ended its output without answering hooks/list".into()
                }
            })
        });
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    let answer = answer?;
    if answer["result"].is_object() {
        Ok(answer["result"].clone())
    } else {
        Err(format!("codex refused hooks/list: {}", answer["error"]))
    }
}

/// How long a hook waits on the daemon before giving up silently. A hook runs on every tool
/// call, so a wedged daemon must cost the agent this at most, never `CLIENT_READ_TIMEOUT`.
const HOOK_TIMEOUT: Duration = Duration::from_millis(500);

/// A hook payload larger than this is not read further; the fields it needs come first.
const HOOK_STDIN_MAX: u64 = 8 * 1024 * 1024;

/// `bench hook <harness>` (#358): one command per harness, wired once. It reads the harness's
/// hook payload, sends benchd the typed fields plus what only this process can see — its
/// parent (the agent) and the host declarations in its environment — and prints what the
/// harness should put in front of the model. Its contract is the hooks': **exit 0 and print
/// nothing on any failure**, so a missing daemon never stops an agent's tool call.
///
/// Output: for claude and codex, `hookSpecificOutput.additionalContext` when there is
/// context (the shape both take on SessionStart, UserPromptSubmit, PreToolUse and
/// PostToolUse; plain stdout is dropped on tool events, measured on Claude 2.1.283). For pi,
/// the reply itself, which its extension reads.
fn hook(harness: Option<&str>) -> i32 {
    let Some(harness) = harness.and_then(Harness::parse) else {
        eprintln!("bench hook: name the harness: claude, codex or pi");
        return 0;
    };
    let mut input = String::new();
    if std::io::stdin()
        .take(HOOK_STDIN_MAX)
        .read_to_string(&mut input)
        .is_err()
    {
        return 0;
    }
    let Ok(payload) = serde_json::from_str::<Value>(&input) else {
        return 0;
    };
    let field = |name: &str| payload[name].as_str().map(str::to_string);
    let (Some(event), Some(session), Some(cwd)) =
        (field("hook_event_name"), field("session_id"), field("cwd"))
    else {
        return 0;
    };
    let env = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
    let args = HookArgs {
        harness,
        event: event.clone(),
        session,
        cwd,
        pid: std::os::unix::process::parent_id(),
        tool: field("tool_name"),
        pane: env("HELM_PANE"),
        bench_session: env("BENCH_SESSION"),
        messaging_socket: env("CLAUDE_CODE_MESSAGING_SOCKET"),
        usage: usage::codex_hook(harness, &event, field("transcript_path").as_deref()),
    };
    let Some(reply) = quiet_request("hook", json!(args))
        .and_then(|data| serde_json::from_value::<HookReply>(data).ok())
    else {
        return 0;
    };
    match harness {
        Harness::Pi => println!("{}", json!(reply)),
        Harness::Claude | Harness::Codex => {
            if let Some(context) = reply.context {
                println!(
                    "{}",
                    json!({ "hookSpecificOutput": {
                        "hookEventName": event,
                        "additionalContext": context,
                    }})
                );
            }
        }
    }
    0
}

/// One request line, one reply line, `None` on anything short of an ok reply, each way bounded by
/// [`HOOK_TIMEOUT`]: what a harness's own hook or statusline asks, which must never stall it. The
/// root is resolved exactly as every other verb resolves it; a suite that cannot isolate reaches
/// no daemon at all.
fn quiet_request(verb: &str, args: Value) -> Option<Value> {
    let root = record_root(None).ok()?;
    let stream = endpoint(&root).ok()?.connect().ok()?;
    let _ = stream.set_write_timeout(Some(HOOK_TIMEOUT));
    let _ = stream.set_read_timeout(Some(HOOK_TIMEOUT));
    let request = Request {
        id: request_id(),
        verb: verb.into(),
        args,
        by: None,
        asked: false,
    };
    let line = serde_json::to_string(&request).ok()? + "\n";
    (&stream).write_all(line.as_bytes()).ok()?;
    let response: Response = serde_json::from_str(&read_response_line(&stream)?).ok()?;
    if response.status != Status::Ok {
        return None;
    }
    response.data
}

/// The record root every verb talks to: the `--suite` flag or `BENCH_SUITE`, validated
/// before any socket is touched — a name that cannot isolate must never resolve to the
/// shared root by accident (#86) — then `BENCH_DIR` and `HOME` by `resolve_root`'s rule.
fn record_root(suite_flag: Option<String>) -> Result<PathBuf, String> {
    let suite = suite_flag
        .or_else(|| std::env::var("BENCH_SUITE").ok())
        .map(|raw| SuiteName::validate(&raw))
        .transpose()?;
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .map_err(|_| "HOME is not set; bench cannot resolve a record root".to_string())?;
    let bench_dir = std::env::var("BENCH_DIR").ok();
    Ok(resolve_root(bench_dir.as_deref(), suite.as_ref(), &home))
}

/// The ordinary one-line-in, one-line-out path.
fn simple(cli: Cli) -> i32 {
    match exchange(&cli) {
        Ok(response) => print_response(&response),
        Err(code) => code,
    }
}

/// One request, one response. `Err` is the exit code of a transport failure, already said.
fn exchange(cli: &Cli) -> Result<Response, i32> {
    request(cli).map_err(say)
}

/// A failure's exit code and why, not yet said: [`request`] and [`dial`] stay quiet, so a caller
/// with a pane of its own (the attach client) decides what reaches the screen.
type Failed = (i32, String);

/// Say why on stderr, answer the exit code.
fn say((code, why): Failed) -> i32 {
    eprintln!("bench: {why}");
    code
}

/// [`exchange`] without a word on stderr.
fn request(cli: &Cli) -> Result<Response, Failed> {
    let (stream, request_line) = dial(cli)?;
    (&stream)
        .write_all(request_line.as_bytes())
        .map_err(|e| (EXIT_NO_DAEMON, format!("write failed ({e})")))?;
    let reply = read_response_line(&stream).ok_or_else(|| {
        let secs = CLIENT_READ_TIMEOUT.as_secs();
        (EXIT_NO_DAEMON, format!("no answer within {secs}s"))
    })?;
    serde_json::from_str(&reply).map_err(|e| {
        let why = format!("unreadable response ({e}): {}", reply.trim());
        (Status::Error.exit_code(), why)
    })
}

/// The reason on stderr, the data as pretty JSON on stdout, the status as the exit code.
fn print_response(response: &Response) -> i32 {
    if let Some(reason) = &response.reason {
        eprintln!("bench: {reason}");
    }
    if let Some(data) = &response.data {
        match serde_json::to_string_pretty(data) {
            Ok(pretty) => println!("{pretty}"),
            Err(_) => println!("{data}"),
        }
    }
    response.status.exit_code()
}

/// `events --follow`: the answer (the document and its seq) as one JSON line, then every
/// frame as the daemon sends it, one JSON line each, until the daemon goes away. Lines, not
/// pretty JSON, so a reader can take them one at a time.
fn follow_events(cli: Cli) -> i32 {
    let (stream, request_line) = match open(&cli) {
        Ok(pair) => pair,
        Err(code) => return code,
    };
    if let Err(e) = (&stream).write_all(request_line.as_bytes()) {
        eprintln!("bench: write failed ({e})");
        return EXIT_NO_DAEMON;
    }
    let reply = match read_response_line(&stream) {
        Some(r) => r,
        None => {
            eprintln!("bench: no answer within {}s", CLIENT_READ_TIMEOUT.as_secs());
            return EXIT_NO_DAEMON;
        }
    };
    let response: Response = match serde_json::from_str(&reply) {
        Ok(r) => r,
        Err(e) => return fail(&format!("unreadable response ({e}): {}", reply.trim())),
    };
    if response.status != Status::Ok {
        if let Some(reason) = &response.reason {
            eprintln!("bench: {reason}");
        }
        return response.status.exit_code();
    }
    let mut out = std::io::stdout();
    if let Some(data) = &response.data {
        let _ = writeln!(out, "{data}");
        let _ = out.flush();
    }
    // A follower waits as long as the bench runs; the daemon bounds its own writes.
    let _ = stream.set_read_timeout(None);
    let mut chunk = [0u8; 16384];
    let mut sock = &stream;
    loop {
        match sock.read(&mut chunk) {
            Ok(0) | Err(_) => return 0,
            Ok(n) => {
                if out.write_all(&chunk[..n]).is_err() {
                    return 0;
                }
                let _ = out.flush();
            }
        }
    }
}

fn open(cli: &Cli) -> Result<(UnixStream, String), i32> {
    dial(cli).map_err(say)
}

/// Where benchd answers for this caller: `BENCH_URL`, else the root's socket.
fn endpoint(root: &Path) -> Result<Endpoint, String> {
    Endpoint::resolve(std::env::var(BENCH_URL).ok().as_deref(), root)
}

/// Connect, and the request line to send. Says nothing: see [`Failed`].
fn dial(cli: &Cli) -> Result<(UnixStream, String), Failed> {
    let endpoint = endpoint(&cli.root).map_err(|why| (Status::Refused.exit_code(), why))?;
    let stream = endpoint
        .connect()
        .map_err(|e| (EXIT_NO_DAEMON, format!("no daemon at {endpoint} ({e})")))?;
    // Bounded on both directions (R2): a hung caller has no exit code, which is the one
    // failure an unattended agent cannot act on.
    let _ = stream.set_write_timeout(Some(DAEMON_IO_TIMEOUT));
    let _ = stream.set_read_timeout(Some(CLIENT_READ_TIMEOUT));
    let request = Request {
        id: request_id(),
        verb: cli.verb.clone(),
        args: cli.args.clone(),
        by: Some(caller()),
        // `--asked`, or `BENCH_ASKED=1`, which benchd sets on a just recipe the operator started
        // (#356): he asked, so its verbs may move his focus.
        asked: cli.asked || std::env::var("BENCH_ASKED").is_ok_and(|v| v == "1"),
    };
    let mut line = serde_json::to_string(&request).map_err(|e| {
        (
            Status::Error.exit_code(),
            format!("cannot encode the request ({e})"),
        )
    })?;
    line.push('\n');
    Ok((stream, line))
}

/// Who is asking: an agent, placed by what its environment declares — the helm pane it runs in
/// and its benchd mailbox. benchd reads them to put what an agent opens in its own workspace.
/// The operator's own gestures come from helm, never from this CLI.
fn caller() -> Actor {
    let declared = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
    Actor::Agent {
        pane: declared("HELM_PANE"),
        handle: declared("BENCH_HANDLE"),
    }
}

/// Read exactly the response line, byte by byte — a BufReader would swallow the raw
/// replay bytes that follow it on an attach connection.
fn read_response_line(mut stream: &UnixStream) -> Option<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(0) | Err(_) => {
                return if line.is_empty() {
                    None
                } else {
                    Some(String::from_utf8_lossy(&line).into_owned())
                };
            }
            Ok(_) => {
                if byte[0] == b'\n' {
                    return Some(String::from_utf8_lossy(&line).into_owned());
                }
                line.push(byte[0]);
                if line.len() > 1_000_000 {
                    return None;
                }
            }
        }
    }
}

// Pre-socket exits derive from the same enum as socket-answered ones (R3).
fn refuse(why: &str) -> i32 {
    eprintln!("bench: {why}");
    Status::Refused.exit_code()
}

fn fail(why: &str) -> i32 {
    eprintln!("bench: {why}");
    Status::Error.exit_code()
}

/// A fresh id per invocation, inside `RequestId`'s own pattern — validated, not assumed.
fn request_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let candidate = format!("bench-{}-{nanos:08x}", process::id());
    RequestId::validate(&candidate)
        .map(|id| id.as_str().to_string())
        .unwrap_or_else(|_| "bench-fallback".to_string())
}
