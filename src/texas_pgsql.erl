-module(texas_pgsql).
-behaviour(texas_adapter).
-compile([{parse_transform, lager_transform}]).

-export([start/0]).
-export([connect/6, exec/2, close/1]).
-export([create_table/2, create_table/3, drop_table/2]).
-export([insert/3, select/4, count/3, update/4, delete/3]).
-export([string_separator/0, string_quote/0, field_separator/0]).
-export([where_null/2, set_null/1]).

-define(STRING_SEPARATOR, $').
-define(STRING_QUOTE, $').
-define(FIELD_SEPARATOR, none).

string_separator() -> ?STRING_SEPARATOR.
string_quote()     -> ?STRING_QUOTE.
field_separator()  -> ?FIELD_SEPARATOR.
where_null("=", Key)  -> io_lib:format("~s IS NULL", [texas_sql:sql_field(Key, ?MODULE)]);
where_null(_, Key)  -> io_lib:format("~s IS NOT NULL", [texas_sql:sql_field(Key, ?MODULE)]).
set_null(Key)  -> io_lib:format("~s = NULL", [texas_sql:sql_field(Key, ?MODULE)]).

-spec start() -> ok.
start() ->
  ok.

-spec connect(string(), string(), string(), integer(), string(), any()) ->
  {ok, texas_adapter:connection()} | {error, texas_adapter:connection_error()}.
connect(User, Password, Server, Port, Database, _Options) ->
  lager:debug("Open database pgsql://~p:~p@~p:~p/~p", [User, Password, Server, Port, Database]),
  epgsql:connect(Server, User, Password, [{database, Database}, {port, list_to_integer(Port)}]).

-spec close(texas_adapter:connection()) -> ok | error.
close(Conn) ->
  epgsql:close(texas:connection(Conn)).

-spec create_table(texas_adapter:connection(), texas_adapter:tablename()) -> ok | error.
create_table(Conn, Table) ->
  SQLCmd = sql(
    create_table,
    atom_to_list(Table),
    lists:map(fun(Field) ->
            sql(
              column_def,
              atom_to_list(Field),
              Table:'-type'(Field),
              Table:'-len'(Field),
              Table:'-autoincrement'(Field),
              Table:'-not_null'(Field),
              Table:'-unique'(Field),
              Table:'-default'(Field))
        end, Table:'-fields'())),
  case exec(SQLCmd, Conn) of
    {ok, _, _} -> ok;
    _ -> error
  end.

-spec create_table(texas_adapter:connection(), texas_adapter:tablename(), list()) -> ok | error.
create_table(Conn, Table, Fields) ->
  SQLCmd = sql(
    create_table,
    atom_to_list(Table),
    lists:map(fun({Field, Options}) ->
            sql(
              column_def,
              atom_to_list(Field),
              texas_sql:get_option(type, Options),
              texas_sql:get_option(len, Options),
              texas_sql:get_option(autoincrement, Options),
              texas_sql:get_option(not_null, Options),
              texas_sql:get_option(unique, Options),
              texas_sql:get_option(default, Options))
        end, Fields)),
  case exec(SQLCmd, Conn) of
    {ok, _, _} -> ok;
    _ -> error
  end.

-spec drop_table(texas_adapter:connection(), texas_adapter:tablename()) -> ok | error.
drop_table(Conn, Table) ->
  SQLCmd = "DROP TABLE IF EXISTS " ++ atom_to_list(Table),
  case exec(SQLCmd, Conn) of
    {ok, _, _} -> ok;
    _ -> error
  end.

-spec insert(texas_adapter:connection(), texas_adapter:tablename(), texas_adapter:data()) -> texas_adapter:data() | {error, texas_adapter:request_error()}.
insert(Conn, Table, Record) ->
  SQLCmd = "INSERT INTO " ++
           texas_sql:sql_field(Table, ?MODULE) ++
           texas_sql:insert_clause(Record, ?MODULE) ++
           case texas_sql:defined_table(Table) of
             true ->
               case Table:'-table_pk_id'() of
                 {ok, PkID} -> " RETURNING " ++ atom_to_list(PkID);
                 _ -> ""
               end;
             _ -> ""
           end,
  case exec(SQLCmd, Conn) of
    {ok, 1, [{column, Col, _, _, _, _}],[{ID}]} ->
      case texas_sql:defined_table(Table) of
        true ->
          ACol = binary_to_atom(Col, utf8),
          select(Conn, Table, first, [{where, [{ACol, texas_type:to(Table:'-type'(ACol), ID)}]}]);
        false -> ok
      end;
    {error, Error} -> {error, Error};
    _ ->
      Record
  end.

-spec select(texas_adapter:connection(), texas_adapter:tablename(), first | all | integer() | {integer(), integer()}, texas_adapter:clauses()) ->
  texas_adapter:data() | [texas_adapter:data()] | [] | {error, texas_adapter:request_error()}.
select(Conn, Table, Type, Clauses) ->
  SQLCmd = "SELECT * FROM " ++
           texas_sql:sql_field(Table, ?MODULE) ++
           texas_sql:where_clause(texas_sql:clause(where, Clauses), ?MODULE) ++
           case Type of
             first ->
               " LIMIT 1";
             Type when is_integer(Type) ->
               lists:flatten(io_lib:format(" LIMIT ~p", [Type]));
             {Limit, Offset} ->
               lists:flatten(io_lib:format(" LIMIT ~p OFFSET ~p", [Limit, Offset]));
             _ ->
               ""
           end,
           % TODO : add GROUP BY, ORDER BY, LIMIT
  case exec(SQLCmd, Conn) of
    {ok, _, []} -> [];
    {ok, Cols, Datas} ->
      ColsList = lists:map(fun({column, Col, _, _, _, _}) -> binary_to_atom(Col, utf8) end, Cols),
      case Type of
        first ->
          [Data|_] = Datas,
          case texas_sql:defined_table(Table) of
            true -> Table:new(Conn, assoc(Table, ColsList, Data));
            _ -> assoc(ColsList, Data)
          end;
        _ ->
          lists:map(fun(Data) ->
                case texas_sql:defined_table(Table) of
                  true -> Table:new(Conn, assoc(Table, ColsList, Data));
                  _ -> assoc(ColsList, Data)
                end
            end, Datas)
      end;
    E -> E
  end.

-spec count(texas_adapter:connection(), texas_adapter:tablename(), texas_adapter:clauses()) -> integer().
count(Conn, Table, Clauses) ->
  SQLCmd = "SELECT COUNT(*) FROM " ++
           texas_sql:sql_field(Table, ?MODULE) ++
           texas_sql:where_clause(texas_sql:clause(where, Clauses), ?MODULE),
  case exec(SQLCmd, Conn) of
    {ok, _, [{N}]} ->
      bucs:to_integer(N);
    _ -> 0
  end.

-spec update(texas_adapter:connection(), texas_adapter:tablename(), texas_adapter:data(), [tuple()]) -> [texas_adapter:data()] | {error, texas_adapter:request_error()}.
update(Conn, Table, Record, UpdateData) ->
  SQLCmd = "UPDATE " ++
           texas_sql:sql_field(Table, ?MODULE) ++
           texas_sql:set_clause(UpdateData, ?MODULE) ++
           where_for_update(Record),
  case exec(SQLCmd, Conn) of
    {ok, _} ->
      UpdateRecord = lists:foldl(fun({Field, Value}, Rec) ->
              Rec:Field(Value)
          end, Record, UpdateData),
      WhereClause = case UpdateRecord:id() of
                      undefined -> UpdateRecord;
                      _ -> [{id, UpdateRecord:id()}]
                    end,
      select(Conn, Table, all, [{where, WhereClause}]);
    E -> E
  end.

-spec delete(texas_adapter:connection(), texas_adapter:tablename(), texas_adapter:data()) -> ok | {error, texas_adapter:request_error()}.
delete(Conn, Table, Record) ->
  SQLCmd = "DELETE FROM " ++
           texas_sql:sql_field(Table, ?MODULE) ++
           where_for_update(Record),
  case exec(SQLCmd, Conn) of
    {ok, _} -> ok;
    E -> E
  end.

% Private --

exec(SQL, Conn) ->
  lager:debug("==> ~p", [SQL]),
  epgsql:squery(texas:connection(Conn), SQL).

assoc(Table, Cols, Datas) ->
  lists:map(fun({Col, Data}) ->
        case Data of
          null -> {Col, undefined};
          _ -> {Col, texas_type:to(Table:'-type'(Col), Data)}
        end
    end, lists:zip(Cols, tuple_to_list(Datas))).

assoc(Cols, Datas) ->
  lists:map(fun({Col, Data}) ->
        case Data of
          null -> {Col, undefined};
          _ -> {Col, Data}
        end
    end, lists:zip(Cols, tuple_to_list(Datas))).

sql(create_table, Name, ColDefs) ->
  "CREATE TABLE IF NOT EXISTS " ++ Name ++ " (" ++ string:join(ColDefs, ", ") ++ ");";
sql(default, date, {ok, now}) -> " DEFAULT CURRENT_DATE";
sql(default, time, {ok, now}) -> " DEFAULT CURRENT_TIME";
sql(default, datetime, {ok, now}) -> " DEFAULT CURRENT_TIMESTAMP";
sql(default, _, {ok, Value}) -> io_lib:format(" DEFAULT ~s", [texas_sql:sql_string(Value, ?MODULE)]);
sql(default, _, _) -> "".
sql(type, id, {ok, true}, _) -> " BIGSERIAL PRIMARY KEY";
sql(type, id, _, _) -> " BIGINT";
sql(type, integer, {ok, true}, _) -> " BIGSERIAL PRIMARY KEY";
sql(type, integer, _, _) -> " BIGINT";
sql(type, string, _, {ok, Len}) -> " VARCHAR(" ++ integer_to_list(Len) ++ ")";
sql(type, string, _, _) -> " TEXT";
sql(type, float, _, _) -> " REAL";
sql(type, date, _, _) -> " DATE";
sql(type, time, _, _) -> " TIME";
sql(type, datetime, _, _) -> " TIMESTAMP(0)";
sql(type, _, _, _) -> " TEXT".
sql(column_def, Name, Type, Len, Autoincrement, NotNull, Unique, Default) ->
  Name ++
  sql(type, Type, Autoincrement, Len) ++
  sql(notnull, NotNull) ++
  sql(unique, Unique) ++
  sql(default, Type, Default).
sql(notnull, {ok, true}) -> " NOT NULL";
sql(unique, {ok, true}) -> " UNIQUE";
sql(_, _) -> "".

where_for_update(Record) ->
  case Record:id() of
    undefined -> texas_sql:where_clause(Record, ?MODULE);
    _ -> texas_sql:where_clause(texas_sql:clause(where, [{where, [{id, Record:id()}]}]), ?MODULE)
  end.

