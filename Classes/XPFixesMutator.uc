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

struct HonorLevelFixTrack
{
    var ROPlayerController ROPC;
    var float TrackStartTime;
};
var array<HonorLevelFixTrack> HonorLevelFixPlayers;

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
    return Len(SteamID) < 17;
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

    `xpflog("tracking Epic stats lifecycle for"
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
            `xpflog("Epic stats reader attached for"
                @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPRI.SteamId64
                @ "State" @ GetStatsReadStateName(ReadState)
            );

            DebugEpicPlayers[i].bLoggedReadState = true;
            DebugEpicPlayers[i].LastReadState = ReadState;
        }
        else if (DebugEpicPlayers[i].LastReadState != ReadState)
        {
            `xpflog("Epic stats state changed for"
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
            `xpflog("Epic stats loaded for"
                @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPRI.SteamId64
                @ "Honor" @ ROPC.StatsWrite.HonorPoints
                @ "HonorLevel" @ ROPC.StatsWrite.HonorLevel
                @ "HonorPointsStart" @ ROPC.HonorPointsStart
            );

            DebugEpicPlayers[i].bLoggedLoaded = true;
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
    );

    `xpflog("config runtime:"
        @ "bEarlyInitEpicStats=" $ bEarlyInitEpicStats
        @ "bSpectateLateJoinersAfterMatchEnd=" $ bSpectateLateJoinersAfterMatchEnd
        @ "bDebugEpicStatsLifecycle=" $ bDebugEpicStatsLifecycle
        @ "DebugEpicStatsPollInterval=" $ DebugEpicStatsPollInterval
        @ "bFixHonorLevel=" $ bFixHonorLevel
        @ "HonorLevelFixPollInterval=" $ HonorLevelFixPollInterval
        @ "HonorLevelFixTimeout=" $ HonorLevelFixTimeout
    );
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

    `xpflog("tracking HonorLevel fix for"
        @ ROPC @ ROPC.PlayerReplicationInfo.PlayerName
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

        // Check timeout.
        if (WorldInfo.TimeSeconds - HonorLevelFixPlayers[i].TrackStartTime > GetHonorLevelFixTimeout())
        {
            `xpflog("HonorLevel fix timed out for"
                @ ROPC.PlayerReplicationInfo.PlayerName
                @ "PRI.HonorLevel=" $ ROPRI.HonorLevel
            );
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

        // If PRI already has a valid level, we're done.
        if (ROPRI.HonorLevel != 0 && ROPRI.HonorLevel != 255)
        {
            RemoveHonorLevelFixPlayer(i);
            continue;
        }

        // Stats loaded but HonorLevel is 0 in StatsWrite too — nothing to fix.
        if (StatsHonorLevel == 0)
        {
            `xpflog("HonorLevel fix: StatsWrite.HonorLevel is also 0 for"
                @ ROPC.PlayerReplicationInfo.PlayerName
                $ ", skipping"
            );
            RemoveHonorLevelFixPlayer(i);
            continue;
        }

        // Fix: server-side set the correct HonorLevel on the PRI.
        `xpflog("HonorLevel fix: correcting"
            @ ROPC.PlayerReplicationInfo.PlayerName
            @ "from" @ ROPRI.HonorLevel
            @ "to" @ StatsHonorLevel
        );
        ROPRI.HonorLevel = StatsHonorLevel;
        RemoveHonorLevelFixPlayer(i);
    }
}

function NotifyLogin(Controller NewPlayer)
{
    local ROPlayerController ROPC;

`if(`isdefined(XPFIXES_DEBUG))
    `xpflog("NewPlayer:" @ NewPlayer
        @ "PC" @ PlayerController(NewPlayer)
        @ "PRI" @ PlayerController(NewPlayer).PlayerReplicationInfo
        @ "SteamId64" @ ROPlayerReplicationInfo(NewPlayer.PlayerReplicationInfo).SteamId64
        @ "bEgsClient" @ PlayerController(NewPlayer).PlayerReplicationInfo.bEgsClient
        @ "IsEgsClient" @ IsEgsClient(ROPlayerReplicationInfo(NewPlayer.PlayerReplicationInfo).SteamId64)
    );
`endif

    ROPC = ROPlayerController(NewPlayer);
    TrackHonorLevelFixPlayer(ROPC);
    TrackDebugEpicPlayer(ROPC);

    if (ShouldSpectateLateJoiner(ROPC))
    {
        `xpflog("forcing late joiner to spectator during match end for"
            @ ROPC @ ROPC.PlayerReplicationInfo.PlayerName
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
        if (!Track.bLoggedLoaded)
        {
            `xpflog("WARNING: Epic client disconnected before stats finished loading for"
                @ ROPC @ ROPC.PlayerReplicationInfo.PlayerName
                @ "SteamId64" @ ROPlayerReplicationInfo(ROPC.PlayerReplicationInfo).SteamId64
                @ "LastState" @ GetStatsReadStateName(Track.LastReadState)
                @ "HonorPointsStart" @ ROPC.HonorPointsStart
            );
        }

        `xpflog("stopping Epic stats lifecycle tracking for"
            @ ROPC @ ROPC.PlayerReplicationInfo.PlayerName
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

