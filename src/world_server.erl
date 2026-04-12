-module(world_server).
-behaviour(gen_server).

-export([start_link/0, move/2, get_state/0, get_my_state/1, get_enemy_state/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MAP_SIZE, 40).
-define(CHAR_COUNT, 6).
-define(ENEMY_COUNT, 12).
-define(SHOP_COUNT, 3).
-define(INN_COUNT, 2).
-define(PARTY_FORM_TICKS, 3).
-define(DISPLAY_INTERVAL, 500).
-define(RESPAWN_DELAY, 2500).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Called by character/enemy processes to move
move(Pid, Direction) ->
    gen_server:cast(?MODULE, {move, Pid, Direction}).

%% Full state dump (used by display)
get_state() ->
    gen_server:call(?MODULE, get_state).

%% Called by character processes to get their own info + a world view
get_my_state(Pid) ->
    gen_server:call(?MODULE, {get_my_state, Pid}).

%% Called by enemy processes to check if they're still alive
get_enemy_state(Pid) ->
    gen_server:call(?MODULE, {get_enemy_state, Pid}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    rand:seed(exsss),
    Characters = spawn_characters(?CHAR_COUNT),
    Enemies = spawn_enemies(?ENEMY_COUNT),
    Shops = spawn_shops(?SHOP_COUNT),
    Inns = spawn_inns(?INN_COUNT),
    DisplayPid = display:start(self()),
    %% Display refreshes on its own timer
    erlang:send_after(?DISPLAY_INTERVAL, self(), render),
    State = #{
        characters => Characters,
        enemies => Enemies,
        shops => Shops,
        inns => Inns,
        display_pid => DisplayPid,
        event_log => [],
        move_count => 0
    },
    {ok, State}.

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call({get_my_state, Pid}, _From, State) ->
    #{characters := Chars, enemies := Enemies, shops := Shops, inns := Inns} = State,
    case maps:find(Pid, Chars) of
        {ok, Info} ->
            %% Build a lightweight world view for the character's AI
            EnemyPositions = maps:fold(fun(_EPid, EInfo, Acc) ->
                [{maps:get(x, EInfo), maps:get(y, EInfo)} | Acc]
            end, [], Enemies),
            ShopPositions = [{maps:get(x, S), maps:get(y, S)} || S <- Shops],
            InnPositions = [{maps:get(x, I), maps:get(y, I)} || I <- Inns],
            WorldView = #{enemy_positions => EnemyPositions,
                          shop_positions => ShopPositions,
                          inn_positions => InnPositions},
            {reply, {ok, Info, WorldView}, State};
        error ->
            {reply, dead, State}
    end;

