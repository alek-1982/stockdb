%%% @doc StockDB iterator module
%%% It accepts stockdb state and operates only with its buffer

-module(stockdb_iterator).
-author({"Danil Zagoskin", z@gosk.in}).

-include("log.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("stockdb.hrl").

% Create new iterator from stockdb state
-export([init/1]).

% Access buffer
-export([seek_utc/2, pop_event/1]).

% Restore last state
-export([restore_last_state/1]).

-record(iterator, {
    dbstate,
    buffer,
    data_start,
    position
  }).

%% @doc Initialize iterator. Position at the very beginning of data
init(#dbstate{} = DBState) ->
  DataStart = first_chunk_offset(DBState),
  {ok, #iterator{
      dbstate = DBState,
      data_start = DataStart,
      position = DataStart}}.

%% @doc replay last chunk and return finl state
restore_last_state(Iterator) ->
  #iterator{dbstate = LastState} = seek_utc(eof, Iterator),
  % Drop buffer to free memory
  LastState#dbstate{buffer = undefined}.


%% @doc get start of first chunk
first_chunk_offset(#dbstate{chunk_map = []} = _DBstate) ->
  % Empty chunk map -> offset undefined
  undefined;
first_chunk_offset(#dbstate{chunk_map = [{_N, _T, Offset}|_Rest]} = _DBstate) ->
  % Just return offset from first chunk
  Offset.

%% @doc Set position to given time
seek_utc(UTC, #iterator{data_start = DataStart, dbstate = #dbstate{chunk_map = ChunkMap}} = Iterator) ->
  ChunksBefore = case UTC of
    undefined -> [];
    eof -> ChunkMap;
    Int when is_integer(Int) -> lists:takewhile(fun({_N, T, _O}) -> T =< UTC end, ChunkMap)
  end,
  {_N, _T, ChunkOffset} = case ChunksBefore of
    [] -> {-1, -1, DataStart};
    [_|_] -> lists:last(ChunksBefore)
  end,
  seek_until(UTC, Iterator#iterator{position = ChunkOffset}).

%% @doc Seek forward event-by-event while timestamp is less than given
seek_until(undefined, Iterator) ->
  Iterator;
seek_until(UTC, #iterator{} = Iterator) ->
  case pop_event(Iterator) of
    {eof, NextIterator} ->
      % EOF. Just return what we have
      NextIterator;
    {Event, NextIterator} when is_integer(UTC) ->
      case packet_timestamp(Event) of
        Before when Before < UTC ->
          % Drop more
          seek_until(UTC, NextIterator);
        _After ->
          % Revert to state before getting event
          Iterator
      end;
    {_, NextIterator} when UTC == eof ->
      seek_until(UTC, NextIterator)
  end.

%% @doc Pop first event from iterator, return {Event|eof, NewIterator}
pop_event(#iterator{dbstate = #dbstate{buffer = FullBuffer} = DBState, position = Pos} = Iterator) ->
  <<_:Pos/binary, Buffer/binary>> = FullBuffer,
  {Event, ReadBytes, NewDBState} = case Buffer of
    <<>> -> {eof, 0, DBState};
    _Other -> get_first_packet(Buffer, DBState)
  end,
  {Event, Iterator#iterator{dbstate = NewDBState, position = Pos + ReadBytes}}.


%% @doc get first event from buffer when State is db state at the beginning of it
get_first_packet(Buffer, #dbstate{depth = Depth, last_bidask = LastBidAsk, last_timestamp = LastTimestamp, scale = Scale} = State) ->
  case stockdb_format:packet_type(Buffer) of
    full_md ->
      {Timestamp, BidAsk, Tail} = stockdb_format:decode_full_md(Buffer, Depth),

      {packet_from_mdentry(Timestamp, BidAsk, State), erlang:byte_size(Buffer) - erlang:byte_size(Tail),
        State#dbstate{last_timestamp = Timestamp, last_bidask = BidAsk}};
    delta_md ->
      {DTimestamp, DBidAsk, Tail} = stockdb_format:decode_delta_md(Buffer, Depth),
      BidAsk = bidask_delta_apply(LastBidAsk, DBidAsk),
      Timestamp = LastTimestamp + DTimestamp,

      {packet_from_mdentry(Timestamp, BidAsk, State), erlang:byte_size(Buffer) - erlang:byte_size(Tail),
        State#dbstate{last_timestamp = Timestamp, last_bidask = BidAsk}};
    trade ->
      {Timestamp, Price, Volume, Tail} = stockdb_format:decode_trade(Buffer),
      {{trade, Timestamp, Price/Scale, Volume}, erlang:byte_size(Buffer) - erlang:byte_size(Tail),
        State#dbstate{last_timestamp = Timestamp}}
  end.

% Foldl: low-memory fold over entries
foldl(Fun, Acc0, FileName) ->
  foldl_range(Fun, Acc0, FileName, {undefined, undefined}).

% foldl_range: fold over entries in specified time range
foldl_range(Fun, Acc0, FileName, {Start, End}) ->
  {ok, State0} = stockdb_reader:open(FileName),
  State1 = seek_utc(Start, State0),
  _FoldResult = case End of
    undefined ->
      do_foldl_full(Fun, Acc0, State1);
    _ ->
      do_foldl_until(Fun, Acc0, State1, End)
  end.

do_foldl_full(Fun, AccIn, Iterator) ->
  {Event, NextIterator} = pop_event(Iterator),
  case Event of
    eof ->
      % Finish folding -- no more events
      AccIn;
    _event ->
      % Iterate
      AccOut = Fun(Event, AccIn),
      do_foldl_full(Fun, AccOut, NextIterator)
  end.

do_foldl_until(Fun, AccIn, Iterator, End) ->
  {Event, NextIterator} = pop_event(Iterator),
  case Event of
    eof ->
      % Finish folding -- no more events
      AccIn;
    _event ->
      case packet_timestamp(Event) of
        Large when Large > End ->
          % end of given interval
          AccIn;
        _small ->
          % Iterate
          AccOut = Fun(Event, AccIn),
          do_foldl_until(Fun, AccOut, NextIterator, End)
      end
  end.


bidask_delta_apply([[_|_] = Bid1, [_|_] = Ask1], [[_|_] = Bid2, [_|_] = Ask2]) ->
  [bidask_delta_apply1(Bid1, Bid2), bidask_delta_apply1(Ask1, Ask2)].

bidask_delta_apply1(List1, List2) ->
  lists:zipwith(fun({Price, Volume}, {DPrice, DVolume}) ->
    {Price + DPrice, Volume + DVolume}
  end, List1, List2).


split_bidask([Bid, Ask], _Depth) ->
  {Bid, Ask}.

packet_from_mdentry(Timestamp, BidAsk, #dbstate{depth = Depth, scale = Scale}) ->
  {Bid, Ask} = split_bidask(BidAsk, Depth),
  SBid = if is_number(Scale) -> apply_scale(Bid, 1/Scale); true -> Bid end,
  SAsk = if is_number(Scale) -> apply_scale(Ask, 1/Scale); true -> Ask end,
  {md, Timestamp, SBid, SAsk}.

apply_scale(PVList, Scale) when is_float(Scale) ->
  lists:map(fun({Price, Volume}) ->
        {Price * Scale, Volume}
    end, PVList).



packet_timestamp({md, Timestamp, _Bid, _Ask}) -> Timestamp;
packet_timestamp({trade, Timestamp, _Price, _Volume}) -> Timestamp.
