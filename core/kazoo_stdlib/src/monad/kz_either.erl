%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2020, 2600Hz
%%% @doc Functor.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_either).

-export([bind/2
        ,cata/3
        ,from_maybe/1
        ,left/1, from_left/1
        ,right/1, from_right/1
        ,unless/2
        ]).

-include_lib("kazoo_stdlib/include/kz_types.hrl").

-type left() :: left(any()).
-type left(T) :: {'error', T}.

-type right() :: right(any()).
-type right(T) :: {'ok', T}.

-type either() :: either(left(), right()).
-type either(L) :: either(L, right()).
-type either(L, R) :: left(L) | right(R).

-export_type([either/0, either/1, either/2
             ,left/0, left/1
             ,right/0, right/1
             ]).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec left(left(T)) -> T.
left({'error', Val}) -> Val.

-spec from_left(T) -> left(T).
from_left(Val) -> {'error', Val}.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec right(right(T)) -> T.
right({'ok', Val}) -> Val.

-spec from_right(T) -> right(T).
from_right(Val) -> {'ok', Val}.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec from_maybe(any()) -> either().
from_maybe('true') -> from_right('true');
from_maybe('false') -> from_left('false');
from_maybe(Term) ->
    case kz_term:is_empty(Term) of
        'true' -> from_left(Term);
        'false' -> from_right(Term)
    end.

%%------------------------------------------------------------------------------
%% @doc This will perform a monadic bind over the right side of the either,
%% otherwise it will do nothing.
%% @end
%%------------------------------------------------------------------------------
-spec bind(either(L, R), fun((R) -> X)) -> X when X :: either(L, any()).
bind({'ok', Val}, Fn) -> Fn(Val);
bind({'error', _}=Left, _Fn) -> Left.

%%------------------------------------------------------------------------------
%% @doc This bind the left side of the either, otherwise it will do nothing.
%% @end
%%------------------------------------------------------------------------------
-spec unless(either(L, R), fun((L) -> X)) -> X when X :: either(any(), R).
unless({'ok', _}=Right, _) -> Right;
unless({'error', Val}, Fn) -> Fn(Val).

%%------------------------------------------------------------------------------
%% @doc The catamorphism for either. If the either is right the right function
%% will be executed with the right value and the value of the function returned.
%% Otherwise the left function will be called with the left value.
%% @end
%%------------------------------------------------------------------------------
-spec cata(either(L, R), fun((L) -> X), fun((R) -> X)) -> X.
cata({'ok', _}=Right, _LFn, RFn) -> RFn(Right);
cata({'error', Val}, LFn, _RFn) -> LFn(Val).
