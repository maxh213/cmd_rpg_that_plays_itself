-module(world_server).
-behaviour(gen_server).

-export([start_link/0]).
-export([move/2]).
-export([get_state/0]).
-export([get_my_state/1]).
-export([get_enemy_state/1]).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).

-define(CHAR_COUNT, 6).
-define(ENEMY_COUNT, 12).
-define(SHOP_COUNT, 3).
-define(INN_COUNT, 2).
-define(DISPLAY_INTERVAL, 500).
-define(RESPAWN_DELAY, 2500).

-type state() :: world:world_state().

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec move(pid(), util:direction()) -> ok.
move(Pid, Direction) ->
    gen_server:cast(?MODULE, {move, Pid, Direction}).

-spec get_state() -> state().
get_state() ->
    gen_server:call(?MODULE, get_state).

-spec get_my_state(pid()) -> world:character_view().
get_my_state(Pid) ->
    gen_server:call(?MODULE, {get_my_state, Pid}).

-spec get_enemy_state(pid()) -> world:enemy_view().
get_enemy_state(Pid) ->
    gen_server:call(?MODULE, {get_enemy_state, Pid}).

-spec init([]) -> {ok, state()}.
init([]) ->
    rand:seed(exsss),
    Characters = spawn_characters(?CHAR_COUNT),
    Enemies = spawn_enemies(?ENEMY_COUNT),
    Shops = world:shops(?SHOP_COUNT),
    Inns = world:inns(?INN_COUNT),
    DisplayPid = display:start(self()),
    erlang:send_after(?DISPLAY_INTERVAL, self(), render),
    {ok, #{
        characters => Characters,
        enemies => Enemies,
        shops => Shops,
        inns => Inns,
        display_pid => DisplayPid,
        event_log => [],
        move_count => 0
    }}.

-spec handle_call(get_state | {get_my_state | get_enemy_state, pid()} | term(),
                    gen_server:from(), state()) ->
    {reply, state() | world:character_view() | world:enemy_view() | ok, state()}.
handle_call(get_state, _From, State) ->
    {reply, State, State};
handle_call({get_my_state, Pid}, _From, State) ->
    {reply, world:character_view(Pid, State), State};
handle_call({get_enemy_state, Pid}, _From, State) ->
    {reply, world:enemy_view(Pid, maps:get(enemies, State)), State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

-spec handle_cast({move, pid(), util:direction()} | term(), state()) -> {noreply, state()}.
handle_cast({move, Pid, Direction}, State) ->
    {NewState, Effects} = world:move(Pid, Direction, State),
    run_effects(Effects),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(render | world:effect() | term(), state()) -> {noreply, state()}.
handle_info(render, State) ->
    #{enemies := Enemies, shops := Shops, inns := Inns,
        display_pid := DPid, move_count := MC} = State,
    {NewChars, FullLog, Effects} = world:render_tick(State),
    run_effects(Effects),
    DPid ! {render, NewChars, Enemies, Shops, Inns, FullLog, MC},
    erlang:send_after(?DISPLAY_INTERVAL, self(), render),
    {noreply, State#{characters := NewChars, event_log := []}};
handle_info({respawn_char, Name, Race}, State) ->
    {Info, Entries} = world:respawn_character(Name, Race),
    Pid = start_character(Race),
    Chars = maps:get(characters, State),
    NewLog = world:append_log(maps:get(event_log, State), Entries),
    {noreply, State#{characters := Chars#{Pid => Info}, event_log := NewLog}};
handle_info({respawn_enemy, Name, Level}, State) ->
    {Info, Entries} = world:respawn_enemy(Name, Level),
    Pid = start_enemy(Level),
    Enemies = maps:get(enemies, State),
    NewLog = world:append_log(maps:get(event_log, State), Entries),
    {noreply, State#{enemies := Enemies#{Pid => Info}, event_log := NewLog}};
handle_info(_Msg, State) ->
    {noreply, State}.

-spec spawn_characters(pos_integer()) -> #{pid() => world:character()}.
spawn_characters(Count) ->
    lists:foldl(fun(_, Acc) ->
        {Race, Info} = world:random_character(),
        Acc#{start_character(Race) => Info}
    end, #{}, lists:seq(1, Count)).

-spec spawn_enemies(pos_integer()) -> #{pid() => world:enemy()}.
spawn_enemies(Count) ->
    lists:foldl(fun(_, Acc) ->
        {Level, Info} = world:random_enemy(),
        Acc#{start_enemy(Level) => Info}
    end, #{}, lists:seq(1, Count)).

-spec start_character(util:race()) -> pid().
start_character(Race) ->
    character:start(Race, fun get_my_state/1, fun move/2).

-spec start_enemy(pos_integer()) -> pid().
start_enemy(Level) ->
    enemy:start(Level, fun get_enemy_state/1, fun move/2).

-spec run_effects([world:effect()]) -> ok.
run_effects(Effects) ->
    lists:foreach(fun run_effect/1, Effects).

-spec run_effect(world:effect()) -> reference() | world:order().
run_effect({respawn_char, Name, Race}) ->
    erlang:send_after(?RESPAWN_DELAY, self(), {respawn_char, Name, Race});
run_effect({respawn_enemy, Name, Level}) ->
    erlang:send_after(?RESPAWN_DELAY, self(), {respawn_enemy, Name, Level});
run_effect({tell, Pid, Msg}) ->
    Pid ! Msg.
