-module(display).
-export([start/1, start/2]).

-define(MAP_SIZE, 40).
-define(IDLE_TIMEOUT, 10000).
-define(FALLBACK_COLS, 85).
-define(FALLBACK_ROWS, 75).
-define(MIN_COLS, 20).
-define(MIN_ROWS, 10).
-define(RESERVED_ROWS, 18).
-define(LOG_SIZE, 12).

start(WorldPid) ->
    start(WorldPid, ?IDLE_TIMEOUT).

start(_WorldPid, Timeout) ->
    spawn(fun() -> loop(Timeout, screen:unpainted()) end).

loop(Timeout, Screen) ->
    receive
        {render, Characters, Enemies, Shops, Inns, EventLog, MoveCount} ->
            Size = terminal_size(io:columns(), io:rows()),
            World = {Characters, Enemies, Shops, Inns, EventLog, MoveCount},
            {Bytes, Painted} = screen:update(Screen, frame_lines(World, Size), Size),
            io:format("~s", [Bytes]),
            loop(Timeout, Painted)
    after Timeout ->
        loop(Timeout, Screen)
    end.

terminal_size({ok, Cols}, {ok, Rows}) ->
    {Cols, Rows};
terminal_size(_Cols, _Rows) ->
    {?FALLBACK_COLS, ?FALLBACK_ROWS}.

frame_lines(_World, {Cols, Rows}) when Cols < ?MIN_COLS; Rows < ?MIN_ROWS ->
    [[{[], "Terminal too small"}]];
frame_lines({Characters, Enemies, Shops, Inns, EventLog, MoveCount}, {Cols, Rows}) ->
    Top = [header_line(MoveCount)]
        ++ map_lines(scale(Cols, Rows), marks(Characters, Enemies, Shops, Inns))
        ++ [legend_line()]
        ++ roster_lines(Characters)
        ++ [enemies_line(Enemies), log_title_line()],
    Top ++ log_lines(EventLog, Rows - 1 - length(Top)).

scale(Cols, Rows) ->
    Fit = max(1, lists:min([?MAP_SIZE, Rows - ?RESERVED_ROWS, (Cols - 5) div 2])),
    ceil(?MAP_SIZE / Fit).

header_line(MoveCount) ->
    [{[bold, cyan], io_lib:format("=== CMD RPG [~p moves] ===", [MoveCount])}].

map_lines(Scale, Marks) ->
    Side = ceil(?MAP_SIZE / Scale),
    Grid = lists:foldl(fun(Mark, Acc) -> strongest(Scale, Mark, Acc) end, #{}, Marks),
    Border = border_line(Side),
    [Border] ++ [row_line(Row, Side, Grid) || Row <- lists:seq(0, Side - 1)] ++ [Border].

border_line(Side) ->
    [{[], "  "}, {[dim], "+" ++ lists:duplicate(Side * 2 + 1, $-) ++ "+"}].

row_line(Row, Side, Grid) ->
    Cells = [element(2, maps:get({Col, Row}, Grid, {{0, 0}, {[dim], ". "}}))
             || Col <- lists:seq(0, Side - 1)],
    [{[], "  "}, {[dim], "|"}] ++ Cells ++ [{[dim], "|"}].

strongest(Scale, {#{x := X, y := Y}, Mark}, Grid) ->
    maps:update_with({X div Scale, Y div Scale}, fun(Held) -> max(Held, Mark) end, Mark, Grid).

marks(Characters, Enemies, Shops, Inns) ->
    [{Inn, {{1, 0}, {[bold, blue], "H "}}} || Inn <- Inns]
        ++ [{Shop, {{2, 0}, {[bold, yellow], "$ "}}} || Shop <- Shops]
        ++ [{Enemy, {{3, 0}, {[bold, red], "! "}}} || Enemy <- maps:values(Enemies)]
        ++ [{Hero, hero_mark(maps:get(party_role, Hero, solo), maps:get(level, Hero))}
            || Hero <- maps:values(Characters)].

hero_mark(follower, _Level) ->
    {{4, 0}, {[dim, cyan], "+ "}};
hero_mark(solo, Level) ->
    {{5, Level}, {[bold, char_color(Level)], "@ "}};
hero_mark(leader, Level) ->
    {{6, Level}, {[bold, char_color(Level)], "& "}}.

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
    [[{[], "  "}, {[bold, cyan], "Heroes:"}]]
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
        ++ follower_lines(Followers, FollowerNames).

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

log_title_line() ->
    [{[], "  "}, {[bold, yellow], "Log:"}].

log_lines([], Room) ->
    last([[{[], "    "}, {[dim], "> (quiet...)"}]], Room);
log_lines(EventLog, Room) ->
    [[{[], "    "}, {[dim], "> "}, {[], Evt}] || Evt <- last(EventLog, min(?LOG_SIZE, Room))].

last(Items, Count) ->
    lists:nthtail(max(0, length(Items) - max(0, Count)), Items).
