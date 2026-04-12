-module(util).
-export([random_name/1, clamp/3, random_pos/1, random_direction/0, shuffle/1]).

%% Generate a random name of the given length from alphanumeric chars
random_name(Length) ->
    Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    [lists:nth(rand:uniform(length(Chars)), Chars) || _ <- lists:seq(1, Length)].

clamp(Val, Min, Max) ->
    max(Min, min(Max, Val)).

random_pos(MapSize) ->
    {rand:uniform(MapSize) - 1, rand:uniform(MapSize) - 1}.

random_direction() ->
    lists:nth(rand:uniform(5), [north, south, east, west, stay]).

shuffle([]) -> [];
shuffle(List) ->
    Tagged = [{rand:uniform(), X} || X <- List],
    [X || {_, X} <- lists:sort(Tagged)].
