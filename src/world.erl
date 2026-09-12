-module(world).

-export([character_view/2]).
-export([enemy_view/2]).
-export([move/3]).
-export([render_tick/1]).
-export([random_character/0]).
-export([random_enemy/0]).
-export([respawn_character/2]).
-export([respawn_enemy/2]).
-export([shops/1]).
-export([inns/1]).
-export([append_log/2]).
-export_type([world_state / 0, character / 0, enemy / 0, world_view / 0]).
-export_type([character_view / 0, enemy_view / 0, effect / 0, order / 0]).

-define(MAP_SIZE, 40).
-define(MAX_COORD, 39).
-define(PARTY_FORM_TICKS, 3).
-define(LOG_LIMIT, 50).

-type coord() :: non_neg_integer().
-type role() :: solo | leader | follower.
-type item_effect() :: {hp_restore | attack | defense | evasion, integer()}.
-type character() :: #{name := string(),
    race := util:race(),
    level := pos_integer(),
    hp := integer(),
    max_hp := pos_integer(),
    exp := non_neg_integer(),
    x := coord(),
    y := coord(),
    inventory := [string()],
    attack_bonus := integer(),
    defense_bonus := integer(),
    gold := non_neg_integer(),
    party_role := role(),
    party_members := [character()],
    follower_pids := [pid()],
    at_inn := boolean(),
    inn_ticks := non_neg_integer()}.
-type enemy() :: #{name := string(),
    level := pos_integer(),
    hp := integer(),
    max_hp := pos_integer(),
    x := coord(),
    y := coord(),
    type := enemy,
    attack_bonus => integer(),
    defense_bonus => integer()}.
-type place() :: #{name := string(), x := coord(), y := coord()}.
-type characters() :: #{pid() => character()}.
-type enemies() :: #{pid() => enemy()}.
-type log() :: [io_lib:chars()].
-type order() :: {follow, pid()} | {solo}.
-type effect() :: {respawn_char, string(), util:race()}
    | {respawn_enemy, string(), pos_integer()}
    | {tell, pid(), order()}.
-type world_state() :: #{characters := characters(),
    enemies := enemies(),
    shops := [place()],
    inns := [place()],
    event_log := log(),
    move_count := non_neg_integer(),
    display_pid => pid()}.
-type world_view() :: #{enemy_positions := [util:position()],
    shop_positions := [util:position()],
    inn_positions := [util:position()]}.
-type character_view() :: {ok, character(), world_view()} | dead.
-type enemy_view() :: {ok, enemy()} | dead.
-type fight() :: {characters(), enemies(), log(), [effect()]}.
-type clash() :: {characters(), log(), [effect()]}.
-type enemy_ref() :: {pid(), enemy()}.
-type group_result() :: {party_won | party_lost, [character(), ...], enemy(),
    pos_integer(), non_neg_integer()}.
-type hit() :: {pos_integer(), character(), pos_integer()}.
-type roles() :: {pid(), pid(), character(), character(), string(), string()}.
-type drop() :: nothing | {string(), item_effect()}.

-spec character_view(pid(), world_state()) -> character_view().
character_view(Pid, State) ->
    case maps:find(Pid, maps:get(characters, State)) of
        {ok, Info} -> {ok, Info, world_view(State)};
        error -> dead
    end.

-spec enemy_view(pid(), enemies()) -> enemy_view().
enemy_view(Pid, Enemies) ->
    case maps:find(Pid, Enemies) of
        {ok, Info} -> {ok, Info};
        error -> dead
    end.

-spec world_view(world_state()) -> world_view().
world_view(State) ->
    #{enemy_positions => enemy_positions(maps:get(enemies, State)),
        shop_positions => place_positions(maps:get(shops, State)),
        inn_positions => place_positions(maps:get(inns, State))}.

-spec enemy_positions(enemies()) -> [util:position()].
enemy_positions(Enemies) ->
    maps:fold(fun(_EPid, EInfo, Acc) ->
        [{maps:get(x, EInfo), maps:get(y, EInfo)} | Acc]
    end, [], Enemies).

-spec place_positions([place()]) -> [util:position()].
place_positions(Places) ->
    [{maps:get(x, Place), maps:get(y, Place)} || Place <- Places].

-spec move(pid(), util:direction(), world_state()) -> {world_state(), [effect()]}.
move(Pid, Direction, State) ->
    case maps:find(Pid, maps:get(characters, State)) of
        {ok, Info} -> move_character(Pid, Info, Direction, State);
        error -> move_non_character(Pid, Direction, State)
    end.

-spec move_character(pid(), character(), util:direction(), world_state()) ->
    {world_state(), [effect()]}.
