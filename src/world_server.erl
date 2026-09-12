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

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

move(Pid, Direction) ->
    gen_server:cast(?MODULE, {move, Pid, Direction}).

get_state() ->
    gen_server:call(?MODULE, get_state).

get_my_state(Pid) ->
    gen_server:call(?MODULE, {get_my_state, Pid}).

get_enemy_state(Pid) ->
    gen_server:call(?MODULE, {get_enemy_state, Pid}).

init([]) ->
    rand:seed(exsss),
    Characters = spawn_characters(?CHAR_COUNT),
    Enemies = spawn_enemies(?ENEMY_COUNT),
    Shops = spawn_shops(?SHOP_COUNT),
    Inns = spawn_inns(?INN_COUNT),
    DisplayPid = display:start(self()),
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
    {reply, character_view(Pid, State), State};
handle_call({get_enemy_state, Pid}, _From, State) ->
    {reply, enemy_view(Pid, maps:get(enemies, State)), State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

character_view(Pid, State) ->
    case maps:find(Pid, maps:get(characters, State)) of
        {ok, Info} -> {ok, Info, world_view(State)};
        error -> dead
    end.

enemy_view(Pid, Enemies) ->
    case maps:find(Pid, Enemies) of
        {ok, Info} -> {ok, Info};
        error -> dead
    end.

world_view(State) ->
    #{enemy_positions => enemy_positions(maps:get(enemies, State)),
      shop_positions => place_positions(maps:get(shops, State)),
      inn_positions => place_positions(maps:get(inns, State))}.

enemy_positions(Enemies) ->
    maps:fold(fun(_EPid, EInfo, Acc) ->
        [{maps:get(x, EInfo), maps:get(y, EInfo)} | Acc]
    end, [], Enemies).

place_positions(Places) ->
    [{maps:get(x, Place), maps:get(y, Place)} || Place <- Places].

handle_cast({move, Pid, Direction}, State) ->
    case maps:find(Pid, maps:get(characters, State)) of
        {ok, Info} -> move_character(Pid, Info, Direction, State);
        error -> move_non_character(Pid, Direction, State)
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

move_character(Pid, Info, Direction, State) ->
    case maps:get(party_role, Info, solo) of
        follower -> {noreply, State};
        _ -> apply_character_move(Pid, Info, Direction, State)
    end.

move_non_character(Pid, Direction, State) ->
    Enemies = maps:get(enemies, State),
    case maps:find(Pid, Enemies) of
        {ok, EInfo} ->
            {NewX, NewY} = apply_direction(Direction, maps:get(x, EInfo), maps:get(y, EInfo)),
            {noreply, State#{enemies := Enemies#{Pid := EInfo#{x := NewX, y := NewY}}}};
        error ->
            {noreply, State}
    end.

apply_character_move(Pid, Info, Direction, State) ->
    #{characters := Chars, enemies := Enemies, shops := Shops,
      inns := Inns, event_log := Log, move_count := MC} = State,
    {NewX, NewY} = apply_direction(Direction, maps:get(x, Info), maps:get(y, Info)),
    NewInfo = Info#{x := NewX, y := NewY},
    NewChars0 = move_followers(Pid, NewX, NewY, Chars#{Pid := NewInfo}),
    {NewChars1, InnLog} = check_inn_interaction(Pid, NewX, NewY, NewChars0, Inns),
    {NewChars2, ShopLog} = check_shop_interaction(Pid, NewX, NewY, NewChars1, Shops),
    {NewChars3, NewEnemies, CombatLog} = check_enemy_collisions(Pid, NewX, NewY, NewChars2, Enemies),
    {NewChars4, PartyLog} = maybe_check_parties(MC, NewChars3, Inns),
    AllLog = InnLog ++ ShopLog ++ CombatLog ++ PartyLog,
    NewLog = trim_log(Log ++ AllLog, 50),
    {noreply, State#{characters := NewChars4, enemies := NewEnemies,
                     event_log := NewLog, move_count := MC + 1}}.

