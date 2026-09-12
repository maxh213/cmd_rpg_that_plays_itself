-module(character).
-export([start/3, start/4]).

start(Race, GetState, Move) ->
    start(Race, util:race_speed(Race), GetState, Move).

start(_Race, Speed, GetState, Move) ->
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
        {ok, MyInfo, WorldView} ->
            act(Speed, GetState, Move, MyInfo, WorldView)
    end.

act(Speed, GetState, Move, MyInfo, WorldView) ->
    case maps:get(party_role, MyInfo, solo) of
        follower ->
            follower_loop(Speed, GetState, Move);
        _ ->
            Move(self(), decide_action(MyInfo, WorldView)),
            timer:sleep(Speed),
            loop(Speed, GetState, Move)
    end.

follower_loop(Speed, GetState, Move) ->
    receive
        {solo} ->
            loop(Speed, GetState, Move);
        die ->
            ok
    after Speed ->
        check_release(GetState(self()), Speed, GetState, Move)
    end.

check_release(dead, _Speed, _GetState, _Move) ->
    ok;
check_release(undefined, _Speed, _GetState, _Move) ->
    ok;
check_release({ok, MyInfo, _WorldView}, Speed, GetState, Move) ->
    case maps:get(party_role, MyInfo, solo) of
        follower -> follower_loop(Speed, GetState, Move);
        _ -> loop(Speed, GetState, Move)
    end.

decide_action(MyInfo, WorldView) ->
    Hp = maps:get(hp, MyInfo),
    MaxHp = maps:get(max_hp, MyInfo),
    AtInn = maps:get(at_inn, MyInfo, false),
    case AtInn andalso Hp * 4 < MaxHp * 3 of
        true -> stay;
        false -> seek_goal(MyInfo, WorldView)
    end.

seek_goal(MyInfo, WorldView) ->
    X = maps:get(x, MyInfo),
    Y = maps:get(y, MyInfo),
    Gold = maps:get(gold, MyInfo, 0),
    EnemyPositions = maps:get(enemy_positions, WorldView, []),
    ShopPositions = maps:get(shop_positions, WorldView, []),
    InnPositions = maps:get(inn_positions, WorldView, []),
    case {maps:get(hp, MyInfo) * 2 < maps:get(max_hp, MyInfo), Gold >= 5} of
        {true, true} -> seek_target(X, Y, ShopPositions, EnemyPositions, 9);
        {true, false} -> seek_target(X, Y, InnPositions, EnemyPositions, 9);
        {_, _} -> seek_combat_goal(MyInfo, X, Y, Gold, EnemyPositions, ShopPositions)
    end.

seek_combat_goal(MyInfo, X, Y, Gold, EnemyPositions, ShopPositions) ->
    case maps:get(party_role, MyInfo, solo) =:= leader of
        true -> seek_enemy(X, Y, EnemyPositions, 8);
        false -> rich_or_fight(X, Y, Gold, EnemyPositions, ShopPositions)
    end.

rich_or_fight(X, Y, Gold, EnemyPositions, ShopPositions) ->
    case Gold >= 15 of
        true -> seek_target(X, Y, ShopPositions, EnemyPositions, 6);
        false -> seek_enemy(X, Y, EnemyPositions, 7)
    end.

seek_target(X, Y, PrimaryPositions, FallbackPositions, Chance) ->
    case find_nearest(X, Y, PrimaryPositions) of
        none -> seek_enemy(X, Y, FallbackPositions, Chance);
        Target -> move_toward_target(X, Y, Target, Chance)
    end.

seek_enemy(X, Y, EnemyPositions, Chance) ->
    case find_nearest(X, Y, EnemyPositions) of
        none -> util:random_direction();
        Target -> move_toward_target(X, Y, Target, Chance)
    end.

move_toward_target(X, Y, {TX, TY}, Chance) ->
    case rand:uniform(10) of
        N when N =< Chance -> move_toward(X, Y, TX, TY);
        _ -> util:random_direction()
    end.

find_nearest(_X, _Y, []) -> none;
find_nearest(X, Y, Positions) ->
    WithDist = [{abs(EX - X) + abs(EY - Y), {EX, EY}} || {EX, EY} <- Positions],
    {_Dist, Nearest} = lists:min(WithDist),
    Nearest.

move_toward(X, Y, EX, EY) ->
    DX = EX - X,
    DY = EY - Y,
    if
        abs(DX) > abs(DY) -> step_horizontal(DX);
        abs(DY) > abs(DX) -> step_vertical(DY);
        true -> break_tie(DX, DY)
    end.

break_tie(0, 0) ->
    stay;
break_tie(DX, DY) ->
    case rand:uniform(2) of
        1 -> step_horizontal(DX);
        2 -> step_vertical(DY)
    end.

step_horizontal(DX) when DX > 0 -> east;
step_horizontal(_DX) -> west.

step_vertical(DY) when DY > 0 -> south;
step_vertical(_DY) -> north.
