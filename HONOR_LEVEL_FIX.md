# HonorLevel 0 Display Bug

## Symptom

Players sometimes appear as level 0 next to their name in-game, even when they are high level (up to level 99). The correct level typically appears after the player respawns.

## Root Cause (Client-Side)

The bug is a race condition between async stats loading and PRI replication.

### The sequence

1. `HonorLevel` on `ROPlayerReplicationInfo` defaults to `255` (sentinel for "not yet loaded") in `ROPlayerReplicationInfo.uc:2344`.

2. When a player joins, `InitializeStats()` in `ROPlayerController.uc:1484` kicks off an **async** `ReadStats()` call to load stats from Steam/online storage.

3. On the client, a **1-second repeating timer** `'UpdateStats'` starts immediately (`ROPlayerController.uc:1501`), before the async stats read completes.

4. `UpdateStats()` (`ROPlayerController.uc:8037`) calls:
   ```
   ROPlayerReplicationInfo(PlayerReplicationInfo).SetHonorLevel(byte(StatsWrite.HonorLevel));
   ```
   But `StatsWrite.HonorLevel` is still `0` (default int) because the async read hasn't finished yet.

5. `SetHonorLevel` on the PRI (`ROPlayerReplicationInfo.uc:1352`) is declared as **`unreliable server`**:
   ```
   unreliable server function SetHonorLevel(byte WithHonorLevel)
   {
       HonorLevel = WithHonorLevel;
   }
   ```
   This sends `HonorLevel = 0` to the server. Being unreliable, the packet can also be dropped entirely.

6. The server accepts the `0`, sets it on the PRI, and replicates it to all clients. Everyone sees the player as level 0.

### Why it fixes on respawn

By the time a player respawns, the async stats read has long completed. `StatsWrite.HonorLevel` now holds the correct value. The next `UpdateStats` tick sends the real level, which the server accepts and replicates.

## Key Source Files

| File | Line(s) | What |
|------|---------|------|
| `ROPlayerReplicationInfo.uc` | 107 | `var repnotify byte HonorLevel;` declaration |
| `ROPlayerReplicationInfo.uc` | 229 | Replication block includes `HonorLevel` |
| `ROPlayerReplicationInfo.uc` | 1352 | `unreliable server function SetHonorLevel()` |
| `ROPlayerReplicationInfo.uc` | 2344 | `HonorLevel=255` default |
| `ROPlayerController.uc` | 1484-1501 | `InitializeStats()` starts async read + 1s timer |
| `ROPlayerController.uc` | 8018-8037 | `UpdateStats()` sends HonorLevel to server |
| `ROGameStatsRead.uc` | 291 | Stats callback populates `StatsWrite.HonorLevel` |

## Proper Client-Side Fix

The bug has two distinct parts, and the fixes have different priorities:

### Part 1: Client sends `0` because stats aren't loaded yet (primary cause)

The 1-second `UpdateStats` timer fires before the async stats read finishes. At that point `StatsWrite.HonorLevel` is still `0` (default int), so the client sends `SetHonorLevel(0)` to the server. **Reliable vs unreliable makes no difference here** -- the client is sending bad data regardless.

### Part 2: Correct value can be lost to packet drops (secondary)

Once stats finally load, the client sends `SetHonorLevel(47)` every tick. With `unreliable`, those packets can drop and the server stays stuck at `0`. With `reliable`, the correct value is guaranteed to eventually arrive.

### Fix priority

**Main fix -- prevent the bad send (either of these solves the root cause):**

**Option A: Delay the timer.** Move the `SetTimer(1.0, true, 'UpdateStats')` from `InitializeStats()` into the `OnStatsInitialized` callback so `UpdateStats` never fires before stats are loaded.

**Option B: Guard inside UpdateStats.** At line 8037, don't call `SetHonorLevel` if stats haven't finished loading:

```
if (StatsRead != None && StatsRead.UserStatsReceivedState == OERS_Done)
{
    ROPlayerReplicationInfo(PlayerReplicationInfo).SetHonorLevel(byte(StatsWrite.HonorLevel));
}
```

