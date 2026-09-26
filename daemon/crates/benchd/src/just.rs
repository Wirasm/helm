//! `just/run` (#356): a recipe from the operator's `<root>/rules/justfile`, run by benchd so it
//! is logged like every other change and dies with the daemon.
//!
//! The recipe is a composition of `bench` verbs, so the run gets `BENCH_DIR` (and
//! `BENCH_SUITE` when set) and every `bench` inside it reaches this daemon. `BENCH_ASKED=1`
//! goes only to a run the operator started: he asked, so its verbs may move his focus. An
//! agent's run gets no such thing, and its verbs are judged as an agent's.
//!
//! Order: `just/started` is logged before the answer, and the answer does not wait for the
//! run. A reaper thread logs `just/finished` with the exit status. The child is on a pipe
//! leash, like the browser: when benchd exits, however it exits, the pipe closes and the
//! wrapper TERMs the run.

use crate::Core;
use bench_wire::{
    Actor, JUST_FINISHED, JUST_STARTED, JustFinished, JustRunArgs, JustStarted, Request,
    is_recipe_name, just_logs_dir, justfile_path,
};
use serde_json::json;
use std::fs::{self, File};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};

/// Why a run did not start: refused (the caller's to fix) or failed (benchd's).
pub enum NotStarted {
    Refused(String),
    Failed(String),
}

/// Where benchd looks for `just` after its own `PATH`: launchd starts it with a minimal one,
/// and Homebrew's prefixes are where `just` lives on the operator's machines.
const FALLBACK_BINS: &[&str] = &["/opt/homebrew/bin", "/usr/local/bin"];

/// The leash. `"$@"` is the `just` command. fd 0 is benchd's pipe: it moves to fd 3 for the
/// watcher, and the run gets /dev/null. EOF on the pipe — benchd gone — TERMs the run.
const WRAPPER: &str = r#"exec 3<&0 </dev/null
"$@" &
c=$!
( read -r _ <&3; kill -TERM "$c" 2>/dev/null ) &
w=$!
wait "$c"
s=$?
kill "$w" 2>/dev/null
exit "$s"
"#;

pub fn run(core: &Arc<Mutex<Core>>, req: &Request) -> Result<JustStarted, NotStarted> {
    let args: JustRunArgs = serde_json::from_value(req.args.clone())
        .map_err(|e| NotStarted::Refused(format!("just/run args: {e}")))?;
    if !is_recipe_name(&args.recipe) {
        return Err(NotStarted::Refused(format!(
            "not a recipe name: {:?} — a recipe is [A-Za-z0-9_-]+",
            args.recipe
        )));
    }
    let asked = req.by == Some(Actor::Operator);
    let mut c = core.lock().unwrap();
    let justfile = justfile_path(&c.root);
    if !justfile.is_file() {
        return Err(NotStarted::Refused(format!(
            "no justfile at {} — write the recipes there",
            justfile.display()
        )));
    }
    let just = find_just().ok_or_else(|| {
        NotStarted::Refused(format!(
            "just is not installed: looked on PATH, then in {}",
            FALLBACK_BINS.join(", ")
        ))
    })?;
    let cwd = working_directory(&c, &args, asked)?;

    let run = format!("run-{}", c.next_seq);
    let logs = just_logs_dir(&c.root);
    fs::create_dir_all(&logs)
        .map_err(|e| NotStarted::Failed(format!("cannot create {}: {e}", logs.display())))?;
    let log_path = logs.join(format!("{run}.log"));
    let log = File::create(&log_path)
        .map_err(|e| NotStarted::Failed(format!("cannot create {}: {e}", log_path.display())))?;
    let err = log
        .try_clone()
        .map_err(|e| NotStarted::Failed(format!("cannot share {}: {e}", log_path.display())))?;

    let mut command = Command::new("/bin/sh");
    command
        .arg("-c")
        .arg(WRAPPER)
        .arg("sh")
        .arg(&just)
        .arg("--justfile")
        .arg(&justfile)
        .arg("--working-directory")
        .arg(&cwd)
        .arg(&args.recipe)
        .args(&args.args)
        .env("BENCH_DIR", &c.root)
        .env_remove("BENCH_ASKED")
        .stdin(Stdio::piped())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(err));
    match &c.suite {
        Some(suite) => command.env("BENCH_SUITE", suite.as_str()),
        None => command.env_remove("BENCH_SUITE"),
    };
    if asked {
        command.env("BENCH_ASKED", "1");
    }
    let mut child = command
        .spawn()
        .map_err(|e| NotStarted::Failed(format!("cannot start {}: {e}", just.display())))?;
    let leash = child.stdin.take();

    let log_str = log_path.display().to_string();
    let started = json!({
        "run": run, "recipe": args.recipe, "by": if asked { "operator" } else { "agent" },
        "cwd": cwd.display().to_string(), "log": log_str,
    });
    if let Err(why) = c.append(JUST_STARTED, started) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(NotStarted::Failed(why));
    }
    drop(c);
    let started = JustStarted { run, log: log_str };
    reap(Arc::clone(core), child, leash, started.clone(), args.recipe);
    Ok(started)
}

/// Waits for the run on a thread of its own and logs how it ended. The leash lives here until
/// then: dropping it early would TERM the run.
fn reap(
    core: Arc<Mutex<Core>>,
    mut child: Child,
    leash: Option<ChildStdin>,
    run: JustStarted,
    recipe: String,
) {
    std::thread::spawn(move || {
        let status = child.wait().ok();
        drop(leash);
        let finished = JustFinished {
            run: run.run,
            recipe,
            exit: status.and_then(|s| s.code()),
            signal: status.and_then(|s| s.signal()),
            log: run.log,
        };
        let _ = core.lock().unwrap().append(JUST_FINISHED, json!(finished));
    });
}

/// The operator's run works where he is: the active workspace. An agent's works where it
/// says, else there too.
fn working_directory(c: &Core, args: &JustRunArgs, asked: bool) -> Result<PathBuf, NotStarted> {
    let active = c.bench.document.active().map(|p| PathBuf::from(p.as_str()));
    let chosen = if asked {
        active
    } else {
        args.cwd.as_ref().map(PathBuf::from).or(active)
    };
    let cwd = chosen.ok_or_else(|| {
        NotStarted::Refused("no workspace is open, so there is nowhere to run it".into())
    })?;
    if !cwd.is_absolute() || !cwd.is_dir() {
        return Err(NotStarted::Refused(format!(
            "{} is not a directory to run in",
            cwd.display()
        )));
    }
    Ok(cwd)
}

fn find_just() -> Option<PathBuf> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path)
        .chain(FALLBACK_BINS.iter().map(PathBuf::from))
        .map(|dir| dir.join("just"))
        .find(|candidate| is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}
