/**
 * Copyright (c) 2024 Tuomo Kriikkula
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

// Performs early stats initialization to avoid accidentally
// resetting stats and experience on EGS clients.
class XPFixesMutator extends ROMutator
    config(Mutator_XPFixes_Config);

var config bool bEarlyInitEpicStats;
var config bool bSpectateLateJoinersAfterMatchEnd;
var config bool bDebugEpicStatsLifecycle;
var config float DebugEpicStatsPollInterval;

var config bool bFixHonorLevel;
var config float HonorLevelFixPollInterval;
var config float HonorLevelFixTimeout;
var config int HonorLevelFixOutageThreshold;
var config float HonorLevelFixHealthProbeInterval;

struct HonorLevelFixTrack
{
    var ROPlayerController ROPC;
    var float TrackStartTime;
};
var array<HonorLevelFixTrack> HonorLevelFixPlayers;

var int ConsecutiveHonorLevelFixTimeouts;
var bool bHonorLevelFixOutageWarned;
var array<ROPlayerController> HonorLevelFixLastUnhealthy;

struct DebugEpicPlayerTrack
{
    var ROPlayerController ROPC;
    var EOnlineEnumerationReadState LastReadState;
    var bool bLoggedReadState;
    var bool bLoggedLoaded;
};

var array<DebugEpicPlayerTrack> DebugEpicPlayers;

// Naive check based on ID length. Always 17 for Steam clients.
// **SHOULD** be less than 17 for all EGS clients.
function bool IsEgsClient(string SteamID)
{
    return Len(SteamID) > 0 && Len(SteamID) < 17;
}

function bool ShouldSpectateLateJoiner(ROPlayerController ROPC)
{
    return bSpectateLateJoinersAfterMatchEnd
        && ROPC != None
        && ROPC.PlayerReplicationInfo != None
        && WorldInfo.GRI != None
        && WorldInfo.GRI.bMatchIsOver;
}

function bool ShouldDebugEpicStats(ROPlayerController ROPC)
{
    return bDebugEpicStatsLifecycle
        && ROPC != None
        && ROPC.PlayerReplicationInfo != None
        && IsEgsClient(ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo).SteamId64);
}

function float GetDebugEpicStatsPollInterval()
{
    if (DebugEpicStatsPollInterval > 0.0)
    {
        return DebugEpicStatsPollInterval;
    }

    return 1.0;
}

function string GetStatsReadStateName(EOnlineEnumerationReadState ReadState)
{
    return string(GetEnum(enum'EOnlineEnumerationReadState', ReadState));
}

function int FindDebugEpicPlayer(ROPlayerController ROPC)
{
    local int i;

    for (i = 0; i < DebugEpicPlayers.Length; i++)
    {
        if (DebugEpicPlayers[i].ROPC == ROPC)
        {
            return i;
        }
    }

    return INDEX_NONE;
}

function RemoveDebugEpicPlayer(int Index)
{
    DebugEpicPlayers.Remove(Index, 1);

    if (DebugEpicPlayers.Length == 0)
    {
        ClearTimer('PollEpicStatsDebug');
    }
}

function TrackDebugEpicPlayer(ROPlayerController ROPC)
{
    local int Index;

    if (!ShouldDebugEpicStats(ROPC) || FindDebugEpicPlayer(ROPC) != INDEX_NONE)
    {
        return;
    }

    Index = DebugEpicPlayers.Length;
    DebugEpicPlayers.Length = Index + 1;
    DebugEpicPlayers[Index].ROPC = ROPC;
    DebugEpicPlayers[Index].LastReadState = OERS_NotStarted;

    `xpfdebug("tracking Epic stats lifecycle for"
        @ ROPC @ ROPC.PlayerReplicationInfo.PlayerName
        @ "SteamId64" @ ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo).SteamId64
    );

    SetTimer(GetDebugEpicStatsPollInterval(), true, 'PollEpicStatsDebug');
}

function PollEpicStatsDebug()
{
    local int i;
    local ROPlayerController ROPC;
    local ROPlayerReplicationInfo ROPRI;
    local EOnlineEnumerationReadState ReadState;

    for (i = DebugEpicPlayers.Length - 1; i >= 0; i--)
    {
        ROPC = DebugEpicPlayers[i].ROPC;
        if (ROPC == None || ROPC.bDeleteMe || ROPC.PlayerReplicationInfo == None)
        {
            RemoveDebugEpicPlayer(i);
            continue;
        }

        ROPRI = ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo);
        if (ROPC.StatsRead == None)
        {
            continue;
        }

        ReadState = ROPC.StatsRead.UserStatsReceivedState;
        if (!DebugEpicPlayers[i].bLoggedReadState)
        {
            `xpfdebug("Epic stats reader attached for"
                @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPRI.SteamId64
                @ "State" @ GetStatsReadStateName(ReadState)
            );

            DebugEpicPlayers[i].bLoggedReadState = true;
            DebugEpicPlayers[i].LastReadState = ReadState;
        }
        else if (DebugEpicPlayers[i].LastReadState != ReadState)
        {
            `xpfdebug("Epic stats state changed for"
                @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPRI.SteamId64
                @ "State" @ GetStatsReadStateName(ReadState)
            );

            DebugEpicPlayers[i].LastReadState = ReadState;
        }

        if (!DebugEpicPlayers[i].bLoggedLoaded
            && ReadState == OERS_Done
            && ROPC.StatsWrite != None)
        {
            `xpfdebug("Epic stats loaded for"
                @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPRI.SteamId64
                @ "Honor" @ ROPC.StatsWrite.HonorPoints
                @ "HonorLevel" @ ROPC.StatsWrite.HonorLevel
                @ "HonorPointsStart" @ ROPC.HonorPointsStart
            );

            DebugEpicPlayers[i].bLoggedLoaded = true;
            RemoveDebugEpicPlayer(i);
            continue;
        }
    }
}

function ForceLateJoinerToSpectator(ROPlayerController ROPC)
{
    if (ROPC == None || ROPC.PlayerReplicationInfo == None)
    {
        return;
    }

    ROPC.PlayerReplicationInfo.bOnlySpectator = true;
    ROPC.PlayerReplicationInfo.bIsSpectator = true;
    ROPC.PlayerReplicationInfo.bOutOfLives = true;
    ROPC.PlayerReplicationInfo.bJoinedAsSpectator = true;
    ROPC.GotoState('Spectating');
    ROPC.ClientGotoState('Spectating');
}

function SyncRuntimeSettingsFromClassDefaults()
{
    bEarlyInitEpicStats = class'XPFixesMutator'.default.bEarlyInitEpicStats;
    bSpectateLateJoinersAfterMatchEnd = class'XPFixesMutator'.default.bSpectateLateJoinersAfterMatchEnd;
    bDebugEpicStatsLifecycle = class'XPFixesMutator'.default.bDebugEpicStatsLifecycle;
    DebugEpicStatsPollInterval = class'XPFixesMutator'.default.DebugEpicStatsPollInterval;
    bFixHonorLevel = class'XPFixesMutator'.default.bFixHonorLevel;
    HonorLevelFixPollInterval = class'XPFixesMutator'.default.HonorLevelFixPollInterval;
    HonorLevelFixTimeout = class'XPFixesMutator'.default.HonorLevelFixTimeout;
    HonorLevelFixOutageThreshold = class'XPFixesMutator'.default.HonorLevelFixOutageThreshold;
    HonorLevelFixHealthProbeInterval = class'XPFixesMutator'.default.HonorLevelFixHealthProbeInterval;
}

function PreBeginPlay()
{
    super.PreBeginPlay();
    SyncRuntimeSettingsFromClassDefaults();
}

simulated event PostBeginPlay()
{
    super.PostBeginPlay();

    `xpflog("config defaults:"
        @ "bEarlyInitEpicStats=" $ class'XPFixesMutator'.default.bEarlyInitEpicStats
        @ "bSpectateLateJoinersAfterMatchEnd=" $ class'XPFixesMutator'.default.bSpectateLateJoinersAfterMatchEnd
        @ "bDebugEpicStatsLifecycle=" $ class'XPFixesMutator'.default.bDebugEpicStatsLifecycle
        @ "DebugEpicStatsPollInterval=" $ class'XPFixesMutator'.default.DebugEpicStatsPollInterval
        @ "bFixHonorLevel=" $ class'XPFixesMutator'.default.bFixHonorLevel
        @ "HonorLevelFixPollInterval=" $ class'XPFixesMutator'.default.HonorLevelFixPollInterval
        @ "HonorLevelFixTimeout=" $ class'XPFixesMutator'.default.HonorLevelFixTimeout
        @ "HonorLevelFixOutageThreshold=" $ class'XPFixesMutator'.default.HonorLevelFixOutageThreshold
        @ "HonorLevelFixHealthProbeInterval=" $ class'XPFixesMutator'.default.HonorLevelFixHealthProbeInterval
    );

    `xpflog("config runtime:"
        @ "bEarlyInitEpicStats=" $ bEarlyInitEpicStats
        @ "bSpectateLateJoinersAfterMatchEnd=" $ bSpectateLateJoinersAfterMatchEnd
        @ "bDebugEpicStatsLifecycle=" $ bDebugEpicStatsLifecycle
        @ "DebugEpicStatsPollInterval=" $ DebugEpicStatsPollInterval
        @ "bFixHonorLevel=" $ bFixHonorLevel
        @ "HonorLevelFixPollInterval=" $ HonorLevelFixPollInterval
        @ "HonorLevelFixTimeout=" $ HonorLevelFixTimeout
        @ "HonorLevelFixOutageThreshold=" $ HonorLevelFixOutageThreshold
        @ "HonorLevelFixHealthProbeInterval=" $ HonorLevelFixHealthProbeInterval
    );

    if (bFixHonorLevel && HonorLevelFixHealthProbeInterval > 0.0)
    {
        SetTimer(GetHonorLevelFixHealthProbeInterval(), true, 'ProbeHonorLevelFixHealth');
    }
}

function float GetHonorLevelFixPollInterval()
{
    if (HonorLevelFixPollInterval > 0.0)
    {
        return HonorLevelFixPollInterval;
    }

    return 1.5;
}

function float GetHonorLevelFixTimeout()
{
    if (HonorLevelFixTimeout > 0.0)
    {
        return HonorLevelFixTimeout;
    }

    return 30.0;
}

function int GetHonorLevelFixOutageThreshold()
{
    if (HonorLevelFixOutageThreshold > 0)
    {
        return HonorLevelFixOutageThreshold;
    }

    return 5;
}

function float GetHonorLevelFixHealthProbeInterval()
{
    if (HonorLevelFixHealthProbeInterval > 0.0)
    {
        return HonorLevelFixHealthProbeInterval;
    }

    return 60.0;
}

function NoteHonorLevelFixHealthy()
{
    ConsecutiveHonorLevelFixTimeouts = 0;

    if (bHonorLevelFixOutageWarned)
    {
        `xpfrecovered("HonorLevel fix recovered: stats subsystem responding again");
        bHonorLevelFixOutageWarned = false;
    }
}

function int FindHonorLevelFixPlayer(ROPlayerController ROPC)
{
    local int i;

    for (i = 0; i < HonorLevelFixPlayers.Length; i++)
    {
        if (HonorLevelFixPlayers[i].ROPC == ROPC)
        {
            return i;
        }
    }

    return INDEX_NONE;
}

function RemoveHonorLevelFixPlayer(int Index)
{
    HonorLevelFixPlayers.Remove(Index, 1);

    if (HonorLevelFixPlayers.Length == 0)
    {
        ClearTimer('PollHonorLevelFix');
    }
}

function TrackHonorLevelFixPlayer(ROPlayerController ROPC)
{
    local int Index;

    if (!bFixHonorLevel
        || ROPC == None
        || ROPC.PlayerReplicationInfo == None
        || ROPC.PlayerReplicationInfo.bBot
        || FindHonorLevelFixPlayer(ROPC) != INDEX_NONE)
    {
        return;
    }

    Index = HonorLevelFixPlayers.Length;
    HonorLevelFixPlayers.Length = Index + 1;
    HonorLevelFixPlayers[Index].ROPC = ROPC;
    HonorLevelFixPlayers[Index].TrackStartTime = WorldInfo.TimeSeconds;

    `xpftrack("tracking HonorLevel fix for"
        @ ROPC @ ROPC.PlayerReplicationInfo.PlayerName
        @ "SteamId64" @ ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo).SteamId64
    );

    SetTimer(GetHonorLevelFixPollInterval(), true, 'PollHonorLevelFix');
}

function PollHonorLevelFix()
{
    local int i;
    local ROPlayerController ROPC;
    local ROPlayerReplicationInfo ROPRI;
    local byte StatsHonorLevel;

    for (i = HonorLevelFixPlayers.Length - 1; i >= 0; i--)
    {
        ROPC = HonorLevelFixPlayers[i].ROPC;
        if (ROPC == None || ROPC.bDeleteMe || ROPC.PlayerReplicationInfo == None)
        {
            RemoveHonorLevelFixPlayer(i);
            continue;
        }

        ROPRI = ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo);
        if (ROPRI == None)
        {
            RemoveHonorLevelFixPlayer(i);
            continue;
        }

        // Short-circuit: if PRI already has a valid level, we're done —
        // don't wait on stats and don't time out during OSS outages.
        if (ROPRI.HonorLevel != 0 && ROPRI.HonorLevel != 255)
        {
            NoteHonorLevelFixHealthy();
            RemoveHonorLevelFixPlayer(i);
            continue;
        }

        // Check timeout.
        if (WorldInfo.TimeSeconds - HonorLevelFixPlayers[i].TrackStartTime > GetHonorLevelFixTimeout())
        {
            `xpftimeout("HonorLevel fix timed out for"
                @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPRI.SteamId64
                @ "PRI.HonorLevel=" $ ROPRI.HonorLevel
                @ "StatsRead=" $ (ROPC.StatsRead != None ? "present" : "None")
                @ "StatsWrite=" $ (ROPC.StatsWrite != None ? "present" : "None")
                @ "ReadState=" $ (ROPC.StatsRead != None ? GetStatsReadStateName(ROPC.StatsRead.UserStatsReceivedState) : "N/A")
                @ "StatsWrite.HonorLevel=" $ (ROPC.StatsWrite != None ? string(ROPC.StatsWrite.HonorLevel) : "N/A")
            );

            ConsecutiveHonorLevelFixTimeouts++;
            if (!bHonorLevelFixOutageWarned
                && ConsecutiveHonorLevelFixTimeouts >= GetHonorLevelFixOutageThreshold())
            {
                `xpfwarn("WARNING: HonorLevel fix appears wedged -"
                    @ ConsecutiveHonorLevelFixTimeouts
                    @ "consecutive timeouts with 0 corrections. Probable OnlineSubsystem stats outage - server process restart may be required."
                );
                bHonorLevelFixOutageWarned = true;
            }

            RemoveHonorLevelFixPlayer(i);
            continue;
        }

        // Wait for stats to finish loading.
        if (ROPC.StatsRead == None
            || ROPC.StatsRead.UserStatsReceivedState != OERS_Done
            || ROPC.StatsWrite == None)
        {
            continue;
        }

        StatsHonorLevel = byte(ROPC.StatsWrite.HonorLevel);

        // -------------------------------------------------------------------
        // OPTIONAL XP CORRECTION (disabled pending publisher approval).
        //
        // Some players have been affected by a bug that leaves their stored
        // HonorPoints as a large negative value (e.g. -1500). Because
        // ROGameStatsRead.GetHonorLevel returns 0 for any negative input,
        // these players appear at level 0 forever and any XP they earn is
        // first consumed clawing back toward zero before it counts.
        //
        // The block below would detect that condition once StatsWrite is
        // loaded and award a one-shot correction equal to -HonorPoints,
        // bringing the stored total back to 0. HonorPointsStart is patched
        // in lock-step so the AAR progress bar reads Start=0 / End=earned
        // instead of showing the bugged baseline. We then flush immediately
        // via WriteStats + FlushOnlineStats so the correction survives a
        // rage-quit or server crash before match end.
        //
        // Left commented out: awarding XP via a mutator is a publisher
        // policy decision, and mis-detection would over-reward a player
        // whose negative value is legitimate (e.g. future anti-cheat
        // clawback). Enable only with explicit sign-off.
        // -------------------------------------------------------------------
        /*
        if (ROPC.StatsWrite.HonorPoints < 0)
        {
            `xpflog("HonorPoints fix: correcting"
                @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPRI.SteamId64
                @ "from" @ ROPC.StatsWrite.HonorPoints
                @ "to 0 (delta" @ (-ROPC.StatsWrite.HonorPoints) $ ")"
            );
            ROPC.StatsWrite.IncrementIntStat(`STATID_Honor, -ROPC.StatsWrite.HonorPoints);
            ROPC.StatsWrite.UpdateHonorLevel();
            ROPC.HonorPointsStart = ROPC.StatsWrite.HonorPoints;
            StatsHonorLevel = byte(ROPC.StatsWrite.HonorLevel);

            ROPC.WriteStats();
            if (WorldInfo.GRI != None && WorldInfo.Game != None
                && ROGameInfo(WorldInfo.Game) != None
                && ROGameInfo(WorldInfo.Game).OnlineSub != None
                && ROGameInfo(WorldInfo.Game).OnlineSub.StatsInterface != None)
            {
                ROGameInfo(WorldInfo.Game).OnlineSub.StatsInterface.FlushOnlineStats('Game');
            }
        }
        */

        // Stats loaded but HonorLevel is 0 in StatsWrite too — nothing to fix.
        if (StatsHonorLevel == 0)
        {
            `xpflog("HonorLevel fix: StatsWrite.HonorLevel is also 0 for"
                @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPRI.SteamId64
                $ ", skipping"
            );
            NoteHonorLevelFixHealthy();
            RemoveHonorLevelFixPlayer(i);
            continue;
        }

        // Fix: server-side set the correct HonorLevel on the PRI.
        `xpfok("HonorLevel fix: correcting"
            @ ROPC.PlayerReplicationInfo.PlayerName
            @ "SteamId64" @ ROPRI.SteamId64
            @ "from" @ ROPRI.HonorLevel
            @ "to" @ StatsHonorLevel
        );
        ROPRI.HonorLevel = StatsHonorLevel;
        NoteHonorLevelFixHealthy();
        RemoveHonorLevelFixPlayer(i);
    }
}