handle_call({get_enemy_state, Pid}, _From, State) ->
    #{enemies := Enemies} = State,
    case maps:find(Pid, Enemies) of
        {ok, Info} -> {reply, {ok, Info}, State};
        error -> {reply, dead, State}
    end;

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast({move, Pid, Direction}, State) ->
    #{characters := Chars, enemies := Enemies, shops := Shops,
      inns := Inns, event_log := Log, move_count := MC} = State,
    case maps:find(Pid, Chars) of
        {ok, Info} ->
            case maps:get(party_role, Info, solo) of
                follower ->
                    {noreply, State};
                _ ->
                    {NewX, NewY} = apply_direction(Direction, maps:get(x, Info), maps:get(y, Info)),
                    NewInfo = Info#{x := NewX, y := NewY},
                    NewChars0 = move_followers(Pid, NewX, NewY, Chars#{Pid := NewInfo}),
                    {NewChars1, InnLog} = check_inn_interaction(Pid, NewX, NewY, NewChars0, Inns),
                    {NewChars2, ShopLog} = check_shop_interaction(Pid, NewX, NewY, NewChars1, Shops),
                    {NewChars3, NewEnemies, CombatLog} = check_enemy_collisions(Pid, NewX, NewY, NewChars2, Enemies),
                    %% Check party formation at inns periodically
                    {NewChars4, PartyLog} = maybe_check_parties(MC, NewChars3, Inns),
                    AllLog = InnLog ++ ShopLog ++ CombatLog ++ PartyLog,
                    NewLog = trim_log(Log ++ AllLog, 50),
                    {noreply, State#{characters := NewChars4, enemies := NewEnemies,
                                     event_log := NewLog, move_count := MC + 1}}
            end;
        error ->
            case maps:find(Pid, Enemies) of
                {ok, EInfo} ->
                    {NewX, NewY} = apply_direction(Direction, maps:get(x, EInfo), maps:get(y, EInfo)),
                    NewEInfo = EInfo#{x := NewX, y := NewY},
                    {noreply, State#{enemies := Enemies#{Pid := NewEInfo}}};
                error ->
                    {noreply, State}
            end
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Display refresh — runs on its own timer
handle_info(render, State) ->
    #{characters := Chars, enemies := Enemies, shops := Shops,
      inns := Inns, display_pid := DPid, event_log := Log, move_count := MC} = State,
    %% Clear inn flags for characters not at an inn
    InnPositions = [{maps:get(x, I), maps:get(y, I)} || I <- Inns],
    NewChars = clear_inn_flags(Chars, InnPositions),
    %% Check PvP (characters that happen to share a cell)
    {NewChars2, PvpLog} = check_pvp_collisions(NewChars),
    DPid ! {render, NewChars2, Enemies, Shops, Inns, Log ++ PvpLog, MC},
    erlang:send_after(?DISPLAY_INTERVAL, self(), render),
    {noreply, State#{characters := NewChars2, event_log := []}};

%% Respawn timers — each respawn schedules itself independently
handle_info({respawn_char, Name, Race}, State) ->
    #{characters := Chars} = State,
    Bonuses = util:race_bonuses(Race),
    BonusHp = maps:get(hp_bonus, Bonuses, 0),
    {X, Y} = util:random_pos(?MAP_SIZE),
    Info = #{name => Name, race => Race, level => 1,
             hp => 20 + BonusHp, max_hp => 20 + BonusHp,
             exp => 0, x => X, y => Y, inventory => [],
             attack_bonus => maps:get(attack_bonus, Bonuses, 0),
             defense_bonus => maps:get(defense_bonus, Bonuses, 0),
             gold => 0, party_role => solo, party_members => [],
             follower_pids => [], at_inn => false, inn_ticks => 0},
    Pid = character:start(Race),
    NewLog = maps:get(event_log, State) ++ [io_lib:format("~s respawned!", [Name])],
    {noreply, State#{characters := Chars#{Pid => Info},
                     event_log := trim_log(NewLog, 50)}};

handle_info({respawn_enemy, Name, Level}, State) ->
    #{enemies := Enemies} = State,
    {X, Y} = util:random_pos(?MAP_SIZE),
    MaxHp = Level * 4 + 5,
    Info = #{name => Name, level => Level, hp => MaxHp, max_hp => MaxHp,
             x => X, y => Y, type => enemy},
    Pid = enemy:start(Level),
    NewLog = maps:get(event_log, State) ++ [io_lib:format("A ~s appeared!", [Name])],
    {noreply, State#{enemies := Enemies#{Pid => Info},
                     event_log := trim_log(NewLog, 50)}};

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

trim_log(Log, Max) ->
    case length(Log) > Max of
        true -> lists:nthtail(length(Log) - Max, Log);
        false -> Log
    end.

%%%-------------------------------------------------------------------
%%% Spawning
%%%-------------------------------------------------------------------

