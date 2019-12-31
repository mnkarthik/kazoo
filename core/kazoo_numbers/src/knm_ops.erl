%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2015-2020, 2600Hz
%%% @doc Bulk operations on numbers.
%%%
%%% <div class="notice">Functions should not throw, instead should return
%%% {@link knm_pipe:collection()}.</div>
%%%
%%% @author Peter Defebvre
%%% @author Pierre Fenoll
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(knm_ops).

-export([get/1, get/2
        ,create/2
        ,move/2, move/3
        ,update/2, update/3
        ,release/1, release/2
        ,delete/2
        ,reserve/2

        ,assign_to_app/2, assign_to_app/3
        ]).

-export([from_jobjs/1]).

-include("knm.hrl").

%%------------------------------------------------------------------------------
%% @doc Attempts to get numbers from DB.
%%
%% <div class="notice">Each number in `Nums' has to be normalized.</div>
%% @end
%%------------------------------------------------------------------------------
-spec get(kz_term:ne_binaries()) -> knm_pipe:collection().
get(Nums) -> get(Nums, knm_options:default()).

-spec get(kz_term:ne_binaries(), knm_options:options()) -> knm_pipe:collection().
get(Nums, Options) -> do_get(Nums, Options).

-spec do_get(kz_term:ne_binaries(), knm_options:options()) -> knm_pipe:collection().
do_get(Nums, Options) ->
    {Yes, No} = knm_converters:are_reconcilable(Nums),
    knm_pipe:do(fun knm_phone_number:fetch/1, knm_pipe:new(Options, Yes, No)).

-spec do_get(kz_term:ne_binaries(), knm_options:options(), knm_pipe:reason()) -> knm_pipe:collection().
do_get(Nums, Options, Error) ->
    {Yes, No} = knm_converters:are_reconcilable(Nums),
    knm_pipe:do(fun knm_phone_number:fetch/1, knm_pipe:new(Options, Yes, No, Error)).

-spec from_jobjs(kz_json:objects()) -> knm_pipe:collection().
from_jobjs(JObjs) ->
    Options = knm_options:default(),
    PNs = [knm_phone_number:from_json_with_options(Doc, Options)
           || JObj <- JObjs,
              Doc <- [kz_json:get_value(<<"doc">>, JObj)],
              kz_doc:type(Doc) =:= <<"number">>
          ],
    knm_pipe:new(Options, PNs, []).

-define(OPTIONS_FOR_LOAD(_Nums, Options),
        case knm_options:ported_in(Options) of
            'false' -> Options;
            'true' -> [{'module_name', ?PORT_IN_MODULE_NAME}|Options]
        end).

%%------------------------------------------------------------------------------
%% @doc Attempts to create new numbers in DB or modify existing ones.
%%
%% <div class="notice">`assign_to' number option MUST be set.</div>
%%
%% <div class="notice">Creating numbers with `ported_in' option set to true will
%% attempt to create them with state `in_service'.</div>
%% @end
%%------------------------------------------------------------------------------
-spec create(kz_term:ne_binaries(), knm_options:options()) -> knm_pipe:collection().
create(Nums, Opts0) ->
    kz_either:catar(knm_lib:ensure_can_create(Opts0), fun(Options) -> do_create(Nums, Options) end).

-spec do_create(kz_term:ne_binaries(), knm_options:options()) -> knm_pipe:collection().
do_create(Nums, Options) ->
    ColGet = do_get(Nums, ?OPTIONS_FOR_LOAD(Nums, props:delete('state', Options))),
    Col0 = knm_pipe:pipe(knm_pipe:set_options(ColGet, Options)
                        ,[fun knm_lib:ensure_can_load_to_create/1
                         ,fun update_for_create/1
                         ]),
    {Col1, NotFounds} = take_not_founds(Col0),
    Col2 = lists:foldl(fun create_new_numbers/2, Col1, NotFounds),
    knm_pipe:pipe(Col2
                 ,[fun knm_states:to_options_state/1
                  ,fun save_numbers/1
                  ]).

-spec create_new_numbers(kz_term:ne_binary(), knm_pipe:collection()) -> knm_pipe:collection().
create_new_numbers(Num, T) ->
    Options = knm_pipe:options(T),
    %% FIXME: move setting success and failed to the function itself
    %% and update the tests
    try knm_lib:ensure_number_is_not_porting(Num, Options) of
        'true' ->
            PN = knm_phone_number:from_number_with_options(Num, Options),
            knm_pipe:add_success(T, PN)
    catch
        'throw':{'error', Reason, Num} ->
            Reason = knm_errors:to_json(Reason, Num),
            knm_pipe:set_failed(T, Num, Reason)
    end.

