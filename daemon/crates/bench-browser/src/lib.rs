//! The shared browser — one Chromium per bench root, owned by the daemon (#350).
//!
//! This crate knows how to find a Chromium, what flags to give it, how to start it so
//! it cannot outlive its owner, and where it says it is listening. It knows nothing
//! about sockets, events or restarts: those are the daemon's, the same split as
//! `bench-mail`.
//!
//! What the daemon does NOT do with this browser is automate it. Agents drive it with
//! Playwright (`playwright-cli attach --cdp=<endpoint.cdp>`), helm renders it over its
//! own CDP websocket, and the daemon is in neither path — it starts, supervises and
//! publishes. That is the spike's architecture (`spike-shared-browser-cdp.md`).
//!
//! Two mechanisms carry the lifecycle rules:
//!
//! - **Port 0 + `DevToolsActivePort`.** Chromium picks a free port and writes it, with
//!   the browser websocket path, into `<profile>/DevToolsActivePort` once its debugging
//!   server is listening. So two suites never collide on a port, and "ready" is a fact
//!   the browser reports rather than a sleep.
//! - **A pipe is the leash.** macOS has no parent-death signal, and the repo's rule is
//!   that anything spawned must die without its spawner (#291: twelve orphaned burners,
//!   nine hours). Chromium runs under a small `sh` wrapper whose stdin is a pipe the
//!   daemon holds. When the daemon dies — cleanly, by SIGTERM, or by SIGKILL — the
//!   kernel closes that pipe, the wrapper's watcher reads EOF and TERMs Chromium. A
//!   deliberate stop closes the same pipe, so there is one shutdown path, not two.

use bench_wire::{
    BROWSER_ENDPOINT_FORMAT, BROWSER_ENDPOINT_VERSION, BROWSER_READY_WAIT, BrowserConfig,
    BrowserEndpoint, BrowserMode, browser_config_path, browser_dir, browser_endpoint_path,
    browser_profile_dir,
};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// Why a start did not happen, split the way the exit codes are: a refusal is
/// something the caller can fix (a config, an install), a failure is the browser not
/// coming up.
#[derive(Debug)]
pub enum LaunchError {
    Refused(String),
    Failed(String),
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Read `<root>/browser/config.json`. Absent is the default; unreadable or unknown keys
/// refuse naming the file, because a config the operator wrote and the daemon ignored
/// is the silent fallback this workspace refuses everywhere else.
pub fn read_config(root: &Path) -> Result<BrowserConfig, LaunchError> {
    let path = browser_config_path(root);
    let text = match fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(BrowserConfig::default()),
        Err(e) => {
            return Err(LaunchError::Refused(format!(
                "cannot read {}: {e}",
                path.display()
            )));
        }
    };
    serde_json::from_str(&text).map_err(|e| {
        LaunchError::Refused(format!(
            "{} is not a browser config ({e}) — keys are \"binary\" and \"args\"",
            path.display()
        ))
    })
}

/// Where to look for a browser when the config names none, best first: Google Chrome
/// where it is installed (the operator's ruling on #350: real Chrome runs the Claude in
/// Chrome and Codex extensions, and Google trusts it), then the newest Playwright
/// Chrome for Testing — the browser the spike proved, and the fallback on a machine
/// without Chrome. A `chromium_headless_shell-*` directory is never a candidate: it
/// cannot show a window for `browser/setup`.
pub fn default_candidates(home: &Path, playwright_browsers_path: Option<&str>) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = if cfg!(target_os = "macos") {
        vec![
            PathBuf::from("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            home.join("Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        ]
    } else {
        vec![
            PathBuf::from("/usr/bin/google-chrome"),
            PathBuf::from("/usr/bin/google-chrome-stable"),
        ]
    };
    let cache = match playwright_browsers_path {
        Some(p) => PathBuf::from(p),
        None if cfg!(target_os = "macos") => home.join("Library/Caches/ms-playwright"),
        None => home.join(".cache/ms-playwright"),
    };
    let mut revisions: Vec<(u64, PathBuf)> = fs::read_dir(&cache)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            let rev = name.strip_prefix("chromium-")?.parse::<u64>().ok()?;
            Some((rev, entry.path()))
        })
        .collect();
    revisions.sort_by(|a, b| b.0.cmp(&a.0));
    const LAYOUTS: &[&str] = &[
        "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        "chrome-mac/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        "chrome-linux64/chrome",
        "chrome-linux/chrome",
    ];
    for (_, dir) in &revisions {
        out.extend(LAYOUTS.iter().map(|layout| dir.join(layout)));
    }
    out
}

