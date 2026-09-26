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
    CLIENT_READ_TIMEOUT, DAEMON_IO_TIMEOUT, EXIT_NO_DAEMON, Harness, HookArgs, HookReply,
    LayoutVerb, MailListArgs, MailReadArgs, MailSendArgs, OPERATOR_HANDLE, Request, RequestId,
    Response, SessionArgs, SessionKey, SessionsArgs, SpawnArgs, Status, SuiteName, resolve_root,
    socket_path,
};
use serde_json::{Value, json};
use std::io::{IsTerminal, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn main() {
    // `hook` is wired into an agent's own hooks and has its own contract (exit 0, always),
    // so it never reaches the verb parser, whose refusals exit 3.
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let code = match raw.first().map(String::as_str) {
        Some("hook") => hook(raw.get(1).map(String::as_str)),
        Some("wiring") => wiring(raw.get(1).map(String::as_str)),
        _ => run(),
    };
    process::exit(code);
}

fn usage() -> &'static str {
    "usage: bench [--suite <name>] <verb> [args]\n\
     verbs: status                              daemon identity, root, uptime, counts\n\
     \x20     events [--since N]                  read the record back from seq N\n\
     \x20     events --follow                     the bench document, then one line per event as it\n\
     \x20                                         happens (the document attached when it changed)\n\
     \x20     get                                 the bench document and the seq it reflects\n\
     \x20     stop                                log the stop, kill sessions, exit\n\
     \x20     spawn --agent <a> --cwd <dir>       spawn an agent into a bench pty\n\
     \x20           [--name <handle>] [--prompt-file <p>] [--model <m>] [--effort <e>]\n\
     \x20     sessions                            list bench sessions\n\
     \x20     sessions --all [--workspace <dir>]  every agent session in a workspace (default: the\n\
     \x20                                         cwd's): helm panes, bench sessions, --bg jobs,\n\
     \x20                                         running subagents, and finished hosted sessions\n\
     \x20     sessions dismiss <id> --harness <h> hide a finished row until it finishes again\n\
     \x20     log <session id | transcript path>  a Claude or pi session's prompts, replies, tool\n\
     \x20         [-n N] [--since 30m|2h|1d|<time>] calls and errors, read from its transcript with no\n\
     \x20         [--json]                        daemon; the last 40 unless -n says otherwise\n\
     \x20     attach <session>                    raw relay to a session's pty (Ctrl-\\ detaches)\n\
     \x20     close <session>                     drain-then-die the session\n\
     \x20     resume <session>                    re-enter an exited session's runtime state\n\
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
     \x20     browser start                       start the shared browser, or find it running;\n\
     \x20                                         `cdp` in its answer is for playwright-cli attach\n\
     \x20     browser status                      the endpoint, or running: false\n\
     \x20     browser stop                        stop the shared browser\n\
     \x20     browser setup                       the same profile in a real window, to install\n\
     \x20                                         extensions and sign in; quit it to go headless\n\
     \x20     drawer toggle <name>                show a drawer over the bench, or hide it: the\n\
     \x20           [--surface <s>]               operator's focus, so refused from an agent. <s>\n\
     \x20                                         is what a new drawer starts with: browser,\n\
     \x20                                         sessions, terminal or file:<path>\n\
     env:   BENCH_SUITE (flag wins) · BENCH_DIR (root override, wins over suite)\n\
     exit:  0 ok · 2 no daemon · 3 refused · 4 daemon failed"
}

struct Cli {
    verb: String,
    args: Value,
    root: PathBuf,
}

