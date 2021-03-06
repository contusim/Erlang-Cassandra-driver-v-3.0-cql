%% Reads binary stream, makes #frame{} records
-module(ecql_parser).
-include("ecql.hrl").
-compile(export_all).

read_frame(<<   Type:1,
                Ver:7/unsigned-integer,
                Flags:8/unsigned-integer,
                Stream:8/signed-integer,
                Opcode:8/unsigned-integer,
                Len:32/big-unsigned-integer,
                Body:Len/binary-unit:8,
                Rest/binary 
            >>) ->
    FrameType = case Type of
        0 -> request;
        1 -> response
    end,
    F = #frame{
        type    = FrameType,
        version = Ver,
        flags   = Flags,
        stream  = Stream,
        opcode  = Opcode,
        length  = Len,
        body    = Body
    },
    {F, Rest};

read_frame(Bin) when is_binary(Bin) ->
    {continue, Bin}.


encode(#frame{
    version = Ver,
    flags = Flags,
    stream = Stream,
    opcode = Opcode,
    body = Body
    } = _F) when Opcode =/= undefined, is_integer(Ver), is_integer(Flags) ->
    Len = iolist_size(Body),
    [<< 
        Ver:8/unsigned-integer,
        Flags:8/unsigned-integer,
        Stream:8/signed-integer,
        Opcode:8/unsigned-integer,
        Len:32/big-unsigned-integer
     >>,
     Body
    ].

make_query_frame(Query0) ->
	make_query_frame(Query0,<<0>>).

make_query_frame(Query0, Flags) ->
	make_query_frame(Query0,Flags, one).

make_query_frame(Query0, Flags, Consistency) ->
	make_query_frame(Query0, Flags, Consistency, 0).

make_query_frame(Query0, Flags, Consistency, StreamId) ->
    Query = fixup_query(Query0),
    B = [
        encode_long_string(Query),
        encode_consistency(Consistency),
		Flags
    ],
    #frame{
        opcode = ?OP_QUERY,
		stream = StreamId,
        body = B
    }.

fixup_query(Q) when is_list(Q) -> unicode:characters_to_binary(Q,utf8);
fixup_query(Q) when is_binary(Q) -> Q.

encode_bytes(B) when is_binary(B) ->
    L = size(B),
    << L:?int, B/binary >>.

val_encode_bytes({bytes, V}) -> encode_bytes(V);
val_encode_bytes({text,  V}) -> encode_bytes(V);
val_encode_bytes({_,     V}) -> encode_bytes(V);
%% Infer types when unspecified:
val_encode_bytes(Num) when is_integer(Num) -> val_encode_bytes({int,Num});
val_encode_bytes(Bin) when is_binary(Bin)  -> val_encode_bytes({text,Bin});
val_encode_bytes(E) -> throw({unknown_val_type, E}).

encode_string_map(L) ->
    {N, List} = lists:foldl(fun({K,V}, {C,Acc}) ->
        {C+1, [
            encode_string(K),
            encode_string(V)
            | Acc
        ]}
    end, {0,[]}, L),
    [ encode_short(N), List ].

encode_int(Int) when is_integer(Int) ->
    << Int:?int >>.

consume_int(<<I:?int,Rest/binary>>) ->
    {I, Rest}.

encode_short(Short) when is_integer(Short) ->
    << Short:?short >>.

encode_string(Str) when is_list(Str) ->
	encode_string(unicode:characters_to_binary(Str,utf8));

encode_string(Str) when is_binary(Str) ->
    Size = size(Str),
    [<< Size:?short >>, Str].

consume_string(<<Len:?short,Str:Len/binary-unit:8,Rest/binary>>) ->
    {Str, Rest}.

encode_long_string(Str) when is_list(Str) ->
	encode_long_string(unicode:characters_to_binary(Str,utf8));

encode_long_string(Str) when is_binary(Str) ->
    Size = size(Str),
    [<< Size:?int >>, Str].

consume_short_bytes(<<Len:?short,Bytes:Len/binary-unit:8,Rest/binary>>) ->
    {Bytes,Rest}.

