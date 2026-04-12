-module(character).
-export([start/1]).

%% Each character is a fully autonomous process with its own movement timer.
%% It queries the world server for its own state, decides what to do, and acts.
start(Race) ->
    Speed = util:race_speed(Race),
    spawn(fun() ->
        %% Small random offset so characters don't all start in sync
        timer:sleep(rand:uniform(Speed)),
        loop(Speed)
    end).

loop(Speed) ->
    %% Query our own state from the world server
    case world_server:get_my_state(self()) of
        dead ->
            %% We've been removed; stop
            ok;
        undefined ->
            %% Not registered yet, wait and retry
            timer:sleep(100),
            loop(Speed);
        {ok, MyInfo, WorldView} ->
            case maps:get(party_role, MyInfo, solo) of
                follower ->
                    %% Followers don't act — just wait for release
                    follower_loop(Speed);
                _ ->
                    Direction = decide_action(MyInfo, WorldView),
                    world_server:move(self(), Direction),
                    timer:sleep(Speed),
                    loop(Speed)
            end
    end.

%% Follower mode: don't move, check periodically if released
follower_loop(Speed) ->
    receive
        {solo} ->
            loop(Speed);
        die ->
            ok
    after Speed ->
        %% Check if we're still a follower
        case world_server:get_my_state(self()) of
            dead -> ok;
            undefined -> ok;
            {ok, MyInfo, _} ->
                case maps:get(party_role, MyInfo, solo) of
                    follower -> follower_loop(Speed);
                    _ -> loop(Speed)
                end
        end
    end.

%% Character AI — decides direction based on own state + world view
decide_action(MyInfo, WorldView) ->
    X = maps:get(x, MyInfo),
    Y = maps:get(y, MyInfo),
    Hp = maps:get(hp, MyInfo),
    MaxHp = maps:get(max_hp, MyInfo),
    Gold = maps:get(gold, MyInfo, 0),
    PartyRole = maps:get(party_role, MyInfo, solo),
    AtInn = maps:get(at_inn, MyInfo, false),
    EnemyPositions = maps:get(enemy_positions, WorldView, []),
    ShopPositions = maps:get(shop_positions, WorldView, []),
    InnPositions = maps:get(inn_positions, WorldView, []),
    %% If resting at inn and HP still low, stay put
    case AtInn andalso Hp * 4 < MaxHp * 3 of
        true -> stay;
        false ->
            IsLeader = PartyRole =:= leader,
            case {Hp * 2 < MaxHp, Gold >= 5} of
                {true, true} ->
                    seek_target(X, Y, ShopPositions, EnemyPositions, 9);
                {true, false} ->
                    seek_target(X, Y, InnPositions, EnemyPositions, 9);
                _ when IsLeader ->
                    seek_enemy(X, Y, EnemyPositions, 8);
                _ ->
                    case Gold >= 15 of
                        true -> seek_target(X, Y, ShopPositions, EnemyPositions, 6);
                        false -> seek_enemy(X, Y, EnemyPositions, 7)
                    end
            end
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
        abs(DX) > abs(DY) ->
            if DX > 0 -> east; true -> west end;
        abs(DY) > abs(DX) ->
            if DY > 0 -> south; true -> north end;
        DX =:= 0 andalso DY =:= 0 ->
            stay;
        true ->
            case rand:uniform(2) of
                1 -> if DX > 0 -> east; true -> west end;
                2 -> if DY > 0 -> south; true -> north end
            end
    end.
