-module(enemy_tests).
-include_lib("eunit/include/eunit.hrl").

dead_state_stops_process_test() ->
    GetState = test_support:const_state(dead),
    Move = test_support:move_recorder(self()),
    Pid = enemy:start(1, 1, GetState, Move),
    timer:sleep(100),
    ?assertNot(is_process_alive(Pid)).

undefined_state_retries_test() ->
    GetState = test_support:scripted_states([undefined, undefined, dead]),
    Move = test_support:move_recorder(self()),
    Pid = enemy:start(1, 1, GetState, Move),
    timer:sleep(500),
    ?assertNot(is_process_alive(Pid)).

enemy_wanders_both_ways_test() ->
    Info = test_support:enemy_info(),
    GetState = test_support:const_state({ok, Info}),
    Move = test_support:move_recorder(self()),
    Pid = enemy:start(1, 1, GetState, Move),
    Moves = test_support:collect_moves(100),
    test_support:kill(Pid),
    ?assert(length(Moves) > 5),
    Expected = [north, south, east, west, stay],
    lists:foreach(fun(D) -> ?assert(lists:member(D, Expected)) end, Moves),
    ?assert(lists:member(stay, Moves)),
    ?assert(length(lists:usort(Moves)) >= 2).
