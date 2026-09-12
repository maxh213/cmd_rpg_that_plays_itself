-module(character_tests).
-include_lib("eunit/include/eunit.hrl").

view(Enemies, Shops, Inns) ->
    #{enemy_positions => Enemies, shop_positions => Shops, inn_positions => Inns}.

run_decider(MyInfo, WorldView, Ms) ->
    GetState = test_support:const_state({ok, MyInfo, WorldView}),
    Move = test_support:move_recorder(self()),
    Pid = character:start(human, 1, GetState, Move),
    Moves = test_support:collect_moves(Ms),
    test_support:kill(Pid),
    Moves.

count(Dir, Moves) ->
    length([D || D <- Moves, D =:= Dir]).

dead_state_stops_process_test() ->
    GetState = test_support:const_state(dead),
    Move = test_support:move_recorder(self()),
    Pid = character:start(human, 1, GetState, Move),
    timer:sleep(100),
    ?assertNot(is_process_alive(Pid)).

undefined_state_retries_test() ->
    GetState = test_support:scripted_states([undefined, undefined, dead]),
    Move = test_support:move_recorder(self()),
    Pid = character:start(human, 1, GetState, Move),
    timer:sleep(500),
    ?assertNot(is_process_alive(Pid)).

resting_hero_stays_put_test() ->
    Info = test_support:char_info(#{at_inn => true, hp => 10, max_hp => 40}),
    Moves = run_decider(Info, view([], [], []), 60),
    ?assert(length(Moves) > 5),
    ?assertEqual([stay], lists:usort(Moves)).

healed_hero_leaves_inn_test() ->
    Info = test_support:char_info(#{at_inn => true, hp => 39, max_hp => 40, gold => 0}),
    Moves = run_decider(Info, view([{8, 5}], [], []), 80),
    ?assert(length(Moves) > 5),
    ?assert(count(east, Moves) > length(Moves) div 2).

hero_below_three_quarters_hp_stays_at_inn_test() ->
    Info = test_support:char_info(#{at_inn => true, hp => 29, max_hp => 40, gold => 0}),
    Moves = run_decider(Info, view([{8, 5}], [], []), 80),
    ?assert(length(Moves) > 5),
    ?assertEqual([stay], lists:usort(Moves)).

hero_at_three_quarters_hp_leaves_inn_test() ->
    Info = test_support:char_info(#{at_inn => true, hp => 30, max_hp => 40, gold => 0}),
    Moves = run_decider(Info, view([{8, 5}], [], []), 80),
    ?assert(length(Moves) > 5),
    ?assert(count(east, Moves) > length(Moves) div 2).

hurt_rich_hero_seeks_shop_test() ->
    Info = test_support:char_info(#{hp => 10, max_hp => 40, gold => 10}),
    Moves = run_decider(Info, view([{20, 20}], [{8, 5}], []), 80),
    ?assert(length(Moves) > 5),
    ?assert(count(east, Moves) > length(Moves) div 2).

hurt_poor_hero_seeks_inn_test() ->
    Info = test_support:char_info(#{hp => 10, max_hp => 40, gold => 0}),
    Moves = run_decider(Info, view([{20, 20}], [], [{5, 2}]), 80),
    ?assert(length(Moves) > 5),
    ?assert(count(north, Moves) > length(Moves) div 2).

hurt_hero_with_five_gold_seeks_shop_test() ->
    Info = test_support:char_info(#{hp => 10, max_hp => 40, gold => 5}),
    Moves = run_decider(Info, view([{20, 20}], [{8, 5}], [{2, 5}]), 80),
    ?assert(length(Moves) > 5),
    ?assert(count(east, Moves) > length(Moves) div 2).

hurt_hero_with_four_gold_seeks_inn_test() ->
    Info = test_support:char_info(#{hp => 10, max_hp => 40, gold => 4}),
    Moves = run_decider(Info, view([{20, 20}], [{8, 5}], [{2, 5}]), 80),
    ?assert(length(Moves) > 5),
    ?assert(count(west, Moves) > length(Moves) div 2).

leader_hunts_enemy_test() ->
    Info = test_support:char_info(#{hp => 40, max_hp => 40, gold => 0,
                                    party_role => leader}),
    Moves = run_decider(Info, view([{2, 5}], [], []), 80),
    ?assert(length(Moves) > 5),
    ?assert(count(west, Moves) > length(Moves) div 2).

rich_solo_seeks_shop_test() ->
    Info = test_support:char_info(#{hp => 40, max_hp => 40, gold => 15}),
    Moves = run_decider(Info, view([{20, 20}], [{5, 8}], []), 100),
    ?assert(length(Moves) > 5),
    ?assert(count(south, Moves) > length(Moves) div 3).

poor_solo_hunts_enemy_test() ->
    Info = test_support:char_info(#{hp => 40, max_hp => 40, gold => 0}),
    Moves = run_decider(Info, view([{8, 8}], [], []), 100),
    ?assert(length(Moves) > 5),
    ?assert(count(east, Moves) > 0),
    ?assert(count(south, Moves) > 0).

missing_shop_falls_back_to_enemy_test() ->
    Info = test_support:char_info(#{hp => 10, max_hp => 40, gold => 10}),
    Moves = run_decider(Info, view([{5, 8}], [], []), 80),
    ?assert(length(Moves) > 5),
    ?assert(count(south, Moves) > length(Moves) div 2).

no_enemies_wanders_randomly_test() ->
    Info = test_support:char_info(#{hp => 40, max_hp => 40, gold => 0}),
    Moves = run_decider(Info, view([], [], []), 80),
    ?assert(length(Moves) > 5),
    Expected = [north, south, east, west, stay],
    lists:foreach(fun(D) -> ?assert(lists:member(D, Expected)) end, Moves),
    ?assert(length(lists:usort(Moves)) >= 2).

enemy_on_same_cell_stays_test() ->
    Info = test_support:char_info(#{hp => 40, max_hp => 40, gold => 0}),
    Moves = run_decider(Info, view([{5, 5}], [], []), 100),
    ?assert(length(Moves) > 5),
    ?assert(lists:member(stay, Moves)).

tie_break_covers_both_axes_test() ->
    Info = test_support:char_info(#{hp => 40, max_hp => 40, gold => 0}),
    Moves = run_decider(Info, view([{4, 6}], [], []), 100),
    ?assert(length(Moves) > 5),
    ?assert(count(west, Moves) > 0),
    ?assert(count(south, Moves) > 0).

follower_stays_idle_until_die_test() ->
    Info = test_support:char_info(#{party_role => follower}),
    GetState = test_support:const_state({ok, Info, view([], [], [])}),
    Move = test_support:move_recorder(self()),
    Pid = character:start(human, 1, GetState, Move),
    Moves = test_support:collect_moves(60),
    ?assertEqual([], Moves),
    ?assert(is_process_alive(Pid)),
    Pid ! die,
    timer:sleep(50),
    ?assertNot(is_process_alive(Pid)).

follower_accepts_solo_message_test() ->
    Info = test_support:char_info(#{party_role => follower}),
    GetState = test_support:const_state({ok, Info, view([], [], [])}),
    Move = test_support:move_recorder(self()),
    Pid = character:start(human, 1, GetState, Move),
    timer:sleep(40),
    Pid ! {solo},
    timer:sleep(40),
    ?assert(is_process_alive(Pid)),
    test_support:kill(Pid).

follower_stops_when_world_says_dead_test() ->
    Follower = {ok, test_support:char_info(#{party_role => follower}), view([], [], [])},
    GetState = test_support:scripted_states([Follower, Follower, dead]),
    Move = test_support:move_recorder(self()),
    Pid = character:start(human, 1, GetState, Move),
    ?assert(test_support:eventually(fun() -> not is_process_alive(Pid) end, 40)).

follower_stops_when_world_undefined_test() ->
    Follower = {ok, test_support:char_info(#{party_role => follower}), view([], [], [])},
    GetState = test_support:scripted_states([Follower, undefined]),
    Move = test_support:move_recorder(self()),
    Pid = character:start(human, 1, GetState, Move),
    ?assert(test_support:eventually(fun() -> not is_process_alive(Pid) end, 40)).

follower_resumes_when_world_releases_test() ->
    FollowerInfo = test_support:char_info(#{party_role => follower}),
    Follower = {ok, FollowerInfo, view([], [], [])},
    Solo = {ok, test_support:char_info(#{hp => 40, max_hp => 40, gold => 0}),
            view([{8, 5}], [], [])},
    GetState = test_support:scripted_states([Follower, Follower, Follower, Solo]),
    Move = test_support:move_recorder(self()),
    Pid = character:start(human, 1, GetState, Move),
    Moves = test_support:collect_moves(150),
    test_support:kill(Pid),
    ?assert(lists:member(east, Moves)).