move_character(Pid, Info, Direction, State) ->
    case maps:get(party_role, Info, solo) of
        follower -> {State, []};
        _ -> apply_character_move(Pid, Info, Direction, State)
    end.

-spec move_non_character(pid(), util:direction(), world_state()) -> {world_state(), []}.
move_non_character(Pid, Direction, State) ->
    Enemies = maps:get(enemies, State),
    case maps:find(Pid, Enemies) of
        {ok, EInfo} ->
            {NewX, NewY} = apply_direction(Direction, maps:get(x, EInfo), maps:get(y, EInfo)),
            {State#{enemies := Enemies#{Pid := EInfo#{x := NewX, y := NewY}}}, []};
        error ->
            {State, []}
    end.

-spec apply_character_move(pid(), character(), util:direction(), world_state()) ->
    {world_state(), [effect()]}.
apply_character_move(Pid, Info, Direction, State) ->
    #{characters := Chars, enemies := Enemies, shops := Shops,
        inns := Inns, event_log := Log, move_count := MC} = State,
    {NewX, NewY} = apply_direction(Direction, maps:get(x, Info), maps:get(y, Info)),
    NewInfo = Info#{x := NewX, y := NewY},
    NewChars0 = move_followers(Pid, NewX, NewY, Chars#{Pid := NewInfo}),
    {NewChars1, InnLog} = check_inn_interaction(Pid, NewX, NewY, NewChars0, Inns),
    {NewChars2, ShopLog} = check_shop_interaction(Pid, NewX, NewY, NewChars1, Shops),
    {NewChars3, NewEnemies, CombatLog, CombatFx} = check_enemy_collisions(Pid, NewX, NewY,
                                                                            NewChars2, Enemies),
    {NewChars4, PartyLog, PartyFx} = maybe_check_parties(MC, NewChars3, Inns),
    AllLog = InnLog ++ ShopLog ++ CombatLog ++ PartyLog,
    NewLog = append_log(Log, AllLog),
    {State#{characters := NewChars4, enemies := NewEnemies,
            event_log := NewLog, move_count := MC + 1},
        CombatFx ++ PartyFx}.

-spec apply_direction(util:direction(), coord(), coord()) -> util:position().
apply_direction(north, X, Y) -> {X, util:clamp(Y - 1, 0, ?MAX_COORD)};
apply_direction(south, X, Y) -> {X, util:clamp(Y + 1, 0, ?MAX_COORD)};
apply_direction(east, X, Y)  -> {util:clamp(X + 1, 0, ?MAX_COORD), Y};
apply_direction(west, X, Y)  -> {util:clamp(X - 1, 0, ?MAX_COORD), Y};
apply_direction(stay, X, Y)  -> {X, Y}.

-spec append_log(log(), log()) -> log().
append_log(Log, Entries) ->
    NewLog = Log ++ Entries,
    case length(NewLog) > ?LOG_LIMIT of
        true -> lists:nthtail(length(NewLog) - ?LOG_LIMIT, NewLog);
        false -> NewLog
    end.

-spec render_tick(world_state()) -> clash().
render_tick(State) ->
    #{characters := Chars, inns := Inns, event_log := Log} = State,
    InnPositions = place_positions(Inns),
    NewChars = clear_inn_flags(Chars, InnPositions),
    {NewChars2, PvpLog, Effects} = check_pvp_collisions(NewChars),
    {NewChars2, Log ++ PvpLog, Effects}.

-spec random_character() -> {util:race(), character()}.
random_character() ->
    Race = util:random_race(),
    {Race, new_character(util:race_name(Race), Race)}.

-spec random_enemy() -> {pos_integer(), enemy()}.
random_enemy() ->
    {Name, Level} = random_enemy_spec(),
    {Level, new_enemy(Name, Level)}.

-spec respawn_character(string(), util:race()) -> {character(), log()}.
respawn_character(Name, Race) ->
    {new_character(Name, Race), [io_lib:format("~s respawned!", [Name])]}.

-spec respawn_enemy(string(), pos_integer()) -> {enemy(), log()}.
respawn_enemy(Name, Level) ->
    {new_enemy(Name, Level), [io_lib:format("A ~s appeared!", [Name])]}.

-spec new_character(string(), util:race()) -> character().
new_character(Name, Race) ->
    Bonuses = util:race_bonuses(Race),
    BonusHp = maps:get(hp_bonus, Bonuses, 0),
    {X, Y} = util:random_pos(?MAP_SIZE),
    #{name => Name, race => Race, level => 1,
        hp => 20 + BonusHp, max_hp => 20 + BonusHp,
        exp => 0, x => X, y => Y, inventory => [],
        attack_bonus => maps:get(attack_bonus, Bonuses, 0),
        defense_bonus => maps:get(defense_bonus, Bonuses, 0),
        gold => 0, party_role => solo, party_members => [],
        follower_pids => [], at_inn => false, inn_ticks => 0}.

