-module(display).
-export([start/1, start/2]).

-define(MAP_SIZE, 40).
-define(IDLE_TIMEOUT, 10000).
-define(FRAME_ROWS, 74).
-define(PARK_ROW, 75).
-define(FRAME_COLS, 85).

-define(RESET,   "\e[0m").
-define(BOLD,    "\e[1m").
-define(RED,     "\e[31m").
-define(GREEN,   "\e[32m").
-define(YELLOW,  "\e[33m").
-define(BLUE,    "\e[34m").
-define(MAGENTA, "\e[35m").
-define(CYAN,    "\e[36m").
-define(WHITE,   "\e[37m").
-define(DIM,     "\e[2m").

-define(HIDE, "\e[?25l").
-define(SHOW, "\e[?25h").
-define(ERASE_RIGHT, "\e[K").

start(WorldPid) ->
    start(WorldPid, ?IDLE_TIMEOUT).

start(_WorldPid, Timeout) ->
    spawn(fun() -> loop(Timeout, dirty_screen()) end).

loop(Timeout, Painted) ->
    receive
        {render, Characters, Enemies, Shops, Inns, EventLog, MoveCount} ->
            Lines = frame_lines(Characters, Enemies, Shops, Inns, EventLog, MoveCount),
            io:format("~s", [update(Painted, Lines)]),
            loop(Timeout, Lines)
    after Timeout ->
        loop(Timeout, Painted)
    end.

dirty_screen() ->
    lists:duplicate(?FRAME_ROWS, lists:duplicate(?FRAME_COLS, dirty)).

update(Painted, Lines) ->
    [?HIDE, frame_ops(Painted, Lines), addr(?PARK_ROW, 1), ?SHOW].

frame_ops(Painted, Lines) ->
    Height = max(length(Painted), length(Lines)),
    Rows = lists:zip3(lists:seq(1, Height), fill(Painted, Height, []), fill(Lines, Height, [])),
    [line_ops(Row, Was, Now) || {Row, Was, Now} <- Rows].

fill(Items, Length, Filler) ->
    Items ++ lists:duplicate(Length - length(Items), Filler).

line_ops(_Row, Same, Same) ->
    [];
line_ops(Row, Was, Now) ->
    Width = max(length(Was), length(Now)),
    Cols = lists:zip3(lists:seq(1, Width), fill(Was, Width, blank), fill(Now, Width, blank)),
    [[paint(Row, Col, Cells) || {Col, Cells} <- runs(Cols)],
     clear_tail(Row, length(Was), length(Now))].

runs([]) ->
    [];
runs([{_Col, Same, Same} | Rest]) ->
    runs(Rest);
runs([{Col, _Was, Now} | Rest]) ->
    {Cells, Tail} = run_cells(Rest, [Now]),
    [{Col, Cells} | runs(Tail)].

run_cells([{_Col, Same, Same} | _] = Tail, Acc) ->
    {lists:reverse(Acc), Tail};
run_cells([], Acc) ->
    {lists:reverse(Acc), []};
run_cells([{_Col, _Was, Now} | Rest], Acc) ->
    run_cells(Rest, [Now | Acc]).

paint(Row, Col, Cells) ->
    painted(Row, Col, [Cell || Cell <- Cells, Cell =/= blank]).

painted(_Row, _Col, []) ->
    [];
painted(Row, Col, Cells) ->
    [addr(Row, Col), cell_bytes(Cells, none), ?RESET].

cell_bytes([], _Style) ->
    [];
cell_bytes([{Style, Char} | Rest], Style) ->
    [Char | cell_bytes(Rest, Style)];
cell_bytes([{Style, Char} | Rest], _Other) ->
    [?RESET, Style, Char | cell_bytes(Rest, Style)].

clear_tail(Row, WasWidth, NowWidth) when WasWidth > NowWidth ->
    [addr(Row, NowWidth + 1), ?ERASE_RIGHT];
clear_tail(_Row, _WasWidth, _NowWidth) ->
    [].

addr(Row, Col) ->
    io_lib:format("\e[~p;~pH", [Row, Col]).

frame_lines(Characters, Enemies, Shops, Inns, EventLog, MoveCount) ->
    Lines = header_lines(MoveCount)
        ++ map_lines(Characters, Enemies, Shops, Inns)
        ++ [legend_line()]
        ++ roster_lines(Characters)
        ++ [enemies_line(Enemies)]
        ++ event_lines(EventLog),
    lists:sublist(Lines, ?FRAME_ROWS).

styled_line(Parts) ->
    Cells = [[{Style, Char} || Char <- lists:flatten(Text)] || {Style, Text} <- Parts],
    lists:sublist(lists:append(Cells), ?FRAME_COLS).

header_lines(MoveCount) ->
    [styled_line([{?BOLD ++ ?CYAN, io_lib:format("=== CMD RPG [~p moves] ===", [MoveCount])}]), []].

