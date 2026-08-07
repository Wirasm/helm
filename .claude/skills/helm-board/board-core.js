// The board's decisions, with no DOM and no quickdraw in sight.
//
// `board.js` is the wiring — mount, fetch, listen, post — and everything it wires together is
// here, as functions over plain values. That split is not tidiness: a browser-only glue file is
// testable by looking at it, which is exactly the medium helm #197 measured three consecutive
// silent defects in. `test.sh` runs every function below in node against real record shapes.
//
// Nothing here imports quickdraw. A record is `{id, typeName, type, x, y, rot, z, props}` and a
// bounds is `{x, y, w, h}`, both of which quickdraw produces and neither of which it owns.

// ---------------------------------------------------------------------------------------------
// Who owns what
// ---------------------------------------------------------------------------------------------

// **The one invariant this whole file rests on: the agent owns a set of ids, and every record
// outside that set is the operator's.**
//
// quickdraw's `loadSnapshot` is a full replace that discards everything — including the stroke
// the operator drew ninety seconds ago — and reconciliation is not something the library does
// (`~/.prp/helm-3ec376fc/reports/quickdraw-upstream.md`: a grep for `reconcile|merge|rebase|
// conflict|anchor|bind|version|schema|migrate|validate` across all nine files finds the
// vocabulary absent). So a board that answers helm's update offer by loading a snapshot answers
// it by destroying the drawing the offer exists to protect.
//
// What replaces it needs no conflict resolution at all, because ownership is decided by id
// rather than discovered: put every record the agent's document names, remove the ones it used
// to name and no longer does, and **touch nothing else**. Ids are caller-supplied and never
// regenerated on load, which is the property that makes this work and the reason the agent must
// name its own shapes.
//
// **The cost, stated plainly rather than hidden:** an agent-owned shape the operator MOVES is
// put back where the agent's document says it is, on the agent's next write. That is what "the
// agent owns these ids" means, and the alternative — treating a move as the operator taking
// ownership — is a reconciliation policy, which is the thing this deliberately does not build.
export function planAgentUpdate(ownedIds, snapshot) {
  const store = (snapshot && snapshot.document && snapshot.document.store) || {};
  const put = Object.values(store).filter((rec) => rec && typeof rec.id === "string" && rec.id);
  const owned = put.map((rec) => rec.id);
  const next = new Set(owned);
  const remove = (ownedIds || []).filter((id) => !next.has(id));
  return { put, remove, owned };
}

// ---------------------------------------------------------------------------------------------
// Resolving a mark to something the agent can find
// ---------------------------------------------------------------------------------------------

// Intersection area of two `{x, y, w, h}` boxes. Zero when they miss.
export function overlapArea(a, b) {
  const w = Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x));
  const h = Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y));
  return w * h;
}

// **Overlap ranking, never `hitTest` — and the difference is not that one is weaker.**
//
// `hitTest` returns the topmost shape. The spike measured it answering
// `edge-handler-asks (arrow)` for a mark drawn squarely over a box, because an arrow crossed
// the mark's centre — and measured the same code giving the right answer at a different zoom.
// An unstable resolver is worse than a blunt one: it is right often enough to be trusted and
// wrong without saying so. Overlap was correct every run.
//
// **Raw intersection area, not a normalised fraction.** Raw area is what was measured to be
// right; a fraction of the mark, or of the candidate, is a different ranking that nobody has
// run. The number is reported rather than only compared, and the runner-up's alongside it, so
// a caller reading the latch has the confidence signal the spike used: a top score with a
// runner-up at zero is unambiguous, two close scores are a mark between two things.
//
// Ties break on id so the answer is stable across runs. An unstable ranking is the defect
// above wearing different clothes.
export function rankByOverlap(mark, candidates) {
  return candidates
    .map((c) => ({ id: c.id, label: c.label || null, overlap: Math.round(overlapArea(mark, c.bounds)) }))
    .filter((c) => c.overlap > 0)
    .sort((a, b) => b.overlap - a.overlap || (a.id < b.id ? -1 : 1));
}

// What a record is called, or null. `label` is geo-only and `text` is text/note-only —
// **arrows and lines carry neither**, which is quickdraw's shape rather than an oversight, and
// the reason SKILL.md tells an authoring agent to write a separate `text` shape for an edge
// label and position it by hand.
export function nameOf(rec) {
  const props = (rec && rec.props) || {};
  const name = props.label || props.text || null;
  return typeof name === "string" && name.trim() ? name.trim().slice(0, 120) : null;
}

// The candidates a mark is resolved against: everything nameable, minus freehand ink, minus
// the mark itself.
//
// **The mark is in the store and it is topmost** — the spike's second lesson, and the first
// version of the spike got it wrong. Excluding it is not an optimisation; including it makes
// every mark resolve to itself.
//
// Ink is excluded as a candidate for the same reason it is a mark rather than a shape: a
// scribble is not something an agent can find again, so naming one answers "what did I draw
// over" with "another thing you drew".
export function candidatesFor(markId, records, boundsOf) {
  return records
    .filter((rec) => rec.id !== markId)
    .filter((rec) => rec.type !== "draw" && rec.type !== "highlight")
    .filter((rec) => rec.typeName !== "asset")
    .filter((rec) => nameOf(rec) !== null)
    .map((rec) => ({ id: rec.id, label: nameOf(rec), bounds: boundsOf(rec) }));
}

