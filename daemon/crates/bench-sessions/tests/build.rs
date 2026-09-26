//! The session list's rules, each against a fixture tree under a temp HOME — never the
//! operator's `~/.claude`, `~/.pi` or `~/.helm`. Which pids are alive is the test's to say,
//! through `Inputs::alive`; the real check is `process::alive`, tested beside it.

use bench_doc::{PaneId, StandardPath};
use bench_sessions::{BenchSession, Built, Cache, HookedAgent, Inputs, build};
use bench_wire::{
    Activity, Dismissal, Harness, Host, HostedSession, HostedVia, MailAddress, OpenAction,
    SessionRow, SessionState,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const PANE: &str = "0E8E8CC6-159B-45D8-BC02-485120975998";
const PANE2: &str = "3C47FA92-A0BE-4012-A697-F7BE06AEDE28";

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// A disposable HOME holding a repo (`ws`) with one worktree inside it and one outside it.
struct Fixture {
    dir: PathBuf,
    /// pid → the start it really had.
    live: HashMap<u32, u64>,
    panes: Vec<Value>,
    bench: Vec<BenchSession>,
    hosted: Vec<HostedSession>,
    hooked: Vec<HookedAgent>,
    dismissed: Vec<Dismissal>,
    /// handle → messages in its inbox.
    unread: HashMap<String, usize>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn jsonl<L: std::fmt::Display>(records: &[L]) -> String {
    records.iter().map(|r| format!("{r}\n")).collect()
}

fn set_mtime(path: &Path, ms: u64) {
    let f = fs::OpenOptions::new().write(true).open(path).unwrap();
    f.set_modified(UNIX_EPOCH + Duration::from_millis(ms))
        .unwrap();
}

impl Fixture {
    fn new() -> Fixture {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "bss-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("home")).unwrap();
        let f = Fixture {
            dir,
            live: HashMap::new(),
            panes: Vec::new(),
            bench: Vec::new(),
            hosted: Vec::new(),
            hooked: Vec::new(),
            dismissed: Vec::new(),
            unread: HashMap::new(),
        };
        // ws/.git with one worktree inside the repo and one outside it.
        let git = f.ws().join(".git");
        fs::create_dir_all(&git).unwrap();
        for (name, at) in [("inner", f.inner()), ("outer", f.outer())] {
            write(
                &git.join("worktrees").join(name).join("gitdir"),
                &format!("{}\n", at.join(".git").display()),
            );
            write(
                &git.join("worktrees").join(name).join("commondir"),
                "../..\n",
            );
            write(
                &at.join(".git"),
                &format!("gitdir: {}\n", git.join("worktrees").join(name).display()),
            );
        }
        f
    }

    fn home(&self) -> PathBuf {
        self.dir.join("home")
    }
    fn ws(&self) -> PathBuf {
        self.dir.join("ws")
    }
    fn inner(&self) -> PathBuf {
        self.ws().join(".worktrees/inner")
    }
    fn outer(&self) -> PathBuf {
        self.dir.join("elsewhere/outer")
    }
    fn s(p: PathBuf) -> String {
        p.display().to_string()
    }

    /// A registry row for a live Claude process started six hours ago.
    fn claude(&mut self, pid: u32, session: &str, cwd: &str, status: Value) -> u64 {
        let started = now_ms() - 6 * 3_600_000;
        self.live.insert(pid, started);
        let mut row = json!({
            "pid": pid, "sessionId": session, "cwd": cwd, "startedAt": started,
            "kind": "interactive", "entrypoint": "cli", "version": "2.1.282",
            "name": format!("name-{session}"), "statusUpdatedAt": started + 1000,
        });
        if let Value::Object(extra) = status {
            row.as_object_mut().unwrap().extend(extra);
        }
        write(
            &self.home().join(format!(".claude/sessions/{pid}.json")),
            &row.to_string(),
        );
        started
    }

    fn pane(&mut self, pane: &str, terminal: Value) {
        self.panes
            .push(json!({"id": pane, "kind": "terminal", "terminal": terminal}));
    }

    fn snapshot(&self, version: u64) {
        let doc = json!({
            "format": "helm.bench-snapshot", "version": version, "writtenAt": "2026-09-25T16:52:42Z",
            "workspaces": [{"path": "/x", "name": "x", "state": "mounted",
                "columns": [{"id": "C", "width": 1.0, "slots": [{"id": "S", "height": 1.0,
                    "selectedPaneId": PANE, "panes": self.panes}]}]}],
        });
        write(
            &self.home().join(".helm/bench/snapshot.json"),
            &doc.to_string(),
        );
    }

    fn subagent<L: std::fmt::Display>(
        &self,
        cwd: &str,
        session: &str,
        agent: &str,
        records: &[L],
    ) -> PathBuf {
        let dir = self
            .home()
            .join(".claude/projects")
            .join(bench_sessions::claude::mangle(cwd));
        let dir = dir.join(session).join("subagents");
        write(
            &dir.join(format!("agent-{agent}.meta.json")),
            &json!({"agentType": "general-purpose", "description": format!("task {agent}")})
                .to_string(),
        );
        let path = dir.join(format!("agent-{agent}.jsonl"));
        write(&path, &jsonl(records));
        path
    }

    fn transcript(&self, cwd: &str, session: &str) -> PathBuf {
        let path = self
            .home()
            .join(".claude/projects")
            .join(bench_sessions::claude::mangle(cwd))
            .join(format!("{session}.jsonl"));
        write(
            &path,
            &jsonl(&[json!({"type": "user", "cwd": cwd, "sessionId": session})]),
        );
        path
    }

    fn hosted(&mut self, harness: Harness, id: &str, cwd: &str) {
        self.hosted.push(HostedSession {
            harness,
            id: id.into(),
            cwd: cwd.into(),
            via: HostedVia::Pane {
                pane: PaneId::parse(PANE).unwrap(),
                handle: None,
            },
            recorded_at: "2026-09-25T10:00:00Z".into(),
        });
    }

    fn build_with(&self, cache: &mut Cache, workspace: &Path) -> Built {
        self.snapshot(1);
        let live = self.live.clone();
        let alive = move |pid: u32, claimed: Option<u64>| {
            live.get(&pid)
                .is_some_and(|real| claimed.is_none_or(|c| c == *real))
        };
        let ws = StandardPath::new(&workspace.display().to_string()).unwrap();
        // A stand-in for benchd's rule (an agent that can take a push); the rows only carry it.
        let mailbox = |handle: &str| MailAddress {
            handle: handle.into(),
            wakeable: self.bench.iter().any(|b| b.live && b.handle == handle),
            unread: self.unread.get(handle).copied().unwrap_or(0),
        };
        build(
            &Inputs {
                home: &self.home(),
                helm_bench_dir: &self.home().join(".helm/bench"),
                workspace: &ws,
                bench: &self.bench,
                hosted: &self.hosted,
                hooked: &self.hooked,
                dismissed: &self.dismissed,
                mailbox: &mailbox,
                now_ms: now_ms(),
                now: "2026-09-25T12:00:00Z",
                alive: &alive,
            },
            cache,
        )
    }

    fn build(&self) -> Built {
        self.build_with(&mut Cache::default(), &self.ws())
    }
}

fn row<'a>(built: &'a Built, id: &str) -> Option<&'a SessionRow> {
    built.list.rows.iter().find(|r| r.id == id)
}

