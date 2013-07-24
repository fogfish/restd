%% @description
%%    acceptor process
-module(restd_acceptor).
-behaviour(kfsm).

-export([
	start_link/2,
	start_link/3,
	init/1,
	free/2,
	'LISTEN'/3,
	'ACCEPT'/3,
	'HANDLE'/3
]).

%% default state
-record(fsm, {
	uid,
	resource,
	request,
	content,
	q
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

%% start acceptor process
start_link(Uid, Uri) ->
	kfsm_pipe:start_link(?MODULE, [Uid, Uri]).

%% start listener process
start_link(Uid, Uri, Pool) ->
	%% TODO: registered service (pipe library)
	kfsm_pipe:start_link(?MODULE, [Uid, Uri, Pool]).

init([Uid, Uri]) ->
	{ok, _} = knet:bind(Uri),
	{ok, 'ACCEPT', 
		#fsm{
			uid = Uid,
			q   = deq:new()
		}
	};

init([Uid, Uri, Pool]) ->
	{ok, _} = knet:listen(Uri, [{acceptor, restd_acceptor_sup}, {pool, Pool}]),
	{ok, 'LISTEN', 
		#fsm{
			uid = Uid
		}
	}.

free(Reason, _) ->
	ok.

%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(_, _, S) ->
	{next_state, 'LISTEN', S}.

%%%------------------------------------------------------------------
%%%
%%% ACCEPT
%%%
%%%------------------------------------------------------------------   

%%
%%
'ACCEPT'({http, Uri, {Mthd, _}}=Req, Pipe, S) ->
	try
		Mod = lookup_resource(S#fsm.uid, Uri),
		ok  = assert_method(Mthd, Mod:allowed_methods()),
		handle_request(Mod, Req, Pipe, S)
	catch _:Reason ->
		io:format("--> ~p~n~p~n", [Uri, Reason]),
		{next_state, 'ACCEPT', S}
	end;

'ACCEPT'(_, _, S) ->
	{next_state, 'ACCEPT', S}.

%%%------------------------------------------------------------------
%%%
%%% HANDLE
%%%
%%%------------------------------------------------------------------   

'HANDLE'({http, _Uri, Msg}, _Pipe, S)
 when is_binary(Msg) ->
   {next_state, 'HANDLE', 
   	S#fsm{
   		q = deq:enq(Msg, S#fsm.q)
   	}
   }; 

'HANDLE'({http, Uri, eof}, Pipe, #fsm{resource=Mod, content=Type}=S) ->
   try
   	{http, Uri, {Mthd, Heads}} = S#fsm.request,
   	Msg  = erlang:iolist_to_binary(deq:list(S#fsm.q)),
		Http = handle_response(Mod:Mthd(Type, Uri, Heads, Msg), Type),
		_    = pipe:a(Pipe, Http),
      {next_state, 'ACCEPT', S#fsm{q = deq:new()}}
   catch _:Reason ->
      io:format("--> ~p~n~p~n", [Uri, Reason]),
		{next_state, 'ACCEPT', S}
   end.

%%
%%
handle_request(Mod, {http, Uri, {Mthd,  Heads}}, Pipe, S)
 when Mthd =:= 'GET' orelse Mthd =:= 'DELETE' orelse Mthd =:= 'HEAD' ->
 	Type = assert_content_type(opts:val('Accept', [{'*', '*'}], Heads), Mod:content_provided()),
 	Http = handle_response(Mod:Mthd(Type, Uri, Heads), Type),
 	_    = pipe:a(Pipe, Http),
   {next_state, 'ACCEPT', S};

handle_request(Mod, {http, Uri, {Mthd,  Heads}}=Req, Pipe, S)
 when Mthd =:= 'PUT' orelse Mthd =:= 'POST' orelse Mthd =:= 'PATCH' ->
 	Type = assert_content_type([opts:val('Content-Type', Heads)], Mod:content_accepted()),
   {next_state, 
      'HANDLE',
      S#fsm{
         resource = Mod,
         request  = Req,
         content  = Type
      }
   };

handle_request(_Mod, {http, _, {_, _}}, _Pipe, _S) ->
   throw({error, not_implemented}).

%%
%%
handle_response({Code, Msg}, Type) ->
 	{Code, [{'Content-Type', Type}, {'Content-Length', size(Msg)}], Msg};
handle_response({Code, Heads, Msg}, Type) ->
	case lists:keyfind('Content-Type', 1, Heads) of
      false -> {Code, [{'Content-Type', Type}, {'Content-Length', size(Msg)} | Heads], Msg};
      _     -> {Code, [{'Content-Length', size(Msg)} | Heads], Msg}
   end; 	
handle_response(Code, Type) ->
   {Code, [{'Content-Type', Type}, {'Content-Length', 0}], <<>>}.

%%
%% 
lookup_resource(Uid, Uri) ->
	case lookup_resource_list(Uri, pns:lookup({restd, Uid}, '_')) of
		%% not_available error
		[] -> 
			throw({error, not_available});
		[{_, Mod}] ->
			Mod
	end.

lookup_resource_list(Uri, List) ->
	Req = uri:get(segments, Uri),
	lists:sort(
		fun({A, _}, {B, _}) -> size(A) =< size(B) end, 
		lists:filter(
			fun({X, _}) -> is_equiv(Req, tuple_to_list(X)) end,
			List
		)
	).
	
%%
%% assert method
assert_method(Method, ['*']) ->
   ok;
assert_method(Method, Allowed) ->
   case lists:member(Method, Allowed) of
      false -> throw({error, not_allowed});
      true  -> ok
   end.

%%
%% assert content type
assert_content_type([], B) ->
	throw({error, not_acceptable});
assert_content_type([H | T], B) ->
	case assert_content_type(H, B) of
		false -> assert_content_type(T, B);
		Type  -> Type
	end;
assert_content_type(A, B) ->
	Req = tuple_to_list(A),
	case lists:filter(fun(X) -> is_equiv(Req, tuple_to_list(X)) end, B) of
		[]   -> false;
		List -> hd(List)
	end.

%% check if two uri segments equivalent
is_equiv(['*'], _) ->
	true;
is_equiv(_, ['*']) ->
	true;
is_equiv([H|A], [_|B])
 when H =:= '_' orelse H =:= '*' ->
	is_equiv(A, B);
is_equiv([_|A], [H|B])
 when H =:= '_' orelse H =:= '*' ->
	is_equiv(A, B);
is_equiv([A|AA], [B|BB]) ->
	case eq(A, B) of
		true  -> is_equiv(AA, BB);
		false -> false
	end;
is_equiv([], []) ->
 	true;
is_equiv(_,   _) ->
 	false.

%% check if two path elements are equal
eq(A, B)
 when is_atom(A), is_binary(B) ->
 	atom_to_binary(A, utf8) =:= B;
eq(A, B)
 when is_binary(A), is_atom(B) ->
 	A =:= atom_to_binary(B, utf8);
eq(A, B) ->
	A =:= B.
