-module(test_support).
-export([char_info/0, char_info/1, enemy_info/0, enemy_info/1,
         world_state/0, world_state/1, fake_pid/0, listener_pid/1,
         scripted_states/1, const_state/1, move_recorder/1, collect_moves/1,
         capture_io/0, capture_io/1, resize/2, captured_text/1, null_group_leader/0, kill/1,
         eventually/2, flush_mailbox/0]).

char_info() ->
    char_info(#{}).

char_info(Overrides) ->
    maps:merge(#{
        name => "Roland", race => human, level => 1,
        hp => 20, max_hp => 23,
        exp => 0, x => 5, y => 5, inventory => [],
        attack_bonus => 0, defense_bonus => 0,
        gold => 0, party_role => solo, party_members => [],
        follower_pids => [], at_inn => false, inn_ticks => 0}, Overrides).

enemy_info() ->
    enemy_info(#{}).

enemy_info(Overrides) ->
    maps:merge(#{
        name => "Goblin", level => 1, hp => 9, max_hp => 9,
        x => 5, y => 5, type => enemy}, Overrides).

world_state() ->
    world_state(#{}).

world_state(Overrides) ->
    maps:merge(#{
        characters => #{}, enemies => #{},
        shops => [], inns => [],
        display_pid => fake_pid(),
        event_log => [], move_count => 0}, Overrides).

fake_pid() ->
    spawn(fun() -> ok end).

listener_pid(TestPid) ->
    spawn(fun() -> listener_loop(TestPid) end).

listener_loop(TestPid) ->
    receive
        Any ->
            TestPid ! {heard, self(), Any},
            listener_loop(TestPid)
    end.

scripted_states(States) ->
    Ref = atomics:new(1, []),
    fun(_) ->
        N = atomics:add_get(Ref, 1, 1),
        lists:nth(min(N, length(States)), States)
    end.

const_state(State) ->
    fun(_) -> State end.

move_recorder(TestPid) ->
    fun(Pid, Direction) -> TestPid ! {moved, Pid, Direction} end.

collect_moves(Ms) ->
    flush_mailbox(),
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    collect_until(Deadline, []).

flush_mailbox() ->
    receive _Any -> flush_mailbox() after 0 -> ok end.

collect_until(Deadline, Acc) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    if
        Remaining =< 0 ->
            lists:reverse(Acc);
        true ->
            receive {moved, _Pid, Direction} ->
                collect_until(Deadline, [Direction | Acc])
            after Remaining ->
                lists:reverse(Acc)
            end
    end.

capture_io() ->
    capture_io(unsized).

capture_io(Size) ->
    spawn(fun() -> capture_loop(Size, []) end).

resize(CapturePid, Size) ->
    CapturePid ! {resize, Size},
    ok.

capture_loop(Size, Acc) ->
    receive
        {io_request, From, ReplyAs, {get_geometry, Which}} ->
            From ! {io_reply, ReplyAs, geometry(Which, Size)},
            capture_loop(Size, Acc);
        {io_request, From, ReplyAs, Request} ->
            From ! {io_reply, ReplyAs, ok},
            capture_loop(Size, [request_chars(Request) | Acc]);
        {resize, NewSize} ->
            capture_loop(NewSize, Acc);
        {get_text, From} ->
            From ! {captured_text, lists:flatten(lists:reverse(Acc))},
            capture_loop(Size, Acc)
    end.

geometry(columns, {Cols, _Rows}) -> Cols;
geometry(rows, {_Cols, Rows}) -> Rows;
geometry(_Which, unsized) -> {error, enotsup}.

request_chars({put_chars, Chars}) -> Chars;
request_chars({put_chars, _Encoding, Chars}) -> Chars;
request_chars({put_chars, _Encoding, Module, Function, Args}) -> apply(Module, Function, Args);
request_chars({requests, Requests}) -> [request_chars(R) || R <- Requests];
request_chars(_Other) -> [].

captured_text(CapturePid) ->
    CapturePid ! {get_text, self()},
    receive {captured_text, Text} -> Text after 3000 -> "" end.

null_group_leader() ->
    spawn(fun() -> null_io_loop() end).

null_io_loop() ->
    receive
        {io_request, From, ReplyAs, _Request} ->
            From ! {io_reply, ReplyAs, ok},
            null_io_loop()
    end.

kill(Pid) when is_pid(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    ok.

eventually(_Predicate, 0) ->
    false;
eventually(Predicate, Retries) ->
    case Predicate() of
        true -> true;
        false ->
            timer:sleep(25),
            eventually(Predicate, Retries - 1)
    end.
