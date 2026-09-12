-module(util).
-export([clamp/3]).
-export([random_pos/1]).
-export([random_direction/0]).
-export([shuffle/1]).
-export([random_race/0]).
-export([race_name/1]).
-export([race_bonuses/1]).
-export([race_label/1]).
-export([race_speed/1]).
-export_type([race / 0, direction / 0, position / 0]).

-type race() :: human | dwarf | dark_elf | gnome | treant | duckman.
-type direction() :: north | south | east | west | stay.
-type position() :: {non_neg_integer(), non_neg_integer()}.
-type bonuses() :: #{hp_bonus := non_neg_integer(),
                        attack_bonus := non_neg_integer(),
                        defense_bonus := non_neg_integer()}.

-spec clamp(integer(), integer(), integer()) -> integer().
clamp(Val, Min, Max) ->
    max(Min, min(Max, Val)).

-spec random_pos(pos_integer()) -> position().
random_pos(MapSize) ->
    {rand:uniform(MapSize) - 1, rand:uniform(MapSize) - 1}.

-spec random_direction() -> direction().
random_direction() ->
    lists:nth(rand:uniform(5), [north, south, east, west, stay]).

-spec shuffle([T]) -> [T].
shuffle([]) -> [];
shuffle(List) ->
    Tagged = [{rand:uniform(), X} || X <- List],
    [X || {_, X} <- lists:sort(Tagged)].

-spec random_race() -> race().
random_race() ->
    Races = [human, dwarf, dark_elf, gnome, treant, duckman],
    lists:nth(rand:uniform(length(Races)), Races).

-spec race_name(race()) -> string().
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

-spec pick([string(), ...]) -> string().
pick(List) ->
    lists:nth(rand:uniform(length(List)), List).

-spec race_bonuses(race()) -> bonuses().
race_bonuses(human)    -> #{hp_bonus => 3,  attack_bonus => 1, defense_bonus => 1};
race_bonuses(dwarf)    -> #{hp_bonus => 6,  attack_bonus => 0, defense_bonus => 3};
race_bonuses(dark_elf) -> #{hp_bonus => 0,  attack_bonus => 4, defense_bonus => 0};
race_bonuses(gnome)    -> #{hp_bonus => 0,  attack_bonus => 2, defense_bonus => 2};
race_bonuses(treant)   -> #{hp_bonus => 10, attack_bonus => 0, defense_bonus => 0};
race_bonuses(duckman)  -> #{hp_bonus => 2,  attack_bonus => 1, defense_bonus => 1}.

-spec race_speed(race()) -> pos_integer().
race_speed(dark_elf) -> 400;
race_speed(gnome)    -> 450;
race_speed(human)    -> 500;
race_speed(duckman)  -> 550;
race_speed(dwarf)    -> 600;
race_speed(treant)   -> 750.

-spec race_label(race()) -> string().
race_label(human)    -> "Hum";
race_label(dwarf)    -> "Dwf";
race_label(dark_elf) -> "DkE";
race_label(gnome)    -> "Gnm";
race_label(treant)   -> "Trt";
race_label(duckman)  -> "Duk".
