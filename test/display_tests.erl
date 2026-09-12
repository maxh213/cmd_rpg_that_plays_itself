-module(display_tests).
-include_lib("eunit/include/eunit.hrl").

strip_ansi(Text) ->
    re:replace(Text, "\e\\[[0-9;?]*[a-zA-Z]", "", [global, {return, list}]).

start_display(Timeout) ->
    CapturePid = test_support:capture_io(),
    OldLeader = erlang:group_leader(),
    erlang:group_leader(CapturePid, self()),
    DisplayPid = display:start(fake_world, Timeout),
    erlang:group_leader(OldLeader, self()),
    {CapturePid, DisplayPid}.

rich_characters() ->
    LeaderPid = test_support:fake_pid(),
    BromPid = test_support:fake_pid(),
    CedricPid = test_support:fake_pid(),
    DurnirPid = test_support:fake_pid(),
    ElaraPid = test_support:fake_pid(),
    NyxPid = test_support:fake_pid(),
    GhostPid = test_support:fake_pid(),
    #{
        LeaderPid => test_support:char_info(#{
            name => "Aldric", race => human, level => 5, party_role => leader,
            hp => 40, max_hp => 40, attack_bonus => 2, defense_bonus => 3,
            x => 1, y => 1, follower_pids => [BromPid, GhostPid],
            party_members => []}),
        BromPid => test_support:char_info(#{
            name => "Brom", race => dwarf, level => 3, party_role => follower,
            hp => 9, max_hp => 20, attack_bonus => 2, defense_bonus => 0,
            x => 1, y => 1}),
        CedricPid => test_support:char_info(#{
            name => "Cedric", race => gnome, level => 2, party_role => follower,
            hp => 15, max_hp => 20, attack_bonus => 0, defense_bonus => 0,
            x => 5, y => 5}),
        DurnirPid => test_support:char_info(#{
            name => "Durnir", race => treant, level => 3, party_role => solo,
            hp => 3, max_hp => 20, attack_bonus => 0, defense_bonus => 4,
            x => 2, y => 2}),
        ElaraPid => test_support:char_info(#{
            name => "Elara", race => dark_elf, level => 1, party_role => solo,
            hp => 19, max_hp => 20, attack_bonus => 0, defense_bonus => 0,
            x => 3, y => 3}),
        NyxPid => maps:remove(gold, maps:remove(race, test_support:char_info(#{
            name => "Nyx", level => 6, party_role => solo,
            hp => 60, max_hp => 60, attack_bonus => 1, defense_bonus => 1,
            x => 4, y => 4})))
    }.