consume_bytes(<<Len:?int,Rest/binary>>) ->
	if Len >= 0 -> 
		<<Bytes:Len/binary-unit:8,R>> = Rest,
		{Bytes,R};
	true -> 
		{null, Rest}
	end.

consume_metadata(<<Flags:?int,ColCount:?int,R/binary>>) ->	
	{HMP, Rest} = case (Flags band ?HAS_MORE_PAGES) =:= ?HAS_MORE_PAGES of
					true -> consume_bytes(R);
					false -> {undefined, R}
				end,
	MD = #metadata{
        flags = Flags,
        numcols = ColCount,
		paging_state = HMP
    },		
	case (Flags band ?NO_METADATA) =:= ?NO_METADATA of
		true ->
			io:format("No metadata to parse"),
			{MD,Rest};
		false ->
			case (Flags band ?GLOBAL_TABLES_SPEC) =:= ?GLOBAL_TABLES_SPEC of
				true ->
					{KeySpace, R1} = consume_string(Rest),
					{Table, R2} = consume_string(R1),
					{ColSpecs, R3} = consume_colspecs_global(ColCount, R2),
					{MD#metadata{
						global_keyspace = KeySpace,
						global_table = Table,
						columns = list_to_tuple(ColSpecs)
					}, R3};
				false ->
					{ColSpecs, R} = consume_colspecs(ColCount, Rest),
					{MD#metadata{
						columns = list_to_tuple(ColSpecs)
					}, R}
			end
	end.

consume_option(<<Id:?short,Rest/binary>>) ->
    case Id of
        16#0000  -> % Custom: the value is a [string] of custom type name
            {TypeName, Rest2} = consume_string(Rest),
            {{custom, TypeName}, Rest2};
        16#0001  -> % Ascii
            {ascii, Rest};
        16#0002  -> % Bigint
            {bigint, Rest};
        16#0003  -> % Blob
            {blob, Rest};
        16#0004  -> % Boolean
            {boolean, Rest};
        16#0005  -> % Counter
            {counter, Rest};
        16#0006  -> % Decimal
            {decimal, Rest};
        16#0007  -> % Double
            {double, Rest};
        16#0008  -> % Float
            {float, Rest};
        16#0009  -> % Int
            {int, Rest};
        16#000B  -> % Timestamp
            {timestamp, Rest};
        16#000C  -> % Uuid
            {uuid, Rest};
        16#000D  -> % Varchar
            {varchar, Rest};
        16#000E  -> % Varint
            {varint, Rest};
        16#000F  -> % Timeuuid
            {timeuuid, Rest};
        16#0010  -> % Inet
            {inet, Rest};
        16#0020  -> % List: the value is an [option], representing the type
                    %      of the elements of the list.
            {ListType, Rest2} = consume_option(Rest),
            {{list, ListType}, Rest2};
        16#0021  -> % Map: the value is two [option], representing the types of the
                    %     keys and values of the map
            {KeyType, Rest2} = consume_option(Rest),
            {ValType, Rest3} = consume_option(Rest2),
            {{map, KeyType, ValType}, Rest3};
        16#0022  -> % Set: the value is an [option], representing the type
                    %      of the elements of the set
            {ItemType, Rest2} = consume_option(Rest),
            {{set, ItemType}, Rest2}
    end.


consume_colspecs_global(N, Bin) when is_integer(N), is_binary(Bin) ->
    consume_colspecs_global(N,Bin,[]).

consume_colspecs_global(0, R, Acc) -> {lists:reverse(Acc), R};
consume_colspecs_global(NumCols, R, Acc) ->
    {ColName, R1} = consume_string(R),
    {ColType, R2} = consume_option(R1),
    ColSpec = {ColType, ColName},
    consume_colspecs_global(NumCols - 1, R2, [ColSpec | Acc]).

consume_colspecs(N, Bin) when is_integer(N), is_binary(Bin) ->
    consume_colspecs(N,Bin,[]).

