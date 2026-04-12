-module(display).
-export([start/1]).

-define(MAP_SIZE, 40).

%% ANSI color codes
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

start(_WorldPid) ->
    spawn(fun() -> loop() end).

loop() ->
    receive
        {render, Characters, Enemies, Shops, Inns, EventLog, MoveCount} ->
            render(Characters, Enemies, Shops, Inns, EventLog, MoveCount),
            loop()
    after 10000 ->
        loop()
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
    io:format("  ~s+", [?DIM]),
    lists:foreach(fun(_) -> io:format("--") end, lists:seq(1, ?MAP_SIZE)),
    io:format("-+~s\e[K~n", [?RESET]),
    lists:foreach(fun(Y) ->
        io:format("  ~s|~s", [?DIM, ?RESET]),
        lists:foreach(fun(X) ->
            case maps:get({X, Y}, Grid, empty) of
                empty ->
                    io:format("~s. ~s", [?DIM, ?RESET]);
                {shop, _Name} ->
                    io:format("~s~s$ ~s", [?BOLD, ?YELLOW, ?RESET]);
                {inn, _Name} ->
                    io:format("~s~sH ~s", [?BOLD, ?BLUE, ?RESET]);
                {char, _Name, Level, solo} ->
                    Color = char_color(Level),
                    io:format("~s~s@ ~s", [?BOLD, Color, ?RESET]);
                {char, _Name, Level, leader} ->
                    Color = char_color(Level),
                    io:format("~s~s& ~s", [?BOLD, Color, ?RESET]);
                {char, _Name, _Level, follower} ->
                    io:format("~s~s+ ~s", [?DIM, ?CYAN, ?RESET]);
                {enemy, _Name, _Level} ->
                    io:format("~s~s! ~s", [?BOLD, ?RED, ?RESET])
            end
        end, lists:seq(0, ?MAP_SIZE - 1)),
        io:format("~s|~s\e[K~n", [?DIM, ?RESET])
    end, lists:seq(0, ?MAP_SIZE - 1)),
    io:format("  ~s+", [?DIM]),
    lists:foreach(fun(_) -> io:format("--") end, lists:seq(1, ?MAP_SIZE)),
    io:format("-+~s\e[K~n", [?RESET]).

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
        X = maps:get(x, Info),
        Y = maps:get(y, Info),
        Name = maps:get(name, Info),
        Level = maps:get(level, Info),
        Acc#{{X, Y} => {char, Name, Level, follower}}
    end, G2, Followers),
    lists:foldl(fun(Info, Acc) ->
        X = maps:get(x, Info),
        Y = maps:get(y, Info),
        Name = maps:get(name, Info),
        Level = maps:get(level, Info),
        Role = maps:get(party_role, Info, solo),
        Acc#{{X, Y} => {char, Name, Level, Role}}
    end, G3, Others).

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
    CharList = maps:values(Characters),
    Sorted = lists:sort(fun(A, B) ->
        RoleA = role_priority(maps:get(party_role, A, solo)),
        RoleB = role_priority(maps:get(party_role, B, solo)),
        case RoleA =:= RoleB of
            true -> maps:get(level, A) >= maps:get(level, B);
            false -> RoleA =< RoleB
        end
    end, CharList),
    lists:foreach(fun(Info) ->
        Name = maps:get(name, Info),
        Race = maps:get(race, Info, human),
        RaceStr = util:race_label(Race),
        Level = maps:get(level, Info),
        Hp = maps:get(hp, Info),
        MaxHp = maps:get(max_hp, Info),
        Exp = maps:get(exp, Info),
        Needed = combat:exp_to_level(Level),
        Gold = maps:get(gold, Info, 0),
        PartyRole = maps:get(party_role, Info, solo),
        AtkBonus = maps:get(attack_bonus, Info),
        DefBonus = maps:get(defense_bonus, Info),
        HpColor = if
            Hp * 3 < MaxHp -> ?RED;
            Hp * 3 < MaxHp * 2 -> ?YELLOW;
            true -> ?GREEN
        end,
        BonusStr = case {AtkBonus, DefBonus} of
            {0, 0} -> "";
            {A, 0} -> io_lib:format(" +~pATK", [A]);
            {0, D} -> io_lib:format(" +~pDEF", [D]);
            {A, D} -> io_lib:format(" +~pATK +~pDEF", [A, D])
        end,
        RoleTag = case PartyRole of
            leader -> io_lib:format(" ~s[LEAD]~s", [?CYAN, ?RESET]);
            follower -> io_lib:format(" ~s[FOLLOW]~s", [?DIM, ?RESET]);
            solo -> ""
        end,
        Indent = case PartyRole of
            follower -> "      ";
            _ -> "    "
        end,
        io:format("~s~s~s~s (~s) Lv~p  ~sHP:~p/~p~s  XP:~p/~p  ~s~pg~s~s~s\e[K~n",
                  [Indent, ?BOLD, Name, ?RESET, RaceStr, Level,
                   HpColor, Hp, MaxHp, ?RESET,
                   Exp, Needed, ?YELLOW, Gold, ?RESET, BonusStr, RoleTag])
    end, Sorted).

role_priority(leader) -> 1;
role_priority(solo) -> 2;
role_priority(follower) -> 3.

print_enemies_summary(Enemies) ->
    Count = maps:size(Enemies),
    io:format("  ~s~sEnemies on map: ~p~s\e[K~n", [?DIM, ?RED, Count, ?RESET]).

print_events(EventLog) ->
    io:format("~n  ~s~sLog:~s\e[K~n", [?BOLD, ?YELLOW, ?RESET]),
    case EventLog of
        [] ->
            io:format("    ~s> (quiet...)~s\e[K~n", [?DIM, ?RESET]);
        _ ->
            Recent = case length(EventLog) > 12 of
                true -> lists:nthtail(length(EventLog) - 12, EventLog);
                false -> EventLog
            end,
            lists:foreach(fun(Evt) ->
                io:format("    ~s> ~s~s\e[K~n", [?DIM, ?RESET, Evt])
            end, Recent)
    end.
