-module(world_server_tests).
-include_lib("eunit/include/eunit.hrl").

pos_of(Pid, State) ->
    Info = maps:get(Pid, maps:get(characters, State)),
    {maps:get(x, Info), maps:get(y, Info)}.

char_at(Pid, State) ->
    maps:get(Pid, maps:get(characters, State)).

log_of(State) ->
    [lists:flatten(Entry) || Entry <- maps:get(event_log, State)].

move_cast(Pid, Direction, State) ->
    world_server:handle_cast({move, Pid, Direction}, State).

get_state_reply_test() ->
    State = test_support:world_state(),
    ?assertEqual({reply, State, State}, world_server:handle_call(get_state, self(), State)).

unknown_call_replies_ok_test() ->
    State = test_support:world_state(),
    ?assertEqual({reply, ok, State}, world_server:handle_call(garbage, self(), State)).

unknown_cast_ignored_test() ->
    State = test_support:world_state(),
    ?assertEqual({noreply, State}, world_server:handle_cast(garbage, State)).

unknown_info_ignored_test() ->
    State = test_support:world_state(),
    ?assertEqual({noreply, State}, world_server:handle_info(garbage, State)).

get_my_state_known_char_test() ->
    Pid = test_support:fake_pid(),
    Info = test_support:char_info(#{x => 3, y => 4}),
    EnemyPid = test_support:fake_pid(),
    Enemy = test_support:enemy_info(#{x => 8, y => 9}),
    State = test_support:world_state(#{
        characters => #{Pid => Info},
        enemies => #{EnemyPid => Enemy},
        shops => [#{name => "S", x => 1, y => 2}],
        inns => [#{name => "I", x => 5, y => 6}]}),
    {reply, Reply, State} = world_server:handle_call({get_my_state, Pid}, self(), State),
    ?assertMatch({ok, _, _}, Reply),
    {ok, Info, View} = Reply,
    ?assertEqual([{8, 9}], maps:get(enemy_positions, View)),
    ?assertEqual([{1, 2}], maps:get(shop_positions, View)),
    ?assertEqual([{5, 6}], maps:get(inn_positions, View)).

get_my_state_unknown_char_test() ->
    State = test_support:world_state(),
    {reply, dead, State} = world_server:handle_call({get_my_state, test_support:fake_pid()}, self(), State).

get_enemy_state_known_test() ->
    Pid = test_support:fake_pid(),
    Enemy = test_support:enemy_info(),
    State = test_support:world_state(#{enemies => #{Pid => Enemy}}),
    {reply, {ok, Enemy}, State} = world_server:handle_call({get_enemy_state, Pid}, self(), State).

get_enemy_state_unknown_test() ->
    State = test_support:world_state(),
    {reply, dead, State} = world_server:handle_call({get_enemy_state, test_support:fake_pid()}, self(), State).

move_steps_and_clamps_test() ->
    Pid = test_support:fake_pid(),
    State0 = test_support:world_state(#{characters => #{Pid => test_support:char_info(#{x => 0, y => 0})}}),
    {noreply, S1} = move_cast(Pid, north, State0),
    ?assertEqual({0, 0}, pos_of(Pid, S1)),
    {noreply, S2} = move_cast(Pid, south, S1),
    ?assertEqual({0, 1}, pos_of(Pid, S2)),
    {noreply, S3} = move_cast(Pid, east, S2),
    ?assertEqual({1, 1}, pos_of(Pid, S3)),
    {noreply, S4} = move_cast(Pid, west, S3),
    ?assertEqual({0, 1}, pos_of(Pid, S4)),
    {noreply, S5} = move_cast(Pid, stay, S4),
    ?assertEqual({0, 1}, pos_of(Pid, S5)),
    ?assertEqual(5, maps:get(move_count, S5)).

move_clamps_at_far_edge_test() ->
    Pid = test_support:fake_pid(),
    State0 = test_support:world_state(#{characters => #{Pid => test_support:char_info(#{x => 39, y => 39})}}),
    {noreply, S1} = move_cast(Pid, east, State0),
    ?assertEqual({39, 39}, pos_of(Pid, S1)),
    {noreply, S2} = move_cast(Pid, south, S1),
    ?assertEqual({39, 39}, pos_of(Pid, S2)).

follower_move_ignored_test() ->
    Pid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{Pid => test_support:char_info(#{party_role => follower})}}),
    ?assertEqual({noreply, State0}, move_cast(Pid, north, State0)).

enemy_moves_test() ->
    Pid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        enemies => #{Pid => test_support:enemy_info(#{x => 10, y => 10})}}),
    {noreply, S1} = move_cast(Pid, east, State0),
    Enemy = maps:get(Pid, maps:get(enemies, S1)),
    ?assertEqual(11, maps:get(x, Enemy)),
    ?assertEqual(10, maps:get(y, Enemy)),
    ?assertEqual(0, maps:get(move_count, S1)).

unknown_pid_move_ignored_test() ->
    State0 = test_support:world_state(),
    ?assertEqual({noreply, State0}, move_cast(test_support:fake_pid(), north, State0)).

inn_rest_heals_and_logs_test() ->
    Pid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{Pid => test_support:char_info(#{x => 5, y => 5, hp => 10, max_hp => 23})},
        inns => [#{name => "The Rusty Flagon", x => 6, y => 5}]}),
    {noreply, S1} = move_cast(Pid, east, State0),
    Info = char_at(Pid, S1),
    ?assertEqual(14, maps:get(hp, Info)),
    ?assertEqual(true, maps:get(at_inn, Info)),
    ?assertEqual(1, maps:get(inn_ticks, Info)),
    ?assertEqual(["Roland rests at the inn (+4HP)"], log_of(S1)).

inn_full_hp_stays_quiet_test() ->
    Pid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{Pid => test_support:char_info(#{x => 5, y => 5, hp => 23, max_hp => 23})},
        inns => [#{name => "The Rusty Flagon", x => 6, y => 5}]}),
    {noreply, S1} = move_cast(Pid, east, State0),
    Info = char_at(Pid, S1),
    ?assertEqual(23, maps:get(hp, Info)),
    ?assertEqual(true, maps:get(at_inn, Info)),
    ?assertEqual([], log_of(S1)).

move_off_inn_no_log_test() ->
    Pid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{Pid => test_support:char_info(#{x => 5, y => 5})}}),
    {noreply, S1} = move_cast(Pid, east, State0),
    ?assertEqual([], log_of(S1)).

log_trimmed_at_fifty_test() ->
    Pid = test_support:fake_pid(),
    OldLog = [io_lib:format("e~2..0b", [N]) || N <- lists:seq(1, 50)],
    State0 = test_support:world_state(#{
        characters => #{Pid => test_support:char_info(#{x => 5, y => 5, hp => 10, max_hp => 23})},
        inns => [#{name => "The Rusty Flagon", x => 6, y => 5}],
        event_log => OldLog}),
    {noreply, S1} = move_cast(Pid, east, State0),
    Log = log_of(S1),
    ?assertEqual(50, length(Log)),
    ?assertEqual("e02", hd(Log)),
    ?assertEqual("Roland rests at the inn (+4HP)", lists:last(Log)).

shop_buy_spends_gold_test() ->
    Pid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{Pid => test_support:char_info(#{x => 5, y => 5, gold => 20})},
        shops => [#{name => "Ye Olde Armoury", x => 6, y => 5}]}),
    {noreply, S1} = move_cast(Pid, east, State0),
    Info = char_at(Pid, S1),
    Gold = maps:get(gold, Info),
    ?assert(Gold < 20),
    ?assertEqual(20 - Gold, price_in_log(log_of(S1))),
    ?assertMatch([_], [L || L <- log_of(S1), lists:prefix("Roland bought ", L)]).

price_in_log(Log) ->
    [BuyLine] = [L || L <- Log, lists:prefix("Roland bought ", L)],
    {match, [Price]} = re:run(BuyLine, "\\(-(\\d+)g\\)$", [{capture, all_but_first, list}]),
    list_to_integer(Price).

shop_purchases_cover_all_items_test() ->
    Pid = test_support:fake_pid(),
    Buys = lists:foldl(fun(_, Seen) ->
        State0 = test_support:world_state(#{
            characters => #{Pid => test_support:char_info(#{x => 5, y => 5, gold => 20})},
            shops => [#{name => "Ye Olde Armoury", x => 6, y => 5}]}),
        {noreply, S1} = move_cast(Pid, east, State0),
        Seen ++ log_of(S1)
    end, [], lists:seq(1, 60)),
    ?assert(lists:any(fun(L) -> lists:prefix("Roland bought Elixir (-12g)", L) end, Buys)),
    ?assert(lists:any(fun(L) -> lists:prefix("Roland bought Tower Shield (-20g)", L) end, Buys)).

shop_poor_hero_buys_potion_test() ->
    Pid = test_support:fake_pid(),
    Buys = lists:foldl(fun(_, Seen) ->
        State0 = test_support:world_state(#{
            characters => #{Pid => test_support:char_info(#{x => 5, y => 5, gold => 5})},
            shops => [#{name => "Ye Olde Armoury", x => 6, y => 5}]}),
        {noreply, S1} = move_cast(Pid, east, State0),
        Seen ++ log_of(S1)
    end, [], lists:seq(1, 20)),
    lists:foreach(fun(L) ->
        ?assert(lists:prefix("Roland bought Health Potion (-5g)", L))
    end, [B || B <- Buys, lists:prefix("Roland bought ", B)]).

shop_without_gold_buys_nothing_test() ->
    Pid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{Pid => test_support:char_info(#{x => 5, y => 5, gold => 0})},
        shops => [#{name => "Ye Olde Armoury", x => 6, y => 5}]}),
    {noreply, S1} = move_cast(Pid, east, State0),
    ?assertEqual([], log_of(S1)),
    ?assertEqual(0, maps:get(gold, char_at(Pid, S1))).

strong_char() ->
    test_support:char_info(#{defense_bonus => 100, attack_bonus => 0,
                             hp => 20, max_hp => 23, exp => 0, gold => 0}).

slay_state(Pid, EnemyPid, EnemyName, EnemyHp) ->
    test_support:world_state(#{
        characters => #{Pid => strong_char()},
        enemies => #{EnemyPid => test_support:enemy_info(#{name => EnemyName, hp => EnemyHp,
                                                          x => 6, y => 5})}}).

hero_hits_enemy_test() ->
    Pid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    State0 = slay_state(Pid, EnemyPid, "Goblin", 30),
    {noreply, S1} = move_cast(Pid, east, State0),
    Enemy = maps:get(EnemyPid, maps:get(enemies, S1)),
    ?assert(maps:get(hp, Enemy) >= 26 andalso maps:get(hp, Enemy) =< 28),
    [Line] = log_of(S1),
    ?assertEqual(match, re:run(Line, "^Roland hit Goblin \\(-[2-4]HP\\)$", [{capture, none}])).

hero_slays_enemy_and_is_rewarded_test() ->
    test_support:flush_mailbox(),
    Pid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    State0 = slay_state(Pid, EnemyPid, "SlewRat", 2),
    T0 = erlang:monotonic_time(millisecond),
    {noreply, S1} = move_cast(Pid, east, State0),
    Info = char_at(Pid, S1),
    ?assertEqual(2, maps:get(exp, Info)),
    ?assert(maps:get(gold, Info) >= 3 andalso maps:get(gold, Info) =< 5),
    ?assertNot(maps:is_key(EnemyPid, maps:get(enemies, S1))),
    Lines = log_of(S1),
    ?assert(lists:any(fun(L) ->
        re:run(L, "^Roland slew SlewRat\\(Lv1\\) \\[\\+2XP \\+[3-5]g\\]$", [{capture, none}]) =:= match
    end, Lines)),
    receive
        {respawn_enemy, "SlewRat", 1} ->
            Elapsed = erlang:monotonic_time(millisecond) - T0,
            ?assert(Elapsed >= 2000),
            ?assert(Elapsed =< 4000)
    after 4500 ->
        ?assert(false)
    end.

hero_levels_up_on_third_xp_test() ->
    Pid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{Pid => (strong_char())#{exp := 2}},
        enemies => #{EnemyPid => test_support:enemy_info(#{name => "LvlBat", hp => 2, x => 6, y => 5})}}),
    {noreply, S1} = move_cast(Pid, east, State0),
    Info = char_at(Pid, S1),
    ?assertEqual(2, maps:get(level, Info)),
    ?assertEqual(1, maps:get(exp, Info)),
    ?assertEqual(31, maps:get(max_hp, Info)),
    ?assertEqual(31, maps:get(hp, Info)),
    ?assert(lists:member("Roland leveled up to Lv2!", log_of(S1))).

weak_char(Hp) ->
    test_support:char_info(#{defense_bonus => 0, attack_bonus => 0,
                             hp => Hp, max_hp => 23, name => "Roland"}).

tough_enemy_state(Pid, EnemyPid, EnemyName, CharHp) ->
    test_support:world_state(#{
        characters => #{Pid => weak_char(CharHp)},
        enemies => #{EnemyPid => test_support:enemy_info(#{name => EnemyName,
                                                          defense_bonus => 100,
                                                          hp => 30, x => 6, y => 5})}}).

hero_hit_by_enemy_test() ->
    Pid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    State0 = tough_enemy_state(Pid, EnemyPid, "Wolf", 20),
    {noreply, S1} = move_cast(Pid, east, State0),
    Info = char_at(Pid, S1),
    ?assert(maps:get(hp, Info) >= 16 andalso maps:get(hp, Info) =< 18),
    [Line] = log_of(S1),
    ?assertEqual(match, re:run(Line, "^Roland hit by Wolf \\(-[2-4]HP\\)$", [{capture, none}])).

hero_mauled_and_respawns_test() ->
    test_support:flush_mailbox(),
    Pid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    GhostPid = test_support:fake_pid(),
    FollowerPid = test_support:listener_pid(self()),
    Char = (weak_char(1))#{follower_pids := [GhostPid, FollowerPid]},
    Follower = test_support:char_info(#{name => "Mira", party_role => follower, x => 9, y => 9}),
    State0 = test_support:world_state(#{
        characters => #{Pid => Char, FollowerPid => Follower},
        enemies => #{EnemyPid => test_support:enemy_info(#{name => "MaulOgre",
                                                          defense_bonus => 100,
                                                          hp => 30, x => 6, y => 5})}}),
    T0 = erlang:monotonic_time(millisecond),
    {noreply, S1} = move_cast(Pid, east, State0),
    ?assertNot(maps:is_key(Pid, maps:get(characters, S1))),
    ?assertEqual(["Roland was mauled by MaulOgre!"], log_of(S1)),
    Released = char_at(FollowerPid, S1),
    ?assertEqual(solo, maps:get(party_role, Released)),
    ?assertEqual([], maps:get(party_members, Released)),
    ?assertEqual([], maps:get(follower_pids, Released)),
    receive {heard, FollowerPid, {solo}} -> ok after 1000 -> ?assert(false) end,
    receive
        {respawn_char, "Roland", human} ->
            Elapsed = erlang:monotonic_time(millisecond) - T0,
            ?assert(Elapsed >= 2000),
            ?assert(Elapsed =< 4000)
    after 4500 ->
        ?assert(false)
    end.

second_enemy_ignored_after_hero_death_test() ->
    Pid = test_support:fake_pid(),
    EnemyPid1 = test_support:fake_pid(),
    EnemyPid2 = test_support:fake_pid(),
    Enemy = test_support:enemy_info(#{name => "Troll", defense_bonus => 100, hp => 30, x => 6, y => 5}),
    State0 = test_support:world_state(#{
        characters => #{Pid => weak_char(1)},
        enemies => #{EnemyPid1 => Enemy, EnemyPid2 => Enemy#{name := "Dragon"}}}),
    {noreply, S1} = move_cast(Pid, east, State0),
    ?assertNot(maps:is_key(Pid, maps:get(characters, S1))),
    ?assertEqual(2, maps:size(maps:get(enemies, S1))),
    ?assertEqual(1, length([L || L <- log_of(S1), lists:suffix("was mauled by Troll!", L)
                                    orelse lists:suffix("was mauled by Dragon!", L)])).

loot_drops_apply_test() ->
    Pid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    Seen = loot_loop(Pid, EnemyPid, #{hp => false, atk => false, def => false, eva => false}, 800),
    ?assert(maps:get(hp, Seen)),
    ?assert(maps:get(atk, Seen)),
    ?assert(maps:get(def, Seen)),
    ?assert(maps:get(eva, Seen)).

loot_loop(_Pid, _EnemyPid, Seen, 0) ->
    Seen;
loot_loop(Pid, EnemyPid, Seen, Tries) ->
    case maps:get(hp, Seen) andalso maps:get(atk, Seen)
         andalso maps:get(def, Seen) andalso maps:get(eva, Seen) of
        true ->
            Seen;
        false ->
            State0 = slay_state(Pid, EnemyPid, "LootGoblin", 2),
            {noreply, S1} = move_cast(Pid, east, State0),
            Info = char_at(Pid, S1),
            NewSeen = lists:foldl(fun(Line, Acc) ->
                note_drop(Line, Info, Acc)
            end, Seen, log_of(S1)),
            loot_loop(Pid, EnemyPid, NewSeen, Tries - 1)
    end.

note_drop(Line, Info, Seen) ->
    case re:run(Line, "^Roland found (.+)! \\(\\+(\\d+) ?(HP|ATK|DEF|EVA)\\)$",
                [{capture, all_but_first, list}]) of
        {match, [_Item, _Amount, "HP"]} ->
            Seen#{hp := true};
        {match, [Item, Amount, "ATK"]} ->
            ?assertEqual(list_to_integer(Amount), maps:get(attack_bonus, Info)),
            ?assert(lists:member(Item, maps:get(inventory, Info))),
            Seen#{atk := true};
        {match, [Item, Amount, "DEF"]} ->
            ?assertEqual(100 + list_to_integer(Amount), maps:get(defense_bonus, Info)),
            ?assert(lists:member(Item, maps:get(inventory, Info))),
            Seen#{def := true};
        {match, [Item, _Amount, "EVA"]} ->
            ?assert(lists:member(Item, maps:get(inventory, Info))),
            Seen#{eva := true};
        nomatch ->
            Seen
    end.

party_state(LeaderPid, LeaderInfo, FollowerPid, FollowerInfo) ->
    test_support:world_state(#{
        characters => #{LeaderPid => LeaderInfo, FollowerPid => FollowerInfo}}).

party_forms_at_inn_test() ->
    test_support:flush_mailbox(),
    LeaderPid = test_support:listener_pid(self()),
    FollowerPid = test_support:listener_pid(self()),
    MoverPid = test_support:fake_pid(),
    Inn = #{name => "The Golden Goose", x => 6, y => 5},
    State0 = test_support:world_state(#{
        characters => #{
            LeaderPid => test_support:char_info(#{name => "Aldric", level => 2,
                                                  x => 6, y => 5, inn_ticks => 3}),
            FollowerPid => test_support:char_info(#{name => "Brom", level => 1,
                                                    x => 6, y => 5, inn_ticks => 3}),
            MoverPid => test_support:char_info(#{name => "Mover", x => 0, y => 0})},
        inns => [Inn],
        move_count => 10}),
    {noreply, S1} = move_cast(MoverPid, east, State0),
    ?assertEqual(["Aldric and Brom formed a party at The Golden Goose!"], log_of(S1)),
    Leader = char_at(LeaderPid, S1),
    ?assertEqual(leader, maps:get(party_role, Leader)),
    ?assertEqual([FollowerPid], maps:get(follower_pids, Leader)),
    ?assertEqual("Brom", maps:get(name, hd(maps:get(party_members, Leader)))),
    Follower = char_at(FollowerPid, S1),
    ?assertEqual(follower, maps:get(party_role, Follower)),
    ?assertEqual({6, 5}, {maps:get(x, Follower), maps:get(y, Follower)}),
    receive {heard, FollowerPid, {follow, LeaderPid}} -> ok after 1000 -> ?assert(false) end.

party_leader_is_highest_level_test() ->
    Pid1 = test_support:fake_pid(),
    Pid2 = test_support:fake_pid(),
    MoverPid = test_support:fake_pid(),
    Inn = #{name => "Driftwood Tavern", x => 6, y => 5},
    State0 = test_support:world_state(#{
        characters => #{
            Pid1 => test_support:char_info(#{name => "Lowbie", level => 1,
                                             x => 6, y => 5, inn_ticks => 4}),
            Pid2 => test_support:char_info(#{name => "Veteran", level => 3,
                                             x => 6, y => 5, inn_ticks => 4}),
            MoverPid => test_support:char_info(#{name => "Mover", x => 0, y => 0})},
        inns => [Inn],
        move_count => 20}),
    {noreply, S1} = move_cast(MoverPid, east, State0),
    ?assertEqual(leader, maps:get(party_role, char_at(Pid2, S1))),
    ?assertEqual(follower, maps:get(party_role, char_at(Pid1, S1))),
    ?assertEqual(["Veteran and Lowbie formed a party at Driftwood Tavern!"], log_of(S1)).

no_party_with_single_candidate_test() ->
    Pid = test_support:fake_pid(),
    MoverPid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{
            Pid => test_support:char_info(#{x => 6, y => 5, inn_ticks => 9}),
            MoverPid => test_support:char_info(#{name => "Mover", x => 0, y => 0})},
        inns => [#{name => "Solo Inn", x => 6, y => 5}],
        move_count => 10}),
    {noreply, S1} = move_cast(MoverPid, east, State0),
    ?assertEqual([], log_of(S1)),
    ?assertEqual(solo, maps:get(party_role, char_at(Pid, S1))).

no_party_before_three_ticks_test() ->
    Pid1 = test_support:fake_pid(),
    Pid2 = test_support:fake_pid(),
    MoverPid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{
            Pid1 => test_support:char_info(#{name => "One", x => 6, y => 5, inn_ticks => 2}),
            Pid2 => test_support:char_info(#{name => "Two", x => 6, y => 5, inn_ticks => 2}),
            MoverPid => test_support:char_info(#{name => "Mover", x => 0, y => 0})},
        inns => [#{name => "Tick Inn", x => 6, y => 5}],
        move_count => 10}),
    {noreply, S1} = move_cast(MoverPid, east, State0),
    ?assertEqual([], log_of(S1)).

party_check_runs_every_ten_moves_test() ->
    Pid1 = test_support:fake_pid(),
    Pid2 = test_support:fake_pid(),
    MoverPid = test_support:fake_pid(),
    Chars = #{
        Pid1 => test_support:char_info(#{name => "One", x => 6, y => 5, inn_ticks => 5}),
        Pid2 => test_support:char_info(#{name => "Two", x => 6, y => 5, inn_ticks => 5}),
        MoverPid => test_support:char_info(#{name => "Mover", x => 0, y => 0})},
    Inn = [#{name => "Cycle Inn", x => 6, y => 5}],
    State0 = test_support:world_state(#{characters => Chars, inns => Inn, move_count => 11}),
    {noreply, S1} = move_cast(MoverPid, east, State0),
    ?assertEqual([], log_of(S1)),
    ?assertEqual(solo, maps:get(party_role, char_at(Pid1, S1))).

followers_do_not_form_parties_test() ->
    Pid1 = test_support:fake_pid(),
    Pid2 = test_support:fake_pid(),
    MoverPid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{
            Pid1 => test_support:char_info(#{name => "One", x => 6, y => 5, inn_ticks => 5}),
            Pid2 => test_support:char_info(#{name => "Two", x => 6, y => 5, inn_ticks => 5,
                                             party_role => follower}),
            MoverPid => test_support:char_info(#{name => "Mover", x => 0, y => 0})},
        inns => [#{name => "Role Inn", x => 6, y => 5}],
        move_count => 10}),
    {noreply, S1} = move_cast(MoverPid, east, State0),
    ?assertEqual([], log_of(S1)),
    ?assertEqual(solo, maps:get(party_role, char_at(Pid1, S1))).

leader_move_drags_followers_test() ->
    LeaderPid = test_support:fake_pid(),
    FollowerPid = test_support:fake_pid(),
    GhostPid = test_support:fake_pid(),
    Leader = test_support:char_info(#{name => "Aldric", party_role => leader,
                                      follower_pids => [FollowerPid, GhostPid],
                                      party_members => []}),
    Follower = test_support:char_info(#{name => "Brom", party_role => follower}),
    State0 = party_state(LeaderPid, Leader, FollowerPid, Follower),
    {noreply, S1} = move_cast(LeaderPid, east, State0),
    ?assertEqual({6, 5}, pos_of(LeaderPid, S1)),
    ?assertEqual({6, 5}, pos_of(FollowerPid, S1)),
    Members = maps:get(party_members, char_at(LeaderPid, S1)),
    ?assertEqual(1, length(Members)),
    ?assertEqual("Brom", maps:get(name, hd(Members))),
    ?assertEqual({6, 5}, {maps:get(x, hd(Members)), maps:get(y, hd(Members))}).

party_fight_state(LeaderPid, FollowerPid, EnemyPid, LeaderHp, FollowerHp, EnemyHp) ->
    Leader = test_support:char_info(#{name => "Aldric", party_role => leader,
                                      defense_bonus => 0, hp => LeaderHp, max_hp => 100,
                                      follower_pids => [FollowerPid],
                                      party_members => [], x => 5, y => 5}),
    Follower = test_support:char_info(#{name => "Brom", party_role => follower,
                                        defense_bonus => 0, hp => FollowerHp, max_hp => 100,
                                        x => 5, y => 5}),
    Enemy = test_support:enemy_info(#{name => "GrimOgre", defense_bonus => 100,
                                     hp => EnemyHp, x => 6, y => 5}),
    test_support:world_state(#{
        characters => #{LeaderPid => Leader, FollowerPid => Follower},
        enemies => #{EnemyPid => Enemy}}).

party_slays_enemy_test() ->
    test_support:flush_mailbox(),
    LeaderPid = test_support:fake_pid(),
    FollowerPid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    Leader = test_support:char_info(#{name => "Aldric", party_role => leader,
                                      defense_bonus => 50, hp => 20, max_hp => 23,
                                      exp => 0, gold => 0,
                                      follower_pids => [FollowerPid], party_members => []}),
    Follower = test_support:char_info(#{name => "Brom", party_role => follower,
                                        defense_bonus => 0, exp => 0}),
    Enemy = test_support:enemy_info(#{name => "PartyRat", hp => 2, x => 6, y => 5}),
    State0 = test_support:world_state(#{
        characters => #{LeaderPid => Leader, FollowerPid => Follower},
        enemies => #{EnemyPid => Enemy}}),
    {noreply, S1} = move_cast(LeaderPid, east, State0),
    SlayLines = log_of(S1),
    ?assert(lists:any(fun(L) ->
        re:run(L, "^Aldric's party slew PartyRat\\(Lv1\\) \\[\\+2XP \\+[3-5]g\\]$", [{capture, none}]) =:= match
    end, SlayLines)),
    Leader1 = char_at(LeaderPid, S1),
    ?assertEqual(2, maps:get(exp, Leader1)),
    ?assert(maps:get(gold, Leader1) >= 3 andalso maps:get(gold, Leader1) =< 5),
    ?assertEqual(2, maps:get(exp, char_at(FollowerPid, S1))),
    ?assertNot(maps:is_key(EnemyPid, maps:get(enemies, S1))),
    receive {respawn_enemy, "PartyRat", 1} -> ok after 4500 -> ?assert(false) end.

party_slays_enemy_with_ghost_first_test() ->
    LeaderPid = test_support:fake_pid(),
    FollowerPid = test_support:fake_pid(),
    GhostPid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    Leader = test_support:char_info(#{name => "Aldric", party_role => leader,
                                      defense_bonus => 50, hp => 20, max_hp => 23,
                                      exp => 0, gold => 0,
                                      follower_pids => [GhostPid, FollowerPid],
                                      party_members => []}),
    Follower = test_support:char_info(#{name => "Brom", party_role => follower,
                                        defense_bonus => 0, exp => 0}),
    Enemy = test_support:enemy_info(#{name => "GhostRat", hp => 2, x => 6, y => 5}),
    State0 = test_support:world_state(#{
        characters => #{LeaderPid => Leader, FollowerPid => Follower},
        enemies => #{EnemyPid => Enemy}}),
    {noreply, S1} = move_cast(LeaderPid, east, State0),
    GhostLines = log_of(S1),
    ?assert(lists:any(fun(L) ->
        re:run(L, "^Aldric's party slew GhostRat", [{capture, none}]) =:= match
    end, GhostLines)),
    ?assertEqual(0, maps:get(exp, char_at(FollowerPid, S1))),
    ?assertEqual(1, length(maps:get(party_members, char_at(LeaderPid, S1)))).

party_hits_enemy_test() ->
    LeaderPid = test_support:fake_pid(),
    FollowerPid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    Leader = test_support:char_info(#{name => "Aldric", party_role => leader,
                                      defense_bonus => 300, hp => 20, max_hp => 23,
                                      follower_pids => [FollowerPid], party_members => []}),
    Follower = test_support:char_info(#{name => "Brom", party_role => follower,
                                        defense_bonus => 300}),
    Enemy = test_support:enemy_info(#{name => "BigTroll", hp => 500, x => 6, y => 5}),
    State0 = test_support:world_state(#{
        characters => #{LeaderPid => Leader, FollowerPid => Follower},
        enemies => #{EnemyPid => Enemy}}),
    {noreply, S1} = move_cast(LeaderPid, east, State0),
    [Line] = log_of(S1),
    ?assertEqual(match, re:run(Line, "^Aldric's party hit BigTroll \\(-\\d+HP\\)$", [{capture, none}])),
    Enemy1 = maps:get(EnemyPid, maps:get(enemies, S1)),
    ?assert(maps:get(hp, Enemy1) < 500),
    ?assertEqual(1, length(maps:get(party_members, char_at(LeaderPid, S1)))).

party_loses_leader_slain_test() ->
    test_support:flush_mailbox(),
    ?assert(attempt_party_death(leader_slain, 60)).

attempt_party_death(_Mode, 0) ->
    false;
attempt_party_death(leader_slain, Tries) ->
    LeaderPid = test_support:fake_pid(),
    FollowerPid = test_support:listener_pid(self()),
    EnemyPid = test_support:fake_pid(),
    State0 = party_fight_state(LeaderPid, FollowerPid, EnemyPid, 1, 50, 30),
    {noreply, S1} = move_cast(LeaderPid, east, State0),
    case lists:member("Aldric was slain by GrimOgre! Party disbanded!", log_of(S1)) of
        true ->
            ?assertNot(maps:is_key(LeaderPid, maps:get(characters, S1))),
            ?assertEqual(solo, maps:get(party_role, char_at(FollowerPid, S1))),
            receive {heard, FollowerPid, {solo}} -> ok after 1000 -> ?assert(false) end,
            receive {respawn_char, "Aldric", human} -> ok after 4500 -> ?assert(false) end,
            true;
        false ->
            attempt_party_death(leader_slain, Tries - 1)
    end.

party_loses_follower_slain_test() ->
    test_support:flush_mailbox(),
    ?assert(attempt_follower_death(60)).

attempt_follower_death(0) ->
    false;
attempt_follower_death(Tries) ->
    LeaderPid = test_support:fake_pid(),
    FollowerPid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    State0 = party_fight_state(LeaderPid, FollowerPid, EnemyPid, 100, 1, 30),
    {noreply, S1} = move_cast(LeaderPid, east, State0),
    case lists:member("Brom was slain by GrimOgre!", log_of(S1)) of
        true ->
            ?assertNot(maps:is_key(FollowerPid, maps:get(characters, S1))),
            Leader1 = char_at(LeaderPid, S1),
            ?assertEqual(solo, maps:get(party_role, Leader1)),
            ?assertEqual([], maps:get(party_members, Leader1)),
            ?assertEqual([], maps:get(follower_pids, Leader1)),
            receive {respawn_char, "Brom", human} -> ok after 4500 -> ?assert(false) end,
            true;
        false ->
            attempt_follower_death(Tries - 1)
    end.

big_party_loses_follower_keeps_leading_test() ->
    test_support:flush_mailbox(),
    ?assert(attempt_big_party_death(80)).

attempt_big_party_death(0) ->
    false;
attempt_big_party_death(Tries) ->
    LeaderPid = test_support:fake_pid(),
    F1 = test_support:fake_pid(),
    F2 = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    Leader = test_support:char_info(#{name => "Aldric", party_role => leader,
                                      defense_bonus => 0, hp => 100, max_hp => 100,
                                      follower_pids => [F1, F2], party_members => []}),
    Follower1 = test_support:char_info(#{name => "BigBrom", party_role => follower,
                                         defense_bonus => 0, hp => 1, max_hp => 100}),
    Follower2 = test_support:char_info(#{name => "BigCedric", party_role => follower,
                                         defense_bonus => 0, hp => 1, max_hp => 100}),
    Enemy = test_support:enemy_info(#{name => "GrimOgre", defense_bonus => 100,
                                     hp => 30, x => 6, y => 5}),
    State0 = test_support:world_state(#{
        characters => #{LeaderPid => Leader, F1 => Follower1, F2 => Follower2},
        enemies => #{EnemyPid => Enemy}}),
    {noreply, S1} = move_cast(LeaderPid, east, State0),
    Log = log_of(S1),
    Deaths = [L || L <- Log, lists:suffix("was slain by GrimOgre!", L)],
    case Deaths of
        [_DeathLine] ->
            Leader1 = char_at(LeaderPid, S1),
            ?assertEqual(leader, maps:get(party_role, Leader1)),
            ?assertEqual(1, length(maps:get(party_members, Leader1))),
            ?assertEqual(1, length(maps:get(follower_pids, Leader1))),
            ?assertEqual(2, maps:size(maps:get(characters, S1))),
            true;
        _ ->
            attempt_big_party_death(Tries - 1)
    end.

party_loses_leader_hit_survives_test() ->
    ?assert(attempt_member_hit("Aldric", 80)).

party_loses_follower_hit_survives_test() ->
    ?assert(attempt_member_hit("Brom", 80)).

attempt_member_hit(_Victim, 0) ->
    false;
attempt_member_hit(Victim, Tries) ->
    LeaderPid = test_support:fake_pid(),
    FollowerPid = test_support:fake_pid(),
    EnemyPid = test_support:fake_pid(),
    State0 = party_fight_state(LeaderPid, FollowerPid, EnemyPid, 100, 100, 30),
    {noreply, S1} = move_cast(LeaderPid, east, State0),
    Pattern = "^" ++ Victim ++ " hit by GrimOgre \\(-\\d+HP\\)$",
    Hits = [L || L <- log_of(S1), re:run(L, Pattern, [{capture, none}]) =:= match],
    case Hits of
        [_Line] ->
            {ExpectedLeaderHp, ExpectedFollowerHp} =
                case Victim of
                    "Aldric" -> {fun(H) -> H < 100 end, fun(H) -> H =:= 100 end};
                    "Brom" -> {fun(H) -> H =:= 100 end, fun(H) -> H < 100 end}
                end,
            ?assert(ExpectedLeaderHp(maps:get(hp, char_at(LeaderPid, S1)))),
            ?assert(ExpectedFollowerHp(maps:get(hp, char_at(FollowerPid, S1)))),
            ?assertEqual(1, length(maps:get(party_members, char_at(LeaderPid, S1)))),
            true;
        _ ->
            attempt_member_hit(Victim, Tries - 1)
    end.

render_state(CharList) ->
    test_support:world_state(#{characters => maps:from_list(CharList)}).

run_render(State) ->
    test_support:flush_mailbox(),
    world_server:handle_info(render, State).

render_log(State) ->
    DisplayPid = test_support:listener_pid(self()),
    {noreply, S1} = run_render(State#{display_pid := DisplayPid}),
    receive
        {heard, DisplayPid, {render, _Chars, _Enemies, _Shops, _Inns, Log, _MC}} ->
            {S1, [lists:flatten(Entry) || Entry <- Log]}
    after 1000 ->
        ?assert(false)
    end.

pvp_clash_test() ->
    Pid1 = test_support:fake_pid(),
    Pid2 = test_support:fake_pid(),
    State0 = render_state([
        {Pid1, test_support:char_info(#{name => "Aldric", defense_bonus => 50,
                                        hp => 20, max_hp => 23, x => 7, y => 7})},
        {Pid2, test_support:char_info(#{name => "Brom", hp => 50, max_hp => 50, x => 7, y => 7})}]),
    {S1, Log} = render_log(State0),
    [Line] = [L || L <- Log, lists:suffix("HP)", L)],
    ?assertEqual(match, re:run(Line, "^Aldric clashed with Brom \\(-[2-4]HP\\)$", [{capture, none}])),
    ?assert(maps:get(hp, char_at(Pid2, S1)) < 50),
    ?assertEqual([], log_of(S1)).

pvp_clash_reverse_winner_test() ->
    Pid1 = test_support:fake_pid(),
    Pid2 = test_support:fake_pid(),
    State0 = render_state([
        {Pid1, test_support:char_info(#{name => "Aldric", hp => 20, max_hp => 23, x => 7, y => 7})},
        {Pid2, test_support:char_info(#{name => "Brom", defense_bonus => 50,
                                        hp => 50, max_hp => 50, x => 7, y => 7})}]),
    {_S1, Log} = render_log(State0),
    [Line] = [L || L <- Log, lists:suffix("HP)", L)],
    ?assertEqual(match, re:run(Line, "^Brom clashed with Aldric \\(-[2-4]HP\\)$", [{capture, none}])).

pvp_defeat_levels_winner_test() ->
    test_support:flush_mailbox(),
    Pid1 = test_support:fake_pid(),
    Pid2 = test_support:fake_pid(),
    State0 = render_state([
        {Pid1, test_support:char_info(#{name => "Aldric", defense_bonus => 50,
                                        hp => 20, max_hp => 23, exp => 2, x => 7, y => 7})},
        {Pid2, test_support:char_info(#{name => "Brom", level => 3, hp => 1, max_hp => 50,
                                        x => 7, y => 7})}]),
    T0 = erlang:monotonic_time(millisecond),
    {S1, Log} = render_log(State0),
    ?assert(lists:member("Aldric defeated Brom! [+3XP]", Log)),
    ?assert(lists:member("Aldric leveled up to Lv2!", Log)),
    ?assertNot(maps:is_key(Pid2, maps:get(characters, S1))),
    Winner = char_at(Pid1, S1),
    ?assertEqual(2, maps:get(level, Winner)),
    ?assertEqual(2, maps:get(exp, Winner)),
    ?assertEqual(31, maps:get(hp, Winner)),
    receive
        {respawn_char, "Brom", human} ->
            ?assert(erlang:monotonic_time(millisecond) - T0 >= 2000)
    after 4500 ->
        ?assert(false)
    end.

pvp_same_party_skips_fight_test() ->
    Pid1 = test_support:fake_pid(),
    Pid2 = test_support:fake_pid(),
    State0 = render_state([
        {Pid1, test_support:char_info(#{name => "Aldric", party_role => leader,
                                        follower_pids => [Pid2], x => 7, y => 7})},
        {Pid2, test_support:char_info(#{name => "Brom", x => 7, y => 7})}]),
    {_S1, Log} = render_log(State0),
    ?assertEqual([], Log).

single_occupant_no_fight_test() ->
    Pid1 = test_support:fake_pid(),
    State0 = render_state([{Pid1, test_support:char_info(#{x => 7, y => 7})}]),
    {_S1, Log} = render_log(State0),
    ?assertEqual([], Log).

follower_skipped_in_pvp_test() ->
    Pid1 = test_support:fake_pid(),
    Pid2 = test_support:fake_pid(),
    State0 = render_state([
        {Pid1, test_support:char_info(#{name => "Aldric", x => 7, y => 7})},
        {Pid2, test_support:char_info(#{name => "Brom", party_role => follower, x => 7, y => 7})}]),
    {_S1, Log} = render_log(State0),
    ?assertEqual([], Log).

inn_flags_cleared_off_inn_test() ->
    OffInnPid = test_support:fake_pid(),
    OnInnPid = test_support:fake_pid(),
    State0 = test_support:world_state(#{
        characters => #{
            OffInnPid => test_support:char_info(#{name => "Away", x => 9, y => 9,
                                                  at_inn => true, inn_ticks => 5}),
            OnInnPid => test_support:char_info(#{name => "Home", x => 1, y => 1,
                                                 at_inn => true, inn_ticks => 2})},
        inns => [#{name => "Flag Inn", x => 1, y => 1}]}),
    {noreply, S1} = run_render(State0),
    Away = char_at(OffInnPid, S1),
    ?assertEqual(false, maps:get(at_inn, Away)),
    ?assertEqual(0, maps:get(inn_ticks, Away)),
    Home = char_at(OnInnPid, S1),
    ?assertEqual(true, maps:get(at_inn, Home)),
    ?assertEqual(2, maps:get(inn_ticks, Home)).

respawn_char_test() ->
    State0 = test_support:world_state(),
    {noreply, S1} = world_server:handle_info({respawn_char, "Reborn", human}, State0),
    ?assertEqual(1, maps:size(maps:get(characters, S1))),
    [Info] = maps:values(maps:get(characters, S1)),
    ?assertEqual("Reborn", maps:get(name, Info)),
    ?assertEqual(1, maps:get(level, Info)),
    ?assertEqual(23, maps:get(hp, Info)),
    ?assertEqual(23, maps:get(max_hp, Info)),
    ?assertEqual(0, maps:get(exp, Info)),
    ?assertEqual(solo, maps:get(party_role, Info)),
    ?assert(maps:get(x, Info) >= 0 andalso maps:get(x, Info) =< 39),
    ?assertEqual(["Reborn respawned!"], log_of(S1)).

respawn_enemy_test() ->
    State0 = test_support:world_state(),
    {noreply, S1} = world_server:handle_info({respawn_enemy, "Rat", 1}, State0),
    ?assertEqual(1, maps:size(maps:get(enemies, S1))),
    [Info] = maps:values(maps:get(enemies, S1)),
    ?assertEqual("Rat", maps:get(name, Info)),
    ?assertEqual(9, maps:get(hp, Info)),
    ?assertEqual(9, maps:get(max_hp, Info)),
    ?assertEqual(enemy, maps:get(type, Info)),
    ?assertEqual(["A Rat appeared!"], log_of(S1)).

live_server_test() ->
    CapturePid = test_support:capture_io(),
    OldLeader = erlang:group_leader(),
    erlang:group_leader(CapturePid, self()),
    {ok, Server} = world_server:start_link(),
    unlink(Server),
    BootState = world_server:get_state(),
    ?assertEqual(6, maps:size(maps:get(characters, BootState))),
    ?assertEqual(12, maps:size(maps:get(enemies, BootState))),
    ?assertEqual(3, length(maps:get(shops, BootState))),
    ?assertEqual(2, length(maps:get(inns, BootState))),
    ?assertEqual(0, maps:get(move_count, BootState)),
    timer:sleep(600),
    State1 = world_server:get_state(),
    timer:sleep(1300),
    State2 = world_server:get_state(),
    ?assert(maps:get(move_count, State2) > maps:get(move_count, State1)),
    ?assertNotEqual(positions(maps:get(characters, State1)),
                    positions(maps:get(characters, State2))),
    ?assertNotEqual(positions(maps:get(enemies, State1)),
                    positions(maps:get(enemies, State2))),
    ?assertEqual(places(maps:get(shops, State1)), places(maps:get(shops, State2))),
    ?assertEqual(places(maps:get(inns, State1)), places(maps:get(inns, State2))),
    assert_in_bounds(maps:get(characters, State2)),
    assert_in_bounds(maps:get(enemies, State2)),
    [CharPid | _] = maps:keys(maps:get(characters, State2)),
    ?assertMatch({ok, _, _}, world_server:get_my_state(CharPid)),
    ?assertEqual(dead, world_server:get_my_state(test_support:fake_pid())),
    [EnemyPid | _] = maps:keys(maps:get(enemies, State2)),
    ?assertMatch({ok, _}, world_server:get_enemy_state(EnemyPid)),
    ?assertEqual(dead, world_server:get_enemy_state(test_support:fake_pid())),
    ok = world_server:move(CharPid, north),
    timer:sleep(200),
    DisplayPid = maps:get(display_pid, State2),
    erlang:group_leader(OldLeader, self()),
    test_support:kill(Server),
    test_support:kill(DisplayPid),
    Text = test_support:captured_text(CapturePid),
    test_support:kill(CapturePid),
    ?assert(string:find(Text, "=== CMD RPG [") =/= nomatch),
    ?assert(string:find(Text, "Heroes:") =/= nomatch),
    ?assert(string:find(Text, "Enemies on map:") =/= nomatch),
    ?assert(string:find(Text, "Log:") =/= nomatch),
    ?assert(string:find(Text, "Hero") =/= nomatch),
    ?assert(string:find(Text, "Party") =/= nomatch),
    ?assert(string:find(Text, "Enemy") =/= nomatch),
    ?assert(string:find(Text, "Shop") =/= nomatch),
    ?assert(string:find(Text, "Inn") =/= nomatch).

positions(Entities) ->
    maps:map(fun(_Pid, Info) -> {maps:get(x, Info), maps:get(y, Info)} end, Entities).

places(Places) ->
    lists:sort([{maps:get(x, P), maps:get(y, P)} || P <- Places]).

assert_in_bounds(Entities) ->
    maps:foreach(fun(_Pid, Info) ->
        ?assert(maps:get(x, Info) >= 0 andalso maps:get(x, Info) =< 39),
        ?assert(maps:get(y, Info) >= 0 andalso maps:get(y, Info) =< 39)
    end, Entities).
