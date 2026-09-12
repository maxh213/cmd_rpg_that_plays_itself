-module(display_tests).
-include_lib("eunit/include/eunit.hrl").

-define(HIDE, "\e[?25l").
-define(PARK, "\e[75;1H\e[?25h").
-define(SCREEN_ROWS, 75).
-define(GRID_TOP_ROW, 3).
-define(GRID_LEFT_COL, 4).

-define(assertShows(Rows, Text), ?assertNotEqual(nomatch, string:find(Rows, Text))).
-define(assertHides(Rows, Text), ?assertEqual(nomatch, string:find(Rows, Text))).

capturing_io(Start) ->
    capturing_io(unsized, Start).

capturing_io(Size, Start) ->
    CapturePid = test_support:capture_io(Size),
    OldLeader = erlang:group_leader(),
    erlang:group_leader(CapturePid, self()),
    DisplayPid = Start(),
    erlang:group_leader(OldLeader, self()),
    {CapturePid, DisplayPid}.

start_display(Timeout) ->
    capturing_io(fun() -> display:start(fake_world, Timeout) end).

await_updates(CapturePid, Wanted) ->
    test_support:eventually(
        fun() -> length(updates(test_support:captured_text(CapturePid))) >= Wanted end, 200).

stop_and_read(CapturePid, DisplayPid) ->
    Text = test_support:captured_text(CapturePid),
    test_support:kill(DisplayPid),
    test_support:kill(CapturePid),
    Text.

world(Overrides) ->
    maps:merge(#{characters => #{}, enemies => #{}, shops => [], inns => [],
                 log => [], moves => 0}, Overrides).

send_render(DisplayPid, World) ->
    DisplayPid ! {render,
                  maps:get(characters, World), maps:get(enemies, World),
                  maps:get(shops, World), maps:get(inns, World),
                  maps:get(log, World), maps:get(moves, World)}.

run_frames(Worlds) ->
    {CapturePid, DisplayPid} = start_display(40),
    lists:foreach(fun(World) -> send_render(DisplayPid, World) end, Worlds),
    await_updates(CapturePid, length(Worlds)),
    timer:sleep(60),
    stop_and_read(CapturePid, DisplayPid).

updates(Text) ->
    tl(string:split(Text, ?HIDE, all)).

last_update(Text) ->
    lists:last(updates(Text)).

occurrences(Text, What) ->
    length(string:split(Text, What, all)) - 1.

new_screen() ->
    #{cursor => {1, 1}, style => "", cells => #{}}.

screen_of(Text) ->
    paint_stream(Text, new_screen()).

