-module(gate_tests).
-include_lib("eunit/include/eunit.hrl").

layers() ->
    [{"rpg_app", 5},
     {"world_server", 4},
     {"character", 3},
     {"enemy", 3},
     {"display", 3},
     {"world", 2},
     {"combat", 1},
     {"util", 0}].

src_modules() ->
    lists:sort([filename:basename(F, ".erl") || F <- filelib:wildcard("src/*.erl")]).

module_inventory_is_fixed_test() ->
    ?assertEqual(lists:sort([M || {M, _} <- layers()]), src_modules()).

no_comments_in_src_test() ->
    lists:foreach(fun assert_comment_free/1, src_modules()).

assert_comment_free(Module) ->
    {ok, Bin} = file:read_file(filename:join("src", Module ++ ".erl")),
    Lines = binary:split(Bin, <<"\n">>, [global]),
    lists:foreach(fun(Line) -> assert_line_comment_free(Module, Line) end, Lines).

assert_line_comment_free(Module, Line) ->
    Code = strip_string_literals(Line),
    ?assertEqual({Module, nomatch}, {Module, binary:match(Code, <<"%">>)}).

strip_string_literals(Line) ->
    re:replace(Line, "\\\"[^\\\"]*\\\"", <<>>, [global, {return, binary}]).

dependency_direction_holds_test() ->
    lists:foreach(fun assert_dependencies_point_down/1, layers()).

assert_dependencies_point_down({Module, Level}) ->
    {ok, Bin} = file:read_file(filename:join("src", Module ++ ".erl")),
    Forbidden = [M || {M, L} <- layers(), L >= Level, M =/= Module],
    lists:foreach(fun(F) -> assert_no_reference(Module, Bin, F) end, Forbidden).

assert_no_reference(Module, Bin, Forbidden) ->
    Pattern = "(^|[^a-zA-Z0-9_])" ++ Forbidden ++ ":",
    ?assertEqual({Module, Forbidden, nomatch},
                 {Module, Forbidden, re:run(Bin, Pattern, [{capture, none}])}).
