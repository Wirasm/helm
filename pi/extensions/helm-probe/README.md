# helm-probe

Reports which parts of pi's extension API this pi actually gave it.

That is deliberately trivial, and it is genuinely useful exactly once per pi upgrade: it is the
answer to *"is my extension alive under this pi, and what does this pi still offer?"* — asked
from inside a real session rather than inferred from a changelog.

It is also the reference shape. Copy this directory to start the next extension; the rules that
keep an extension from taking pi down travel with the file. See [../../AGENTS.md](../../AGENTS.md).

## What it registers

| Surface | Name | Notes |
|---|---|---|
| Event handler | `session_start` | Reports through `ctx.ui.notify` at startup. |
| Command | `/helm-probe` | The same report, on demand. |
| Tool | `helm_probe` | The same report, callable by the model. |

Every one of the three is feature-detected before it is registered, and each is installed
independently — a pi that has lost one still gets the other two, and says on stderr which one
went missing.

## Install

```bash
ln -s "$(git rev-parse --show-toplevel)/pi/extensions/helm-probe" ~/.pi/agent/extensions/helm-probe
```

A symlink, so editing in the repo is what ships. Remove the symlink to uninstall. Nothing is
copied and nothing is built — pi loads the TypeScript directly.

## Switch it off without uninstalling

```bash
HELM_PROBE_OFF=1 pi
```

An environment variable rather than a CLI flag, and that is not a style choice: measured on
0.83.0, `pi.getFlag()` inside a factory returns the flag's registered *default*, never the value
on argv, because argv is bound to extension flags only after every extension has loaded. A
flag-based kill switch would read correctly and do nothing.

## Run it in isolation

```bash
pi --no-extensions -e "$(git rev-parse --show-toplevel)/pi/extensions/helm-probe/index.ts"
```

## Test it

```bash
bash pi/test.sh          # typecheck, unit, rpc, pty — none of them calls a model
```
