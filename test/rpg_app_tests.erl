-module(rpg_app_tests).
-include_lib("eunit/include/eunit.hrl").

stop_world_server() ->
    case whereis(world_server) of
        undefined ->
            ok;
        Server ->
            DisplayPid = maps:get(display_pid, sys:get_state(Server)),
            test_support:kill(Server),
            test_support:kill(DisplayPid),
            ?assert(test_support:eventually(fun() -> whereis(world_server) =:= undefined end, 60)),
            ok
    end.

boot_failure_reports_and_halts_test() ->
    NullLeader = test_support:null_group_leader(),
    OldLeader = erlang:group_leader(),
    erlang:group_leader(NullLeader, self()),
    {ok, Server} = world_server:start_link(),
    unlink(Server),
    CapturePid = test_support:capture_io(),
    erlang:group_leader(CapturePid, self()),
    Result = rpg_app:start(fun(Code) -> {halt_called, Code} end),
    erlang:group_leader(OldLeader, self()),
    ?assertEqual({halt_called, 1}, Result),
    stop_world_server(),
    test_support:kill(NullLeader),
    Text = test_support:captured_text(CapturePid),
    test_support:kill(CapturePid),
    ?assert(string:find(Text, "Starting CMD RPG...") =/= nomatch),
    ?assert(string:find(Text, "Failed to start:") =/= nomatch).

boot_success_announces_and_waits_test() ->
    test_support:flush_mailbox(),
    CapturePid = test_support:capture_io(),
    TestPid = self(),
    Runner = spawn(fun() ->
        erlang:group_leader(CapturePid, self()),
        rpg_app:start(fun(Code) -> TestPid ! {halted, Code}, ok end)
    end),
    timer:sleep(1400),
    Runner ! stop,
    receive {halted, 0} -> ok after 2000 -> ?assert(false) end,
    stop_world_server(),
    Text = test_support:captured_text(CapturePid),
    test_support:kill(CapturePid),
    ?assert(string:find(Text, "Starting CMD RPG...") =/= nomatch),
    ?assert(string:find(Text, "World is alive. Watch the heroes fight!") =/= nomatch),
    ?assert(string:find(Text, "Press Ctrl+C to stop.") =/= nomatch),
    ?assert(string:find(Text, "=== CMD RPG [") =/= nomatch).

start_uses_default_halt_test() ->
    NullLeader = test_support:null_group_leader(),
    Runner = spawn(fun() ->
        erlang:group_leader(NullLeader, self()),
        rpg_app:start()
    end),
    timer:sleep(1400),
    Server = whereis(world_server),
    ?assert(is_pid(Server)),
    DisplayPid = maps:get(display_pid, sys:get_state(Server)),
    test_support:kill(Runner),
    timer:sleep(50),
    test_support:kill(Server),
    test_support:kill(DisplayPid),
    ?assert(test_support:eventually(fun() -> whereis(world_server) =:= undefined end, 60)),
    test_support:kill(NullLeader).