-spec new_enemy(string(), pos_integer()) -> enemy().
new_enemy(Name, Level) ->
    {X, Y} = util:random_pos(?MAP_SIZE),
    MaxHp = Level * 4 + 5,
    #{name => Name, level => Level, hp => MaxHp, max_hp => MaxHp,
        x => X, y => Y, type => enemy}.

-spec random_enemy_spec() -> {string(), pos_integer()}.
random_enemy_spec() ->
    Enemies = [
        {"Goblin", 1}, {"Rat", 1}, {"Slime", 1}, {"Bat", 1},
        {"Wolf", 2}, {"Bandit", 2}, {"Skeleton", 2},
        {"Orc", 3}, {"Zombie", 3}, {"Spider", 3},
        {"Troll", 4}, {"Dark Mage", 4},
        {"Ogre", 5},
        {"Dragon", 6}
    ],
    lists:nth(rand:uniform(length(Enemies)), Enemies).

-spec shops(non_neg_integer()) -> [place()].
shops(Count) ->
    ShopNames = ["Ye Olde Armoury", "Potion Emporium", "Blade Bazaar",
        "Mystic Market", "Shield Shack"],
    PickedNames = lists:sublist(util:shuffle(ShopNames), Count),
    lists:map(fun(SName) ->
        {X, Y} = util:random_pos(?MAP_SIZE),
        #{name => SName, x => X, y => Y}
    end, PickedNames).

-spec inns(non_neg_integer()) -> [place()].
inns(Count) ->
    InnNames = ["The Rusty Flagon", "Hearthstone Rest", "The Wanderer's Respite",
        "The Golden Goose", "Driftwood Tavern"],
    PickedNames = lists:sublist(util:shuffle(InnNames), Count),
    lists:map(fun(IName) ->
        {X, Y} = util:random_pos(?MAP_SIZE),
        #{name => IName, x => X, y => Y}
    end, PickedNames).

-spec check_inn_interaction(pid(), coord(), coord(), characters(), [place()]) ->
    {characters(), log()}.
check_inn_interaction(CharPid, X, Y, Chars, Inns) ->
    case at_any_inn(X, Y, Inns) of
        false -> {Chars, []};
        true -> rest_at_inn(CharPid, Chars)
    end.

