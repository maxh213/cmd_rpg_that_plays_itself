-module(enemy_rules_tests).
-include_lib("eunit/include/eunit.hrl").

level_speed_starts_a_live_enemy_test() ->
    GetState = test_support:const_state(undefined),
    Pid = enemy:start(1, GetState, test_support:move_recorder(self())),
    timer:sleep(50),
    Alive = is_process_alive(Pid),
    test_support:kill(Pid),
    ?assert(Alive).
