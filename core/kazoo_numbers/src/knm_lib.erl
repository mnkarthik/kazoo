%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2016-2019, 2600Hz
%%% @doc
%%% @author Peter Defebvre
%%% @author Pierre Fenoll
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(knm_lib).

-export([ensure_can_create/1
        ,ensure_can_load_to_create/1
        ,state_for_create/1
        ,allowed_creation_states/1, allowed_creation_states/2
        ]).

-export([feature_im/1
        ,feature_inbound_cname/1
        ,feature_prepend/1
        ,find_early_ringback/1
        ,find_transfer_ringback/1
        ,force_outbound_feature/1
        ,is_force_outbound/1
        ]).

-ifdef(TEST).
%% TODO: Remove me after fixturedb has save feature
-export([ensure_can_create/2]).
-endif.

-include("knm.hrl").

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec state_for_create(knm_options:options()) -> kz_term:ne_binary().
state_for_create(Options) ->
    case {knm_options:state(Options, ?NUMBER_STATE_IN_SERVICE)
         ,knm_options:ported_in(Options)
         ,knm_options:module_name(Options)
         }
    of
        {?NUMBER_STATE_PORT_IN=PortIn, _, _} -> PortIn;
        {_, 'true', _} -> ?NUMBER_STATE_IN_SERVICE;
        {_, _, ?CARRIER_MDN} -> ?NUMBER_STATE_IN_SERVICE;
        {State, _, _} ->
            AuthBy = knm_options:auth_by(Options),
            kz_either:cata(kz_either:from_maybe(lists:member(State, allowed_creation_states(Options, AuthBy)))
                          ,fun({'error', 'false'}) -> {'error', 'unauthorized'} end
                          ,fun({'ok', 'true'}) ->
                                   lager:debug("allowing picking state ~s for ~s", [State, AuthBy]),
                                   State
                           end
                          )
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec allowed_creation_states(kz_term:api_ne_binary()) -> kz_term:ne_binaries().
allowed_creation_states(AuthBy) ->
    allowed_creation_states([], AuthBy).

-spec allowed_creation_states(knm_options:options(), kz_term:api_ne_binary()) -> kz_term:ne_binaries().
allowed_creation_states(_, 'undefined') -> [];
allowed_creation_states(Options, AuthBy) ->
    case {knm_phone_number:is_admin(AuthBy)
         ,allow_number_additions(Options, AuthBy)
         }
    of
        {'true', _} ->
            [?NUMBER_STATE_AGING
            ,?NUMBER_STATE_AVAILABLE
            ,?NUMBER_STATE_IN_SERVICE
            ,?NUMBER_STATE_PORT_IN
            ,?NUMBER_STATE_RESERVED
            ];
        {'false', 'true'} ->
            [?NUMBER_STATE_IN_SERVICE
            ,?NUMBER_STATE_RESERVED
            ];
        _ -> []
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec ensure_can_load_to_create(knm_pipe:collection()) -> knm_pipe:collection();
                               (knm_phone_number:record()) -> 'true'.
