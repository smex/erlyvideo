% Media entry is instance of some resource

-module(file_media).
-author('Max Lapshin <max@maxidoors.ru>').
-include("../include/ems.hrl").
-include("../../include/media_info.hrl").
-include_lib("erlmedia/include/video_frame.hrl").

-behaviour(gen_server).

%% External API
-export([start_link/3, read_frame/2, name/1, seek/3, metadata/1]).
-export([file_dir/1, file_format/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).


start_link(Path, Type, Opts) ->
   gen_server:start_link(?MODULE, [Path, Type, Opts], []).


read_frame(MediaEntry, Key) ->
  Ref = erlang:make_ref(),
  MediaEntry ! {'$gen_call', {self(), Ref}, {read, Key}},
  erlang:yield(),
  receive
    {Ref, Frame} -> Frame;
    {'DOWN', _Ref, process, MediaEntry, _Reason} -> erlang:error(mediaentry_died)
  after
    1000 -> erlang:error(timeout_read_frame)
  end.
  % gen_server:call(MediaEntry, {read, Key}).

name(Server) ->
  gen_server:call(Server, name).

seek(Server, BeforeAfter, Timestamp) when BeforeAfter == before orelse BeforeAfter == 'after' ->
  gen_server:call(Server, {seek, BeforeAfter, Timestamp}).

metadata(Server) ->
  gen_server:call(Server, metadata).


init([Name, file, Opts]) ->
  Clients = ets:new(clients, [set, private]),
  Host = proplists:get_value(host, Opts),
  LifeTimeout = proplists:get_value(life_timeout, Opts, ?FILE_CACHE_TIME),
  {ok, Info} = open_file(Name, Host),
  ?D({"Opened file", Name}),
  {ok, Info#media_info{clients = Clients, type = file, host = Host, life_timeout = LifeTimeout}, LifeTimeout}.




%%-------------------------------------------------------------------------
%% @spec (Request, From, State) -> {reply, Reply, State}          |
%%                                 {reply, Reply, State, Timeout} |
%%                                 {noreply, State}               |
%%                                 {noreply, State, Timeout}      |
%%                                 {stop, Reason, Reply, State}   |
%%                                 {stop, Reason, State}
%% @doc Callback for synchronous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------

handle_call(info, _From, #media_info{duration = Duration, width = W, height = H, life_timeout = LifeTimeout} = MediaInfo) ->
  {reply, [{length,Duration},{type,file},{start,0},{width,W},{height,H}], MediaInfo, LifeTimeout};
  
handle_call({unsubscribe, _Client}, _From, #media_info{life_timeout = LifeTimeout} = MediaInfo) ->
  {reply, ok, MediaInfo, LifeTimeout};
  
handle_call({subscribe, _Client}, _From, #media_info{life_timeout = LifeTimeout} = MediaInfo) ->
  {reply, {ok, file}, MediaInfo, LifeTimeout};

handle_call(clients, _From, #media_info{life_timeout = LifeTimeout} = MediaInfo) ->
  {reply, [], MediaInfo, LifeTimeout};

handle_call(name, _From, #media_info{name = FileName, life_timeout = LifeTimeout} = MediaInfo) ->
  {reply, FileName, MediaInfo, LifeTimeout};
  
handle_call({seek, BeforeAfter, Timestamp}, _From, #media_info{format = Format, life_timeout = LifeTimeout} = MediaInfo) ->
  {reply, Format:seek(MediaInfo, BeforeAfter, Timestamp), MediaInfo, LifeTimeout};


handle_call({read, done}, _From, #media_info{life_timeout = LifeTimeout} = MediaInfo) ->
  {reply, done, MediaInfo, LifeTimeout};

handle_call({read, undefined}, From, #media_info{format = Format} = MediaInfo) ->
  handle_call({read, Format:first(MediaInfo)}, From, MediaInfo);

handle_call({read, Key}, _From, #media_info{format = FileFormat, life_timeout = LifeTimeout} = MediaInfo) ->
  {reply, FileFormat:read_frame(MediaInfo, Key), MediaInfo, LifeTimeout};


handle_call(metadata, _From, #media_info{format = Format, life_timeout = LifeTimeout} = MediaInfo) ->
  case Format:properties(MediaInfo) of
    undefined ->
      {reply, undefined, MediaInfo, LifeTimeout};
    Metadata ->   
      {reply, {object, Metadata}, MediaInfo, LifeTimeout}
  end;

handle_call(Request, _From, State) ->
  ?D({"Undefined call", Request, _From}),
  {stop, {unknown_call, Request}, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for asyncrous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_cast(_Msg, #media_info{life_timeout = LifeTimeout} = State) ->
  ?D({"Undefined cast", _Msg}),
  {noreply, State, LifeTimeout}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for messages sent directly to server's mailbox.
%%      If `{stop, ...}' tuple is returned, the server is stopped and
%%      `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------

handle_info(timeout, State) ->
  {stop, normal, State};

handle_info(_Info, #media_info{life_timeout = LifeTimeout} = State) ->
  ?D({"Undefined info", _Info}),
  {noreply, State, LifeTimeout}.

%%-------------------------------------------------------------------------
%% @spec (Reason, State) -> any
%% @doc  Callback executed on server shutdown. It is only invoked if
%%       `process_flag(trap_exit, true)' is set by the server process.
%%       The return value is ignored.
%% @end
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, #media_info{device = Device, host = Host, name = URL} = _MediaInfo) ->
  (catch file:close(Device)),
  ems_event:stream_stopped(Host, URL, self()),
  ok.

%%-------------------------------------------------------------------------
%% @spec (OldVsn, State, Extra) -> {ok, NewState}
%% @doc  Convert process state when code is changed.
%% @end
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

open_file(Name, Host) when is_binary(Name) ->
  open_file(binary_to_list(Name), Host);
  
open_file(Name, Host) ->
  FileName = filename:join([file_media:file_dir(Host), Name]), 
	{ok, Device} = file:open(FileName, [read, binary, {read_ahead, 100000}, raw]),
	FileFormat = file_media:file_format(FileName),
	MediaInfo = #media_info{
	  device = Device,
	  name = FileName,
    format = FileFormat
	},
	case FileFormat:init(MediaInfo) of
		{ok, MediaInfo1} -> 
		  {ok, MediaInfo1};
    _HdrError -> 
		  ?D(_HdrError),
		  {error, _HdrError}
	end.




%%-------------------------------------------------------------------------
%% @spec (Host) -> FileName::string()
%% @doc retrieves video file folder from application environment
%% @end
%%-------------------------------------------------------------------------	
file_dir(Host) ->
  ems:get_var(file_dir, Host, undefined).



file_format(Name) ->
  Readers = ems:get_var(file_formats, [mp4_reader, flv_reader]),
  file_format(Name, Readers).

file_format(Name, []) ->
  undefined;
  
file_format(Name, [Reader|Readers]) ->
  case Reader:can_open_file(Name) of
    true -> Reader;
    false -> file_format(Name, Readers)
  end.
