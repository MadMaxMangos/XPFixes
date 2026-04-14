# Negative HonorPoints Correction (Disabled)

## Symptom

A small number of players have their stored `HonorPoints` stuck at a large
negative value (e.g. `-1500`). Because `ROGameStatsRead.GetHonorLevel` returns
`0` for any negative input, these players are permanently displayed as level 0
and any XP they earn is first consumed clawing back toward zero before it
starts counting toward the next level.

This is distinct from the HonorLevel 0 display bug described in
[HONOR_LEVEL_FIX.md](HONOR_LEVEL_FIX.md) — that one is a client-side race on
replication. This one is persisted corruption of the backend stat itself, so
the existing HonorLevel workaround cannot recover it.

## Where the fix would live

See the commented-out block inside `PollHonorLevelFix` in
[Classes/XPFixesMutator.uc](Classes/XPFixesMutator.uc), guarded by the same
`StatsRead == OERS_Done && StatsWrite != None` wait the HonorLevel fix already
uses.

## What it would do

When a tracked player's stats finish loading and `StatsWrite.HonorPoints < 0`:

1. Award a one-shot delta of `-HonorPoints` via
   `StatsWrite.IncrementIntStat(STATID_Honor, ...)` so the stored total
   becomes `0`.
2. Call `StatsWrite.UpdateHonorLevel()` to recompute the level from the new
   points value.
3. Patch `ROPC.HonorPointsStart` to match, so the AAR progress bar reads
   `Start=0 / End=earned` instead of exposing the bugged baseline.
4. Immediately call `ROPC.WriteStats()` and
   `OnlineSub.StatsInterface.FlushOnlineStats('Game')` so the correction
   persists even if the player rage-quits or the server crashes before
   match end.

## Why it is disabled

Awarding XP from a mutator is a publisher policy decision. Mis-detection
would over-reward any player whose negative `HonorPoints` is legitimate
(for example a future anti-cheat clawback, or an intentional admin
adjustment). The block is left in the source — commented out with intent
documented inline — so it can be enabled cleanly once approval is granted,
without needing to re-derive the detection path or the flush sequence.

## Enabling

Uncomment the block in `PollHonorLevelFix`. No config flag is currently
exposed; if enabled for production, add a `bFixNegativeHonorPoints` config
bool alongside `bFixHonorLevel` so it can be toggled per server.

## Caveats

- The fix runs once per session per player (the existing poll-list removal
  handles that). A player who somehow re-corrupts mid-session would need to
  reconnect.
- `FlushOnlineStats` is async and can fail silently. Logging the
  before/after `HonorPoints` gives a trail to verify the write stuck,
  especially for EGS clients where `XPFixesMutator` already has lifecycle
  debug hooks.
- The player will see their displayed `HonorLevel` snap from 0 to the
  correct level mid-match as soon as the fix applies. That is the intended
  visible confirmation.
