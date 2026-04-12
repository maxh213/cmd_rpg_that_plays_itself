-module(enemy).
-export([start/1]).

%% Spawn an enemy process — wanders around the map, slower than characters
start(WorldPid) ->
    spawn(fun() -> loop(WorldPid) end).

loop(WorldPid) ->
    receive
        {tick, _State} ->
            %% Enemies move less often (50% chance to stay put)
            Direction = case rand:uniform(2) of
                1 -> stay;
                2 -> util:random_direction()
            end,
            world_server:move(self(), Direction),
            loop(WorldPid);
        die ->
            ok
    after 5000 ->
        loop(WorldPid)
    end.
