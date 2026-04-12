-module(combat).
-export([resolve/2, resolve_group/2, exp_to_level/1, check_level_up/1,
         roll_survive/2, generate_drop/1, drop_name/1]).

%% XP required to reach the next level
exp_to_level(Level) -> Level * 2 + 1.

%% Roll a survive value for combat — factors in bonuses
roll_survive(Level, Hp) ->
    rand:uniform(Level * 2 + Hp).

%% 1v1 combat resolution.
resolve(A, B) ->
    AtkBonusA = maps:get(attack_bonus, A, 0),
    DefBonusA = maps:get(defense_bonus, A, 0),
    AtkBonusB = maps:get(attack_bonus, B, 0),
    DefBonusB = maps:get(defense_bonus, B, 0),
    RollA = roll_survive(maps:get(level, A), maps:get(hp, A)) + DefBonusA,
    RollB = roll_survive(maps:get(level, B), maps:get(hp, B)) + DefBonusB,
    if
        RollA >= RollB ->
            Dmg = max(1, maps:get(level, A) + AtkBonusA + rand:uniform(3) - DefBonusB),
            NewHpB = maps:get(hp, B) - Dmg,
            {A, B#{hp := NewHpB}, Dmg};
        true ->
            Dmg = max(1, maps:get(level, B) + AtkBonusB + rand:uniform(3) - DefBonusA),
            NewHpA = maps:get(hp, A) - Dmg,
            {B, A#{hp := NewHpA}, Dmg}
    end.

%% Group combat: Party (list of character info maps) vs single opponent.
%% Returns {party_won | party_lost, UpdatedParty, UpdatedOpponent, Dmg, HitIndex}
%% HitIndex is the 1-based index of the party member who takes damage on a loss.
resolve_group(Party, Opponent) when is_list(Party), length(Party) > 0 ->
    %% Each party member rolls; party uses the best roll + combined defense
    TotalDef = lists:sum([maps:get(defense_bonus, M, 0) || M <- Party]),
    TotalAtk = lists:sum([maps:get(attack_bonus, M, 0) || M <- Party]),
    PartyRolls = [roll_survive(maps:get(level, M), maps:get(hp, M)) || M <- Party],
    BestRoll = lists:max(PartyRolls) + TotalDef,
    OppAtk = maps:get(attack_bonus, Opponent, 0),
    OppDef = maps:get(defense_bonus, Opponent, 0),
    OppRoll = roll_survive(maps:get(level, Opponent), maps:get(hp, Opponent)) + OppDef,
    if
        BestRoll >= OppRoll ->
            %% Party wins this round — combined damage
            Dmg = max(1, lists:sum([maps:get(level, M) || M <- Party]) + TotalAtk +
                        rand:uniform(3) - OppDef),
            NewOppHp = maps:get(hp, Opponent) - Dmg,
            {party_won, Party, Opponent#{hp := NewOppHp}, Dmg, 0};
        true ->
            %% Opponent wins — hits a random party member
            Dmg = max(1, maps:get(level, Opponent) + OppAtk + rand:uniform(3) - TotalDef div length(Party)),
            HitIdx = rand:uniform(length(Party)),
            HitMember = lists:nth(HitIdx, Party),
            NewHp = maps:get(hp, HitMember) - Dmg,
            UpdatedMember = HitMember#{hp := NewHp},
            UpdatedParty = list_replace(HitIdx, UpdatedMember, Party),
            {party_lost, UpdatedParty, Opponent, Dmg, HitIdx}
    end;
resolve_group([Single], Opponent) ->
    %% Single member party — delegate to 1v1
    {Winner, Loser, Dmg} = resolve(Single, Opponent),
    case maps:get(name, Winner) =:= maps:get(name, Single) of
        true  -> {party_won, [Winner], Loser, Dmg, 0};
        false -> {party_lost, [Loser], Winner, Dmg, 1}
    end.

list_replace(Idx, Val, List) ->
    {Before, [_Old | After]} = lists:split(Idx - 1, List),
    Before ++ [Val | After].

%% Check if a character should level up; apply level-up if so
check_level_up(Char) ->
    Level = maps:get(level, Char),
    Exp = maps:get(exp, Char),
    Needed = exp_to_level(Level),
    if
        Exp >= Needed ->
            NewLevel = Level + 1,
            Race = maps:get(race, Char, human),
            MaxHp = new_max_hp(NewLevel, Race),
            Char#{level := NewLevel, exp := Exp - Needed,
                  max_hp := MaxHp, hp := MaxHp};
        true ->
            Char
    end.

new_max_hp(Level, Race) ->
    RaceBonuses = util:race_bonuses(Race),
    HpBonus = maps:get(hp_bonus, RaceBonuses, 0),
    Level * 8 + 12 + HpBonus.

%% Generate a random drop based on enemy level
generate_drop(EnemyLevel) ->
    Roll = rand:uniform(100),
    if
        Roll =< 10 ->
            rare_drop(EnemyLevel);
        Roll =< 35 ->
            common_drop(EnemyLevel);
        true ->
            nothing
    end.

rare_drop(EnemyLevel) ->
    Items = [
        {"Enchanted Blade",  {attack, EnemyLevel + 2}},
        {"Dragon Shield",    {defense, EnemyLevel + 2}},
        {"Phoenix Feather",  {hp_restore, EnemyLevel * 3}},
        {"Shadow Cloak",     {evasion, EnemyLevel + 1}},
        {"Thunder Ring",     {attack, EnemyLevel + 3}}
    ],
    lists:nth(rand:uniform(length(Items)), Items).

common_drop(EnemyLevel) ->
    Items = [
        {"Iron Sword",     {attack, max(1, EnemyLevel)}},
        {"Wooden Shield",  {defense, max(1, EnemyLevel)}},
        {"Health Potion",  {hp_restore, EnemyLevel * 2 + 5}},
        {"Leather Armor",  {defense, max(1, EnemyLevel - 1)}},
        {"Steel Dagger",   {attack, max(1, EnemyLevel - 1)}}
    ],
    lists:nth(rand:uniform(length(Items)), Items).

drop_name(nothing) -> none;
drop_name({Name, _Bonus}) -> Name.