#[expect(
    clippy::too_many_lines,
    clippy::cognitive_complexity,
    reason = "legacy (#418): 250 lines, limit 100; cognitive complexity 27, limit 25"
)]
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
            "--follow" => follow = true,
            "--all" => all = true,
            "--agent" | "--cwd" | "--prompt-file" | "--model" | "--effort" | "--rows"
            | "--cols" | "--name" | "--to" | "--from" | "--subject" | "--body" | "--body-file"
            | "--handle" | "--workspace" | "--harness" | "--pane" | "--surface" => {
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
    if follow && verb != "events" {
        return refuse("--follow is for `events`");
    }
    if all && verb != "sessions" {
        return refuse("--all is for `sessions`");
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
        "spawn" => {
            let mut spawn = SpawnArgs {
                agent: String::new(),
                cwd: String::new(),
                name: flag("name"),
                // Absolute: the agent reads it from its own cwd, which is not the caller's.
                prompt_file: flag("prompt_file").map(|p| {
                    std::env::current_dir()
                        .map(|cwd| cwd.join(&p).display().to_string())
                        .unwrap_or(p)
                }),
                model: flag("model"),
                effort: flag("effort"),
                rows: None,
                cols: None,
            };
            if let Some(a) = flag("agent") {
                spawn.agent = a;
            } else {
                return refuse("spawn needs --agent <claude|codex|pi>");
            }
            if let Some(c) = flag("cwd") {
                spawn.cwd = c;
            } else {
                return refuse("spawn needs --cwd <absolute dir>");
            }
            for k in ["rows", "cols"] {
                if let Some(v) = flag(k) {
                    match v.parse::<u16>() {
                        Ok(n) => {
                            if k == "rows" {
                                spawn.rows = Some(n)
                            } else {
                                spawn.cols = Some(n)
                            }
                        }
                        Err(_) => return refuse(&format!("--{k} needs a number")),
                    }
                }
            }
            json!(spawn)
        }
        "attach" | "close" | "resume" => {
            let Some(sid) = positional.first() else {
                return refuse(&format!(
                    "{verb} needs a session id — `bench sessions` lists them"
                ));
            };
            let (rows, cols) = if verb == "attach" {
                // Tell the daemon the viewer's size so the pty matches before replay.
                match terminal_size() {
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
    };
    if verb == "attach" {
        attach(cli)
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
        "terminal" => Ok(Surface::terminal()),
        _ => match raw.strip_prefix("file:") {
            Some(path) => {
                let cwd = std::env::current_dir().unwrap_or_default();
                Surface::file(&cwd.join(path).display().to_string())
            }
            None => Err(format!(
                "--surface is browser, sessions, terminal or file:<path>, not {raw:?}"
            )),
        },
    }
}

/// `bench wiring`: what to add, once per machine, so an agent the operator starts himself
/// reports to benchd — the settings and hooks files, and pi's extension. The command is always
/// this `bench`, by absolute path, so the wiring never changes and codex trusts it once.
/// benchd gives the sessions it spawns the same wiring on its own.
///
/// `bench wiring --check` reads the files and says what is missing: exit 0 when all of it is
/// there, 3 when something is not. It never writes them.
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
                    "then": "open codex once and trust the hook in /hooks",
                },
                "pi": { "link": pi_link, "to": "<helm checkout>/pi/extensions/bench" },
            });
            println!(
                "{}",
                serde_json::to_string_pretty(&plan).unwrap_or_default()
            );
            0
        }
        Some("--check") => {
            let read = |path: &PathBuf| -> Value {
                std::fs::read_to_string(path)
                    .ok()
                    .and_then(|t| serde_json::from_str(&t).ok())
                    .unwrap_or(Value::Null)
            };
            let claude = read(&claude_file);
            let claude_missing = bench_wire::hook::unwired(Harness::Claude, &claude, &bench);
            let codex_missing =
                bench_wire::hook::unwired(Harness::Codex, &read(&codex_file), &bench);
            let inbound = claude["crossSessionInbound"] == "accept";
            let pi = pi_link.join("index.ts").is_file();
            let exists = PathBuf::from(&bench).is_file();
            let report = json!({
                "bench": bench,
                "bench_exists": exists,
                "claude": { "file": claude_file, "missing_events": claude_missing,
                            "cross_session_inbound_accept": inbound },
                "codex": { "file": codex_file, "missing_events": codex_missing },
                "pi": { "link": pi_link, "installed": pi },
            });
            println!(
                "{}",
                serde_json::to_string_pretty(&report).unwrap_or_default()
            );
            let all = exists && claude_missing.is_empty() && codex_missing.is_empty();
            if all && inbound && pi {
                0
            } else {
                Status::Refused.exit_code()
            }
        }
        Some(other) => refuse(&format!(
            "bench wiring takes no argument or --check, not {other:?}"
        )),
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
    };
    let Some(reply) = hook_request(&args) else {
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

/// One request line, one reply line, `None` on anything short of an ok reply. The root is
/// resolved exactly as every other verb resolves it; a suite that cannot isolate reaches no
/// daemon at all.
fn hook_request(args: &HookArgs) -> Option<HookReply> {
    let root = record_root(None).ok()?;
    let stream = UnixStream::connect(socket_path(&root)).ok()?;
    let _ = stream.set_write_timeout(Some(HOOK_TIMEOUT));
    let _ = stream.set_read_timeout(Some(HOOK_TIMEOUT));
    let request = Request {
        id: request_id(),
        verb: "hook".into(),
        args: json!(args),
        by: None,
        asked: false,
    };
    let line = serde_json::to_string(&request).ok()? + "\n";
    (&stream).write_all(line.as_bytes()).ok()?;
    let response: Response = serde_json::from_str(&read_response_line(&stream)?).ok()?;
    if response.status != Status::Ok {
        return None;
    }
    serde_json::from_value(response.data?).ok()
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

/// The attach path: response line, then the connection is a raw relay. Local terminal
/// goes raw (keystrokes reach the agent unmangled, Ctrl-C included); Ctrl-\ detaches.
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

fn attach(cli: Cli) -> i32 {
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
    eprintln!("bench: attached — Ctrl-\\ detaches");
    let _ = stream.set_read_timeout(None);

    // Raw local terminal for the duration; restored on the way out. `stty -g` gives a
    // restore token, so whatever the mode was is what comes back.
    let stdin_is_tty = std::io::stdin().is_terminal();
    let saved = if stdin_is_tty {
        let saved = std::process::Command::new("stty")
            .arg("-g")
            .stdin(std::process::Stdio::inherit())
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
        let _ = std::process::Command::new("stty")
            .args(["raw", "-echo"])
            .stdin(std::process::Stdio::inherit())
            .status();
        saved
    } else {
        None
    };

    // Down: socket → stdout, byte-for-byte — escape sequences ride through, which is
    // what lets an OSC from the agent reach whatever terminal hosts this client.
    let down = {
        let mut sock = match stream.try_clone() {
            Ok(s) => s,
            Err(_) => return fail("cannot clone stream"),
        };
        std::thread::spawn(move || {
            let mut out = std::io::stdout();
            let mut chunk = [0u8; 8192];
            loop {
                match sock.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if out.write_all(&chunk[..n]).is_err() {
                            break;
                        }
                        let _ = out.flush();
                    }
                }
            }
        })
    };

    // Up: stdin → socket, until Ctrl-\ (0x1C) or EOF.
    let mut stdin = std::io::stdin();
    let up_sock = stream;
    let mut chunk = [0u8; 1024];
    let code = loop {
        match stdin.read(&mut chunk) {
            Ok(0) | Err(_) => break 0,
            Ok(n) => {
                if let Some(pos) = chunk[..n].iter().position(|&b| b == 0x1c) {
                    if pos > 0 {
                        let _ = (&up_sock).write_all(&chunk[..pos]);
                    }
                    break 0;
                }
                if (&up_sock).write_all(&chunk[..n]).is_err() {
                    break 0;
                }
            }
        }
    };
    let _ = up_sock.shutdown(std::net::Shutdown::Both);
    let _ = down.join();
    if let Some(token) = saved {
        let _ = std::process::Command::new("stty")
            .arg(token)
            .stdin(std::process::Stdio::inherit())
            .status();
    }
    eprintln!("\nbench: detached");
    code
}