-spec update_for_create(knm_pipe:collection()) -> knm_pipe:collection().
update_for_create(Collection) ->
    Options = knm_pipe:options(Collection),
    Updates = knm_options:to_phone_number_setters(
                props:delete('state', Options)
               ),
    knm_phone_number:setters(Collection, Updates).

-spec take_not_founds(knm_pipe:collection()) -> {knm_pipe:collection(), kz_term:ne_binaries()}.
take_not_founds(Collection) ->
    Failed = knm_pipe:failed(Collection),
    F = fun ({_Num, Reason}) -> 'not_found' =:= Reason end,
    {NumsNotFound, NewFailed} = lists:partition(F, maps:to_list(Failed)),
    Nums = [Num || {Num, 'not_found'} <- NumsNotFound],
    {knm_pipe:set_failed(Collection, maps:from_list(NewFailed)), Nums}.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec move(kz_term:ne_binaries(), kz_term:ne_binary()) -> knm_pipe:collection().
move(Nums, MoveTo) ->
    move(Nums, MoveTo, knm_options:default()).

-spec move(kz_term:ne_binaries(), kz_term:ne_binary(), knm_options:options()) -> knm_pipe:collection().
move(Nums, ?MATCH_ACCOUNT_RAW(MoveTo), Options0) ->
    Options = props:set_value('assign_to', MoveTo, Options0),
    {TFound, NotFounds} = take_not_founds(do_get(Nums, Options)),
    Updates = knm_options:to_phone_number_setters(Options0),
    TUpdated = knm_pipe:do(fun (T) -> knm_phone_number:setters(T, Updates) end, TFound),
    TDiscovered = knm_pipe:do(fun discover/1, knm_pipe:new(Options, NotFounds)),
    T = knm_pipe:merge_okkos(TUpdated, TDiscovered),
    knm_pipe:do(fun move_to/1, T).

%%------------------------------------------------------------------------------
%% @doc Attempts to update some phone_number fields.
%%
%% <div class="notice">Will always result in a phone_number save.</div>
%% @end
%%------------------------------------------------------------------------------
-spec update(kz_term:ne_binaries(), knm_phone_number:set_functions()) -> knm_pipe:collection().
update(Nums, Routines) ->
    update(Nums, Routines, knm_options:default()).

-ifdef(TEST).

-spec update(kz_term:ne_binaries() | knm_phone_number:records(), knm_phone_number:set_functions(), knm_options:options()) ->
          knm_pipe:collection().
%% FIXME: first argument could be ne_binaries or knm_phone_numbers
update([?NE_BINARY|_]=Nums, Routines, Options) ->
    Reason = 'not_reconcilable',  %% FIXME: unify to atom OR knm_error.
    do_update(do_get(Nums, Options, Reason), Routines);
update(Ns, Updates, Options) ->
    Routines = [{fun knm_phone_number:set_dirty/2, 'false'}
                | knm_options:to_phone_number_setters(Options)
                ++ Updates
               ],
    T0 = knm_pipe:new(Options, Ns),
    T1 = knm_pipe:do(fun (T) -> knm_phone_number:setters(T, Routines) end, T0),
    knm_pipe:do(fun save_numbers/1, T1).

-else.

-spec update(kz_term:ne_binaries(), knm_phone_number:set_functions(), knm_options:options()) -> knm_pipe:collection().
update(Nums, Routines, Options) ->
    Reason = 'not_reconcilable',  %% FIXME: unify to atom OR knm_error.
    do_update(do_get(Nums, Options, Reason), Routines).

-endif.

do_update(T0, Routines) ->
    knm_pipe:pipe(T0
                 ,[fun (T) -> knm_phone_number:setters(T, Routines) end
                  ,fun save_numbers/1
                  ]
                 ).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec release(kz_term:ne_binaries()) -> knm_pipe:collection().
release(Nums) ->
    release(Nums, knm_options:default()).

-spec release(kz_term:ne_binaries(), knm_options:options()) -> knm_pipe:collection().
release(Nums, Options) ->
    knm_pipe:pipe(do_get(Nums, Options)
                 ,[fun try_release/1
                  ,fun knm_providers:delete/1
                  ,fun unwind_maybe_disconnect/1
                  ,fun save_phone_numbers/1
                  ]).