/// The browser to run: the config's `binary` when set — refused if it is not a file,
/// never quietly replaced by a default — else the first candidate that exists.
pub fn resolve_binary(
    config: &BrowserConfig,
    candidates: &[PathBuf],
    root: &Path,
) -> Result<PathBuf, LaunchError> {
    if let Some(b) = &config.binary {
        let p = PathBuf::from(b);
        if !p.is_file() {
            return Err(LaunchError::Refused(format!(
                "binary {b:?} in {} is not a file",
                browser_config_path(root).display()
            )));
        }
        return Ok(p);
    }
    candidates
        .iter()
        .find(|c| c.is_file())
        .cloned()
        .ok_or_else(|| {
            LaunchError::Refused(format!(
                "no browser found — install Google Chrome, or Chrome for Testing with `npx playwright install chromium`, or set \"binary\" in {}",
                browser_config_path(root).display()
            ))
        })
}

/// The default flags a config's `args` replaces. The user agent is the load-bearing
/// one: Google refuses sign-in to `HeadlessChrome` ("This browser or app may not be
/// secure") — measured on Chrome for Testing 147 in the spike and again on Google
/// Chrome 153 for #350, where the override moved the same flow on to the account
/// lookup. So the browser presents as the Chrome it is, at its own major version, read
/// from `--version` rather than typed here to go stale.
///
/// `--remote-allow-origins=*` is kept on the operator's ruling. Neither consumer needs
/// it today — helm's pane is a native websocket and Playwright's is node's, and neither
/// sends an `Origin` — but a page-based viewer would, and the spike's did.
pub fn default_args(version_output: &str) -> Result<Vec<String>, String> {
    let major = version_output
        .split_whitespace()
        .find(|tok| {
            tok.split('.').count() >= 2
                && tok
                    .split('.')
                    .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
        })
        .and_then(|v| v.split('.').next())
        .ok_or_else(|| {
            format!(
                "cannot read a version from `--version` output {:?} — set \"args\" in the browser config to choose flags yourself",
                version_output.trim()
            )
        })?;
    let platform = if cfg!(target_os = "macos") {
        "Macintosh; Intel Mac OS X 10_15_7"
    } else {
        "X11; Linux x86_64"
    };
    Ok(vec![
        "--headless=new".into(),
        format!(
            "--user-agent=Mozilla/5.0 ({platform}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{major}.0.0.0 Safari/537.36"
        ),
        "--remote-allow-origins=*".into(),
        "--window-size=1280,800".into(),
    ])
}

/// The flags the daemon owns. They go LAST so they win over anything a config's
/// `args` says about the same switch: the profile must be the bench's, and the port
/// must be the one the daemon reads back. `mock_keychain` is `BrowserConfig`'s field,
/// forced on under a HOME that is not the account's own (`is_accounts_own_home`).
pub fn owned_args(profile: &Path, mock_keychain: bool) -> Vec<String> {
    let mut args = vec![
        format!("--user-data-dir={}", profile.display()),
        "--remote-debugging-port=0".into(),
        "--no-first-run".into(),
        "--no-default-browser-check".into(),
    ];
    if mock_keychain {
        args.push("--use-mock-keychain".into());
        args.push("--password-store=basic".into());
    }
    args
}

