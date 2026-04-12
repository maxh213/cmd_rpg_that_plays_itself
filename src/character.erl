-module(character).
-export([start/1]).

%% Spawn a character process that autonomously decides actions each tick
start(WorldPid) ->
    spawn(fun() -> loop(WorldPid) end).

loop(WorldPid) ->
    receive
        {tick, State} ->
            Direction = decide_action(State),
            world_server:move(self(), Direction),
            loop(WorldPid);
        {you_died, _KillerPid} ->
            world_server:char_died(self(), _KillerPid),
            ok;
        die ->
            ok
    after 5000 ->
        loop(WorldPid)
    end.

%% Character AI: seek nearest enemy, with some randomness
decide_action(State) ->
    X = maps:get(x, State),
    Y = maps:get(y, State),
    EnemyPositions = maps:get(enemy_positions, State, []),
    case find_nearest(X, Y, EnemyPositions) of
        none ->
            util:random_direction();
        {EX, EY} ->
            %% 70% chance to move toward enemy, 30% random
            case rand:uniform(10) of
                N when N =< 7 -> move_toward(X, Y, EX, EY);
                _ -> util:random_direction()
            end
    end.

find_nearest(_X, _Y, []) -> none;
find_nearest(X, Y, Positions) ->
    WithDist = [{abs(EX - X) + abs(EY - Y), {EX, EY}} || {EX, EY} <- Positions],
    {_Dist, Nearest} = lists:min(WithDist),
    Nearest.

move_toward(X, Y, EX, EY) ->
    DX = EX - X,
    DY = EY - Y,
    %% Move along the axis with greater distance, break ties randomly
    if
        abs(DX) > abs(DY) ->
            if DX > 0 -> east; true -> west end;
        abs(DY) > abs(DX) ->
            if DY > 0 -> south; true -> north end;
        DX =:= 0 andalso DY =:= 0 ->
            stay;
        true ->
            %% Equal distance on both axes, pick randomly
            case rand:uniform(2) of
                1 -> if DX > 0 -> east; true -> west end;
                2 -> if DY > 0 -> south; true -> north end
            end
    end.