%% FIXME: opaque
ensure_can_load_to_create(T0=#{'todo' := PNs}) ->
    F = fun (PN, T) ->
                case knm_pipe:attempt(fun ensure_can_load_to_create/1, [PN]) of
                    'true' -> knm_pipe:set_succeeded(T, PN);
                    {'error', R} ->
                        Num = knm_phone_number:number(PN),
                        knm_pipe:set_failed(T, Num, R)
                end
        end,
    lists:foldl(F, T0, PNs);
ensure_can_load_to_create(PN) ->
    ensure_state(PN, [?NUMBER_STATE_AGING
                     ,?NUMBER_STATE_AVAILABLE
                     ,?NUMBER_STATE_PORT_IN
                     ]).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec ensure_state(knm_phone_number:record(), kz_term:ne_binaries()) -> 'true'.
ensure_state(PN, AllowedStates) ->
    State = knm_phone_number:state(PN),
    case lists:member(State, AllowedStates) of
        'true' -> 'true';
        'false' ->
            Num = knm_phone_number:number(PN),
            lager:error("~s wrong state ~s, expected one of ~p", [Num, State, AllowedStates]),
            knm_errors:number_exists(Num)
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec ensure_can_create(knm_pipe:collection()) -> knm_pipe:collection().
%% FIXME: opaque
ensure_can_create(T0=#{'todo' := Nums, 'options' := Options}) ->
    F = fun (Num, T) ->
                case knm_pipe:attempt(fun ensure_can_create/2, [Num, Options]) of
                    {'error', R} -> knm_pipe:set_failed(T, Num, R);
                    'true' ->
                        PN = knm_phone_number:from_number_with_options(Num, Options),
                        knm_pipe:set_succeeded(T, PN)
                end
        end,
    lists:foldl(F, T0, Nums).

-spec ensure_can_create(kz_term:ne_binary(), knm_options:options()) -> 'true'.
ensure_can_create(Num, Options) ->
    ensure_account_can_create(Options, knm_options:auth_by(Options))
        andalso ensure_number_is_not_porting(Num, Options).

-ifdef(TEST).
%% TODO: this is required to simulate reseller account without number_allowed_addition
%% Remove this after fixturedb supports save operation
-define(LOAD_ACCOUNT(Options, AccountId)
       ,(case props:get_value(<<"auth_by_account">>, Options) of
             'undefined' -> kzd_accounts:fetch(AccountId);
             AccountJObj ->
                 {'ok', Fetched} = kzd_accounts:fetch(AccountId),
                 {'ok', kz_json:merge(Fetched, AccountJObj)}
         end)
       ).
-else.
-define(LOAD_ACCOUNT(_Options, AccountId)
       ,kzd_accounts:fetch(AccountId)
       ).
-endif.

-spec allow_number_additions(knm_options:options(), kz_term:ne_binary()) -> boolean().
allow_number_additions(_Options, ?KNM_DEFAULT_AUTH_BY) ->
    'true';
allow_number_additions(_Options, _AccountId) ->
    {'ok', JObj} = ?LOAD_ACCOUNT(_Options, _AccountId),
    kzd_accounts:allow_number_additions(JObj).

ensure_account_can_create(_, ?KNM_DEFAULT_AUTH_BY) ->
    lager:info("bypassing auth"),
    'true';
ensure_account_can_create(Options, ?MATCH_ACCOUNT_RAW(AccountId)) ->
    knm_options:ported_in(Options)
        orelse knm_options:state(Options) =:= ?NUMBER_STATE_PORT_IN
        orelse allow_number_additions(Options, AccountId)
        orelse knm_phone_number:is_admin(AccountId)
        orelse knm_errors:unauthorized();
ensure_account_can_create(_, _NotAnAccountId) ->
    lager:debug("'~p' is not an account id", [_NotAnAccountId]),
    knm_errors:unauthorized().

-spec ensure_number_is_not_porting(kz_term:ne_binary(), knm_options:options()) -> 'true'.
-ifdef(TEST).
%% TODO: Remove me after fixturedb has save feature
ensure_number_is_not_porting(?TEST_CREATE_NUM, _Options) -> 'true';
ensure_number_is_not_porting(?TEST_AVAILABLE_NUM = Num, _Options) ->
    knm_errors:number_is_porting(Num).
-else.
ensure_number_is_not_porting(Num, Options) ->
    JustPorted = knm_options:ported_in(Options),
    case JustPorted
        orelse knm_port_request:get(Num)
    of
        'true' -> 'true';
        {'ok', _Doc} -> knm_errors:number_is_porting(Num);
        {'error', 'not_found'} -> 'true';
        {'error', _} -> 'true'
    end.
-endif.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec feature_prepend(knm_phone_number:record()) -> kz_term:api_binary().
feature_prepend(PhoneNumber) ->
    Prepend = knm_phone_number:feature(PhoneNumber, ?FEATURE_PREPEND),
    case kz_json:is_true(?PREPEND_ENABLED, Prepend) of
        'false' -> 'undefined';
        'true' -> kz_json:get_ne_value(?PREPEND_NAME, Prepend)
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec feature_im(knm_phone_number:record()) -> kz_term:api_binary().
feature_im(PhoneNumber) ->
    IM = knm_phone_number:feature(PhoneNumber, ?FEATURE_IM),
    case knm_im:enabled(PhoneNumber) of
        'false' -> 'undefined';
        'true' -> IM
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec feature_inbound_cname(knm_phone_number:record()) -> boolean().
feature_inbound_cname(PhoneNumber) ->
    case knm_phone_number:feature(PhoneNumber, ?FEATURE_CNAM_INBOUND) of
        'undefined' -> 'false';
        _ ->
            Mod = knm_phone_number:module_name(PhoneNumber),
            Module = kz_term:to_atom(Mod, 'true'),
            try Module:should_lookup_cnam() of
                Boolean -> kz_term:is_true(Boolean)
            catch
                _E:_R -> 'true'
            end
    end.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec find_early_ringback(knm_phone_number:record()) -> kz_term:api_binary().
find_early_ringback(PhoneNumber) ->
    RingBack = knm_phone_number:feature(PhoneNumber, ?FEATURE_RINGBACK),
    kz_json:get_ne_value(?RINGBACK_EARLY, RingBack).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec find_transfer_ringback(knm_phone_number:record()) -> kz_term:api_binary().
find_transfer_ringback(PhoneNumber) ->
    RingBack = knm_phone_number:feature(PhoneNumber, ?FEATURE_RINGBACK),
    kz_json:get_ne_value(?RINGBACK_TRANSFER, RingBack).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec is_force_outbound(knm_phone_number:record()) -> boolean().
is_force_outbound(PN) ->
    is_force_outbound(knm_phone_number:state(PN)
                     ,knm_phone_number:module_name(PN)
                     ,force_outbound_feature(PN)
                     ).

-spec is_force_outbound(kz_term:ne_binary(), kz_term:ne_binary(), boolean()) -> boolean().
is_force_outbound(?NUMBER_STATE_PORT_IN, Module, _ForceOutbound) ->
    knm_config:should_force_port_in_outbound()
        orelse force_module_outbound(Module);
is_force_outbound(?NUMBER_STATE_PORT_OUT, Module, _ForceOutbound) ->
    knm_config:should_force_port_out_outbound()
        orelse force_module_outbound(Module);
is_force_outbound(_State, ?CARRIER_LOCAL, _ForceOutbound) ->
    force_local_outbound();
is_force_outbound(_State, ?CARRIER_MDN, _ForceOutbound) ->
    force_local_outbound();
is_force_outbound(_State, _Module, ForceOutbound) ->
    ForceOutbound.

%% FIXME: move to kpn
-spec force_outbound_feature(knm_phone_number:record()) -> boolean().
force_outbound_feature(PN) ->
    case knm_phone_number:feature(PN, ?FEATURE_FORCE_OUTBOUND) of
        'undefined' -> knm_config:should_force_outbound();
        FO -> kz_term:is_true(FO)
    end.

-spec force_module_outbound(kz_term:ne_binary()) -> boolean().
force_module_outbound(?CARRIER_LOCAL) -> force_local_outbound();
force_module_outbound(?CARRIER_MDN) -> force_local_outbound();
force_module_outbound(_Mod) -> 'false'.

-spec force_local_outbound() -> boolean().
force_local_outbound() ->
    knm_config:should_force_local_outbound().
