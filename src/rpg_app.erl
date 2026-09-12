-module(rpg_app).
-export([start/0, start/1]).

-spec start() -> no_return().
start() ->
    start(fun erlang:halt/1).

-spec start(fun((0 | 1) -> T)) -> T.
start(Halt) ->
    io:format("Starting CMD RPG...~n"),
    case world_server:start_link() of
        {ok, _Pid} ->
            io:format("World is alive. Watch the heroes fight!~n"),
            io:format("Press Ctrl+C to stop.~n~n"),
            timer:sleep(1000),
            wait_forever(Halt);
        {error, Reason} ->
            io:format("Failed to start: ~p~n", [Reason]),
            Halt(1)
    end.

-spec wait_forever(fun((0) -> T)) -> T.
wait_forever(Halt) ->
    receive
        stop -> Halt(0)
    end.
