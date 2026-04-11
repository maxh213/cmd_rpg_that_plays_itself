-module(world_server).
-behaviour(gen_server).

-export([start_link/0, move/2, get_state/0, register_char/2, char_died/2,
         enemy_killed/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAP_SIZE, 10).
-define(CHAR_COUNT, 5).
-define(ENEMY_COUNT, 8).
-define(TICK_MS, 600).
-define(RESPAWN_TICKS, 5).
-define(ENEMY_RESPAWN_TICKS, 3).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

move(Pid, Direction) ->
    gen_server:cast(?MODULE, {move, Pid, Direction}).

get_state() ->
    gen_server:call(?MODULE, get_state).

register_char(Pid, Info) ->
    gen_server:cast(?MODULE, {register_char, Pid, Info}).

char_died(Pid, KillerPid) ->
    gen_server:cast(?MODULE, {char_died, Pid, KillerPid}).

enemy_killed(EnemyPid, KillerPid, EnemyInfo) ->
    gen_server:cast(?MODULE, {enemy_killed, EnemyPid, KillerPid, EnemyInfo}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    rand:seed(exsss),
    %% Spawn characters
    Characters = spawn_characters(?CHAR_COUNT),
    %% Spawn enemies
    Enemies = spawn_enemies(?ENEMY_COUNT),
    %% Start display
    DisplayPid = display:start(self()),
    %% Schedule first tick
    TRef = erlang:send_after(?TICK_MS, self(), tick),
    State = #{
        characters => Characters,    %% #{Pid => char_info}
        enemies => Enemies,          %% #{Pid => enemy_info}
        display_pid => DisplayPid,
        tick_ref => TRef,
        event_log => [],
        respawn_queue => [],          %% [{name, ticks_remaining, type}]
        tick_count => 0
    },
    {ok, State}.

handle_call(get_state, _From, State) ->
    {reply, State, State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast({move, Pid, Direction}, State) ->
    #{characters := Chars, enemies := Enemies, event_log := Log} = State,
    case maps:find(Pid, Chars) of
        {ok, Info} ->
            {NewX, NewY} = apply_direction(Direction, maps:get(x, Info), maps:get(y, Info)),
            NewInfo = Info#{x := NewX, y := NewY},
            NewChars = Chars#{Pid := NewInfo},
            %% Check for enemy collision at new position
            {NewChars2, NewEnemies, CombatLog} = check_enemy_collisions(Pid, NewX, NewY, NewChars, Enemies),
            {noreply, State#{characters := NewChars2, enemies := NewEnemies,
                             event_log := Log ++ CombatLog}};
        error ->
            %% Maybe it's an enemy moving
            case maps:find(Pid, Enemies) of
                {ok, EInfo} ->
                    {NewX, NewY} = apply_direction(Direction, maps:get(x, EInfo), maps:get(y, EInfo)),
                    NewEInfo = EInfo#{x := NewX, y := NewY},
                    NewEnemies = Enemies#{Pid := NewEInfo},
                    {noreply, State#{enemies := NewEnemies}};
                error ->
                    {noreply, State}
            end
    end;

handle_cast({enemy_killed, EnemyPid, KillerPid, EnemyInfo}, State) ->
    #{characters := Chars, enemies := Enemies, event_log := Log,
      respawn_queue := RQ} = State,
    EnemyName = maps:get(name, EnemyInfo),
    EnemyLevel = maps:get(level, EnemyInfo),
    %% Remove enemy
    NewEnemies = maps:remove(EnemyPid, Enemies),
    %% Reward killer with XP and possible drop
    {NewChars, KillLog} = case maps:find(KillerPid, Chars) of
        {ok, KillerInfo} ->
            XpGain = EnemyLevel + 1,
            KName = maps:get(name, KillerInfo),
            K1 = KillerInfo#{exp := maps:get(exp, KillerInfo) + XpGain},
            %% Check for level up
            K2 = combat:check_level_up(K1),
            LevelUpLog = case maps:get(level, K2) > maps:get(level, K1) of
                true ->
                    [io_lib:format("~s leveled up to Lv~p!", [KName, maps:get(level, K2)])];
                false -> []
            end,
            %% Check for drop
            Drop = combat:generate_drop(EnemyLevel),
            {K3, DropLog} = apply_drop(K2, Drop),
            KilledLog = [io_lib:format("~s slew ~s(Lv~p) [+~pXP]",
                                       [KName, EnemyName, EnemyLevel, XpGain])],
            {Chars#{KillerPid := K3}, KilledLog ++ LevelUpLog ++ DropLog};
        error ->
            {Chars, []}
    end,
    %% Queue enemy respawn
    NewRQ = RQ ++ [{EnemyName, ?ENEMY_RESPAWN_TICKS, enemy, EnemyLevel}],
    {noreply, State#{characters := NewChars, enemies := NewEnemies,
                     event_log := Log ++ KillLog, respawn_queue := NewRQ}};

handle_cast({char_died, Pid, KillerPid}, State) ->
    #{characters := Chars, enemies := Enemies, event_log := Log,
      respawn_queue := RQ} = State,
    case maps:find(Pid, Chars) of
        {ok, DeadInfo} ->
            DeadName = maps:get(name, DeadInfo),
            NewChars = maps:remove(Pid, Chars),
            %% If killer is a character, give XP
            {NewChars2, KillLog} = case maps:find(KillerPid, NewChars) of
                {ok, KillerInfo} ->
                    XpGain = maps:get(level, DeadInfo),
                    KName = maps:get(name, KillerInfo),
                    K1 = KillerInfo#{exp := maps:get(exp, KillerInfo) + XpGain},
                    K2 = combat:check_level_up(K1),
                    LvlLog = case maps:get(level, K2) > maps:get(level, K1) of
                        true -> [io_lib:format("~s leveled up to Lv~p!", [KName, maps:get(level, K2)])];
                        false -> []
                    end,
                    {NewChars#{KillerPid := K2},
                     [io_lib:format("~s was slain by ~s!", [DeadName, KName]) | LvlLog]};
                error ->
                    %% Killed by enemy
                    KillerName = case maps:find(KillerPid, Enemies) of
                        {ok, EI} -> maps:get(name, EI);
                        error -> "unknown"
                    end,
                    {NewChars, [io_lib:format("~s was slain by ~s!", [DeadName, KillerName])]}
            end,
            NewRQ = RQ ++ [{DeadName, ?RESPAWN_TICKS, character}],
            {noreply, State#{characters := NewChars2, event_log := Log ++ KillLog,
                             respawn_queue := NewRQ}};
        error ->
            {noreply, State}
    end;

