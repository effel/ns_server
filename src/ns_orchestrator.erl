%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Monitor and maintain the vbucket layout of each bucket.
%% There is one of these per bucket.
%%
-module(ns_orchestrator).

-behaviour(gen_server).

-include("ns_common.hrl").

%% Constants and definitions

-record(state, {bucket, janitor, rebalancer, progress}).

%% API
-export([start_link/1]).

-export([failover/2,
         needs_rebalance/1,
         rebalance_progress/1,
         start_rebalance/3,
         stop_rebalance/1]).

-define(REBALANCE_SUCCESSFUL, 1).
-define(REBALANCE_FAILED, 2).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

%% API
start_link(Bucket) ->
    %% If it's already running elsewhere in the cluster, just monitor
    %% the existing process.
    case gen_server:start_link(server(Bucket), ?MODULE, Bucket, []) of
        {error, {already_started, Pid}} ->
            {ok, spawn_link(fun () -> misc:wait_for_process(Pid, infinity) end)};
        X -> X
    end.

failover(Bucket, Node) ->
    gen_server:call(server(Bucket), {failover, Node}).

needs_rebalance(Bucket) ->
    {_NumReplicas, _NumVBuckets, Map, Servers} = ns_bucket:config(Bucket),
    NumServers = length(Servers),
    %% Don't warn about missing replicas when you have fewer servers
    %% than your copy count!
    lists:any(
      fun (Chain) ->
              lists:member(
                undefined,
                lists:sublist(Chain, NumServers))
      end, Map) orelse
        unbalanced(histograms(Map, Servers)).

rebalance_progress(Bucket) ->
    try gen_server:call(server(Bucket), rebalance_progress, 2000) of
        Result -> Result
    catch
        Err ->
            ?log_error("Couldn't talk to orchestrator: ~p", [Err]),
            not_running
    end.

start_rebalance(Bucket, KeepNodes, EjectNodes) ->
    gen_server:call(server(Bucket), {start_rebalance, KeepNodes, EjectNodes}).

stop_rebalance(Bucket) ->
    gen_server:call(server(Bucket), stop_rebalance).

