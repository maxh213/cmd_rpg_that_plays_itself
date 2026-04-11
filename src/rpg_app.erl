-module(rpg_app).
-export([start/0]).

%% Entry point — starts the world server and lets it run
start() ->
    io:format("Starting CMD RPG...~n"),
    case world_server:start_link() of
        {ok, _Pid} ->
            io:format("World is alive. Watch the heroes fight!~n"),
            io:format("Press Ctrl+C to stop.~n~n"),
            timer:sleep(1000),
            %% Keep the main process alive
            wait_forever();
        {error, Reason} ->
            io:format("Failed to start: ~p~n", [Reason]),
            halt(1)
    end.

wait_forever() ->
    receive
        stop -> halt(0)
    end.
