% @doc 4 inline listening server.
%
% Entities:
% <ul>
% <li> 1 server process accepting connections </li>
% <li> 1 game coordinator (linked to server) </li>
% <li> 1 player process per connected client (children of the server) </li>
% <li> 1 game processes for each pair of clients playing (child of game coordinator, monitored by players, monitors players) </li>
% </ul>
%
-module(c4_server).
-export([start/0,start/1,start_loop/1, player_master/0,policy_master/0, serve_policy/2]).

-define(DEFAULT_PORT,8080).
-define(POLICY_PORT, 8043).
-define(DEFAULT_ROWS, 7).
-define(DEFAULT_COLS, 6).

% @doc Starts the server process using the default port.
start() ->
	start(?DEFAULT_PORT).

% Starts the server socket and spawns the connection accepting process
start(Port) ->
	io:format("Will Start on port ~w ~n", [Port]),
	Pid = spawn_link(c4_server, start_loop, [Port]),
	io:format("Opened process ~w ~n", [Pid]).

% Setup for the main socket listening loop.
start_loop(Port) ->
	register(c4_server, self()),
	{ok, LSock} = gen_tcp:listen(
		Port, 
		[binary, {backlog, 5}, {active, false}, {nodelay, true}]),
	io:format("Listening on port ~w ~n", [Port]),
	% Spawn game master process
	c4_game_master:start(?DEFAULT_ROWS, ?DEFAULT_COLS),
	PPid = spawn_link(?MODULE, player_master, []),
	spawn_link(?MODULE, policy_master, []),
	loop(LSock, PPid).

% @doc Main server loop, accepting incoming connections.   
loop(LSock, PPid) ->
	{ok, S} = gen_tcp:accept(LSock),
	gen_tcp:controlling_process(S, PPid),
	PPid ! {new_player, S},
	loop(LSock, PPid).

% @doc Start point for the player_master process that spawns and monitors player processes
player_master() ->
	process_flag(trap_exit, true),
	player_loop().

% @doc Main loop of the player master process.
player_loop() ->
	receive
		{new_player, S} ->
			Pid = spawn_link(c4_player, start, [S]),
			% Safely transfering msg reception to player process, which should expect a first message with tcp payload.
			% If the new process sets active=once before passing control to it, we could end up with an unexpected tcp msg in our inbox.
			gen_tcp:controlling_process(S, Pid),
			inet:setopts(S, [{active, once}]),
			player_loop();
		{'DOWN', Pid, Reason} ->
			io:format("Player process finished ~w : ~w ~n", [Pid, Reason]),
			player_loop();
		BadMsg ->
			io:format("Unexpected message to player master ~w ~n", [BadMsg])
	end.

policy_master() ->
	register(policy_master, self()),
	Port = ?POLICY_PORT,
	{ok, LSock} = gen_tcp:listen(
		Port, 
		[binary, {backlog, 5}, {active, false}, {nodelay, true}]),
	io:format("Policy server listening on port ~w ~n", [Port]),
	policy_loop(LSock).

policy_loop(LS) ->
	{ok, S} = gen_tcp:accept(LS),
	Ref = erlang:make_ref(),
	Pid = spawn(?MODULE, serve_policy, [Ref, S]),
	gen_tcp:controlling_process(S, Pid),
	Pid ! { Ref, serve },
	policy_loop(LS).

serve_policy(Ref, S) ->
	receive
		{Ref, serve} ->
			{ok, {Addr, Port}} = inet:peername(S),
%			{ok, Hostent} = inet:gethostbyaddr(Addr),
			io:format("Sending policy to ~w ~n", [{Addr,Port}]),
			gen_tcp:send(S, 
				"<?xml version='1.0'?>"
				"<cross-domain-policy>"
				"<allow-access-from domain='*' to-ports='8080'/>"
				"</cross-domain-policy>"),
			gen_tcp:close(S);
		Msg -> 
			io:format("Unexpected message for serve_policy ~w ~n", [Msg])
	after 5000 -> 
		io:format("server policy processed timed out on receive ~n", [])
	end.
	