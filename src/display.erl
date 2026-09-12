-module(display).
-export([start/1, start/2]).

-define(MAP_SIZE, 40).
-define(IDLE_TIMEOUT, 10000).

start(WorldPid) ->
    start(WorldPid, ?IDLE_TIMEOUT).

start(_WorldPid, Timeout) ->
    spawn(fun() -> loop(Timeout, screen:unpainted()) end).

loop(Timeout, Screen) ->
    receive
        {render, Characters, Enemies, Shops, Inns, EventLog, MoveCount} ->
            Lines = frame_lines(Characters, Enemies, Shops, Inns, EventLog, MoveCount),
            {Bytes, Painted} = screen:update(Screen, Lines),
            io:format("~s", [Bytes]),
            loop(Timeout, Painted)
    after Timeout ->
        loop(Timeout, Screen)
    end.

frame_lines(Characters, Enemies, Shops, Inns, EventLog, MoveCount) ->
    header_lines(MoveCount)
        ++ map_lines(Characters, Enemies, Shops, Inns)
        ++ [legend_line()]
        ++ roster_lines(Characters)
        ++ [enemies_line(Enemies)]
        ++ event_lines(EventLog).

header_lines(MoveCount) ->
    [[{[bold, cyan], io_lib:format("=== CMD RPG [~p moves] ===", [MoveCount])}], []].

map_lines(Characters, Enemies, Shops, Inns) ->
    Grid = build_grid(Characters, Enemies, Shops, Inns),
    [border_line()] ++ [row_line(Y, Grid) || Y <- lists:seq(0, ?MAP_SIZE - 1)] ++ [border_line()].

border_line() ->
    [{[], "  "}, {[dim], "+" ++ lists:duplicate(?MAP_SIZE * 2 + 1, $-) ++ "+"}].

row_line(Y, Grid) ->
    Cells = [cell_part(maps:get({X, Y}, Grid, empty)) || X <- lists:seq(0, ?MAP_SIZE - 1)],
    [{[], "  "}, {[dim], "|"}] ++ Cells ++ [{[dim], "|"}].

cell_part(empty) ->
    {[dim], ". "};
cell_part({shop, _Name}) ->
    {[bold, yellow], "$ "};
cell_part({inn, _Name}) ->
    {[bold, blue], "H "};
cell_part({char, _Name, Level, solo}) ->
    {[bold, char_color(Level)], "@ "};
cell_part({char, _Name, Level, leader}) ->
    {[bold, char_color(Level)], "& "};
cell_part({char, _Name, _Level, follower}) ->
    {[dim, cyan], "+ "};
cell_part({enemy, _Name, _Level}) ->
    {[bold, red], "! "}.

