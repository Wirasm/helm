#!/usr/bin/env node
/**
 * Build a helm canvas previewing a video stored by the archon-video pack, as it
 * would appear when posted.
 *
 * This renderer INVENTS NOTHING. Title, narration, post copy and QC all come
 * from the files the pack's `store` node wrote. Every one of them is required:
 * a preview that fills a gap with a plausible caption is worse than no preview,
 * because you would ship what you saw.
 *
 * Data is baked into the HTML at build time rather than fetched at runtime, so
 * the page is self-contained and renders in a dumb previewer (qlmanage) as well
 * as in helm.
 *
 * Usage:
 *   node build-canvas.mjs --store <prp-store-dir> [latest | <run-id> | <stored-video-dir>] [--no-push]
 */

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// The bench CLI puts the page on the bench (`bench open`); $BENCH names it when it is
// not on PATH.
const BENCH = process.env.BENCH || "bench";

// Every file store.py writes that this page reads.
const REQUIRED = ["video.mp4", "manifest.json", "script.json", "copy.json", "qc.json"];

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

function git(...args) {
  try {
    return execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return "";
  }
}

/**
 * The Archon state dirs this project could own, in the order Archon would pick
 * them (packages/paths/src/archon-paths.ts): `<owner>/<repo>` for a codebase
 * registered from a GitHub remote, `_local/<name>` for one registered without,
 * `_cwd/<name>` for a run from an unregistered directory.
 */
function stateDirCandidates() {
  if (process.env.STATE_DIR) return [process.env.STATE_DIR];
  const home = process.env.ARCHON_HOME || path.join(os.homedir(), ".archon");
  const common = git("rev-parse", "--path-format=absolute", "--git-common-dir");
  const root = common.endsWith("/.git") ? path.dirname(common) : process.cwd();
  const name = path.basename(root);
  const roots = [];
  const remote = git("-C", root, "remote", "get-url", "origin").match(/[:/]([^/:]+)\/([^/]+?)(?:\.git)?$/);
  if (remote) roots.push(path.join(remote[1], remote[2]));
  roots.push(path.join("_local", name), path.join("_cwd", name.replace(/[^a-zA-Z0-9_-]/g, "_") || "_"));
  return roots.map((r) => path.join(home, "workspaces", r, "state"));
}

function resolveVideoDir(arg) {
  // A path names a stored video directly — the route for a pack whose
  // `output.dir` moved the library out of Archon's state folder.
  if (arg?.includes("/")) return path.resolve(arg);

  const candidates = stateDirCandidates().map((s) => path.join(s, "video/videos"));
  const lib = candidates.find((c) => fs.existsSync(c));
  if (!lib) die(`no archon-video library — looked in:\n  ${candidates.join("\n  ")}`);

  if (!arg || arg === "latest") {
    // store.py repoints `latest` atomically after every store; mtime is not a substitute.
    const link = path.join(lib, "latest");
    if (!fs.existsSync(link)) die(`no latest link in ${lib}`);
    return fs.realpathSync(link);
  }
  return path.join(lib, arg);
}

const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const esc = (s) =>
  String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// ---------------------------------------------------------------- page

