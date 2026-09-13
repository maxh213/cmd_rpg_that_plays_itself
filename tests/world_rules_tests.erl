-module(world_rules_tests).
-include_lib("eunit/include/eunit.hrl").

-define(ROLL_4_SEED, 9).
-define(ROLL_9_SEED, 1).

hero(Overrides) ->
    test_support:char_info(maps:merge(#{name => "Ann", x => 4, y => 5}, Overrides)).

state(Characters, Overrides) ->
    test_support:world_state(maps:merge(#{characters => Characters, move_count => 1}, Overrides)).

step(Seed, State) ->
    rand:seed(exsss, {Seed, 0, 0}),
    world:move(hero, east, State).

text(Log) ->
    [lists:flatten(Line) || Line <- Log].

has(Fragment, Lines) ->
    lists:any(fun(Line) -> string:find(Line, Fragment) =/= nomatch end, Lines).

place(X, Y) ->
    #{name => "Spot", x => X, y => Y}.

inn_needs_both_coordinates_test() ->
    {S, _} = step(1, state(#{hero => hero(#{})}, #{inns => [place(5, 9)]})),
    ?assertEqual(hero(#{x => 5}), maps:get(hero, maps:get(characters, S))).

inn_flags_clear_off_the_inn_test() ->
    Resting = hero(#{x => 5, at_inn => true, inn_ticks => 2}),
    {Chars, _, _} = world:render_tick(state(#{hero => Resting}, #{inns => [place(5, 9)]})),
    ?assertEqual(Resting#{at_inn := false, inn_ticks := 0}, maps:get(hero, Chars)).

shop_needs_both_coordinates_test() ->
    Rich = hero(#{gold => 100}),
    {S, _} = step(1, state(#{hero => Rich}, #{shops => [place(5, 9)]})),
    ?assertEqual(Rich#{x := 5}, maps:get(hero, maps:get(characters, S))).

enemy_needs_both_coordinates_test() ->
    Enemies = #{rat => test_support:enemy_info(#{x => 5, y => 9})},
    {S, Fx} = step(1, state(#{hero => hero(#{})}, #{enemies => Enemies})),
    ?assertEqual({Enemies, [], []}, {maps:get(enemies, S), maps:get(event_log, S), Fx}).

log_keeps_the_newest_fifty_test() ->
    Fifty = lists:seq(1, 50),
    ?assertEqual(Fifty, world:append_log(lists:seq(1, 49), [50])),
    ?assertEqual(lists:seq(3, 52), world:append_log(Fifty, [51, 52])).

equal_levels_make_the_first_candidate_leader_test() ->
    Chars = #{a => hero(#{name => "Bea", x => 5, level => 2, inn_ticks => 3}),
              hero => hero(#{level => 2, inn_ticks => 3})},
    {S, _} = step(1, state(Chars, #{inns => [place(5, 5)], move_count => 0})),
    [Follower, Leader] = maps:keys(Chars),
    NewChars = maps:get(characters, S),
    ?assertEqual({leader, follower}, {maps:get(party_role, maps:get(Leader, NewChars)),
                                      maps:get(party_role, maps:get(Follower, NewChars))}).

shop_log(Seed, Gold) ->
    {S, _} = step(Seed, state(#{hero => hero(#{gold => Gold})}, #{shops => [place(5, 5)]})),
    hd(text(maps:get(event_log, S))).

roll_of_four_buys_the_best_heal_test() ->
    ?assertEqual("Ann bought Elixir (-12g)", shop_log(?ROLL_4_SEED, 20)).

roll_of_nine_buys_the_best_stat_test() ->
    ?assertEqual("Ann bought Tower Shield (-20g)", shop_log(?ROLL_9_SEED, 20)),
    ?assertEqual("Ann bought Wooden Shield (-8g)", shop_log(?ROLL_9_SEED, 12)).

potion_restores_hp_test() ->
    Hurt = hero(#{gold => 5, hp => 10}),
    {S, _} = step(1, state(#{hero => Hurt}, #{shops => [place(5, 5)]})),
    ?assertEqual(20, maps:get(hp, maps:get(hero, maps:get(characters, S)))).

kill_without_level_up_logs_no_level_test() ->
    Strong = hero(#{level => 9, hp => 50, max_hp => 50, attack_bonus => 99, defense_bonus => 999}),
    Enemies = #{rat => test_support:enemy_info(#{name => "Rat", hp => 1})},
    {S, _} = step(1, state(#{hero => Strong}, #{enemies => Enemies})),
    Log = text(maps:get(event_log, S)),
    ?assert(has("Ann slew Rat(Lv1)", Log)),
    ?assertNot(has("leveled up", Log)).

damage_to_exactly_zero_hp_mauls_test() ->
    Frail = hero(#{hp => 1, defense_bonus => 10}),
    Enemies = #{ogre => test_support:enemy_info(#{name => "Ogre", defense_bonus => 99})},
    {S, _} = step(1, state(#{hero => Frail}, #{enemies => Enemies})),
    ?assertNot(maps:is_key(hero, maps:get(characters, S))),
    ?assertEqual(["Ann was mauled by Ogre!"], text(maps:get(event_log, S))).

solo_damage_to_exactly_zero_hp_slays_test() ->
    Guarded = hero(#{defense_bonus => 1000}),
    Enemies = #{ogre => test_support:enemy_info(#{name => "Ogre", hp => 1, defense_bonus => 100})},
    {S, _} = step(1, state(#{hero => Guarded}, #{enemies => Enemies})),
    Log = text(maps:get(event_log, S)),
    ?assertEqual(#{}, maps:get(enemies, S)),
    ?assert(has("Ann slew Ogre(Lv1)", Log)),
    ?assertNot(has("Ann hit", Log)).

party_damage_to_exactly_zero_hp_slays_test() ->
    Leader = hero(#{party_role => leader, defense_bonus => 1000}),
    Enemies = #{ogre => test_support:enemy_info(#{name => "Ogre", hp => 1, defense_bonus => 100})},
    {S, _} = step(1, state(#{hero => Leader}, #{enemies => Enemies})),
    ?assertEqual(#{}, maps:get(enemies, S)).

party_state() ->
    Member = #{hp => 1, defense_bonus => 100, x => 4},
    Fay = hero(Member#{name => "Fay", party_role => follower}),
    Gus = hero(Member#{name => "Gus", party_role => follower}),
    Lea = hero(Member#{name => "Lea", party_role => leader,
                       follower_pids => [f1, f2], party_members => [Fay, Gus]}),
    Enemies = #{ogre => test_support:enemy_info(#{name => "Ogre", defense_bonus => 10000})},
    state(#{hero => Lea, f1 => Fay, f2 => Gus}, #{enemies => Enemies}).

member_damage_to_exactly_zero_hp_slays_test() ->
    Logs = lists:append([text(maps:get(event_log, element(1, step(Seed, party_state()))))
                         || Seed <- lists:seq(1, 30)]),
    ?assertNot(has(" hit by ", Logs)),
    ?assert(has("Lea was slain by Ogre! Party disbanded!", Logs)),
    ?assert(has("Fay was slain by Ogre!", Logs) orelse has("Gus was slain by Ogre!", Logs)).

pvp_damage_to_exactly_zero_hp_defeats_test() ->
    Chars = #{a => hero(#{x => 5, defense_bonus => 1000}),
              b => hero(#{name => "Bob", x => 5, hp => 1, defense_bonus => 100})},
    {NewChars, Log, _} = world:render_tick(state(Chars, #{})),
    ?assertNot(maps:is_key(b, NewChars)),
    ?assertEqual(["Ann defeated Bob! [+1XP]"], text(Log)).