build_grid(Characters, Enemies, Shops, Inns) ->
    G0 = lists:foldl(fun(#{name := IName, x := IX, y := IY}, Acc) ->
        Acc#{{IX, IY} => {inn, IName}}
    end, #{}, Inns),
    G1 = lists:foldl(fun(#{name := SName, x := SX, y := SY}, Acc) ->
        Acc#{{SX, SY} => {shop, SName}}
    end, G0, Shops),
    G2 = maps:fold(fun(_Pid, Info, Acc) ->
        X = maps:get(x, Info),
        Y = maps:get(y, Info),
        Name = maps:get(name, Info),
        Level = maps:get(level, Info),
        Acc#{{X, Y} => {enemy, Name, Level}}
    end, G1, Enemies),
    {Followers, Others} = maps:fold(fun(_Pid, Info, {FAcc, OAcc}) ->
        case maps:get(party_role, Info, solo) of
            follower -> {[Info | FAcc], OAcc};
            _ -> {FAcc, [Info | OAcc]}
        end
    end, {[], []}, Characters),
    G3 = lists:foldl(fun(Info, Acc) ->
        place_char(Info, follower, Acc)
    end, G2, Followers),
    lists:foldl(fun(Info, Acc) ->
        place_char(Info, maps:get(party_role, Info, solo), Acc)
    end, G3, Others).

place_char(Info, Role, Grid) ->
    X = maps:get(x, Info),
    Y = maps:get(y, Info),
    Name = maps:get(name, Info),
    Level = maps:get(level, Info),
    Grid#{{X, Y} => {char, Name, Level, Role}}.

char_color(Level) when Level >= 5 -> magenta;
char_color(Level) when Level >= 3 -> yellow;
char_color(_Level) -> green.

legend_line() ->
    [{[], "  "},
     {[bold, green], "@ "}, {[], "Hero  "},
     {[bold, green], "& "}, {[], "Party  "},
     {[bold, red], "! "}, {[], "Enemy  "},
     {[bold, yellow], "$ "}, {[], "Shop  "},
     {[bold, blue], "H "}, {[], "Inn"}].

roster_lines(Characters) ->
    {Leaders, Solos, Followers} = split_roles(Characters),
    Parties = [party_lines(Leader, Followers, Characters) || Leader <- Leaders],
    [[], [{[], "  "}, {[bold, cyan], "Heroes:"}]]
        ++ lists:append(Parties)
        ++ solo_lines(Solos).

split_roles(Characters) ->
    maps:fold(fun(Pid, Info, {LAcc, SAcc, FAcc}) ->
        case maps:get(party_role, Info, solo) of
            leader -> {[{Pid, Info} | LAcc], SAcc, FAcc};
            solo -> {LAcc, [Info | SAcc], FAcc};
            follower -> {LAcc, SAcc, [Info | FAcc]}
        end
    end, {[], [], []}, Characters).

party_lines({_LeaderPid, LeaderInfo}, Followers, Characters) ->
    LName = maps:get(name, LeaderInfo),
    FollowerPids = maps:get(follower_pids, LeaderInfo, []),
    FollowerNames = follower_names(Followers, FollowerPids, Characters),
    Members = string:join([LName | FollowerNames], " + "),
    [[{[], "  "}, {[bold, cyan], "--- Party: " ++ Members ++ " ---"}],
     hero_line("    ", LeaderInfo)]
        ++ follower_lines(Followers, FollowerNames)
        ++ [[]].

follower_names(Followers, FollowerPids, Characters) ->
    [maps:get(name, FI) || FI <- Followers, is_follower_of(FI, FollowerPids, Characters)].

is_follower_of(FollowerInfo, FollowerPids, Characters) ->
    lists:any(fun(FPid) ->
        follower_named(FPid, maps:get(name, FollowerInfo), Characters)
    end, FollowerPids).

follower_named(FPid, Name, Characters) ->
    case maps:find(FPid, Characters) of
        {ok, FChar} -> maps:get(name, FChar) =:= Name;
        error -> false
    end.

follower_lines(Followers, FollowerNames) ->
    [hero_line("      ", FInfo) || FInfo <- Followers,
                                   lists:member(maps:get(name, FInfo), FollowerNames)].

solo_lines(Solos) ->
    SortedSolos = lists:sort(fun(A, B) ->
        maps:get(level, A) >= maps:get(level, B)
    end, Solos),
    [hero_line("    ", Info) || Info <- SortedSolos].

hero_line(Indent, Info) ->
    Level = maps:get(level, Info),
    Hp = maps:get(hp, Info),
    MaxHp = maps:get(max_hp, Info),
    RaceStr = util:race_label(maps:get(race, Info, human)),
    [{[], Indent},
     role_icon(maps:get(party_role, Info, solo)),
     {[bold], maps:get(name, Info)},
     {[], io_lib:format(" (~s) Lv~p  ", [RaceStr, Level])},
     {[hp_color(Hp, MaxHp)], io_lib:format("HP:~p/~p", [Hp, MaxHp])},
     {[], io_lib:format("  XP:~p/~p  ", [maps:get(exp, Info), combat:exp_to_level(Level)])},
     {[yellow], io_lib:format("~pg", [maps:get(gold, Info, 0)])},
     {[], bonus_str(maps:get(attack_bonus, Info), maps:get(defense_bonus, Info))}].

hp_color(Hp, MaxHp) when Hp * 3 < MaxHp -> red;
hp_color(Hp, MaxHp) when Hp * 3 < MaxHp * 2 -> yellow;
hp_color(_Hp, _MaxHp) -> green.

bonus_str(0, 0) -> "";
bonus_str(A, 0) -> io_lib:format(" +~pATK", [A]);
bonus_str(0, D) -> io_lib:format(" +~pDEF", [D]);
bonus_str(A, D) -> io_lib:format(" +~pATK +~pDEF", [A, D]).

role_icon(leader) -> {[cyan], "& "};
role_icon(follower) -> {[dim], "+ "};
role_icon(solo) -> {[green], "@ "}.

enemies_line(Enemies) ->
    [{[], "  "}, {[dim, red], io_lib:format("Enemies on map: ~p", [maps:size(Enemies)])}].

event_lines(EventLog) ->
    [[], [{[], "  "}, {[bold, yellow], "Log:"}]] ++ log_lines(EventLog).

log_lines([]) ->
    [[{[], "    "}, {[dim], "> (quiet...)"}]];
log_lines(EventLog) ->
    [[{[], "    "}, {[dim], "> "}, {[], Evt}] || Evt <- recent(EventLog)].

recent(EventLog) when length(EventLog) > 12 ->
    lists:nthtail(length(EventLog) - 12, EventLog);
recent(EventLog) ->
    EventLog.
