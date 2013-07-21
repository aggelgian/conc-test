%% -*- erlang-indent-level: 2 -*-
%%------------------------------------------------------------------------------
-module(concolic_spec_parse).

%% 
%% Core Erlang AST #c_module{}.attrs
%% =================================
%% 
%% #c_module{}.attrs :: (Attr)*
%% 
%% Attr :: TypeAttrDef | SpecAttrDef
%% 
%% TypeAttrDef :: {{c_literal, _, type}, {c_literal, _, [TypeAttr]}}
%% │
%% └─ TypeAttr :: RecordDef | TypeDef
%%    │
%%    ├─ RecordDef :: {{record, RecordName :: atom()}, (RecordField)+, []}
%%    │  └─ RecordField :: UntypedRecordField | TypedRecordField
%%    │     ├─ UntypedRecordField :: {record_field, _Ln, FieldName} 
%%    │     │                      | {record_field, _Ln, FieldName, DefaultValue :: term()}
%%    │     └─ TypedRecordField :: {typed_record_field, UntypedRecordField, Type}
%%    │
%%    └─ TypeDef :: {TypeName :: atom(), Type, (FreeVar)*}
%%       └─ FreeVar :: {var, _Ln, VarName :: atom()}
%% 
%% SpecAttrDef :: {{c_literal, _, spec}, {c_literal, _, [SpecAttr]}}
%% │
%% └─ SpecAttr :: {{F :: atom(), A :: byte()}, [Spec]}
%%    ├─ Spec :: Fun | BoundedFun
%%    │
%%    ├─ Fun :: {type, _Ln, 'fun', [Product, Type]}
%%    │  └─ Product :: {type, _Ln, product, (Type)*}
%%    │
%%    └─ BoundedFun :: {type, _Ln, bounded_fun, [Fun, (Constraint)*]}
%%       └─ Constraint :: {type, _Ln, constraint, SubTypeCnst}
%%          └─ SubTypeCnst :: [{atom, _Ln, is_subtype}, [VarName :: atom(), Type]]
%% 
%% Type :: Fun
%%       | Literal
%%       | {type, _Ln, any, []}
%%       | {type, _Ln, term, []}
%%       | {type, _Ln, atom, []}
%%       | {type, _Ln, binary, []}
%%       | {type, _Ln, bitstring, []}
%%       | {type, _Ln, boolean, []}
%%       | {type, _Ln, byte, []}
%%       | {type, _Ln, char, []}
%%       | {type, _Ln, float, []}
%%       | {type, _Ln, integer, []}
%%       | {type, _Ln, list, (Type)*}
%%       | {type, _Ln, mfa, []}
%%       | {type, _Ln, module, []}
%%       | {type, _Ln, neg_integer, []}
%%       | {type, _Ln, node, []}
%%       | {type, _Ln, no_return, []}
%%       | {type, _Ln, non_neg_integer, []}
%%       | {type, _Ln, none, []}
%%       | {type, _Ln, nonempty_string, []}
%%       | {type, _Ln, number, []}
%%       | {type, _Ln, pid, []}
%%       | {type, _Ln, pos_integer, []}
%%       | {type, _Ln, range, [Type, Type]}
%%       | {type, _Ln, record, [{atom, _Ln, RecordName :: atom()}]}
%%       | {type, _Ln, string, []}
%%       | {type, _Ln, timeout, []}
%%       | {type, _Ln, tuple, [any] | (Type)+}
%%       | {type, _Ln, union, (Type)+}
%%       | {type, _Ln, UserDefinedType :: atom(), (Type)*}
%%       | {parent_type, _Ln, [Type]}
%%       | {ann_type, _Ln, [VarName :: atom(), Type]}
%%       | {remote_type, _Ln, RemType}
%%       | BoundedVar (when we have a BoundedFun or a UserDefinedType)
%%
%%  Literal :: {atom, _Ln, atom()} | {integer, _Ln, integer()} | {type, _Ln, nil, []}
%%  RemType :: [{atom, _Ln, M :: atom()}, {atom, _Ln, T :: atom()}, (Type)*]
%%  BoundedVar :: {var, _Ln, VarName :: atom()}
%% 