fn ids(built: &Built) -> Vec<&str> {
    let mut v: Vec<&str> = built.list.rows.iter().map(|r| r.id.as_str()).collect();
    v.sort();
    v
}

fn activity(r: &SessionRow) -> &Activity {
    match &r.state {
        SessionState::Running { activity } => activity,
        SessionState::Finished { .. } => panic!("{} is finished", r.id),
    }
}

fn pane_owner(pid: u32, session: &str, cwd: &str) -> Value {
    json!({"isLive": true, "foregroundPid": pid,
        "owner": {"runtime": "claude", "pid": pid, "sessionId": session, "cwd": cwd, "handle": "h-1"}})
}

// ---------------------------------------------------------------------------

#[test]
fn a_pane_agent_is_listed_to_focus_and_a_live_agent_outside_helm_is_not_listed_at_all() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    f.claude(100, "in-pane", &ws, json!({"status": "idle"}));
    f.claude(200, "in-zed", &ws, json!({"status": "busy"}));
    f.pane(PANE, pane_owner(100, "in-pane", &ws));
    // Its transcript exists, so only the missing record keeps it out of the finished rows.
    f.transcript(&ws, "in-zed");

    let built = f.build();
    assert_eq!(ids(&built), ["in-pane"]);
    let r = row(&built, "in-pane").unwrap();
    assert_eq!(*activity(r), Activity::Idle);
    let pane = PaneId::parse(PANE).unwrap();
    assert_eq!(r.host, Host::Pane { pane });
    assert_eq!(r.open, OpenAction::FocusPane { pane });
    assert_eq!(r.name.as_deref(), Some("name-in-pane"));
    assert_eq!(
        built.newly_hosted.len(),
        1,
        "the pane agent joins the record"
    );
    assert!(
        built.list.unreadable.is_empty(),
        "{:?}",
        built.list.unreadable
    );
}

