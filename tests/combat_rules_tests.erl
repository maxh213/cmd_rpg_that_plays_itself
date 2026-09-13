-module(combat_rules_tests).
-include_lib("eunit/include/eunit.hrl").

-define(ROLL_10_SEED, 2).
-define(ROLL_35_SEED, 92).
-define(ROLL_50_SEED, 39).

fixed_roller(Overrides) ->
    maps:merge(#{name => "A", level => 1, hp => -1, max_hp => 10,
                 attack_bonus => 0, defense_bonus => 0}, Overrides).

tied_rolls_favour_the_first_fighter_test() ->
    A = fixed_roller(#{name => "A", defense_bonus => 10}),
    B = fixed_roller(#{name => "B", defense_bonus => 10}),
    ?assertEqual({A, B#{hp := -2}, 1}, combat:resolve(A, B)).

second_fighter_damage_subtracts_defence_test() ->
    A = fixed_roller(#{name => "A", defense_bonus => 2}),
    B = fixed_roller(#{name => "B", defense_bonus => 5, attack_bonus => 5}),
    {Winner, Loser, Dmg} = combat:resolve(A, B),
    ?assertEqual(B, Winner),
    ?assert(lists:member(Dmg, [5, 6, 7])),
    ?assertEqual(A#{hp := -1 - Dmg}, Loser).

tied_group_rolls_favour_the_party_test() ->
    Party = [fixed_roller(#{name => "L", defense_bonus => 2, attack_bonus => 5})],
    Opponent = fixed_roller(#{name => "O", defense_bonus => 2}),
    {Result, NewParty, NewOpp, Dmg, HitIdx} = combat:resolve_group(Party, Opponent),
    ?assertEqual({party_won, Party, 0}, {Result, NewParty, HitIdx}),
    ?assert(lists:member(Dmg, [5, 6, 7])),
    ?assertEqual(Opponent#{hp := -1 - Dmg}, NewOpp).

opponent_damage_subtracts_party_guard_test() ->
    [Member] = Party = [fixed_roller(#{name => "L", defense_bonus => 2})],
    Opponent = fixed_roller(#{name => "O", defense_bonus => 5, attack_bonus => 5}),
    {Result, NewParty, NewOpp, Dmg, HitIdx} = combat:resolve_group(Party, Opponent),
    ?assertEqual({party_lost, Opponent, 1}, {Result, NewOpp, HitIdx}),
    ?assert(lists:member(Dmg, [5, 6, 7])),
    ?assertEqual([Member#{hp := -1 - Dmg}], NewParty).

empty_party_cannot_fight_test() ->
    ?assertError(function_clause, combat:resolve_group([], fixed_roller(#{}))).

drop_for_seed(Seed) ->
    rand:seed(exsss, {Seed, 0, 0}),
    combat:generate_drop(3).

roll_of_ten_is_rare_test() ->
    {Name, _} = drop_for_seed(?ROLL_10_SEED),
    ?assert(lists:member(Name, ["Enchanted Blade", "Dragon Shield", "Phoenix Feather",
                                "Shadow Cloak", "Thunder Ring"])).

roll_of_thirty_five_is_common_test() ->
    {Name, _} = drop_for_seed(?ROLL_35_SEED),
    ?assert(lists:member(Name, ["Iron Sword", "Wooden Shield", "Health Potion",
                                "Leather Armor", "Steel Dagger"])).

roll_of_fifty_drops_nothing_test() ->
    ?assertEqual(nothing, drop_for_seed(?ROLL_50_SEED)).