spawn_characters(Count) ->
    lists:foldl(fun(_, Acc) ->
        Race = util:random_race(),
        Name = util:race_name(Race),
        Bonuses = util:race_bonuses(Race),
        BonusHp = maps:get(hp_bonus, Bonuses, 0),
        {X, Y} = util:random_pos(?MAP_SIZE),
        Info = #{name => Name, race => Race, level => 1,
                 hp => 20 + BonusHp, max_hp => 20 + BonusHp,
                 exp => 0, x => X, y => Y, inventory => [],
                 attack_bonus => maps:get(attack_bonus, Bonuses, 0),
                 defense_bonus => maps:get(defense_bonus, Bonuses, 0),
                 gold => 0, party_role => solo, party_members => [],
                 follower_pids => [], at_inn => false, inn_ticks => 0},
        Pid = character:start(Race),
        Acc#{Pid => Info}
    end, #{}, lists:seq(1, Count)).

spawn_enemies(Count) ->
    lists:foldl(fun(_, Acc) ->
        {Name, Level} = random_enemy(),
        {X, Y} = util:random_pos(?MAP_SIZE),
        MaxHp = Level * 4 + 5,
        Info = #{name => Name, level => Level, hp => MaxHp, max_hp => MaxHp,
                 x => X, y => Y, type => enemy},
        Pid = enemy:start(Level),
        Acc#{Pid => Info}
    end, #{}, lists:seq(1, Count)).

random_enemy() ->
    Enemies = [
        {"Goblin", 1}, {"Rat", 1}, {"Slime", 1}, {"Bat", 1},
        {"Wolf", 2}, {"Bandit", 2}, {"Skeleton", 2},
        {"Orc", 3}, {"Zombie", 3}, {"Spider", 3},
        {"Troll", 4}, {"Dark Mage", 4},
        {"Ogre", 5},
        {"Dragon", 6}
    ],
    lists:nth(rand:uniform(length(Enemies)), Enemies).

spawn_shops(Count) ->
    ShopNames = ["Ye Olde Armoury", "Potion Emporium", "Blade Bazaar",
                 "Mystic Market", "Shield Shack"],
    PickedNames = lists:sublist(util:shuffle(ShopNames), Count),
    lists:map(fun(SName) ->
        {X, Y} = util:random_pos(?MAP_SIZE),
        #{name => SName, x => X, y => Y}
    end, PickedNames).

spawn_inns(Count) ->
    InnNames = ["The Rusty Flagon", "Hearthstone Rest", "The Wanderer's Respite",
                "The Golden Goose", "Driftwood Tavern"],
    PickedNames = lists:sublist(util:shuffle(InnNames), Count),
    lists:map(fun(IName) ->
        {X, Y} = util:random_pos(?MAP_SIZE),
        #{name => IName, x => X, y => Y}
    end, PickedNames).

%%%-------------------------------------------------------------------
%%% Inn interaction
%%%-------------------------------------------------------------------

