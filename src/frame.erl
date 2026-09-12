-module(frame).
-export([lines/2]).

-define(MAP_SIZE, 40).
-define(MIN_COLS, 20).
-define(MIN_ROWS, 10).
-define(RESERVED_ROWS, 18).
-define(GRID_FRAME_COLS, 5).
-define(LOG_SIZE, 12).
-define(EMPTY_MARK, {{0, 0}, {[dim], ". "}}).

-type attribute() :: bold | dim | red | green | yellow | blue | magenta | cyan.
-type part() :: {[attribute()], io_lib:chars()}.
-type line() :: [part()].
-type role() :: solo | leader | follower.
-type hero() :: #{name := string(),
                    level := pos_integer(),
                    hp := integer(),
                    max_hp := pos_integer(),
                    exp := non_neg_integer(),
                    x := non_neg_integer(),
                    y := non_neg_integer(),
                    attack_bonus := integer(),
                    defense_bonus := integer(),
                    gold => non_neg_integer(),
                    race => util:race(),
                    party_role => role(),
                    follower_pids => [pid()],
                    atom() => term()}.
-type located() :: #{x := non_neg_integer(), y := non_neg_integer(), atom() => term()}.
-type heroes() :: #{pid() => hero()}.
-type world() :: {heroes(), #{pid() => located()}, [located()], [located()],
                    [io_lib:chars()], non_neg_integer()}.
-type size() :: {pos_integer(), pos_integer()}.
-type mark() :: {{0..6, non_neg_integer()}, part()}.
-type grid() :: #{{non_neg_integer(), non_neg_integer()} => mark()}.

-spec lines(world(), size()) -> [line()].
lines(_World, {Cols, Rows}) when Cols < ?MIN_COLS; Rows < ?MIN_ROWS ->
    [[{[], "Terminal too small"}]];
lines({Characters, Enemies, Shops, Inns, EventLog, MoveCount}, {Cols, Rows}) ->
    Top = [header_line(MoveCount)]
        ++ map_lines(scale(Cols, Rows), marks(Characters, Enemies, Shops, Inns))
        ++ [legend_line()]
        ++ roster_lines(Characters)
        ++ [enemies_line(Enemies), log_title_line()],
    Top ++ log_lines(EventLog, Rows - 1 - length(Top)).

-spec scale(pos_integer(), pos_integer()) -> pos_integer().
scale(Cols, Rows) ->
    Side = max(1, lists:min([?MAP_SIZE, Rows - ?RESERVED_ROWS, (Cols - ?GRID_FRAME_COLS) div 2])),
    ceil((?MAP_SIZE) / Side).

-spec header_line(non_neg_integer()) -> line().
header_line(MoveCount) ->
    [{[bold, cyan], io_lib:format("=== CMD RPG [~p moves] ===", [MoveCount])}].