full_frame_renders_everything_test() ->
    {CapturePid, DisplayPid} = start_display(40),
    Characters = rich_characters(),
    EnemyPid = test_support:fake_pid(),
    Enemies = #{EnemyPid => test_support:enemy_info(#{name => "Goblin", level => 2, x => 6, y => 6})},
    Shops = [#{name => "Ye Olde Armoury", x => 7, y => 7}],
    Inns = [#{name => "The Rusty Flagon", x => 8, y => 8}],
    Events = [io_lib:format("ev~2..0b", [N]) || N <- lists:seq(1, 15)],
    DisplayPid ! {render, Characters, Enemies, Shops, Inns, Events, 7},
    timer:sleep(150),
    test_support:kill(DisplayPid),
    Text = strip_ansi(test_support:captured_text(CapturePid)),
    test_support:kill(CapturePid),
    ?assert(string:find(Text, "=== CMD RPG [7 moves] ===") =/= nomatch),
    ?assert(string:find(Text, "@ Hero  & Party  ! Enemy  $ Shop  H Inn") =/= nomatch),
    ?assert(string:find(Text, "Heroes:") =/= nomatch),
    ?assert(string:find(Text, "--- Party: Aldric + Brom ---") =/= nomatch),
    ?assert(string:find(Text, "    & Aldric (Hum)") =/= nomatch),
    ?assert(string:find(Text, "      + Brom (Dwf)") =/= nomatch),
    ?assert(string:find(Text, "    @ Durnir (Trt)") =/= nomatch),
    ?assert(string:find(Text, "    @ Nyx (Hum)") =/= nomatch),
    ?assertEqual(nomatch, string:find(Text, "Cedric")),
    ?assert(string:find(Text, "+2ATK +3DEF") =/= nomatch),
    ?assert(string:find(Text, "+4DEF") =/= nomatch),
    ?assert(string:find(Text, "Enemies on map: 1") =/= nomatch),
    ?assert(string:find(Text, "ev04") =/= nomatch),
    ?assertEqual(nomatch, string:find(Text, "ev03")),
    ?assert(string:find(Text, "&") =/= nomatch),
    ?assert(string:find(Text, "!") =/= nomatch),
    ?assert(string:find(Text, "$") =/= nomatch),
    ?assert(string:find(Text, "H") =/= nomatch),
    GridRows = [Line || Line <- string:split(Text, "\n", all), grid_row(Line)],
    ?assertEqual(40, length(GridRows)),
    lists:foreach(fun(Line) -> ?assertEqual(84, length(Line)) end, GridRows),
    BorderRows = [Line || Line <- string:split(Text, "\n", all), border_row(Line)],
    ?assertEqual(2, length(BorderRows)).

grid_row("  |" ++ Rest) ->
    length(Rest) > 0 andalso lists:last(Rest) =:= $|;
grid_row(_) ->
    false.

border_row("  +" ++ Rest) ->
    length(Rest) > 0 andalso lists:last(Rest) =:= $+;
border_row(_) ->
    false.

party_map_cell_is_single_glyph_test() ->
    {CapturePid, DisplayPid} = start_display(40),
    Characters = rich_characters(),
    DisplayPid ! {render, Characters, #{}, [], [], [], 3},
    timer:sleep(100),
    test_support:kill(DisplayPid),
    Text = strip_ansi(test_support:captured_text(CapturePid)),
    test_support:kill(CapturePid),
    GridLines = [Line || Line <- string:split(Text, "\n", all), grid_row(Line)],
    Grid = string:join(GridLines, "\n"),
    ?assertEqual(1, count_occurrences(Grid, "&")),
    ?assertEqual(3, count_occurrences(Grid, "@")),
    ?assertEqual(1, count_occurrences(Grid, "+")).

count_occurrences(Text, What) ->
    length(string:split(Text, What, all)) - 1.

empty_frame_shows_quiet_log_test() ->
    {CapturePid, DisplayPid} = start_display(40),
    DisplayPid ! {render, #{}, #{}, [], [], [], 0},
    timer:sleep(100),
    test_support:kill(DisplayPid),
    Text = strip_ansi(test_support:captured_text(CapturePid)),
    test_support:kill(CapturePid),
    ?assert(string:find(Text, "=== CMD RPG [0 moves] ===") =/= nomatch),
    ?assert(string:find(Text, "Heroes:") =/= nomatch),
    ?assert(string:find(Text, "Enemies on map: 0") =/= nomatch),
    ?assert(string:find(Text, "> (quiet...)") =/= nomatch).

short_log_shows_all_events_test() ->
    {CapturePid, DisplayPid} = start_display(40),
    DisplayPid ! {render, #{}, #{}, [], [], ["first", "second", "third"], 1},
    timer:sleep(100),
    test_support:kill(DisplayPid),
    Text = strip_ansi(test_support:captured_text(CapturePid)),
    test_support:kill(CapturePid),
    ?assert(string:find(Text, "> first") =/= nomatch),
    ?assert(string:find(Text, "> second") =/= nomatch),
    ?assert(string:find(Text, "> third") =/= nomatch),
    ?assertEqual(nomatch, string:find(Text, "(quiet...)")).

start_with_default_timeout_test() ->
    DisplayPid = display:start(self()),
    ?assert(is_process_alive(DisplayPid)),
    test_support:kill(DisplayPid).
