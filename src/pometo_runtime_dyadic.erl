-module(pometo_runtime_dyadic).

%% exported for inclusion in compiled modules
%% should never be called directly
-export([
					dyadic_RUNTIME/1
				]).

%% exported for use in other parts of the runtime
-export([
					zip/4
				]).

-include_lib("eunit/include/eunit.hrl").

-include("parser_records.hrl").
-include("errors.hrl").
-include("runtime_include.hrl").

dyadic_RUNTIME([#'$func¯'{do      = [Fn],
													rank    = Rank,
													line_no = LNo,
													char_no = CNo},
								#'$ast¯'{do      = ?shape(_D1, Type)} = Left,
								#'$ast¯'{}                            = Right]) when (Type == number  orelse
																																		  Type == boolean orelse
																																		  Type == mixed   orelse
																																		  Type == complex orelse
																																		  Type == runtime orelse
																																		  Type == array)  andalso
																																		 (Fn == "/"       orelse
																																		  Fn == "⌿") ->
	NewLeft  = pometo_runtime:make_eager(pometo_runtime:maybe_cast_scalar_to_vector(Left)),
	NewRight = pometo_runtime:make_eager(pometo_runtime:maybe_cast_scalar_to_vector(Right)),
	#'$ast¯'{do = ?shp(NewD1)} = NewLeft,
	#'$ast¯'{do = ?shp(NewD2)} = NewRight,
	ActualRank = pometo_runtime:resolve_rank(NewD2, Rank),
	ok = pometo_runtime_rank:is_rank_valid(NewRight, ActualRank, LNo, CNo),
	_Compatability = pometo_runtime_rank:check_shape_compatible(ActualRank, NewD1, NewD2, LNo, CNo),
	ExpandedShape = pometo_runtime_rank:iterate_over_rank(NewLeft, NewRight, ActualRank, fun replicate/7),
	#'$ast¯'{do = Shp} = ExpandedShape,
	NewDims = make_replacement_dims(ActualRank, Left, ExpandedShape),
	ExpandedShape#'$ast¯'{do = Shp#'$shape¯'{dimensions = NewDims,
																				   indexed    = true}};
% rho needs to know the length of the vector
% this clause handles both a scalar and a vector on either of the LHS or the RHS
dyadic_RUNTIME([#'$func¯'{do = ["⍴"]},
								#'$ast¯'{do      = ?shape(N1, Type1) = Shp,
												 args    = A1,
												 line_no = LNo,
												 char_no = CNo},
								#'$ast¯'{do      = ?shape(N2, Type2),
												 args    = A2} = Right]) when Type1 == number  orelse
												                              Type1 == boolean ->
	% this casts any scalars on either side to vectors
	NewN2 = case N2 of
			unsized_vector -> [length(A2)];
			_              -> N2
	end,

	NewA1 = case N1 of
				0 -> [A1];   % scalar
				_ -> A1
			end,
	NewA2 = case NewN2 of
				0 -> [A2];   % scalar
				_ -> A2
			end,
	case pometo_runtime:are_all_positive_integers(NewA1) of
		true ->
			{Size, NewA1} = case NewA1 of
				Map  when is_map(Map)   -> {pometo_runtime:get_no_of_elements_from_args(NewA1), NewA1};
				List when is_list(List) -> {pometo_runtime:get_no_of_elements_from_args(NewA1), NewA1};
				N                       -> {N, [N]}
			end,
			SliceSize = pometo_runtime:get_no_of_elements_from_dims(NewN2),
			NewArgs = if
						Size <  SliceSize -> pometo_runtime:snip_args(NewA2, Size);
						Size == SliceSize -> NewA2;
						Size >  SliceSize -> Repetitions = trunc(Size/SliceSize),
																 Rem = Size rem SliceSize,
																 TopUp = pometo_runtime:snip_args(NewA2, Rem),
																 pometo_runtime:extend(NewA2, SliceSize, Repetitions, TopUp, Rem)
						 end,
			Indexed = if
				is_map(NewArgs)  -> true;
				is_list(NewArgs) -> false
			end,
			Right#'$ast¯'{do   = Shp#'$shape¯'{dimensions = pometo_runtime:args_to_list(NewA1),
																				 indexed    = Indexed,
																				 type       = Type2},
										args = NewArgs};
		false ->
			Msg1  = "dyadic ⍴ only accepts integer arguments to the left and was called with",
			Args1 = pometo_runtime:args_to_list(A1),
			Args2 = pometo_runtime:args_to_list(A2),
			Msg2  = io_lib:format("Left: ~p - Right: ~p", [Args1, Args2]),
			Error = pometo_runtime_format:make_error("DOMAIN ERROR", Msg1, Msg2, LNo, CNo),
			throw({error, Error})
	end;