#[test]
fn the_foreground_pid_places_an_agent_that_claimed_no_mailbox() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    f.claude(
        100,
        "fg",
        &ws,
        json!({"status": "waiting", "waitingFor": "permission prompt"}),
    );
    f.pane(PANE, json!({"isLive": true, "foregroundPid": 100}));
    let built = f.build();
    let r = row(&built, "fg").unwrap();
    assert_eq!(
        *activity(r),
        Activity::Waiting {
            waiting_for: Some("permission prompt".into())
        }
    );
}

#[test]
fn rows_are_scoped_to_the_repo_and_every_worktree_including_one_outside_it() {
    let mut f = Fixture::new();
    let (ws, inner, outer) = (
        Fixture::s(f.ws()),
        Fixture::s(f.inner()),
        Fixture::s(f.outer()),
    );
    let other = Fixture::s(f.dir.join("other-repo"));
    f.claude(101, "in-repo", &format!("{ws}/daemon"), json!({}));
    f.claude(102, "in-inner", &inner, json!({}));
    f.claude(103, "in-outer", &outer, json!({}));
    f.claude(104, "elsewhere", &other, json!({}));
    for (pid, pane) in [(101, PANE), (102, PANE2)] {
        f.pane(pane, json!({"foregroundPid": pid}));
    }
    f.pane(
        "11111111-1111-1111-1111-111111111111",
        json!({"foregroundPid": 103}),
    );
    f.pane(
        "22222222-2222-2222-2222-222222222222",
        json!({"foregroundPid": 104}),
    );

    let built = f.build();
    assert_eq!(ids(&built), ["in-inner", "in-outer", "in-repo"]);
    assert_eq!(row(&built, "in-repo").unwrap().root, ws);
    assert_eq!(row(&built, "in-inner").unwrap().root, inner);
    assert_eq!(row(&built, "in-outer").unwrap().root, outer);
    assert_eq!(built.list.workspace, ws);

    // Asked from inside the outside worktree, the workspace is still the repo.
    let from_outer = f.build_with(&mut Cache::default(), &f.outer().join("src"));
    assert_eq!(from_outer.list.workspace, ws);
    assert_eq!(ids(&from_outer), ids(&built));
}

fn assistant(stop: Value, blocks: &[&str]) -> Value {
    let content: Vec<Value> = blocks.iter().map(|b| json!({"type": b})).collect();
    json!({"type": "assistant", "message": {"content": content, "stop_reason": stop}})
}