// ---------------------------------------------------------------------------------------------
// Pressure — the one thing that separates a hand from a script
// ---------------------------------------------------------------------------------------------

// `props.pts` is a flat `[x, y, pressure, x, y, pressure, …]` run.
//
// **A synthetic `PointerEvent` reports a constant pressure of 0.5; a trackpad varies.** That is
// the discriminator the quickdraw spike closed its last leg with, and it is reported here for
// one reason: an agent reading this latch can say what the page observed, and cannot claim to
// have drawn it. `varies: false` on a stroke is not proof of forgery and `varies: true` is not
// proof of a hand — it is the number, and the operator is the only one who can say whose hand
// it was.
export function pressureRange(pts) {
  const list = [];
  for (let i = 2; i < (pts || []).length; i += 3) {
    if (typeof pts[i] === "number") list.push(pts[i]);
  }
  if (!list.length) return null;
  const min = Math.min(...list);
  const max = Math.max(...list);
  return {
    min: Math.round(min * 100) / 100,
    max: Math.round(max * 100) / 100,
    varies: list.length > 1 && max - min > 0.001,
  };
}

// How many points a stroke has, from the same flat run.
export function pointCount(pts) {
  return Math.floor((pts || []).length / 3);
}

// ---------------------------------------------------------------------------------------------
// The report
// ---------------------------------------------------------------------------------------------

// **Caps, and they are about the reader rather than the disk.** helm refuses a state report over
// 64 KB because every byte of it lands in the next agent turn's context window. These numbers
// keep a busy board an order of magnitude under that; a board that outgrows them says so with
// `truncated` rather than silently reporting a prefix.
export const MAX_MARKS = 32;
export const MAX_SHAPES = 96;

// **`format` and `version` INSIDE the state, and that is not a duplicate of helm's envelope.**
//
// helm's latch wraps this in `{format: "helm.canvas-state", version, writtenAt, artifact,
// state}` — that envelope versions *helm's file*, and helm never reads what is inside it. This
// object is a second thing an agent parses, with its own vocabulary that will grow, so it
// carries its own discriminator from the first message rather than acquiring one when a second
// shape arrives. helm's canvas has paid the other bill once already: the page→helm bridge
// shipped `{id, text, rect}` with no `kind`, and the gate that had to infer the shape dropped
// every geometry mark for months (#216).
export function boardReport({ records, boundsOf, ownedIds, generation, warnings }) {
  const owned = new Set(ownedIds || []);
  const shapes = records.filter((rec) => rec.typeName !== "asset");
  const drawn = shapes.filter((rec) => !owned.has(rec.id));
  const nameable = shapes.filter((rec) => nameOf(rec) !== null);

  const marks = drawn.slice(-MAX_MARKS).map((rec) => {
    const ranked = rankByOverlap(boundsOf(rec), candidatesFor(rec.id, shapes, boundsOf));
    const pressure = rec.type === "draw" ? pressureRange(rec.props && rec.props.pts) : null;
    const mark = {
      id: rec.id,
      type: rec.type,
      over: ranked[0] || null,
      runnerUp: ranked[1] || null,
    };
    if (rec.type === "draw") {
      mark.points = pointCount(rec.props && rec.props.pts);
      mark.pressure = pressure;
    }
    const name = nameOf(rec);
    if (name) mark.label = name;
    return mark;
  });

  const report = {
    format: "helm.board",
    version: 1,
    // **Always present, both ways round.** `board.js` posts `mounted: false` when it cannot find
    // its container — the one failure that would otherwise be a blank page and a silent latch —
    // and a field that only ever appears on failure is one a reader has to know to look for.
    // Absent is not a third state; it is an older build.
    mounted: true,
    generation: typeof generation === "number" ? generation : null,
    counts: {
      records: shapes.length,
      agent: shapes.filter((rec) => owned.has(rec.id)).length,
      operator: drawn.length,
    },
    shapes: nameable.slice(0, MAX_SHAPES).map((rec) => ({
      id: rec.id,
      type: rec.type,
      label: nameOf(rec),
      owner: owned.has(rec.id) ? "agent" : "operator",
    })),
    marks,
  };
  if (drawn.length > MAX_MARKS || nameable.length > MAX_SHAPES) {
    report.truncated = {
      marks: Math.max(0, drawn.length - MAX_MARKS),
      shapes: Math.max(0, nameable.length - MAX_SHAPES),
    };
  }
  // **The page's only way to be loud.** helm's log records what helm dropped; nothing records
  // what the page could not do. A drawing that has quietly stopped surviving reloads, or a
  // document file that answered 500, is a fact the agent has to be able to read — and this
  // latch is the only channel a canvas has. Absent when there is nothing wrong, so its presence
  // is the signal.
  if (warnings && warnings.length) report.warnings = warnings.slice(0, 8);
  return report;
}
