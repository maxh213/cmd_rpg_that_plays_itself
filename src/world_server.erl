-module(world_server).
-behaviour(gen_server).

-export([start_link/0, move/2, get_state/0, get_my_state/1, get_enemy_state/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHAR_COUNT, 6).
-define(ENEMY_COUNT, 12).
-define(SHOP_COUNT, 3).
-define(INN_COUNT, 2).
-define(DISPLAY_INTERVAL, 500).
-define(RESPAWN_DELAY, 2500).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

move(Pid, Direction) ->
    gen_server:cast(?MODULE, {move, Pid, Direction}).

get_state() ->
    gen_server:call(?MODULE, get_state).

get_my_state(Pid) ->
    gen_server:call(?MODULE, {get_my_state, Pid}).

get_enemy_state(Pid) ->
    gen_server:call(?MODULE, {get_enemy_state, Pid}).

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

handle_call(get_state, _From, State) ->
    {reply, State, State};
handle_call({get_my_state, Pid}, _From, State) ->
    {reply, world:character_view(Pid, State), State};
handle_call({get_enemy_state, Pid}, _From, State) ->
    {reply, world:enemy_view(Pid, maps:get(enemies, State)), State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast({move, Pid, Direction}, State) ->
    {NewState, Effects} = world:move(Pid, Direction, State),
    run_effects(Effects),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

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

spawn_characters(Count) ->
    lists:foldl(fun(_, Acc) ->
        {Race, Info} = world:random_character(),
        Acc#{start_character(Race) => Info}
    end, #{}, lists:seq(1, Count)).

spawn_enemies(Count) ->
    lists:foldl(fun(_, Acc) ->
        {Level, Info} = world:random_enemy(),
        Acc#{start_enemy(Level) => Info}
    end, #{}, lists:seq(1, Count)).

start_character(Race) ->
    character:start(Race, fun get_my_state/1, fun move/2).

start_enemy(Level) ->
    enemy:start(Level, fun get_enemy_state/1, fun move/2).

run_effects(Effects) ->
    lists:foreach(fun run_effect/1, Effects).

run_effect({respawn_char, Name, Race}) ->
    erlang:send_after(?RESPAWN_DELAY, self(), {respawn_char, Name, Race});
run_effect({respawn_enemy, Name, Level}) ->
    erlang:send_after(?RESPAWN_DELAY, self(), {respawn_enemy, Name, Level});
run_effect({tell, Pid, Msg}) ->
    Pid ! Msg.
