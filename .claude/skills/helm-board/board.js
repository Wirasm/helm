// The wiring: mount a board, take helm's updates without being reloaded, and tell helm what is
// on it. Every decision this makes lives in `board-core.js`, which has no DOM in it and is what
// `test.sh` runs.
//
// Nothing here is required for the board to draw. Open the artifact in any browser and it
// mounts, renders the agent's document and takes a pen — helm's two channels are feature-
// detected, and a page that needed them would render in helm and be blank in a headless
// browser, which is exactly what an artifact must never be (helm #33).

import { createQuickdraw, pageBounds } from "./quickdraw/index.js";
import { planAgentUpdate, boardReport } from "./board-core.js";

// ---------------------------------------------------------------------------------------------
// Where things are
// ---------------------------------------------------------------------------------------------

// `helm-canvas://<host>/plan-board.html` → `plan-board`. Siblings are resolved against the
// artifact's own directory, so a relative name is the whole address.
const artifact = decodeURIComponent(location.pathname.split("/").pop() || "board.html");
const base = artifact.replace(/\.[^.]+$/, "");
const documentURL = `./${base}.document.json`;
// **A page-local cache of the OPERATOR's records, and nothing else.** helm reloads a canvas
// whenever the appearance flips or the operator presses Reload, and a reload is a fresh
// document with a fresh store — so without this, switching to dark mode throws their drawing
// away. The agent's records are never cached: they are re-fetched from the file, which is the
// authority for the ids the agent owns.
const cacheKey = `helm.board/${artifact}`;

const latch =
  window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.helmCanvasState;

const warnings = [];

function warn(message) {
  if (warnings.length < 8 && warnings.indexOf(message) < 0) warnings.push(message);
  console.warn(`board: ${message}`);
}

const container = document.getElementById("board");

// **A missing container is the one failure that is otherwise completely silent.** The artifact
// is the author's to edit, and renaming the element quickdraw mounts into throws inside
// `createQuickdraw` before anything below runs — an ES module that throws leaves a blank page,
// no message on screen, and nothing in the latch. So it is said in both directions: on the page
// for whoever is looking at it, and in the report for the agent who is not.
if (!container) {
  const said = `no element with id "board" — the artifact must carry <main id="board" data-helm-surface>`;
  warn(said);
  const note = document.createElement("p");
  note.textContent = `This board cannot mount: ${said}`;
  document.body.appendChild(note);
  if (latch) {
    latch.postMessage({
      kind: "canvas.state",
      state: { format: "helm.board", version: 1, mounted: false, warnings: [said] },
    });
  }
  throw new Error(said);
}

// ---------------------------------------------------------------------------------------------
// Mount
// ---------------------------------------------------------------------------------------------

const dark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
const board = createQuickdraw({
  container,
  theme: dark ? "dark" : "light",
  grid: "dots",
  // Honoured, documented, and costs nothing — verified absent in the spike.
  watermark: false,
});
const editor = board.editor;
const store = editor.store;

const boundsOf = (rec) => pageBounds(rec);

// Which ids the agent's document names. Everything else in the store is the operator's, and
// that sentence is the whole of `planAgentUpdate`.
let ownedIds = [];
let generation = null;

async function readAgentDocument() {
  try {
    const response = await fetch(documentURL, { cache: "no-store" });
    // A sibling fetch reports a real status (helm #201), so 404 means "the agent has not
    // written a document yet" — a blank board, not a failure.
    if (response.status === 404) return { document: { store: {} } };
    if (!response.ok) {
      warn(`${documentURL} answered ${response.status}`);
      return null;
    }
    return await response.json();
  } catch (error) {
    warn(`${documentURL} could not be read: ${error && error.message}`);
    return null;
  }
}

// Apply the agent's document over whatever is on the board, touching nothing the agent does not
// own. `source: "remote"` keeps an agent's write out of the OPERATOR's undo stack — ⌘Z should
// take back the last thing the hand did, never the last thing an agent did.
function applyAgentDocument(snapshot) {
  const plan = planAgentUpdate(ownedIds, snapshot);
  store.transact(() => {
    if (plan.remove.length) store.remove(plan.remove, "remote");
    for (const record of plan.put) store.put(record, "remote");
  }, "remote");
  ownedIds = plan.owned;
}

// ---------------------------------------------------------------------------------------------
// The operator's own records, across a reload
// ---------------------------------------------------------------------------------------------

function restoreOperatorRecords() {
  let cached;
  try {
    cached = window.localStorage.getItem(cacheKey);
  } catch (error) {
    warn(`the drawing cache is unreadable: ${error && error.message}`);
    return;
  }
  if (!cached) return;
  let parsed;
  try {
    parsed = JSON.parse(cached);
  } catch {
    warn("the drawing cache was not JSON and was ignored");
    return;
  }
  if (!parsed || parsed.format !== "helm.board-cache" || parsed.version !== 1) {
    warn("the drawing cache is from a different build and was ignored");
    return;
  }
  const owned = new Set(ownedIds);
  store.transact(() => {
    for (const record of parsed.records || []) {
      // Never over an id the agent owns: the file is the authority for those, and a cache that
      // could win over it would resurrect a shape the agent deleted.
      if (record && record.id && !owned.has(record.id)) store.put(record, "remote");
    }
  }, "remote");
}

function cacheOperatorRecords() {
  const owned = new Set(ownedIds);
  const records = store.all().filter((rec) => !owned.has(rec.id));
  try {
    window.localStorage.setItem(
      cacheKey,
      JSON.stringify({ format: "helm.board-cache", version: 1, records })
    );
  } catch (error) {
    // Loud, in the one place a page can be loud to an agent: the report itself. A drawing that
    // silently stops surviving reloads is the failure nobody notices until it has happened.
    warn(`the drawing could not be cached: ${error && error.message}`);
  }
}