%%------------------------------------------------------------------------------
%% @doc Remove numbers from the system without doing any state checking.
%% Sounds too harsh for you? You are looking for release/1,2.
%% @end
%%------------------------------------------------------------------------------
-spec delete(kz_term:ne_binaries(), knm_options:options()) -> knm_pipe:collection().
delete(Nums, Options) ->
    case knm_phone_number:is_admin(knm_options:auth_by(Options)) of
        'false' ->
            knm_pipe:new(Options, [], Nums, knm_errors:to_json('unauthorized'));
        'true' ->
            T0 = do_get(Nums, Options),
            F1 = fun knm_providers:delete/1,
            F2 = fun knm_phone_number:delete/1,
            knm_pipe:do(F2, knm_pipe:do(F1, T0))
    end.

%%------------------------------------------------------------------------------
%% @doc Fetches then transitions existing numbers to the reserved state.
%% @end
%%------------------------------------------------------------------------------
-spec reserve(kz_term:ne_binaries(), knm_options:options()) -> knm_pipe:collection().
reserve(Nums, Options) ->
    knm_pipe:pipe(do_get(Nums, Options)
                 ,[fun fail_if_assign_to_is_not_an_account_id/1
                  ,fun to_reserved/1
                  ]).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec assign_to_app(kz_term:ne_binaries(), kz_term:api_ne_binary()) -> knm_pipe:collection().
assign_to_app(Nums, App) ->
    assign_to_app(Nums, App, knm_options:default()).

-spec assign_to_app(kz_term:ne_binaries(), kz_term:api_ne_binary(), knm_options:options()) -> knm_pipe:collection().
assign_to_app(Nums, App, Options) ->
    Setters = [{fun knm_phone_number:set_used_by/2, App}],
    knm_pipe:pipe(do_get(Nums, Options)
                 ,[fun (T) -> knm_phone_number:setters(T, Setters) end
                  ,fun knm_phone_number:save/1
                  ]).

-spec save_phone_numbers(knm_pipe:collection()) -> knm_pipe:collection().
save_phone_numbers(T) ->
    knm_pipe:do(fun knm_phone_number:save/1, T).

-spec save_numbers(knm_pipe:collection()) -> knm_pipe:collection().
save_numbers(T) ->
    knm_pipe:pipe(T, [fun knm_providers:save/1
                     ,fun save_phone_numbers/1
                     ,fun update_services/1
                     ]).