**Secondary fix -- hardening:**

**Option C: Make the RPC reliable.** Change `SetHonorLevel` from `unreliable server` to `reliable server` so the correct value isn't lost to packet drops. The dev comment says "unreliable because it's called quite a bit" but it's a single byte -- the overhead is negligible. This alone does **not** fix the bug (the initial bad `0` still gets sent), but it guarantees recovery once stats load.

### TL;DR

The root cause is the timer firing too early, not the unreliable RPC. Options A or B are the real fixes. Option C is good hardening on top.

## Related: Stat Reset Risk

The same timing race condition can cause **actual stat resets** (permanent loss of HonorLevel, XP, etc. on Steam/Epic storage), not just display bugs. The existing XPFixesMutator comment already warns about this:

> "Performs early stats initialization to avoid accidentally resetting stats and experience on EGS clients."

### How the reset happens

`WriteStats` at [ROPlayerController.uc:12940](../../RS2_Src/ROGame/Classes/ROPlayerController.uc) does:

```
exec function WriteStats(optional bool bOnlySaveAchievements)
{
    if (!bOnlySaveAchievements)
    {
        UpdateStats();  // writes StatsWrite.HonorLevel into PRI
    }

    if (OnlineSub != None && StatsWrite != None)
    {
        OnlineSub.StatsInterface.WriteOnlineStats('Game', ..., StatsWrite);  // persists to storage
    }
}
```

If `WriteStats` runs before the async stats read completes, `StatsWrite.HonorLevel` is still `0` -- and that zero gets pushed to persistent storage, overwriting the player's real level permanently.

### Display fix does NOT prevent resets

The server-side HonorLevel fix in this mutator corrects `PRI.HonorLevel` on the server (for display), but it does **not** touch `StatsWrite`. If `WriteStats` fires before stats load, the reset has already happened in storage before our poll timer runs.

### What prevents resets

The existing XPFixesMutator features mitigate this:

- `bEarlyInitEpicStats` -- gives the async read a head start so it's more likely done before any write
- `bSpectateLateJoinersAfterMatchEnd` -- prevents late joiners' stats from being written at all

### The real reset fix

A proper fix would guard `WriteStats` / `WriteOnlineStats` against running when `StatsRead.UserStatsReceivedState != OERS_Done`. This would need to live client-side since `WriteStats` is called from many `exec` / simulated paths that a server mutator can't easily intercept.

## Server-Side Workaround (XPFixesMutator)

Since the client cannot be patched, `XPFixesMutator` includes a server-side workaround enabled with `bFixHonorLevel=true`.

### How it works

1. On player login (`NotifyLogin`), the mutator starts tracking the player.
2. A polling timer (`PollHonorLevelFix`) checks every 1.5 seconds (configurable).
3. It waits for `StatsRead.UserStatsReceivedState == OERS_Done` (stats fully loaded on server).
4. Once loaded, if the PRI's `HonorLevel` is `0` or `255` but `StatsWrite.HonorLevel` has a valid value, the mutator directly sets `ROPRI.HonorLevel` on the server.
5. The corrected value replicates to all clients via the existing `repnotify` mechanism.
6. Tracking stops once fixed or after a 30-second timeout.

### Edge cases

- **Genuine level 0 players**: `StatsWrite.HonorLevel` will also be `0`, so the mutator skips them (no false correction).
- **Players whose level replicated correctly**: PRI already has a valid level (not 0 or 255), so the mutator removes them from tracking immediately.
- **Stats never load**: The 30-second timeout prevents indefinite polling.

### Configuration

In `ROMutator_XPFixes_Config.ini`:

```ini
bFixHonorLevel=true              ; Enable/disable the fix
HonorLevelFixPollInterval=1.5    ; Seconds between checks
HonorLevelFixTimeout=30.0        ; Give up after this many seconds
```

### Limitation

There is still a brief window (1-3 seconds after joining) where a player may appear as level 0 before the server-side fix kicks in. This is unavoidable without a client patch.