%% complex element number handling first
%% complex numbers in arrays are unpacked in execute_dyadic
%% some ops on complex numbers are simple scalar extentions
dyadic_RUNTIME([#'$func¯'{}       = Func,
								?complex_el(A1)   = Left,
								?complex_el(A2)]) ->
	Vals = do_complex(Func, A1, A2),
	Left?complex_el(Vals);
% mixed real and complex addition and subtraction
dyadic_RUNTIME([#'$func¯'{}           = Func,
								?complex_el(A1)       = Left,
								#'$ast¯'{do = ?shp(0),
												 args = A2}]) ->
	Vals = do_complex(Func, A1, [A2, 0]),
	Left?complex_el(Vals);
dyadic_RUNTIME([#'$func¯'{}              = Func,
								#'$ast¯'{do   = ?shp(0),
												 args = A1},
								?complex_el(A2)          = Right]) ->
	Vals = do_complex(Func, [A1, 0], A2),
	Right?complex_el(Vals);

% handle scalars
% if both sides are scalar return a scalar
dyadic_RUNTIME([#'$func¯'{} = Func,
								#'$ast¯'{do = ?shp(0),
												 args = A1} = Left,
								#'$ast¯'{do = ?shp(0),
												 args = A2}]) ->
	Val = execute_dyadic(Func, A1, A2),
	Left#'$ast¯'{args = Val};