handle_info(render, State) ->
    #{characters := Chars, enemies := Enemies, shops := Shops,
      inns := Inns, display_pid := DPid, event_log := Log, move_count := MC} = State,
    InnPositions = place_positions(Inns),
    NewChars = clear_inn_flags(Chars, InnPositions),
    {NewChars2, PvpLog} = check_pvp_collisions(NewChars),
    DPid ! {render, NewChars2, Enemies, Shops, Inns, Log ++ PvpLog, MC},
    erlang:send_after(?DISPLAY_INTERVAL, self(), render),
    {noreply, State#{characters := NewChars2, event_log := []}};
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
    Pid = start_character(Race),
    NewLog = maps:get(event_log, State) ++ [io_lib:format("~s respawned!", [Name])],
    {noreply, State#{characters := Chars#{Pid => Info},
                     event_log := trim_log(NewLog, 50)}};
handle_info({respawn_enemy, Name, Level}, State) ->
    #{enemies := Enemies} = State,
    {X, Y} = util:random_pos(?MAP_SIZE),
    MaxHp = Level * 4 + 5,
    Info = #{name => Name, level => Level, hp => MaxHp, max_hp => MaxHp,
             x => X, y => Y, type => enemy},
    Pid = start_enemy(Level),
    NewLog = maps:get(event_log, State) ++ [io_lib:format("A ~s appeared!", [Name])],
    {noreply, State#{enemies := Enemies#{Pid => Info},
                     event_log := trim_log(NewLog, 50)}};
handle_info(_Msg, State) ->
    {noreply, State}.

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

start_character(Race) ->
    character:start(Race, fun get_my_state/1, fun move/2).

start_enemy(Level) ->
    enemy:start(Level, fun get_enemy_state/1, fun move/2).

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
        Pid = start_character(Race),
        Acc#{Pid => Info}
    end, #{}, lists:seq(1, Count)).

spawn_enemies(Count) ->
    lists:foldl(fun(_, Acc) ->
        {Name, Level} = random_enemy(),
        {X, Y} = util:random_pos(?MAP_SIZE),
        MaxHp = Level * 4 + 5,
        Info = #{name => Name, level => Level, hp => MaxHp, max_hp => MaxHp,
                 x => X, y => Y, type => enemy},
        Pid = start_enemy(Level),
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

check_inn_interaction(CharPid, X, Y, Chars, Inns) ->
    case at_any_inn(X, Y, Inns) of
        false -> {Chars, []};
        true -> rest_at_inn(CharPid, Chars)
    end.