map_lines(Characters, Enemies, Shops, Inns) ->
    Grid = build_grid(Characters, Enemies, Shops, Inns),
    [border_line()] ++ [row_line(Y, Grid) || Y <- lists:seq(0, ?MAP_SIZE - 1)] ++ [border_line()].

border_line() ->
    styled_line([{"", "  "}, {?DIM, "+" ++ lists:duplicate(?MAP_SIZE * 2 + 1, $-) ++ "+"}]).

row_line(Y, Grid) ->
    Cells = [cell_part(maps:get({X, Y}, Grid, empty)) || X <- lists:seq(0, ?MAP_SIZE - 1)],
    styled_line([{"", "  "}, {?DIM, "|"}] ++ Cells ++ [{?DIM, "|"}]).

cell_part(empty) ->
    {?DIM, ". "};
cell_part({shop, _Name}) ->
    {?BOLD ++ ?YELLOW, "$ "};
cell_part({inn, _Name}) ->
    {?BOLD ++ ?BLUE, "H "};
cell_part({char, _Name, Level, solo}) ->
    {?BOLD ++ char_color(Level), "@ "};
cell_part({char, _Name, Level, leader}) ->
    {?BOLD ++ char_color(Level), "& "};
cell_part({char, _Name, _Level, follower}) ->
    {?DIM ++ ?CYAN, "+ "};
cell_part({enemy, _Name, _Level}) ->
    {?BOLD ++ ?RED, "! "}.

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

char_color(Level) when Level >= 5 -> ?MAGENTA;
char_color(Level) when Level >= 3 -> ?YELLOW;
char_color(_Level) -> ?GREEN.

legend_line() ->
    styled_line([{"", "  "},
                 {?BOLD ++ ?GREEN, "@ "}, {"", "Hero  "},
                 {?BOLD ++ ?GREEN, "& "}, {"", "Party  "},
                 {?BOLD ++ ?RED, "! "}, {"", "Enemy  "},
                 {?BOLD ++ ?YELLOW, "$ "}, {"", "Shop  "},
                 {?BOLD ++ ?BLUE, "H "}, {"", "Inn"}]).

roster_lines(Characters) ->
    {Leaders, Solos, Followers} = split_roles(Characters),
    Parties = [party_lines(Leader, Followers, Characters) || Leader <- Leaders],
    [[], styled_line([{"", "  "}, {?BOLD ++ ?CYAN, "Heroes:"}])]
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
    [styled_line([{"", "  "}, {?BOLD ++ ?CYAN, "--- Party: " ++ Members ++ " ---"}]),
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
    styled_line([{"", Indent},
                 role_icon(maps:get(party_role, Info, solo)),
                 {?BOLD, maps:get(name, Info)},
                 {"", io_lib:format(" (~s) Lv~p  ", [RaceStr, Level])},
                 {hp_color(Hp, MaxHp), io_lib:format("HP:~p/~p", [Hp, MaxHp])},
                 {"", io_lib:format("  XP:~p/~p  ",
                                    [maps:get(exp, Info), combat:exp_to_level(Level)])},
                 {?YELLOW, io_lib:format("~pg", [maps:get(gold, Info, 0)])},
                 {"", bonus_str(maps:get(attack_bonus, Info), maps:get(defense_bonus, Info))}]).

hp_color(Hp, MaxHp) when Hp * 3 < MaxHp -> ?RED;
hp_color(Hp, MaxHp) when Hp * 3 < MaxHp * 2 -> ?YELLOW;
hp_color(_Hp, _MaxHp) -> ?GREEN.

bonus_str(0, 0) -> "";
bonus_str(A, 0) -> io_lib:format(" +~pATK", [A]);
bonus_str(0, D) -> io_lib:format(" +~pDEF", [D]);
bonus_str(A, D) -> io_lib:format(" +~pATK +~pDEF", [A, D]).

role_icon(leader) -> {?CYAN, "& "};
role_icon(follower) -> {?DIM, "+ "};
role_icon(solo) -> {?GREEN, "@ "}.

enemies_line(Enemies) ->
    styled_line([{"", "  "},
                 {?DIM ++ ?RED, io_lib:format("Enemies on map: ~p", [maps:size(Enemies)])}]).

event_lines(EventLog) ->
    [[], styled_line([{"", "  "}, {?BOLD ++ ?YELLOW, "Log:"}])] ++ log_lines(EventLog).

log_lines([]) ->
    [styled_line([{"", "    "}, {?DIM, "> (quiet...)"}])];
log_lines(EventLog) ->
    [styled_line([{"", "    "}, {?DIM, "> "}, {"", Evt}]) || Evt <- recent(EventLog)].

recent(EventLog) when length(EventLog) > 12 ->
    lists:nthtail(length(EventLog) - 12, EventLog);
recent(EventLog) ->
    EventLog.