/// Is `home` the home directory the user database records for this account?
///
/// Chrome on macOS stores its encryption key in the login keychain it finds under
/// `$HOME/Library/Keychains`. Under any other HOME there is none, and macOS puts up
/// "Keychain Not Found … Reset To Defaults" — a dialog whose default button would reset
/// the operator's real keychains. That happened once (#350: a conformance test reached
/// the real Chrome under a temp HOME). An answer this cannot get counts as "not his".
pub fn is_accounts_own_home(home: &Path) -> bool {
    let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut buf = vec![0 as libc::c_char; 16 * 1024];
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    let rc = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            &mut pwd,
            buf.as_mut_ptr(),
            buf.len(),
            &mut result,
        )
    };
    if rc != 0 || result.is_null() || pwd.pw_dir.is_null() {
        return false;
    }
    let dir = unsafe { std::ffi::CStr::from_ptr(pwd.pw_dir) };
    let own = PathBuf::from(std::ffi::OsStr::from_bytes(dir.to_bytes()));
    match (fs::canonicalize(&own), fs::canonicalize(home)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// Run `<binary> --version`, bounded — a binary that hangs here must not hang a start.
fn read_version(binary: &Path) -> Result<String, LaunchError> {
    let mut child = Command::new(binary)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| LaunchError::Failed(format!("cannot run {}: {e}", binary.display())))?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(LaunchError::Failed(format!(
                    "{} --version did not answer within 5s",
                    binary.display()
                )));
            }
        }
    }
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = std::io::Read::read_to_string(&mut stdout, &mut out);
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// The running browser
// ---------------------------------------------------------------------------

/// The leash, as a script. `$0` is the browser, `"$@"` its flags. fd 0 is the daemon's
/// pipe: it moves to fd 3 for the watcher and the browser gets /dev/null. The first
/// line on stdout is the browser's pid; everything else goes to the log. When the
/// browser is gone the wrapper removes the endpoint file itself, so a daemon killed
/// outright still leaves no endpoint naming a dead browser.
const WRAPPER: &str = r#"exec 3<&0 </dev/null
"$0" "$@" >&2 &
c=$!
echo "$c"
exec >&2
( read -r _ <&3; kill -TERM "$c" 2>/dev/null ) &
w=$!
wait "$c"
s=$?
rm -f "$BENCH_BROWSER_ENDPOINT"
kill "$w" 2>/dev/null
exit "$s"
"#;

/// One running browser. The daemon holds it in an `Arc`; the thread started by
/// `launch` owns the wrapper `Child` and is the only thing that waits on it.
pub struct Browser {
    pub endpoint: BrowserEndpoint,
    wrapper_pid: u32,
    leash: Mutex<Option<ChildStdin>>,
    exit: Mutex<Option<ExitInfo>>,
    exited: Condvar,
    endpoint_path: PathBuf,
}

/// How a browser ended. `requested` separates a stop the daemon asked for from a
/// crash — the supervisor restarts only the second.
#[derive(Debug, Clone)]
pub struct ExitInfo {
    pub pid: u32,
    pub mode: BrowserMode,
    pub code: Option<i32>,
    pub requested: bool,
}

fn signal(pid: u32, sig: i32) {
    // Only ever pids this process spawned and has not yet reaped, or the browser's own
    // pid reported by that wrapper — never a pattern (repo rule).
    unsafe {
        libc::kill(pid as libc::pid_t, sig);
    }
}

impl Browser {
    /// Start a browser for `root` and return once it is listening. `on_exit` runs on
    /// the supervising thread when the browser ends, for whatever reason, after the
    /// endpoint file is gone.
    pub fn launch(
        root: &Path,
        home: &Path,
        candidates: &[PathBuf],
        mode: BrowserMode,
        started_at: String,
        on_exit: Box<dyn FnOnce(ExitInfo) + Send>,
    ) -> Result<Arc<Browser>, LaunchError> {
        let config = read_config(root)?;
        let binary = resolve_binary(&config, candidates, root)?;
        let mut args = match &config.args {
            Some(a) => a.clone(),
            None => default_args(&read_version(&binary)?).map_err(LaunchError::Failed)?,
        };
        if mode == BrowserMode::Setup {
            // The same profile and flags, in a real window.
            args.retain(|a| !a.starts_with("--headless"));
        }
        let dir = browser_dir(root);
        let profile = browser_profile_dir(root);
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&profile)
            .map_err(|e| {
                LaunchError::Failed(format!("cannot create {}: {e}", profile.display()))
            })?;
        let mock_keychain = config.mock_keychain.unwrap_or(false) || !is_accounts_own_home(home);
        args.extend(owned_args(&profile, mock_keychain));
        link_native_messaging_hosts(&profile, home);

