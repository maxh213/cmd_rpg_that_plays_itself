-module(display).
-export([start/1, start/2]).

-define(MAP_SIZE, 40).
-define(IDLE_TIMEOUT, 10000).

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

start(WorldPid) ->
    start(WorldPid, ?IDLE_TIMEOUT).

start(_WorldPid, Timeout) ->
    spawn(fun() -> loop(Timeout) end).

loop(Timeout) ->
    receive
        {render, Characters, Enemies, Shops, Inns, EventLog, MoveCount} ->
            render(Characters, Enemies, Shops, Inns, EventLog, MoveCount),
            loop(Timeout)
    after Timeout ->
        loop(Timeout)
    end.

render(Characters, Enemies, Shops, Inns, EventLog, MoveCount) ->
    io:format("\e[?25l\e[H", []),
    print_header(MoveCount),
    print_map(Characters, Enemies, Shops, Inns),
    print_legend(),
    print_roster(Characters),
    print_enemies_summary(Enemies),
    print_events(EventLog),
    io:format("\e[J\e[?25h", []).

print_header(MoveCount) ->
    io:format("~s~s=== CMD RPG [~p moves] ===~s\e[K~n\e[K~n",
              [?BOLD, ?CYAN, MoveCount, ?RESET]).

print_map(Characters, Enemies, Shops, Inns) ->
    Grid = build_grid(Characters, Enemies, Shops, Inns),
    print_border(),
    lists:foreach(fun(Y) -> print_row(Y, Grid) end, lists:seq(0, ?MAP_SIZE - 1)),
    print_border().

print_border() ->
    io:format("  ~s+", [?DIM]),
    lists:foreach(fun(_) -> io:format("--") end, lists:seq(1, ?MAP_SIZE)),
    io:format("-+~s\e[K~n", [?RESET]).

print_row(Y, Grid) ->
    io:format("  ~s|~s", [?DIM, ?RESET]),
    lists:foreach(fun(X) -> print_cell(maps:get({X, Y}, Grid, empty)) end, lists:seq(0, ?MAP_SIZE - 1)),
    io:format("~s|~s\e[K~n", [?DIM, ?RESET]).

print_cell(empty) ->
    io:format("~s. ~s", [?DIM, ?RESET]);
print_cell({shop, _Name}) ->
    io:format("~s~s$ ~s", [?BOLD, ?YELLOW, ?RESET]);
print_cell({inn, _Name}) ->
    io:format("~s~sH ~s", [?BOLD, ?BLUE, ?RESET]);
print_cell({char, _Name, Level, solo}) ->
    io:format("~s~s@ ~s", [?BOLD, char_color(Level), ?RESET]);
print_cell({char, _Name, Level, leader}) ->
    io:format("~s~s& ~s", [?BOLD, char_color(Level), ?RESET]);
print_cell({char, _Name, _Level, follower}) ->
    io:format("~s~s+ ~s", [?DIM, ?CYAN, ?RESET]);
print_cell({enemy, _Name, _Level}) ->
    io:format("~s~s! ~s", [?BOLD, ?RED, ?RESET]).

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

print_legend() ->
    io:format("  ~s~s@ ~sHero  ~s~s& ~sParty  ~s~s! ~sEnemy  ~s~s$ ~sShop  ~s~sH ~sInn~s\e[K~n",
              [?BOLD, ?GREEN, ?RESET,
               ?BOLD, ?GREEN, ?RESET,
               ?BOLD, ?RED, ?RESET,
               ?BOLD, ?YELLOW, ?RESET,
               ?BOLD, ?BLUE, ?RESET,
               ?RESET]).

print_roster(Characters) ->
    io:format("~n  ~s~sHeroes:~s\e[K~n", [?BOLD, ?CYAN, ?RESET]),
    {Leaders, Solos, Followers} = split_roles(Characters),
    lists:foreach(fun(Leader) -> print_party(Leader, Followers, Characters) end, Leaders),
    print_solos(Solos).

split_roles(Characters) ->
    maps:fold(fun(Pid, Info, {LAcc, SAcc, FAcc}) ->
        case maps:get(party_role, Info, solo) of
            leader -> {[{Pid, Info} | LAcc], SAcc, FAcc};
            solo -> {LAcc, [Info | SAcc], FAcc};
            follower -> {LAcc, SAcc, [Info | FAcc]}
        end
    end, {[], [], []}, Characters).

