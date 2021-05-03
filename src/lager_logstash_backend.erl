-module(lager_logstash_backend).

%% Started from the lager logstash backend
-author('marc.e.campbell@gmail.com').
-author('mhald@mac.com').

-behaviour(gen_event).

-export([init/1,
         handle_call/2,
         handle_event/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         logtime/0,
         get_app_version/0
]).

-define(RECONNECT_TIME, 2000).

-record(state, {
  protocol :: udp | tcp,
  socket :: pid(),
  connected = false :: true | false,
  lager_level_type :: 'mask' | 'number' | 'unknown',
  level :: atom(),
  logstash_host :: string(),
  logstash_port :: number(),
  logstash_address :: inet:ip_address(),
  node_role :: string(),
  node_version :: string(),
  metadata :: list()
}).

init(Params) ->
  %% we need the lager version, but we aren't loaded, so... let's try real hard
  %% this is obviously too fragile
  {ok, Properties}     = application:get_all_key(),
  {vsn, Lager_Version} = proplists:lookup(vsn, Properties),
  Lager_Level_Type =
    case string:to_float(Lager_Version) of
      {V1, _} when V1 < 2.0 ->
        'number';
      {V2, _} when V2 =:= 2.0 ->
        'mask';
      {_, _} ->
        'unknown'
    end,

  Level = lager_util:level_to_num(proplists:get_value(level, Params, debug)),
  Host = proplists:get_value(logstash_host, Params, "localhost"),
  Port = proplists:get_value(logstash_port, Params, 9125),
  Protocol = proplists:get_value(protocol, Params, udp),
  Node_Role = proplists:get_value(node_role, Params, "no_role"),
  Node_Version = proplists:get_value(node_version, Params, "no_version"),

  Metadata = proplists:get_value(metadata, Params, []) ++
     [
      {pid, [{encoding, process}]},
      {function, [{encoding, atom}]},
      {line, [{encoding, integer}]},
      {file, [{encoding, string}]},
      {module, [{encoding, atom}]}
     ],

  Address =
   case inet:getaddr(Host, inet) of
     {ok, Addr} -> Addr;
     {error, _Err} -> Host
   end,

  erlang:send_after(0, self(), connect),
  {ok, #state{
              protocol = Protocol,
              lager_level_type = Lager_Level_Type,
              level = Level,
              logstash_host = Host,
              logstash_port = Port,
              logstash_address = Address,
              node_role = Node_Role,
              node_version = Node_Version,
              metadata = Metadata}}.