        // A port file from an earlier run would be read as this run's answer.
        let port_file = profile.join("DevToolsActivePort");
        let _ = fs::remove_file(&port_file);
        let log_path = dir.join("chrome.log");
        let log = File::create(&log_path).map_err(|e| {
            LaunchError::Failed(format!("cannot create {}: {e}", log_path.display()))
        })?;

        let endpoint_path = browser_endpoint_path(root);
        let mut child = Command::new("/bin/sh")
            .env("BENCH_BROWSER_ENDPOINT", &endpoint_path)
            .arg("-c")
            .arg(WRAPPER)
            .arg(&binary)
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(log))
            .spawn()
            .map_err(|e| LaunchError::Failed(format!("cannot start the browser wrapper: {e}")))?;
        let wrapper_pid = child.id();
        let leash = child.stdin.take();

        // From here, every failure must take down what it started.
        let abandon =
            |mut child: Child, leash: Option<ChildStdin>, pid: Option<u32>, why: String| {
                drop(leash);
                if let Some(p) = pid {
                    signal(p, 9);
                }
                let _ = child.kill();
                let _ = child.wait();
                LaunchError::Failed(format!("{why} — see {}", log_path.display()))
            };

        let mut pid_line = String::new();
        let read = child
            .stdout
            .take()
            .map(|out| BufReader::new(out).read_line(&mut pid_line));
        let pid = match (read, pid_line.trim().parse::<u32>()) {
            (Some(Ok(_)), Ok(p)) => p,
            _ => {
                return Err(abandon(
                    child,
                    leash,
                    None,
                    "the browser wrapper did not report a pid".into(),
                ));
            }
        };

        let deadline = Instant::now() + BROWSER_READY_WAIT;
        let (port, ws_path) = loop {
            if let Some(answer) = read_port_file(&port_file) {
                break answer;
            }
            if let Ok(Some(status)) = child.try_wait() {
                return Err(abandon(
                    child,
                    leash,
                    None,
                    format!(
                        "{} exited ({status}) before it was listening",
                        binary.display()
                    ),
                ));
            }
            if Instant::now() >= deadline {
                return Err(abandon(
                    child,
                    leash,
                    Some(pid),
                    format!(
                        "{} did not report a debugging port within {}s",
                        binary.display(),
                        BROWSER_READY_WAIT.as_secs()
                    ),
                ));
            }
            std::thread::sleep(Duration::from_millis(50));
        };

        let endpoint = BrowserEndpoint {
            format: BROWSER_ENDPOINT_FORMAT.into(),
            version: BROWSER_ENDPOINT_VERSION,
            cdp: format!("http://127.0.0.1:{port}"),
            ws: format!("ws://127.0.0.1:{port}{ws_path}"),
            port,
            pid,
            mode,
            binary: binary.display().to_string(),
            profile: profile.display().to_string(),
            started_at,
        };
        if let Err(e) = write_endpoint(&endpoint_path, &endpoint) {
            return Err(abandon(child, leash, Some(pid), e));
        }

        let browser = Arc::new(Browser {
            endpoint,
            wrapper_pid,
            leash: Mutex::new(leash),
            exit: Mutex::new(None),
            exited: Condvar::new(),
            endpoint_path,
        });
        let supervised = Arc::clone(&browser);
        std::thread::spawn(move || {
            let status = child.wait();
            // A stop drops the leash before the wrapper can exit, so an absent leash
            // here means the daemon asked.
            let requested = supervised.leash.lock().unwrap().is_none();
            let info = ExitInfo {
                pid: supervised.endpoint.pid,
                mode: supervised.endpoint.mode,
                code: status.ok().and_then(|s: ExitStatus| s.code()),
                requested,
            };
            let _ = fs::remove_file(&supervised.endpoint_path);
            *supervised.exit.lock().unwrap() = Some(info.clone());
            supervised.exited.notify_all();
            on_exit(info);
        });
        Ok(browser)
    }

    pub fn is_running(&self) -> bool {
        self.exit.lock().unwrap().is_none()
    }

    /// Close the leash and wait for the browser to go. A browser that ignores TERM for
    /// `grace` is killed, and so is its wrapper. Returns whether it was running.
    pub fn stop(&self, grace: Duration) -> bool {
        let was_running = self.is_running();
        drop(self.leash.lock().unwrap().take());
        let guard = self.exit.lock().unwrap();
        let (guard, timeout) = self
            .exited
            .wait_timeout_while(guard, grace, |e| e.is_none())
            .unwrap();
        if timeout.timed_out() && guard.is_none() {
            drop(guard);
            signal(self.endpoint.pid, 9);
            signal(self.wrapper_pid, 9);
            let guard = self.exit.lock().unwrap();
            let _ = self
                .exited
                .wait_timeout_while(guard, Duration::from_secs(2), |e| e.is_none());
        }
        was_running
    }
}