check_inn_interaction(CharPid, X, Y, Chars, Inns) ->
    AtInn = lists:any(fun(#{x := IX, y := IY}) -> IX =:= X andalso IY =:= Y end, Inns),
    case AtInn of
        false -> {Chars, []};
        true ->
            case maps:find(CharPid, Chars) of
                {ok, CharInfo} ->
                    Hp = maps:get(hp, CharInfo),
                    MaxHp = maps:get(max_hp, CharInfo),
                    CName = maps:get(name, CharInfo),
                    OldTicks = maps:get(inn_ticks, CharInfo, 0),
                    HealAmt = max(3, MaxHp div 5),
                    NewHp = min(MaxHp, Hp + HealAmt),
                    Healed = NewHp - Hp,
                    C1 = CharInfo#{hp := NewHp, at_inn := true, inn_ticks := OldTicks + 1},
                    HealLog = if
                        Healed > 0 -> [io_lib:format("~s rests at the inn (+~pHP)", [CName, Healed])];
                        true -> []
                    end,
                    {Chars#{CharPid := C1}, HealLog};
                error -> {Chars, []}
            end
    end.

clear_inn_flags(Chars, InnPositions) ->
    maps:map(fun(_Pid, Info) ->
        X = maps:get(x, Info),
        Y = maps:get(y, Info),
        AtInn = lists:any(fun({IX, IY}) -> IX =:= X andalso IY =:= Y end, InnPositions),
        case AtInn of
            true -> Info;
            false -> Info#{at_inn := false, inn_ticks := 0}
        end
    end, Chars).

%%%-------------------------------------------------------------------
%%% Party formation — checked every N moves to avoid overhead
%%%-------------------------------------------------------------------

maybe_check_parties(MC, Chars, Inns) when MC rem 10 =:= 0 ->
    check_party_formation(Chars, Inns);
maybe_check_parties(_MC, Chars, _Inns) ->
    {Chars, []}.

check_party_formation(Chars, Inns) ->
    lists:foldl(fun(#{x := IX, y := IY, name := InnName}, {AccChars, AccLog}) ->
        Candidates = maps:fold(fun(Pid, Info, Acc) ->
            case maps:get(party_role, Info, solo) =:= solo
                 andalso maps:get(x, Info) =:= IX
                 andalso maps:get(y, Info) =:= IY
                 andalso maps:get(inn_ticks, Info, 0) >= ?PARTY_FORM_TICKS of
                true -> [{Pid, Info} | Acc];
                false -> Acc
            end
        end, [], AccChars),
        case Candidates of
            [{Pid1, I1}, {Pid2, I2} | _] ->
                {LeaderPid, LeaderInfo, FollowerPid, FollowerInfo} =
                    case maps:get(level, I1) >= maps:get(level, I2) of
                        true  -> {Pid1, I1, Pid2, I2};
                        false -> {Pid2, I2, Pid1, I1}
                    end,
                LName = maps:get(name, LeaderInfo),
                FName = maps:get(name, FollowerInfo),
                NewLeader = LeaderInfo#{
                    party_role := leader,
                    party_members := [FollowerInfo],
                    follower_pids := [FollowerPid]
                },
                NewFollower = FollowerInfo#{
                    party_role := follower,
                    x := maps:get(x, LeaderInfo),
                    y := maps:get(y, LeaderInfo)
                },
                FollowerPid ! {follow, LeaderPid},
                NewChars = AccChars#{LeaderPid := NewLeader, FollowerPid := NewFollower},
                PartyLog = [io_lib:format("~s and ~s formed a party at ~s!",
                                          [LName, FName, InnName])],
                {NewChars, AccLog ++ PartyLog};
            _ ->
                {AccChars, AccLog}
        end
    end, {Chars, []}, Inns).

move_followers(LeaderPid, NewX, NewY, Chars) ->
    case maps:find(LeaderPid, Chars) of
        {ok, LeaderInfo} ->
            FollowerPids = maps:get(follower_pids, LeaderInfo, []),
            %% Update follower positions in the Chars map
            Chars2 = lists:foldl(fun(FPid, AccChars) ->
                case maps:find(FPid, AccChars) of
                    {ok, FInfo} ->
                        AccChars#{FPid := FInfo#{x := NewX, y := NewY}};
                    error -> AccChars
                end
            end, Chars, FollowerPids),
            %% Sync party_members in leader with live follower state
            UpdatedMembers = [case maps:find(FPid, Chars2) of
                {ok, FI} -> FI;
                error -> nil
            end || FPid <- FollowerPids],
            LiveMembers = [M || M <- UpdatedMembers, M =/= nil],
            NewLeader = maps:get(LeaderPid, Chars2),
            Chars2#{LeaderPid := NewLeader#{party_members := LiveMembers}};
        error -> Chars
    end.

disband_party(LeaderInfo, Chars) ->
    FollowerPids = maps:get(follower_pids, LeaderInfo, []),
    lists:foldl(fun(FPid, AccChars) ->
        FPid ! {solo},
        case maps:find(FPid, AccChars) of
            {ok, FInfo} ->
                AccChars#{FPid := FInfo#{party_role := solo, party_members := [],
                                         follower_pids := []}};
            error -> AccChars
        end
    end, Chars, FollowerPids).

