-module(util).
-export([random_name/1, clamp/3, random_pos/1, random_direction/0, shuffle/1,
         random_race/0, race_name/1, race_bonuses/1, race_label/1, race_speed/1]).

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

random_race() ->
    Races = [human, dwarf, dark_elf, gnome, treant, duckman],
    lists:nth(rand:uniform(length(Races)), Races).

race_name(human) ->
    pick(["Roland", "Elara", "Gareth", "Lyra", "Cedric", "Mira",
          "Aldric", "Sera", "Brom", "Isolde"]);
race_name(dwarf) ->
    pick(["Thorin", "Gimrak", "Durnir", "Bruni", "Fargrim", "Torunn",
          "Balin", "Khelgar", "Agna", "Dolgrin"]);
race_name(dark_elf) ->
    pick(["Malekith", "Drizara", "Vaelith", "Szoreth", "Nylara", "Pharaun",
          "Viconia", "Zaknir", "Liriel", "Solaufein"]);
race_name(gnome) ->
    pick(["Fizzwick", "Tinkle", "Wobblecog", "Nimblefin", "Gizwick", "Sprocket",
          "Cogsworth", "Pibble", "Nyx", "Ratchet"]);
race_name(treant) ->
    pick(["Oakmoss", "Rootbeard", "Willowshade", "Fernbark", "Elmheart", "Mossgrove",
          "Ashbough", "Birchsong", "Thornveil", "Cedarwick"]);
race_name(duckman) ->
    pick(["Quacksworth", "Sir Mallard", "Duckington", "Waddles", "Beakman",
          "Featherton", "Lord Drake", "Bill", "Eider", "Tealsworth"]).

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).

race_bonuses(human)    -> #{hp_bonus => 3,  attack_bonus => 1, defense_bonus => 1};
race_bonuses(dwarf)    -> #{hp_bonus => 6,  attack_bonus => 0, defense_bonus => 3};
race_bonuses(dark_elf) -> #{hp_bonus => 0,  attack_bonus => 4, defense_bonus => 0};
race_bonuses(gnome)    -> #{hp_bonus => 0,  attack_bonus => 2, defense_bonus => 2};
race_bonuses(treant)   -> #{hp_bonus => 10, attack_bonus => 0, defense_bonus => 0};
race_bonuses(duckman)  -> #{hp_bonus => 2,  attack_bonus => 1, defense_bonus => 1}.

race_speed(dark_elf) -> 400;
race_speed(gnome)    -> 450;
race_speed(human)    -> 500;
race_speed(duckman)  -> 550;
race_speed(dwarf)    -> 600;
race_speed(treant)   -> 750.

race_label(human)    -> "Hum";
race_label(dwarf)    -> "Dwf";
race_label(dark_elf) -> "DkE";
race_label(gnome)    -> "Gnm";
race_label(treant)   -> "Trt";
race_label(duckman)  -> "Duk".