handle_call({set_loglevel, Level}, State) ->
  {ok, ok, State#state{level=lager_util:level_to_num(Level)}};

handle_call(get_loglevel, State) ->
  {ok, State#state.level, State};

handle_call(_Request, State) ->
  {ok, ok, State}.

handle_event({log, _}, #state{socket=S}=State) when S =:= undefined ->
  {ok, State};
handle_event({log, {lager_msg, Q, Metadata, Severity, {Date, Time}, _, Message}}, State) ->
  handle_event({log, {lager_msg, Q, Metadata, Severity, {Date, Time}, Message}}, State);

handle_event({log, {lager_msg, _, Metadata, Severity, {Date, Time}, Message}}, #state{level=L, metadata=Config_Meta}=State) ->
  case lager_util:level_to_num(Severity) =< L of
    true ->
      Encoded_Message = encode_json_event(State#state.lager_level_type,
                                                  node(),
                                                  State#state.node_role,
                                                  State#state.node_version,
                                                  Severity,
                                                  Date,
                                                  Time,
                                                  Message,
                                                  metadata(Metadata, Config_Meta)),
      send(Encoded_Message, State);
    _ ->
      ok
  end,
  {ok, State};

handle_event(_Event, State) ->
  {ok, State}.

handle_info(connect, State = #state{protocol = udp}) ->
  Socket =
  case gen_udp:open(0, [binary]) of
    {ok, Sock} -> Sock;
    {error, _What} ->
      reconnect(),
      undefined
  end,
  {ok, State#state{socket = Socket}};
handle_info(connect, State = #state{protocol = tcp, logstash_address = Peer, logstash_port = Port}) ->
  Socket =
  case gen_tcp:connect(Peer, Port, [{active, false}, {keepalive, true}, {mode, binary}, {reuseaddr, true}]) of
    {ok, Sock} -> Sock;
    {error, _What} ->
      reconnect(),
      undefined
  end,
  {ok, State#state{socket = Socket}};
handle_info({tcp_closed, Socket}, S=#state{socket = Socket}) ->
  reconnect(),
  {ok, S#state{socket = undefined}};
handle_info({tcp_error, Socket, _}, S=#state{socket = Socket}) ->
  reconnect(),
  {ok, S#state{socket = undefined}};
handle_info(_Info, State) ->
  {ok, State}.

terminate(_Reason, #state{protocol = tcp, socket=S}=_State) ->
  gen_tcp:close(S),
  ok;
terminate(_Reason, #state{protocol = udp, socket=S}=_State) ->
  gen_udp:close(S),
  ok;
terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  %% TODO version number should be read here, or else we don't support upgrades
  Vsn = get_app_version(),
  {ok, State#state{node_version=Vsn}}.

reconnect() ->
  erlang:send_after(?RECONNECT_TIME, self(),  connect).

send(Message, #state{protocol = udp, socket = Sock, logstash_address = Peer, logstash_port = Port}) ->
  gen_udp:send(Sock, Peer, Port, Message);
send(Message, #state{protocol = tcp, socket = Sock}) ->
  gen_tcp:send(Sock, [Message, "\n"]);
send(P1, P2) ->
  io:format("Msg: ~p, State: ~p",[P1, P2]).

encode_json_event(_, Node, Node_Role, Node_Version, Severity, Date, Time, Message, Metadata) ->
  TimeWithoutUtc = re:replace(Time, "(\\s+)UTC", "", [{return, list}]),
  DateTime = io_lib:format("~sT~sZ", [Date,TimeWithoutUtc]),
  jiffy:encode({[
                {<<"fields">>,
                    {[
                        {<<"level">>, Severity},
                        {<<"role">>, list_to_binary(Node_Role)},
                        {<<"role_version">>, list_to_binary(Node_Version)},
                        {<<"node">>, Node}
                    ] ++ Metadata }
                },
                {<<"@timestamp">>, list_to_binary(DateTime)}, %% use the logstash timestamp
                {<<"message">>, safe_list_to_binary(Message)},
                {<<"type">>, <<"erlang">>}
            ]
  }).

safe_list_to_binary(L) when is_list(L) ->
  unicode:characters_to_binary(L);
safe_list_to_binary(L) when is_binary(L) ->
  unicode:characters_to_binary(L).

get_app_version() ->
  [App,_Host] = string:tokens(atom_to_list(node()), "@"),
  Apps = application:which_applications(),
  case proplists:lookup(list_to_atom(App), Apps) of
    none ->
      "no_version";
    {_, _, V} ->
      V
  end.

logtime() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = erlang:universaltime(),
    lists:flatten(io_lib:format("~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~2.10.0B.~.10.0BZ",
        [Year, Month, Day, Hour, Minute, Second, 0])).

metadata(Metadata, Config_Meta) ->
    Expanded = [{Name, Properties, proplists:get_value(Name, Metadata)} || {Name, Properties} <- Config_Meta],
    [{list_to_binary(atom_to_list(Name)), encode_value(Value, proplists:get_value(encoding, Properties))} || {Name, Properties, Value} <- Expanded, Value =/= undefined].

encode_value(Val, string) when is_list(Val) -> list_to_binary(Val);
encode_value(Val, string) when is_binary(Val) -> Val;
encode_value(Val, string) when is_atom(Val) -> list_to_binary(atom_to_list(Val));
encode_value(Val, binary) when is_list(Val) -> list_to_binary(Val);
encode_value(Val, binary) -> Val;
encode_value(Val, process) when is_pid(Val) -> list_to_binary(pid_to_list(Val));
encode_value(Val, process) when is_list(Val) -> list_to_binary(Val);
encode_value(Val, process) when is_atom(Val) -> list_to_binary(atom_to_list(Val));
encode_value(Val, integer) -> list_to_binary(integer_to_list(Val));
encode_value(Val, atom) -> list_to_binary(atom_to_list(Val));
encode_value(_Val, undefined) -> throw(encoding_error).