fn open(cli: &Cli) -> Result<(UnixStream, String), i32> {
    let sock = socket_path(&cli.root);
    let stream = match UnixStream::connect(&sock) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("bench: no daemon at {} ({e})", sock.display());
            return Err(EXIT_NO_DAEMON);
        }
    };
    // Bounded on both directions (R2): a hung caller has no exit code, which is the one
    // failure an unattended agent cannot act on.
    let _ = stream.set_write_timeout(Some(DAEMON_IO_TIMEOUT));
    let _ = stream.set_read_timeout(Some(CLIENT_READ_TIMEOUT));
    let request = Request {
        id: request_id(),
        verb: cli.verb.clone(),
        args: cli.args.clone(),
        // The CLI speaks for an agent until M3 gives it `--asked` and the layout verbs; an
        // absent `by` already means exactly that.
        by: None,
        asked: false,
    };
    let mut line = match serde_json::to_string(&request) {
        Ok(l) => l,
        Err(_) => return Err(4),
    };
    line.push('\n');
    Ok((stream, line))
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

fn terminal_size() -> Option<(u16, u16)> {
    if !std::io::stdout().is_terminal() {
        return None;
    }
    let out = std::process::Command::new("stty")
        .arg("size")
        .stdin(std::process::Stdio::inherit())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let mut parts = text.split_whitespace();
    let rows = parts.next()?.parse().ok()?;
    let cols = parts.next()?.parse().ok()?;
    Some((rows, cols))
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