handle_cast({register_char, Pid, Info}, State) ->
    #{characters := Chars} = State,
    {noreply, State#{characters := Chars#{Pid => Info}}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    #{characters := Chars, enemies := Enemies, display_pid := DPid,
      event_log := _Log, respawn_queue := RQ, tick_count := TC} = State,
    %% Build list of enemy positions for character AI
    EnemyPositions = maps:fold(fun(_EPid, EInfo, Acc) ->
        [{maps:get(x, EInfo), maps:get(y, EInfo)} | Acc]
    end, [], Enemies),
    %% Send tick to all character processes (with nearby enemy info)
    maps:foreach(fun(Pid, Info) ->
        Pid ! {tick, Info#{enemy_positions => EnemyPositions}}
    end, Chars),
    %% Send tick to all enemy processes
    maps:foreach(fun(Pid, Info) ->
        Pid ! {tick, Info}
    end, Enemies),
    %% Check for character-vs-character collisions
    {NewChars, PvpLog} = check_pvp_collisions(Chars),
    %% Process respawn queue
    {NewRQ, SpawnedChars, SpawnedEnemies, RespawnLog} = process_respawns(RQ),
    FinalChars = maps:merge(NewChars, SpawnedChars),
    FinalEnemies = maps:merge(Enemies, SpawnedEnemies),
    %% Send render to display
    DPid ! {render, FinalChars, FinalEnemies,
            maps:get(event_log, State) ++ PvpLog ++ RespawnLog, TC},
    %% Schedule next tick
    TRef = erlang:send_after(?TICK_MS, self(), tick),
    {noreply, State#{characters := FinalChars, enemies := FinalEnemies,
                     tick_ref := TRef, event_log := [],
                     respawn_queue := NewRQ, tick_count := TC + 1}};

