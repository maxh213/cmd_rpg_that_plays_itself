-module(frame_rules_tests).
-include_lib("eunit/include/eunit.hrl").

hero_names(Characters) ->
    Lines = frame:lines({Characters, #{}, [], [], [], 0}, {80, 40}),
    [Name || Line <- Lines, {[bold], Name} <- Line].

solos_list_highest_level_first_test() ->
    Characters = #{a => test_support:char_info(#{name => "Ann", level => 1}),
                   b => test_support:char_info(#{name => "Bob", level => 2})},
    ?assertEqual(["Bob", "Ann"], hero_names(Characters)).

solos_of_equal_level_keep_roster_order_test() ->
    Characters = #{a => test_support:char_info(#{name => "Ann", level => 2}),
                   b => test_support:char_info(#{name => "Bob", level => 2})},
    RosterOrder = lists:reverse([maps:get(name, Info) || {_, Info} <- maps:to_list(Characters)]),
    ?assertEqual(RosterOrder, hero_names(Characters)).
