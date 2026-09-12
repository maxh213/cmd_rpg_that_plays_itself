-module(screen_tests).
-include_lib("eunit/include/eunit.hrl").

-define(CLEAR, "\e[?25l\e[H\e[2J").

line(Text) ->
    [{[], Text}].

bytes(Screen, Lines, Size) ->
    {Bytes, Next} = screen:update(Screen, Lines, Size),
    {lists:flatten(Bytes), Next}.

first_update_clears_and_parks_on_the_last_row_test() ->
    {Bytes, _} = bytes(screen:unpainted(), [line("ab")], {10, 5}),
    ?assertEqual(?CLEAR ++ "\e[1;1H\e[0mab\e[0m\e[5;1H\e[?25h", Bytes).

same_size_repaints_only_what_changed_test() ->
    {_, Painted} = bytes(screen:unpainted(), [line("ab"), line("cd")], {10, 5}),
    {Bytes, _} = bytes(Painted, [line("ab"), line("cx")], {10, 5}),
    ?assertEqual("\e[?25l\e[2;2H\e[0mx\e[0m\e[5;1H\e[?25h", Bytes),
    {Same, _} = bytes(Painted, [line("ab"), line("cd")], {10, 5}),
    ?assertEqual("\e[?25l\e[5;1H\e[?25h", Same).

a_new_size_repaints_in_full_test() ->
    {_, Painted} = bytes(screen:unpainted(), [line("ab")], {10, 5}),
    {Bytes, _} = bytes(Painted, [line("ab")], {12, 6}),
    ?assertEqual(?CLEAR ++ "\e[1;1H\e[0mab\e[0m\e[6;1H\e[?25h", Bytes).

lines_are_clipped_to_the_terminal_test() ->
    {Bytes, _} = bytes(screen:unpainted(), [line("abcdef"), line("gh"), line("ij")], {3, 3}),
    ?assertEqual(?CLEAR ++ "\e[1;1H\e[0mabc\e[0m\e[2;1H\e[0mgh\e[0m\e[3;1H\e[?25h", Bytes).

a_one_row_terminal_gets_only_the_clear_and_the_park_test() ->
    {Bytes, _} = bytes(screen:unpainted(), [line("Terminal too small")], {30, 1}),
    ?assertEqual(?CLEAR ++ "\e[1;1H\e[?25h", Bytes).