// ---------------------------------------------------------------------------------------------
// Force, which is the only channel a hand reaches this page on
// ---------------------------------------------------------------------------------------------

// **`PointerEvent.pressure` is a dead end on macOS and this is what replaces it.** A trackpad is
// a mouse-class pointer there, so pressure is pinned at 0.5 while a button is down no matter how
// hard anyone presses — measured on a live board, five strokes, 70 held samples, all 0.5. The
// force is real and arrives on Apple's own channel: `webkitForce` on mouse events, changing
// through `webkitmouseforcechanged`. `board-core.js` turns the samples into a range; collecting
// them needs the DOM, so it happens here.
//
// Samples are attributed to the records a gesture CREATED, found by diffing the store's ids
// across the gesture rather than by reading quickdraw's change payload — the diff depends on
// nothing but `store.all()`, which is already this file's only view of the store.
const forceById = {};
let gesture = null;

// **`capture: true`, and it is load-bearing.** quickdraw creates the stroke record on its own
// `pointerdown`; a bubble-phase listener here would run after that and snapshot a store that
// already contains the record, so the diff would be empty and every gesture would report no
// force at all.
container.addEventListener(
  "pointerdown",
  () => {
    gesture = { before: new Set(store.all().map((rec) => rec.id)), samples: [] };
  },
  { capture: true }
);

// **`capture: true` again, and for a different reason than above.** quickdraw mounts its own
// `<canvas>` inside this container, so a force event's target is a descendant rather than the
// container itself. `webkitmouseforce*` is a non-standard family and whether it bubbles is not
// something to take on trust from a listener that would simply never fire; the capture phase
// visits every ancestor on the way down whatever the answer is.
container.addEventListener(
  "webkitmouseforcechanged",
  (event) => {
    if (gesture && typeof event.webkitForce === "number") gesture.samples.push(event.webkitForce);
  },
  { capture: true }
);

// On `window`, because quickdraw takes pointer capture during a drag and a release outside the
// container would otherwise never reach a listener bound to it — leaving `gesture` open and the
// next stroke's samples appended to the last one's.
for (const type of ["pointerup", "pointercancel"]) {
  window.addEventListener(
    type,
    () => {
      const done = gesture;
      gesture = null;
      if (!done) return;
      const live = new Set();
      for (const rec of store.all()) {
        live.add(rec.id);
        if (done.samples.length && !done.before.has(rec.id)) forceById[rec.id] = done.samples;
      }
      // Undo takes the record away; its force reading goes with it rather than accumulating in a
      // page that stays open all day. Outside the `samples.length` guard on purpose: a gesture
      // that produced no force is exactly what an undo is, and it still has to sweep.
      for (const id of Object.keys(forceById)) if (!live.has(id)) delete forceById[id];
    },
    { capture: true }
  );
}

// A force click is macOS offering to look something up, and the gesture this page is inviting is
// exactly the one that triggers it. There is nothing on a board to look up.
container.addEventListener("webkitmouseforcewillbegin", (event) => event.preventDefault(), {
  capture: true,
});

// ---------------------------------------------------------------------------------------------
// Telling helm what is on the board
// ---------------------------------------------------------------------------------------------

function report() {
  if (!latch) return;
  const state = boardReport({
    records: store.all(),
    boundsOf,
    ownedIds,
    generation,
    warnings,
    forceById,
  });
  latch.postMessage({ kind: "canvas.state", state });
}

// **Coalesced on settle, never on a timer and never on a frame.** A freehand drag emits a
// transaction per pointer move, and helm writes the latch on every changed report — so posting
// per transaction would rewrite a file sixty times a second in the pane the operator is drawing
// in. This fires once, after the hand stops. It is not a poll: nothing schedules it but a real
// change, and a board nobody touches posts nothing at all.
let pending = null;
function reportSoon() {
  if (pending) clearTimeout(pending);
  pending = setTimeout(() => {
    pending = null;
    cacheOperatorRecords();
    report();
  }, 300);
}

// `source: "user"` — the operator's own edits. An agent's write comes back through the same
// store as `"remote"` and reporting it would be helm telling the agent what the agent just said.
store.listen(reportSoon, { source: "user" });

// ---------------------------------------------------------------------------------------------
// Taking helm's update instead of being reloaded (#109)
// ---------------------------------------------------------------------------------------------

// **Defining this is the whole contract: a page that defines it is never reloaded by helm.**
// That is what makes a board survivable — an agent rewriting the diagram is the ordinary way a
// canvas changes, and a reload would take the camera, the selection, the undo history and the
// operator's ink with it every time.
window.helmCanvasUpdate = function (update) {
  generation = update && typeof update.generation === "number" ? update.generation : generation;
  readAgentDocument().then((snapshot) => {
    if (!snapshot) return;
    applyAgentDocument(snapshot);
    report();
  });
  // Handled. The fetch is in flight rather than complete, and that is deliberate: the answer
  // helm wants is "do not reload me", which is true the moment this function exists. Returning
  // a promise would make it `[object Promise] !== false` — handled by accident rather than on
  // purpose — so it says so directly.
  return true;
};

// ---------------------------------------------------------------------------------------------
// Go
// ---------------------------------------------------------------------------------------------

const initial = await readAgentDocument();
if (initial) applyAgentDocument(initial);
restoreOperatorRecords();
// `margin` here is a FRACTION of the smaller viewport dimension, not pixels — the `.d.ts` says
// only `margin?: number` and the obvious guess of `40` insets by forty times the viewport,
// clamps the camera to minimum zoom and strands the drawing microscopic with no error at all.
// It cost the spike two capture cycles; the fix is filed upstream as a draft.
if (store.size) editor.fitContent({ margin: 0.06 });
report();