used_screen() ->
    Filled = paint_stream(lists:flatten([["\e[", integer_to_list(Row), ";1H", lists:duplicate(85, $#)]
                                         || Row <- lists:seq(1, 74)]), new_screen()),
    Boot = "\e[1;1HStarting CMD RPG...\e[2;1HWorld is alive. Watch the heroes fight!"
           "\e[3;1HPress Ctrl+C to stop.\e[5;1H",
    paint_stream(Boot, Filled).

paint_stream([], Screen) ->
    Screen;
paint_stream([$\e, $[ | Rest], Screen) ->
    {Params, Final, Tail} = csi(Rest, []),
    paint_stream(Tail, csi_op(Params, Final, Screen));
paint_stream([Char | Rest], Screen) ->
    paint_stream(Rest, put_char(Char, Screen)).

csi([Char | Rest], Acc) when Char >= $@ ->
    {lists:reverse(Acc), Char, Rest};
csi([Char | Rest], Acc) ->
    csi(Rest, [Char | Acc]).

csi_op(Params, $H, Screen) ->
    Screen#{cursor := cursor_of(Params)};
csi_op("2", $J, Screen) ->
    Screen#{cells := #{}};
csi_op(_Params, $K, Screen) ->
    erase_right(Screen);
csi_op("0", $m, Screen) ->
    Screen#{style := ""};
csi_op(Params, $m, Screen) ->
    Screen#{style := maps:get(style, Screen) ++ "\e[" ++ Params ++ "m"};
csi_op(_Params, _Final, Screen) ->
    Screen.

cursor_of("") ->
    {1, 1};
cursor_of(Params) ->
    [Row, Col] = string:split(Params, ";"),
    {list_to_integer(Row), list_to_integer(Col)}.

erase_right(Screen) ->
    {Row, Col} = maps:get(cursor, Screen),
    Kept = maps:filter(fun({R, C}, _Cell) -> R =/= Row orelse C < Col end,
                       maps:get(cells, Screen)),
    Screen#{cells := Kept}.

put_char(Char, Screen) ->
    {Row, Col} = maps:get(cursor, Screen),
    Cells = maps:put({Row, Col}, {maps:get(style, Screen), Char}, maps:get(cells, Screen)),
    Screen#{cells := Cells, cursor := {Row, Col + 1}}.

painted_rows(Screen) ->
    lists:usort([Row || {Row, _Col} <- maps:keys(maps:get(cells, Screen))]).

row_width(Screen, Row) ->
    lists:max([0 | [Col || {R, Col} <- maps:keys(maps:get(cells, Screen)), R =:= Row]]).

row_text(Screen, Row) ->
    [char_at(Screen, Row, Col) || Col <- lists:seq(1, row_width(Screen, Row))].

char_at(Screen, Row, Col) ->
    element(2, cell_at(Screen, Row, Col)).

style_at(Screen, Row, Col) ->
    element(1, cell_at(Screen, Row, Col)).

cell_at(Screen, Row, Col) ->
    maps:get({Row, Col}, maps:get(cells, Screen), {"", $\s}).

screen_rows(Screen) ->
    [row_text(Screen, Row) || Row <- lists:seq(1, ?SCREEN_ROWS)].

screen_text(Screen) ->
    string:join(screen_rows(Screen), "\n").

row_holding(Screen, Needle) ->
    [Row || Row <- lists:seq(1, ?SCREEN_ROWS),
            string:find(row_text(Screen, Row), Needle) =/= nomatch].

grid_cell(Screen, X, Y) ->
    cell_at(Screen, ?GRID_TOP_ROW + Y, ?GRID_LEFT_COL + 2 * X).

grid_row("  |" ++ Rest) ->
    length(Rest) > 0 andalso lists:last(Rest) =:= $|;
grid_row(_) ->
    false.

border_row("  +" ++ Rest) ->
    length(Rest) > 0 andalso lists:last(Rest) =:= $+;
border_row(_) ->
    false.

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

rich_world() ->
    EnemyPid = test_support:fake_pid(),
    world(#{characters => rich_characters(),
            enemies => #{EnemyPid => test_support:enemy_info(
                #{name => "Goblin", level => 2, x => 6, y => 6})},
            shops => [#{name => "Ye Olde Armoury", x => 7, y => 7}],
            inns => [#{name => "The Rusty Flagon", x => 8, y => 8}],
            log => [io_lib:format("ev~2..0b", [N]) || N <- lists:seq(1, 15)],
            moves => 7}).

solo_hero(Name, Overrides) ->
    test_support:char_info(maps:merge(#{name => Name, level => 1, x => 3, y => 4}, Overrides)).

solo_world(Name, Overrides) ->
    Pid = test_support:fake_pid(),
    world(#{characters => #{Pid => solo_hero(Name, Overrides)}}).

goblins(Count, Y) ->
    maps:from_list([{test_support:fake_pid(),
                     test_support:enemy_info(#{name => "Goblin", x => X, y => Y})}
                    || X <- lists:seq(1, Count)]).

first_update_paints_the_whole_frame_test() ->
    Text = run_frames([rich_world()]),
    ?assertEqual(1, length(updates(Text))),
    ?assert(lists:prefix(?HIDE ++ "\e[H\e[2J", Text)),
    Screen = screen_of(Text),
    Rows = screen_text(Screen),
    ?assertEqual([1], row_holding(Screen, "=== CMD RPG [7 moves] ===")),
    ?assertShows(Rows, "@ Hero  & Party  ! Enemy  $ Shop  H Inn"),
    ?assertShows(Rows, "Heroes:"),
    ?assertShows(Rows, "--- Party: Aldric + Brom ---"),
    ?assertShows(Rows, "    & Aldric (Hum)"),
    ?assertShows(Rows, "      + Brom (Dwf)"),
    ?assertShows(Rows, "    @ Durnir (Trt)"),
    ?assertShows(Rows, "    @ Nyx (Hum)"),
    ?assertHides(Rows, "Cedric"),
    ?assertShows(Rows, "+2ATK +3DEF"),
    ?assertShows(Rows, "+4DEF"),
    [BromRow] = row_holding(Screen, "      + Brom"),
    ?assert(lists:suffix("g +2ATK", row_text(Screen, BromRow))),
    ?assertShows(Rows, "Enemies on map: 1"),
    ?assertEqual([lists:flatten(io_lib:format("    > ev~2..0b", [N])) || N <- lists:seq(4, 15)],
                 [row_text(Screen, Row) || Row <- row_holding(Screen, "> ")]),
    ?assertHides(Rows, "ev03"),
    GridRows = [Line || Line <- screen_rows(Screen), grid_row(Line)],
    ?assertEqual(40, length(GridRows)),
    lists:foreach(fun(Line) -> ?assertEqual(84, length(Line)) end, GridRows),
    ?assertEqual(2, length([Line || Line <- screen_rows(Screen), border_row(Line)])),
    ?assertEqual([2, 43], row_holding(Screen, "+---")).

first_update_erases_everything_the_terminal_already_showed_test() ->
    Text = run_frames([world(#{log => ["one"]})]),
    Clean = screen_of(Text),
    Used = paint_stream(Text, used_screen()),
    ?assertHides(screen_text(Used), "Watch the heroes fight!"),
    ?assertHides(screen_text(Used), "#"),
    ?assertEqual(maps:get(cells, Clean), maps:get(cells, Used)).

party_map_cell_is_single_glyph_test() ->
    Screen = screen_of(run_frames([world(#{characters => rich_characters(), moves => 3})])),
    Grid = string:join([Line || Line <- screen_rows(Screen), grid_row(Line)], "\n"),
    ?assertEqual(1, occurrences(Grid, "&")),
    ?assertEqual(3, occurrences(Grid, "@")),
    ?assertEqual(1, occurrences(Grid, "+")).

empty_frame_shows_quiet_log_test() ->
    Screen = screen_of(run_frames([world(#{})])),
    Rows = screen_text(Screen),
    ?assertShows(Rows, "=== CMD RPG [0 moves] ==="),
    ?assertShows(Rows, "Heroes:"),
    ?assertShows(Rows, "Enemies on map: 0"),
    ?assertShows(Rows, "> (quiet...)").

short_log_shows_all_events_test() ->
    Screen = screen_of(run_frames([world(#{log => ["first", "second", "third"], moves => 1})])),
    Rows = screen_text(Screen),
    ?assertShows(Rows, "> first"),
    ?assertShows(Rows, "> second"),
    ?assertShows(Rows, "> third"),
    ?assertHides(Rows, "(quiet...)").

existing_entry_points_still_work_test() ->
    {CapturePid, DisplayPid} = capturing_io(fun() -> display:start(self()) end),
    ?assert(is_process_alive(DisplayPid)),
    DisplayPid ! {render, rich_characters(), goblins(4, 12), [], [], ["one"], 5},
    await_updates(CapturePid, 1),
    Rows = screen_text(screen_of(stop_and_read(CapturePid, DisplayPid))),
    ?assertShows(Rows, "=== CMD RPG [5 moves] ==="),
    ?assertShows(Rows, "Enemies on map: 4"),
    ?assertShows(Rows, "> one").

start_paints_nothing_before_the_first_render_test() ->
    {CapturePid, DisplayPid} = start_display(40),
    timer:sleep(120),
    ?assertEqual("", test_support:captured_text(CapturePid)),
    send_render(DisplayPid, world(#{moves => 2})),
    await_updates(CapturePid, 1),
    Text = stop_and_read(CapturePid, DisplayPid),
    ?assert(lists:prefix(?HIDE ++ "\e[H\e[2J", Text)),
    ?assertShows(screen_text(screen_of(Text)), "=== CMD RPG [2 moves] ===").

each_display_paints_its_own_first_frame_in_full_test() ->
    First = run_frames([world(#{moves => 1})]),
    Second = run_frames([world(#{moves => 1})]),
    ?assertEqual(First, Second),
    ?assertEqual(1, occurrences(Second, "\e[2J")).

first_update_is_the_only_full_repaint_test() ->
    Text = run_frames([rich_world(),
                       maps:merge(rich_world(), #{moves => 8}),
                       maps:merge(rich_world(), #{moves => 9})]),
    ?assertEqual(1, occurrences(Text, "\e[H")),
    ?assertEqual(0, occurrences(Text, "\e[J")),
    ?assertEqual(1, occurrences(Text, "\e[2J")).

every_tick_puts_one_bracketed_update_on_the_wire_test() ->
    Worlds = [world(#{moves => N}) || N <- lists:seq(1, 20)],
    Text = run_frames(Worlds),
    Updates = updates(Text),
    ?assertEqual(20, length(Updates)),
    lists:foreach(fun(Update) -> ?assert(lists:suffix(?PARK, Update)) end, Updates),
    ?assertEqual(Text, ?HIDE ++ string:join(Updates, ?HIDE)),
    ?assertEqual(20, occurrences(Text, "\e[?25h")).

an_unchanged_world_paints_nothing_but_the_park_test() ->
    World = rich_world(),
    Text = run_frames([World, World]),
    ?assertEqual(?PARK, last_update(Text)),
    Twice = screen_of(Text),
    Once = screen_of(run_frames([World])),
    ?assertEqual(maps:get(cells, Once), maps:get(cells, Twice)).

later_updates_repaint_only_what_changed_test() ->
    Before = world(#{characters => rich_characters(), enemies => goblins(6, 20),
                     log => ["one"], moves => 11}),
    Movers = maps:map(fun(_Pid, Info) -> Info#{x := maps:get(x, Info) + 1} end,
                      maps:get(characters, Before)),
    After = maps:merge(Before, #{characters => Movers, enemies => goblins(6, 21),
                                 log => ["one", "two", "three"], moves => 12}),
    Text = run_frames([Before, After]),
    Update = last_update(Text),
    ?assert(length(Update) < 6000),
    ?assertEqual(0, occurrences(Update, "\e[2J")),
    ?assertEqual(0, occurrences(Update, "\e[J")),
    ?assertEqual(0, length([Char || Char <- Update, lists:member(Char, "ABCD")])),
    ?assertShows(Update, "\e[1;15H"),
    ?assertShows(Update, "two"),
    ?assertHides(Update, "Heroes:"),
    ?assertHides(Update, "Hero  "),
    Screen = screen_of(Text),
    ?assertShows(screen_text(Screen), "> three"),
    ?assertEqual(["    > one", "    > two", "    > three"],
                 [row_text(Screen, Row) || Row <- row_holding(Screen, "> ")]),
    assert_far_apart_changes_repaint_only_their_cells().

assert_far_apart_changes_repaint_only_their_cells() ->
    Shops = world(#{shops => [#{name => "West", x => 0, y => 20}, #{name => "East", x => 39, y => 20}],
                    moves => 4}),
    Inns = maps:merge(Shops, #{shops => [], inns => maps:get(shops, Shops)}),
    Blue = "\e[0m\e[1m\e[34mH \e[0m",
    ?assertEqual("\e[23;4H" ++ Blue ++ "\e[23;82H" ++ Blue ++ ?PARK,
                 lists:flatten(last_update(run_frames([Shops, Inns])))).

the_screen_matches_a_full_repaint_of_the_same_world_test() ->
    Steps = [world(#{characters => rich_characters(), enemies => goblins(10, 30),
                     log => ["one"], moves => 1}),
             world(#{characters => rich_characters(), enemies => goblins(9, 31),
                     log => [], moves => 2}),
             rich_world()],
    Differential = screen_of(run_frames(Steps)),
    Full = screen_of(run_frames([lists:last(Steps)])),
    ?assertEqual(maps:get(cells, Full), maps:get(cells, Differential)).

colours_survive_a_differential_repaint_test() ->
    Heroes = rich_characters(),
    Before = world(#{characters => Heroes, enemies => goblins(3, 30),
                     shops => [#{name => "Shop", x => 7, y => 7}],
                     inns => [#{name => "Inn", x => 8, y => 8}], moves => 1}),
    After = maps:merge(Before, #{enemies => goblins(3, 31), moves => 2}),
    Screen = screen_of(run_frames([Before, After])),
    ?assertEqual({"\e[2m", $.}, grid_cell(Screen, 20, 30)),
    ?assertEqual({"\e[1m\e[31m", $!}, grid_cell(Screen, 1, 31)),
    ?assertEqual({"\e[1m\e[33m", $$}, grid_cell(Screen, 7, 7)),
    ?assertEqual({"\e[1m\e[34m", $H}, grid_cell(Screen, 8, 8)),
    ?assertEqual({"\e[1m\e[35m", $&}, grid_cell(Screen, 1, 1)),
    ?assertEqual({"\e[1m\e[33m", $@}, grid_cell(Screen, 2, 2)),
    ?assertEqual({"\e[1m\e[32m", $@}, grid_cell(Screen, 3, 3)),
    ?assertEqual({"\e[2m\e[36m", $+}, grid_cell(Screen, 5, 5)),
    ?assertEqual("\e[1m\e[36m", style_at(Screen, 1, 1)),
    [PartyRow] = row_holding(Screen, "--- Party:"),
    ?assertEqual("\e[1m\e[36m", style_at(Screen, PartyRow, 3)),
    [EnemyRow] = row_holding(Screen, "Enemies on map:"),
    ?assertEqual("\e[2m\e[31m", style_at(Screen, EnemyRow, 3)),
    [LogRow] = row_holding(Screen, "Log:"),
    ?assertEqual("\e[1m\e[33m", style_at(Screen, LogRow, 3)),
    ?assertEqual(["\e[2m", "\e[2m"],
                 [style_at(Screen, Row, 3) || Row <- row_holding(Screen, "+---")]),
    assert_hp_colours(Screen).

hp_colour_changes_exactly_at_a_third_and_two_thirds_test() ->
    Heroes = maps:from_list([{test_support:fake_pid(), solo_hero(Name, #{hp => Hp, max_hp => 30})}
                             || {Name, Hp} <- [{"Third", 10}, {"Twothirds", 20}, {"Under", 9}]]),
    Screen = screen_of(run_frames([world(#{characters => Heroes})])),
    ?assertEqual("\e[33m", hp_style(Screen, "Third (")),
    ?assertEqual("\e[32m", hp_style(Screen, "Twothirds (")),
    ?assertEqual("\e[31m", hp_style(Screen, "Under (")).

every_part_keeps_its_colour_through_a_differential_repaint_test() ->
    {Busy, Quiet} = styled_worlds(),
    QuietScreen = screen_of(run_frames([Busy, Quiet])),
    ?assertEqual(styled_table() ++ [{52, [{"", "    "}, {"\e[2m", "> (quiet...)"}]}],
                 table_of(QuietScreen)),
    lists:foreach(fun(Row) ->
        ?assertEqual({"\e[2m", $|}, cell_at(QuietScreen, Row, 3)),
        ?assertEqual({"\e[2m", $|}, cell_at(QuietScreen, Row, 84))
    end, lists:seq(?GRID_TOP_ROW, ?GRID_TOP_ROW + 39)),
    BusyScreen = screen_of(run_frames([Quiet, Busy])),
    ?assertEqual([{"", "    "}, {"\e[2m", "> "}, {"", "one"}], style_runs(BusyScreen, 52)).

styled_worlds() ->
    LeaderPid = test_support:fake_pid(),
    FollowerPid = test_support:fake_pid(),
    Heroes = #{
        LeaderPid => solo_hero("Aldric", #{level => 5, hp => 40, max_hp => 40, gold => 12,
                                           attack_bonus => 2, defense_bonus => 3,
                                           x => 1, y => 1, party_role => leader,
                                           follower_pids => [FollowerPid]}),
        FollowerPid => solo_hero("Brom", #{race => dwarf, level => 3, hp => 9, max_hp => 20,
                                           gold => 3, x => 11, y => 1,
                                           party_role => follower}),
        test_support:fake_pid() => solo_hero("Elara", #{level => 2, hp => 19, max_hp => 20,
                                                        gold => 7, x => 3, y => 1})},
    Quiet = world(#{characters => Heroes,
                    enemies => #{test_support:fake_pid() =>
                                     test_support:enemy_info(#{x => 5, y => 1})},
                    shops => [#{name => "Shop", x => 7, y => 1}],
                    inns => [#{name => "Inn", x => 9, y => 1}], moves => 2}),
    Busy = maps:merge(Quiet, #{enemies => goblins(3, 30), log => ["one"], moves => 1}),
    {Busy, Quiet}.

styled_table() ->
    Dim = "\e[2m",
    Dot = {Dim, ". "},
    [{1, [{"\e[1m\e[36m", "=== CMD RPG [2 moves] ==="}]},
     {2, [{"", "  "}, {Dim, "+" ++ lists:duplicate(81, $-) ++ "+"}]},
     {4, [{"", "  "}, {Dim, "|. "}, {"\e[1m\e[35m", "& "}, Dot, {"\e[1m\e[32m", "@ "}, Dot,
          {"\e[1m\e[31m", "! "}, Dot, {"\e[1m\e[33m", "$ "}, Dot, {"\e[1m\e[34m", "H "}, Dot,
          {"\e[2m\e[36m", "+ "}, {Dim, lists:append(lists:duplicate(28, ". ")) ++ "|"}]},
     {43, [{"", "  "}, {Dim, "+" ++ lists:duplicate(81, $-) ++ "+"}]},
     {44, [{"", "  "}, {"\e[1m\e[32m", "@ "}, {"", "Hero  "}, {"\e[1m\e[32m", "& "},
           {"", "Party  "}, {"\e[1m\e[31m", "! "}, {"", "Enemy  "}, {"\e[1m\e[33m", "$ "},
           {"", "Shop  "}, {"\e[1m\e[34m", "H "}, {"", "Inn"}]},
     {45, [{"", "  "}, {"\e[1m\e[36m", "Heroes:"}]},
     {46, [{"", "  "}, {"\e[1m\e[36m", "--- Party: Aldric + Brom ---"}]},
     {47, [{"", "    "}, {"\e[36m", "& "}, {"\e[1m", "Aldric"}, {"", " (Hum) Lv5  "},
           {"\e[32m", "HP:40/40"}, {"", "  XP:0/11  "}, {"\e[33m", "12g"},
           {"", " +2ATK +3DEF"}]},
     {48, [{"", "      "}, {Dim, "+ "}, {"\e[1m", "Brom"}, {"", " (Dwf) Lv3  "},
           {"\e[33m", "HP:9/20"}, {"", "  XP:0/7  "}, {"\e[33m", "3g"}]},
     {49, [{"", "    "}, {"\e[32m", "@ "}, {"\e[1m", "Elara"}, {"", " (Hum) Lv2  "},
           {"\e[32m", "HP:19/20"}, {"", "  XP:0/5  "}, {"\e[33m", "7g"}]},
     {50, [{"", "  "}, {"\e[2m\e[31m", "Enemies on map: 1"}]},
     {51, [{"", "  "}, {"\e[1m\e[33m", "Log:"}]}].

table_of(Screen) ->
    [{Row, style_runs(Screen, Row)}
     || Row <- painted_rows(Screen), Row < ?GRID_TOP_ROW orelse Row > 42 orelse Row =:= 4].

style_runs(Screen, Row) ->
    Cells = [cell_at(Screen, Row, Col) || Col <- lists:seq(1, row_width(Screen, Row))],
    lists:reverse(lists:foldl(fun merge_run/2, [], Cells)).

merge_run({Style, Char}, [{Style, Text} | Runs]) ->
    [{Style, Text ++ [Char]} | Runs];
merge_run({Style, Char}, Runs) ->
    [{Style, [Char]} | Runs].

hp_style(Screen, Name) ->
    [Row] = row_holding(Screen, Name),
    style_at(Screen, Row, hp_column(Screen, Row)).

assert_hp_colours(Screen) ->
    [Healthy] = row_holding(Screen, "Nyx ("),
    [Hurt] = row_holding(Screen, "+ Brom ("),
    [Dying] = row_holding(Screen, "Durnir ("),
    ?assertEqual("\e[32m", style_at(Screen, Healthy, hp_column(Screen, Healthy))),
    ?assertEqual("\e[33m", style_at(Screen, Hurt, hp_column(Screen, Hurt))),
    ?assertEqual("\e[31m", style_at(Screen, Dying, hp_column(Screen, Dying))).

hp_column(Screen, Row) ->
    Text = row_text(Screen, Row),
    [Head | _] = string:split(Text, "HP:"),
    length(Head) + 1.

nothing_stale_is_left_when_a_section_shrinks_test() ->
    assert_vacated_cell_shows_a_dot(),
    assert_shrinking_log_leaves_no_stale_lines(),
    assert_shrinking_roster_leaves_no_stale_lines().

assert_vacated_cell_shows_a_dot() ->
    Before = solo_world("Roland", #{x => 3, y => 4}),
    Pid = hd(maps:keys(maps:get(characters, Before))),
    After = Before#{characters := #{Pid => solo_hero("Roland", #{x => 9, y => 4})}},
    Screen = screen_of(run_frames([Before, After])),
    ?assertEqual({"\e[2m", $.}, grid_cell(Screen, 3, 4)),
    ?assertEqual({"\e[1m\e[32m", $@}, grid_cell(Screen, 9, 4)).

assert_shrinking_log_leaves_no_stale_lines() ->
    Busy = world(#{log => [io_lib:format("ev~2..0b", [N]) || N <- lists:seq(1, 12)]}),
    Quiet = maps:merge(Busy, #{log => []}),
    Screen = screen_of(run_frames([Busy, Quiet])),
    Rows = screen_text(Screen),
    ?assertShows(Rows, "> (quiet...)"),
    ?assertHides(Rows, "ev"),
    [QuietRow] = row_holding(Screen, "(quiet...)"),
    ?assertEqual([], [Row || Row <- painted_rows(Screen), Row > QuietRow]).

assert_shrinking_roster_leaves_no_stale_lines() ->
    Heroes = rich_characters(),
    [Gone | _] = [Pid || {Pid, Info} <- maps:to_list(Heroes),
                         maps:get(name, Info) =:= "Elara"],
    Before = world(#{characters => Heroes, log => ["one"]}),
    After = Before#{characters := maps:remove(Gone, Heroes)},
    Screen = screen_of(run_frames([Before, After])),
    Rows = screen_text(Screen),
    ?assertHides(Rows, "Elara"),
    ?assertEqual(1, occurrences(Rows, "Enemies on map:")),
    ?assertEqual(1, occurrences(Rows, "> one")),
    [LastRow | _] = lists:reverse(painted_rows(Screen)),
    ?assertEqual(LastRow, hd(row_holding(Screen, "> one"))).

a_narrowing_line_leaves_no_stale_text_test() ->
    Counted = world(#{enemies => goblins(10, 30)}),
    Killed = Counted#{enemies := goblins(9, 30)},
    CountScreen = screen_of(run_frames([Counted, Killed])),
    [CountRow] = row_holding(CountScreen, "Enemies on map:"),
    ?assertEqual("  Enemies on map: 9", row_text(CountScreen, CountRow)),
    Rich = solo_world("Roland", #{gold => 14}),
    Pid = hd(maps:keys(maps:get(characters, Rich))),
    Poorer = Rich#{characters := #{Pid => solo_hero("Roland", #{gold => 9})}},
    GoldScreen = screen_of(run_frames([Rich, Poorer])),
    [GoldRow] = row_holding(GoldScreen, "Roland"),
    ?assert(lists:suffix("9g", row_text(GoldScreen, GoldRow))).

the_frame_never_scrolls_test() ->
    Crowd = maps:from_list([{test_support:fake_pid(),
                             solo_hero(io_lib:format("Hero~2..0b", [N]), #{})}
                            || N <- lists:seq(1, 20)]),
    Tall = world(#{characters => Crowd,
                   log => [io_lib:format("ev~2..0b", [N]) || N <- lists:seq(1, 12)]}),
    Text = run_frames([Tall]),
    Screen = screen_of(Text),
    ?assertEqual(74, lists:last(painted_rows(Screen))),
    ?assertEqual(0, occurrences(Text, "\n")),
    ?assert(lists:suffix(?PARK, Text)),
    ?assertEqual([], [Row || Row <- painted_rows(Screen), Row > 74]),
    Wide = screen_of(run_frames([world(#{log => [lists:duplicate(200, $x)]})])),
    ?assertEqual([], [Row || Row <- painted_rows(Wide), row_width(Wide, Row) > 85]),
    ?assertEqual(85, row_width(Wide, lists:last(painted_rows(Wide)))).

every_update_hides_and_parks_the_cursor_test() ->
    Text = run_frames([rich_world(), world(#{moves => 1}), rich_world()]),
    lists:foreach(fun(Update) ->
        ?assert(lists:suffix(?PARK, Update)),
        ?assertEqual(1, occurrences(Update, "\e[?25h"))
    end, updates(Text)),
    Screen = screen_of(Text),
    ?assertEqual([], [Row || Row <- painted_rows(Screen), Row >= 75]).

run_sized(Steps) ->
    [{FirstSize, _} | _] = Steps,
    {CapturePid, DisplayPid} = capturing_io(FirstSize, fun() -> display:start(fake_world, 40) end),
    lists:foldl(fun({Size, World}, Sent) ->
        test_support:resize(CapturePid, Size),
        send_render(DisplayPid, World),
        await_updates(CapturePid, Sent + 1),
        Sent + 1
    end, 0, Steps),
    stop_and_read(CapturePid, DisplayPid).

hero_at(Name, Level, Role, {X, Y}) ->
    solo_hero(Name, #{level => Level, party_role => Role, x => X, y => Y}).

heroes_in_parties(Pairs) ->
    Names = ["Aldric", "Brom", "Cedric", "Durnir", "Elara", "Nyx"],
    Pids = [test_support:fake_pid() || _ <- Names],
    Roles = [role_in_pairs(Index, Pairs) || Index <- lists:seq(1, 6)],
    maps:from_list([{Pid, party_info(hero_at(Name, 1, Role, {Index, Index}), Role, Pid, Pids)}
                    || {Index, {Name, Pid, Role}} <- lists:enumerate(lists:zip3(Names, Pids, Roles))]).

role_in_pairs(Index, Pairs) when Index > 2 * Pairs -> solo;
role_in_pairs(Index, _Pairs) when Index rem 2 =:= 1 -> leader;
role_in_pairs(_Index, _Pairs) -> follower.

party_info(Info, leader, Pid, Pids) ->
    Info#{follower_pids => [next_pid(Pid, Pids)]};
party_info(Info, _Role, _Pid, _Pids) ->
    Info.

next_pid(Pid, [Pid, Next | _]) -> Next;
next_pid(Pid, [_ | Rest]) -> next_pid(Pid, Rest).

town_world(Pairs, Log) ->
    world(#{characters => heroes_in_parties(Pairs), enemies => goblins(12, 30),
            shops => [#{name => "S" ++ [Char], x => 30, y => Y} || {Char, Y} <- [{$a, 1}, {$b, 2}, {$c, 3}]],
            inns => [#{name => "I" ++ [Char], x => 35, y => Y} || {Char, Y} <- [{$a, 1}, {$b, 2}]],
            log => Log, moves => 3}).

events(Count) ->
    [lists:flatten(io_lib:format("ev~2..0b", [N])) || N <- lists:seq(1, Count)].

log_rows(Screen) ->
    [{Row, row_text(Screen, Row)} || Row <- row_holding(Screen, "    > ")].

assert_within(Screen, Cols, Rows) ->
    ?assertEqual([], [Row || Row <- painted_rows(Screen), Row >= Rows]),
    ?assertEqual([], [Row || Row <- painted_rows(Screen), row_width(Screen, Row) > Cols]).

an_80x24_terminal_shows_every_section_test() ->
    Text = run_sized([{{80, 24}, town_world(0, [])}]),
    ?assert(lists:prefix(?HIDE ++ "\e[H\e[2J", Text)),
    ?assert(lists:suffix("\e[24;1H\e[?25h", Text)),
    Screen = screen_of(Text),
    Border = "  +-------------+",
    ?assertEqual(["=== CMD RPG [3 moves] ===", Border],
                 [row_text(Screen, Row) || Row <- [1, 2]]),
    ?assert(lists:all(fun(Row) -> grid_row(row_text(Screen, Row)) andalso
                                  length(row_text(Screen, Row)) =:= 16 end,
                      lists:seq(3, 8))),
    ?assertEqual([Border, "  @ Hero  & Party  ! Enemy  $ Shop  H Inn", "  Heroes:"],
                 [row_text(Screen, Row) || Row <- [9, 10, 11]]),
    ?assert(lists:all(fun(Row) -> lists:prefix("    @ ", row_text(Screen, Row)) end,
                      lists:seq(12, 17))),
    ?assertEqual(["  Enemies on map: 12", "  Log:", "    > (quiet...)"],
                 [row_text(Screen, Row) || Row <- [18, 19, 20]]),
    assert_within(Screen, 80, 24).

the_log_truncates_to_the_rows_that_are_left_test() ->
    Log = events(12),
    Solo = screen_of(run_sized([{{80, 24}, town_world(0, Log)}])),
    ?assertEqual([{20, "    > ev09"}, {21, "    > ev10"}, {22, "    > ev11"}, {23, "    > ev12"}],
                 log_rows(Solo)),
    OneParty = screen_of(run_sized([{{80, 24}, town_world(1, Log)}])),
    ?assertEqual([{21, "    > ev10"}, {22, "    > ev11"}, {23, "    > ev12"}], log_rows(OneParty)),
    Parties = screen_of(run_sized([{{80, 24}, town_world(3, Log)}])),
    ?assertEqual([{23, "    > ev12"}], log_rows(Parties)),
    lists:foreach(fun(Name) -> ?assertShows(screen_text(Parties), " " ++ Name ++ " (") end,
                  ["Aldric", "Brom", "Cedric", "Durnir", "Elara", "Nyx"]),
    assert_within(Parties, 80, 24).

fold_cell(Heroes, Extra) ->
    World = maps:merge(world(#{characters => maps:from_list([{test_support:fake_pid(), Hero}
                                                             || Hero <- Heroes])}), Extra),
    Screen = screen_of(run_sized([{{80, 24}, World}])),
    {cell_at(Screen, 3, 4), cell_at(Screen, 3, 6)}.

several_world_cells_fold_into_one_drawn_cell_test() ->
    Things = #{enemies => #{test_support:fake_pid() => test_support:enemy_info(#{x => 6, y => 6})},
               shops => [#{name => "Shop", x => 7, y => 0}]},
    Lv1 = hero_at("Low", 1, solo, {0, 0}),
    ?assertEqual({{"\e[1m\e[32m", $@}, {"\e[1m\e[33m", $$}}, fold_cell([Lv1], Things)),
    Lv5 = hero_at("High", 5, solo, {3, 3}),
    ?assertMatch({{"\e[1m\e[35m", $@}, _}, fold_cell([Lv1, Lv5], Things)),
    Leader = hero_at("Lead", 1, leader, {0, 0}),
    ?assertMatch({{"\e[1m\e[32m", $&}, _}, fold_cell([Leader, Lv5], #{})),
    ?assertMatch({{"\e[2m\e[36m", $+}, _}, fold_cell([hero_at("Follow", 5, follower, {0, 0})], #{})).

a_large_terminal_shows_the_world_one_to_one_test() ->
    World = maps:merge(town_world(0, events(15)), #{moves => 7}),
    LargeText = run_sized([{{85, 75}, World}]),
    ?assert(lists:suffix("\e[75;1H\e[?25h", LargeText)),
    Large = screen_of(LargeText),
    ?assertEqual(40, length([Line || Line <- screen_rows(Large), grid_row(Line)])),
    ?assertEqual([85, 85], [length(Line) || Line <- screen_rows(Large), border_row(Line)]),
    ?assertEqual(12, length(log_rows(Large))),
    Wide = screen_of(run_sized([{{120, 40}, World}])),
    ?assertEqual(20, length([Line || Line <- screen_rows(Wide), grid_row(Line)])),
    ?assertEqual([45, 45], [length(Line) || Line <- screen_rows(Wide), border_row(Line)]),
    assert_within(Wide, 120, 40).

resizing_mid_game_re_renders_at_the_new_size_test() ->
    [W1, W2, W3, W4] = [maps:merge(rich_world(), #{moves => N}) || N <- [1, 2, 3, 4]],
    Text = run_sized([{{85, 75}, W1}, {{80, 24}, W2}, {{80, 24}, W3}, {{85, 75}, W4}]),
    [_, Shrunk, Steady, Grown] = updates(Text),
    ?assert(lists:prefix("\e[H\e[2J", Shrunk)),
    ?assertEqual(0, occurrences(Steady, "\e[2J")),
    ?assert(lists:suffix("\e[24;1H\e[?25h", Steady)),
    ?assert(lists:prefix("\e[H\e[2J", Grown)),
    AtSmall = screen_of(run_sized([{{85, 75}, W1}, {{80, 24}, W3}])),
    ?assertEqual(maps:get(cells, screen_of(run_sized([{{80, 24}, W3}]))), maps:get(cells, AtSmall)),
    ?assertEqual(maps:get(cells, screen_of(run_sized([{{85, 75}, W4}]))),
                 maps:get(cells, screen_of(Text))).

a_terminal_too_small_gets_a_notice_test() ->
    World = rich_world(),
    Text = run_sized([{{80, 24}, World}, {{19, 24}, World}, {{19, 24}, World},
                      {{19, 24}, maps:merge(World, #{moves => 8})}]),
    [_, Notice, Quiet1, Quiet2] = updates(Text),
    ?assert(lists:prefix("\e[H\e[2J", Notice)),
    ?assertEqual(["\e[24;1H\e[?25h", "\e[24;1H\e[?25h"], [Quiet1, Quiet2]),
    Screen = screen_of(Text),
    ?assertEqual([1], painted_rows(Screen)),
    ?assertEqual("Terminal too small", row_text(Screen, 1)),
    Short = run_sized([{{80, 9}, World}]),
    ?assert(lists:suffix("\e[9;1H\e[?25h", Short)),
    ?assertEqual("Terminal too small", row_text(screen_of(Short), 1)),
    ?assertEqual("Terminal t", row_text(screen_of(run_sized([{{10, 5}, World}])), 1)),
    Back = screen_of(run_sized([{{19, 24}, World}, {{80, 24}, World}])),
    ?assertEqual([1], row_holding(Back, "=== CMD RPG [7 moves] ===")),
    ?assertHides(screen_text(Back), "Terminal too small").

at_the_minimum_size_the_frame_is_clipped_test() ->
    Text = run_sized([{{20, 10}, town_world(0, events(3))}]),
    Screen = screen_of(Text),
    ?assertEqual(["  +---+", "  +---+"], [row_text(Screen, Row) || Row <- [2, 4]]),
    ?assert(grid_row(row_text(Screen, 3))),
    ?assertEqual("  @ Hero  & Party  !", row_text(Screen, 5)),
    ?assertEqual("  Heroes:", row_text(Screen, 6)),
    ?assertEqual(lists:seq(1, 9), painted_rows(Screen)),
    ?assertEqual(20, row_width(Screen, 7)),
    ?assertEqual(0, occurrences(Text, "\n")),
    assert_within(Screen, 20, 10).

an_unreadable_size_falls_back_to_85x75_test() ->
    Text = run_frames([rich_world()]),
    ?assert(lists:suffix(?PARK, Text)),
    ?assertEqual(40, length([Line || Line <- screen_rows(screen_of(Text)), grid_row(Line)])).
