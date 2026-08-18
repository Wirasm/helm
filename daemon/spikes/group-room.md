# Spike: a group mailbox — one room, three runtimes, fan-out wakes

**Question**: does the mailbox generalize to a GROUP — a shared room where a message
from any member reaches every other member — on the same primitives the ring spike
proved (files, an event log, pty-paste wakes)? The genuinely new risks: fan-out (one
message wakes N−1 agents), loop amplification (every answer is itself a message that
wakes everyone again), and the assignment discipline (members hold full file tools but
are pointed at exactly one message per wake).

**Verdict: PROVEN.** 2026-08-18. A room is a directory; a message is a file; the
reactor wakes every member except the author. Three members (claude, codex, pi, helm
postures), one seeded question (9×9), protocol: answer once as a file, NOOP every other
wake, read only the file the notice names.

## The measurement

- **All three answer files correct** (`member-x: 81`), no double-posts.
- **Exactly 9 wakes** — the fan-out arithmetic to the wake (3 for the seed + 3 answers
  × 2 non-authors), against a cap of 12 that was never hit.
- **6 NOOP turns observed** — every answer-notice was received, read, and correctly
  declined by members who had already posted. The room **settled on its own** in 46.9s:
  traffic stopped because the protocol said stop, not because the cap fired.
- Concurrency was real: wakes about one message landed while other members were
  mid-turn on the previous one; the per-agent idle wait serialized delivery per member
  while members ran concurrently.

## Design consequences

- **A group is not a new mechanism.** Room = shared inbox directory; fan-out = the same
  `mail/received ⇒ agent/wake` reactor with "everyone but the author" as the recipient
  set. `bench-mail`'s model needs one concept (a recipient set on a mailbox), not a
  second subsystem.
- **The amplification math is the thing to respect**: N members turn one message into
  N−1 wakes, and every reply compounds it. A wake cap per room per window (the spike
  carried 12) is the loop brake, and it belongs in the reactor — the mailbox stays pure.
- **The assignment discipline held under temptation.** Members had unrestricted file
  tools and a directory full of siblings; pointed notices ("read only that file") were
  followed. Capability open, policy in the brief — the posture, observed working.
- Not exercised: rooms at 5+, cross-room traffic, a member joining mid-conversation,
  and adversarial protocol violation. The first busy real room will say more than
  another synthetic run would.

Harness: scratchpad `pty-spike/src/bin/group_spike.rs` (throwaway; this file is the
deliverable). Companions: `pty-ownership-verdict.md`, `mail-wake-verdict.md`.
