-module(combat).
-export([resolve/2, exp_to_level/1, check_level_up/1, roll_survive/2,
         generate_drop/1, drop_name/1]).

%% XP required to reach the next level
exp_to_level(Level) -> Level * 2.

%% Roll a survive value for combat — higher is better
roll_survive(Level, Hp) ->
    rand:uniform(Level * 2 + Hp).

%% Resolve combat between two combatants.
%% Each combatant is a map: #{level, hp, ...}
%% Returns {Winner, Loser, Damage, Events} where Winner/Loser are updated maps.
resolve(A, B) ->
    RollA = roll_survive(maps:get(level, A), maps:get(hp, A)),
    RollB = roll_survive(maps:get(level, B), maps:get(hp, B)),
    if
        RollA >= RollB ->
            Dmg = max(2, maps:get(level, A) + rand:uniform(3)),
            NewHpB = maps:get(hp, B) - Dmg,
            B2 = B#{hp := NewHpB},
            {A, B2, Dmg};
        true ->
            Dmg = max(2, maps:get(level, B) + rand:uniform(3)),
            NewHpA = maps:get(hp, A) - Dmg,
            A2 = A#{hp := NewHpA},
            {B, A2, Dmg}
    end.

%% Check if a character should level up; apply level-up if so
check_level_up(Char) ->
    Level = maps:get(level, Char),
    Exp = maps:get(exp, Char),
    Needed = exp_to_level(Level),
    if
        Exp >= Needed ->
            NewLevel = Level + 1,
            MaxHp = new_max_hp(NewLevel),
            Char#{level := NewLevel, exp := Exp - Needed,
                  max_hp := MaxHp, hp := MaxHp};
        true ->
            Char
    end.

new_max_hp(Level) -> Level * 5 + 5.

%% Generate a random drop based on enemy level
%% Returns {ItemName, StatBonus} or nothing
generate_drop(EnemyLevel) ->
    Roll = rand:uniform(100),
    if
        Roll =< 10 ->
            %% 10% rare drop
            rare_drop(EnemyLevel);
        Roll =< 35 ->
            %% 25% common drop
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
        {"Health Potion",  {hp_restore, EnemyLevel * 2}},
        {"Leather Armor",  {defense, max(1, EnemyLevel - 1)}},
        {"Steel Dagger",   {attack, max(1, EnemyLevel - 1)}}
    ],
    lists:nth(rand:uniform(length(Items)), Items).

drop_name(nothing) -> none;
drop_name({Name, _Bonus}) -> Name.
