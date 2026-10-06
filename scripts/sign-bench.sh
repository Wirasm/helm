#!/bin/bash
# Re-sign the installed bench and benchd with an Apple Development certificate and a fixed identifier.
#
# cargo signs ad hoc under a name ending in the build's hash, so macOS takes every release for a new
# program and asks again for each privacy grant (the agents run under benchd, so their file reads are
# benchd's). Signed this way the designated requirement is identifier + certificate, which a rebuild
# keeps, and an Allow given once holds across releases.
#
# Usage: sign-bench.sh <bin-dir>. With no Apple Development identity in the keychain (a contributor,
# CI) it says so and leaves the ad hoc signature: the binaries still run, the prompts just come back.
# Callers treat a failure as a warning for the same reason.
set -u
bin="${1:?usage: sign-bench.sh <bin-dir>}"
identity="$(security find-identity -v -p codesigning 2>/dev/null |
  sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
if [ -z "$identity" ]; then
  echo "sign-bench: no Apple Development identity; bench and benchd stay ad hoc signed" >&2
  exit 0
fi
for name in bench benchd; do
  timeout 60 codesign --force --sign "$identity" --identifier "com.wirasm.$name" --timestamp=none \
    "$bin/$name" || { echo "sign-bench: signing $bin/$name failed; it keeps cargo's ad hoc signature" >&2; exit 1; }
done
echo "sign-bench: bench and benchd signed by $identity"