% if one side is a scalar cast it to an array
dyadic_RUNTIME([#'$func¯'{}             = Func,
								#'$ast¯'{do = ?shp(0)}  = Left,
								#'$ast¯'{do = ?shp(_N)} = Right]) ->
	% order of A2 and A1 swapped and return record based on 2nd shp
	apply(Func, Right, pometo_runtime:maybe_cast_scalar_to_vector(Left), left, fun dyadic_fn/3);
dyadic_RUNTIME([#'$func¯'{}             = Func,
								#'$ast¯'{do = ?shp(_N)} = Left,
								#'$ast¯'{do = ?shp(0)}  = Right]) ->
	apply(Func, Left, pometo_runtime:maybe_cast_scalar_to_vector(Right), right, fun dyadic_fn/3);
%% now plain number handling
%% this clause will match two unsized vectors or two vectors of the same size
dyadic_RUNTIME([#'$func¯'{}            = Func,
								#'$ast¯'{do = ?shp(N)} = Left,
								#'$ast¯'{do = ?shp(N)} = Right]) ->
	zip(Func, Left, Right, fun dyadic_fn/3);
%% this clause will handle on mixed case
dyadic_RUNTIME([#'$func¯'{}                         = Func,
								#'$ast¯'{do = ?shp(unsized_vector)} = Left,
								#'$ast¯'{do = ?shp(L)}              = Right]) when is_list(L) ->
	zip(Func, Left, Right, fun dyadic_fn/3);
%% this clause will handle the other
dyadic_RUNTIME([#'$func¯'{}                         = Func,
								#'$ast¯'{do = ?shp(L)}              = Left,
								#'$ast¯'{do = ?shp(unsized_vector)} = Right]) when is_list(L) ->
	zip(Func, Left, Right, fun dyadic_fn/3);
dyadic_RUNTIME([#'$func¯'{} = Func,
								#'$ast¯'{do = ?shp([1])} = Left,
								#'$ast¯'{}               = Right]) ->
	% order of A2 and A1 swapped and return record based on 2nd shp
	apply(Func, Right, Left, left, fun dyadic_fn/3);
dyadic_RUNTIME([#'$func¯'{}              = Func,
								#'$ast¯'{}               = Left,
								#'$ast¯'{do = ?shp([1])} = Right]) ->
	apply(Func, Left, Right, right, fun dyadic_fn/3);
dyadic_RUNTIME([#'$func¯'{do = Do},
								#'$ast¯'{do      = ?shp(N1),
												 line_no = LNo,
												 char_no = CNo},
								#'$ast¯'{do      = ?shp(N2)}]) ->
	Lhs = case is_list(N1) of
		true  -> string:join([get_fmt(X) || X <- N1], ", ");
		false -> get_fmt(N1)
	end,
	Rhs = case is_list(N2) of
		true  -> string:join([get_fmt(X) || X <- N2], ", ");
		false -> get_fmt(N2)
	end,
	Msg1  = io_lib:format("dimensions mismatch in dyadic ~p", [Do]),
	Msg2  = io_lib:format("LHS dimensions ~p - RHS dimensions ~p", [Lhs, Rhs]),
	Error = pometo_runtime_format:make_error("LENGTH ERROR", Msg1, Msg2, LNo, CNo),
	throw({error, Error}).

dyadic_fn(N, Val, Acc) when is_list(Acc) -> {N + 1, [Val | Acc]};
dyadic_fn(N, Val, Acc) when is_map(Acc)  -> {N + 1, maps:put(N, Val, Acc)}.

%%
%% private fns
%%

zip(Func, #'$ast¯'{do    = #'$shape¯'{} = Shp,
									 args    = Args1,
									 line_no = LNo,
									 char_no = CNo} = AST1,
					#'$ast¯'{do      = #'$shape¯'{},
									 args    = Args2} = AST2, ZipFn) ->
	Accumulator = pometo_runtime:choose_accumulator(AST1, AST2),
	Left  = make_enumerable(Args1),
	Right = make_enumerable(Args2),
	{NoArgs, NewArgs} = do_zip(Left, Right, Func, LNo, CNo, ZipFn, ?START_COUNTING_ARGS, Accumulator),
	pometo_runtime:set_return_type(AST1#'$ast¯'{do   = Shp#'$shape¯'{dimensions = [NoArgs]},
																						  args = NewArgs}, Accumulator).

do_zip(Left, Right, Func, LNo, CNo, ZipFn, N, Acc) ->
	case {is_terminated(Left), is_terminated(Right)} of
		{true,  true} ->
			{N - 1, pometo_runtime:maybe_reverse(Acc)};
		{false, true} ->
			zip_error(Func, LNo, CNo, N);
		{true,  false} ->
			zip_error(Func, LNo, CNo, N);
		{false, false} ->
			{NewL, ValL} = get_first(Left),
			{NewR, ValR} = get_first(Right),
			NewVal = execute_dyadic(Func, ValL, ValR),
			{NewN, NewAcc} = ZipFn(N, NewVal, Acc),
			do_zip(NewL, NewR, Func, LNo, CNo, ZipFn, NewN, NewAcc)
	end.

zip_error(#'$func¯'{do = Do}, LNo, CNo, N) ->
	Msg1 = io_lib:format("dimensions mismatch in dyadic ~p", [Do]),
	Msg2 = case N - 1 of
		1 -> io_lib:format("ran out of matches after 1 element",   []);
		_ -> io_lib:format("ran out of matches after ~p elements", [N - 1])
	end,
	Error = pometo_runtime_format:make_error("LENGTH ERROR", Msg1, Msg2, LNo, CNo),
	throw({error, Error}).

is_terminated({map, none}) -> true;
is_terminated({list, []})  -> true;
is_terminated(_)           -> false.

make_enumerable(Map)  when is_map(Map)   -> {map,  maps:iterator(Map)};
make_enumerable(List) when is_list(List) -> {list, List}.

apply(Func, #'$ast¯'{args = Args} = AST, Singleton, Direction, ZipFn) ->
	Accumulator = pometo_runtime:choose_accumulator(AST, Singleton),
	Left  = make_enumerable(Args),
	Val = get_singleton(Singleton),
	{NoArgs, NewArgs} = do_apply(Left, Val, Direction, Func, ZipFn, ?START_COUNTING_ARGS, Accumulator),
	pometo_runtime:set_return_type(maybe_make_eager(AST#'$ast¯'{args = NewArgs}, NoArgs), Accumulator).

do_apply(Left, Val, Direction, Func, ZipFn, N, Acc) ->
	case is_terminated(Left) of
		true  -> {N - 1, pometo_runtime:maybe_reverse(Acc)};
		false -> {NewL, ValL} = get_first(Left),
							NewVal = case Direction of
								left  -> execute_dyadic(Func, Val,  ValL);
								right -> execute_dyadic(Func, ValL, Val)
							end,
							{NewN, NewAcc} = ZipFn(N, NewVal, Acc),
							do_apply(NewL, Val, Direction, Func, ZipFn, NewN, NewAcc)
	end.

get_singleton(#'$ast¯'{args = Map}) when is_map(Map) -> maps:get(1, Map);
get_singleton(#'$ast¯'{args = [X]})                  -> X.

% first capture the complex nos
execute_dyadic(Func, ?cmplx(L), ?cmplx(R)) -> ?cmplx(do_complex(Func, L,      R));
execute_dyadic(Func, ?cmplx(L), R)         -> ?cmplx(do_complex(Func, L,      [R, 0]));
execute_dyadic(Func,  L,        ?cmplx(R)) -> ?cmplx(do_complex(Func, [L, 0], R));

% we don't want reduce (or any axis operators) to descend into the AST
execute_dyadic(#'$func¯'{do = ["/"]}, L, R) -> duplicate(L, R);

%% complex arrays
execute_dyadic(Func, #'$ast¯'{} = L, #'$ast¯'{} = R) -> dyadic_RUNTIME([Func, L, R]);
execute_dyadic(Func, #'$ast¯'{} = L, R)              -> dyadic_RUNTIME([Func, L, make_scalar_ast(R)]);
execute_dyadic(Func, L,              #'$ast¯'{} = R) -> dyadic_RUNTIME([Func, make_scalar_ast(L), R]);

% if a function can be applied to a complex no it
% has to be listed after the complex execution descends into the
% complex AST
execute_dyadic(#'$func¯'{do = ["+"]}, L, R) -> L + R;
execute_dyadic(#'$func¯'{do = ["-"]}, L, R) -> L - R;
execute_dyadic(#'$func¯'{do = ["×"]}, L, R) -> L * R;
execute_dyadic(#'$func¯'{do = ["÷"]}, L, R) -> L / R;
execute_dyadic(#'$func¯'{do = ["|"]}, 0, R) -> R;
execute_dyadic(#'$func¯'{do = ["|"]}, L, R) -> R/L.

duplicate(L, R) ->
	lists:duplicate(L, R).

make_scalar_ast(Arg) -> Shp = #'$shape¯'{dimensions = 0},
												#'$ast¯'{do = Shp, args = Arg}.

do_complex(#'$func¯'{do = [Do]} = Func, A1, A2) when Do == "+" orelse
																							       Do == "-" ->
	% call zip with dummy line and char nos because we know it won't fail
	% and they are only needed for the error message
	% make 'em grepable because yeah-it-can-never-get-there code ***ALWAYS*** gets executed
	% that's the law, I didn't fuckin make it, ok? bud...
	Left  = make_enumerable(A1),
	Right = make_enumerable(A2),
	{_NoArgs, Vals} = do_zip(Left, Right, Func, -98765, -98765, fun dyadic_fn/3, ?START_COUNTING_ARGS, ?EMPTY_ACCUMULATOR),
	Vals;
do_complex(#'$func¯'{do = [Do]}, [Rl1, Im1], [Rl2, Im2]) when Do == "×" ->
	[Rl1 * Rl2 - Im1 * Im2, Rl1 * Im2 + Im1 * Rl2];
do_complex(#'$func¯'{do = [Do]}, [Rl1, Im1], [Rl2, Im2]) when Do == "÷" ->
	Sq = Rl2 * Rl2 + Im2 * Im2,
	Real = (Rl1 * Rl2 + Im1 * Im2)/Sq,
	Imag = (Im1 * Rl2 - Rl1 * Im2)/Sq,
	[Real, Imag].

maybe_make_eager(#'$ast¯'{do = #'$shape¯'{dimensions = unsized_vector} = Shp} = AST, NoArgs) ->
	AST#'$ast¯'{do = Shp#'$shape¯'{dimensions = [NoArgs]}};
maybe_make_eager(X, _N) ->
	X.

get_first({map, Iter})      -> {_K, Val, NewIter} = maps:next(Iter),
															 {{map,  NewIter}, Val};
get_first({list, [H | T]})  -> {{list, T},       H}.


get_fmt(X) ->
	#fmt_segment{strings = [Str]} = pometo_runtime_format:fmt(X),
	Str.

replicate(OutputN, LHS, ChunkSize, ChunkNo, RankLen, Chunk, Acc) ->
	% '/' converts lazy to eager already
	#'$ast¯'{do = #'$shape¯'{dimensions = Dims}} = LHS,
	Lookup = case ChunkNo rem RankLen of
		0 -> RankLen;
		N -> N
	end,
	Mult = case Dims of
		[1] -> pometo_runtime:get_nth(LHS, 1);
		_   -> pometo_runtime:get_nth(LHS, Lookup)
	end,
	replicate2(?START_COUNTING_ARGS, OutputN, Mult + 1, ChunkSize, Chunk, Acc).

replicate2(_Mult, OutputN, _Mult, _ChunkSize, _Chunk, Acc) ->
	{OutputN, Acc};
replicate2(N, OutputN, Mult, ChunkSize, Chunk, Acc) ->
	{NewOutputN, NewAcc} = replicate3(OutputN, ?START_COUNTING_ARGS, ChunkSize + 1, Chunk, Acc),
	replicate2(N + 1, NewOutputN, Mult, ChunkSize, Chunk, NewAcc).

replicate3(OutputN, _ChunkSize, _ChunkSize, _Chunk, Acc) ->
	{OutputN, Acc};
replicate3(OutputN, N, ChunkSize, Chunk, Acc) ->
	NewVal = maps:get(N, Chunk),
	NewAcc = maps:put(OutputN, NewVal, Acc),
	replicate3(OutputN + 1, N + 1, ChunkSize, Chunk, NewAcc).

%dyadic_map(N, Vals, Acc) when is_list(Vals) andalso
%															is_list(Acc)         -> Len = length(Vals),
%																											{N + Len, Vals ++ Acc};
%dyadic_map(N, Val,  Acc) when is_list(Acc)         -> {N + 1, [Val | Acc]};
%dyadic_map(N, Vals, Map) when is_list(Vals) andalso
%															is_map(Map)          -> AccFun = fun(V, {K, M}) ->
%																								       {K + 1, maps:put(K, V, M)}
%																							        end,
%																							        lists:foldl(AccFun, {N, Map}, Vals);
%dyadic_map(N, Val,  Map) when is_map(Map)          -> {N + 1, maps:put(N, Val, Map)}.

make_replacement_dims(Rank, #'$ast¯'{do   = ?shp(0),
																		 args = Args}, Right) ->
	#'$ast¯'{do = #'$shape¯'{dimensions = D}} = Right,
	NewDim = sumup(Args),
	{LDim, RDim} = lists:split(Rank - 1, D),
	case RDim of
								[] -> LDim ++ [NewDim];
								_  -> [H | T] = RDim,
											LDim ++ [NewDim * H| T]
	end;
make_replacement_dims(Rank, #'$ast¯'{args = Args}, Right) ->
	#'$ast¯'{do = #'$shape¯'{dimensions = D}} = Right,
	NewDim = sumup(Args),
	{LDim, RDim} = lists:split(Rank - 1, D),
	case RDim of
								[] -> LDim ++ [NewDim];
								_  -> [_H | T] = RDim,
											LDim ++ [NewDim| T]
	end.

sumup(List) when is_list(List) -> lists:sum(List);
sumup(Map)  when is_map(Map)   -> {_Keys, Vals} = lists:unzip(maps:to_list(Map)),
																	lists:sum(Vals);
sumup(N)   when is_integer(N)  -> N.
