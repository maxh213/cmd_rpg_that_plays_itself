-module(enemy).
-export([start/3, start/4]).

-define(BASE_SPEED, 800).

-type view() :: dead | undefined | {ok, world:enemy()}.
-type get_state() :: fun((pid()) -> view()).
-type move() :: fun((pid(), util:direction()) -> ok).

-spec start(pos_integer(), get_state(), move()) -> pid().
start(Level, GetState, Move) ->
    start(Level, Level * 50 + ?BASE_SPEED, GetState, Move).

-spec start(pos_integer(), pos_integer(), get_state(), move()) -> pid().
start(_Level, Speed, GetState, Move) ->
    spawn(fun() ->
        timer:sleep(rand:uniform(Speed)),
        loop(Speed, GetState, Move)
    end).

-spec loop(pos_integer(), get_state(), move()) -> ok.
loop(Speed, GetState, Move) ->
    case GetState(self()) of
        {ok, _Info} ->
            Move(self(), wander_direction()),
            timer:sleep(Speed),
            loop(Speed, GetState, Move);
        undefined ->
            timer:sleep(100),
            loop(Speed, GetState, Move);
        dead ->
            ok
    end.

-spec wander_direction() -> util:direction().
wander_direction() ->
    case rand:uniform(2) of
        1 -> stay;
        2 -> util:random_direction()
    end.