%% gen_server callbacks
init(Bucket) ->
    timer:send_interval(10000, janitor),
    {ok, #state{bucket=Bucket}}.

handle_call({failover, Node}, _From, State = #state{bucket = Bucket}) ->
    {_, _, Map, Servers} = ns_bucket:config(Bucket),
    %% Promote replicas of vbuckets on this node
    Map1 = promote_replicas(Bucket, Map, [Node]),
    ns_bucket:set_map(Bucket, Map1),
    ns_bucket:set_servers(Bucket, lists:delete(Node, Servers)),
    lists:foreach(fun (N) ->
                          ns_vbm_sup:kill_dst_children(N, Bucket, Node)
                  end, lists:delete(Node, Servers)),
    {reply, ok, State};
handle_call(rebalance_progress, _From, State = #state{rebalancer = {_Pid, _Ref},
                                                      progress = Progress}) ->
    {reply, {running, Progress}, State};
handle_call(rebalance_progress, _From, State) ->
    {reply, not_running, State};
handle_call({start_rebalance, KeepNodes, EjectNodes}, _From,
            State = #state{bucket=Bucket, rebalancer=undefined, janitor=Janitor}) ->
    {_NumReplicas, _NumVBuckets, Map, Servers} = ns_bucket:config(Bucket),
    Histograms = histograms(Map, Servers),
    case {lists:sort(Servers), lists:sort(KeepNodes), EjectNodes,
          unbalanced(Histograms)} of
        {S, S, [], false} ->
            error_logger:info_msg(
              "ns_orchestrator not rebalancing because already_balanced~n~p~n",
              [{Servers, KeepNodes, EjectNodes, Histograms}]),
            {reply, already_balanced, State};
        _ ->
            {ok, Pid, Ref} =
                misc:spawn_link_safe(
                  fun () ->
                          spawn_link(
                            fun() ->
                                    case Janitor of
                                        undefined ->
                                            ok;
                                        {JPid, _Ref} ->
                                            ok = misc:wait_for_process(JPid)
                                    end,
                                    do_rebalance(Bucket, KeepNodes, EjectNodes,
                                                 Map, 2)
                            end)
                  end),
            {reply, ok, State#state{rebalancer={Pid, Ref}, progress=[]}}
    end;
handle_call({start_rebalance, _, _}, _From, State) ->
    error_logger:info_msg("ns_orchestrator not rebalancing because in_progress~n", []),
    {reply, in_progress, State};
handle_call(stop_rebalance, _From, State = #state{rebalancer={Pid, _Ref}}) ->
    Pid ! stop,
    {reply, ok, State};
handle_call(stop_rebalance, _From, State) ->
    {reply, not_rebalancing, State};
handle_call(Request, From, State) ->
    error_logger:info_msg("~p:handle_call(~p, ~p, ~p)~n",
                          [?MODULE, Request, From, State]),
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast({progress, Progress}, State) ->
    {noreply, State#state{progress=Progress}};
handle_cast(Msg, State) ->
    error_logger:info_msg("~p:handle_cast(~p, ~p)~n",
                          [?MODULE, Msg, State]),
    {noreply, State}.

handle_info(janitor, State = #state{bucket=Bucket, rebalancer=undefined, janitor=undefined}) ->
    misc:flush(janitor),
    {_, _, Map, Servers} = ns_bucket:config(Bucket),
    case Servers == undefined orelse Servers == [] of
        true ->
            %% TODO: this is a hack and should happen someplace else.
            error_logger:info_msg("Performing initial rebalance~n"),
            ns_cluster_membership:activate([node()]),
            timer:apply_after(0, ?MODULE, start_rebalance, [Bucket, [node()], []]),
            {noreply, State};
        _ ->
            {ok, Pid, Ref} =
                misc:spawn_link_safe(
                  fun () ->
                          spawn_link(
                            fun () ->
                                    ns_janitor:cleanup(Bucket, Map, Servers)
                           end)
                  end),
            {noreply, State#state{janitor={Pid, Ref}}}
    end;
handle_info({Ref, Reason}, State = #state{rebalancer={_Pid, Ref}}) ->
    case Reason of
        {'EXIT', _, normal} ->
            ns_log:log(?MODULE, ?REBALANCE_SUCCESSFUL,
                       "Rebalance completed successfully.~n");
        {'EXIT', _, R} ->
            ns_log:log(?MODULE, ?REBALANCE_FAILED,
                       "Rebalance exited with reason ~p~n", [R]);
        _ ->
            ns_log:log(?MODULE, ?REBALANCE_FAILED,
                       "Rebalance failed with reason ~p~n", [Reason])
    end,
    {noreply, State#state{rebalancer=undefined}};
handle_info({Ref, _Reason}, State = #state{janitor={_Pid, Ref}}) ->
    {noreply, State#state{janitor=undefined}};
handle_info(Msg, State) ->
    error_logger:info_msg("~p:handle_info(~p, ~p)~n",
                          [?MODULE, Msg, State]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Internal functions
apply_moves(_, [], Map) ->
    Map;
apply_moves(I, [{V, _, New}|Tail], Map) ->
    Chain = lists:nth(V+1, Map),
    NewChain = misc:nthreplace(I, New, Chain),
    apply_moves(I, Tail, misc:nthreplace(V+1, NewChain, Map)).

assign(Histogram, AvoidNodes) ->
    Histogram1 = lists:keysort(2, Histogram),
    case lists:splitwith(fun ({N, _}) -> lists:member(N, AvoidNodes) end,
                         Histogram1) of
        {Head, [{Node, N}|Rest]} ->
            {Node, Head ++ [{Node, N+1}|Rest]};
        {_, []} ->
            {undefined, Histogram1}
    end.

balance_nodes(Bucket, Map, Histograms, I) when is_integer(I) ->
    VNF = [{V, lists:nth(I, Chain), lists:sublist(Chain, I-1)} ||
              {V, Chain} <- misc:enumerate(Map, 0)],
    Hist = lists:nth(I, Histograms),
    balance_nodes(Bucket, VNF, Hist, []);
balance_nodes(Bucket, VNF, Hist, Moves) ->
    {MinNode, MinCount} = misc:keymin(2, Hist),
    {MaxNode, MaxCount} = misc:keymax(2, Hist),
    case MaxCount - MinCount > 1 of
        true ->
            %% Get the first vbucket that is on MaxNode and for which MinNode is not forbidden
            case lists:splitwith(
                   fun ({_, N, F}) ->
                           N /= MaxNode orelse
                               lists:member(MinNode, F)
                   end, VNF) of
                {Prefix, [{V, N, F}|Tail]} ->
                    N = MaxNode,
                    VNF1 = Prefix ++ [{V, MinNode, F}|Tail],
                    Hist1 = lists:keyreplace(MinNode, 1, Hist, {MinNode, MinCount + 1}),
                    Hist2 = lists:keyreplace(MaxNode, 1, Hist1, {MaxNode, MaxCount - 1}),
                    balance_nodes(Bucket, VNF1, Hist2, [{V, MaxNode, MinNode}|Moves]);
                X ->
                    error_logger:info_msg("~p:balance_nodes(~p, ~p, ~p): No further moves (~p)~n",
                                          [?MODULE, VNF, Hist, Moves, X]),
                    Moves
            end;
        false ->
            Moves
    end.

do_rebalance(Bucket, KeepNodes, EjectNodes, Map, Tries) ->
    try
        AllNodes = KeepNodes ++ EjectNodes,
        ns_bucket:set_servers(Bucket, AllNodes),
        AliveNodes = ns_node_disco:nodes_actual_proper(),
        RemapNodes = EjectNodes -- AliveNodes, % No active node, promote a replica
        lists:foreach(fun (N) -> ns_cluster:leave(N) end, RemapNodes),
        update_progress(Bucket, AllNodes, 0.1),
        maybe_stop(),
        EvacuateNodes = EjectNodes -- RemapNodes, % Nodes we can move data off of
        Map1 = promote_replicas(Bucket, Map, RemapNodes),
        ns_bucket:set_map(Bucket, Map1),
        update_progress(Bucket, AllNodes, 0.3),
        maybe_stop(),
        Histograms1 = histograms(Map1, KeepNodes),
        Moves1 = master_moves(Bucket, EvacuateNodes, Map1, Histograms1),
        Map2 = perform_moves(Bucket, Map1, Moves1),
        update_progress(Bucket, AllNodes, 0.6),
        maybe_stop(),
        Histograms2 = histograms(Map2, KeepNodes),
        Moves2 = balance_nodes(Bucket, Map2, Histograms2, 1),
        Map3 = perform_moves(Bucket, Map2, Moves2),
        update_progress(Bucket, AllNodes, 0.7),
        maybe_stop(),
        Histograms3 = histograms(Map3, KeepNodes),
        Map4 = new_replicas(Bucket, EjectNodes, Map3, Histograms3),
        ns_bucket:set_map(Bucket, Map4),
        update_progress(Bucket, AllNodes, 0.8),
        maybe_stop(),
        Histograms4 = histograms(Map4, KeepNodes),
        ChainLength = length(lists:nth(1, Map4)),
        Map5 = lists:foldl(
                 fun (I, M) ->
                         Moves = balance_nodes(Bucket, M, Histograms4, I),
                         apply_moves(I, Moves, M)
                 end, Map4, lists:seq(2, ChainLength)),
        ns_bucket:set_servers(Bucket, KeepNodes),
        ns_bucket:set_map(Bucket, Map5),
        update_progress(Bucket, AllNodes, 0.9),
        %% Push out the config with the new map in case this node is being removed
        ns_config_rep:push(),
        maybe_stop(),
        ns_cluster_membership:deactivate(EjectNodes),
        %% Leave myself last
        LeaveNodes = lists:delete(node(), EvacuateNodes),
        lists:foreach(fun (N) -> ns_cluster:leave(N) end, LeaveNodes),
        case lists:member(node(), EvacuateNodes) of
            true ->
                ns_cluster:leave();
            false ->
                ok
        end
    catch
        throw:stopped ->
            fixup_replicas(Bucket, KeepNodes, EjectNodes),
            exit(stopped);
        exit:Reason ->
            case Tries of
                0 ->
                    exit(Reason);
                _ ->
                    error_logger:warning_msg(
                      "Rebalance received exit: ~p, retrying.~n", [Reason]),
                    timer:sleep(1500),
                    do_rebalance(Bucket, KeepNodes, EjectNodes, Map, Tries - 1)
            end
    end.

%% Ensure there are replicas for any unreplicated buckets if we stop
fixup_replicas(Bucket, KeepNodes, EjectNodes) ->
    {_, _, Map, _} = ns_bucket:config(Bucket),
    Histograms = histograms(Map, KeepNodes),
    Map1 = new_replicas(Bucket, EjectNodes, Map, Histograms),
    ns_bucket:set_servers(Bucket, KeepNodes ++ EjectNodes),
    ns_bucket:set_map(Bucket, Map1).

master_moves(Bucket, EvacuateNodes, Map, Histograms) ->
    master_moves(Bucket, EvacuateNodes, Map, Histograms, 0, []).

master_moves(_, _, [], _, _, Moves) ->
    Moves;
master_moves(Bucket, EvacuateNodes, [[OldMaster|_]|MapTail], Histograms, V,
                 Moves) ->
    [MHist|RHists] = Histograms,
    case (OldMaster == undefined) orelse lists:member(OldMaster, EvacuateNodes) of
        true ->
            {NewMaster, MHist1} = assign(MHist, []),
            master_moves(Bucket, EvacuateNodes, MapTail, [MHist1|RHists],
                             V+1, [{V, OldMaster, NewMaster}|Moves]);
        false ->
            master_moves(Bucket, EvacuateNodes, MapTail, Histograms, V+1,
                             Moves)
    end.

maybe_stop() ->
    receive stop ->
            throw(stopped)
    after 0 ->
            ok
    end.

new_replicas(Bucket, EjectNodes, Map, Histograms) ->
    new_replicas(Bucket, EjectNodes, Map, Histograms, 0, []).

new_replicas(_, _, [], _, _, NewMapReversed) ->
    lists:reverse(NewMapReversed);
new_replicas(Bucket, EjectNodes, [Chain|MapTail], Histograms, V,
              NewMapReversed) ->
    %% Split off the masters - we don't want to move them!
    {[Master|Replicas], [MHist|RHists]} = {Chain, Histograms},
    ChainHist = lists:zip(Replicas, RHists),
    {Replicas1, RHists1} =
        lists:unzip(
          lists:map(fun ({undefined, Histogram}) ->
                            assign(Histogram, [Master|EjectNodes]);
                        (X = {OldNode, Histogram}) ->
                            case lists:member(OldNode, EjectNodes) of
                                true ->
                                    assign(Histogram, Chain ++ EjectNodes);
                                false ->
                                    X
                            end
                        end, ChainHist)),
    new_replicas(Bucket, EjectNodes, MapTail, [MHist|RHists1], V + 1,
                  [[Master|Replicas1]|NewMapReversed]).

perform_moves(Bucket, Map, []) ->
    ns_bucket:set_map(Bucket, Map),
    Map;
perform_moves(Bucket, Map, [{V, Old, New}|Moves]) ->
    try maybe_stop()
    catch
        throw:stopped ->
            ns_bucket:set_map(Bucket, Map),
            throw(stopped)
    end,
    [Old|Replicas] = lists:nth(V+1, Map),
    case {Old, New} of
        {X, X} ->
            perform_moves(Bucket, Map, Moves);
        {_, _} ->
            Map1 = misc:nthreplace(V+1, [New|lists:duplicate(length(Replicas),
                                                           undefined)], Map),
            case Old of
                undefined ->
                    %% This will fail if another node is restarting.
                    %% The janitor will catch it later if it does.
                    catch ns_memcached:set_vbucket_state(New, Bucket, V, active);
                _ ->
                    ns_vbm_sup:move(Bucket, V, Old, New)
            end,
            perform_moves(Bucket, Map1, Moves)
    end.

promote_replicas(Bucket, Map, RemapNodes) ->
    [promote_replica(Bucket, Chain, RemapNodes, V) ||
        {V, Chain} <- misc:enumerate(Map, 0)].

promote_replica(Bucket, Chain, RemapNodes, V) ->
    [OldMaster|_] = Chain,
    Bad = fun (Node) -> lists:member(Node, RemapNodes) end,
    NotBad = fun (Node) -> not lists:member(Node, RemapNodes) end,
    NewChain = lists:takewhile(NotBad, lists:dropwhile(Bad, Chain)), % TODO garbage collect orphaned pending buckets later
    NewChainExtended = NewChain ++ lists:duplicate(length(Chain) - length(NewChain), undefined),
    case NewChainExtended of
        [OldMaster|_] ->
            %% No need to promote
            NewChainExtended;
        [undefined|_] ->
            error_logger:error_msg("~p:promote_replicas(~p, ~p, ~p, ~p): No master~n", [?MODULE, Bucket, V, RemapNodes, Chain]),
            NewChainExtended;
        [NewMaster|_] ->
            error_logger:info_msg("~p:promote_replicas(~p, ~p, ~p, ~p): Setting node ~p active for vbucket ~p~n",
                                  [?MODULE, Bucket, V, RemapNodes, Chain, NewMaster, V]),
            %% The janitor will catch it if this fails.
            catch ns_memcached:set_vbucket_state(NewMaster, V, active),
            NewChainExtended
    end.

histograms(Map, Servers) ->
    Histograms = [lists:keydelete(
                    undefined, 1,
                    misc:uniqc(
                      lists:sort(
                        [N || N<-L,
                              lists:member(N, Servers)]))) ||
                     L <- misc:rotate(Map)],
    lists:map(fun (H) ->
                      Missing = [{N, 0} || N <- Servers,
                                           not lists:keymember(N, 1, H)],
                      Missing ++ H
              end, Histograms).

server(Bucket) ->
    {global, list_to_atom(lists:flatten(io_lib:format("~s-~s", [?MODULE, Bucket])))}.

%% returns true iff the max vbucket count in any class on any server is >2 more than the min
unbalanced(Histograms) ->
    lists:any(fun (Histogram) ->
                      case [N || {_, N} <- Histogram] of
                          [] -> false;
                          Counts -> lists:max(Counts) - lists:min(Counts) > 2
                      end
              end, Histograms).

update_progress(Bucket, Nodes, Fraction) ->
    Progress = [{Node, Fraction} || Node <- Nodes],
    gen_server:cast(server(Bucket), {progress, Progress}).
