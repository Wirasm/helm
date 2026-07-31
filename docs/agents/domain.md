# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

**Layout: single-context.** helm is one Swift package with one target — no workspace file, no
`packages/`, no `package.json` at all.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root
- **`docs/adr/`** — read ADRs that touch the area you're about to work in

Neither exists yet. If any of these files don't exist, **proceed silently**. Don't flag their absence;
don't suggest creating them upfront. The `/domain-modeling` skill creates them lazily when terms or
decisions actually get resolved.

## Also read, for this repo specifically

helm's vocabulary is not all local. Before naming anything:

- **`../GLOSSARY.md`** — canonical vocabulary for the whole sild workspace, which helm sits inside.
  It outranks any term invented here.
- **`docs/direction.md`** — where helm is headed. An entry point, explicitly not a spec: it decides
  nothing, and says so. Treat its contents as intent, not as settled fact.
- **`docs/SPIKE.md`** and **`docs/VENDORED.md`** — the libghostty embed. These *are* settled fact:
  pinned versions, API landmines found the hard way, and the retirement condition for the local patch.

## File structure

```
/
├── CONTEXT.md          ← does not exist yet
├── docs/
│   ├── adr/            ← does not exist yet
│   ├── agents/         ← this directory
│   ├── direction.md
│   ├── SPIKE.md
│   └── VENDORED.md
├── Sources/Helm/
└── Tests/HelmTests/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test
name), use the term as defined in `CONTEXT.md` — and, above it, `../GLOSSARY.md`. Don't drift to
synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language
the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
