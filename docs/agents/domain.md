# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

**Layout: single-context.** helm is one Swift package with one target — no workspace file, no
`packages/`, no `package.json` at all.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — **helm's canonical vocabulary.** It outranks `../GLOSSARY.md`
  for anything helm shows.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in

`docs/adr/` does not exist yet. If a file listed here doesn't exist, **proceed silently**. Don't flag
its absence; don't suggest creating it upfront. The `/domain-modeling` skill creates them lazily when
terms or decisions actually get resolved.

## Also read, for this repo specifically

helm's vocabulary is not all local. Before naming anything:

- **`../GLOSSARY.md`** — the **cross-repo** terms helm shares with kild and prp. Since helm #34 it no
  longer carries helm's own vocabulary: `CONTEXT.md` outranks it for anything helm shows, and most of
  what remains there names kild's room model, which helm does not have.
- **`docs/direction.md`** — where helm is headed. An entry point, explicitly not a spec: it decides
  nothing, and says so. Treat its contents as intent, not as settled fact.
- **`docs/SPIKE.md`** and **`docs/VENDORED.md`** — the libghostty embed. These *are* settled fact:
  pinned versions, API landmines found the hard way, and the retirement condition for the local patch.

## File structure

```
/
├── CONTEXT.md          ← helm's canonical vocabulary
├── docs/
│   ├── adr/            ← does not exist yet
│   ├── agents/         ← this directory
│   ├── direction.md
│   ├── SPIKE.md
│   └── VENDORED.md
├── Sources/Helm/       ← sliced vertically by feature, see below
└── Tests/HelmTests/    ← mirrors the same slices
```

**The source is sliced by feature, not by layer.** Each directory holds that feature's
model, views and command handling together, so two features can be built at once without
editing the same file.

```
Sources/Helm/
├── App/          composition only — the scene, the keyboard map, the menu, notification names
├── Workspaces/   the folders helm has open, and their persisted per-workspace state
├── Terminals/    sessions, the shared ghostty runtime, the tab strip
├── Canvas/       rendering a markdown/HTML file — the pane and its webviews
├── Artifacts/    finding artifacts: store discovery, the ⌘O browser, store resolution
└── Shared/       the few things no single feature owns
```

`AGENTS.md` carries the reasoning for placing code — read it before adding a file.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test
name), use the term as defined in `CONTEXT.md` — falling back to `../GLOSSARY.md` only for terms that
cross into kild or prp. Don't drift to synonyms either file lists under `_Avoid_` / "Never say".

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language
the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
