# future-planning

**M0 — the daemon skeleton at `daemon/` — is built (PR #340); everything else in this
directory remains unbuilt, and nothing in it authorises building.**

These documents describe a proposed successor to helm — a headless daemon owning ptys and
state, with the app as a thin face. They are here so the reasoning survives and can be argued
with. They are **not** a description of the working tree, and they are not a work order.

- `workbench-audit-2026-08.md` — an audit of helm as it stands, a survey of the 2026 field,
  and the greenfield design. **Part I is about code that exists; Parts II and III are not.**
- `bench-roadmap.md` — the milestone sequence M0–M7, written in the imperative for a session
  that has been sent here deliberately.

## Why the folder, and why this file

The roadmap opens with *"Read this cold. This document assumes no prior context… what to
build, in what order."* That is exactly right for someone sent here on purpose and exactly
wrong for an agent that wandered in from `docs/` looking for guidance — it is
self-consistent, committed to `development`, and written as instructions.

**Work here starts when the operator says a milestone starts, and only then.** If you arrived
without being pointed at a specific milestone by name, you are in the wrong directory: `AGENTS.md`
describes the tree as it is, and the GitHub issues are the work that exists.

That distinction is not pedantry. This repo spent 2026-08-10 fixing seven claims in `AGENTS.md`
that the code contradicted, and the lesson generalises in both directions: **a document that
asserts something untrue is expensive whether the untruth is behind it or ahead of it.** These
two are ahead of it, and the failure mode is an agent helpfully making them true.

## What is safe to take from here today

The audit's **Part I** is a measurement of the current tree and was accurate when written
(2026-08-09, with a dated addendum). Its weaknesses list and its debt list are real and several
have since been closed. Reading it to understand helm is fine. Reading Part III to decide what
to build next is not, unless that is the conversation you are in.
