%% Copyright (c) 2013-2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_auth_mongo).

-include("emqx_auth_mongo.hrl").

-include_lib("emqx/include/emqx.hrl").

-export([check/2, description/0]).

-behaviour(ecpool_worker).

-export([replvar/2, replvars/2, connect/1, query/2, query_multi/2]).

-define(EMPTY(Username), (Username =:= undefined orelse Username =:= <<>>)).

check(Credentials = #{username := Username, password := Password}, _Config)
        when ?EMPTY(Username); ?EMPTY(Password) ->
    {ok, Credentials#{auth_result => bad_username_or_password}};

check(Credentials = #{password := Password}, #{authquery := AuthQuery, superquery := SuperQuery}) ->
    #authquery{collection = Collection, field = Fields,
               hash = HashType, selector = Selector} = AuthQuery,
    case query(Collection, maps:from_list(replvars(Selector, Credentials))) of
        undefined -> ok;
        UserMap ->
            Result = case [maps:get(Field, UserMap, undefined) || Field <- Fields] of
                        [undefined] -> {error, password_error};
                        [PassHash] -> check_pass(PassHash, Password, HashType);
                        [PassHash, Salt|_] -> check_pass(PassHash, Salt, Password, HashType)
                     end,
            case Result of
                ok -> {stop, Credentials#{is_superuser => is_superuser(SuperQuery, Credentials),
                                          auth_result => success}};
                {error, Error} -> {stop, Credentials#{auth_result => Error}}
            end
    end.

check_pass(PassHash, Password, HashType) ->
    check_pass(PassHash, emqx_passwd:hash(HashType, Password)).

check_pass(PassHash, _Salt, Password, plain) ->
    check_pass(PassHash, Password, plain);
check_pass(PassHash, Salt, Password, {pbkdf2, Macfun, Iterations, Dklen}) ->
    check_pass(PassHash, emqx_passwd:hash(pbkdf2, {Salt, Password, Macfun, Iterations, Dklen}));
check_pass(PassHash, Salt, Password, {salt, bcrypt}) ->
    check_pass(PassHash, emqx_passwd:hash(bcrypt, {Salt, Password}));
check_pass(PassHash, Salt, Password, {salt, HashType}) ->
    check_pass(PassHash, emqx_passwd:hash(HashType, <<Salt/binary, Password/binary>>));
check_pass(PassHash, Salt, Password, {HashType, salt}) ->
    check_pass(PassHash, emqx_passwd:hash(HashType, <<Password/binary, Salt/binary>>)).

check_pass(PassHash, PassHash) -> ok;
check_pass(_Hash1, _Hash2)     -> {error, password_error}.

description() -> "Authentication with MongoDB".

%%--------------------------------------------------------------------
%% Is Superuser?
%%--------------------------------------------------------------------

-spec(is_superuser(undefined | #superquery{}, emqx_types:credentials()) -> boolean()).
is_superuser(undefined, _Credentials) ->
    false;
is_superuser(#superquery{collection = Coll, field = Field, selector = Selector}, Credentials) ->
    Row = query(Coll, maps:from_list(replvars(Selector, Credentials))),
    case maps:get(Field, Row, false) of
        true   -> true;
        _False -> false
    end.

replvars(VarList, Credentials) ->
    lists:map(fun(Var) -> replvar(Var, Credentials) end, VarList).

replvar({Field, <<"%u">>}, #{username := Username}) ->
    {Field, Username};
replvar({Field, <<"%c">>}, #{client_id := ClientId}) ->
    {Field, ClientId};
replvar(Selector, _Client) ->
    Selector.

%%--------------------------------------------------------------------
%% MongoDB Connect/Query
%%--------------------------------------------------------------------

connect(Opts) ->
    Type = proplists:get_value(type, Opts, single),
    Hosts = proplists:get_value(hosts, Opts, []),
    Options = proplists:get_value(options, Opts, []),
    WorkerOptions = proplists:get_value(worker_options, Opts, []),
    mongo_api:connect(Type, Hosts, Options, WorkerOptions).

query(Collection, Selector) ->
    ecpool:with_client(?APP, fun(Conn) -> mongo_api:find_one(Conn, Collection, Selector, #{}) end).

query_multi(Collection, SelectorList) ->
    lists:foldr(fun(Selector, Acc) ->
        case query(Collection, Selector) of
            undefined -> Acc;
            Result -> [Result|Acc]
        end
    end, [], SelectorList).

