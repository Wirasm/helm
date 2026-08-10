#!/bin/bash
# spike322 T4b — WHY did pi refuse the sibling import? Symlink, or relative import, or both?
# Four variants, one variable changed at a time.
set -u
SPIKE=/Users/rasmus/Projects/mine/sild/helm/.claude/worktrees/agent-a8fd5cb1964e14a8d/spike322
export HELM_DEFAULTS_SUITE=spike322
T=$(mktemp -d /tmp/spike322-imp.XXXXXX)
cd "$T" || exit 1

run_pi () { timeout 120 pi -p -ne -e "$1" --no-session "say only: ok" 2>&1 | grep -iE "spike322|Cannot find|Failed to load|error" | head -4; }

echo "=== 1. REAL PATH (no symlink), relative sibling import ==="
run_pi "$SPIKE/pi-ext/index.ts"

echo
echo "=== 2. SYMLINKED DIRECTORY, relative sibling import (the way pi extensions install) ==="
mkdir -p "$T/ext1"; ln -s "$SPIKE/pi-ext" "$T/ext1/spike322"
run_pi "$T/ext1/spike322/index.ts"

echo
echo "=== 3. SYMLINKED FILE, relative sibling import ==="
mkdir -p "$T/ext2/spike322"; ln -s "$SPIKE/pi-ext/index.ts" "$T/ext2/spike322/index.ts"
run_pi "$T/ext2/spike322/index.ts"

echo
echo "=== 4. REAL PATH, ABSOLUTE import specifier ==="
mkdir -p "$T/ext3/spike322"
sed "s#\"../bench-mail-core.mjs\"#\"$SPIKE/bench-mail-core.mjs\"#" "$SPIKE/pi-ext/index.ts" > "$T/ext3/spike322/index.ts"
grep -n "bench-mail-core" "$T/ext3/spike322/index.ts"
run_pi "$T/ext3/spike322/index.ts"

echo
echo "=== 5. SYMLINKED DIRECTORY + absolute import specifier ==="
mkdir -p "$T/ext4"; ln -s "$T/ext3/spike322" "$T/ext4/spike322"
run_pi "$T/ext4/spike322/index.ts"

echo
echo "=== 6. the alternative the ticket actually proposes: the extension SHELLS OUT to the CLI ==="
mkdir -p "$T/ext5/spike322"
cat > "$T/ext5/spike322/index.ts" <<TS
import { execFileSync } from "node:child_process";
export default function (pi: any): void {
  const out = execFileSync("$SPIKE/bench-mail", ["list"], { encoding: "utf8" });
  console.error("[spike322] SHELLED OUT to the CLI, got " + out.trim().split("\\n").length + " rows");
}
TS
run_pi "$T/ext5/spike322/index.ts"

echo
echo "T=$T"
