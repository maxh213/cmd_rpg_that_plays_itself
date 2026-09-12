-module(gate_tests).
-include_lib("eunit/include/eunit.hrl").

src_files() ->
    Files = filelib:wildcard("src/*.erl"),
    ?assert(length(Files) >= 7),
    Files.

no_comments_in_src_test() ->
    lists:foreach(fun assert_comment_free/1, src_files()).

assert_comment_free(File) ->
    {ok, Bin} = file:read_file(File),
    Lines = binary:split(Bin, <<"\n">>, [global]),
    lists:foreach(fun(Line) -> assert_line_comment_free(File, Line) end, Lines).

assert_line_comment_free(File, Line) ->
    Code = strip_string_literals(Line),
    ?assertEqual({File, nomatch}, {File, binary:match(Code, <<"%">>)}).

strip_string_literals(Line) ->
    re:replace(Line, "\\\"[^\\\"]*\\\"", <<>>, [global, {return, binary}]).

dependency_direction_holds_test() ->
    Lower = ["character", "enemy", "display", "combat", "util"],
    lists:foreach(fun assert_lower_module_clean/1, Lower),
    assert_free_of("world_server", "rpg_app").

assert_lower_module_clean(Module) ->
    assert_free_of(Module, "world_server"),
    assert_free_of(Module, "rpg_app").

assert_free_of(Module, Forbidden) ->
    {ok, Bin} = file:read_file(filename:join("src", Module ++ ".erl")),
    ?assertEqual({Module, Forbidden, nomatch}, {Module, Forbidden, binary:match(Bin, list_to_binary(Forbidden))}).