#[test]
fn a_subagent_runs_while_its_tail_is_open_and_is_hidden_once_its_turn_ended() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    let parent_start = f.claude(100, "parent", &ws, json!({"status": "busy"}));
    f.pane(PANE, pane_owner(100, "parent", &ws));
    let old = now_ms() - 30_000; // after the parent started, and quiet for 30 s
    let tool = f.subagent(
        &ws,
        "parent",
        "tool",
        &[assistant(json!(null), &["tool_use"])],
    );
    let result = f.subagent(&ws, "parent", "result", &[json!({"type": "user"})]);
    f.subagent(
        &ws,
        "parent",
        "ended",
        &[assistant(json!("end_turn"), &["text"])],
    );
    let fresh = f.subagent(&ws, "parent", "fresh", &[assistant(json!(null), &["text"])]);
    let quiet = f.subagent(&ws, "parent", "quiet", &[assistant(json!(null), &["text"])]);
    for p in [&tool, &result, &fresh] {
        set_mtime(p, old);
    }
    // Rule 1's quiet window: null stop_reason, 61 s without a write.
    set_mtime(&quiet, now_ms() - 61_000);
    // A trailing summary record says nothing about the turn.
    let summarised = f.subagent(
        &ws,
        "parent",
        "summarised",
        &[
            assistant(json!(null), &["tool_use"]),
            json!({"type": "summary", "summary": "x"}),
        ],
    );
    set_mtime(&summarised, old);
    assert!(parent_start < old);

    let built = f.build();
    let running: Vec<&str> = ids(&built)
        .into_iter()
        .filter(|id| *id != "parent")
        .collect();
    assert_eq!(running, ["fresh", "result", "summarised", "tool"]);
    let r = row(&built, "tool").unwrap();
    assert_eq!(r.parent.as_deref(), Some("parent"));
    assert_eq!(r.name.as_deref(), Some("general-purpose · task tool"));
    assert_eq!(
        r.open,
        OpenAction::Transcript {
            path: tool.display().to_string(),
            parent: "parent".into()
        }
    );
}

#[test]
fn a_subagent_last_written_before_its_parent_process_started_died_with_an_earlier_one() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    let parent_start = f.claude(100, "parent", &ws, json!({}));
    f.pane(PANE, pane_owner(100, "parent", &ws));
    let orphan = f.subagent(
        &ws,
        "parent",
        "orphan",
        &[assistant(json!(null), &["tool_use"])],
    );
    set_mtime(&orphan, parent_start - 7_000);
    let built = f.build();
    assert_eq!(
        ids(&built),
        ["parent"],
        "a tool_use tail alone would say running"
    );
}

#[test]
fn a_subagent_whose_turn_ended_with_tasks_outstanding_is_waiting_on_them() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    f.claude(100, "parent", &ws, json!({}));
    f.pane(PANE, pane_owner(100, "parent", &ws));
    // Key order is Claude's, not serde_json's (which sorts): the launched agent's id comes
    // after the status, and the line's own `agentId` names the writer.
    let launched = |id: &str| -> String {
        format!(
            r#"{{"type":"user","toolUseResult":{{"isAsync":true,"status":"async_launched","agentId":"{id}"}},"agentId":"self"}}"#
        )
    };
    let notified = |id: &str| {
        json!({"type": "user", "message": {"content": format!("<task-notification><task-id>{id}</task-id></task-notification>")}})
        .to_string()
    };
    let end = assistant(json!("end_turn"), &["text"]).to_string();
    f.subagent(
        &ws,
        "parent",
        "orchestrator",
        &[
            launched("a1"),
            json!({"type": "user", "toolUseResult": {"backgroundTaskId": "b1"}}).to_string(),
            json!({"type": "user", "toolUseResult": {"resumedAgentId": "r1"}}).to_string(),
            launched("a2"),
            notified("a2"),
            end.clone(),
        ],
    );
    f.subagent(
        &ws,
        "parent",
        "done",
        &[launched("x"), notified("x"), end.clone()],
    );
    // A background shell the agent stopped itself never reports back.
    f.subagent(
        &ws,
        "parent",
        "stopped",
        &[
            json!({"type": "user", "toolUseResult": {"backgroundTaskId": "b9"}}).to_string(),
            json!({"type": "assistant", "message": {"stop_reason": "tool_use", "content": [
                {"type": "tool_use", "name": "TaskStop", "input": {"task_id": "b9"}}]}})
            .to_string(),
            end.clone(),
        ],
    );
    // A shell Claude ends with the subagent's own final response.
    f.subagent(
        &ws,
        "parent",
        "flagged",
        &[
            r#"{"type":"user","toolUseResult":{"backgroundTaskId":"b8","timedOutAfterMs":120000,"backgroundEndsWithFinalResponse":true}}"#.to_string(),
            end.clone(),
        ],
    );
    // Tasks outstanding, but nothing written for three hours: they ended without reporting
    // back (measured on the operator's machine), so it is not waiting.
    let stale = f.subagent(&ws, "parent", "stale", &[launched("s1"), end.clone()]);
    set_mtime(&stale, now_ms() - 3 * 3_600_000);
    let built = f.build();
    assert_eq!(ids(&built), ["orchestrator", "parent"]);
    assert_eq!(
        *activity(row(&built, "orchestrator").unwrap()),
        Activity::WaitingOnTasks { count: 3 }
    );
}

