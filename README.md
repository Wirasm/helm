# helm

The native macOS surface you work in: libghostty terminals where your CLI agent (pi,
Claude Code, codex) runs, arranged with the files it writes into a workbench — columns of
tabbed slots, several panes on screen at once — with workspaces above it. Markdown and
HTML are rendered from the filesystem; there is no backend.

"Agent" always means a CLI agent you already run. helm hosts it in a terminal it owns and
renders what it writes. It does not build or host an agent of its own.

Status: **rebuilding.** The kild layer was removed — see `docs/direction.md` for where
this is going, and `docs/SPIKE.md` for the terminal lifecycle contract that everything
else rests on.

## A second Claude account

benchd can start each new Claude agent on whichever of two Claude subscriptions has quota to
spend (`daemon/direction.md`, "which Claude login"). The second login is its own config dir that
links to `~/.claude` for everything but the login, so agents on it run your settings, hooks,
skills, plugins and `CLAUDE.md`, and their conversations stay where `bench log`, resume and
Pocket find them. Once:

1. `just claude-account add ~/.claude-b`: links the dir, seeds its `.claude.json` (trust, MCP
   servers, onboarding; never your login), and lists it in `~/.bench/accounts.toml`.
2. `CLAUDE_CONFIG_DIR=/Users/<you>/.claude-b claude`, exactly the path `add` printed, then
   `/login` with the second account and `/exit`. The login goes to its own keychain item; the
   default one is untouched.
3. In the same session, `/mcp` to sign in to any MCP server that uses OAuth, if agents on the
   second account need it.

After you trust a new top-level folder or add an MCP server in your default login, run
`just claude-account seed ~/.claude-b` with no claude running on it. The status bar shows the
second login's plan as `Claude .claude-b`.

## Running

- `swift run helm` (or `make run`) — fast SPM iteration loop; no bundle, no signing.
- `make app` — the real Helm.app bundle via XcodeGen (`project.yml` → Helm.xcodeproj
  → xcodebuild; needs `xcodegen`). The target echoes the built .app path.
- `make build` / `make test` / `make lint` / `make clean`.

Both paths build the same sources against the same local package, `Packages/GhosttyTerminal`
(named in `Package.swift` AND `project.yml`). The terminal is a real GhosttyKit surface:
official Ghostty, built by us at a pinned commit and fetched prebuilt by SPM, so no zig is
needed to build helm. `docs/VENDORED.md` ("Ghostty") says how the pin moves.