/// Give the bench profile the native-messaging hosts the operator's everyday Chrome
/// already has, by linking its directory.
///
/// Chrome looks for user-level hosts under `<user-data-dir>/NativeMessagingHosts`, not
/// under a fixed per-user path — measured for #350: a host manifest in the profile's own
/// directory was launched by an extension in a `--headless=new` browser, and the same
/// manifest in the default location was not. Claude Code and Codex install their hosts
/// into the everyday Chrome's directory, so without this link their extensions would
/// load in the bench profile and never reach the CLI they exist to talk to.
///
/// Only when the profile has no entry of its own: a directory the operator made there is
/// his, and is left alone.
pub fn link_native_messaging_hosts(profile: &Path, home: &Path) {
    let everyday = if cfg!(target_os = "macos") {
        home.join("Library/Application Support/Google/Chrome/NativeMessagingHosts")
    } else {
        home.join(".config/google-chrome/NativeMessagingHosts")
    };
    let link = profile.join("NativeMessagingHosts");
    if everyday.is_dir() && fs::symlink_metadata(&link).is_err() {
        let _ = std::os::unix::fs::symlink(&everyday, &link);
    }
}

/// `DevToolsActivePort` is two lines — the port, then the browser websocket path —
/// and only a complete file is an answer.
fn read_port_file(path: &Path) -> Option<(u16, String)> {
    let text = fs::read_to_string(path).ok()?;
    let mut lines = text.lines();
    let port = lines.next()?.trim().parse::<u16>().ok()?;
    let ws_path = lines.next()?.trim().to_string();
    (port != 0 && ws_path.starts_with('/')).then_some((port, ws_path))
}

