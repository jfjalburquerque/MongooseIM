%%==============================================================================
%% Copyright 2014 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

-module(component_SUITE).
-compile(export_all).

-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("exml/include/exml.hrl").
-include_lib("exml/include/exml_stream.hrl").

-import(conf_reload_SUITE, [modify_config_file/2,
                            bacup_ejabberd_config_file/1,
                            restore_ejabberd_config_file/1,
                            reload_through_ctl/1,
                            restart_ejabberd_node/0,
                            set_ejabberd_node_cwd/1]).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [{group, xep0114},
     {group, subdomain}].

groups() ->
    [{xep0114, [], [register_one_component,
                    register_two_components,
                    try_registering_component_twice,
                    try_registering_existing_host,
                    disco_components]},
     {subdomain, [], [register_subdomain]}].

suite() ->
    escalus:suite().

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    escalus:init_per_suite(Config).

end_per_suite(Config) ->
    escalus:end_per_suite(Config).

init_per_group(subdomain, Config) ->
    Config1 = add_domain(Config),
    escalus:create_users(Config1, {by_name, [alice, astrid]});
init_per_group(_GroupName, Config) ->
    escalus:create_users(Config, {by_name, [alice, bob]}).

end_per_group(subdomain, Config) ->
    escalus:delete_users(Config, {by_name, [alice, astrid]}),
    restore_domain(Config);
end_per_group(_GroupName, Config) ->
    escalus:delete_users(Config, {by_name, [alice, bob]}).

init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).


%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------
register_one_component(Config) ->
    %% Given one connected component
    {Component, ComponentAddr, _} = connect_component(component1),

    escalus:story(Config, [1], fun(Alice) ->
                %% When Alice sends a message to the component
                Msg1 = escalus_stanza:chat_to(ComponentAddr, <<"Hi!">>),
                escalus:send(Alice, Msg1),
                %% Then component receives it
                Reply1 = escalus:wait_for_stanza(Component),
                escalus:assert(is_chat_message, [<<"Hi!">>], Reply1),

                %% When component sends a reply
                Msg2 = escalus_stanza:chat_to(Alice, <<"Oh hi!">>),
                escalus:send(Component, escalus_stanza:from(Msg2, ComponentAddr)),

                %% Then Alice receives it
                Reply2 = escalus:wait_for_stanza(Alice),
                escalus:assert(is_chat_message, [<<"Oh hi!">>], Reply2),
                escalus:assert(is_stanza_from, [ComponentAddr], Reply2)
        end),

    ok = escalus_connection:stop(Component).

register_two_components(Config) ->
    %% Given two connected components
    {Comp1, CompAddr1, _} = connect_component(component1),
    {Comp2, CompAddr2, _} = connect_component(component2),

    escalus:story(Config, [1,1], fun(Alice, Bob) ->
                %% When Alice sends a message to the first component
                Msg1 = escalus_stanza:chat_to(Alice, <<"abc">>),
                escalus:send(Comp1, escalus_stanza:from(Msg1, CompAddr1)),
                %% Then component receives it
                Reply1 = escalus:wait_for_stanza(Alice),
                escalus:assert(is_chat_message, [<<"abc">>], Reply1),
                escalus:assert(is_stanza_from, [CompAddr1], Reply1),

                %% When Bob sends a message to the second component
                Msg2 = escalus_stanza:chat_to(Bob, <<"def">>),
                escalus:send(Comp2, escalus_stanza:from(Msg2, CompAddr2)),
                %% Then it also receives it
                Reply2 = escalus:wait_for_stanza(Bob),
                escalus:assert(is_chat_message, [<<"def">>], Reply2),
                escalus:assert(is_stanza_from, [CompAddr2], Reply2),

                %% When the second component sends a reply to Bob
                Msg3 = escalus_stanza:chat_to(CompAddr2, <<"ghi">>),
                escalus:send(Bob, Msg3),
                %% Then he receives it
                Reply3 = escalus:wait_for_stanza(Comp2),
                escalus:assert(is_chat_message, [<<"ghi">>], Reply3),

                %% WHen the first component sends a reply to Alice
                Msg4 = escalus_stanza:chat_to(CompAddr1, <<"jkl">>),
                escalus:send(Alice, Msg4),
                %% Then she receives it
                Reply4 = escalus:wait_for_stanza(Comp1),
                escalus:assert(is_chat_message, [<<"jkl">>], Reply4)
        end),

    ok = escalus_connection:stop(Comp1),
    ok = escalus_connection:stop(Comp2).

try_registering_component_twice(_Config) ->
    %% Given two components with the same name
    {Comp1, Addr, _} = connect_component(component1),

    try
        %% When trying to connect the second one
        {Comp2, Addr, _} = connect_component(component1),
        ok = escalus_connection:stop(Comp2),
        ct:fail("second component connected successfully")
    catch error:{badmatch, _} ->
        %% Then it should fail to do so
        ok
    end,

    ok = escalus_connection:stop(Comp1).

try_registering_existing_host(_Config) ->
    %% Given a external muc component
    Component = muc_component,

    try
        %% When trying to connect it to the server
        {Comp, Addr, _} = connect_component(Component),
        ok = escalus_connection:stop(Comp),
        ct:fail("muc component connected successfully")
    catch error:{badmatch, _} ->
        %% Then it should fail since muc service already exists on the server
        ok
    end.