-export([retrieve_spec/3, get_params_types/1,
         parse_specs_in_module/1, locate_spec_in_module/1]).

-export_type([type_sig/0, prefixed_type_sig/0, maybe_prefixed_type_sig/0]).

-include("concolic_internal.hrl").
-include_lib("compiler/src/core_parse.hrl").

-record(type, {
  line :: pos_integer(),
  name :: atom(),
  args :: any | list()
}).

-type empty() :: maybe_empty | non_empty.
-type maybe_prefixed_type_sig() :: {ok, prefixed_type_sig()} | error.
-type prefixed_type_sig() :: {?TYPE_SIG_PREFIX, type_sig()}.
-type type_sig() :: {literal, term()}
                  | any
                  | atom
                  | binary
                  | bitstring
                  | boolean
                  | byte
                  | char
                  | float
                  | {function, [type_sig()], type_sig()}
                  | {integer, any | pos | neg | non_neg}
                  | {list, empty(), type_sig()}
                  | mfa
                  | module
                  | node
                  | none
                  | number
                  | pid
                  | {range, type_sig(), type_sig()}
                  | {string, empty()}
                  | timeout
                  | {tuple, [type_sig()]}
                  | {union, [type_sig()]}.

%% =================================================
%% Debugging Funs
%% =================================================

-spec parse_specs_in_module(atom()) -> ok.

parse_specs_in_module(M) ->
  Server = concolic_cserver:init_codeserver("dev", self()),
  {Specs, BoundTypes} = spec_and_bind_types(Server, M),
  parse_all_specs(Server, Specs, BoundTypes),
  error_logger:tty(false),
  concolic_cserver:terminate(Server).

spec_and_bind_types(Server, M) ->
  [{attributes, Attrs}] = 
    case concolic_cserver:load(Server, M) of
      {ok, MDb} -> ets:lookup(MDb, attributes);
      _ -> exit(module_load_error)
    end,
  Types = lists:filtermap(fun filter_types/1, Attrs),
  Specs = lists:filtermap(fun filter_specs/1, Attrs),
  BoundTypes = declare_types(Server, Types),
  {Specs, BoundTypes}.

parse_all_specs(Server, Specs, BoundTypes) ->
  F = fun(X) ->
    io:format("~n%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%~n"),
%    io:format("~p~n",[X]),
    try
      {{F, A}, T} = parse_spec(Server, X, BoundTypes),
      io:format("Spec for ~p/~p~n", [F, A]),
      pp_sig(T),
      io:format("~n"),
      ST = simplify(T),
      pp_sig(ST),
      io:format("~n"),
      {function, Ps, R} = ST,
      FF = fun(XX) ->
        try
          JSON = concolic_json:typesig_to_json({'__type_sig', XX}),
          io:format("~p~n", [JSON])
        catch
          throw:Msg -> io:format("ERROR! ~p~n", [Msg])
        end
      end,
      lists:foreach(FF, Ps ++ [R])
    catch
      exit:E -> io:format("Parse Spec Exception: ~p~n", [E])
    end,
    io:format("~n")
  end,
  lists:foreach(F, Specs).

-spec locate_spec_in_module(mfa()) -> {ok, type_sig()} | error.

locate_spec_in_module({M, _F, _A}=MFA) ->
  Server = concolic_cserver:init_codeserver("dev", self()),
  {Specs, BoundTypes} = spec_and_bind_types(Server, M),
  S = locate_mfa_spec(Server, MFA, Specs, BoundTypes),
  io:format("~p~n", [S]),
  error_logger:tty(false),
  concolic_cserver:terminate(Server),
  S.

%% =================================================

-spec retrieve_spec(pid(), mfa(), [{cerl:cerl(), cerl:cerl()}]) -> maybe_prefixed_type_sig().

