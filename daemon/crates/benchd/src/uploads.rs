//! `browser/upload` (helm #549): a file the operator chose on helm's machine, kept on this one
//! so the browser's file input can take it as a path (`DOM.setFileInputFiles`). Only a helm on
//! another machine sends it; on one machine helm hands Chrome its own path.

use bench_wire::{BrowserUploadArgs, BrowserUploaded, browser_uploads_dir, unbase64};
use serde_json::{Value, json};
use std::fs::{self, DirBuilder};
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Names each upload's folder uniquely within this process.
static NEXT: AtomicU64 = AtomicU64::new(0);

/// Writes the file into a folder of its own under `<root>/browser/uploads` and answers its path.
/// The name is the page's to see, so it must be one path component: no folder, no `..`.
pub fn upload(root: &Path, args: &Value) -> Result<Value, String> {
    let args: BrowserUploadArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("browser/upload args: {e}"))?;
    let name = args.name.as_str();
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\0') {
        return Err(format!("browser/upload: {name:?} is not a file name"));
    }
    let bytes = unbase64(&args.base64)
        .ok_or_else(|| "browser/upload: the bytes are not standard base64".to_string())?;
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let folder =
        browser_uploads_dir(root).join(format!("{stamp}-{}", NEXT.fetch_add(1, Ordering::Relaxed)));
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&folder)
        .map_err(|e| format!("cannot make {}: {e}", folder.display()))?;
    let path = folder.join(name);
    fs::write(&path, bytes).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    Ok(json!(BrowserUploaded {
        path: path.display().to_string()
    }))
}

/// Uploads from an earlier run are no page's any more: the browser that took them ended with it.
pub fn clear(root: &Path) {
    let _ = fs::remove_dir_all(browser_uploads_dir(root));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "bench-uploads-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn an_upload_lands_under_its_own_name_and_two_of_one_name_do_not_collide() {
        let root = root();
        let args = json!({ "name": "report.pdf", "base64": "dXBsb2FkLW1lCg==" });
        let first: BrowserUploaded = serde_json::from_value(upload(&root, &args).unwrap()).unwrap();
        let second: BrowserUploaded =
            serde_json::from_value(upload(&root, &args).unwrap()).unwrap();
        assert_ne!(first.path, second.path);
        for answer in [&first, &second] {
            let path = Path::new(&answer.path);
            assert_eq!(path.file_name().unwrap(), "report.pdf");
            assert!(path.starts_with(browser_uploads_dir(&root)));
            assert_eq!(fs::read(path).unwrap(), b"upload-me\n");
        }
        clear(&root);
        assert!(!browser_uploads_dir(&root).exists());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_name_that_is_a_path_or_bytes_that_are_not_base64_are_refused() {
        let root = root();
        for name in ["", ".", "..", "../escape", "a/b"] {
            let refused = upload(&root, &json!({ "name": name, "base64": "AA==" }));
            assert!(refused.is_err(), "{name:?} was accepted");
        }
        assert!(upload(&root, &json!({ "name": "x", "base64": "not base64!" })).is_err());
        assert!(
            !browser_uploads_dir(&root).exists(),
            "a refusal writes nothing"
        );
        fs::remove_dir_all(&root).unwrap();
    }
}