#[test]
fn a_warm_build_scans_only_what_was_appended() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    f.claude(100, "parent", &ws, json!({}));
    f.pane(PANE, pane_owner(100, "parent", &ws));
    let padding = "x".repeat(4096);
    let mut records: Vec<Value> = (0..512)
        .map(|i| json!({"type": "user", "n": i, "pad": padding}))
        .collect();
    records.push(json!({"type": "user", "toolUseResult": {"backgroundTaskId": "b1"}}));
    records.push(assistant(json!("end_turn"), &["text"]));
    let path = f.subagent(&ws, "parent", "big", &records);
    let size = fs::metadata(&path).unwrap().len();

    let mut cache = Cache::default();
    let first = f.build_with(&mut cache, &f.ws());
    assert!(row(&first, "big").is_some());
    assert_eq!(
        cache.bytes_scanned, size,
        "a cold build scans the file once"
    );

    let appended = format!(
        "{}\n{}\n",
        json!({"type": "user", "message": {"content": "<task-id>b1</task-id>"}}),
        assistant(json!("end_turn"), &["text"])
    );
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    std::io::Write::write_all(&mut file, appended.as_bytes()).unwrap();
    drop(file);

    let second = f.build_with(&mut cache, &f.ws());
    assert!(row(&second, "big").is_none(), "the task reported back");
    assert_eq!(
        cache.bytes_scanned,
        size + appended.len() as u64,
        "a warm build read {} bytes for a {}-byte append",
        cache.bytes_scanned - size,
        appended.len()
    );
}

#[test]
fn a_running_background_job_is_listed_unless_it_has_neither_process_nor_transcript() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    let transcript = f.transcript(&ws, "job-working");
    let job = |f: &Fixture, id: &str, state: Value| {
        write(
            &f.home().join(format!(".claude/jobs/{id}/state.json")),
            &state.to_string(),
        );
    };
    job(
        &f,
        "j1",
        json!({"state": "working", "sessionId": "job-working", "cwd": ws, "name": "Review",
            "linkScanPath": transcript}),
    );
    job(
        &f,
        "j2",
        json!({"state": "blocked", "sessionId": "job-july", "cwd": ws, "detail": "waiting",
            "linkScanPath": format!("{ws}/gone.jsonl")}),
    );
    f.claude(300, "job-asking", &ws, json!({}));
    job(
        &f,
        "j3",
        json!({"state": "needs_reply", "sessionId": "job-asking", "cwd": ws, "needs": "which branch?"}),
    );
    job(
        &f,
        "j4",
        json!({"state": "done", "sessionId": "job-done", "cwd": ws}),
    );

    let built = f.build();
    assert_eq!(ids(&built), ["job-asking", "job-working"]);
    let r = row(&built, "job-working").unwrap();
    assert_eq!(*activity(r), Activity::Busy);
    assert_eq!(r.open, OpenAction::ClaudeAttach { job: "j1".into() });
    assert_eq!(
        *activity(row(&built, "job-asking").unwrap()),
        Activity::Blocked {
            state: "needs_reply".into(),
            detail: Some("which branch?".into())
        }
    );
}

