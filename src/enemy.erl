-module(enemy).
-export([start/3, start/4]).

-define(BASE_SPEED, 800).

start(Level, GetState, Move) ->
    start(Level, ?BASE_SPEED + Level * 50, GetState, Move).

start(_Level, Speed, GetState, Move) ->
    spawn(fun() ->
        timer:sleep(rand:uniform(Speed)),
        loop(Speed, GetState, Move)
    end).

loop(Speed, GetState, Move) ->
    case GetState(self()) of
        dead ->
            ok;
        undefined ->
            timer:sleep(100),
            loop(Speed, GetState, Move);
        {ok, _Info} ->
            Move(self(), wander_direction()),
            timer:sleep(Speed),
            loop(Speed, GetState, Move)
    end.

wander_direction() ->
    case rand:uniform(2) of
        1 -> stay;
        2 -> util:random_direction()
    end.
