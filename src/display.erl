-module(display).
-export([start/1, start/2]).

-define(IDLE_TIMEOUT, 10000).
-define(FALLBACK_COLS, 85).
-define(FALLBACK_ROWS, 75).

start(WorldPid) ->
    start(WorldPid, ?IDLE_TIMEOUT).

start(_WorldPid, Timeout) ->
    spawn(fun() -> loop(Timeout, screen:unpainted()) end).

loop(Timeout, Screen) ->
    receive
        {render, Characters, Enemies, Shops, Inns, EventLog, MoveCount} ->
            Size = terminal_size(io:columns(), io:rows()),
            World = {Characters, Enemies, Shops, Inns, EventLog, MoveCount},
            {Bytes, Painted} = screen:update(Screen, frame:lines(World, Size), Size),
            io:format("~s", [Bytes]),
            loop(Timeout, Painted)
    after Timeout ->
        loop(Timeout, Screen)
    end.

terminal_size({ok, Cols}, {ok, Rows}) ->
    {Cols, Rows};
terminal_size(_Cols, _Rows) ->
    {?FALLBACK_COLS, ?FALLBACK_ROWS}.

