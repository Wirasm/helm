// `board-core.js`, EXECUTED. Run by `test.sh`, never on its own — it imports the module from
// `BOARD_CORE`, which `test.sh` sets to a copy of the shipped file with an `.mjs` extension so
// node reads it as the ES module a browser does. That copy is why this skill needs no
// `package.json`: the bytes under test are the bytes that ship, and nothing in the directory
// exists only to satisfy a test runner.
//
// The last case reads the record shape out of `SKILL.md` itself rather than restating it. A
// test that retypes a documented snippet is a second copy that drifts, and would keep passing
// while the doc said something else.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const core = await import(process.env.BOARD_CORE);
const here = dirname(fileURLToPath(import.meta.url));

let pass = 0;
let fail = 0;

function check(label, got, want) {
  const a = JSON.stringify(got);
  const b = JSON.stringify(want);
  if (a === b) {
    pass++;
    console.log(`  ok    ${label}`);
  } else {
    fail++;
    console.log(`  FAIL  ${label}\n          wanted ${b}\n          got    ${a}`);
  }
}

function ok(label, condition, detail) {
  if (condition) {
    pass++;
    console.log(`  ok    ${label}`);
  } else {
    fail++;
    console.log(`  FAIL  ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

// --- fixtures ---------------------------------------------------------------------------------

const geo = (id, x, y, w, h, label) => ({
  id,
  typeName: "shape",
  type: "geo",
  x,
  y,
  rot: 0,
  z: 1,
  props: { geo: "rectangle", w, h, label },
});

const stroke = (id, x, y, w, h, pressures) => ({
  id,
  typeName: "shape",
  type: "draw",
  x,
  y,
  rot: 0,
  z: 9,
  props: {
    size: "m",
    pts: pressures.flatMap((p, i) => [x + (w * i) / pressures.length, y + h / 2, p]),
    __w: w,
    __h: h,
  },
});

// A stand-in for quickdraw's `pageBounds`, which the real board passes in. Deliberately not
// imported: `board-core.js` takes the function precisely so it depends on no engine, and a test
// that reached for the engine would be testing the engine.
const boundsOf = (rec) =>
  rec.type === "draw"
    ? { x: rec.x, y: rec.y, w: rec.props.__w, h: rec.props.__h }
    : { x: rec.x, y: rec.y, w: rec.props.w, h: rec.props.h };

const snapshot = (records) => ({
  document: { store: Object.fromEntries(records.map((r) => [r.id, r])) },
});

// --- ownership --------------------------------------------------------------------------------

console.log("ownership by id");
{
  const plan = core.planAgentUpdate([], snapshot([geo("a", 0, 0, 100, 50, "A")]));
  check("a first load owns everything it named", plan.owned, ["a"]);
  check("and removes nothing", plan.remove, []);
  check("and puts what it named", plan.put.map((r) => r.id), ["a"]);
}
{
  const plan = core.planAgentUpdate(["a", "b"], snapshot([geo("b", 0, 0, 1, 1, "B"), geo("c", 0, 0, 1, 1, "C")]));
  check("an id the agent used to own and no longer names is removed", plan.remove, ["a"]);
  check("and the new set is what it names now", plan.owned, ["b", "c"]);
}
{
  // The invariant the whole update rests on. `mark:1` is the operator's; it appears in neither
  // the old owned set nor the new document, and must be untouched by both lists.
  const plan = core.planAgentUpdate(["a"], snapshot([geo("a", 0, 0, 1, 1, "A")]));
  ok(
    "an operator's record is named by neither list",
    !plan.remove.includes("mark:1") && !plan.put.some((r) => r.id === "mark:1"),
    JSON.stringify(plan)
  );
}
{
  const plan = core.planAgentUpdate(["a"], { document: { store: { bad: { typeName: "shape" } } } });
  check("a record with no id is not applied", plan.put, []);
  check("and it is not counted as owned", plan.owned, []);
}
{
  const plan = core.planAgentUpdate(["a"], null);
  check("a document that would not parse removes what it used to own", plan.remove, ["a"]);
}

// --- resolution -------------------------------------------------------------------------------

console.log("resolving a mark");
check("boxes that miss overlap by nothing", core.overlapArea({ x: 0, y: 0, w: 10, h: 10 }, { x: 20, y: 0, w: 10, h: 10 }), 0);
check("a box inside another overlaps by its own area", core.overlapArea({ x: 2, y: 2, w: 4, h: 4 }, { x: 0, y: 0, w: 10, h: 10 }), 16);
{
  const mark = { x: 0, y: 0, w: 10, h: 10 };
  const ranked = core.rankByOverlap(mark, [
    { id: "small", label: "S", bounds: { x: 8, y: 8, w: 10, h: 10 } },
    { id: "big", label: "B", bounds: { x: 0, y: 0, w: 10, h: 10 } },
    { id: "miss", label: "M", bounds: { x: 50, y: 50, w: 10, h: 10 } },
  ]);
  check("ranked by overlap, and a miss is not a candidate at all", ranked.map((r) => r.id), ["big", "small"]);
  check("with the runner-up's score reported too", ranked[1].overlap, 4);
}
{
  // Stability is the whole reason this is not `hitTest`. Equal scores must not depend on the
  // order the store happened to hand them over.
  const mark = { x: 0, y: 0, w: 10, h: 10 };
  const tied = [
    { id: "zebra", bounds: { x: 0, y: 0, w: 10, h: 10 } },
    { id: "aardvark", bounds: { x: 0, y: 0, w: 10, h: 10 } },
  ];
  check("ties break on id, both ways round", core.rankByOverlap(mark, tied).map((r) => r.id), ["aardvark", "zebra"]);
  check("and again reversed", core.rankByOverlap(mark, [...tied].reverse()).map((r) => r.id), ["aardvark", "zebra"]);
}
{
  const records = [
    geo("box", 0, 0, 10, 10, "Box"),
    geo("unnamed", 0, 0, 10, 10, ""),
    stroke("other-ink", 0, 0, 10, 10, [0.5]),
    stroke("mark", 0, 0, 10, 10, [0.5]),
  ];
  const ids = core.candidatesFor("mark", records, boundsOf).map((c) => c.id);
  check("the mark is never a candidate for itself, and ink is never a name", ids, ["box"]);
}
check("an arrow has no name — label is geo-only, text is text-only", core.nameOf({ type: "arrow", props: { dx: 1, dy: 1 } }), null);
check("a text shape is named by its text", core.nameOf({ type: "text", props: { text: " issues " } }), "issues");

// --- pressure ---------------------------------------------------------------------------------

console.log("pressure");
check("a mouse-class pointer reports one constant value — every macOS trackpad stroke, and every script", core.pressureRange([0, 0, 0.5, 1, 1, 0.5]), { min: 0.5, max: 0.5, varies: false });
check("a device that does report pressure is passed through — a stylus, where pointerType is pen", core.pressureRange([0, 0, 0.21, 1, 1, 0.68]), { min: 0.21, max: 0.68, varies: true });
check("no points is no answer, never a fabricated zero", core.pressureRange([]), null);
check("points count in threes", core.pointCount([0, 0, 0.5, 1, 1, 0.5, 2, 2, 0.5]), 3);

// --- force ------------------------------------------------------------------------------------

// Measured on a live board 2026-08-10, five real trackpad strokes: `pressure` was 0.5 for all 70
// held samples of the longest one and `webkitForce` ran 1 → 1.9998 across the same gesture, with
// 254 `webkitmouseforcechanged` events. So the discriminator is here, not in `pressureRange`.

console.log("force");
check("no samples is no answer, never a fabricated zero", core.forceRange([]), null);
check("nor when nobody passed any", core.forceRange(undefined), null);
check("one sample cannot vary", core.forceRange([1]), { min: 1, max: 1, varies: false, samples: 1 });
check(
  "a plain click sits at the mouse-down constant and stays there",
  core.forceRange([1, 1, 1]),
  { min: 1, max: 1, varies: false, samples: 3 }
);
check(
  "a hand pressing varies, rounded the way pressure is",
  core.forceRange([1, 1.42, 1.9998]),
  { min: 1, max: 2, varies: true, samples: 3 }
);
check("and a value that is not a number is not a sample", core.forceRange([1, null, "2", 1.6]), {
  min: 1,
  max: 1.6,
  varies: true,
  samples: 2,
});

// --- the report -------------------------------------------------------------------------------

console.log("the report");
{
  const records = [
    geo("auth-service", 0, 0, 200, 90, "Auth"),
    geo("session-store", 400, 0, 200, 90, "Sessions"),
    stroke("mark:1", 10, 10, 180, 70, [0.2, 0.6, 0.4]),
  ];
  const report = core.boardReport({
    records,
    boundsOf,
    ownedIds: ["auth-service", "session-store"],
    generation: 3,
  });
  check("it says what it is, from the first message", [report.format, report.version], ["helm.board", 1]);
  check("and that it is mounted, in the same words the failure path uses", report.mounted, true);
  check("and which update it has applied", report.generation, 3);
  check("counts split by owner", report.counts, { records: 3, agent: 2, operator: 1 });
  check("the operator's stroke is a mark", report.marks.map((m) => m.id), ["mark:1"]);
  check("resolved to the shape it covers", report.marks[0].over.id, "auth-service");
  check("with a runner-up that did not touch it left out", report.marks[0].runnerUp, null);
  check("carrying its point count", report.marks[0].points, 3);
  check("and its pressure", report.marks[0].pressure.varies, true);
  check("named shapes carry their owner", report.shapes.map((s) => `${s.id}:${s.owner}`), [
    "auth-service:agent",
    "session-store:agent",
  ]);
  ok("nothing is truncated on a small board", report.truncated === undefined);
  ok("and nothing is warned about", report.warnings === undefined);
}
{
  // A shape the OPERATOR added and labelled is nameable, and is both a mark and a shape — it is
  // something they put there AND something an agent can find again.
  const records = [geo("theirs", 0, 0, 10, 10, "Mine")];
  const report = core.boardReport({ records, boundsOf, ownedIds: [], generation: null });
  check("an operator's labelled box is reported as theirs", report.shapes[0].owner, "operator");
  check("and it is a mark too", report.marks.map((m) => m.id), ["theirs"]);
  ok("with no pressure invented for a shape that is not ink", report.marks[0].pressure === undefined);
}
{
  // The whole point, in one report: what macOS puts on `PointerEvent.pressure` is flat, and the
  // hand shows up on the force channel beside it. Both are carried, because "pressure was flat"
  // is itself a fact about the platform and deleting it would leave a reader guessing.
  const records = [
    geo("auth-service", 0, 0, 200, 90, "Auth"),
    stroke("mark:hand", 10, 10, 180, 70, [0.5, 0.5, 0.5]),
  ];
  const report = core.boardReport({
    records,
    boundsOf,
    ownedIds: ["auth-service"],
    generation: null,
    forceById: { "mark:hand": [1, 1.42, 1.9998] },
  });
  check("pressure is flat, exactly as macOS reports a trackpad", report.marks[0].pressure, {
    min: 0.5,
    max: 0.5,
    varies: false,
  });
  check("and the force channel is the one that moved", report.marks[0].force.varies, true);
  check("carrying its range", [report.marks[0].force.min, report.marks[0].force.max], [1, 2]);
  check("and how many samples it saw", report.marks[0].force.samples, 3);
}
{
  const records = [stroke("mark:quiet", 0, 0, 10, 10, [0.5])];
  const report = core.boardReport({ records, boundsOf, ownedIds: [], generation: null });
  ok(
    "a mark nobody reported force for carries no force field, rather than a fabricated null",
    report.marks[0].force === undefined
  );
}
{
  // Force belongs to the GESTURE, not to ink — a labelled box the operator dragged out under
  // pressure is as much a hand as a scribble is, and it carries no `pts` for pressureRange.
  const records = [geo("theirs", 0, 0, 10, 10, "Mine")];
  const report = core.boardReport({
    records,
    boundsOf,
    ownedIds: [],
    generation: null,
    forceById: { theirs: [1, 1.7] },
  });
  ok("a shape that is not ink still reports the force it was drawn with", report.marks[0].force.varies === true);
  ok("and still invents no pressure", report.marks[0].pressure === undefined);
}
{
  const many = [];
  for (let i = 0; i < core.MAX_MARKS + 5; i++) many.push(stroke(`m${i}`, i, 0, 5, 5, [0.5]));
  const report = core.boardReport({ records: many, boundsOf, ownedIds: [], generation: 0 });
  check("a busy board reports at most the cap", report.marks.length, core.MAX_MARKS);
  check("and says how many it left out rather than quietly truncating", report.truncated.marks, 5);
  ok(
    "a full report stays well inside helm's 64 KB latch limit",
    JSON.stringify(report).length < 64000,
    `${JSON.stringify(report).length} bytes`
  );
}
{
  const report = core.boardReport({ records: [], boundsOf, ownedIds: [], generation: 0, warnings: ["nope"] });
  check("a page with something to say says it", report.warnings, ["nope"]);
}

// --- the documented record shape ---------------------------------------------------------------

console.log("SKILL.md");
{
  const skill = readFileSync(join(here, "SKILL.md"), "utf8");
  const block = skill.match(/```json\n([\s\S]*?)```/);
  ok("the SKILL.md carries a document example", !!block);
  const parsed = JSON.parse(block[1]);
  const plan = core.planAgentUpdate([], parsed);
  ok(
    "and every record in it is one the board would actually apply",
    plan.put.length === Object.keys(parsed.document.store).length,
    `${plan.put.length} of ${Object.keys(parsed.document.store).length}`
  );
  const report = core.boardReport({
    records: plan.put,
    boundsOf: (rec) => ({ x: rec.x, y: rec.y, w: rec.props.w || 10, h: rec.props.h || 10 }),
    ownedIds: plan.owned,
    generation: 0,
  });
  check(
    "the documented arrow has no name, exactly as the doc says",
    report.shapes.map((s) => s.id).includes("auth-to-db"),
    false
  );
  check("while the box and the edge's separate text shape do", report.shapes.map((s) => s.id), [
    "auth-service",
    "auth-to-db-label",
  ]);

  // The doc used to teach `pressure.varies` as the way to tell a hand from a script. That is
  // false on macOS — measured — and a skill that still taught it would send every agent reading
  // it to the one field that cannot answer. So the gate holds the doc to what the code reports.
  ok("the doc names the force channel", /webkitForce/.test(skill), "SKILL.md never mentions webkitForce");
  ok(
    "and does not still teach pressure.varies as the discriminator",
    !/`pressure\.varies` is (what a hand looks like|the discriminator)/.test(skill),
    "SKILL.md still points agents at pressure.varies"
  );
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
