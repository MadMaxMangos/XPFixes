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
    config(Mutator_XPFixes);

var config bool bEarlyInitEpicStats;
var config bool bSpectateLateJoinersAfterMatchEnd;

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

DefaultProperties
{
    bEarlyInitEpicStats=true
    bSpectateLateJoinersAfterMatchEnd=true
}