print_party({_LeaderPid, LeaderInfo}, Followers, Characters) ->
    LName = maps:get(name, LeaderInfo),
    FollowerPids = maps:get(follower_pids, LeaderInfo, []),
    FollowerNames = follower_names(Followers, FollowerPids, Characters),
    MemberStrs = [LName | FollowerNames],
    io:format("  ~s~s--- Party: ~s ---~s\e[K~n",
              [?BOLD, ?CYAN, string:join(MemberStrs, " + "), ?RESET]),
    print_hero_line("    ", LeaderInfo),
    print_followers(Followers, FollowerNames),
    io:format("\e[K~n").

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

print_followers(Followers, FollowerNames) ->
    lists:foreach(fun(FInfo) -> print_named_follower(FInfo, FollowerNames) end, Followers).

print_named_follower(FInfo, FollowerNames) ->
    case lists:member(maps:get(name, FInfo), FollowerNames) of
        true -> print_hero_line("      ", FInfo);
        false -> ok
    end.

print_solos(Solos) ->
    SortedSolos = lists:sort(fun(A, B) ->
        maps:get(level, A) >= maps:get(level, B)
    end, Solos),
    lists:foreach(fun(Info) ->
        print_hero_line("    ", Info)
    end, SortedSolos).

print_hero_line(Indent, Info) ->
    Name = maps:get(name, Info),
    RaceStr = util:race_label(maps:get(race, Info, human)),
    Level = maps:get(level, Info),
    Hp = maps:get(hp, Info),
    MaxHp = maps:get(max_hp, Info),
    Exp = maps:get(exp, Info),
    Needed = combat:exp_to_level(Level),
    Gold = maps:get(gold, Info, 0),
    AtkBonus = maps:get(attack_bonus, Info),
    DefBonus = maps:get(defense_bonus, Info),
    io:format("~s~s~s~s~s (~s) Lv~p  ~sHP:~p/~p~s  XP:~p/~p  ~s~pg~s~s\e[K~n",
              [Indent, role_icon(maps:get(party_role, Info, solo)), ?BOLD, Name, ?RESET,
               RaceStr, Level,
               hp_color(Hp, MaxHp), Hp, MaxHp, ?RESET,
               Exp, Needed, ?YELLOW, Gold, ?RESET, bonus_str(AtkBonus, DefBonus)]).

hp_color(Hp, MaxHp) when Hp * 3 < MaxHp -> ?RED;
hp_color(Hp, MaxHp) when Hp * 3 < MaxHp * 2 -> ?YELLOW;
hp_color(_Hp, _MaxHp) -> ?GREEN.

bonus_str(0, 0) -> "";
bonus_str(A, 0) -> io_lib:format(" +~pATK", [A]);
bonus_str(0, D) -> io_lib:format(" +~pDEF", [D]);
bonus_str(A, D) -> io_lib:format(" +~pATK +~pDEF", [A, D]).

role_icon(leader) -> io_lib:format("~s& ~s", [?CYAN, ?RESET]);
role_icon(follower) -> io_lib:format("~s+ ~s", [?DIM, ?RESET]);
role_icon(solo) -> io_lib:format("~s@ ~s", [?GREEN, ?RESET]).

print_enemies_summary(Enemies) ->
    Count = maps:size(Enemies),
    io:format("  ~s~sEnemies on map: ~p~s\e[K~n", [?DIM, ?RED, Count, ?RESET]).

print_events(EventLog) ->
    io:format("~n  ~s~sLog:~s\e[K~n", [?BOLD, ?YELLOW, ?RESET]),
    print_event_lines(EventLog).

print_event_lines([]) ->
    io:format("    ~s> (quiet...)~s\e[K~n", [?DIM, ?RESET]);
print_event_lines(EventLog) ->
    lists:foreach(fun(Evt) ->
        io:format("    ~s> ~s~s\e[K~n", [?DIM, ?RESET, Evt])
    end, recent(EventLog)).

recent(EventLog) when length(EventLog) > 12 ->
    lists:nthtail(length(EventLog) - 12, EventLog);
recent(EventLog) ->
    EventLog.
