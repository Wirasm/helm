# Spike: agent-to-agent mail with wakes, across runtimes, as log reactions

**Question**: can agent↔agent mail — pi⇄claude⇄codex, all directions — work as nothing
but (a) files as the record, (b) an event log, (c) a reactor that answers
`mail/received` with `agent/wake`, using the pty-paste wake the pty spike proved?
This is the operator's own decomposition — *"mailbox is mailbox; if the daemon can
`agent/spawn`, then `mail/received ⇒ agent/wake` is just a reaction"* — put under test.

**Verdict: PROVEN.** 2026-08-18, same throwaway harness family as the pty spike
(`portable-pty`, headless, no controlling terminal). Three agents in harness-owned
ptys; a number seeded as mail and passed around the ring, **each hop adds 1** — so a
correct final value cannot come from echoes; every runtime must read real mail, compute,
and send real mail.

## The measurement

Ring `claude → codex → pi → claude`, seed 100, expected 103. Result: **103, cycle
31.5s**, hops at 0.8s / 9.0s / 20.5s / 31.5s (~10s per hop: wake + read + compute +
write). Ready-to-brief time for all three agents: 10.5s. Postures: helm's
`SpoolUnattendedPolicy` (claude `--dangerously-skip-permissions`, codex
`--dangerously-bypass-approvals-and-sandbox`, pi `--approve`).

The harness's own `events.jsonl` is the deliverable's shape as well as its evidence:

```
agent/spawned ×3 → agent/ready ×3 → mail/sent (harness seed)
→ mail/received(post-claude) → agent/woken(post-claude)
→ mail/received(post-codex)  → agent/woken(post-codex)
→ mail/received(post-pi)     → agent/woken(post-pi)
→ mail/received(post-claude, body 103) → cycle/complete
```

## Design consequences

- **The pty is the universal wake transport.** One mechanism woke all three runtimes —
  paste the notice (path, never body) into an idle composer, submit separately. No
  per-runtime sockets were needed. Claude's session socket (#320, 0.12s) and `claude
  --bg` remain available as *optimizations* for one runtime, to be evaluated at M3 as
  the roadmap already says — they are not load-bearing for the design.
- **Wake policy is a reactor over the log, not part of mail.** The mailbox stayed pure
  (directories + files + `mail/*` events); waking was a separate loop subscribing to
  `mail/received`. Spawn-on-mail is the same reactor with one more rule —
  `mail/received` for a handle with no live pane ⇒ `agent/spawn` — and loop caps on
  agent↔agent chains belong in this reactor too (bench-side, roadmap M2).
- **Idle detection was the crude form and it sufficed** (pty quiet ≥2s). benchd's taps
  (M1) make this judgement properly — which is the dependency that put attention before
  mail in the roadmap. The spike confirms the *rest* of M2 carries no comparable risk.
- **Crate shape**: the mailbox rules (roots, handles, notice format) want to be a
  `bench-mail` crate beside `bench-wire` — usable by benchd's verbs and by a standalone
  CLI, which covers the "portable, maybe its own app" instinct without a second daemon.

## Honest limits

- The ring covered 3 of 6 directed pairs (each runtime sent once and received once);
  the mechanism is pair-agnostic, but the other three pairs were not run.
- Recipients were sequenced idle; concurrent cross-traffic, a busy recipient, and the
  wake-while-thinking case were not exercised — that is tap territory.
- One cosmetic harness bug: the `cycle/complete` log line prints Rust's `Some(103)`
  rather than plain JSON. The measurement stands; the line would not pass benchd's own
  boot-time log scan, which is a nice accidental proof of why that scan exists.

Harness: scratchpad `pty-spike/src/bin/mail_spike.rs` (throwaway; this file is the
deliverable). Companion: `pty-ownership-verdict.md`.
