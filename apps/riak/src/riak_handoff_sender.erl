-module(riak_handoff_sender).
-export([start_link/3]).
-include("riakserver_pb.hrl").

start_link(TargetNode, Partition, BKeyList) ->
    Self = self(),
    spawn_link(fun() -> start_fold(TargetNode, Partition, BKeyList, Self) end).

start_fold(TargetNode, Partition, BKeyList, ParentPid) ->
    [_Name,Host] = string:tokens(atom_to_list(TargetNode), "@"),
    {ok, Port} = get_handoff_port(TargetNode),
    {ok, Socket} = gen_tcp:connect(Host, Port, 
                                   [binary, {packet, 4}, {header,1}, {active, once}], 15000),
    M = <<0:8,Partition:160/integer>>,
    ok = gen_tcp:send(Socket, M),
    case BKeyList of
        all ->
            gen_server2:call(riak_vnode_master, 
                     {fold, {Partition, fun folder/3, {Socket, ParentPid, []}}},
                     infinity);
        _ ->
            io:format("intermediate handoff:~n~p~n",[BKeyList]),
            inner_fold({Socket,ParentPid,[]},BKeyList)
    end,
    gen_fsm:send_event(ParentPid, handoff_complete).

inner_fold(_FoldArg,[]) -> ok;
inner_fold(FoldArg,[{B,K}|Tail]) ->
    {_Socket,ParentPid,_Count} = FoldArg,
    {ok, V} = gen_fsm:sync_send_event(ParentPid, {get_binary, {B,K}}, infinity),
    inner_fold(folder({B,K},V,FoldArg),Tail).

folder({B,K}, V, {Socket, ParentPid, []}) ->
    gen_tcp:controlling_process(Socket, self()),
    visit_item({B,K}, V, {Socket, ParentPid, 0});
folder({B,K}, V, AccIn) ->
    visit_item({B,K}, V, AccIn).

visit_item({B,K}, V, {Socket, ParentPid, 100}) ->
    M = <<2:8,"sync">>,
    ok = gen_tcp:send(Socket, M),
    inet:setopts(Socket, [{active, false}]),
    {ok,[2|<<"sync">>]} = gen_tcp:recv(Socket, 0),
    inet:setopts(Socket, [{active, once}]),
    visit_item({B,K}, V, {Socket, ParentPid, 0});
visit_item({B,K}, V, {Socket, ParentPid, Acc}) ->
    D = zlib:zip(riakserver_pb:encode_riakobject_pb(
                   #riakobject_pb{bucket=B, key=K, val=V})),
    M = <<1:8,D/binary>>,
    ok = gen_tcp:send(Socket, M),
    {Socket, ParentPid, Acc+1}.
    

get_handoff_port(Node) when is_atom(Node) ->
    gen_server2:call({riak_handoff_listener, Node}, handoff_port).







