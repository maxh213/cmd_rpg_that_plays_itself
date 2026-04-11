-module(display).
-export([start/1]).

-define(MAP_SIZE, 10).

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
-define(BG_RED,  "\e[41m").

start(_WorldPid) ->
    spawn(fun() -> loop() end).

loop() ->
    receive
        {render, Characters, Enemies, EventLog, TickCount} ->
            render(Characters, Enemies, EventLog, TickCount),
            loop()
    after 10000 ->
        loop()
    end.

render(Characters, Enemies, EventLog, TickCount) ->
    %% Move cursor to top-left (avoids flicker vs full clear)
    io:format("\e[H\e[2J", []),
    print_header(TickCount),
    print_map(Characters, Enemies),
    print_roster(Characters),
    print_enemies_summary(Enemies),
    print_events(EventLog),
    io:format("~n", []).

print_header(TickCount) ->
    io:format("~s~s=== CMD RPG (Tick ~p) ===~s~n~n", [?BOLD, ?CYAN, TickCount, ?RESET]).

print_map(Characters, Enemies) ->
    %% Build grid: each cell is either empty, a character, or an enemy
    Grid = build_grid(Characters, Enemies),
    %% Print top border
    io:format("  ~s+", [?DIM]),
    lists:foreach(fun(_) -> io:format("----") end, lists:seq(1, ?MAP_SIZE)),
    io:format("-+~s~n", [?RESET]),
    %% Print rows
    lists:foreach(fun(Y) ->
        io:format("  ~s|~s ", [?DIM, ?RESET]),
        lists:foreach(fun(X) ->
            case maps:get({X, Y}, Grid, empty) of
                empty ->
                    io:format("~s .  ~s", [?DIM, ?RESET]);
                {char, Name, Level} ->
                    Color = char_color(Level),
                    io:format("~s~s~s~p ~s", [?BOLD, Color, Name, Level, ?RESET]);
                {enemy, Name, _Level} ->
                    io:format("~s~s~s~s", [?RED, short_name(Name), " ", ?RESET])
            end
        end, lists:seq(0, ?MAP_SIZE - 1)),
        io:format("~s|~s~n", [?DIM, ?RESET])
    end, lists:seq(0, ?MAP_SIZE - 1)),
    %% Print bottom border
    io:format("  ~s+", [?DIM]),
    lists:foreach(fun(_) -> io:format("----") end, lists:seq(1, ?MAP_SIZE)),
    io:format("-+~s~n", [?RESET]).

build_grid(Characters, Enemies) ->
    G1 = maps:fold(fun(_Pid, Info, Acc) ->
        X = maps:get(x, Info),
        Y = maps:get(y, Info),
        Name = maps:get(name, Info),
        Level = maps:get(level, Info),
        Acc#{{X, Y} => {char, Name, Level}}
    end, #{}, Characters),
    maps:fold(fun(_Pid, Info, Acc) ->
        X = maps:get(x, Info),
        Y = maps:get(y, Info),
        Name = maps:get(name, Info),
        Level = maps:get(level, Info),
        %% Don't overwrite a character with an enemy
        case maps:is_key({X, Y}, Acc) of
            true -> Acc;
            false -> Acc#{{X, Y} => {enemy, Name, Level}}
        end
    end, G1, Enemies).

char_color(Level) when Level >= 5 -> ?MAGENTA;
char_color(Level) when Level >= 3 -> ?YELLOW;
char_color(_Level) -> ?GREEN.

short_name(Name) ->
    %% Take first 3 chars of enemy name for display
    case length(Name) > 3 of
        true -> lists:sublist(Name, 3);
        false -> Name
    end.

print_roster(Characters) ->
    io:format("~n  ~s~sHeroes:~s~n", [?BOLD, ?CYAN, ?RESET]),
    CharList = maps:values(Characters),
    Sorted = lists:sort(fun(A, B) -> maps:get(level, A) >= maps:get(level, B) end, CharList),
    lists:foreach(fun(Info) ->
        Name = maps:get(name, Info),
        Level = maps:get(level, Info),
        Hp = maps:get(hp, Info),
        MaxHp = maps:get(max_hp, Info),
        Exp = maps:get(exp, Info),
        Needed = combat:exp_to_level(Level),
        Inv = maps:get(inventory, Info),
        AtkBonus = maps:get(attack_bonus, Info),
        DefBonus = maps:get(defense_bonus, Info),
        HpColor = if
            Hp * 3 < MaxHp -> ?RED;
            Hp * 3 < MaxHp * 2 -> ?YELLOW;
            true -> ?GREEN
        end,
        InvStr = case Inv of
            [] -> "";
            Items -> io_lib:format(" [~s]", [string:join(Items, ", ")])
        end,
        BonusStr = case {AtkBonus, DefBonus} of
            {0, 0} -> "";
            {A, 0} -> io_lib:format(" +~pATK", [A]);
            {0, D} -> io_lib:format(" +~pDEF", [D]);
            {A, D} -> io_lib:format(" +~pATK +~pDEF", [A, D])
        end,
        io:format("    ~s~s~s Lv~p  ~sHP:~p/~p~s  XP:~p/~p~s~s~n",
                  [?BOLD, Name, ?RESET, Level, HpColor, Hp, MaxHp, ?RESET,
                   Exp, Needed, BonusStr, InvStr])
    end, Sorted).

print_enemies_summary(Enemies) ->
    Count = maps:size(Enemies),
    io:format("  ~s~sEnemies on map: ~p~s~n", [?DIM, ?RED, Count, ?RESET]).

print_events(EventLog) ->
    case EventLog of
        [] -> ok;
        _ ->
            io:format("~n  ~s~sLog:~s~n", [?BOLD, ?YELLOW, ?RESET]),
            %% Show only last 8 events
            Recent = case length(EventLog) > 8 of
                true -> lists:nthtail(length(EventLog) - 8, EventLog);
                false -> EventLog
            end,
            lists:foreach(fun(Evt) ->
                io:format("    ~s> ~s~s~n", [?DIM, ?RESET, Evt])
            end, Recent)
    end.
