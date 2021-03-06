%%
%% rdpproxy
%% remote desktop proxy
%%
%% Copyright 2012-2019 Alex Wilson <alex@uq.edu.au>
%% The University of Queensland
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
%% IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
%% NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
%% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
%% THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
%% THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%%

-module(host_alloc_fsm).

-behaviour(gen_fsm).

-include("session.hrl").

-export([start/1]).
-export([init/1, handle_info/3, terminate/3, code_change/4]).
-export([check_user_sessions/2, check_user_cookies/2, check_host_cookies/2,
    list_available/2, pick_new_session/2, probe/2, save_cookie/2]).

-spec start(BaseSession :: #session{}) -> {ok, pid()}.
start(BaseSession = #session{}) ->
    gen_fsm:start(?MODULE, [self(), BaseSession], []).

-record(state, {from, mref, sess, metas=[], tried=[], exhausted=0}).

%% @private
init([From, Sess = #session{user = U}]) ->
    lager:debug("allocating session for ~p", [U]),
    MRef = erlang:monitor(process, From),
    {ok, check_user_sessions, #state{mref = MRef, from = From, sess = Sess}, 0}.

check_user_sessions(timeout, S = #state{sess = Sess = #session{user = U}}) ->
    case db_host_meta:find(user, U) of
        {ok, [{Ip, Meta} | _]} ->
            Sess1 = Sess#session{host = Ip, port = 3389},
            lager:debug("existing session found for ~p on ~p", [U, Ip]),
            {next_state, check_host_cookies,
                S#state{tried = [Ip], sess = Sess1}, 0};
        _ ->
            {next_state, check_user_cookies, S, 0}
    end.

check_user_cookies(timeout, S = #state{sess = Sess = #session{user = U}}) ->
    case db_cookie:find(user, U) of
        {ok, Cookies} when (length(Cookies) > 0) ->
            [#session{host = Ip} | _] = Cookies,
            Sess1 = Sess#session{host = Ip, port = 3389},
            lager:debug("existing cookie found for ~p on ~p", [U, Ip]),
            {next_state, check_host_cookies, S#state{tried = [Ip],
                sess = Sess1}, 0};
        _ ->
            {next_state, list_available, S, 0}
    end.

list_available(timeout, S = #state{}) ->
    case db_host_meta:find(status, <<"available">>) of
        {ok, Metas} ->
            MetasWithRand = [
                {Ip, [{random, crypto:rand_uniform(0, 1 bsl 32)} | Pl]} ||
                {Ip, Pl} <- Metas],
            SortedMetas = lists:sort(fun({IpA,A}, {IpB,B}) ->
                RoleA = proplists:get_value(<<"role">>, A),
                RoleB = proplists:get_value(<<"role">>, B),
                ImageA = proplists:get_value(<<"image">>, A, <<>>),
                ImageB = proplists:get_value(<<"image">>, B, <<>>),
                RandA = proplists:get_value(random, A, 0),
                RandB = proplists:get_value(random, B, 0),
                UpdatedA = proplists:get_value(<<"updated">>, A, 0),
                UpdatedB = proplists:get_value(<<"updated">>, B, 0),
                SessionsA = proplists:get_value(<<"sessions">>, A, []),
                SessionsB = proplists:get_value(<<"sessions">>, B, []),
                IdleStartA = case SessionsA of
                    [] -> 0;
                    _ -> lists:min([UpdatedA - proplists:get_value(<<"idle">>, S, 0) || S <- SessionsA])
                end,
                IdleStartB = case SessionsB of
                    [] -> 0;
                    _ -> lists:min([UpdatedB - proplists:get_value(<<"idle">>, S, 0) || S <- SessionsB])
                end,
                IsLabA = (binary:longest_common_prefix([ImageA, <<"lab">>]) =/= 0),
                IsLabB = (binary:longest_common_prefix([ImageB, <<"lab">>]) =/= 0),
                % A <= B  => true
                % else    => false
                %
                % lists:sort sorts ascending, and we are going to start at the
                % front, so more preferred => return true
                if
                    % prefer actual vlab machines over everything else
                    (RoleA =:= <<"vlab">>) and (not (RoleB =:= <<"vlab">>)) -> true;
                    (RoleB =:= <<"vlab">>) and (not (RoleA =:= <<"vlab">>)) -> false;
                    IsLabA and (not IsLabB) -> true;
                    IsLabB and (not IsLabA) -> false;
                    % then prefer machines with no sessions open
                    (length(SessionsA) < length(SessionsB)) -> true;
                    (length(SessionsA) > length(SessionsB)) -> false;
                    % then most recent images first
                    (ImageA > ImageB) -> true;
                    (ImageA < ImageB) -> false;
                    % if same image and same # of sessions, the one that went to
                    % "idle" earliest is preferred
                    (IdleStartA < IdleStartB) -> true;
                    (IdleStartA > IdleStartB) -> false;
                    % fall back to the randomness to spread things out
                    true -> (RandA =< RandB)
                end
            end, Metas),
            {next_state, pick_new_session, S#state{metas = SortedMetas}, 0};
        Ret ->
            lager:debug("db_host_meta:find returned ~p", [Ret]),
            {next_state, list_available, S, 1000}
    end.

pick_new_session(timeout, S = #state{metas = Metas, sess = Sess, tried = Tried}) ->
    case Metas of
        [{Ip, Meta} | Rest] ->
            Sess1 = Sess#session{host = Ip, port = 3389},
            {next_state, check_host_cookies,
                S#state{tried = [Ip | Tried], metas = Rest, sess = Sess1}, 0};
        _ ->
            lager:debug("exhausted all host candidates!"),
            {next_state, list_available,
                S#state{exhausted = S#state.exhausted + 1}, 1000}
    end.

check_host_cookies(timeout, S = #state{sess = Sess}) ->
    #session{user = U, host = Ip} = Sess,
    case db_cookie:find(host, Ip) of
        {ok, Cookies} ->
            NotMine = [S || S = #session{user = User} <- Cookies, not (User =:= U)],
            Now = calendar:datetime_to_gregorian_seconds(erlang:localtime()),
            case NotMine of
                [] ->
                    {next_state, probe, S, 0};
                _ ->
                    % If there are any cookies for a different user, veto this
                    % host... unless we've exhausted all candidates 5 times and
                    % the cookie was from >30 min ago.
                    CreatedAgo = ?COOKIE_TTL -
                        lists:max([Exp - Now || #session{expiry = Exp} <- NotMine]),
                    if
                        (S#state.exhausted > 5) and (CreatedAgo > 1800) ->
                            OtherUsers = [User || #session{user = User} <- NotMine],
                            lager:debug("recent cookies found for other users "
                                "on ~p, but still allocating ~p anyway "
                                "(last was ~p sec ago, other users = ~p)",
                                [Ip, U, CreatedAgo, OtherUsers]),
                            {next_state, probe, S, 0};
                        true ->
                            {next_state, pick_new_session, S, 0}
                    end
            end;
        _ ->
            {next_state, probe, S, 0}
    end.

probe(timeout, S = #state{sess = Sess}) ->
    #session{host = Ip, port = Port} = Sess,
    case backend:probe(binary_to_list(Ip), Port) of
        ok ->
            {next_state, save_cookie, S, 0};
        _ ->
            lager:debug("probe failed on ~p, looking at another machine", [Ip]),
            {next_state, pick_new_session, S, 0}
    end.

save_cookie(timeout, S = #state{sess = Sess}) ->
    {ok, Cookie} = db_cookie:new(Sess),
    S#state.from ! {allocated_session, self(), Sess#session{cookie = Cookie}},
    {stop, normal, S}.

handle_info({'DOWN', MRef, process, _, _}, _State, S = #state{mref = MRef}) ->
    {stop, normal, S};
handle_info(Msg, State, S = #state{}) ->
    ?MODULE:State(Msg, S).

%% @private
terminate(_Reason, _State, _Data) ->
    ok.

%% @private
% default handler
code_change(_OldVsn, State, _Data, _Extra) ->
    {ok, State}.