retrieve_spec(Server, MFA, Attrs) ->
  Types = lists:filtermap(fun filter_types/1, Attrs),
  Specs = lists:filtermap(fun filter_specs/1, Attrs),
  BoundTypes = declare_types(Server, Types),
  locate_mfa_spec(Server, MFA, Specs, BoundTypes).

locate_mfa_spec(_Server, _MFA, [], _BoundTypes) -> error;
locate_mfa_spec(Server, {_M, F, A}=MFA, [S|Ss], BoundTypes) ->
  case parse_spec(Server, S, BoundTypes) of
    {{F, A}, T} -> {ok, {?TYPE_SIG_PREFIX, simplify(T)}};
    _ -> locate_mfa_spec(Server, MFA, Ss, BoundTypes)
  end.

filter_specs({#c_literal{val = spec}, #c_literal{val = [Spec]}}) -> {true, Spec};
filter_specs(_Attr) -> false.

filter_types({#c_literal{val = type}, #c_literal{val = [Type]}}) -> {true, Type};
filter_types(_Attr) -> false.

%% Replace unions that have an any clause with any
%% (also nested unions)
-spec simplify(type_sig()) -> type_sig().

simplify({function, Ps, R}) ->
  {function, lists:map(fun simplify/1, Ps), simplify(R)};
simplify({list, Empty, T}) ->
  {list, Empty, simplify(T)};
simplify({range, From, To}) ->
  {range, simplify(From), simplify(To)};
simplify({tuple, Vs}) ->
  {tuple, lists:map(fun simplify/1, Vs)};
simplify({union, Vs}) ->
  SimpVs = lists:map(fun simplify/1, Vs),
  case lists:any(fun(T) -> T =:= any end, SimpVs) of
    true  -> any;
    false -> {union, SimpVs}
  end;
simplify(T) -> T.

%% Return the types of a function's parameters
-spec get_params_types(prefixed_type_sig()) -> {ok, [prefixed_type_sig()]} | error.

get_params_types({?TYPE_SIG_PREFIX, {function, Ps, _R}}) ->
  {ok, [{?TYPE_SIG_PREFIX, X} || X <- Ps]};
get_params_types(_) -> error.

%% -------------------------------------------------
%% Declare Types
%% -------------------------------------------------

declare_types(Server, Types) ->
  F = fun(X, Y) -> 
%    io:format("~n$$$~n~p~n$$$~n", [X]),
    declare_type(Server, X, Y)
  end,
  lists:foldl(F, orddict:new(), Types).

%% Store the declaration of a record
declare_type(Server, {{record, RecordName}, RecordSig, []}, Bound) ->
  F = fun(BX) ->
    Ts = lists:map(fun(X) -> parse_record_field(Server, X, BX) end, RecordSig),
    {tuple, [{literal, RecordName} | Ts]}
  end,
  orddict:store({record, RecordName}, F, Bound);
%% Store the declaration of a type
declare_type(Server, {Name, TypeSig, Vars}, Bound) ->
  Vs = lists:map(fun({var, _Ln, X}) -> {var, X} end, Vars),
  F = fun(As, BX) ->
    Ts = lists:map(fun(X) -> fun(T) -> parse_type(Server, X, T) end end, As),
    Zs = lists:zip(Vs, Ts),
    BX1 = lists:foldl(fun({A, B}, C) -> orddict:store(A, B, C) end, BX, Zs),
    parse_type(Server, TypeSig, BX1)
  end,
  orddict:store({type, {Name, length(Vars)}}, F, Bound);
%% XXX Do not expect to get here
declare_type(_Server, Type, _) -> exit({unknown_type, Type}).

%% Get the type of a record's field
parse_record_field(_Server, {record_field, _Ln, _FieldName}, _Bound) ->
  any;
parse_record_field(_Server, {record_field, _Ln, _FieldName, _DefVal}, _Bound) ->
  any;
parse_record_field(Server, {typed_record_field, {record_field, _Ln, _FieldName}, Type}, Bound) ->
  parse_type(Server, Type, Bound);
parse_record_field(Server, {typed_record_field, {record_field, _Ln, _FieldName, _DefVal}, Type}, Bound) ->
  parse_type(Server, Type, Bound).

%% -------------------------------------------------
%% Parse a Spec
%% -------------------------------------------------

parse_spec(Server, {FA, [Type]}, Bound) ->
  {FA, parse_type(Server, Type, Bound)}.

%% literals (atom, integer, [])
parse_type(_Server, {atom, _, A}, _Bound) -> {literal, A};
parse_type(_Server, {integer, _, I}, _Bound) -> {literal, I};
parse_type(_Server, #type{name = nil, args = []}, _Bound) -> {literal, nil};
%% any(), term()
parse_type(_Server, #type{name = X, args = []}, _Bound) when X =:= any; X =:= term->
  any;
%% atom(), binary(), bitstring(), boolean(), byte(), char()
%% float(), mfa(), module(), node(), number(), pid(), timeout()
parse_type(_Server, #type{name = X, args = []}, _Bound)
  when X =:= atom;
       X =:= binary;
       X =:= bitstring;
       X =:= boolean;
       X =:= byte;
       X =:= char;
       X =:= float;
       X =:= mfa;
       X =:= module;
       X =:= node;
       X =:= number;
       X =:= pid;
       X =:= timeout ->
  X;
%% integer()
parse_type(_Server, #type{name = integer, args = []}, _Bound) ->
  {integer, any};
parse_type(_Server, #type{name = pos_integer, args = []}, _Bound) ->
  {integer, pos};
parse_type(_Server, #type{name = neg_integer, args = []}, _Bound) ->
  {integer, neg};
parse_type(_Server, #type{name = non_neg_integer, args = []}, _Bound) ->
  {integer, non_neg};
%% none(), no_return()
parse_type(_Server, #type{name = X, args = []}, _Bound) when X =:= none; X =:= no_return ->
  none;
%% string()
parse_type(_Server, #type{name = string, args = []}, _Bound) -> {string, maybe_empty};
parse_type(_Server, #type{name = nonempty_string, args = []}, _Bound) -> {string, non_empty};
%% list()
parse_type(Server, #type{name = L, args = Args}, Bound) when L =:= list; L =:= nonempty_list ->
  Maps = [{list, maybe_empty}, {nonempty_list, non_empty}],
  case Args of
    []  -> {list, proplists:get_value(L, Maps), any};
    [A] -> {list, proplists:get_value(L, Maps), parse_type(Server, A, Bound)}
  end;
%% tuple()
parse_type(_Server, #type{name = tuple, args = any}, _Bound) ->
  {tuple, []};
parse_type(Server, #type{name = tuple, args = Args}, Bound) ->
  Ts = lists:map(fun(X) -> parse_type(Server, X, Bound) end, Args),
  {tuple, Ts};
%% union()
parse_type(Server, #type{name = union, args = Args}, Bound) ->
  Ts = lists:map(fun(X) -> parse_type(Server, X, Bound) end, Args),
  {union, Ts};
%% range()
parse_type(Server, #type{name = range, args = [From, To]}, Bound) ->
  {range, parse_type(Server, From, Bound), parse_type(Server, To, Bound)};
%% bounded_fun
parse_type(Server, #type{name = bounded_fun, args = [Fun, Cs]}, Bound) ->
  Bound1 = bind_constraints(Server, Cs, Bound),
  parse_type(Server, Fun, Bound1);
%% fun
parse_type(Server, #type{name = 'fun', args = [Param, Result]}, Bound) ->
  Ptype = ensure_param_list(parse_type(Server, Param, Bound)),
  Rtype = parse_type(Server, Result, Bound),
  {function, Ptype, Rtype};
%% product (used in fun)
parse_type(Server, #type{name = product, args = Args}, Bound) ->
  lists:map(fun(X) -> parse_type(Server, X, Bound) end, Args);
%% annotated type
parse_type(Server, {ann_type, _Ln, [_Var, Type]}, Bound) ->
  parse_type(Server, Type, Bound);
%% parenthesized type
parse_type(Server, {paren_type, _Ln, [Type]}, Bound) ->
  parse_type(Server, Type, Bound);
%% record()
parse_type(_Server, #type{name = record, args = [{atom, _Ln, Rec}]}, Bound) ->
  V = orddict:fetch({record, Rec}, Bound),
  V(Bound);
%% user defined type
parse_type(_Server, #type{name = Type, args = Args}, Bound) ->
  V = orddict:fetch({type, {Type, length(Args)}}, Bound),
  V(Args, Bound);
%% bound variable (used in bounded_funs, records, user defined types)
parse_type(_Server, {var, _Ln, Var}, Bound) ->
  V = orddict:fetch({var, Var}, Bound),
  V(Bound);
%% XXX
parse_type(_Server, Type, _) -> exit(Type).

%% Store the constraints of a bounded fun
bind_constraints(Server, Cs, Bound) ->
  lists:foldl(fun(X, Y) -> parse_constraint(Server, X, Y) end, Bound, Cs).

%% Store the type of a constraint (in a bounded fun)
parse_constraint(Server, #type{name = constraint, args = [{atom, _, is_subtype}, [Var, Type]]}, Bound) ->
  {var, _, V} = Var,
  orddict:store({var, V}, fun(BX) -> parse_type(Server, Type, BX) end, Bound).

ensure_param_list(Ps) when is_list(Ps) -> Ps;
ensure_param_list(P) -> [P].

%% -------------------------------------------------
%% Pretty Print a type_sig()
%% -------------------------------------------------

%% literal
pp_sig({literal, Lit}) -> io:format("~p", [Lit]);
%% any, atom, binary, bitstring, boolean, byte, char,
%% float, mfa, module, node, none, number, pid, timeout
pp_sig(T) when T =:= any;
               T =:= atom;
               T =:= binary;
               T =:= bitstring;
               T =:= boolean;
               T =:= byte;
               T =:= char;
               T =:= float;
               T =:= mfa;
               T =:= module;
               T =:= node;
               T =:= none;
               T =:= number;
               T =:= pid;
               T =:= timeout ->
  io:format("~p()", [T]);
%% string
pp_sig({string, maybe_empty}) -> io:format("string()");
pp_sig({string, non_empty})   -> io:format("nonempty_string()");
%% integer
pp_sig({integer, any}) -> io:format("integer()");
pp_sig({integer, X})   -> io:format("~p_integer()", [X]);
%% list
pp_sig({list, Empty, S}) ->
  io:format("["),
  pp_sig(S),
  case Empty of
    maybe_empty -> ok;
    non_empty -> io:format(", ...")
  end,
  io:format("]");
%% union
pp_sig({union, [S|Sigs]}) ->
  io:format("("),
  pp_sig(S),
  lists:foreach(fun(X) -> io:format(" | "), pp_sig(X) end, Sigs),
  io:format(")");
%% range
pp_sig({range, F, T}) ->
  pp_sig(F),
  io:format(".."),
  pp_sig(T);
%% tuple
pp_sig({tuple, []}) -> io:format("tuple()");
pp_sig({tuple, [S|Sigs]}) ->
  io:format("{"),
  pp_sig(S),
  lists:foreach(fun(X) -> io:format(" , "), pp_sig(X) end, Sigs),
  io:format("}");
%% fun
pp_sig({function, [], R}) ->
  io:format("fun() -> "),
  pp_sig(R);
pp_sig({function, [P|Ps], R}) ->
  io:format("fun("),
  pp_sig(P),
  lists:foreach(fun(X) -> io:format(" , "), pp_sig(X) end, Ps),
  io:format(") -> "),
  pp_sig(R).

