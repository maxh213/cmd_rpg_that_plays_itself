-module(util_tests).
-include_lib("eunit/include/eunit.hrl").

clamp_test() ->
    ?assertEqual(5, util:clamp(5, 0, 39)),
    ?assertEqual(0, util:clamp(-1, 0, 39)),
    ?assertEqual(39, util:clamp(40, 0, 39)),
    ?assertEqual(0, util:clamp(0, 0, 39)),
    ?assertEqual(39, util:clamp(39, 0, 39)).

random_pos_test() ->
    Positions = [util:random_pos(40) || _ <- lists:seq(1, 200)],
    lists:foreach(fun({X, Y}) ->
        ?assert(X >= 0 andalso X =< 39),
        ?assert(Y >= 0 andalso Y =< 39)
    end, Positions).

random_direction_test() ->
    Directions = [util:random_direction() || _ <- lists:seq(1, 500)],
    Expected = [north, south, east, west, stay],
    lists:foreach(fun(D) -> ?assert(lists:member(D, Expected)) end, Directions),
    ?assertEqual(lists:sort(Expected), lists:sort(lists:usort(Directions))).

shuffle_empty_test() ->
    ?assertEqual([], util:shuffle([])).

shuffle_keeps_elements_test() ->
    List = [1, 2, 3, 4, 5, 6, 7],
    Results = [util:shuffle(List) || _ <- lists:seq(1, 50)],
    lists:foreach(fun(Shuffled) -> ?assertEqual(List, lists:sort(Shuffled)) end, Results),
    ?assert(length(lists:usort(Results)) > 1).

random_race_test() ->
    Races = [util:random_race() || _ <- lists:seq(1, 500)],
    Expected = [dark_elf, duckman, dwarf, gnome, human, treant],
    lists:foreach(fun(R) -> ?assert(lists:member(R, Expected)) end, Races),
    ?assertEqual(Expected, lists:sort(lists:usort(Races))).

race_name_test() ->
    Pools = #{
        human => ["Roland", "Elara", "Gareth", "Lyra", "Cedric", "Mira",
                  "Aldric", "Sera", "Brom", "Isolde"],
        dwarf => ["Thorin", "Gimrak", "Durnir", "Bruni", "Fargrim", "Torunn",
                  "Balin", "Khelgar", "Agna", "Dolgrin"],
        dark_elf => ["Malekith", "Drizara", "Vaelith", "Szoreth", "Nylara", "Pharaun",
                     "Viconia", "Zaknir", "Liriel", "Solaufein"],
        gnome => ["Fizzwick", "Tinkle", "Wobblecog", "Nimblefin", "Gizwick", "Sprocket",
                  "Cogsworth", "Pibble", "Nyx", "Ratchet"],
        treant => ["Oakmoss", "Rootbeard", "Willowshade", "Fernbark", "Elmheart", "Mossgrove",
                   "Ashbough", "Birchsong", "Thornveil", "Cedarwick"],
        duckman => ["Quacksworth", "Sir Mallard", "Duckington", "Waddles", "Beakman",
                    "Featherton", "Lord Drake", "Bill", "Eider", "Tealsworth"]},
    maps:foreach(fun(Race, Pool) ->
        Samples = [util:race_name(Race) || _ <- lists:seq(1, 200)],
        lists:foreach(fun(Name) -> ?assert(lists:member(Name, Pool)) end, Samples)
    end, Pools).

race_bonuses_test() ->
    ?assertEqual(#{hp_bonus => 3, attack_bonus => 1, defense_bonus => 1}, util:race_bonuses(human)),
    ?assertEqual(#{hp_bonus => 6, attack_bonus => 0, defense_bonus => 3}, util:race_bonuses(dwarf)),
    ?assertEqual(#{hp_bonus => 0, attack_bonus => 4, defense_bonus => 0}, util:race_bonuses(dark_elf)),
    ?assertEqual(#{hp_bonus => 0, attack_bonus => 2, defense_bonus => 2}, util:race_bonuses(gnome)),
    ?assertEqual(#{hp_bonus => 10, attack_bonus => 0, defense_bonus => 0}, util:race_bonuses(treant)),
    ?assertEqual(#{hp_bonus => 2, attack_bonus => 1, defense_bonus => 1}, util:race_bonuses(duckman)).

race_speed_test() ->
    ?assertEqual(400, util:race_speed(dark_elf)),
    ?assertEqual(450, util:race_speed(gnome)),
    ?assertEqual(500, util:race_speed(human)),
    ?assertEqual(550, util:race_speed(duckman)),
    ?assertEqual(600, util:race_speed(dwarf)),
    ?assertEqual(750, util:race_speed(treant)).

race_label_test() ->
    ?assertEqual("Hum", util:race_label(human)),
    ?assertEqual("Dwf", util:race_label(dwarf)),
    ?assertEqual("DkE", util:race_label(dark_elf)),
    ?assertEqual("Gnm", util:race_label(gnome)),
    ?assertEqual("Trt", util:race_label(treant)),
    ?assertEqual("Duk", util:race_label(duckman)).
