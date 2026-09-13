-module(combat).
-export([resolve/2]).
-export([resolve_group/2]).
-export([exp_to_level/1]).
-export([check_level_up/1]).
-export([roll_survive/2]).
-export([generate_drop/1]).

-type fighter() :: #{level := pos_integer(),
                        hp := integer(),
                        attack_bonus => integer(),
                        defense_bonus => integer(),
                        atom() => term()}.
-type hero() :: #{level := pos_integer(),
                    exp := non_neg_integer(),
                    max_hp := pos_integer(),
                    hp := integer(),
                    race => util:race(),
                    atom() => term()}.
-type effect() :: {hp_restore | attack | defense | evasion, integer()}.
-type drop() :: nothing | {string(), effect()}.
-type group_result() :: {party_won | party_lost, [fighter(), ...], fighter(),
                            pos_integer(), non_neg_integer()}.

-spec exp_to_level(non_neg_integer()) -> pos_integer().
exp_to_level(Level) -> Level * 2 + 1.

-spec roll_survive(pos_integer(), integer()) -> pos_integer().
roll_survive(Level, Hp) ->
    rand:uniform(Level * 2 + Hp).

-spec resolve(fighter(), fighter()) -> {fighter(), fighter(), pos_integer()}.
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

-spec resolve_group([fighter(), ...], fighter()) -> group_result().
resolve_group([_ | _] = Party, Opponent) ->
    TotalDef = lists:sum([maps:get(defense_bonus, M, 0) || M <- Party]),
    TotalAtk = lists:sum([maps:get(attack_bonus, M, 0) || M <- Party]),
    PartyRolls = [roll_survive(maps:get(level, M), maps:get(hp, M)) || M <- Party],
    BestRoll = lists:max(PartyRolls) + TotalDef,
    OppDef = maps:get(defense_bonus, Opponent, 0),
    OppRoll = roll_survive(maps:get(level, Opponent), maps:get(hp, Opponent)) + OppDef,
    if
        BestRoll >= OppRoll ->
            party_strikes(Party, Opponent, TotalAtk, OppDef);
        true ->
            opponent_strikes(Party, Opponent, TotalDef)
    end.

-spec party_strikes([fighter(), ...], fighter(), integer(), integer()) -> group_result().
party_strikes(Party, Opponent, TotalAtk, OppDef) ->
    Levels = lists:sum([maps:get(level, M) || M <- Party]),
    Dmg = max(1, Levels + TotalAtk + rand:uniform(3) - OppDef),
    NewOppHp = maps:get(hp, Opponent) - Dmg,
    {party_won, Party, Opponent#{hp := NewOppHp}, Dmg, 0}.

-spec opponent_strikes([fighter(), ...], fighter(), integer()) -> group_result().
opponent_strikes(Party, Opponent, TotalDef) ->
    OppAtk = maps:get(attack_bonus, Opponent, 0),
    Guard = TotalDef div length(Party),
    Dmg = max(1, maps:get(level, Opponent) + OppAtk + rand:uniform(3) - Guard),
    HitIdx = rand:uniform(length(Party)),
    HitMember = lists:nth(HitIdx, Party),
    NewHp = maps:get(hp, HitMember) - Dmg,
    UpdatedMember = HitMember#{hp := NewHp},
    UpdatedParty = list_replace(HitIdx, UpdatedMember, Party),
    {party_lost, UpdatedParty, Opponent, Dmg, HitIdx}.

-spec list_replace(pos_integer(), T, [T, ...]) -> [T, ...].
list_replace(Idx, Val, List) ->
    {Before, [_Old | After]} = lists:split(Idx - 1, List),
    Before ++ [Val | After].

-spec check_level_up(hero()) -> hero().
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

-spec new_max_hp(pos_integer(), util:race()) -> pos_integer().
new_max_hp(Level, Race) ->
    RaceBonuses = util:race_bonuses(Race),
    HpBonus = maps:get(hp_bonus, RaceBonuses, 0),
    Level * 8 + 12 + HpBonus.

-spec generate_drop(pos_integer()) -> drop().
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

-spec rare_drop(pos_integer()) -> drop().
rare_drop(EnemyLevel) ->
    Items = [
        {"Enchanted Blade",  {attack, EnemyLevel + 2}},
        {"Dragon Shield",    {defense, EnemyLevel + 2}},
        {"Phoenix Feather",  {hp_restore, EnemyLevel * 3}},
        {"Shadow Cloak",     {evasion, EnemyLevel + 1}},
        {"Thunder Ring",     {attack, EnemyLevel + 3}}
    ],
    lists:nth(rand:uniform(length(Items)), Items).

-spec common_drop(pos_integer()) -> drop().
common_drop(EnemyLevel) ->
    Items = [
        {"Iron Sword",     {attack, max(1, EnemyLevel)}},
        {"Wooden Shield",  {defense, max(1, EnemyLevel)}},
        {"Health Potion",  {hp_restore, EnemyLevel * 2 + 5}},
        {"Leather Armor",  {defense, max(1, EnemyLevel - 1)}},
        {"Steel Dagger",   {attack, max(1, EnemyLevel - 1)}}
    ],
    lists:nth(rand:uniform(length(Items)), Items).
