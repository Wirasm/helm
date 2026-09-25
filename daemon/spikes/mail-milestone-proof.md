# Mail milestone — the acceptance proof

**2026-08-18, `just mail-proof`, first run green.** Three real agents (claude, codex,
pi) in daemon ptys, handles `post-claude`/`post-codex`/`post-pi`, briefed by file. The
operator seeded `100` as mail; each agent was WOKEN by the production reactor (notice:
path + sender, never the body), `cat`-ed the real message file, computed N+1, and sent
onward through the real `bench mail send` — from-identity resolved from `BENCH_HANDLE`,
which the daemon declared into its pty. `103` arrived back from `post-pi` and was
collected with `bench mail read`.

Event trail, verbatim shape: `mail/sent → agent/woken` ×4, then `mail/read`. The fourth
wake is the honest observation: the ring protocol is unbounded (claude, woken by the
returning 103, would have sent 104), and the run stayed sane because the wake cap is a
per-recipient token bucket in the courier. **Stop conditions live in briefs; the brake
lives in the reactor** — the group-room spike's lesson, now load-bearing in production.

What the conformance suite pins beyond this run (27 tests, real binaries):
notice-carries-path-never-body observed through the relay; retirement at delivery;
retire-never-delete; metadata-only listings; the cap starving wakes but never mail;
`operator` addressable-never-claimable; duplicate and path-shaped handles refused.

Rerun anytime: `just mail-proof` (three small agent turns).