-spec update_services(knm_pipe:collection()) -> knm_pipe:collection().
-ifdef(TEST).
%% FIXME: opaque
update_services(T=#{'todo' := Ns}) -> knm_pipe:set_succeeded(T, Ns).
-else.
%% FIXME: opaque
update_services(T=#{'todo' := Numbers, 'options' := Options}) ->
    case {knm_options:batch_run(Options)
         ,knm_options:dry_run(Options)
         }
    of
        {'true', _} ->
            lager:debug("batch_run-ing btw"),
            knm_pipe:set_succeeded(T, Numbers);
        {_, 'true'} -> maybe_dry_run_services(T);
        {_, _} -> run_services(T)
    end.

-spec run_services(knm_pipe:collection()) -> knm_pipe:collection().
%% FIXME: opaque
run_services(T=#{'todo' := Numbers}) ->
    Updates = services_group_numbers(Numbers),
    AccountIds = kz_json:get_keys(Updates),
    try run_services(AccountIds, Updates, []) of
        'ok' ->
            knm_pipe:set_succeeded(T, Numbers)
    catch
        'throw':{'error', 'not_enough_credit', AccountId, Units} ->
            Reason = knm_errors:to_json('not_enough_credit', AccountId, Units),
            knm_pipe:set_failed(T, Numbers, Reason)
    end.

-spec run_services(kz_term:ne_binaries(), kz_json:object(), [kz_services:services()]) -> 'ok'.
run_services([], _Updates, UpdatedServicesAcc) ->
    _ = [kz_services:commit(UpdatedServices) || UpdatedServices <- lists:reverse(UpdatedServicesAcc)],
    'ok';
run_services([AccountId|AccountIds], Updates, UpdatedServicesAcc) ->
    CurrentJObjs = kz_json:get_value([AccountId, <<"current">>], Updates),
    ProposedJObjs = kz_json:get_value([AccountId, <<"proposed">>], Updates),
    Services = kz_services:fetch(AccountId),
    UpdatedServices = kz_services:set_updates(Services
                                             ,AccountId
                                             ,CurrentJObjs
                                             ,ProposedJObjs
                                             ),
    Quotes = kz_services_invoices:create(UpdatedServices),
    HasAdditions = kz_services_invoices:has_billable_additions(Quotes),
    check_creditably(Services, Quotes, HasAdditions),
    run_services(AccountIds, Updates, [UpdatedServices | UpdatedServicesAcc]).

-spec check_creditably(kz_services:services(), kz_services_invoices:invoices(), boolean() | number()) -> 'ok'.
check_creditably(_Services, _Quotes, 'false') ->
    'ok';
check_creditably(Services, Quotes, 'true') ->
    Key = [<<"difference">>, <<"billable">>],
    Additions = [begin
                     Changes = kz_services_item:changes(Item),
                     BillableQuantity = kz_json:get_integer_value(Key, Changes, 0),
                     Rate = kz_services_item:rate(Item),
                     BillableQuantity * Rate
                 end
                 || Invoice <- kz_services_invoices:billable_additions(Quotes),
                    Item <- kz_services_invoice:items(Invoice),
                    kz_services_item:has_billable_additions(Item)
                ],
    check_creditably(Services, Quotes, lists:sum(Additions));
check_creditably(_Services, _Quotes, Amount) when Amount =< 0 ->
    'ok';
check_creditably(Services, Quotes, Amount) ->
    Options = #{'amount' => kz_currency:dollars_to_units(Amount)
               ,'quotes' => Quotes
               },
    case kz_services_standing:acceptable(Services, Options) of
        {'true', _} -> 'ok';
        {'false', Reason} ->
            knm_errors:billing_issue(kz_services:account_id(Services)
                                    ,kz_json:from_map(Reason)
                                    )
    end.

-spec maybe_dry_run_services(knm_pipe:collection()) -> knm_pipe:collection().
%% FIXME: opaque
maybe_dry_run_services(T=#{'todo' := Numbers, 'options' := Options}) ->
    case knm_options:crossbar(Options) of
        'undefined' -> knm_pipe:set_succeeded(T, Numbers);
        CrossbarOptions -> dry_run_services(T, CrossbarOptions)
    end.

-spec dry_run_services(knm_pipe:collection(), kz_term:proplist()) -> knm_pipe:collection().
%% FIXME: opaque
dry_run_services(T=#{'todo' := Numbers}, CrossbarOptions) ->
    Services = props:get_value('services', CrossbarOptions),
    AccountId = props:get_value('account_id', CrossbarOptions),
    Updates = services_group_numbers(Numbers),
    CurrentJObjs = kz_json:get_value([AccountId, <<"current">>], Updates),
    ProposedJObjs = kz_json:get_value([AccountId, <<"proposed">>], Updates),
    UpdatedServices = kz_services:set_updates(Services
                                             ,AccountId
                                             ,CurrentJObjs
                                             ,ProposedJObjs
                                             ),
    Quotes = kz_services_invoices:create(UpdatedServices),
    case kz_services_invoices:has_changes(Quotes) of
        'false' -> knm_pipe:set_succeeded(T, Numbers);
        'true' ->
            JObj = kz_services_invoices:public_json(Quotes),
            knm_pipe:set_succeeded(knm_pipe:set_quotes(T, JObj), Numbers)
    end.

-spec services_group_numbers(knm_phone_number:records()) -> kz_json:object().
services_group_numbers(PNs) ->
    %% TODO: sort these so the account with the largest pvt_tree is first...
    services_group_numbers(PNs, dict:new()).

-spec services_group_numbers(knm_phone_number:records(), dict:dict()) -> kz_json:object().
services_group_numbers([], Updates) ->
    kz_json:set_values(dict:to_list(Updates), kz_json:new());
services_group_numbers([PhoneNumber|PNs], Updates) ->
    AssignedTo = kz_term:to_api_term(
                   knm_phone_number:assigned_to(PhoneNumber)
                  ),
    PrevAssignedTo = kz_term:to_api_term(
                       knm_phone_number:prev_assigned_to(PhoneNumber)
                      ),
    Props = services_group_number(PhoneNumber, AssignedTo, PrevAssignedTo),
    UpdatedGroups = lists:foldl(fun({Key, Value}, U) ->
                                        dict:append(Key, Value, U)
                                end
                               ,Updates
                               ,Props
                               ),
    services_group_numbers(PNs, UpdatedGroups).

-spec services_group_number(knm_phone_number:record(), kz_term:api_binary(), kz_term:api_binary()) -> kz_term:proplist().
services_group_number(_PhoneNumber, 'undefined', 'undefined') -> [];
services_group_number(PhoneNumber, 'undefined', PrevAssignedTo) ->
    ProposedJObj = kz_json:new(),
    CurrentJObj = knm_phone_number:current_doc(PhoneNumber),
    [{[PrevAssignedTo, <<"proposed">>], ProposedJObj}
    ,{[PrevAssignedTo, <<"current">>], CurrentJObj}
    ];
services_group_number(PhoneNumber, AssignedTo, 'undefined') ->
    ProposedJObj = knm_phone_number:to_json(PhoneNumber),
    CurrentJObj = kz_json:new(),
    [{[AssignedTo, <<"proposed">>], ProposedJObj}
    ,{[AssignedTo, <<"current">>], CurrentJObj}
    ];
services_group_number(PhoneNumber, AssignedTo, AssignedTo) ->
    ProposedJObj = knm_phone_number:to_json(PhoneNumber),
    CurrentJObj = knm_phone_number:current_doc(PhoneNumber),
    [{[AssignedTo, <<"proposed">>], ProposedJObj}
    ,{[AssignedTo, <<"current">>], CurrentJObj}
    ];
services_group_number(PhoneNumber, AssignedTo, PrevAssignedTo) ->
    ProposedJObj = knm_phone_number:to_json(PhoneNumber),
    CurrentJObj = knm_phone_number:current_doc(PhoneNumber),
    [{[AssignedTo, <<"proposed">>], ProposedJObj}
    ,{[AssignedTo, <<"current">>], kz_json:new()}
    ,{[PrevAssignedTo, <<"proposed">>], kz_json:new()}
    ,{[PrevAssignedTo, <<"current">>], CurrentJObj}
    ].
-endif.

%% FIXME: opaque
-spec discover(knm_pipe:collection()) -> knm_pipe:collection().
discover(T0=#{'todo' := Nums, 'options' := Options}) ->
    F = fun (Num, T) ->
                case knm_search:discovery(Num, Options) of
                    {'ok', N} -> knm_pipe:set_succeeded(T, N);
                    {'error', R} -> knm_pipe:set_failed(T, Num, R)
                end
        end,
    lists:foldl(F, T0, Nums).

-spec move_to(knm_pipe:collection()) -> knm_pipe:collection().
move_to(T) ->
    NewOptions = [{'state', ?NUMBER_STATE_IN_SERVICE} | knm_pipe:options(T)],
    knm_pipe:pipe(knm_pipe:set_options(T, NewOptions)
                 ,[fun knm_states:to_options_state/1
                  ,fun save_numbers/1
                  ]).
-spec to_reserved(knm_pipe:collection()) -> knm_pipe:collection().
to_reserved(T) ->
    NewOptions = [{'state', ?NUMBER_STATE_RESERVED} | knm_pipe:options(T)],
    knm_pipe:pipe(knm_pipe:set_options(T, NewOptions)
                 ,[fun knm_states:to_options_state/1
                  ,fun save_numbers/1
                  ]).

-spec fail_if_assign_to_is_not_an_account_id(knm_pipe:collection() | knm_pipe:collection()) -> knm_pipe:collection() | knm_pipe:collection().
%% FIXME: opaque
fail_if_assign_to_is_not_an_account_id(T=#{'todo' := NsOrPNs, 'options' := Options}) ->
    case knm_options:assign_to(Options) of
        ?MATCH_ACCOUNT_RAW(_) -> knm_pipe:set_succeeded(T, NsOrPNs);
        _ ->
            Reason = knm_errors:to_json('assign_failure', 'undefined', 'field_undefined'),
            NsOrNums = case knm_phone_number:is_phone_number(hd(NsOrPNs)) of
                           'false' -> NsOrPNs;
                           'true' -> [knm_phone_number:number(PN) || PN <- NsOrPNs]
                       end,
            knm_pipe:set_failed(T, NsOrNums, Reason)
    end.

-spec try_release(knm_pipe:collection()) -> knm_pipe:collection().
try_release(T) ->
    knm_pipe:pipe(T
                 ,[fun can_release/1
                  ,fun knm_phone_number:is_authorized/1
                  ,fun reset_features/1
                  ]).

-spec can_release(knm_pipe:collection()) -> knm_pipe:collection().
can_release(T0=#{'todo' := PNs}) ->
    ToState = knm_config:released_state(),
    F = fun (PN, T) ->
                FromState = knm_phone_number:state(PN),
                case can_release(FromState, knm_phone_number:module_name(PN)) of
                    'true' -> knm_pipe:set_succeeded(T, PN);
                    'false' ->
                        {'error', A, B, C} = (catch knm_errors:invalid_state_transition('undefined', FromState, ToState)),
                        Reason = knm_errors:to_json(A, B, C),
                        knm_pipe:set_failed(T, knm_phone_number:number(PN), Reason)
                end
        end,
    lists:foldl(F, T0, PNs).

-spec can_release(kz_term:ne_binary(), kz_term:ne_binary()) -> boolean().
can_release(?NUMBER_STATE_RELEASED, _) -> 'true';
can_release(?NUMBER_STATE_RESERVED, _) -> 'true';
can_release(?NUMBER_STATE_PORT_IN, _) -> 'true';
can_release(?NUMBER_STATE_IN_SERVICE, _) -> 'true';
can_release(_, ?CARRIER_LOCAL) -> 'true';
can_release(_, _) -> 'false'.

-spec reset_features(knm_pipe:collection()) -> knm_pipe:collection().
reset_features(T) ->
    Routines = [fun knm_phone_number:reset_features/1
               ,fun knm_phone_number:reset_doc/1
               ],
    knm_phone_number:setters(T, Routines).

-spec unwind_maybe_disconnect(knm_pipe:collection()) -> knm_pipe:collection().
unwind_maybe_disconnect(T) ->
    T0 = knm_pipe:do(fun knm_phone_number:unwind_reserve_history/1, T),
    {ToDisconnect, DontDisconnect} = lists:partition(fun should_disconnect/1, knm_pipe:succeeded(T0)),
    Ta = knm_pipe:set_succeeded(T0, DontDisconnect),
    Tb = knm_pipe:pipe(knm_pipe:set_succeeded(T0, ToDisconnect)
                      ,[fun knm_carriers:disconnect/1
                       ,fun delete_maybe_age/1
                       ]),
    knm_pipe:merge_okkos(Ta, Tb).

-spec should_disconnect(knm_phone_number:record()) -> boolean().
should_disconnect(PN) ->
    'undefined' =:= knm_phone_number:assigned_to(PN).

-spec delete_maybe_age(knm_pipe:collection()) -> knm_pipe:collection().
delete_maybe_age(T) ->
    case knm_config:should_permanently_delete() of
        'true' -> delete_permanently(T);
        'false' ->
            {DeleteNs, OtherNs} = split_on(fun is_carrier_local_or_mdn/1, T),
            knm_pipe:merge_okkos(delete_permanently(DeleteNs), maybe_age(OtherNs))
    end.

-spec delete_permanently(knm_pipe:collection()) -> knm_pipe:collection().
delete_permanently(T) ->
    knm_pipe:do(fun knm_phone_number:delete/1, T).

%% FIXME: opaque
-spec split_on(fun((knm_phone_number:record()) -> boolean()), knm_pipe:collection()) ->
          {knm_pipe:collection(), knm_pipe:collection()}.
split_on(Pred, T=#{'todo' := PNs}) ->
    {Yes, No} = lists:partition(Pred, PNs),
    {knm_pipe:set_todo(T, Yes), knm_pipe:set_todo(T, No)}.

-spec is_carrier_local_or_mdn(knm_phone_number:record()) -> boolean().
is_carrier_local_or_mdn(PN) ->
    Carrier = knm_phone_number:module_name(PN),
    ?CARRIER_LOCAL =:= Carrier
        orelse ?CARRIER_MDN =:= Carrier.

-spec maybe_age(knm_pipe:collection()) -> knm_pipe:collection().
%% FIXME: opaque
maybe_age(T=#{'todo' := PNs}) ->
    case knm_config:should_age() of
        'false' -> knm_pipe:set_succeeded(T, PNs);
        'true' ->
            lager:debug("aging for some time"),
            {Yes, No} = lists:partition(fun is_state_available/1, PNs),
            Ta = knm_pipe:do(fun knm_pipe:id/1, knm_pipe:set_todo(T, No)),
            NewOptions = [{'state', ?NUMBER_STATE_AGING} | knm_pipe:options(T)],
            Tb = knm_pipe:do(fun knm_states:to_options_state/1
                            ,knm_pipe:set_options(knm_pipe:set_todo(T,Yes), NewOptions)
                            ),
            knm_pipe:merge_okkos(Ta, Tb)
    end.

-spec is_state_available(knm_phone_number:record()) -> boolean().
is_state_available(PN) ->
    ?NUMBER_STATE_AVAILABLE =:= knm_phone_number:state(PN).
