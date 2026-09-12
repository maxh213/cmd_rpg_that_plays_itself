-module(combat_tests).
-include_lib("eunit/include/eunit.hrl").

exp_to_level_test() ->
    ?assertEqual(3, combat:exp_to_level(1)),
    ?assertEqual(5, combat:exp_to_level(2)),
    ?assertEqual(7, combat:exp_to_level(3)),
    ?assertEqual(21, combat:exp_to_level(10)).

roll_survive_test() ->
    Rolls = [combat:roll_survive(2, 10) || _ <- lists:seq(1, 300)],
    lists:foreach(fun(R) -> ?assert(R >= 1 andalso R =< 14) end, Rolls),
    ?assert(lists:member(1, Rolls)),
    ?assert(lists:member(14, Rolls)).

fighter(Overrides) ->
    maps:merge(#{name => "A", level => 1, hp => 10, max_hp => 10,
                 attack_bonus => 0, defense_bonus => 0}, Overrides).

resolve_first_wins_test() ->
    A = fighter(#{name => "Strong", defense_bonus => 5}),
    B = fighter(#{name => "Weak", hp => 1, level => 1}),
    Results = [combat:resolve(A, B) || _ <- lists:seq(1, 30)],
    lists:foreach(fun({Winner, Loser, Dmg}) ->
        ?assertEqual("Strong", maps:get(name, Winner)),
        ?assertEqual("Weak", maps:get(name, Loser)),
        ?assert(Dmg >= 2 andalso Dmg =< 4),
        ?assertEqual(maps:get(hp, B) - Dmg, maps:get(hp, Loser))
    end, Results).

resolve_second_wins_test() ->
    A = fighter(#{name => "Weak", hp => 1, level => 1}),
    B = fighter(#{name => "Strong", defense_bonus => 5}),
    Results = [combat:resolve(A, B) || _ <- lists:seq(1, 30)],
    lists:foreach(fun({Winner, Loser, Dmg}) ->
        ?assertEqual("Strong", maps:get(name, Winner)),
        ?assertEqual("Weak", maps:get(name, Loser)),
        ?assert(Dmg >= 2 andalso Dmg =< 4),
        ?assertEqual(maps:get(hp, A) - Dmg, maps:get(hp, Loser))
    end, Results).

resolve_group_party_wins_test() ->
    Party = [fighter(#{name => "L", defense_bonus => 5, level => 2}),
             fighter(#{name => "F", defense_bonus => 5, level => 1, hp => 8})],
    Opponent = fighter(#{name => "Opp", hp => 3, level => 1}),
    Results = [combat:resolve_group(Party, Opponent) || _ <- lists:seq(1, 30)],
    lists:foreach(fun({Result, NewParty, NewOpp, Dmg, HitIdx}) ->
        ?assertEqual(party_won, Result),
        ?assertEqual(Party, NewParty),
        ?assertEqual(0, HitIdx),
        ?assert(Dmg >= 4 andalso Dmg =< 6),
        ?assertEqual(3 - Dmg, maps:get(hp, NewOpp))
    end, Results).

resolve_group_party_loses_test() ->
    Party = [fighter(#{name => "L", hp => 30}), fighter(#{name => "F", hp => 30})],
    Opponent = fighter(#{name => "Opp", defense_bonus => 100, attack_bonus => 0, level => 1}),
    {Indexes, _} = lists:unzip(lists:map(fun(_) ->
        {Result, NewParty, NewOpp, Dmg, HitIdx} = combat:resolve_group(Party, Opponent),
        ?assertEqual(party_lost, Result),
        ?assertEqual(Opponent, NewOpp),
        ?assert(Dmg >= 2 andalso Dmg =< 4),
        ?assert(lists:member(HitIdx, [1, 2])),
        HitMember = lists:nth(HitIdx, NewParty),
        ?assertEqual(30 - Dmg, maps:get(hp, HitMember)),
        OtherMember = lists:nth(3 - HitIdx, NewParty),
        ?assertEqual(30, maps:get(hp, OtherMember)),
        {HitIdx, ok}
    end, lists:seq(1, 60))),
    ?assertEqual([1, 2], lists:usort(Indexes)).

resolve_group_single_member_test() ->
    Party = [fighter(#{name => "Solo", defense_bonus => 5})],
    Opponent = fighter(#{name => "Opp", hp => 3}),
    {Result, NewParty, NewOpp, Dmg, HitIdx} = combat:resolve_group(Party, Opponent),
    ?assertEqual(party_won, Result),
    ?assertEqual(Party, NewParty),
    ?assertEqual(0, HitIdx),
    ?assert(Dmg >= 2 andalso Dmg =< 4),
    ?assertEqual(3 - Dmg, maps:get(hp, NewOpp)).

check_level_up_below_threshold_test() ->
    Char = fighter(#{exp => 2, level => 1, hp => 10, max_hp => 23, race => human}),
    ?assertEqual(Char, combat:check_level_up(Char)).

check_level_up_applies_once_test() ->
    Char = fighter(#{exp => 3, level => 1, hp => 5, max_hp => 23, race => human}),
    Leveled = combat:check_level_up(Char),
    ?assertEqual(2, maps:get(level, Leveled)),
    ?assertEqual(0, maps:get(exp, Leveled)),
    ?assertEqual(31, maps:get(max_hp, Leveled)),
    ?assertEqual(31, maps:get(hp, Leveled)).

check_level_up_single_level_per_check_test() ->
    Char = fighter(#{exp => 8, level => 1, race => human}),
    Leveled = combat:check_level_up(Char),
    ?assertEqual(2, maps:get(level, Leveled)),
    ?assertEqual(5, maps:get(exp, Leveled)).

check_level_up_uses_race_hp_test() ->
    Char = fighter(#{exp => 5, level => 2, race => duckman}),
    Leveled = combat:check_level_up(Char),
    ?assertEqual(3, maps:get(level, Leveled)),
    ?assertEqual(0, maps:get(exp, Leveled)),
    ?assertEqual(38, maps:get(max_hp, Leveled)),
    ?assertEqual(38, maps:get(hp, Leveled)).

generate_drop_kinds_test() ->
    Drops = [combat:generate_drop(3) || _ <- lists:seq(1, 400)],
    Kinds = lists:usort([drop_kind(D) || D <- Drops]),
    ?assertEqual([common, nothing, rare], Kinds).

drop_kind(nothing) -> nothing;
drop_kind({Name, _Effect}) ->
    Rare = ["Enchanted Blade", "Dragon Shield", "Phoenix Feather",
            "Shadow Cloak", "Thunder Ring"],
    Common = ["Iron Sword", "Wooden Shield", "Health Potion",
              "Leather Armor", "Steel Dagger"],
    case lists:member(Name, Rare) of
        true -> rare;
        false ->
            ?assert(lists:member(Name, Common)),
            common
    end.

rare_drop_values_test() ->
    Drops = [combat:generate_drop(3) || _ <- lists:seq(1, 400)],
    Rare = [D || D <- Drops, drop_kind(D) =:= rare],
    ?assert(length(Rare) > 0),
    lists:foreach(fun({Name, Effect}) ->
        Expected = #{"Enchanted Blade" => {attack, 5},
                     "Dragon Shield" => {defense, 5},
                     "Phoenix Feather" => {hp_restore, 9},
                     "Shadow Cloak" => {evasion, 4},
                     "Thunder Ring" => {attack, 6}},
        ?assertEqual(maps:get(Name, Expected), Effect)
    end, Rare).

common_drop_values_test() ->
    Drops = [combat:generate_drop(3) || _ <- lists:seq(1, 400)],
    Common = [D || D <- Drops, drop_kind(D) =:= common],
    ?assert(length(Common) > 0),
    lists:foreach(fun({Name, Effect}) ->
        Expected = #{"Iron Sword" => {attack, 3},
                     "Wooden Shield" => {defense, 3},
                     "Health Potion" => {hp_restore, 11},
                     "Leather Armor" => {defense, 2},
                     "Steel Dagger" => {attack, 2}},
        ?assertEqual(maps:get(Name, Expected), Effect)
    end, Common).
