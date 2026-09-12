-module(screen).
-export([unpainted/0, update/2]).

-define(ROWS, 74).
-define(COLS, 85).
-define(PARK_ROW, 75).

-define(HIDE, "\e[?25l").
-define(SHOW, "\e[?25h").
-define(RESET, "\e[0m").
-define(ERASE_RIGHT, "\e[K").

unpainted() ->
    lists:duplicate(?ROWS, lists:duplicate(?COLS, dirty)).

update(Painted, Lines) ->
    Now = [cells(Line) || Line <- lists:sublist(Lines, ?ROWS)],
    {[?HIDE, row_updates(Painted, Now), addr(?PARK_ROW, 1), ?SHOW], Now}.

cells(Parts) ->
    lists:sublist(lists:append([part_cells(Part) || Part <- Parts]), ?COLS).

part_cells({Attributes, Text}) ->
    Style = style(Attributes),
    [{Style, Char} || Char <- lists:flatten(Text)].

style(Attributes) ->
    lists:append([attribute(Attribute) || Attribute <- Attributes]).

attribute(bold) -> "\e[1m";
attribute(dim) -> "\e[2m";
attribute(red) -> "\e[31m";
attribute(green) -> "\e[32m";
attribute(yellow) -> "\e[33m";
attribute(blue) -> "\e[34m";
attribute(magenta) -> "\e[35m";
attribute(cyan) -> "\e[36m".

row_updates(Painted, Lines) ->
    Height = max(length(Painted), length(Lines)),
    Rows = lists:zip3(lists:seq(1, Height), pad(Painted, Height, []), pad(Lines, Height, [])),
    [row_update(Row, Was, Now) || {Row, Was, Now} <- Rows].

pad(Items, Length, Filler) ->
    Items ++ lists:duplicate(Length - length(Items), Filler).

row_update(_Row, Same, Same) ->
    [];
row_update(Row, Was, Now) ->
    Width = length(Now),
    Columns = lists:zip3(lists:seq(1, Width), on_screen(Was, Width), Now),
    [[paint_run(Row, Col, Run) || {Col, Run} <- changed_runs(Columns)],
     clear_tail(Row, length(Was), Width)].

on_screen(Was, Width) ->
    pad(lists:sublist(Was, Width), Width, blank).

changed_runs([]) ->
    [];
changed_runs([{_Col, Same, Same} | Rest]) ->
    changed_runs(Rest);
changed_runs([{Col, _Was, Now} | Rest]) ->
    {Run, Tail} = run_from(Rest, [Now]),
    [{Col, Run} | changed_runs(Tail)].

run_from([{_Col, Same, Same} | _] = Tail, Acc) ->
    {lists:reverse(Acc), Tail};
run_from([], Acc) ->
    {lists:reverse(Acc), []};
run_from([{_Col, _Was, Now} | Rest], Acc) ->
    run_from(Rest, [Now | Acc]).

paint_run(Row, Col, Run) ->
    [addr(Row, Col), cell_bytes(Run, none), ?RESET].

cell_bytes([], _Style) ->
    [];
cell_bytes([{Style, Char} | Rest], Style) ->
    [Char | cell_bytes(Rest, Style)];
cell_bytes([{Style, Char} | Rest], _Other) ->
    [?RESET, Style, Char | cell_bytes(Rest, Style)].

clear_tail(Row, WasWidth, NowWidth) when WasWidth > NowWidth ->
    [addr(Row, NowWidth + 1), ?ERASE_RIGHT];
clear_tail(_Row, _WasWidth, _NowWidth) ->
    [].

addr(Row, Col) ->
    io_lib:format("\e[~p;~pH", [Row, Col]).