%%%-------------------------------------------------------------------
%%% Shop interaction
%%%-------------------------------------------------------------------

shop_items() ->
    [
        {"Health Potion",    5,  {hp_restore, 10}},
        {"Iron Sword",       8,  {attack, 2}},
        {"Wooden Shield",    8,  {defense, 2}},
        {"Steel Blade",      15, {attack, 4}},
        {"Chain Mail",       15, {defense, 4}},
        {"Elixir",           12, {hp_restore, 25}},
        {"Enchanted Ring",   20, {attack, 6}},
        {"Tower Shield",     20, {defense, 6}}
    ].

check_shop_interaction(CharPid, X, Y, Chars, Shops) ->
    AtShop = lists:any(fun(#{x := SX, y := SY}) -> SX =:= X andalso SY =:= Y end, Shops),
    case AtShop of
        false -> {Chars, []};
        true ->
            case maps:find(CharPid, Chars) of
                {ok, CharInfo} ->
                    Gold = maps:get(gold, CharInfo, 0),
                    CName = maps:get(name, CharInfo),
                    case pick_shop_purchase(Gold) of
                        nothing -> {Chars, []};
                        {ItemName, Cost, Effect} ->
                            C1 = CharInfo#{gold := Gold - Cost},
                            {C2, ItemLog} = apply_drop(C1, {ItemName, Effect}),
                            BuyLog = [io_lib:format("~s bought ~s (-~pg)", [CName, ItemName, Cost])],
                            {Chars#{CharPid := C2}, BuyLog ++ ItemLog}
                    end;
                error -> {Chars, []}
            end
    end.

pick_shop_purchase(Gold) ->
    Items = shop_items(),
    Affordable = [{Name, Cost, Effect} || {Name, Cost, Effect} <- Items, Cost =< Gold],
    case Affordable of
        [] -> nothing;
        _ ->
            case rand:uniform(10) of
                N when N =< 4 ->
                    Heals = [{Na, Co, Ef} || {Na, Co, Ef} <- Affordable,
                              element(1, Ef) =:= hp_restore],
                    case Heals of
                        [] -> pick_best_stat(Affordable);
                        _ -> lists:last(lists:sort(fun({_, C1, _}, {_, C2, _}) -> C1 =< C2 end, Heals))
                    end;
                _ ->
                    pick_best_stat(Affordable)
            end
    end.

pick_best_stat(Affordable) ->
    Stats = [{Na, Co, Ef} || {Na, Co, Ef} <- Affordable,
              element(1, Ef) =:= attack orelse element(1, Ef) =:= defense],
    case Stats of
        [] ->
            lists:last(lists:sort(fun({_, C1, _}, {_, C2, _}) -> C1 =< C2 end, Affordable));
        _ ->
            lists:last(lists:sort(fun({_, C1, _}, {_, C2, _}) -> C1 =< C2 end, Stats))
    end.

%%%-------------------------------------------------------------------
%%% Combat
%%%-------------------------------------------------------------------

check_enemy_collisions(CharPid, X, Y, Chars, Enemies) ->
    EnemiesAtPos = maps:filter(fun(_EPid, EInfo) ->
        maps:get(x, EInfo) =:= X andalso maps:get(y, EInfo) =:= Y
    end, Enemies),
    maps:fold(fun(EPid, EInfo, {AccChars, AccEnemies, AccLog}) ->
        case maps:find(CharPid, AccChars) of
            {ok, CharInfo} ->
                IsLeader = maps:get(party_role, CharInfo, solo) =:= leader,
                case IsLeader of
                    true ->
                        %% Build party from live Chars map, not stale party_members
                        FollowerPids = maps:get(follower_pids, CharInfo, []),
                        LiveMembers = [FI || FPid <- FollowerPids,
                                       {ok, FI} <- [maps:find(FPid, AccChars)]],
                        FullParty = [CharInfo | LiveMembers],
                        resolve_group_enemy(CharPid, FullParty, EPid, EInfo,
                                            AccChars, AccEnemies, AccLog);
                    false ->
                        resolve_solo_enemy(CharPid, CharInfo, EPid, EInfo,
                                           AccChars, AccEnemies, AccLog)
                end;
            error ->
                {AccChars, AccEnemies, AccLog}
        end
    end, {Chars, Enemies, []}, EnemiesAtPos).

resolve_solo_enemy(CharPid, CharInfo, EPid, EInfo, AccChars, AccEnemies, AccLog) ->
    CName = maps:get(name, CharInfo),
    EName = maps:get(name, EInfo),
    ELevel = maps:get(level, EInfo),
    {Winner, _Loser, Dmg} = combat:resolve(CharInfo, EInfo),
    WinnerName = maps:get(name, Winner),
    CharWon = WinnerName =:= CName,
    if
        CharWon ->
            NewEHp = maps:get(hp, EInfo) - Dmg,
            if
                NewEHp =< 0 ->
                    XpGain = ELevel + 1,
                    GoldGain = ELevel * 2 + rand:uniform(3),
                    C1 = CharInfo#{exp := maps:get(exp, CharInfo) + XpGain,
                                   gold := maps:get(gold, CharInfo, 0) + GoldGain},
                    C2 = combat:check_level_up(C1),
                    LvlLog = case maps:get(level, C2) > maps:get(level, CharInfo) of
                        true -> [io_lib:format("~s leveled up to Lv~p!", [CName, maps:get(level, C2)])];
                        false -> []
                    end,
                    Drop = combat:generate_drop(ELevel),
                    {C3, DropLog} = apply_drop(C2, Drop),
                    KillLog = [io_lib:format("~s slew ~s(Lv~p) [+~pXP +~pg]",
                                             [CName, EName, ELevel, XpGain, GoldGain])],
                    schedule_respawn_enemy(EName, ELevel),
                    {AccChars#{CharPid := C3}, maps:remove(EPid, AccEnemies),
                     AccLog ++ KillLog ++ LvlLog ++ DropLog};
                true ->
                    {AccChars, AccEnemies#{EPid := EInfo#{hp := NewEHp}},
                     AccLog ++ [io_lib:format("~s hit ~s (-~pHP)", [CName, EName, Dmg])]}
            end;
        true ->
            NewCHp = maps:get(hp, CharInfo) - Dmg,
            if
                NewCHp =< 0 ->
                    Race = maps:get(race, CharInfo, human),
                    schedule_respawn_char(CName, Race),
                    NewChars = disband_party(CharInfo, maps:remove(CharPid, AccChars)),
                    {NewChars, AccEnemies,
                     AccLog ++ [io_lib:format("~s was mauled by ~s!", [CName, EName])]};
                true ->
                    {AccChars#{CharPid := CharInfo#{hp := NewCHp}}, AccEnemies,
                     AccLog ++ [io_lib:format("~s hit by ~s (-~pHP)", [CName, EName, Dmg])]}
            end
    end.

resolve_group_enemy(CharPid, FullParty, EPid, EInfo, AccChars, AccEnemies, AccLog) ->
    LeaderName = maps:get(name, hd(FullParty)),
    EName = maps:get(name, EInfo),
    ELevel = maps:get(level, EInfo),
    {Result, UpdatedParty, UpdatedEnemy, Dmg, HitIdx} =
        combat:resolve_group(FullParty, EInfo),
    case Result of
        party_won ->
            NewEHp = maps:get(hp, UpdatedEnemy),
            if
                NewEHp =< 0 ->
                    XpGain = ELevel + 1,
                    GoldGain = ELevel * 2 + rand:uniform(3),
                    Leader0 = hd(UpdatedParty),
                    Leader1 = Leader0#{exp := maps:get(exp, Leader0) + XpGain,
                                       gold := maps:get(gold, Leader0, 0) + GoldGain},
                    Leader2 = combat:check_level_up(Leader1),
                    UpdatedMembers = [begin
                        M1 = M#{exp := maps:get(exp, M) + XpGain},
                        combat:check_level_up(M1)
                    end || M <- tl(UpdatedParty)],
                    Drop = combat:generate_drop(ELevel),
                    {Leader3, DropLog} = apply_drop(Leader2, Drop),
                    KillLog = [io_lib:format("~s's party slew ~s(Lv~p) [+~pXP +~pg]",
                                             [LeaderName, EName, ELevel, XpGain, GoldGain])],
                    schedule_respawn_enemy(EName, ELevel),
                    NewLeader = Leader3#{party_members := UpdatedMembers},
                    FollowerPids = maps:get(follower_pids, NewLeader, []),
                    NewChars = update_follower_infos(FollowerPids, UpdatedMembers,
                                                     AccChars#{CharPid := NewLeader}),
                    {NewChars, maps:remove(EPid, AccEnemies),
                     AccLog ++ KillLog ++ DropLog};
                true ->
                    Leader0 = hd(UpdatedParty),
                    NewLeader = Leader0#{party_members := tl(UpdatedParty)},
                    {AccChars#{CharPid := NewLeader},
                     AccEnemies#{EPid := UpdatedEnemy},
                     AccLog ++ [io_lib:format("~s's party hit ~s (-~pHP)",
                                              [LeaderName, EName, Dmg])]}
            end;
        party_lost ->
            HitMember = lists:nth(HitIdx, UpdatedParty),
            HitName = maps:get(name, HitMember),
            HitHp = maps:get(hp, HitMember),
            if
                HitHp =< 0 andalso HitIdx =:= 1 ->
                    Race = maps:get(race, hd(FullParty), human),
                    schedule_respawn_char(maps:get(name, hd(FullParty)), Race),
                    NewChars = disband_party(hd(FullParty), maps:remove(CharPid, AccChars)),
                    {NewChars, AccEnemies,
                     AccLog ++ [io_lib:format("~s was slain by ~s! Party disbanded!", [HitName, EName])]};
                HitHp =< 0 ->
                    FollowerPids = maps:get(follower_pids, hd(UpdatedParty), []),
                    DeadFPid = lists:nth(HitIdx - 1, FollowerPids),
                    DeadFRace = maps:get(race, HitMember, human),
                    schedule_respawn_char(HitName, DeadFRace),
                    NewFollowerPids = lists:delete(DeadFPid, FollowerPids),
                    NewMembers = lists:delete(HitMember, tl(UpdatedParty)),
                    Leader0 = hd(UpdatedParty),
                    NewRole = case NewMembers of [] -> solo; _ -> leader end,
                    NewLeader = Leader0#{party_role := NewRole,
                                         party_members := NewMembers,
                                         follower_pids := NewFollowerPids},
                    NewChars = maps:remove(DeadFPid, AccChars#{CharPid := NewLeader}),
                    {NewChars, AccEnemies,
                     AccLog ++ [io_lib:format("~s was slain by ~s!", [HitName, EName])]};
                true ->
                    Leader0 = hd(UpdatedParty),
                    NewLeader = Leader0#{party_members := tl(UpdatedParty)},
                    NewChars = case HitIdx > 1 of
                        true ->
                            FollowerPids = maps:get(follower_pids, NewLeader, []),
                            update_follower_infos(FollowerPids, tl(UpdatedParty),
                                                   AccChars#{CharPid := NewLeader});
                        false ->
                            AccChars#{CharPid := NewLeader}
                    end,
                    {NewChars, AccEnemies,
                     AccLog ++ [io_lib:format("~s hit by ~s (-~pHP)", [HitName, EName, Dmg])]}
            end
    end.

update_follower_infos(FollowerPids, MemberInfos, Chars) ->
    %% Update combat-relevant fields but preserve position from Chars map
    Pairs = safe_zip(FollowerPids, MemberInfos),
    lists:foldl(fun({FPid, CombatInfo}, AccChars) ->
        case maps:find(FPid, AccChars) of
            {ok, CurrentInfo} ->
                %% Merge combat results (hp, exp, level, etc.) but keep current position
                Merged = CombatInfo#{x := maps:get(x, CurrentInfo),
                                     y := maps:get(y, CurrentInfo)},
                AccChars#{FPid := Merged};
            error -> AccChars
        end
    end, Chars, Pairs).

safe_zip([], _) -> [];
safe_zip(_, []) -> [];
safe_zip([H1 | T1], [H2 | T2]) -> [{H1, H2} | safe_zip(T1, T2)].

%% Schedule respawns as delayed messages to self
schedule_respawn_char(Name, Race) ->
    erlang:send_after(?RESPAWN_DELAY, self(), {respawn_char, Name, Race}).

schedule_respawn_enemy(Name, Level) ->
    erlang:send_after(?RESPAWN_DELAY, self(), {respawn_enemy, Name, Level}).

check_pvp_collisions(Chars) ->
    ByPos = maps:fold(fun(Pid, Info, Acc) ->
        case maps:get(party_role, Info, solo) of
            follower -> Acc;
            _ ->
                Pos = {maps:get(x, Info), maps:get(y, Info)},
                Current = maps:get(Pos, Acc, []),
                Acc#{Pos => [{Pid, Info} | Current]}
        end
    end, #{}, Chars),
    maps:fold(fun(_Pos, Occupants, {AccChars, AccLog}) ->
        case Occupants of
            [_Single] -> {AccChars, AccLog};
            [{Pid1, _}, {Pid2, _} | _] ->
                case same_party(Pid1, Pid2, AccChars) of
                    true -> {AccChars, AccLog};
                    false ->
                        case {maps:find(Pid1, AccChars), maps:find(Pid2, AccChars)} of
                            {{ok, I1}, {ok, I2}} ->
                                resolve_pvp(Pid1, I1, Pid2, I2, AccChars, AccLog);
                            _ -> {AccChars, AccLog}
                        end
                end
        end
    end, {Chars, []}, ByPos).

same_party(Pid1, Pid2, Chars) ->
    Check1 = case maps:find(Pid1, Chars) of
        {ok, I1} -> lists:member(Pid2, maps:get(follower_pids, I1, []));
        error -> false
    end,
    Check2 = case maps:find(Pid2, Chars) of
        {ok, I2} -> lists:member(Pid1, maps:get(follower_pids, I2, []));
        error -> false
    end,
    Check1 orelse Check2.

resolve_pvp(Pid1, I1, Pid2, I2, AccChars, AccLog) ->
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
            XpGain = maps:get(level, LoserInfo),
            W1 = WinnerInfo#{exp := maps:get(exp, WinnerInfo) + XpGain},
            W2 = combat:check_level_up(W1),
            LvlLog = case maps:get(level, W2) > maps:get(level, WinnerInfo) of
                true -> [io_lib:format("~s leveled up to Lv~p!", [WName, maps:get(level, W2)])];
                false -> []
            end,
            LRace = maps:get(race, LoserInfo, human),
            schedule_respawn_char(LName, LRace),
            NewChars = disband_party(LoserInfo, maps:remove(LoserPid, AccChars#{WinnerPid := W2})),
            {NewChars,
             AccLog ++ [io_lib:format("~s defeated ~s! [+~pXP]", [WName, LName, XpGain])] ++ LvlLog};
        true ->
            {AccChars#{LoserPid := LoserInfo#{hp := NewLoserHp}},
             AccLog ++ [io_lib:format("~s clashed with ~s (-~pHP)", [WName, LName, Dmg])]}
    end.

%%%-------------------------------------------------------------------
%%% Drop handling
%%%-------------------------------------------------------------------

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