function ProbeHonorLevelFixHealth()
{
    local int TotalPlayers, StatsReadNone, StatsReadDone, StatsReadNotDone, StatsWriteNone;
    local int PersistentUnhealthy;
    local ROPlayerController ROPC;
    local ROGameInfo ROGI;
    local string OSSState;
    local string HealthState;
    local string ProbeMsg;
    local array<ROPlayerController> CurrentUnhealthy;
    local bool bUnhealthy;

    foreach WorldInfo.AllControllers(class'ROPlayerController', ROPC)
    {
        if (ROPC.PlayerReplicationInfo == None || ROPC.PlayerReplicationInfo.bBot)
        {
            continue;
        }

        TotalPlayers++;
        bUnhealthy = false;

        if (ROPC.StatsRead == None)
        {
            StatsReadNone++;
            bUnhealthy = true;
        }
        else if (ROPC.StatsRead.UserStatsReceivedState == OERS_Done)
        {
            StatsReadDone++;
        }
        else
        {
            StatsReadNotDone++;
            bUnhealthy = true;
        }

        if (ROPC.StatsWrite == None)
        {
            StatsWriteNone++;
            bUnhealthy = true;
        }

        if (bUnhealthy)
        {
            CurrentUnhealthy.AddItem(ROPC);
            if (HonorLevelFixLastUnhealthy.Find(ROPC) != INDEX_NONE)
            {
                PersistentUnhealthy++;
            }
        }
    }

    HonorLevelFixLastUnhealthy = CurrentUnhealthy;

    ROGI = ROGameInfo(WorldInfo.Game);
    if (ROGI == None)
    {
        OSSState = "ROGameInfo=None";
    }
    else if (ROGI.OnlineSub == None)
    {
        OSSState = "OnlineSub=None";
    }
    else if (ROGI.OnlineSub.StatsInterface == None)
    {
        OSSState = "StatsInterface=None";
    }
    else
    {
        OSSState = "OK";
    }

    if (OSSState != "OK" || bHonorLevelFixOutageWarned)
    {
        HealthState = "FAIL";
    }
    else if (PersistentUnhealthy > 0)
    {
        HealthState = "DEGRADED";
    }
    else
    {
        HealthState = "OK";
    }

    ProbeMsg = "HonorLevel fix health probe:"
        @ "health=" $ HealthState
        @ "players=" $ TotalPlayers
        @ "tracked=" $ HonorLevelFixPlayers.Length
        @ "StatsRead[None=" $ StatsReadNone $ ",Done=" $ StatsReadDone $ ",NotDone=" $ StatsReadNotDone $ "]"
        @ "StatsWriteNone=" $ StatsWriteNone
        @ "persistent_unhealthy=" $ PersistentUnhealthy
        @ "OSS=" $ OSSState
        @ "consecutive_timeouts=" $ ConsecutiveHonorLevelFixTimeouts
        @ "outage_warned=" $ bHonorLevelFixOutageWarned;

    if (HealthState == "FAIL")
    {
        `xpfwarn(ProbeMsg);
    }
    else if (HealthState == "DEGRADED")
    {
        `xpfdegraded(ProbeMsg);
    }
    else
    {
        `xpfok(ProbeMsg);
    }
}

function NotifyLogin(Controller NewPlayer)
{
    local ROPlayerController ROPC;

`if(`isdefined(XPFIXES_DEBUG))
    if (PlayerController(NewPlayer) != None && NewPlayer.PlayerReplicationInfo != None)
    {
        `xpflog("NewPlayer:" @ NewPlayer
            @ "PC" @ PlayerController(NewPlayer)
            @ "PRI" @ PlayerController(NewPlayer).PlayerReplicationInfo
            @ "SteamId64" @ ROPlayerReplicationInfo(NewPlayer.PlayerReplicationInfo).SteamId64
            @ "bEgsClient" @ PlayerController(NewPlayer).PlayerReplicationInfo.bEgsClient
            @ "IsEgsClient" @ IsEgsClient(ROPlayerReplicationInfo(NewPlayer.PlayerReplicationInfo).SteamId64)
        );
    }
`endif

    ROPC = ROPlayerController(NewPlayer);
    TrackHonorLevelFixPlayer(ROPC);
    TrackDebugEpicPlayer(ROPC);

    if (ShouldSpectateLateJoiner(ROPC))
    {
        `xpflog("forcing late joiner to spectator during match end for"
            @ ROPC @ ROPC.PlayerReplicationInfo.PlayerName
            @ "SteamId64" @ ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo).SteamId64
        );

        ForceLateJoinerToSpectator(ROPC);
    }

    if (bEarlyInitEpicStats
        && ROPC != None
        && ROPC.PlayerReplicationInfo != None
        && IsEgsClient(ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo).SteamId64)
        // && ROPC.PlayerReplicationInfo.bEgsClient // TODO: this does not work this early?
    )
    {
        `xpflog("performing early stats init for"
            @ ROPC @ ROPC.PlayerReplicationInfo.PlayerName
            @ ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo).SteamId64
        );

        ROPC.InitializeStats();
    }

    super.NotifyLogin(NewPlayer);
}

function NotifyLogout(Controller Exiting)
{
    local int Index;
    local ROPlayerController ROPC;
    local DebugEpicPlayerTrack Track;

    ROPC = ROPlayerController(Exiting);

    Index = FindHonorLevelFixPlayer(ROPC);
    if (Index != INDEX_NONE)
    {
        RemoveHonorLevelFixPlayer(Index);
    }

    Index = FindDebugEpicPlayer(ROPC);
    if (Index != INDEX_NONE)
    {
        Track = DebugEpicPlayers[Index];
        if (!Track.bLoggedLoaded && ROPC.PlayerReplicationInfo != None)
        {
            `xpftimeout("WARNING: Epic client disconnected before stats finished loading for"
                @ ROPC @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo).SteamId64
                @ "LastState" @ GetStatsReadStateName(Track.LastReadState)
                @ "HonorPointsStart" @ ROPC.HonorPointsStart
            );
        }

        `xpflog("stopping Epic stats lifecycle tracking for"
            @ ROPC
            @ (ROPC.PlayerReplicationInfo != None ? ROPC.PlayerReplicationInfo.PlayerName : "unknown")
        );

        RemoveDebugEpicPlayer(Index);
    }

    super.NotifyLogout(Exiting);
}

`if(`isdefined(XPFIXES_DEBUG))

function ROMutate(string MutateString, PlayerController Sender, out string ResultMsg)
{
    local array<string> Args;

    Args = SplitString(MutateString);

    if (Locs(Args[0]) == "endmatch")
    {
        ROGameInfo(WorldInfo.Game).MatchWon(0, ROWC_MatchEndTime, 0, 0, 0);
    }

    super.ROMutate(MutateString, Sender, ResultMsg);
}

`endif