#[test]
fn finished_rows_come_only_from_the_record_and_a_dismissal_hides_one_until_it_finishes_again() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    let t_hosted = f.transcript(&ws, "hosted-claude");
    f.transcript(&ws, "archon-run"); // in scope, never hosted
    f.hosted(Harness::Claude, "hosted-claude", &ws);
    f.hosted(Harness::Claude, "transcript-gone", &ws);
    let pi_dir = f.home().join(".pi/agent/sessions").join(format!(
        "--{}--",
        ws.trim_start_matches('/').replace('/', "-")
    ));
    write(
        &pi_dir.join("2026-09-25T10-00-00-000Z_pi-1.jsonl"),
        &jsonl(&[json!({"type": "session", "version": 3, "id": "pi-1", "cwd": ws})]),
    );
    f.hosted(Harness::Pi, "pi-1", &ws);

    let built = f.build();
    assert_eq!(ids(&built), ["hosted-claude", "pi-1"]);
    let r = row(&built, "hosted-claude").unwrap();
    assert!(matches!(r.state, SessionState::Finished { .. }));
    assert_eq!(r.host, Host::None);
    let OpenAction::Resume { argv, cwd } = &r.open else {
        panic!("{:?}", r.open)
    };
    assert_eq!(argv.first().map(String::as_str), Some("claude"));
    assert!(
        argv.windows(2).any(|w| w == ["--resume", "hosted-claude"]),
        "{argv:?}"
    );
    assert_eq!(cwd, &ws);
    let OpenAction::Resume { argv, .. } = &row(&built, "pi-1").unwrap().open else {
        panic!()
    };
    assert!(
        argv.windows(2).any(|w| w == ["--session-id", "pi-1"]),
        "{argv:?}"
    );

    // Dismissed at or after it finished: hidden.
    let finished = fs::metadata(&t_hosted)
        .unwrap()
        .modified()
        .unwrap()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    f.dismissed.push(Dismissal {
        harness: Harness::Claude,
        id: "hosted-claude".into(),
        at_ms: finished + 10,
    });
    assert_eq!(ids(&f.build()), ["pi-1"]);
    // Resumed and finished again later: back.
    set_mtime(&t_hosted, finished + 60_000);
    assert_eq!(ids(&f.build()), ["hosted-claude", "pi-1"]);

    // Live again: running, never also finished.
    f.claude(100, "hosted-claude", &ws, json!({}));
    f.pane(PANE, pane_owner(100, "hosted-claude", &ws));
    let built = f.build();
    assert_eq!(ids(&built), ["hosted-claude", "pi-1"]);
    assert!(row(&built, "hosted-claude").unwrap().state.is_running());
}

#[test]
fn a_pane_records_what_it_hosted_even_after_the_agent_exited() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    f.transcript(&ws, "gone-agent");
    f.pane(
        PANE,
        json!({"isLive": false, "resumable": {"command": "claude", "session": "gone-agent", "cwd": ws, "isOffered": false}}),
    );
    let built = f.build();
    assert_eq!(built.newly_hosted.len(), 1);
    assert_eq!(built.newly_hosted[0].id, "gone-agent");
    assert_eq!(
        ids(&built),
        ["gone-agent"],
        "a newly recorded session is a finished row in the same build"
    );
}

#[test]
fn a_bench_session_is_listed_to_attach_with_its_registry_status() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    f.claude(400, "bench-claude", &ws, json!({"status": "shell"}));
    f.bench.push(BenchSession {
        session: "s1".into(),
        harness: Harness::Claude,
        runtime_session: Some("bench-claude".into()),
        cwd: ws.clone(),
        pid: 400,
        live: true,
        spawned_ms: now_ms(),
        handle: "worker".into(),
    });
    f.bench.push(BenchSession {
        session: "s2".into(),
        harness: Harness::Codex,
        runtime_session: None,
        cwd: ws.clone(),
        pid: 401,
        live: true,
        spawned_ms: now_ms(),
        handle: "s2".into(),
    });
    let built = f.build();
    assert_eq!(ids(&built), ["bench-claude", "s2"]);
    let r = row(&built, "bench-claude").unwrap();
    assert_eq!(*activity(r), Activity::Shell);
    assert_eq!(
        r.open,
        OpenAction::BenchAttach {
            session: "s1".into()
        }
    );
    assert_eq!(*activity(row(&built, "s2").unwrap()), Activity::Unknown);
}

fn bench_session(
    session: &str,
    runtime: &str,
    cwd: &str,
    handle: &str,
    live: bool,
) -> BenchSession {
    BenchSession {
        session: session.into(),
        harness: Harness::Pi,
        runtime_session: Some(runtime.into()),
        cwd: cwd.into(),
        pid: 500,
        live,
        spawned_ms: now_ms(),
        handle: handle.into(),
    }
}