function renderPage({ manifest, script, copy, qc, sheets, runId }) {
  const m = qc.measurements;
  const tags = copy.hashtags.map((h) => `<span class="tag">#${esc(h)}</span>`).join("");
  const ytTags = copy.youtube_tags.map(esc).join(", ");
  const flags = qc.flags.length
    ? qc.flags.map((f) => `<tr><td>${f.t.toFixed(1)}s</td><td class="warn">${esc(f.issue)}</td></tr>`).join("")
    : `<tr><td>flags</td><td class="ok">none</td></tr>`;
  const sheetImgs = sheets.map((f) => `<img src="./${esc(f)}" alt="">`).join("");

  // YouTube folds the description after its first line behind "…more".
  const [firstLine, ...rest] = copy.youtube_description.split("\n");
  const restLines = rest.join("\n").trim();
  // A spec failure stops the run in qc.py before `store`, so a stored run always passed;
  // only its flags vary.
  const pill = qc.flags.length ? ["fail", `QC PASSED · ${qc.flags.length} FLAG${qc.flags.length === 1 ? "" : "S"}`] : ["pass", "QC PASSED"];

  return `<meta charset="utf-8">
<title>Post preview — ${esc(script.title)}</title>
<style>
:root{--bg:#0d0f13;--panel:#161a21;--line:#252a35;--ink:#e9ebf1;--dim:#939bac;
--ok:#4ade80;--warn:#fbbf24;--accent:#ffe14d;--yt:#ff4444;--tt:#25f4ee;--ig:#e1306c}
*{box-sizing:border-box}
body{margin:0;padding:30px 26px 60px;background:var(--bg);color:var(--ink);
font:15px/1.6 ui-sans-serif,-apple-system,"SF Pro Text",system-ui,sans-serif}
.wrap{max-width:1240px;margin:0 auto}
h1{font-size:26px;letter-spacing:-.02em;margin:0 0 5px}
.sub{color:var(--dim);font-size:13.5px}
.pill{display:inline-block;padding:2px 9px;border-radius:999px;font-size:12px;
font-weight:600;margin-left:8px;vertical-align:2px}
.pass{background:rgba(74,222,128,.12);color:var(--ok)}
.fail{background:rgba(251,191,36,.12);color:var(--warn)}
.cols{display:grid;grid-template-columns:minmax(250px,330px) 1fr;gap:26px;
align-items:start;margin-top:24px}
@media(max-width:900px){.cols{grid-template-columns:1fr}}
video{width:100%;border-radius:14px;display:block;background:#000;border:1px solid var(--line)}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;
padding:17px 19px;margin-bottom:16px}
h2{font-size:11.5px;text-transform:uppercase;letter-spacing:.09em;color:var(--dim);
margin:0 0 11px;font-weight:600;display:flex;align-items:center;gap:7px}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block}
.hook{font-size:18px;line-height:1.45;font-weight:600;border-left:3px solid var(--accent);
padding-left:13px;margin:0 0 14px}
p{margin:0 0 10px}.narration{color:#ccd2df}
.yt-title{font-size:17px;font-weight:600;line-height:1.3;margin-bottom:9px}
.yt-desc{color:#c3cad8;font-size:14px;white-space:pre-wrap}
.more{color:var(--dim);font-size:13px;margin-top:7px;border-top:1px solid var(--line);padding-top:9px;white-space:pre-wrap}
.cap{color:#d3d9e5;white-space:pre-wrap}
.tags{display:flex;flex-wrap:wrap;gap:6px;margin-top:9px}
.tag{background:#1d2330;border:1px solid var(--line);color:#9fc6ff;padding:3px 9px;
border-radius:5px;font-size:12.5px}
table{width:100%;border-collapse:collapse;font-size:13.5px}
td{padding:6px 0;border-bottom:1px solid var(--line)}
td:first-child{color:var(--dim);width:22%}tr:last-child td{border-bottom:0}
.ok{color:var(--ok)}.warn{color:var(--warn)}
.sheets img{width:100%;border-radius:6px;border:1px solid var(--line);display:block;margin-bottom:8px}
.meta{display:flex;gap:6px 20px;flex-wrap:wrap;color:var(--dim);font-size:13px;margin-top:9px}
.meta b{color:var(--ink);font-weight:600}
footer{margin-top:26px;color:var(--dim);font-size:12.5px;line-height:1.7}
code{background:#1d2330;padding:1px 5px;border-radius:4px;font-size:12.5px}
</style>
<div class="wrap">
<h1>${esc(script.title)}<span class="pill ${pill[0]}">${pill[1]}</span></h1>
<div class="sub">Post preview · <code>${esc(manifest.format)}</code> · run <code>${esc(runId.slice(0, 12))}…</code>
· playbook v${esc(manifest.playbook_version)} · ${esc(manifest.created_at)} · not published</div>

<div class="cols">
  <div>
    <video src="./video.mp4" controls preload="metadata" playsinline></video>
    <div class="meta">
      <div>Duration <b>${m.duration.toFixed(1)}s</b></div>
      <div>Res <b>${m.width}×${m.height}</b></div>
      <div>${m.fps} fps</div>
      <div>${m.integrated_lufs} LUFS</div>
      <div>${m.true_peak_dbtp} dBTP</div>
    </div>
    <div class="meta">Voice <b>${esc(manifest.voice.provider)} ${esc(manifest.voice.model)}</b></div>
    <div class="panel sheets" style="margin-top:16px">
      <h2>Review frames</h2>
      ${sheetImgs}
    </div>
  </div>

  <div>
    <div class="panel">
      <h2><span class="dot" style="background:var(--yt)"></span>YouTube Shorts</h2>
      <div class="yt-title">${esc(copy.youtube_title)}</div>
      <div class="yt-desc">${esc(firstLine)}</div>
      <div class="more"><b>…more</b>${restLines ? `\n\n${esc(restLines)}` : ""}</div>
      <div class="sub" style="margin-top:11px">Tags: ${ytTags}</div>
    </div>

    <div class="panel">
      <h2><span class="dot" style="background:var(--tt)"></span>TikTok</h2>
      <div class="cap">${esc(copy.tiktok_caption)}</div>
      <div class="sub" style="margin-top:8px">${[...copy.tiktok_caption].length} / 150 chars</div>
    </div>

    <div class="panel">
      <h2><span class="dot" style="background:var(--ig)"></span>Instagram Reels</h2>
      <div class="cap">${esc(copy.instagram_caption)}</div>
      <div class="tags">${tags}</div>
    </div>

    <div class="panel">
      <h2>Alt text</h2>
      <p class="cap">${esc(copy.alt_text)}</p>
    </div>

    <div class="panel">
      <h2>Script</h2>
      <p class="hook">${esc(script.overlay)}</p>
      <p class="narration">${esc(script.narration)}</p>
      <div class="sub">Opening shot: ${esc(script.first_frame)}</div>
    </div>

    <div class="panel">
      <h2>Brief</h2>
      <p class="cap">${esc(manifest.brief)}</p>
      <h2 style="margin-top:14px">Edit</h2>
      <p class="cap">${esc(manifest.edit_summary)}</p>
    </div>

    <div class="panel">
      <h2>Technical QC</h2>
      <table>${flags}</table>
    </div>
  </div>
</div>

<footer>
Every field above is read from <code>manifest.json</code>, <code>script.json</code>,
<code>copy.json</code> and <code>qc.json</code> in the run's stored directory. This page generates none of it.
</footer>
</div>
`;
}