-spec at_any_inn(coord(), coord(), [place()]) -> boolean().
at_any_inn(X, Y, Inns) ->
    lists:any(fun(#{x := IX, y := IY}) -> IX =:= X andalso IY =:= Y end, Inns).

-spec rest_at_inn(pid(), characters()) -> {characters(), log()}.
rest_at_inn(CharPid, Chars) ->
    CharInfo = maps:get(CharPid, Chars),
    Hp = maps:get(hp, CharInfo),
    MaxHp = maps:get(max_hp, CharInfo),
    HealAmt = max(3, MaxHp div 5),
    NewHp = min(MaxHp, Hp + HealAmt),
    C1 = CharInfo#{hp := NewHp, at_inn := true,
        inn_ticks := maps:get(inn_ticks, CharInfo, 0) + 1},
    {Chars#{CharPid := C1}, heal_log(maps:get(name, CharInfo), NewHp - Hp)}.

-spec heal_log(string(), integer()) -> log().
heal_log(_Name, 0) -> [];
heal_log(Name, Healed) ->
    [io_lib:format("~s rests at the inn (+~pHP)", [Name, Healed])].

-spec clear_inn_flags(characters(), [util:position()]) -> characters().
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

-spec maybe_check_parties(non_neg_integer(), characters(), [place()]) -> clash().
maybe_check_parties(MC, Chars, Inns) when MC rem 10 =:= 0 ->
    check_party_formation(Chars, Inns);
maybe_check_parties(_MC, Chars, _Inns) ->
    {Chars, [], []}.

-spec check_party_formation(characters(), [place()]) -> clash().
check_party_formation(Chars, Inns) ->
    lists:foldl(fun form_party_at_inn/2, {Chars, [], []}, Inns).

-spec form_party_at_inn(place(), clash()) -> clash().
form_party_at_inn(#{x := IX, y := IY, name := InnName}, {AccChars, AccLog, AccFx}) ->
    case party_candidates(IX, IY, AccChars) of
        [{Pid1, I1}, {Pid2, I2} | _] ->
            form_party(Pid1, I1, Pid2, I2, InnName, AccChars, AccLog, AccFx);
        _ ->
            {AccChars, AccLog, AccFx}
    end.

-spec party_candidates(coord(), coord(), characters()) -> [{pid(), character()}].
party_candidates(IX, IY, Chars) ->
    maps:fold(fun(Pid, Info, Acc) ->
        case party_eligible(Info, IX, IY) of
            true -> [{Pid, Info} | Acc];
            false -> Acc
        end
    end, [], Chars).

-spec party_eligible(character(), coord(), coord()) -> boolean().
party_eligible(Info, IX, IY) ->
    maps:get(party_role, Info, solo) =:= solo
        andalso maps:get(x, Info) =:= IX
        andalso maps:get(y, Info) =:= IY
        andalso maps:get(inn_ticks, Info, 0) >= ?PARTY_FORM_TICKS.

-spec form_party(pid(), character(), pid(), character(), string(), characters(), log(),
                    [effect()]) -> clash().
form_party(Pid1, I1, Pid2, I2, InnName, AccChars, AccLog, AccFx) ->
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
    NewChars = AccChars#{LeaderPid := NewLeader, FollowerPid := NewFollower},
    PartyLog = [io_lib:format("~s and ~s formed a party at ~s!",
        [LName, FName, InnName])],
    {NewChars, AccLog ++ PartyLog, AccFx ++ [{tell, FollowerPid, {follow, LeaderPid}}]}.

-spec pick_leader(pid(), character(), pid(), character()) ->
    {pid(), character(), pid(), character()}.
pick_leader(Pid1, I1, Pid2, I2) ->
    case maps:get(level, I1) >= maps:get(level, I2) of
        true -> {Pid1, I1, Pid2, I2};
        false -> {Pid2, I2, Pid1, I1}
    end.

-spec move_followers(pid(), coord(), coord(), characters()) -> characters().
move_followers(LeaderPid, NewX, NewY, Chars) ->
    LeaderInfo = maps:get(LeaderPid, Chars),
    FollowerPids = maps:get(follower_pids, LeaderInfo, []),
    Chars2 = pin_followers(FollowerPids, NewX, NewY, Chars),
    UpdatedLeader = maps:get(LeaderPid, Chars2),
    Chars2#{LeaderPid := UpdatedLeader#{party_members := live_members(FollowerPids, Chars2)}}.

-spec pin_followers([pid()], coord(), coord(), characters()) -> characters().
pin_followers(FollowerPids, X, Y, Chars) ->
    lists:foldl(fun(FPid, AccChars) ->
        case maps:find(FPid, AccChars) of
            {ok, FInfo} -> AccChars#{FPid := FInfo#{x := X, y := Y}};
            error -> AccChars
        end
    end, Chars, FollowerPids).

-spec live_members([pid()], characters()) -> [character()].
live_members(FollowerPids, Chars) ->
    [FInfo || FPid <- FollowerPids, {ok, FInfo} <- [maps:find(FPid, Chars)]].

-spec disband_party(character(), characters()) -> {characters(), [effect()]}.
disband_party(LeaderInfo, Chars) ->
    FollowerPids = maps:get(follower_pids, LeaderInfo, []),
    lists:foldl(fun release_follower/2, {Chars, []}, FollowerPids).

-spec release_follower(pid(), {characters(), [effect()]}) -> {characters(), [effect()]}.
release_follower(FPid, {AccChars, AccFx}) ->
    case maps:find(FPid, AccChars) of
        {ok, FInfo} ->
            {AccChars#{FPid := FInfo#{party_role := solo, party_members := [],
                    follower_pids := []}},
                AccFx ++ [{tell, FPid, {solo}}]};
        error ->
            {AccChars, AccFx ++ [{tell, FPid, {solo}}]}
    end.

-spec shop_items() -> [{string(), pos_integer(), item_effect()}].
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

-spec check_shop_interaction(pid(), coord(), coord(), characters(), [place()]) ->
    {characters(), log()}.
check_shop_interaction(CharPid, X, Y, Chars, Shops) ->
    case at_any_shop(X, Y, Shops) of
        false -> {Chars, []};
        true -> buy_at_shop(CharPid, Chars)
    end.

-spec at_any_shop(coord(), coord(), [place()]) -> boolean().
at_any_shop(X, Y, Shops) ->
    lists:any(fun(#{x := SX, y := SY}) -> SX =:= X andalso SY =:= Y end, Shops).

-spec buy_at_shop(pid(), characters()) -> {characters(), log()}.
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

-spec pick_shop_purchase(non_neg_integer()) ->
    nothing | {string(), pos_integer(), item_effect()}.
pick_shop_purchase(Gold) ->
    Affordable = [{Name, Cost, Effect} || {Name, Cost, Effect} <- shop_items(), Cost =< Gold],
    case Affordable of
        [] -> nothing;
        _ -> pick_from(Affordable)
    end.

-spec pick_from([{string(), pos_integer(), item_effect()}, ...]) ->
    {string(), pos_integer(), item_effect()}.
pick_from(Affordable) ->
    case rand:uniform(10) of
        N when N =< 4 -> priciest(heals(Affordable));
        _ -> pick_best_stat(Affordable)
    end.

-spec heals([{string(), pos_integer(), item_effect()}]) ->
    [{string(), pos_integer(), item_effect()}].
heals(Items) ->
    [{Na, Co, Ef} || {Na, Co, Ef} <- Items, element(1, Ef) =:= hp_restore].

-spec priciest([{string(), pos_integer(), item_effect()}]) ->
    {string(), pos_integer(), item_effect()}.
priciest(Items) ->
    lists:last(lists:sort(fun({_, C1, _}, {_, C2, _}) -> C1 =< C2 end, Items)).

-spec pick_best_stat([{string(), pos_integer(), item_effect()}, ...]) ->
    {string(), pos_integer(), item_effect()}.
pick_best_stat(Affordable) ->
    Stats = [{Na, Co, Ef} || {Na, Co, Ef} <- Affordable,
        element(1, Ef) =:= attack orelse element(1, Ef) =:= defense],
    case Stats of
        [] -> priciest(Affordable);
        _ -> priciest(Stats)
    end.

-spec check_enemy_collisions(pid(), coord(), coord(), characters(), enemies()) -> fight().
check_enemy_collisions(CharPid, X, Y, Chars, Enemies) ->
    EnemiesAtPos = maps:filter(fun(_EPid, EInfo) ->
        maps:get(x, EInfo) =:= X andalso maps:get(y, EInfo) =:= Y
    end, Enemies),
    maps:fold(fun(EPid, EInfo, Acc) ->
        fight_at_cell(CharPid, {EPid, EInfo}, Acc)
    end, {Chars, Enemies, [], []}, EnemiesAtPos).

-spec fight_at_cell(pid(), enemy_ref(), fight()) -> fight().
fight_at_cell(CharPid, Enemy, {AccChars, _, _, _} = Acc) ->
    case maps:find(CharPid, AccChars) of
        {ok, CharInfo} ->
            engage_enemy(CharPid, CharInfo, Enemy, Acc);
        error ->
            Acc
    end.

-spec engage_enemy(pid(), character(), enemy_ref(), fight()) -> fight().
engage_enemy(CharPid, CharInfo, Enemy, {AccChars, _, _, _} = Acc) ->
    case maps:get(party_role, CharInfo, solo) =:= leader of
        true ->
            FollowerPids = maps:get(follower_pids, CharInfo, []),
            LiveMembers = live_members(FollowerPids, AccChars),
            resolve_group_enemy(CharPid, [CharInfo | LiveMembers], Enemy, Acc);
        false ->
            resolve_solo_enemy(CharPid, CharInfo, Enemy, Acc)
    end.

-spec resolve_solo_enemy(pid(), character(), enemy_ref(), fight()) -> fight().
resolve_solo_enemy(CharPid, CharInfo, {_EPid, EInfo} = Enemy, Acc) ->
    {Winner, _Loser, Dmg} = combat:resolve(CharInfo, EInfo),
    case maps:get(name, Winner) =:= maps:get(name, CharInfo) of
        true ->
            solo_victory(CharPid, CharInfo, Enemy, Dmg, Acc);
        false ->
            solo_defeat(CharPid, CharInfo, EInfo, Dmg, Acc)
    end.

-spec solo_victory(pid(), character(), enemy_ref(), pos_integer(), fight()) -> fight().
solo_victory(CharPid, CharInfo, {EPid, EInfo} = Enemy, Dmg, Acc) ->
    {AccChars, AccEnemies, AccLog, AccFx} = Acc,
    NewEHp = maps:get(hp, EInfo) - Dmg,
    case NewEHp =< 0 of
        true ->
            enemy_slain(CharPid, CharInfo, Enemy, Acc);
        false ->
            {AccChars, AccEnemies#{EPid := EInfo#{hp := NewEHp}},
                AccLog ++ [io_lib:format("~s hit ~s (-~pHP)",
                    [maps:get(name, CharInfo), maps:get(name, EInfo), Dmg])],
                AccFx}
    end.

-spec enemy_slain(pid(), character(), enemy_ref(), fight()) -> fight().
enemy_slain(CharPid, CharInfo, {EPid, EInfo}, {AccChars, AccEnemies, AccLog, AccFx}) ->
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
    {AccChars#{CharPid := C3}, maps:remove(EPid, AccEnemies),
        AccLog ++ KillLog ++ LvlLog ++ DropLog,
        AccFx ++ [{respawn_enemy, EName, ELevel}]}.

-spec level_log(pos_integer(), pos_integer(), string()) -> log().
level_log(OldLevel, NewLevel, Name) ->
    case NewLevel > OldLevel of
        true -> [io_lib:format("~s leveled up to Lv~p!", [Name, NewLevel])];
        false -> []
    end.

-spec solo_defeat(pid(), character(), enemy(), pos_integer(), fight()) -> fight().
solo_defeat(CharPid, CharInfo, EInfo, Dmg, {AccChars, AccEnemies, AccLog, AccFx} = Acc) ->
    NewCHp = maps:get(hp, CharInfo) - Dmg,
    case NewCHp =< 0 of
        true ->
            character_mauled(CharPid, CharInfo, EInfo, Acc);
        false ->
            {AccChars#{CharPid := CharInfo#{hp := NewCHp}}, AccEnemies,
                AccLog ++ [io_lib:format("~s hit by ~s (-~pHP)",
                    [maps:get(name, CharInfo), maps:get(name, EInfo), Dmg])],
                AccFx}
    end.

-spec character_mauled(pid(), character(), enemy(), fight()) -> fight().
character_mauled(CharPid, CharInfo, EInfo, {AccChars, AccEnemies, AccLog, AccFx}) ->
    CName = maps:get(name, CharInfo),
    Race = maps:get(race, CharInfo, human),
    {NewChars, DisbandFx} = disband_party(CharInfo, maps:remove(CharPid, AccChars)),
    {NewChars, AccEnemies,
        AccLog ++ [io_lib:format("~s was mauled by ~s!", [CName, maps:get(name, EInfo)])],
        AccFx ++ [{respawn_char, CName, Race}] ++ DisbandFx}.

-spec resolve_group_enemy(pid(), [character(), ...], enemy_ref(), fight()) -> fight().
resolve_group_enemy(CharPid, FullParty, {_EPid, EInfo} = Enemy, Acc) ->
    Result = combat:resolve_group(FullParty, EInfo),
    group_outcome(Result, CharPid, FullParty, Enemy, Acc).

-spec group_outcome(group_result(), pid(), [character(), ...], enemy_ref(), fight()) -> fight().
group_outcome({party_won, UpdatedParty, UpdatedEnemy, Dmg, _HitIdx}, CharPid, _FullParty,
                Enemy, Acc) ->
    case maps:get(hp, UpdatedEnemy) =< 0 of
        true ->
            party_slays_enemy(CharPid, UpdatedParty, Enemy, Acc);
        false ->
            party_hits_enemy(CharPid, UpdatedParty, {UpdatedEnemy, Dmg}, Enemy, Acc)
    end;
group_outcome({party_lost, UpdatedParty, _UpdatedEnemy, Dmg, HitIdx}, CharPid, FullParty,
                {_EPid, EInfo}, Acc) ->
    HitMember = lists:nth(HitIdx, UpdatedParty),
    member_hit_outcome(maps:get(hp, HitMember), {HitIdx, HitMember, Dmg}, CharPid,
        {FullParty, UpdatedParty}, EInfo, Acc).

-spec party_slays_enemy(pid(), [character(), ...], enemy_ref(), fight()) -> fight().
party_slays_enemy(CharPid, UpdatedParty, {EPid, EInfo}, {AccChars, AccEnemies, AccLog, AccFx}) ->
    LeaderName = maps:get(name, hd(UpdatedParty)),
    EName = maps:get(name, EInfo),
    ELevel = maps:get(level, EInfo),
    XpGain = ELevel + 1,
    GoldGain = ELevel * 2 + rand:uniform(3),
    {Leader3, UpdatedMembers, DropLog} = share_spoils(UpdatedParty, XpGain, GoldGain, ELevel),
    KillLog = [io_lib:format("~s's party slew ~s(Lv~p) [+~pXP +~pg]",
        [LeaderName, EName, ELevel, XpGain, GoldGain])],
    NewLeader = Leader3#{party_members := UpdatedMembers},
    FollowerPids = maps:get(follower_pids, NewLeader, []),
    NewChars = update_follower_infos(FollowerPids, UpdatedMembers,
        AccChars#{CharPid := NewLeader}),
    {NewChars, maps:remove(EPid, AccEnemies),
        AccLog ++ KillLog ++ DropLog,
        AccFx ++ [{respawn_enemy, EName, ELevel}]}.

-spec share_spoils([character(), ...], pos_integer(), pos_integer(), pos_integer()) ->
    {character(), [character()], log()}.
share_spoils([Leader0 | Members], XpGain, GoldGain, ELevel) ->
    Leader1 = Leader0#{exp := maps:get(exp, Leader0) + XpGain,
        gold := maps:get(gold, Leader0, 0) + GoldGain},
    Leader2 = combat:check_level_up(Leader1),
    UpdatedMembers = [combat:check_level_up(M#{exp := maps:get(exp, M) + XpGain})
        || M <- Members],
    {Leader3, DropLog} = apply_drop(Leader2, combat:generate_drop(ELevel)),
    {Leader3, UpdatedMembers, DropLog}.

-spec party_hits_enemy(pid(), [character(), ...], {enemy(), pos_integer()}, enemy_ref(),
                        fight()) -> fight().
party_hits_enemy(CharPid, UpdatedParty, {UpdatedEnemy, Dmg}, {EPid, EInfo},
                    {AccChars, AccEnemies, AccLog, AccFx}) ->
    LeaderName = maps:get(name, hd(UpdatedParty)),
    EName = maps:get(name, EInfo),
    Leader0 = hd(UpdatedParty),
    NewLeader = Leader0#{party_members := tl(UpdatedParty)},
    {AccChars#{CharPid := NewLeader},
        AccEnemies#{EPid := UpdatedEnemy},
        AccLog ++ [io_lib:format("~s's party hit ~s (-~pHP)", [LeaderName, EName, Dmg])],
        AccFx}.

-spec member_hit_outcome(integer(), hit(), pid(), {[character(), ...], [character(), ...]},
                            enemy(), fight()) -> fight().
member_hit_outcome(Hp, {1, HitMember, _Dmg}, CharPid, {FullParty, _UpdatedParty},
                    EInfo, {AccChars, AccEnemies, AccLog, AccFx}) when Hp =< 0 ->
    Race = maps:get(race, hd(FullParty), human),
    {NewChars, DisbandFx} = disband_party(hd(FullParty), maps:remove(CharPid, AccChars)),
    {NewChars, AccEnemies,
        AccLog ++ [io_lib:format("~s was slain by ~s! Party disbanded!",
            [maps:get(name, HitMember), maps:get(name, EInfo)])],
        AccFx ++ [{respawn_char, maps:get(name, hd(FullParty)), Race}] ++ DisbandFx};
member_hit_outcome(Hp, {HitIdx, HitMember, _Dmg}, CharPid, {_FullParty, UpdatedParty},
                    EInfo, {AccChars, AccEnemies, AccLog, AccFx}) when Hp =< 0 ->
    HitName = maps:get(name, HitMember),
    FollowerPids = maps:get(follower_pids, hd(UpdatedParty), []),
    DeadFPid = lists:nth(HitIdx - 1, FollowerPids),
    DeadFRace = maps:get(race, HitMember, human),
    NewFollowerPids = lists:delete(DeadFPid, FollowerPids),
    NewMembers = lists:delete(HitMember, tl(UpdatedParty)),
    Leader0 = hd(UpdatedParty),
    NewLeader = Leader0#{party_role := member_role(NewMembers),
        party_members := NewMembers,
        follower_pids := NewFollowerPids},
    NewChars = maps:remove(DeadFPid, AccChars#{CharPid := NewLeader}),
    {NewChars, AccEnemies,
        AccLog ++ [io_lib:format("~s was slain by ~s!", [HitName, maps:get(name, EInfo)])],
        AccFx ++ [{respawn_char, HitName, DeadFRace}]};
member_hit_outcome(_Hp, {HitIdx, HitMember, Dmg}, CharPid, {_FullParty, UpdatedParty},
                    EInfo, {AccChars, AccEnemies, AccLog, AccFx}) ->
    Leader0 = hd(UpdatedParty),
    NewLeader = Leader0#{party_members := tl(UpdatedParty)},
    NewChars = sync_hit_member(HitIdx, NewLeader, tl(UpdatedParty), CharPid, AccChars),
    {NewChars, AccEnemies,
        AccLog ++ [io_lib:format("~s hit by ~s (-~pHP)",
            [maps:get(name, HitMember), maps:get(name, EInfo), Dmg])],
        AccFx}.

-spec member_role([character()]) -> role().
member_role([]) -> solo;
member_role(_Members) -> leader.

-spec sync_hit_member(pos_integer(), character(), [character()], pid(), characters()) ->
    characters().
sync_hit_member(1, NewLeader, _Members, CharPid, AccChars) ->
    AccChars#{CharPid := NewLeader};
sync_hit_member(_HitIdx, NewLeader, Members, CharPid, AccChars) ->
    FollowerPids = maps:get(follower_pids, NewLeader, []),
    update_follower_infos(FollowerPids, Members, AccChars#{CharPid := NewLeader}).

-spec update_follower_infos([pid()], [character()], characters()) -> characters().
update_follower_infos(FollowerPids, MemberInfos, Chars) ->
    Pairs = lists:zip(FollowerPids, MemberInfos, trim),
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

-spec check_pvp_collisions(characters()) -> clash().
check_pvp_collisions(Chars) ->
    ByPos = group_by_position(Chars),
    maps:fold(fun resolve_cell/3, {Chars, [], []}, ByPos).

-spec group_by_position(characters()) -> #{util:position() => [{pid(), character()}, ...]}.
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

-spec resolve_cell(util:position(), [{pid(), character()}, ...], clash()) -> clash().
resolve_cell(_Pos, [_Single], Acc) ->
    Acc;
resolve_cell(_Pos, [{Pid1, _}, {Pid2, _} | _], {AccChars, _, _} = Acc) ->
    case same_party(Pid1, Pid2, AccChars) of
        true ->
            Acc;
        false ->
            {{ok, I1}, {ok, I2}} = {maps:find(Pid1, AccChars), maps:find(Pid2, AccChars)},
            resolve_pvp({Pid1, I1}, {Pid2, I2}, Acc)
    end.

-spec same_party(pid(), pid(), characters()) -> boolean().
same_party(Pid1, Pid2, Chars) ->
    follows(Pid1, Pid2, Chars) orelse follows(Pid2, Pid1, Chars).

-spec follows(pid(), pid(), characters()) -> boolean().
follows(LeaderPid, MemberPid, Chars) ->
    lists:member(MemberPid, maps:get(follower_pids, maps:get(LeaderPid, Chars), [])).

-spec resolve_pvp({pid(), character()}, {pid(), character()}, clash()) -> clash().
resolve_pvp({Pid1, I1}, {Pid2, I2}, Acc) ->
    {Winner, _Loser, Dmg} = combat:resolve(I1, I2),
    {_, _, _, LoserInfo, _, _} = Roles = pvp_roles(Pid1, I1, Pid2, I2, Winner),
    pvp_outcome(maps:get(hp, LoserInfo) - Dmg, Roles, Dmg, Acc).

-spec pvp_roles(pid(), character(), pid(), character(), character()) -> roles().
pvp_roles(Pid1, I1, Pid2, I2, Winner) ->
    case maps:get(name, Winner) =:= maps:get(name, I1) of
        true ->
            {Pid1, Pid2, I1, I2, maps:get(name, I1), maps:get(name, I2)};
        false ->
            {Pid2, Pid1, I2, I1, maps:get(name, I2), maps:get(name, I1)}
    end.

-spec pvp_outcome(integer(), roles(), pos_integer(), clash()) -> clash().
pvp_outcome(NewLoserHp, {WinnerPid, LoserPid, WinnerInfo, LoserInfo, WName, LName}, _Dmg,
            {AccChars, AccLog, AccFx}) when NewLoserHp =< 0 ->
    XpGain = maps:get(level, LoserInfo),
    W1 = WinnerInfo#{exp := maps:get(exp, WinnerInfo) + XpGain},
    W2 = combat:check_level_up(W1),
    LvlLog = level_log(maps:get(level, WinnerInfo), maps:get(level, W2), WName),
    LRace = maps:get(race, LoserInfo, human),
    Survivors = maps:remove(LoserPid, AccChars#{WinnerPid := W2}),
    {NewChars, DisbandFx} = disband_party(LoserInfo, Survivors),
    {NewChars,
        AccLog ++ [io_lib:format("~s defeated ~s! [+~pXP]", [WName, LName, XpGain])] ++ LvlLog,
        AccFx ++ [{respawn_char, LName, LRace}] ++ DisbandFx};
pvp_outcome(NewLoserHp, {_WinnerPid, LoserPid, _WinnerInfo, LoserInfo, WName, LName}, Dmg,
            {AccChars, AccLog, AccFx}) ->
    {AccChars#{LoserPid := LoserInfo#{hp := NewLoserHp}},
        AccLog ++ [io_lib:format("~s clashed with ~s (-~pHP)", [WName, LName, Dmg])],
        AccFx}.

-spec apply_drop(character(), drop()) -> {character(), log()}.
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
