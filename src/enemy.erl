-module(enemy).
-export([start/1]).

-define(BASE_SPEED, 800).

%% Each enemy is an autonomous process. Higher level enemies move slower.
start(Level) ->
    Speed = ?BASE_SPEED + Level * 50,
    spawn(fun() ->
        timer:sleep(rand:uniform(Speed)),
        loop(Speed)
    end).

loop(Speed) ->
    case world_server:get_enemy_state(self()) of
        dead ->
            ok;
        undefined ->
            timer:sleep(100),
            loop(Speed);
        {ok, _Info} ->
            %% 50% chance to stay put, 50% to wander
            Direction = case rand:uniform(2) of
                1 -> stay;
                2 -> util:random_direction()
            end,
            world_server:move(self(), Direction),
            timer:sleep(Speed),
            loop(Speed)
    end.