// ---------------------------------------------------------------- main

const args = process.argv.slice(2);
const noPush = args.includes("--no-push");
const storeAt = args.indexOf("--store");
const store = storeAt >= 0 ? args[storeAt + 1] : undefined;
const runArg = args.find((a, i) => !a.startsWith("--") && (storeAt < 0 || i !== storeAt + 1));

// No default: a guessed key writes into another project's store (the old
// hardcoded `archon-75601ef6` did exactly that). SKILL.md resolves it with prp's
// canonical resolver and passes it in.
if (!store || !path.isAbsolute(store) || !fs.statSync(store, { throwIfNoEntry: false })?.isDirectory()) {
  die("--store <absolute prp store dir> is required — resolve it with the block in SKILL.md");
}

const dir = resolveVideoDir(runArg);
const runId = path.basename(dir);
for (const req of REQUIRED) {
  if (!fs.existsSync(path.join(dir, req))) die(`${dir} is missing ${req} — not a stored archon-video run`);
}

const [manifest, script, copy, qc] = ["manifest", "script", "copy", "qc"].map((n) => readJson(path.join(dir, `${n}.json`)));
const framesDir = path.join(dir, "frames");
const sheets = (fs.existsSync(framesDir) ? fs.readdirSync(framesDir) : [])
  .filter((f) => /^review-\d+\.jpg$/.test(f))
  .sort((a, b) => a.localeCompare(b, "en", { numeric: true }));

// Siblings must sit beside the artifact: that directory is the canvas read
// boundary, and it follows symlinks, so the video and sheets are copied in.
const out = path.join(store, `post-${runId.slice(0, 8)}`);
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(path.join(out, "frames"), { recursive: true });
fs.copyFileSync(path.join(dir, "video.mp4"), path.join(out, "video.mp4"));
for (const f of sheets) fs.copyFileSync(path.join(framesDir, f), path.join(out, "frames", f));

const artifact = path.join(out, "canvas.html");
fs.writeFileSync(artifact, renderPage({ manifest, script, copy, qc, sheets: sheets.map((f) => `frames/${f}`), runId }));
console.log(artifact);

if (!noPush) {
  try {
    execFileSync(BENCH, ["open", artifact], { stdio: ["ignore", "ignore", "inherit"] });
  } catch (err) {
    die(`bench open failed (${err.status ?? err.code}) — see stderr above`);
  }
}
