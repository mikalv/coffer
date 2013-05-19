%%% -*- erlang -*-
%%%
%%% This file is part of coffer released under the Apache license 2.
%%% See the NOTICE for more information.

-module(coffer_storage).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start/2, stop/1]).
-export([new_upload/2, get/3, delete/2, all/1, foldl/4, foreach/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start(Backend, Config) ->
    gen_server:start_link(?MODULE, [Backend, Config], []).

stop(Pid) ->
    gen_server:call(Pid, stop).


new_upload(Pid, BlobRef) ->
    gen_server:call(Pid, {new_upload, BlobRef}).

get(Pid, Id, Options) ->
    gen_server:call(Pid, {get, Id, Options}).

delete(Pid, Id) ->
    gen_server:call(Pid, {delete, Id}).

all(Pid) ->
    gen_server:call(Pid, {all}).

foldl(Pid, Func, InitState, Options) ->
    gen_server:call(Pid, {foldl, Func, InitState, Options}).

foreach(Pid, Func) ->
    gen_server:call(Pid, {foreach, Func}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-record(ss, {
    backend,
    config,
    state
}).

init([GivenBackend, GivenConfig]) ->
    case GivenBackend:init(GivenConfig) of
        {ok, State} ->
            SS = #ss{backend=GivenBackend, config=GivenConfig, state=State},
            {ok, SS};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({stop}, _From, #ss{backend=Backend, state=State}=SS) ->
    case Backend:terminate(State) of
        ok ->
            {stop, normal, ok, SS};
        {error, Reason} ->
            % TODO not too sure what to do here...
            {reply, {error, Reason}, SS}
    end;
handle_call({new_upload, BlobRef}, _From, #ss{backend=Backend,
                                              state=State}=SS) ->
    case Backend:new_receiver(State, BlobRef) of
        {ok, {_ReceiverPid, _Config}=Receiver, NewState} ->
            {reply, {ok, Receiver}, SS#ss{state=NewState}};
        {error, Reason, NewState} ->
            {reply, {error, Reason}, SS#ss{state=NewState}}
    end;
handle_call({get, Id, Options}, _From, #ss{backend=Backend, state=State}=SS) ->
    case Backend:handle_get(State, Id, Options) of
        {error, Reason} ->
            {reply, {error, Reason}, SS};
        Reply ->
            {reply, Reply, SS}
    end;
handle_call({delete, Id}, _From, #ss{backend=Backend, state=State}=SS) ->
    case Backend:handle_delete(State, Id) of
        {ok, NewState} ->
            UpdatedSS = SS#ss{state=NewState},
            {reply, ok, UpdatedSS};
        {error, Reason} ->
            {reply, {error, Reason}, SS}
    end;
handle_call({all}, _From, #ss{backend=Backend, state=State}=SS) ->
    case Backend:handle_all(State) of
        {error, Reason} ->
            {reply, {error, Reason}, SS};
        Reply ->
            {reply, Reply, SS}
    end;
handle_call({foldl, Func, InitState, Options}, _From, #ss{backend=Backend, state=State}=SS) ->
    case Backend:handle_foldl(State, Func, InitState, Options) of
        {error, Reason} ->
            {reply, {error, Reason}, SS};
        Reply ->
            {reply, Reply, SS}
    end;
handle_call({foreach, Func}, _From, #ss{backend=Backend, state=State}=SS) ->
    case Backend:handle_all(State, Func) of
        {error, Reason} ->
            {reply, {error, Reason}, SS};
        Reply ->
            {reply, Reply, SS}
    end;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #ss{backend=Backend, state=State}=_SS) ->
    Backend:terminate(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ---------------------------------------------------------------------------
%% Internal Function Definitions
%% ---------------------------------------------------------------------------