handle_info({queue_respawn, Name, Ticks, Type, Level}, State) ->
    #{respawn_queue := RQ} = State,
    {noreply, State#{respawn_queue := RQ ++ [{Name, Ticks, Type, Level}]}};

handle_info({queue_respawn, Name, Ticks, character}, State) ->
    #{respawn_queue := RQ} = State,
    {noreply, State#{respawn_queue := RQ ++ [{Name, Ticks, character}]}};

handle_info({enemy_killed_internal, _EPid, _KillerPid, _EnemyInfo}, State) ->
    %% Legacy — handled inline now
    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

apply_direction(north, X, Y) -> {X, util:clamp(Y - 1, 0, ?MAP_SIZE - 1)};
apply_direction(south, X, Y) -> {X, util:clamp(Y + 1, 0, ?MAP_SIZE - 1)};
apply_direction(east, X, Y)  -> {util:clamp(X + 1, 0, ?MAP_SIZE - 1), Y};
apply_direction(west, X, Y)  -> {util:clamp(X - 1, 0, ?MAP_SIZE - 1), Y};
apply_direction(stay, X, Y)  -> {X, Y}.

spawn_characters(Count) ->
    lists:foldl(fun(_, Acc) ->
        Name = util:random_name(3),
        {X, Y} = util:random_pos(?MAP_SIZE),
        Info = #{name => Name, level => 1, hp => 10, max_hp => 10,
                 exp => 0, x => X, y => Y, inventory => [], attack_bonus => 0,
                 defense_bonus => 0},
        Pid = character:start(self()),
        Acc#{Pid => Info}
    end, #{}, lists:seq(1, Count)).

spawn_enemies(Count) ->
    lists:foldl(fun(_, Acc) ->
        {Name, Level} = random_enemy(),
        {X, Y} = util:random_pos(?MAP_SIZE),
        MaxHp = Level * 3 + 2,
        Info = #{name => Name, level => Level, hp => MaxHp, max_hp => MaxHp,
                 x => X, y => Y, type => enemy},
        Pid = enemy:start(self()),
        Acc#{Pid => Info}
    end, #{}, lists:seq(1, Count)).

random_enemy() ->
    Enemies = [
        {"Goblin", 1}, {"Rat", 1}, {"Slime", 1},
        {"Wolf", 2}, {"Bandit", 2}, {"Skeleton", 2},
        {"Orc", 3}, {"Zombie", 3}, {"Spider", 3},
        {"Troll", 4}, {"Dark Mage", 4},
        {"Ogre", 5}, {"Wraith", 5},
        {"Dragon", 7}, {"Demon Lord", 8}
    ],
    lists:nth(rand:uniform(length(Enemies)), Enemies).

check_enemy_collisions(CharPid, X, Y, Chars, Enemies) ->
    %% Find enemies at the same position
    EnemiesAtPos = maps:filter(fun(_EPid, EInfo) ->
        maps:get(x, EInfo) =:= X andalso maps:get(y, EInfo) =:= Y
    end, Enemies),
    maps:fold(fun(EPid, EInfo, {AccChars, AccEnemies, AccLog}) ->
        case maps:find(CharPid, AccChars) of
            {ok, CharInfo} ->
                CName = maps:get(name, CharInfo),
                EName = maps:get(name, EInfo),
                ELevel = maps:get(level, EInfo),
                {Winner, _Loser, Dmg} = combat:resolve(CharInfo, EInfo),
                WinnerName = maps:get(name, Winner),
                CharWon = WinnerName =:= CName,
                if
                    CharWon ->
                        %% Character hit the enemy
                        NewEHp = maps:get(hp, EInfo) - Dmg,
                        if
                            NewEHp =< 0 ->
                                %% Enemy killed
                                EPid ! die,
                                XpGain = ELevel + 1,
                                C1 = CharInfo#{exp := maps:get(exp, CharInfo) + XpGain},
                                C2 = combat:check_level_up(C1),
                                LvlLog = case maps:get(level, C2) > maps:get(level, CharInfo) of
                                    true -> [io_lib:format("~s leveled up to Lv~p!", [CName, maps:get(level, C2)])];
                                    false -> []
                                end,
                                Drop = combat:generate_drop(ELevel),
                                {C3, DropLog} = apply_drop(C2, Drop),
                                KillLog = [io_lib:format("~s slew ~s(Lv~p) [+~pXP]", [CName, EName, ELevel, XpGain])],
                                %% Queue enemy respawn
                                self() ! {queue_respawn, EName, ?ENEMY_RESPAWN_TICKS, enemy, ELevel},
                                {AccChars#{CharPid := C3}, maps:remove(EPid, AccEnemies),
                                 AccLog ++ KillLog ++ LvlLog ++ DropLog};
                            true ->
                                %% Enemy damaged but alive
                                {AccChars, AccEnemies#{EPid := EInfo#{hp := NewEHp}},
                                 AccLog ++ [io_lib:format("~s hit ~s (-~pHP)", [CName, EName, Dmg])]}
                        end;
                    true ->
                        %% Enemy hit the character
                        NewCHp = maps:get(hp, CharInfo) - Dmg,
                        if
                            NewCHp =< 0 ->
                                %% Character killed by enemy
                                CharPid ! {you_died, EPid},
                                {maps:remove(CharPid, AccChars), AccEnemies,
                                 AccLog ++ [io_lib:format("~s was mauled by ~s!", [CName, EName])]};
                            true ->
                                {AccChars#{CharPid := CharInfo#{hp := NewCHp}}, AccEnemies,
                                 AccLog ++ [io_lib:format("~s hit by ~s (-~pHP)", [CName, EName, Dmg])]}
                        end
                end;
            error ->
                {AccChars, AccEnemies, AccLog}
        end
    end, {Chars, Enemies, []}, EnemiesAtPos).

check_pvp_collisions(Chars) ->
    %% Group characters by position
    ByPos = maps:fold(fun(Pid, Info, Acc) ->
        Pos = {maps:get(x, Info), maps:get(y, Info)},
        Current = maps:get(Pos, Acc, []),
        Acc#{Pos => [{Pid, Info} | Current]}
    end, #{}, Chars),
    %% Resolve fights where multiple characters share a cell
    maps:fold(fun(_Pos, Occupants, {AccChars, AccLog}) ->
        case Occupants of
            [_Single] -> {AccChars, AccLog};
            [{Pid1, _}, {Pid2, _} | _] ->
                case {maps:find(Pid1, AccChars), maps:find(Pid2, AccChars)} of
                    {{ok, I1}, {ok, I2}} ->
                        N1 = maps:get(name, I1),
                        N2 = maps:get(name, I2),
                        {Winner, _Loser, Dmg} = combat:resolve(I1, I2),
                        WinnerName = maps:get(name, Winner),
                        {WinnerPid, LoserPid, WinnerInfo, LoserInfo, WName, LName} =
                            case WinnerName =:= N1 of
                                true  -> {Pid1, Pid2, I1, I2, N1, N2};
                                false -> {Pid2, Pid1, I2, I1, N2, N1}
                            end,
                        NewLoserHp = maps:get(hp, LoserInfo) - Dmg,
                        if
                            NewLoserHp =< 0 ->
                                LoserPid ! {you_died, WinnerPid},
                                %% Give winner XP
                                XpGain = maps:get(level, LoserInfo),
                                W1 = WinnerInfo#{exp := maps:get(exp, WinnerInfo) + XpGain},
                                W2 = combat:check_level_up(W1),
                                LvlLog = case maps:get(level, W2) > maps:get(level, WinnerInfo) of
                                    true -> [io_lib:format("~s leveled up to Lv~p!", [WName, maps:get(level, W2)])];
                                    false -> []
                                end,
                                self() ! {queue_respawn, LName, ?RESPAWN_TICKS, character},
                                {maps:remove(LoserPid, AccChars#{WinnerPid := W2}),
                                 AccLog ++ [io_lib:format("~s defeated ~s! [+~pXP]", [WName, LName, XpGain])] ++ LvlLog};
                            true ->
                                {AccChars#{LoserPid := LoserInfo#{hp := NewLoserHp}},
                                 AccLog ++ [io_lib:format("~s clashed with ~s (-~pHP)", [WName, LName, Dmg])]}
                        end;
                    _ -> {AccChars, AccLog}
                end
        end
    end, {Chars, []}, ByPos).

process_respawns(RQ) ->
    lists:foldl(fun
        ({Name, 1, character}, {AccRQ, AccChars, AccEnemies, AccLog}) ->
            {X, Y} = util:random_pos(?MAP_SIZE),
            Info = #{name => Name, level => 1, hp => 10, max_hp => 10,
                     exp => 0, x => X, y => Y, inventory => [],
                     attack_bonus => 0, defense_bonus => 0},
            Pid = character:start(self()),
            {AccRQ, AccChars#{Pid => Info}, AccEnemies,
             AccLog ++ [io_lib:format("~s respawned!", [Name])]};
        ({Name, 1, enemy, Level}, {AccRQ, AccChars, AccEnemies, AccLog}) ->
            {X, Y} = util:random_pos(?MAP_SIZE),
            MaxHp = Level * 3 + 2,
            Info = #{name => Name, level => Level, hp => MaxHp, max_hp => MaxHp,
                     x => X, y => Y, type => enemy},
            Pid = enemy:start(self()),
            {AccRQ, AccChars, AccEnemies#{Pid => Info},
             AccLog ++ [io_lib:format("A ~s appeared!", [Name])]};
        ({Name, Ticks, Type}, {AccRQ, AccChars, AccEnemies, AccLog}) ->
            {AccRQ ++ [{Name, Ticks - 1, Type}], AccChars, AccEnemies, AccLog};
        ({Name, Ticks, Type, Level}, {AccRQ, AccChars, AccEnemies, AccLog}) ->
            {AccRQ ++ [{Name, Ticks - 1, Type, Level}], AccChars, AccEnemies, AccLog}
    end, {[], #{}, #{}, []}, RQ).

apply_drop(Char, nothing) -> {Char, []};
apply_drop(Char, {ItemName, {hp_restore, Amount}}) ->
    MaxHp = maps:get(max_hp, Char),
    NewHp = min(MaxHp, maps:get(hp, Char) + Amount),
    CName = maps:get(name, Char),
    {Char#{hp := NewHp},
     [io_lib:format("~s found ~s! (+~pHP)", [CName, ItemName, Amount])]};
apply_drop(Char, {ItemName, {attack, Bonus}}) ->
    CName = maps:get(name, Char),
    OldBonus = maps:get(attack_bonus, Char),
    Inv = maps:get(inventory, Char),
    {Char#{attack_bonus := OldBonus + Bonus, inventory := [ItemName | Inv]},
     [io_lib:format("~s found ~s! (+~p ATK)", [CName, ItemName, Bonus])]};
apply_drop(Char, {ItemName, {defense, Bonus}}) ->
    CName = maps:get(name, Char),
    OldBonus = maps:get(defense_bonus, Char),
    Inv = maps:get(inventory, Char),
    {Char#{defense_bonus := OldBonus + Bonus, inventory := [ItemName | Inv]},
     [io_lib:format("~s found ~s! (+~p DEF)", [CName, ItemName, Bonus])]};
apply_drop(Char, {ItemName, {evasion, Bonus}}) ->
    CName = maps:get(name, Char),
    Inv = maps:get(inventory, Char),
    {Char#{inventory := [ItemName | Inv]},
     [io_lib:format("~s found ~s! (+~p EVA)", [CName, ItemName, Bonus])]}.