fn address(handle: &str, wakeable: bool, unread: usize) -> Option<MailAddress> {
    Some(MailAddress {
        handle: handle.into(),
        wakeable,
        unread,
    })
}

#[test]
fn a_bench_session_carries_its_mail_address_and_a_pane_agent_carries_the_one_its_hook_claimed() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    f.bench
        .push(bench_session("s1", "pi-live", &ws, "worker", true));
    f.unread.insert("worker".into(), 2);
    f.claude(100, "in-pane", &ws, json!({}));
    f.pane(PANE, pane_owner(100, "in-pane", &ws));
    f.unread.insert("operator".into(), 3);
    let built = f.build();
    assert_eq!(
        row(&built, "pi-live").unwrap().mail,
        address("worker", true, 2)
    );
    assert_eq!(
        row(&built, "in-pane").unwrap().mail,
        None,
        "a pane agent whose hook claimed nothing has no benchd mailbox"
    );
    assert_eq!(built.list.operator, address("operator", false, 3).unwrap());

    // Its hook claims one (#358): the record now carries the handle, and so does the row,
    // live and after it finished.
    f.hosted.push(HostedSession {
        harness: Harness::Claude,
        id: "in-pane".into(),
        cwd: ws.clone(),
        via: HostedVia::Pane {
            pane: PaneId::parse(PANE).unwrap(),
            handle: Some("ws-pane".into()),
        },
        recorded_at: "2026-09-26T10:00:00Z".into(),
    });
    f.unread.insert("ws-pane".into(), 1);
    assert_eq!(
        row(&f.build(), "in-pane").unwrap().mail,
        address("ws-pane", false, 1)
    );
    f.live.remove(&100);
    f.transcript(&ws, "in-pane");
    let finished = f.build();
    let r = row(&finished, "in-pane").unwrap();
    assert!(!r.state.is_running());
    assert_eq!(r.mail, address("ws-pane", false, 1));
}

#[test]
fn a_finished_row_keeps_the_mailbox_its_session_was_spawned_with() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    let pi_dir = f
        .home()
        .join(".pi/agent/sessions")
        .join(bench_sessions::pi::dir_name(&ws));
    for id in ["pi-dead", "pi-unnamed"] {
        write(
            &pi_dir.join(format!("2026-09-25T10-00-00-000Z_{id}.jsonl")),
            &jsonl(&[json!({"type": "session", "version": 3, "id": id, "cwd": ws})]),
        );
    }
    // Both ran as bench session s1, in two lives of the daemon — ids begin again at s1 after
    // a restart. The daemon holds neither now; only the record remembers them.
    for (id, handle) in [("pi-dead", Some("worker")), ("pi-unnamed", None)] {
        f.hosted.push(HostedSession {
            harness: Harness::Pi,
            id: id.into(),
            cwd: ws.clone(),
            via: HostedVia::Bench {
                session: "s1".into(),
                handle: handle.map(String::from),
            },
            recorded_at: "2026-09-25T10:00:00Z".into(),
        });
    }
    f.unread.insert("worker".into(), 1);
    let built = f.build();
    assert_eq!(ids(&built), ["pi-dead", "pi-unnamed"]);
    assert_eq!(
        row(&built, "pi-dead").unwrap().mail,
        address("worker", false, 1),
        "mail waits for it, and nothing will wake it"
    );
    assert_eq!(
        row(&built, "pi-unnamed").unwrap().mail,
        None,
        "recorded before handles were: no address is invented"
    );

    // A new live session claims the same handle, as `--name worker` may once the first is
    // closed: a send to it now wakes, and the row says so.
    f.bench
        .push(bench_session("s1", "pi-new", &ws, "worker", true));
    let built = f.build();
    assert_eq!(
        row(&built, "pi-dead").unwrap().mail,
        address("worker", true, 1)
    );
    assert_eq!(
        row(&built, "pi-unnamed").unwrap().mail,
        None,
        "never by bench session id, which the new s1 reuses"
    );
}

