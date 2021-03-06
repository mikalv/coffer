%%% -*- erlang -*-
%%%
%%% This file is part of coffer-server released under the Apache license 2.
%%% See the NOTICE for more information.

-module(coffer_http_storage).

-export([init/3]).
-export([handle/2]).
-export([terminate/3]).

-define(LIMIT, 16#10000000).

init(_Transport, Req, []) ->
    {ok, Req, undefined}.

handle(Req, State) ->
    {Method, Req2} = cowboy_req:method(Req),
    {StorageName, Req3} = cowboy_req:binding(storage, Req2),
    {ok, Req4} = maybe_process(StorageName, Method, Req3),
    {ok, Req4, State}.

maybe_process(StorageName, <<"HEAD">>, Req) ->
    case coffer:get_storage(StorageName) of
        {error, not_found} ->
            cowboy_req:reply(404, [], [], Req);
        _ ->
            cowboy_req:reply(200, [], [], Req)
    end;
maybe_process(StorageName, <<"POST">>, Req) ->
    case coffer:get_storage(StorageName) of
        {error, not_found} ->
            coffer_http_util:not_found(Req);
        {error, Reason} ->
            coffer_http_util:error(Reason, Req);
        _ ->
            Pid = coffer:get_storage(StorageName),

            {Results, Req2} = process_multipart(Pid, Req),
            Success = lists:foldl(
                fun({BlobRef, Status}, Acc) ->
                    case Status of
                        {ok, UploadSize} ->
                            [[
                                {<<"blobref">>, BlobRef},
                                {<<"size">>, UploadSize}
                            ]|Acc];
                        _ ->
                            Acc
                    end
                end,
                [],
                Results
            ),
            Errors = lists:foldl(
                fun({BlobRef, Status}, Acc) ->
                    case Status of
                        {ok, _} ->
                            Acc;
                        _Error ->
                            [[
                                {<<"blobref">>, BlobRef},
                                {<<"reason">>, <<"TBD">>}
                            ]|Acc]
                    end
                end,
                [],
                Results
            ),
            StatusMessage = [
                { <<"received">>, Success },
                { <<"errors">>, Errors }
            ],
            {Json, Req3} = coffer_http_util:to_json(StatusMessage,
                                                    Req2),
            cowboy_req:reply(201, [{<<"Content-Type">>, <<"application/json">>}],
                             Json, Req3)
    end;
maybe_process(StorageName, <<"GET">>, Req) ->
    case coffer:get_storage(StorageName) of
        {error, not_found} ->
            coffer_http_util:not_found(Req);
        {error, Reason} ->
            coffer_http_util:error(Reason, Req);
        Storage ->
            {Limit, Req2} = case cowboy_req:qs_val(<<"limit">>, Req) of
                {undefined, Req1} -> {?LIMIT, Req1};
                {L, Req1} -> {list_to_integer(binary_to_list(L)), Req1}
            end,
            {ok, EnumeratePid} = coffer:start_enumerate(Storage),
            BodyFun = fun(ChunkFun) ->
                    StartBody =  <<"{\"blobs\": [\n" >>,

                    ChunkFun(StartBody),
                    do_enumerate(EnumeratePid, ChunkFun, <<"">>, 0,
                                 Limit - 1),
                    ChunkFun(<< "\n]}" >>),
                    ok
            end,
            cowboy_req:reply(200, [{<<"Content-Type">>,
                                    <<"application/json">>}],
                             {chunked, BodyFun}, Req2)
    end;
maybe_process(_, _, Req) ->
    coffer_http_util:not_allowed([<<"HEAD">>, <<"GET">>, <<"POST">>], Req).

terminate(_Reason, _Req, _State) ->
    ok.

%% ---
do_enumerate(EnumeratePid, _ChunkFun, _Pre, Count, Limit)
        when Count > Limit ->
    coffer:stop_enumerate(EnumeratePid),
    ok;
do_enumerate(EnumeratePid, ChunkFun, Pre, Count, Limit) ->
    case coffer:enumerate(EnumeratePid) of
        done ->
            ok;
        {error, Reason} ->
            Json = jsx:encode([{<<"error">>, Reason}]),
            ChunkFun(iolist_to_binary([Pre, Json])),
            ok;
        {ok, {BlobRef, Size}} ->
            Json = jsx:encode([{<<"blobref">>, BlobRef},
                               {<<"size">>, Size}]),
            ChunkFun(iolist_to_binary([Pre, Json])),
            do_enumerate(EnumeratePid, ChunkFun, <<",\n">>, Count+1,
                         Limit)
    end.

multipart_data(Req) ->
    case cowboy_req:multipart_data(Req) of
        {headers, Headers, Req2} ->
            {{headers, Headers}, Req2};
        {body, Data, Req2} ->
            {{body, Data}, Req2};
        {end_of_part, Req2} ->
            {end_of_part, Req2};
        {eof, Req2} ->
            {eof, Req2};
        {ok, undefined, Req2} ->
            {undefined, Req2};
        WTF ->
            lager:error("Multipart unknown return value: ~p", [WTF]),
            WTF
    end.

process_multipart(Pid, Req) ->
    {Reply, Req2} = multipart_data(Req),

    case Reply of
        {headers, _Headers} ->
            get_part(Pid, Reply, <<>>, [], [], Req2);
        {eof, Req2} ->
            {error, no_part, Req2};
        {ok, undefined, Req2} ->
            {error, no_part, Req2}
    end.

get_part(Pid, {headers, Headers}, _, _, Acc, Req) ->
    DispositionBinary = proplists:get_value(<<"content-disposition">>, Headers),
    Disposition = cowboy_multipart:content_disposition(DispositionBinary),
    {_FormDataTag, Props} = Disposition,
    BlobRef = proplists:get_value(<<"name">>, Props),
    lager:info("BlobRef ~p", [BlobRef]),

    case coffer:new_upload(Pid, BlobRef) of
        {ok, Receiver} ->
            {Reply, Req2} = multipart_data(Req),
            get_part(Pid, Reply, BlobRef, Receiver, Acc, Req2);
        Error ->
            BlobReport = {BlobRef, Error},
            UpdatedAcc = [BlobReport|Acc],
            {ok, Req2} = cowboy_req:multipart_skip(Req),
            {Reply, Req3} = multipart_data(Req2),
            get_part(Pid, Reply, <<>>, [], UpdatedAcc, Req3)
    end;

get_part(Pid, {body, Data}, BlobRef, Receiver, Acc, Req) ->
    lager:info("Got some data ~p", [Data]),
    case coffer:upload(Receiver, Data) of
        {ok, Receiver1} ->
            {Reply, Req2} = multipart_data(Req),
            get_part(Pid, Reply, BlobRef, Receiver1, Acc, Req2);
        Error ->
            BlobReport = {BlobRef, Error},
            UpdatedAcc = [BlobReport|Acc],
            {ok, Req2} = cowboy_req:multipart_skip(Req),
            {Reply, Req3} = multipart_data(Req2),
            get_part(Pid, Reply, <<>>, [], UpdatedAcc, Req3)
    end;

get_part(Pid, end_of_part, BlobRef, Receiver, Acc, Req) ->
    lager:info("End of PART!!!"),
    UpdatedAcc = case coffer:upload(Receiver, eob) of
        {ok, UploadSize} ->
            BlobReport = {BlobRef, {ok, UploadSize}},
            [BlobReport|Acc];
        Error ->
            BlobReport = {BlobRef, Error},
            [BlobReport|Acc]
    end,
    {Reply, Req2} = multipart_data(Req),
    case Reply of
        {headers, _} ->
            get_part(Pid, Reply, <<>>, [], UpdatedAcc, Req2);
        eof ->
            {UpdatedAcc, Req2}
    end;

get_part(_, eof, _, _, Acc, Req) ->
    {Acc, Req}.