-spec map_lines(pos_integer(), [{located(), mark()}]) -> [line()].
map_lines(Scale, Marks) ->
    Side = ceil((?MAP_SIZE) / Scale),
    Grid = lists:foldl(fun(Mark, Acc) -> strongest(Scale, Mark, Acc) end, #{}, Marks),
    Border = border_line(Side),
    [Border] ++ [row_line(Row, Side, Grid) || Row <- lists:seq(0, Side - 1)] ++ [Border].

-spec border_line(pos_integer()) -> line().
border_line(Side) ->
    [{[], "  "}, {[dim], "+" ++ lists:duplicate(Side * 2 + 1, $-) ++ "+"}].

-spec row_line(non_neg_integer(), pos_integer(), grid()) -> line().
row_line(Row, Side, Grid) ->
    Cells = [glyph(maps:get({Col, Row}, Grid, ?EMPTY_MARK)) || Col <- lists:seq(0, Side - 1)],
    [{[], "  "}, {[dim], "|"}] ++ Cells ++ [{[dim], "|"}].

-spec glyph(mark()) -> part().
glyph({_Rank, Glyph}) ->
    Glyph.

-spec strongest(pos_integer(), {located(), mark()}, grid()) -> grid().
strongest(Scale, {#{x := X, y := Y}, Mark}, Grid) ->
    maps:update_with({X div Scale, Y div Scale}, fun(Held) -> max(Held, Mark) end, Mark, Grid).

-spec marks(heroes(), #{pid() => located()}, [located()], [located()]) -> [{located(), mark()}].
marks(Characters, Enemies, Shops, Inns) ->
    [{Inn, {{1, 0}, {[bold, blue], "H "}}} || Inn <- Inns]
        ++ [{Shop, {{2, 0}, {[bold, yellow], "$ "}}} || Shop <- Shops]
        ++ [{Enemy, {{3, 0}, {[bold, red], "! "}}} || Enemy <- maps:values(Enemies)]
        ++ [{Hero, hero_mark(maps:get(party_role, Hero, solo), maps:get(level, Hero))}
            || Hero <- maps:values(Characters)].

-spec hero_mark(role(), pos_integer()) -> mark().
hero_mark(follower, _Level) ->
    {{4, 0}, {[dim, cyan], "+ "}};
hero_mark(solo, Level) ->
    {{5, Level}, {[bold, char_color(Level)], "@ "}};
hero_mark(leader, Level) ->
    {{6, Level}, {[bold, char_color(Level)], "& "}}.

-spec char_color(pos_integer()) -> magenta | yellow | green.
char_color(Level) when Level >= 5 -> magenta;
char_color(Level) when Level >= 3 -> yellow;
char_color(_Level) -> green.

-spec legend_line() -> line().
legend_line() ->
    [{[], "  "},
        {[bold, green], "@ "}, {[], "Hero  "},
        {[bold, green], "& "}, {[], "Party  "},
        {[bold, red], "! "}, {[], "Enemy  "},
        {[bold, yellow], "$ "}, {[], "Shop  "},
        {[bold, blue], "H "}, {[], "Inn"}].

-spec roster_lines(heroes()) -> [line()].
roster_lines(Characters) ->
    {Leaders, Solos, Followers} = split_roles(Characters),
    Parties = [party_lines(Leader, Followers, Characters) || Leader <- Leaders],
    [[{[], "  "}, {[bold, cyan], "Heroes:"}]]
        ++ lists:append(Parties)
        ++ solo_lines(Solos).

-spec split_roles(heroes()) -> {[{pid(), hero()}], [hero()], [hero()]}.
split_roles(Characters) ->
    maps:fold(fun(Pid, Info, {LAcc, SAcc, FAcc}) ->
        case maps:get(party_role, Info, solo) of
            leader -> {[{Pid, Info} | LAcc], SAcc, FAcc};
            solo -> {LAcc, [Info | SAcc], FAcc};
            follower -> {LAcc, SAcc, [Info | FAcc]}
        end
    end, {[], [], []}, Characters).

-spec party_lines({pid(), hero()}, [hero()], heroes()) -> [line()].
party_lines({_LeaderPid, LeaderInfo}, Followers, Characters) ->
    LName = maps:get(name, LeaderInfo),
    FollowerPids = maps:get(follower_pids, LeaderInfo, []),
    FollowerNames = follower_names(Followers, FollowerPids, Characters),
    Members = string:join([LName | FollowerNames], " + "),
    [[{[], "  "}, {[bold, cyan], "--- Party: " ++ Members ++ " ---"}],
        hero_line("    ", LeaderInfo)]
        ++ follower_lines(Followers, FollowerNames).

-spec follower_names([hero()], [pid()], heroes()) -> [string()].
follower_names(Followers, FollowerPids, Characters) ->
    [maps:get(name, FI) || FI <- Followers, is_follower_of(FI, FollowerPids, Characters)].

-spec is_follower_of(hero(), [pid()], heroes()) -> boolean().
is_follower_of(FollowerInfo, FollowerPids, Characters) ->
    lists:any(fun(FPid) ->
        follower_named(FPid, maps:get(name, FollowerInfo), Characters)
    end, FollowerPids).

-spec follower_named(pid(), string(), heroes()) -> boolean().
follower_named(FPid, Name, Characters) ->
    case maps:find(FPid, Characters) of
        {ok, FChar} -> maps:get(name, FChar) =:= Name;
        error -> false
    end.

-spec follower_lines([hero()], [string()]) -> [line()].
follower_lines(Followers, FollowerNames) ->
    [hero_line("      ", FInfo) || FInfo <- Followers,
        lists:member(maps:get(name, FInfo), FollowerNames)].

-spec solo_lines([hero()]) -> [line()].
solo_lines(Solos) ->
    SortedSolos = lists:sort(fun(A, B) ->
        maps:get(level, A) >= maps:get(level, B)
    end, Solos),
    [hero_line("    ", Info) || Info <- SortedSolos].

-spec hero_line(string(), hero()) -> line().
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

-spec hp_color(integer(), pos_integer()) -> red | yellow | green.
hp_color(Hp, MaxHp) when Hp * 3 < MaxHp -> red;
hp_color(Hp, MaxHp) when Hp * 3 < MaxHp * 2 -> yellow;
hp_color(_Hp, _MaxHp) -> green.

-spec bonus_str(integer(), integer()) -> io_lib:chars().
bonus_str(0, 0) -> "";
bonus_str(A, 0) -> io_lib:format(" +~pATK", [A]);
bonus_str(0, D) -> io_lib:format(" +~pDEF", [D]);
bonus_str(A, D) -> io_lib:format(" +~pATK +~pDEF", [A, D]).

-spec role_icon(role()) -> part().
role_icon(leader) -> {[cyan], "& "};
role_icon(follower) -> {[dim], "+ "};
role_icon(solo) -> {[green], "@ "}.

-spec enemies_line(#{pid() => located()}) -> line().
enemies_line(Enemies) ->
    [{[], "  "}, {[dim, red], io_lib:format("Enemies on map: ~p", [maps:size(Enemies)])}].

-spec log_title_line() -> line().
log_title_line() ->
    [{[], "  "}, {[bold, yellow], "Log:"}].

-spec log_lines([io_lib:chars()], integer()) -> [line()].
log_lines([], Room) ->
    last([[{[], "    "}, {[dim], "> (quiet...)"}]], Room);
log_lines(EventLog, Room) ->
    [[{[], "    "}, {[dim], "> "}, {[], Evt}] || Evt <- last(EventLog, min(?LOG_SIZE, Room))].

-spec last([T], integer()) -> [T].
last(Items, Count) ->
    lists:nthtail(max(0, length(Items) - max(0, Count)), Items).
