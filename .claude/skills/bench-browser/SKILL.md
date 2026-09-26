---
name: bench-browser
description: Use the operator's shared browser — the one Chrome benchd runs, where he is logged in to his accounts and can watch what you do in a helm pane. Use when a task needs a real browser, a logged-in session, or a web page the operator should see; when the operator says "use the browser", "in my browser", "log in and…", "check the site"; or before reaching for any other browser tool.
---

# The shared browser

There is **one** browser on the bench: a Chrome that `benchd` starts and keeps running, with the
operator's logins in its profile. He sees it in a helm pane, and you drive it with Playwright.
Use it rather than starting a browser of your own. A second browser has none of his sessions,
and he can't see it.

## Get the endpoint

```bash
BENCH="${BENCH:-bench}"
OUT=$("$BENCH" browser start) || exit
CDP=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cdp"])')
echo "$CDP"
```

`browser start` starts the browser, or finds it running, and prints its endpoint. `cdp` is what
Playwright takes. The `|| exit` keeps bench's exit code and its reason (on stderr), rather than
handing Playwright an empty endpoint. Always go through `browser start` rather than reading
`browser/endpoint.json` yourself: the file is simply missing when the browser is down or open
for setup, and only `start` starts it or tells you why it can't. Exit codes: `0` ok · `2` no daemon · `3` refused (the reason names the fix) · `4`
the browser did not come up.

It refuses while the operator has the browser open in a window for setup (installing
extensions, signing in). That window is a plain Chrome with no debugging port, so there is
nothing to attach to. Leave it alone. It comes back by itself when he quits that window, and
`"$BENCH" browser status` shows `"mode": "headless"` again.

## Drive it with Playwright

```text
playwright-cli -s=<your-name> attach --cdp="$CDP"
playwright-cli -s=<your-name> tab-new https://example.com
playwright-cli -s=<your-name> snapshot
playwright-cli -s=<your-name> detach
```

- **Attach, never `open`.** `open` launches a separate browser without his logins.
- **Work in a tab of your own** (`tab-new`), and do not navigate the tab he is looking at unless
  he asked you to. The pane follows whichever tab opens or navigates, so he sees your work
  either way.
- **`detach` when you are done.** It disconnects you and leaves the browser and its tabs running.
  Never stop the browser (`bench browser stop`) unless he asked. Other agents may be using it.
- Playwright MCP works too, with `--cdp-endpoint "$CDP"`.

## Show it to him

The browser lives in his `browser` drawer, over the bench. One command puts it there and badges
the drawer, without opening it or taking his keyboard:

```text
swift <helm checkout>/tools/helm-command.swift openBrowser
```

He opens it with ⌘⇧B or the drawer's capsule on the status bar, when he chooses. Tell him it is
there; never try to open the drawer for him.

## Facts with edges

- Logins, cookies and extensions live in the profile under the bench root and survive restarts.
  A crashed browser is restarted automatically, and the endpoint changes when it restarts, so
  run `browser start` again rather than reusing an old `$CDP`.
- It is real Google Chrome where installed (else Chrome for Testing), headless, with a normal
  Chrome user agent, so sites that refuse headless browsers accept it.
- A login that needs his password or 2FA is his to do. He signs in through the pane, or through
  `bench browser setup` when it needs browser UI the pane can't show (an extension, a passkey
  prompt). Then continue in the same session.