disco_components(Config) ->
    %% Given two connected components
    {Comp1, Addr1, _} = connect_component(component1),
    {Comp2, Addr2, _} = connect_component(component2),

    escalus:story(Config, [1], fun(Alice) ->
                %% When server asked for the disco features
                Server = escalus_client:server(Alice),
                Disco = escalus_stanza:service_discovery(Server),
                escalus:send(Alice, Disco),

                %% Then it contains hosts of 2 components
                DiscoReply = escalus:wait_for_stanza(Alice),
                escalus:assert(has_service, [Addr1], DiscoReply),
                escalus:assert(has_service, [Addr2], DiscoReply)
        end),

    ok = escalus_connection:stop(Comp1),
    ok = escalus_connection:stop(Comp2).

register_subdomain(Config) ->
    %% Given one connected component
    {Comp, _Addr, Name} = connect_component_subdomain(component1),

    escalus:story(Config, [1,1], fun(Alice, Astrid) ->
                %% When Alice asks for service discovery on the server
                Server1 = escalus_client:server(Alice),
                Disco1 = escalus_stanza:service_discovery(Server1),
                escalus:send(Alice, Disco1),

                %% Then it contains the registered route
                DiscoReply1 = escalus:wait_for_stanza(Alice),
                ComponentHost1 = <<Name/binary, ".", Server1/binary>>,
                escalus:assert(has_service, [ComponentHost1], DiscoReply1),

                %% When Astrid ask for service discovery on her server
                Server2 = escalus_client:server(Astrid),
                false = (Server1 =:= Server2),
                Disco2 = escalus_stanza:service_discovery(Server2),
                escalus:send(Astrid, Disco2),

                %% Then it also contains the registered route
                DiscoReply2 = escalus:wait_for_stanza(Astrid),
                ComponentHost2 = <<Name/binary, ".", Server2/binary>>,
                escalus:assert(has_service, [ComponentHost2], DiscoReply2)

        end),

    ok = escalus_connection:stop(Comp).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
connect_component(Name) ->
    connect_component(Name, component_start_stream).

connect_component_subdomain(Name) ->
    connect_component(Name, component_start_stream_subdomain).

connect_component(Name, StartStep) ->
    {_, ComponentOpts} = escalus_users:get_user_by_name(Name),
    {ok, Component, _, _} = escalus_connection:start(ComponentOpts,
                                                     [{?MODULE, StartStep},
                                                      {?MODULE, component_handshake}]),
    {component, ComponentName} = lists:keyfind(component, 1, ComponentOpts),
    {host, ComponentHost} = lists:keyfind(host, 1, ComponentOpts),
    ComponentAddr = <<ComponentName/binary, ".", ComponentHost/binary>>,
    {Component, ComponentAddr, ComponentName}.

add_domain(Config) ->
    Hosts = {hosts, "[\"localhost\", \"sogndal\"]"},
    Config1 = set_ejabberd_node_cwd(Config),
    bacup_ejabberd_config_file(Config1),
    modify_config_file([Hosts], Config1),
    reload_through_ctl(Config1),
    Config1.

restore_domain(Config) ->
    restore_ejabberd_config_file(Config),
    restart_ejabberd_node(),
    Config.

%%--------------------------------------------------------------------
%% Escalus connection steps
%%--------------------------------------------------------------------
component_start_stream(Conn, Props, []) ->
    {server, Server} = lists:keyfind(server, 1, Props),
    {component, Component} = lists:keyfind(component, 1, Props),

    ComponentHost = <<Component/binary, ".", Server/binary>>,
    StreamStart = component_stream_start(ComponentHost, false),
    ok = escalus_connection:send(Conn, StreamStart),
    StreamStartRep = escalus_connection:get_stanza(Conn, wait_for_stream),

    #xmlstreamstart{attrs = Attrs} = StreamStartRep,
    Id = proplists:get_value(<<"id">>, Attrs),

    {Conn, [{sid, Id}|Props], []}.

component_start_stream_subdomain(Conn, Props, []) ->
    {component, Component} = lists:keyfind(component, 1, Props),

    StreamStart = component_stream_start(Component, true),
    ok = escalus_connection:send(Conn, StreamStart),
    StreamStartRep = escalus_connection:get_stanza(Conn, wait_for_stream),

    #xmlstreamstart{attrs = Attrs} = StreamStartRep,
    Id = proplists:get_value(<<"id">>, Attrs),

    {Conn, [{sid, Id}|Props], []}.

component_handshake(Conn, Props, []) ->
    {password, Password} = lists:keyfind(password, 1, Props),
    {sid, SID} = lists:keyfind(sid, 1, Props),

    Handshake = component_handshake(SID, Password),
    ok = escalus_connection:send(Conn, Handshake),

    HandshakeRep = escalus_connection:get_stanza(Conn, handshake),
    #xmlel{name = <<"handshake">>, children = []} = HandshakeRep,

    {Conn, Props, []}.

%%--------------------------------------------------------------------
%% Stanzas
%%--------------------------------------------------------------------
component_stream_start(Component, IsSubdomain) ->
    Attrs1 = [{<<"to">>, Component},
              {<<"xmlns">>, <<"jabber:component:accept">>},
              {<<"xmlns:stream">>,
               <<"http://etherx.jabber.org/streams">>}],
    Attrs2 = case IsSubdomain of
        false ->
            Attrs1;
        true ->
            [{<<"is_subdomain">>, <<"true">>}|Attrs1]
    end,
    #xmlstreamstart{name = <<"stream:stream">>, attrs = Attrs2}.

component_handshake(SID, Password) ->
    Handshake = crypto:hash(sha, <<SID/binary, Password/binary>>),
    #xmlel{name = <<"handshake">>,
           children = [#xmlcdata{content = base16:encode(Handshake)}]}.