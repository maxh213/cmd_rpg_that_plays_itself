-module(character_rules_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TOWARD_SEED, 11).
-define(CHANCE_SEVEN_SEED, 8).
-define(TIE_EAST_SEED, 10).
-define(TIE_SOUTH_SEED, 5).

first_move(Seed, Overrides, View) ->
    Info = test_support:char_info(maps:merge(#{hp => 20, max_hp => 20}, Overrides)),
    WorldView = maps:merge(#{enemy_positions => [], shop_positions => [], inn_positions => []}, View),
    GetState = fun(_) ->
        rand:seed(exsss, {Seed, 0, 0}),
        {ok, Info, WorldView}
    end,
    Pid = character:start(human, 1, GetState, test_support:move_recorder(self())),
    Direction = receive {moved, Pid, D} -> D after 2000 -> timeout end,
    test_support:kill(Pid),
    test_support:flush_mailbox(),
    Direction.

inn_west_enemy_east() ->
    #{inn_positions => [{2, 5}], shop_positions => [{2, 5}], enemy_positions => [{8, 5}]}.

hp_is_low_only_when_double_is_below_max_test() ->
    ?assertEqual(east, first_move(?TOWARD_SEED, #{hp => 10, max_hp => 15}, inn_west_enemy_east())),
    ?assertEqual(east, first_move(?TOWARD_SEED, #{hp => 10, max_hp => 20}, inn_west_enemy_east())),
    ?assertEqual(west, first_move(?TOWARD_SEED, #{hp => 9, max_hp => 20}, inn_west_enemy_east())).

leader_with_gold_still_hunts_test() ->
    Leader = #{party_role => leader, gold => 20},
    ?assertEqual(east, first_move(?TOWARD_SEED, Leader, inn_west_enemy_east())).

fifteen_gold_goes_shopping_test() ->
    ?assertEqual(west, first_move(?TOWARD_SEED, #{gold => 15}, inn_west_enemy_east())),
    ?assertEqual(east, first_move(?TOWARD_SEED, #{gold => 14}, inn_west_enemy_east())).

roll_equal_to_chance_moves_toward_target_test() ->
    ?assertEqual(east, first_move(?CHANCE_SEVEN_SEED, #{}, inn_west_enemy_east())).

nearest_enemy_by_manhattan_distance_test() ->
    Horizontal = #{enemy_positions => [{6, 5}, {2, 5}, {5, 8}]},
    ?assertEqual(east, first_move(?TOWARD_SEED, #{}, Horizontal)),
    Vertical = #{enemy_positions => [{5, 6}, {9, 0}]},
    ?assertEqual(south, first_move(?TOWARD_SEED, #{}, Vertical)).

diagonal_tie_steps_either_way_by_roll_test() ->
    Diagonal = #{enemy_positions => [{8, 8}]},
    ?assertEqual(east, first_move(?TIE_EAST_SEED, #{}, Diagonal)),
    ?assertEqual(south, first_move(?TIE_SOUTH_SEED, #{}, Diagonal)).

steps_toward_distant_targets_test() ->
    ?assertEqual(south, first_move(?TOWARD_SEED, #{}, #{enemy_positions => [{5, 8}]})),
    ?assertEqual(north, first_move(?TOWARD_SEED, #{}, #{enemy_positions => [{5, 2}]})),
    ?assertEqual(west, first_move(?TOWARD_SEED, #{}, #{enemy_positions => [{2, 5}]})).