at_any_inn(X, Y, Inns) ->
    lists:any(fun(#{x := IX, y := IY}) -> IX =:= X andalso IY =:= Y end, Inns).

rest_at_inn(CharPid, Chars) ->
    CharInfo = maps:get(CharPid, Chars),
    Hp = maps:get(hp, CharInfo),
    MaxHp = maps:get(max_hp, CharInfo),
    HealAmt = max(3, MaxHp div 5),
    NewHp = min(MaxHp, Hp + HealAmt),
    C1 = CharInfo#{hp := NewHp, at_inn := true,
                   inn_ticks := maps:get(inn_ticks, CharInfo, 0) + 1},
    {Chars#{CharPid := C1}, heal_log(maps:get(name, CharInfo), NewHp - Hp)}.

heal_log(_Name, 0) -> [];
heal_log(Name, Healed) ->
    [io_lib:format("~s rests at the inn (+~pHP)", [Name, Healed])].

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

maybe_check_parties(MC, Chars, Inns) when MC rem 10 =:= 0 ->
    check_party_formation(Chars, Inns);
maybe_check_parties(_MC, Chars, _Inns) ->
    {Chars, []}.

check_party_formation(Chars, Inns) ->
    lists:foldl(fun form_party_at_inn/2, {Chars, []}, Inns).

form_party_at_inn(#{x := IX, y := IY, name := InnName}, {AccChars, AccLog}) ->
    case party_candidates(IX, IY, AccChars) of
        [{Pid1, I1}, {Pid2, I2} | _] ->
            form_party(Pid1, I1, Pid2, I2, InnName, AccChars, AccLog);
        _ ->
            {AccChars, AccLog}
    end.

party_candidates(IX, IY, Chars) ->
    maps:fold(fun(Pid, Info, Acc) ->
        case party_eligible(Info, IX, IY) of
            true -> [{Pid, Info} | Acc];
            false -> Acc
        end
    end, [], Chars).

party_eligible(Info, IX, IY) ->
    maps:get(party_role, Info, solo) =:= solo
        andalso maps:get(x, Info) =:= IX
        andalso maps:get(y, Info) =:= IY
        andalso maps:get(inn_ticks, Info, 0) >= ?PARTY_FORM_TICKS.

form_party(Pid1, I1, Pid2, I2, InnName, AccChars, AccLog) ->
    {LeaderPid, LeaderInfo, FollowerPid, FollowerInfo} = pick_leader(Pid1, I1, Pid2, I2),
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
    {NewChars, AccLog ++ PartyLog}.

pick_leader(Pid1, I1, Pid2, I2) ->
    case maps:get(level, I1) >= maps:get(level, I2) of
        true -> {Pid1, I1, Pid2, I2};
        false -> {Pid2, I2, Pid1, I1}
    end.

move_followers(LeaderPid, NewX, NewY, Chars) ->
    LeaderInfo = maps:get(LeaderPid, Chars),
    FollowerPids = maps:get(follower_pids, LeaderInfo, []),
    Chars2 = pin_followers(FollowerPids, NewX, NewY, Chars),
    UpdatedLeader = maps:get(LeaderPid, Chars2),
    Chars2#{LeaderPid := UpdatedLeader#{party_members := live_members(FollowerPids, Chars2)}}.

pin_followers(FollowerPids, X, Y, Chars) ->
    lists:foldl(fun(FPid, AccChars) ->
        case maps:find(FPid, AccChars) of
            {ok, FInfo} -> AccChars#{FPid := FInfo#{x := X, y := Y}};
            error -> AccChars
        end
    end, Chars, FollowerPids).

live_members(FollowerPids, Chars) ->
    [FInfo || FPid <- FollowerPids, {ok, FInfo} <- [maps:find(FPid, Chars)]].

disband_party(LeaderInfo, Chars) ->
    FollowerPids = maps:get(follower_pids, LeaderInfo, []),
    lists:foldl(fun release_follower/2, Chars, FollowerPids).

release_follower(FPid, AccChars) ->
    FPid ! {solo},
    case maps:find(FPid, AccChars) of
        {ok, FInfo} ->
            AccChars#{FPid := FInfo#{party_role := solo, party_members := [],
                                     follower_pids := []}};
        error ->
            AccChars
    end.

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
    case at_any_shop(X, Y, Shops) of
        false -> {Chars, []};
        true -> buy_at_shop(CharPid, Chars)
    end.

at_any_shop(X, Y, Shops) ->
    lists:any(fun(#{x := SX, y := SY}) -> SX =:= X andalso SY =:= Y end, Shops).

buy_at_shop(CharPid, Chars) ->
    CharInfo = maps:get(CharPid, Chars),
    Gold = maps:get(gold, CharInfo, 0),
    case pick_shop_purchase(Gold) of
        nothing ->
            {Chars, []};
        {ItemName, Cost, Effect} ->
            C1 = CharInfo#{gold := Gold - Cost},
            {C2, ItemLog} = apply_drop(C1, {ItemName, Effect}),
            BuyLog = [io_lib:format("~s bought ~s (-~pg)",
                                    [maps:get(name, CharInfo), ItemName, Cost])],
            {Chars#{CharPid := C2}, BuyLog ++ ItemLog}
    end.

pick_shop_purchase(Gold) ->
    Affordable = [{Name, Cost, Effect} || {Name, Cost, Effect} <- shop_items(), Cost =< Gold],
    case Affordable of
        [] -> nothing;
        _ -> pick_from(Affordable)
    end.

pick_from(Affordable) ->
    case rand:uniform(10) of
        N when N =< 4 -> priciest(heals(Affordable));
        _ -> pick_best_stat(Affordable)
    end.

heals(Items) ->
    [{Na, Co, Ef} || {Na, Co, Ef} <- Items, element(1, Ef) =:= hp_restore].

priciest(Items) ->
    lists:last(lists:sort(fun({_, C1, _}, {_, C2, _}) -> C1 =< C2 end, Items)).

pick_best_stat(Affordable) ->
    Stats = [{Na, Co, Ef} || {Na, Co, Ef} <- Affordable,
              element(1, Ef) =:= attack orelse element(1, Ef) =:= defense],
    case Stats of
        [] -> priciest(Affordable);
        _ -> priciest(Stats)
    end.

check_enemy_collisions(CharPid, X, Y, Chars, Enemies) ->
    EnemiesAtPos = maps:filter(fun(_EPid, EInfo) ->
        maps:get(x, EInfo) =:= X andalso maps:get(y, EInfo) =:= Y
    end, Enemies),
    maps:fold(fun(EPid, EInfo, Acc) ->
        fight_at_cell(CharPid, EPid, EInfo, Acc)
    end, {Chars, Enemies, []}, EnemiesAtPos).

fight_at_cell(CharPid, EPid, EInfo, {AccChars, AccEnemies, AccLog}) ->
    case maps:find(CharPid, AccChars) of
        {ok, CharInfo} ->
            engage_enemy(CharPid, CharInfo, EPid, EInfo, AccChars, AccEnemies, AccLog);
        error ->
            {AccChars, AccEnemies, AccLog}
    end.

engage_enemy(CharPid, CharInfo, EPid, EInfo, AccChars, AccEnemies, AccLog) ->
    case maps:get(party_role, CharInfo, solo) =:= leader of
        true ->
            FollowerPids = maps:get(follower_pids, CharInfo, []),
            LiveMembers = [FInfo || FPid <- FollowerPids,
                           {ok, FInfo} <- [maps:find(FPid, AccChars)]],
            resolve_group_enemy(CharPid, [CharInfo | LiveMembers], EPid, EInfo,
                                AccChars, AccEnemies, AccLog);
        false ->
            resolve_solo_enemy(CharPid, CharInfo, EPid, EInfo,
                               AccChars, AccEnemies, AccLog)
    end.

resolve_solo_enemy(CharPid, CharInfo, EPid, EInfo, AccChars, AccEnemies, AccLog) ->
    {Winner, _Loser, Dmg} = combat:resolve(CharInfo, EInfo),
    case maps:get(name, Winner) =:= maps:get(name, CharInfo) of
        true ->
            solo_victory(CharPid, CharInfo, EPid, EInfo, Dmg, AccChars, AccEnemies, AccLog);
        false ->
            solo_defeat(CharPid, CharInfo, EInfo, Dmg, AccChars, AccEnemies, AccLog)
    end.

solo_victory(CharPid, CharInfo, EPid, EInfo, Dmg, AccChars, AccEnemies, AccLog) ->
    NewEHp = maps:get(hp, EInfo) - Dmg,
    case NewEHp =< 0 of
        true ->
            enemy_slain(CharPid, CharInfo, EPid, EInfo, AccChars, AccEnemies, AccLog);
        false ->
            {AccChars, AccEnemies#{EPid := EInfo#{hp := NewEHp}},
             AccLog ++ [io_lib:format("~s hit ~s (-~pHP)",
                                      [maps:get(name, CharInfo), maps:get(name, EInfo), Dmg])]}
    end.

enemy_slain(CharPid, CharInfo, EPid, EInfo, AccChars, AccEnemies, AccLog) ->
    CName = maps:get(name, CharInfo),
    EName = maps:get(name, EInfo),
    ELevel = maps:get(level, EInfo),
    XpGain = ELevel + 1,
    GoldGain = ELevel * 2 + rand:uniform(3),
    C1 = CharInfo#{exp := maps:get(exp, CharInfo) + XpGain,
                   gold := maps:get(gold, CharInfo, 0) + GoldGain},
    C2 = combat:check_level_up(C1),
    LvlLog = level_log(maps:get(level, CharInfo), maps:get(level, C2), CName),
    Drop = combat:generate_drop(ELevel),
    {C3, DropLog} = apply_drop(C2, Drop),
    KillLog = [io_lib:format("~s slew ~s(Lv~p) [+~pXP +~pg]",
                             [CName, EName, ELevel, XpGain, GoldGain])],
    schedule_respawn_enemy(EName, ELevel),
    {AccChars#{CharPid := C3}, maps:remove(EPid, AccEnemies),
     AccLog ++ KillLog ++ LvlLog ++ DropLog}.

level_log(OldLevel, NewLevel, Name) ->
    case NewLevel > OldLevel of
        true -> [io_lib:format("~s leveled up to Lv~p!", [Name, NewLevel])];
        false -> []
    end.

solo_defeat(CharPid, CharInfo, EInfo, Dmg, AccChars, AccEnemies, AccLog) ->
    NewCHp = maps:get(hp, CharInfo) - Dmg,
    case NewCHp =< 0 of
        true ->
            character_mauled(CharPid, CharInfo, EInfo, AccChars, AccEnemies, AccLog);
        false ->
            {AccChars#{CharPid := CharInfo#{hp := NewCHp}}, AccEnemies,
             AccLog ++ [io_lib:format("~s hit by ~s (-~pHP)",
                                      [maps:get(name, CharInfo), maps:get(name, EInfo), Dmg])]}
    end.

character_mauled(CharPid, CharInfo, EInfo, AccChars, AccEnemies, AccLog) ->
    CName = maps:get(name, CharInfo),
    Race = maps:get(race, CharInfo, human),
    schedule_respawn_char(CName, Race),
    NewChars = disband_party(CharInfo, maps:remove(CharPid, AccChars)),
    {NewChars, AccEnemies,
     AccLog ++ [io_lib:format("~s was mauled by ~s!", [CName, maps:get(name, EInfo)])]}.

resolve_group_enemy(CharPid, FullParty, EPid, EInfo, AccChars, AccEnemies, AccLog) ->
    {Result, UpdatedParty, UpdatedEnemy, Dmg, HitIdx} =
        combat:resolve_group(FullParty, EInfo),
    group_outcome(Result, CharPid, FullParty, UpdatedParty, UpdatedEnemy, Dmg,
                  HitIdx, EPid, EInfo, AccChars, AccEnemies, AccLog).

group_outcome(party_won, CharPid, _FullParty, UpdatedParty, UpdatedEnemy, Dmg,
              _HitIdx, EPid, EInfo, AccChars, AccEnemies, AccLog) ->
    case maps:get(hp, UpdatedEnemy) =< 0 of
        true ->
            party_slays_enemy(CharPid, UpdatedParty, EPid, EInfo, AccChars, AccEnemies, AccLog);
        false ->
            party_hits_enemy(CharPid, UpdatedParty, UpdatedEnemy, Dmg, EPid, EInfo,
                             AccChars, AccEnemies, AccLog)
    end;
group_outcome(party_lost, CharPid, FullParty, UpdatedParty, _UpdatedEnemy, Dmg,
              HitIdx, _EPid, EInfo, AccChars, AccEnemies, AccLog) ->
    HitMember = lists:nth(HitIdx, UpdatedParty),
    member_hit_outcome(maps:get(hp, HitMember), HitIdx, CharPid, FullParty, UpdatedParty,
                       HitMember, Dmg, EInfo, AccChars, AccEnemies, AccLog).

party_slays_enemy(CharPid, UpdatedParty, EPid, EInfo, AccChars, AccEnemies, AccLog) ->
    LeaderName = maps:get(name, hd(UpdatedParty)),
    EName = maps:get(name, EInfo),
    ELevel = maps:get(level, EInfo),
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
     AccLog ++ KillLog ++ DropLog}.

party_hits_enemy(CharPid, UpdatedParty, UpdatedEnemy, Dmg, EPid, EInfo,
                 AccChars, AccEnemies, AccLog) ->
    LeaderName = maps:get(name, hd(UpdatedParty)),
    EName = maps:get(name, EInfo),
    Leader0 = hd(UpdatedParty),
    NewLeader = Leader0#{party_members := tl(UpdatedParty)},
    {AccChars#{CharPid := NewLeader},
     AccEnemies#{EPid := UpdatedEnemy},
     AccLog ++ [io_lib:format("~s's party hit ~s (-~pHP)", [LeaderName, EName, Dmg])]}.

member_hit_outcome(Hp, 1, CharPid, FullParty, _UpdatedParty, HitMember, _Dmg,
                   EInfo, AccChars, AccEnemies, AccLog) when Hp =< 0 ->
    Race = maps:get(race, hd(FullParty), human),
    schedule_respawn_char(maps:get(name, hd(FullParty)), Race),
    NewChars = disband_party(hd(FullParty), maps:remove(CharPid, AccChars)),
    {NewChars, AccEnemies,
     AccLog ++ [io_lib:format("~s was slain by ~s! Party disbanded!",
                              [maps:get(name, HitMember), maps:get(name, EInfo)])]};
member_hit_outcome(Hp, HitIdx, CharPid, _FullParty, UpdatedParty, HitMember, _Dmg,
                   EInfo, AccChars, AccEnemies, AccLog) when Hp =< 0 ->
    HitName = maps:get(name, HitMember),
    FollowerPids = maps:get(follower_pids, hd(UpdatedParty), []),
    DeadFPid = lists:nth(HitIdx - 1, FollowerPids),
    DeadFRace = maps:get(race, HitMember, human),
    schedule_respawn_char(HitName, DeadFRace),
    NewFollowerPids = lists:delete(DeadFPid, FollowerPids),
    NewMembers = lists:delete(HitMember, tl(UpdatedParty)),
    Leader0 = hd(UpdatedParty),
    NewLeader = Leader0#{party_role := member_role(NewMembers),
                         party_members := NewMembers,
                         follower_pids := NewFollowerPids},
    NewChars = maps:remove(DeadFPid, AccChars#{CharPid := NewLeader}),
    {NewChars, AccEnemies,
     AccLog ++ [io_lib:format("~s was slain by ~s!", [HitName, maps:get(name, EInfo)])]};
member_hit_outcome(_Hp, HitIdx, CharPid, _FullParty, UpdatedParty, HitMember, Dmg,
                   EInfo, AccChars, AccEnemies, AccLog) ->
    Leader0 = hd(UpdatedParty),
    NewLeader = Leader0#{party_members := tl(UpdatedParty)},
    NewChars = sync_hit_member(HitIdx, NewLeader, tl(UpdatedParty), CharPid, AccChars),
    {NewChars, AccEnemies,
     AccLog ++ [io_lib:format("~s hit by ~s (-~pHP)",
                              [maps:get(name, HitMember), maps:get(name, EInfo), Dmg])]}.

member_role([]) -> solo;
member_role(_Members) -> leader.

sync_hit_member(1, NewLeader, _Members, CharPid, AccChars) ->
    AccChars#{CharPid := NewLeader};
sync_hit_member(_HitIdx, NewLeader, Members, CharPid, AccChars) ->
    FollowerPids = maps:get(follower_pids, NewLeader, []),
    update_follower_infos(FollowerPids, Members, AccChars#{CharPid := NewLeader}).

update_follower_infos(FollowerPids, MemberInfos, Chars) ->
    Pairs = safe_zip(FollowerPids, MemberInfos),
    lists:foldl(fun({FPid, CombatInfo}, AccChars) ->
        case maps:find(FPid, AccChars) of
            {ok, CurrentInfo} ->
                Merged = CombatInfo#{x := maps:get(x, CurrentInfo),
                                     y := maps:get(y, CurrentInfo)},
                AccChars#{FPid := Merged};
            error ->
                AccChars
        end
    end, Chars, Pairs).

safe_zip([], _) -> [];
safe_zip(_, []) -> [];
safe_zip([H1 | T1], [H2 | T2]) -> [{H1, H2} | safe_zip(T1, T2)].

schedule_respawn_char(Name, Race) ->
    erlang:send_after(?RESPAWN_DELAY, self(), {respawn_char, Name, Race}).

schedule_respawn_enemy(Name, Level) ->
    erlang:send_after(?RESPAWN_DELAY, self(), {respawn_enemy, Name, Level}).

check_pvp_collisions(Chars) ->
    ByPos = group_by_position(Chars),
    maps:fold(fun resolve_cell/3, {Chars, []}, ByPos).

group_by_position(Chars) ->
    maps:fold(fun(Pid, Info, Acc) ->
        case maps:get(party_role, Info, solo) of
            follower ->
                Acc;
            _ ->
                Pos = {maps:get(x, Info), maps:get(y, Info)},
                Acc#{Pos => [{Pid, Info} | maps:get(Pos, Acc, [])]}
        end
    end, #{}, Chars).

resolve_cell(_Pos, [_Single], Acc) ->
    Acc;
resolve_cell(_Pos, [{Pid1, _}, {Pid2, _} | _], {AccChars, AccLog}) ->
    case same_party(Pid1, Pid2, AccChars) of
        true ->
            {AccChars, AccLog};
        false ->
            {{ok, I1}, {ok, I2}} = {maps:find(Pid1, AccChars), maps:find(Pid2, AccChars)},
            resolve_pvp(Pid1, I1, Pid2, I2, AccChars, AccLog)
    end.

same_party(Pid1, Pid2, Chars) ->
    follows(Pid1, Pid2, Chars) orelse follows(Pid2, Pid1, Chars).

follows(LeaderPid, MemberPid, Chars) ->
    lists:member(MemberPid, maps:get(follower_pids, maps:get(LeaderPid, Chars), [])).

resolve_pvp(Pid1, I1, Pid2, I2, AccChars, AccLog) ->
    {Winner, _Loser, Dmg} = combat:resolve(I1, I2),
    {WinnerPid, LoserPid, WinnerInfo, LoserInfo, WName, LName} =
        pvp_roles(Pid1, I1, Pid2, I2, Winner),
    pvp_outcome(maps:get(hp, LoserInfo) - Dmg, WinnerPid, LoserPid, WinnerInfo,
                LoserInfo, WName, LName, Dmg, AccChars, AccLog).

pvp_roles(Pid1, I1, Pid2, I2, Winner) ->
    case maps:get(name, Winner) =:= maps:get(name, I1) of
        true ->
            {Pid1, Pid2, I1, I2, maps:get(name, I1), maps:get(name, I2)};
        false ->
            {Pid2, Pid1, I2, I1, maps:get(name, I2), maps:get(name, I1)}
    end.

pvp_outcome(NewLoserHp, WinnerPid, LoserPid, WinnerInfo, LoserInfo,
            WName, LName, _Dmg, AccChars, AccLog) when NewLoserHp =< 0 ->
    XpGain = maps:get(level, LoserInfo),
    W1 = WinnerInfo#{exp := maps:get(exp, WinnerInfo) + XpGain},
    W2 = combat:check_level_up(W1),
    LvlLog = level_log(maps:get(level, WinnerInfo), maps:get(level, W2), WName),
    LRace = maps:get(race, LoserInfo, human),
    schedule_respawn_char(LName, LRace),
    NewChars = disband_party(LoserInfo, maps:remove(LoserPid, AccChars#{WinnerPid := W2})),
    {NewChars,
     AccLog ++ [io_lib:format("~s defeated ~s! [+~pXP]", [WName, LName, XpGain])] ++ LvlLog};
pvp_outcome(NewLoserHp, _WinnerPid, LoserPid, _WinnerInfo, LoserInfo,
            WName, LName, Dmg, AccChars, AccLog) ->
    {AccChars#{LoserPid := LoserInfo#{hp := NewLoserHp}},
     AccLog ++ [io_lib:format("~s clashed with ~s (-~pHP)", [WName, LName, Dmg])]}.

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
