%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2015-2020, 2600Hz
%%% @doc
%%% @author Peter Defebvre
%%% @author James Aimonetti
%%% @author Pierre Fenoll
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(knm_number).

-export([get/1, get/2
        ,create/2
        ,move/2, move/3
        ,update/2, update/3
        ,release/1, release/2
        ,delete/2
        ,assign_to_app/2, assign_to_app/3
        ,lookup_account/1
        ,reserve/2
        ]).

-include("knm.hrl").

-type lookup_error() :: 'not_reconcilable' |
                        'not_found' |
                        'unassigned' |
                        {'not_in_service', kz_term:ne_binary()} |
                        {'account_disabled', kz_term:ne_binary()}.

-type lookup_account_return() :: {'ok', kz_term:ne_binary(), knm_options:extra_options()} |
                                 {'error', lookup_error()}.

-type dry_run_return() :: {'dry_run', knm_pipe:quotes()}.
-type either_obj() :: kz_either:either(knm_errors:error() | atom(), knm_phone_number:record()).
-type either_objs() :: kz_either:either(knm_errors:error() | atom(), knm_phone_number:records()).

-type return() :: either_obj() | dry_run_return().

-export_type([return/0
             ,either_obj/0
             ,either_objs/0
             ]).

%% FIXME: opaque
-define(KNM_NUMBERS_CLAUSES(Num)
       ,{'false', #{'succeeded' := [Number]}} ->
               {'ok', Number};
            {'true', #{'succeeded' := [_Number], 'quotes' := Quotes}} ->
               {'dry_run', Quotes};
            {_, #{'failed' := ErrorM}} ->
               {'error', hd(maps:values(ErrorM))}
                   ).

-define(RUN_KNM_NUMBERS_FUN(F, Num, Options)
       ,case {knm_options:dry_run(Options)
             ,knm_ops:F([Num], Options)
             }
        of ?KNM_NUMBERS_CLAUSES(Num)
            end
       ).

-define(RUN_KNM_NUMBERS_FUN_ARGS(F, Num, Arg2, Options),
        case {knm_options:dry_run(Options)
             ,knm_ops:F([Num], Arg2, Options)
             }
        of ?KNM_NUMBERS_CLAUSES(Num)
            end
       ).

%%------------------------------------------------------------------------------
%% @doc Attempts to get a number from DB.
%%
%% <div class="notice">Number parameter has to be normalized.</div>
%%
%% <div class="notice">{@link get/1}, {@link get/2} should not throw,
%% instead they should return: `{ok,_} | {error,_} | ...'.</div>
%% @end
%%------------------------------------------------------------------------------
-spec get(kz_term:ne_binary()) -> return().
get(Num) ->
    get(Num, knm_options:default()).

-spec get(kz_term:ne_binary(), knm_options:options()) -> return().
get(Num, Options) ->
    case knm_ops:get([Num], Options) of
        %% FIXME: opaque
        #{'succeeded' := [PN]} -> {'ok', PN};
        #{'failed' := M} -> {'error', hd(maps:values(M))}
    end.

%%------------------------------------------------------------------------------
%% @doc Attempts to create a new number in DB or modify an existing one.
%%
%% <div class="notice">`assign_to' number option MUST be set.</div>
%% @end
%%------------------------------------------------------------------------------
-spec create(kz_term:ne_binary(), knm_options:options()) -> return().
create(Num, Options) ->
    ?RUN_KNM_NUMBERS_FUN('create', Num, Options).

%%------------------------------------------------------------------------------
%% @doc Fetches then transitions an existing number to the reserved state.
%% @end
%%------------------------------------------------------------------------------
-spec reserve(kz_term:ne_binary(), knm_options:options()) -> return().
reserve(Num, Options) ->
    ?RUN_KNM_NUMBERS_FUN('reserve', Num, Options).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------

-spec move(kz_term:ne_binary(), kz_term:ne_binary()) -> return().
move(Num, MoveTo) ->
    move(Num, MoveTo, knm_options:default()).

-spec move(kz_term:ne_binary(), kz_term:ne_binary(), knm_options:options()) -> return().
move(?NE_BINARY=Num, ?NE_BINARY=MoveTo, Options) ->
    ?RUN_KNM_NUMBERS_FUN_ARGS('move', Num, MoveTo, Options).

%%------------------------------------------------------------------------------
%% @doc Attempts to update some phone_number fields.
%%
%% <div class="notice">will always result in a phone_number save.</div>
%% @end
%%------------------------------------------------------------------------------

-spec update(kz_term:ne_binary(), knm_phone_number:set_functions()) -> return().
update(Num, Routines) ->
    update(Num, Routines, knm_options:default()).

-spec update(kz_term:ne_binary(), knm_phone_number:set_functions(), knm_options:options()) -> return().
update(Num, Routines, Options) ->
    ?RUN_KNM_NUMBERS_FUN_ARGS('update', Num, Routines, Options).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------

-spec release(kz_term:ne_binary()) -> return().
release(Num) ->
    release(Num, knm_options:default()).

-spec release(kz_term:ne_binary(), knm_options:options()) -> return().
release(Num, Options) ->
    ?RUN_KNM_NUMBERS_FUN('release', Num, Options).

%%------------------------------------------------------------------------------
%% @doc Remove a number from the system without doing any state checking.
%% Sounds too harsh for you? You are looking for release/1,2.
%% @end
%%------------------------------------------------------------------------------
-spec delete(kz_term:ne_binary(), knm_options:options()) -> return().
delete(Num, Options) ->
    ?RUN_KNM_NUMBERS_FUN('delete', Num, Options).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------

-spec assign_to_app(kz_term:ne_binary(), kz_term:api_ne_binary()) -> return().
assign_to_app(Num, App) ->
    assign_to_app(Num, App, knm_options:default()).

-spec assign_to_app(kz_term:ne_binary(), kz_term:api_ne_binary(), knm_options:options()) -> return().
assign_to_app(Num, App, Options) ->
    ?RUN_KNM_NUMBERS_FUN_ARGS('assign_to_app', Num, App, Options).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec lookup_account(kz_term:api_ne_binary()) -> lookup_account_return().
lookup_account('undefined') ->
    {'error', 'not_reconcilable'};
lookup_account(Num) ->
    NormalizedNum = knm_converters:normalize(Num),
    Key = {'account_lookup', NormalizedNum},
    case kz_cache:peek_local(?CACHE_NAME, Key) of
        {'ok', Ok} -> Ok;
        {'error', 'not_found'} ->
            case fetch_account_from_number(NormalizedNum) of
                {'ok', _, _}=Ok ->
                    NumberDb = knm_converters:to_db(NormalizedNum),
                    CacheProps = [{'origin', [{'db', NumberDb, NormalizedNum}]}],
                    kz_cache:store_local(?CACHE_NAME, Key, Ok, CacheProps),
                    Ok;
                Else -> Else
            end
    end.

-spec fetch_account_from_number(kz_term:ne_binary()) -> lookup_account_return().
fetch_account_from_number(Num) ->
    case knm_phone_number:fetch(Num) of
        {'ok', PN} -> check_number(PN);
        {'error', _}=Error -> maybe_fetch_account_from_ports(Num, Error)
    end.

-spec check_number(knm_phone_number:record()) -> lookup_account_return().
check_number(PN) ->
    AssignedTo = knm_phone_number:assigned_to(PN),
    case kz_term:is_empty(AssignedTo) of
        'true' -> {'error', 'unassigned'};
        'false' ->
            States = [?NUMBER_STATE_PORT_IN
                     ,?NUMBER_STATE_IN_SERVICE
                     ,?NUMBER_STATE_PORT_OUT
                     ,?NUMBER_STATE_RESERVED
                     ],
            case lists:member(knm_phone_number:state(PN), States) of
                'true' -> check_account(PN);
                'false' -> {'error', {'not_in_service', AssignedTo}}
            end
    end.

-spec check_account(knm_phone_number:record()) -> lookup_account_return().
check_account(PN) ->
    AssignedTo = knm_phone_number:assigned_to(PN),
    case kzd_accounts:is_enabled(AssignedTo) of
        'false' -> {'error', {'account_disabled', AssignedTo}};
        'true' ->
            Props = [{'pending_port', knm_phone_number:state(PN) =:= ?NUMBER_STATE_PORT_IN}
                    ,{'local', knm_phone_number:module_name(PN) =:= ?CARRIER_LOCAL}
                    ,{'number', knm_phone_number:number(PN)}
                    ,{'account_id', AssignedTo}
                    ,{'prepend', knm_lib:feature_prepend(PN)}
                    ,{'inbound_cnam', knm_lib:feature_inbound_cname(PN)}
                    ,{'ringback_media', knm_lib:find_early_ringback(PN)}
                    ,{'transfer_media', knm_lib:find_transfer_ringback(PN)}
                    ,{'force_outbound', knm_lib:is_force_outbound(PN)}
                    ,{'im', knm_lib:feature_im(PN)}
                    ],
            {'ok', AssignedTo, Props}
    end.

-spec maybe_fetch_account_from_ports(kz_term:ne_binary(), {'error', any()}) -> lookup_account_return().
maybe_fetch_account_from_ports(Num, Error) ->
    case knm_config:should_fetch_account_from_ports() of
        'false' -> Error;
        'true' -> fetch_account_from_ports(Num, Error)
    end.

-spec fetch_account_from_ports(kz_term:ne_binary(), {'error', any()}) -> lookup_account_return().
fetch_account_from_ports(Num, Error) ->
    case knm_port_request:get(Num) of
        {'error', _E} -> Error;
        {'ok', Port} ->
            AccountId = kz_doc:account_id(Port),
            Props = [{'pending_port', 'true'}
                    ,{'local', 'true'}
                    ,{'number', Num}
                    ,{'account_id', AccountId}
                     %% No prepend
                    ,{'inbound_cnam', 'false'}
                     %% No ringback_media
                     %% No transfer_media
                    ,{'force_outbound', 'true'}
                    ],
            {'ok', AccountId, Props}
    end.
