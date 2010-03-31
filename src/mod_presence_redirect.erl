%%%----------------------------------------------------------------------
%%% File    : mod_presence_redirect.erl
%%% Author  : Darren Ferguson <darren.ferguson@openband.net>
%%% Purpose : Send presence packets via xmlrpc to a listener
%%% Id      : $Id: mod_presence_redirect.erl
%%%----------------------------------------------------------------------

-module(mod_presence_redirect).
-author('darren.ferguson@openband.net').
-version("0.5").

-behaviour(gen_mod).

% API for the module
-export([start/2,
         stop/1,
         presence_send/4,
         on_presence_update/4,
         offline_presence_update/4]).

% will only use for debugging purposes, will remove the line once finished
-define(ejabberd_debug, true).

% including the ejabberd main header file
-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_mod_presence_redirect).

% variable with _ i.e. _Opts will not bring a compiler unused error if not used
start(Host, Opts) ->
    % getting the list of servers that are associated with the module so we can determine
    % which one we need to send the xmlrpc request back too from this one
    S = gen_mod:get_opt(servers, Opts, "127.0.0.1"),
    F = fun(N) ->
       V = lists:nth(1, N),
       case V of
          Host ->
              true;
          _ ->
              false
       end
    end,
    Servers = lists:filter(F, S),
    % check if we received anything back from server variable
    case lists:member(Host, lists:nth(1, Servers)) of
         true ->
              Server = lists:nth(2, lists:nth(1, Servers));
         _ ->
              Server = "127.0.0.1"
    end,

    % parsing the host config incase it has been utilized instead of the module config portion
    Url = case ejabberd_config:get_local_option({mod_presence_redirect_url , Host}) of
             undefined -> Server;
             U -> U
          end,
    Port = case ejabberd_config:get_local_option({mod_presence_redirect_port , Host}) of
              undefined -> gen_mod:get_opt(port, Opts, 4560);
              P -> P
           end,
    Uri = case ejabberd_config:get_local_option({mod_presence_redirect_uri , Host}) of
              undefined -> gen_mod:get_opt(uri, Opts, "/xmlrpc.php");
              UR -> UR
          end,
    Method = case ejabberd_config:get_local_option({mod_presence_redirect_method , Host}) of
                undefined -> gen_mod:get_opt(method, Opts, "xmpp_relationships.update_presence");
                M -> M
             end,

    % adding hooks for the presence handlers so our function will be called
    ejabberd_hooks:add(set_presence_hook, Host,
                       ?MODULE, on_presence_update, 50),
    ejabberd_hooks:add(unset_presence_hook, Host,
                       ?MODULE, offline_presence_update, 50),
    % spawning a background process so we can use these variables later (erlang no global variables)
    register(gen_mod:get_module_proc(Host, ?PROCNAME),
             spawn(mod_presence_redirect, presence_send, [Url, Port, Uri, Method])),
    ok.

stop(Host) ->
    % removing the hooks for the presence handlers when the server is stopped
    ejabberd_hooks:delete(set_presence_hook, Host,
                          ?MODULE, on_presence_update, 50),
    ejabberd_hooks:delete(unset_presence_hook, Host,
                          ?MODULE, offline_presence_update, 50),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    Proc ! stop,
    ok.

% listener function that will send the packet with pertinent information
% to the adminjid and resource that has been specified in the configuration
presence_send(Server, Port, Uri, Method) ->
    receive
        {User, Srv, Res} ->
                xmlrpc:call(Server, Port, Uri,
                            {call, Method, [jlib:jid_to_string(jlib:make_jid(User, Srv, Res)), "offline", "offline"]}),
                presence_send(Server, Port, Uri, Method);
        {U, S, R, P} ->
                case xml:get_path_s(P, [{elem, "show"}, cdata]) of
	             ""        -> Show = "available";
	             ShowTag   -> Show = ShowTag
                end,

                case xml:get_path_s(P, [{elem, "status"}, cdata]) of
                     ""        -> Status = "";
	             STag      -> Status = STag
                end,
                xmlrpc:call(Server, Port, Uri,
                            {call, Method, [jlib:jid_to_string(jlib:make_jid(U, S, R)), Show, Status]}),
                presence_send(Server, Port, Uri, Method);
        stop ->
                exit(normal)
    end.

% function called when we have a presence update and the user is staying online
on_presence_update(User, Server, Resource, Status) ->
    Proc = gen_mod:get_module_proc(Server, ?PROCNAME),
    Proc ! {User, Server, Resource, Status}.

% function called when we have an offline presence update
offline_presence_update(User, Server, Resource, _Status) ->
    Proc = gen_mod:get_module_proc(Server, ?PROCNAME),
    Proc ! {User, Server, Resource}.