consume_colspecs(0, R, Acc) -> {lists:reverse(Acc), R};
consume_colspecs(NumCols, R, Acc) ->
    {KeySpace, R1} = consume_string(R),
    {Table,    R2} = consume_string(R1),
    {ColName,  R3} = consume_string(R2),
    {ColType,  R4} = consume_option(R3),
    ColSpec = {{KeySpace,Table}, ColType, ColName},
    consume_colspecs_global(NumCols - 1, R4, [ColSpec | Acc]).

consume_num_rows(Num, MD = #metadata{}, Bin) when is_integer(Num), is_binary(Bin) ->
    consume_num_rows(Num, MD, Bin, []).


consume_num_rows(0, _MD, Bin, Acc) -> 
    {lists:reverse(Acc), Bin};
consume_num_rows(N, MD, Bin, Acc) ->
    {Fields, Rest} = consume_columns(MD, MD#metadata.numcols, Bin, 1, []),
    consume_num_rows(N-1, MD, Rest, [Fields|Acc]).

consume_columns(_MD, 0, Rest, _ColPos, Acc) -> {lists:reverse(Acc), Rest};
consume_columns(MD, N, <<Len:?int, Rest/binary>>, ColPos, Acc) when N > 0 ->
	ColType = case MD#metadata.columns of
					[] ->
						blob;
					_ ->
						{CT,_ColName} = element(ColPos, MD#metadata.columns),
						CT
				end,
    case Len =:= -1 of
        true -> 
            consume_columns(MD, N-1, Rest, ColPos + 1, [null | Acc]);
        false ->
            <<Bytes:Len/binary-unit:8, Bin/binary>> = Rest,
            Val = column_bytes_to_type(ColType, Bytes),
            consume_columns(MD, N-1, Bin, ColPos + 1, [Val | Acc])
    end.

%% TODO check what format stuff is, like what's a counter, etc?
column_bytes_to_type({custom, _}, Bytes) -> Bytes;
column_bytes_to_type(ascii, Bytes) -> Bytes;
column_bytes_to_type(bigint, <<V:64/big-integer>>) -> V;
column_bytes_to_type(blob, Bytes) -> Bytes;
column_bytes_to_type(boolean, Bytes) -> Bytes;
column_bytes_to_type(counter, Bytes) -> column_bytes_to_type(bigint, Bytes);
column_bytes_to_type(decimal, Bytes) -> parse_decimal(Bytes); %% variable precision decimal?
column_bytes_to_type(double, Bytes) -> Bytes; %% 64 bit float
column_bytes_to_type(float, Bytes) -> Bytes; %% 32 bit float
column_bytes_to_type(int, <<V:32/big-integer>>) -> V;
column_bytes_to_type(text, Bytes) -> Bytes;
column_bytes_to_type(timestamp, Bytes) -> parse_timestamp(Bytes);
column_bytes_to_type(uuid, Bytes) -> Bytes;
column_bytes_to_type(varchar, Bytes) -> Bytes;
column_bytes_to_type(varint, Bytes) -> parse_varint(Bytes);
column_bytes_to_type(timeuuid, Bytes) -> parse_timeuuid(Bytes);
column_bytes_to_type(inet, Bytes) -> parse_inet(Bytes);
column_bytes_to_type({list, Type}, Bytes) ->
    {{list,Type}, Bytes};
column_bytes_to_type({map, Type}, Bytes) ->
    {{map,Type}, Bytes};
column_bytes_to_type({set, Type}, Bytes) ->
    {{set,Type}, Bytes}.

parse_timeuuid(Bytes) -> {timeuuid, parse_timestamp(Bytes)}.
parse_timestamp(Bytes) -> {timestamp, Bytes}.
parse_varint(Bytes) -> {varint, Bytes}.
parse_decimal(Bytes) -> {decimal, Bytes}.
parse_inet(Bytes) -> {inet, Bytes}.

encode_consistency(any)         -> << ?CONSISTENCY_ANY:?short >>;
encode_consistency(one)         -> << ?CONSISTENCY_ONE:?short >>;
encode_consistency(two)         -> << ?CONSISTENCY_TWO:?short >>;
encode_consistency(three)       -> << ?CONSISTENCY_THREE:?short >>;
encode_consistency(quorum)      -> << ?CONSISTENCY_QUORUM:?short >>;
encode_consistency(all)         -> << ?CONSISTENCY_ALL:?short >>;
encode_consistency(local_quorum)-> << ?CONSISTENCY_LOCAL_QUORUM:?short >>;
encode_consistency(each_quorum) -> << ?CONSISTENCY_EACH_QUORUM:?short >>;
encode_consistency(serial) 		-> << ?CONSISTENCY_SERIAL:?short >>;
encode_consistency(local_serial) -> << ?CONSISTENCY_LOCAL_SERIAL:?short >>.

decode_consistency(?CONSISTENCY_ANY)        -> any;
decode_consistency(?CONSISTENCY_ONE)        -> one;
decode_consistency(?CONSISTENCY_TWO)        -> two;
decode_consistency(?CONSISTENCY_THREE)      -> three;
decode_consistency(?CONSISTENCY_QUORUM)     -> quorum;
decode_consistency(?CONSISTENCY_ALL)        -> all;
decode_consistency(?CONSISTENCY_LOCAL_QUORUM) -> local_quorum;
decode_consistency(?CONSISTENCY_EACH_QUORUM)  -> each_quorum;
decode_consistency(?CONSISTENCY_SERIAL)  -> serial;
decode_consistency(?CONSISTENCY_LOCAL_SERIAL)  -> local_serial.



binary_to_type(bigint,      <<V:64/big-integer>>) -> V;
binary_to_type(varchar,     V) -> V;
binary_to_type(T, _) -> throw({cant_cast_type, T}).

%% returns error atom, or {atom, Fun} to convert rest of ERROR msg body to props
error_code(16#0000) -> server_error;
error_code(16#000A) -> protocol_error;
error_code(16#0100) -> bad_credentials;
error_code(16#1000) -> {unavailable_exception, 
     fun(<<Cons:?short,Required:?int,Alive:?int,_/binary>>) ->
        [   {consistency, decode_consistency(Cons)},
            {nodes_required, Required},
            {node_alive, Alive}
        ]
     end};
error_code(16#1001) -> overloaded;
error_code(16#1002) -> is_bootstrapping;
error_code(16#1003) -> truncate_error;
error_code(16#1100) -> {write_timeout,
     fun(<<Cons:?short,Received:?int,BlockFor:?int,Rest/binary>>) ->
        {WriteTypeStr, _} = consume_string(Rest),
        WriteType = case WriteTypeStr of
            <<"SIMPLE">> -> simple;
            <<"BATCH">>  -> batch;
            <<"UNLOGGED_BATCH">> -> unlogged_batch;
            <<"COUNTER">> -> counter;
            <<"BATCH_LOG">> -> batch_log
        end,
        [   {consistency, decode_consistency(Cons)},
            {nodes_acked, Received},
            {node_required, BlockFor},
            {write_type, WriteType}
        ]
     end};
error_code(16#1200) -> {read_timeout,
     fun(<<Cons:?short,Received:?int,BlockFor:?int,DataPresent:8,_/binary>>) ->
        [   {consistency, decode_consistency(Cons)},
            {nodes_acked, Received},
            {node_required, BlockFor},
            {data_present, not DataPresent == 0}
        ]
     end};
error_code(16#2000) -> syntax_error;
error_code(16#2100) -> unauthorized;
error_code(16#2200) -> invalid;
error_code(16#2300) -> config_error;
error_code(16#2400) -> {already_exists,
    fun(Bin) ->
        {Ks, R1} = consume_string(Bin),
        {Table, _} = consume_string(R1),
        [{keyspace, Ks}, {table, Table}]
    end};
error_code(16#2500) -> {unprepared,
    fun(Bin) ->
        {Id,_} = consume_short_bytes(Bin),
        [{id, Id}]
    end};
error_code(_)       -> unknown_error_code.