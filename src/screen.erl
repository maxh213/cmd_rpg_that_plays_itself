-module(screen).
-export([unpainted/0]).
-export([update/3]).
-export_type([screen / 0, size / 0]).

-define(HIDE, "\e[?25l").
-define(SHOW, "\e[?25h").
-define(RESET, "\e[0m").
-define(ERASE_RIGHT, "\e[K").
-define(CLEAR, "\e[H\e[2J").

-type attribute() :: bold | dim | red | green | yellow | blue | magenta | cyan.
-type part() :: {[attribute()], io_lib:chars()}.
-type size() :: {pos_integer(), pos_integer()}.
-type cell() :: {string(), char()}.
-type row() :: [cell()].
-type slot() :: cell() | blank.
-type column() :: {pos_integer(), slot(), cell()}.
-type screen() :: {unsized, []} | {size(), [row()]}.

-spec unpainted() -> screen().
unpainted() ->
    {unsized, []}.

-spec update(screen(), [[part()]], size()) -> {io_lib:chars(), screen()}.
update(Screen, Lines, Size) ->
    Now = visible(Lines, Size),
    {[?HIDE, repaint(Screen, Now, Size), park(Size), ?SHOW], {Size, Now}}.

-spec repaint(screen(), [row()], size()) -> io_lib:chars().
repaint({Size, Painted}, Now, Size) ->
    row_updates(Painted, Now);
repaint(_Screen, Now, _Size) ->
    [?CLEAR, row_updates([], Now)].

-spec visible([[part()]], size()) -> [row()].
visible(Lines, {Cols, Rows}) ->
    [cells(Line, Cols) || Line <- lists:sublist(Lines, Rows - 1)].

-spec park(size()) -> io_lib:chars().
park({_Cols, Rows}) ->
    addr(Rows, 1).

-spec cells([part()], pos_integer()) -> row().
cells(Parts, Cols) ->
    lists:sublist(lists:append([part_cells(Part) || Part <- Parts]), Cols).

-spec part_cells(part()) -> row().
part_cells({Attributes, Text}) ->
    Style = style(Attributes),
    [{Style, Char} || Char <- lists:flatten(Text)].

-spec style([attribute()]) -> string().
style(Attributes) ->
    lists:append([attribute(Attribute) || Attribute <- Attributes]).

-spec attribute(attribute()) -> string().
attribute(bold) -> "\e[1m";
attribute(dim) -> "\e[2m";
attribute(red) -> "\e[31m";
attribute(green) -> "\e[32m";
attribute(yellow) -> "\e[33m";
attribute(blue) -> "\e[34m";
attribute(magenta) -> "\e[35m";
attribute(cyan) -> "\e[36m".

-spec row_updates([row()], [row()]) -> io_lib:chars().
row_updates(Painted, Lines) ->
    Height = max(length(Painted), length(Lines)),
    Rows = lists:zip3(lists:seq(1, Height), pad(Painted, Height, []), pad(Lines, Height, [])),
    [row_update(Row, Was, Now) || {Row, Was, Now} <- Rows].

-spec pad([T], non_neg_integer(), T) -> [T].
pad(Items, Length, Filler) ->
    Items ++ lists:duplicate(Length - length(Items), Filler).

-spec row_update(pos_integer(), row(), row()) -> io_lib:chars().
row_update(_Row, Same, Same) ->
    [];
row_update(Row, Was, Now) ->
    Width = length(Now),
    Columns = lists:zip3(lists:seq(1, Width), on_screen(Was, Width), Now),
    [[paint_run(Row, Col, Run) || {Col, Run} <- changed_runs(Columns, [])],
        clear_tail(Row, length(Was), Width)].

-spec on_screen(row(), non_neg_integer()) -> [slot()].
on_screen(Was, Width) ->
    pad(lists:sublist(Was, Width), Width, blank).

-spec changed_runs([column()], [{pos_integer(), row()}]) -> [{pos_integer(), row()}].
changed_runs([], Acc) ->
    lists:reverse(Acc);
changed_runs([{_Col, Same, Same} | Rest], Acc) ->
    changed_runs(Rest, Acc);
changed_runs([{Col, _Was, Now} | Rest], Acc) ->
    {Run, Tail} = run_from(Rest, [Now]),
    changed_runs(Tail, [{Col, Run} | Acc]).

-spec run_from([column()], row()) -> {row(), [column()]}.
run_from([{_Col, Same, Same} | _] = Tail, Acc) ->
    {lists:reverse(Acc), Tail};
run_from([], Acc) ->
    {lists:reverse(Acc), []};
run_from([{_Col, _Was, Now} | Rest], Acc) ->
    run_from(Rest, [Now | Acc]).

-spec paint_run(pos_integer(), pos_integer(), row()) -> io_lib:chars().
paint_run(Row, Col, Run) ->
    [addr(Row, Col), cell_bytes(Run, none, []), ?RESET].

-spec cell_bytes(row(), string() | none, io_lib:chars()) -> io_lib:chars().
cell_bytes([], _Style, Acc) ->
    lists:reverse(Acc);
cell_bytes([{Style, Char} | Rest], Style, Acc) ->
    cell_bytes(Rest, Style, [Char | Acc]);
cell_bytes([{Style, Char} | Rest], _Other, Acc) ->
    cell_bytes(Rest, Style, [Char, Style, ?RESET | Acc]).

-spec clear_tail(pos_integer(), non_neg_integer(), non_neg_integer()) -> io_lib:chars().
clear_tail(Row, WasWidth, NowWidth) when WasWidth > NowWidth ->
    [addr(Row, NowWidth + 1), ?ERASE_RIGHT];
clear_tail(_Row, _WasWidth, _NowWidth) ->
    [].

-spec addr(pos_integer(), pos_integer()) -> io_lib:chars().
addr(Row, Col) ->
    io_lib:format("\e[~p;~pH", [Row, Col]).
