---
name: post-canvas
description: Render a finished archon-video video as a helm canvas post preview — the video playing inline beside its YouTube/TikTok/Instagram copy, hashtags, alt text, script, review frames and technical QC. Use when asked to preview a post, show what a video would look like posted, open a video canvas, review generated video copy, or see the latest short.
---

# Post canvas

Renders a video stored by the [archon-video](https://github.com/Wirasm/archon-video) workflow
pack as a post preview: the MP4 playing inline, next to the exact copy that would ship with it.

**This skill renders. It does not write copy.** Title, narration, captions, hashtags and QC all come
from the files the pack's `store` node wrote. If one is missing the driver refuses rather than
filling the gap — a preview that invents its own caption is worse than no preview, because you
would ship what you saw.

The driver is `build-canvas.mjs` beside this file. It pushes through `helm-canvas`'s `push.sh`,
which must sit beside this skill (it does in helm's repo and in `~/.claude/skills`).

## Run it

From the video project's directory (the repo you run `archon workflow run video-make` in):

```bash
# --- PRP store resolver (canonical; keep byte-identical across skills) ---
# Adopt the store that already records this root; mint a key only when none does.
_gd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
case "$_gd" in */.git) _root="${_gd%/.git}" ;; "") _root="$PWD" ;; *) _root="$_gd" ;; esac
_root="$(cd "$_root" && pwd -P)"
_name="$(basename "$_root" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
_home="${PRP_HOME:-$HOME/.prp}"
_hit="$(grep -lsF "\"path\": \"$_root\"" "$_home"/*/project.json 2>/dev/null | head -1)"
PRP_DIR="${_hit%/project.json}"
[ -n "$PRP_DIR" ] || PRP_DIR="$_home/${_name:-project}-$(printf %s "$_root" | git hash-object --stdin | cut -c1-8)"
mkdir -p "$PRP_DIR"; [ -f "$PRP_DIR/project.json" ] || printf '{"path": "%s", "name": "%s"}\n' "$_root" "${_name:-project}" > "$PRP_DIR/project.json"
node ~/.claude/skills/post-canvas/build-canvas.mjs --store "$PRP_DIR" latest
```

The first block is prp's canonical store resolver, copied verbatim. It picks the `~/.prp/<key>/`
store of the project you are in, so the preview lands beside that project's other artifacts. The
driver has no default store and refuses without `--store`.

That renders the most recent stored video into `$PRP_DIR/post-<run-id-prefix>/canvas.html`,
prints the path and pushes it to a canvas tab. Instead of `latest`:

- a run id renders that run;
- a path (anything with a `/`) renders that stored-video directory. Use it when the pack's
  `output.dir` moved the library out of Archon's state folder.

Add `--no-push` to build without opening a tab.

## Where it reads from

archon-video stores each video at `$STATE_DIR/video/videos/<run-id>/` and repoints a `latest` link
there after every store. The driver finds `$STATE_DIR` the way Archon lays it out
(`$ARCHON_HOME`, default `~/.archon`, then `workspaces/<project>/state`) and tries, in order:

1. `<owner>/<repo>` from the repo's `origin` remote (a codebase registered from GitHub),
2. `_local/<repo-dir-name>` (registered without a remote),
3. `_cwd/<repo-dir-name>` (run from an unregistered directory).

It uses the first that has a `video/videos` folder. Set `STATE_DIR` to skip the guess.

Per video it requires `video.mp4`, `manifest.json`, `script.json`, `copy.json` and `qc.json`, and
shows every `frames/review-*.jpg` contact sheet.

## What the page shows

- The video inline, with duration, resolution, fps, loudness and the voice used
- **YouTube**: title, the description with the real `…more` fold after its first line, and tags
- **TikTok**: caption with a character count against the 150 limit
- **Instagram**: caption plus hashtag chips
- **Alt text**
- **Script**: the opening overlay, the narration and the opening shot
- **Brief** and the editor's summary of the edit
- **Technical QC**: every timestamped flag (silence, black or frozen frames,
  shots that look like a recent video)
- The review contact sheets, 12 labelled frames each

## Verify a render without helm

The artifact is self-contained HTML with its data baked in, so a plain renderer can check layout:

```bash
node ~/.claude/skills/post-canvas/build-canvas.mjs --store "$PRP_DIR" --no-push
qlmanage -t -s 1300 -o /tmp "$PRP_DIR"/post-<id>/canvas.html
```

Then look at `/tmp/canvas.html.png`. Quick Look renders layout and CSS but **does not run
JavaScript**, which is why the driver bakes data in rather than fetching it.

## Gotchas

- **Data is baked in, not fetched.** Do not turn it into a `fetch('./copy.json')`: it breaks the
  Quick Look check for no gain.
- **`<meta charset="utf-8">` is required.** Without it em dashes render as `â€"` in Quick Look.
- **Siblings are copied, not symlinked.** The canvas read boundary follows symlinks, so a link
  pointing outside the artifact directory is refused. The driver copies the MP4 and sheets in, and
  wipes its output directory on every render so repeats do not pile up.
- **`--no-push` still writes the artifact.** It only skips opening the tab.
- **Pushing the same path again re-renders in place** without stealing focus, but resets the page's
  scroll position.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `--store … is required` | Run the resolver block above first, or pass an existing absolute store dir. |
| `no archon-video library — looked in: …` | Not run from the video project, or nothing stored yet. `cd` there, or set `STATE_DIR`. |
| `… is missing <file>` | Not a finished archon-video run. A failed `store` leaves `.<run-id>.partial`, which is never picked. |
| `push failed (exit 8)` or `(exit 6)` | Not in a helm pane. Use `--no-push` and hand the operator the printed path. |
| `helm-canvas push.sh not found` | `helm-canvas` is not installed beside this skill. |

## Installing

The skill lives in helm's repo at `.claude/skills/post-canvas/`. Link it into `~/.claude/skills`
the same way as `helm-canvas`, replacing any older unlinked copy there:

```bash
rm -rf ~/.claude/skills/post-canvas
ln -s <helm-checkout>/.claude/skills/post-canvas ~/.claude/skills/post-canvas
```

Its gate is `bash .claude/skills/post-canvas/test.sh`.
