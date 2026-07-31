# AGENTS.md — helm

Native macOS surface: SwiftUI + GhosttyKit. A terminal as the permanent centre, workspaces
above it, a right dock for an open artifact. **No backend** — artifacts are files.

**"Agent" means a CLI agent already in use — Claude Code, pi, codex.** helm hosts one in a
terminal it owns and renders what it writes. It never builds or hosts an agent of its own.

Direction: `docs/direction.md` (an entry point, not a spec).

## Working here

Gate, all green before a PR to `development`:

```
bash scripts/patch-libghostty.sh && swift build && swift test && make lint && xcodegen generate
```

The patch script is first and not optional — the patched libghostty is gitignored, so a
fresh worktree has nothing to link against. Never borrow another checkout's `vendor/`;
that proves the other checkout builds.

- **Never restart a running helm without warning the operator** — a live window may be
  hosting their session.
- **Never delete a test to make the gate green.** If its subject genuinely no longer
  exists, say which and why in the commit.
- **You cannot see the UI.** Screen Recording is not granted to agent contexts and cannot
  be self-granted, so `winshot` capture fails unattended, and the accessibility tree is
  empty for SwiftUI content (verified against a known-good build). `swift
  tools/winshot.swift --list helm` needs no grant and distinguishes a real window from a
  crash or a zero-sized one — and says nothing about what is drawn. Never report a surface
  as verified without the operator.
- `swift run helm` to iterate, `make app` for the real bundle.
- Conventional commits, written as a human — no AI attribution.