#[test]
fn a_shape_no_reader_knows_skips_the_row_and_says_which_file() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    f.claude(100, "pondering", &ws, json!({"status": "pondering"}));
    f.pane(PANE, pane_owner(100, "pondering", &ws));
    f.claude(101, "parent", &ws, json!({}));
    f.pane(PANE2, pane_owner(101, "parent", &ws));
    f.subagent(
        &ws,
        "parent",
        "odd",
        &[assistant(json!("vibes"), &["text"])],
    );
    write(
        &f.home().join(".claude/jobs/j9/state.json"),
        &json!({"state": "hibernating", "sessionId": "x", "cwd": ws}).to_string(),
    );
    let pi_dir = f.home().join(".pi/agent/sessions").join(format!(
        "--{}--",
        ws.trim_start_matches('/').replace('/', "-")
    ));
    write(
        &pi_dir.join("t_pi-4.jsonl"),
        &jsonl(&[json!({"type": "session", "version": 4, "id": "pi-4", "cwd": ws})]),
    );
    f.hosted(Harness::Pi, "pi-4", &ws);

    let built = f.build();
    assert_eq!(
        ids(&built),
        ["parent"],
        "every unknown shape skipped its row"
    );
    let mut sources: Vec<&str> = built
        .list
        .unreadable
        .iter()
        .map(|u| u.source.as_str())
        .collect();
    sources.sort();
    assert_eq!(
        sources,
        [
            "claude-job",
            "claude-registry",
            "claude-subagent",
            "pi-session"
        ]
    );
    let registry = built
        .list
        .unreadable
        .iter()
        .find(|u| u.source == "claude-registry")
        .unwrap();
    assert!(registry.why.contains("pondering") && registry.path.ends_with("100.json"));
}

#[test]
fn a_snapshot_version_this_build_does_not_read_is_reported_and_places_no_one() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    f.claude(100, "in-pane", &ws, json!({}));
    f.pane(PANE, pane_owner(100, "in-pane", &ws));
    let mut cache = Cache::default();
    let built = f.build_with(&mut cache, &f.ws());
    assert_eq!(ids(&built), ["in-pane"]);
    f.snapshot(2);
    let alive = |_: u32, _: Option<u64>| true;
    let ws_path = StandardPath::new(&ws).unwrap();
    let built = build(
        &Inputs {
            home: &f.home(),
            helm_bench_dir: &f.home().join(".helm/bench"),
            workspace: &ws_path,
            bench: &[],
            hosted: &[],
            hooked: &[],
            dismissed: &[],
            mailbox: &|h: &str| MailAddress {
                handle: h.into(),
                wakeable: false,
                unread: 0,
            },
            now_ms: now_ms(),
            now: "t",
            alive: &alive,
        },
        &mut cache,
    );
    assert!(built.list.rows.is_empty());
    assert_eq!(built.list.unreadable.len(), 1);
    assert!(built.list.unreadable[0].why.contains("version 2"));
}

#[test]
fn an_agent_whose_hooks_report_is_listed_in_its_pane_once_and_only_while_it_lives() {
    let mut f = Fixture::new();
    let ws = Fixture::s(f.ws());
    let pane = PaneId::parse(PANE2).unwrap();
    let hooked = |harness, session: &str, pid| HookedAgent {
        harness,
        session: session.into(),
        cwd: ws.clone(),
        pane,
        pid,
        activity: Activity::Idle,
        handle: format!("ws-{session}"),
    };
    // A pi agent: no registry, no snapshot record; its hooks are the only source.
    f.live.insert(300, now_ms());
    f.hooked.push(hooked(Harness::Pi, "pi-1", 300));
    // A Claude agent the snapshot already places by its foreground pid: listed once.
    f.claude(100, "in-pane", &ws, json!({"status": "busy"}));
    f.pane(PANE, pane_owner(100, "in-pane", &ws));
    f.hooked.push(hooked(Harness::Claude, "in-pane", 100));
    let built = f.build();
    let pi = row(&built, "pi-1").expect("the pi agent is listed");
    assert_eq!(pi.host, Host::Pane { pane });
    assert_eq!(*activity(pi), Activity::Idle, "as its hooks last said");
    assert_eq!(pi.mail, address("ws-pi-1", false, 0));
    assert_eq!(ids(&built), ["in-pane", "pi-1"], "the Claude agent once");
    // Its process gone (killed: no SessionEnd), it is no longer a running row.
    f.live.remove(&300);
    assert!(row(&f.build(), "pi-1").is_none());
}
