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

If the client could be patched, either of these would resolve it:

### Option A: Delay the timer

Move the `SetTimer(1.0, true, 'UpdateStats')` from `InitializeStats()` into the `OnStatsInitialized` callback so `UpdateStats` never fires before stats are loaded.

### Option B: Guard inside UpdateStats

At line 8037, don't call `SetHonorLevel` if stats haven't finished loading:

```
if (StatsRead != None && StatsRead.UserStatsReceivedState == OERS_Done)
{
    ROPlayerReplicationInfo(PlayerReplicationInfo).SetHonorLevel(byte(StatsWrite.HonorLevel));
}
```

### Option C: Make the RPC reliable

Change `SetHonorLevel` from `unreliable server` to `reliable server` so the correct value isn't lost to packet drops. The dev comment says "unreliable because it's called quite a bit" but it's a single byte -- the overhead is negligible.

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