/// Temp file + rename, 0600: a reader never sees half an endpoint.
fn write_endpoint(path: &Path, endpoint: &BrowserEndpoint) -> Result<(), String> {
    let tmp = path.with_extension("json.tmp");
    let body = serde_json::to_vec_pretty(endpoint).map_err(|e| format!("encode endpoint: {e}"))?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    file.write_all(&body)
        .and_then(|()| file.write_all(b"\n"))
        .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    fs::rename(&tmp, path).map_err(|e| format!("cannot publish {}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_user_agent_carries_the_binarys_own_major_and_never_headless() {
        for (out, major) in [
            ("Google Chrome for Testing 147.0.7727.15 \n", "147"),
            ("Google Chrome 139.0.7258.66", "139"),
            ("Chromium 120.0.6099.0 built on Debian", "120"),
        ] {
            let args = default_args(out).unwrap();
            let ua = args
                .iter()
                .find(|a| a.starts_with("--user-agent="))
                .unwrap();
            assert!(ua.contains(&format!("Chrome/{major}.0.0.0")), "{ua}");
            assert!(!ua.contains("Headless"), "{ua}");
            assert!(args.contains(&"--headless=new".to_string()));
        }
    }

    #[test]
    fn with_no_browser_anywhere_the_refusal_names_every_way_to_get_one() {
        let root = Path::new("/r");
        match resolve_binary(
            &BrowserConfig::default(),
            &[PathBuf::from("/no/chrome")],
            root,
        ) {
            Err(LaunchError::Refused(why)) => {
                assert!(why.contains("Google Chrome"), "{why}");
                assert!(why.contains("npx playwright install chromium"), "{why}");
                assert!(why.contains("/r/browser/config.json"), "{why}");
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    #[test]
    fn the_profile_borrows_the_everyday_native_hosts_unless_it_has_its_own() {
        let home = std::env::temp_dir().join(format!("bbn-{}", std::process::id()));
        let everyday = if cfg!(target_os = "macos") {
            home.join("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        } else {
            home.join(".config/google-chrome/NativeMessagingHosts")
        };
        fs::create_dir_all(&everyday).unwrap();
        let linked = home.join("p1");
        fs::create_dir_all(&linked).unwrap();
        link_native_messaging_hosts(&linked, &home);
        assert_eq!(
            fs::read_link(linked.join("NativeMessagingHosts")).unwrap(),
            everyday
        );

        let own = home.join("p2");
        fs::create_dir_all(own.join("NativeMessagingHosts")).unwrap();
        link_native_messaging_hosts(&own, &home);
        assert!(
            fs::read_link(own.join("NativeMessagingHosts")).is_err(),
            "his directory is left alone"
        );
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn a_home_that_is_not_the_accounts_own_is_never_mistaken_for_it() {
        assert!(!is_accounts_own_home(&std::env::temp_dir()));
        assert!(!is_accounts_own_home(Path::new("/no/such/home")));
    }

    #[test]
    fn a_version_that_cannot_be_read_says_how_to_choose_flags_instead() {
        let err = default_args("something went wrong").unwrap_err();
        assert!(err.contains("\"args\""), "{err}");
    }

    #[test]
    fn a_config_key_nobody_reads_is_refused_not_ignored() {
        let dir = std::env::temp_dir().join(format!("bbr-{}", std::process::id()));
        fs::create_dir_all(browser_dir(&dir)).unwrap();
        fs::write(browser_config_path(&dir), r#"{"binnary": "/x"}"#).unwrap();
        match read_config(&dir) {
            Err(LaunchError::Refused(why)) => assert!(why.contains("config.json"), "{why}"),
            other => panic!("expected a refusal, got {other:?}"),
        }
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn only_a_complete_port_file_is_an_answer() {
        let dir = std::env::temp_dir().join(format!("bbp-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let f = dir.join("DevToolsActivePort");
        fs::write(&f, "50033\n").unwrap();
        assert_eq!(read_port_file(&f), None);
        fs::write(&f, "50033\n/devtools/browser/abc\n").unwrap();
        assert_eq!(
            read_port_file(&f),
            Some((50033, "/devtools/browser/abc".into()))
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_newest_playwright_chromium_wins_and_a_headless_shell_never_does() {
        let home = std::env::temp_dir().join(format!("bbh-{}", std::process::id()));
        let cache = home.join("pw");
        for rev in [
            "chromium-1200",
            "chromium-1217",
            "chromium_headless_shell-1300",
        ] {
            let bin = cache.join(rev).join("chrome-linux64/chrome");
            fs::create_dir_all(bin.parent().unwrap()).unwrap();
            fs::write(&bin, "").unwrap();
        }
        let candidates = default_candidates(&home, Some(cache.to_str().unwrap()));
        // Google Chrome comes first whatever this machine has installed.
        assert!(
            candidates[0]
                .to_string_lossy()
                .to_lowercase()
                .contains("google")
        );
        let cft: Vec<PathBuf> = candidates
            .into_iter()
            .filter(|c| c.starts_with(&cache))
            .collect();
        let got = resolve_binary(&BrowserConfig::default(), &cft, &home).unwrap();
        assert!(
            got.to_string_lossy().contains("chromium-1217"),
            "{}",
            got.display()
        );
        fs::remove_dir_all(&home).unwrap();
    }
}
