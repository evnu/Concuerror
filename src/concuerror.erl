%%%----------------------------------------------------------------------
%%% Copyright (c) 2012, Alkis Gotovos <el3ctrologos@hotmail.com>,
%%%                     Maria Christakis <mchrista@softlab.ntua.gr>
%%%                 and Kostis Sagonas <kostis@cs.ntua.gr>.
%%% All rights reserved.
%%%
%%% This file is distributed under the Simplified BSD License.
%%% Details can be found in the LICENSE file.
%%%----------------------------------------------------------------------
%%% Authors     : Ilias Tsitsimpis <iliastsi@hotmail.com>
%%% Description : Command Line Interface
%%%----------------------------------------------------------------------

-module(concuerror).

%% UI exports.
-export([gui/1, cli/0, analyze/1, export/2, stop/0, stop/1]).
%% Log server callback exports.
-export([init/1, terminate/2, handle_event/2]).

-export_type([options/0]).

-include("gen.hrl").

%%%----------------------------------------------------------------------
%%% Debug
%%%----------------------------------------------------------------------

%%-define(TTY, true).
-ifdef(TTY).
-define(tty(), ok).
-else.
-define(tty(), error_logger:tty(false)).
-endif.

%%%----------------------------------------------------------------------
%%% Types
%%%----------------------------------------------------------------------

-type analysis_ret() ::
      concuerror_sched:analysis_ret()
    | {'error', 'arguments', string()}.

%% Command line options
-type option() ::
      {'target',  concuerror_sched:analysis_target()}
    | {'files',   [file:filename()]}
    | {'output',  file:filename()}
    | {'include', [file:name()]}
    | {'define',  concuerror_instr:macros()}
    | {'dpor', 'full' | 'source' | 'classic'}
    | {'noprogress'}
    | {'quiet'}
    | {'preb',    concuerror_sched:bound()}
    | {'gui'}
    | {'verbose', non_neg_integer()}
    | {'keep_temp'}
    | {'show_output'}
    | {'fail_uninstrumented'}
    | {'wait_messages'}
    | {'ignore_timeout', pos_integer()}
    | {'ignore',  [module()]}
    | {'app_controller'}
    | {'help'}.

-type options() :: [option()].

%%%----------------------------------------------------------------------
%%% UI functions
%%%----------------------------------------------------------------------

%% @spec stop() -> ok
%% @doc: Stop the Concuerror analysis
-spec stop() -> ok.
stop() ->
    try ?RP_SCHED ! stop_analysis
    catch
        error:badarg ->
            init:stop()
    end,
    ok.

%% @spec stop_node([string(),...]) -> ok
%% @doc: Stop the Concuerror analysis
-spec stop([string(),...]) -> ok.
stop([Name]) ->
    %% Disable error logging messages.
    ?tty(),
    Node = list_to_atom(Name ++ ?HOST),
    case rpc:call(Node, ?MODULE, stop, []) of
        {badrpc, _Reason} ->
            %% Retry
            stop([Name]);
        _Res ->
            ok
    end.

%% @spec gui(options()) -> 'true'
%% @doc: Start the Concuerror GUI.
-spec gui(options()) -> 'true'.
gui(Options) ->
    %% Disable error logging messages.
    ?tty(),
    concuerror_gui:start(Options).

%% @spec cli() -> 'true'
%% @doc: Parse the command line arguments and start Concuerror.
-spec cli() -> 'true'.
cli() ->
    %% Disable error logging messages.
    ?tty(),
    %% First get the command line options
    Args = init:get_arguments(),
    %% There should be no plain_arguments
    case init:get_plain_arguments() of
        [PlArg|_] ->
            io:format("~s: unrecognised argument: ~s\n", [?APP_STRING, PlArg]);
        [] ->
            case parse(Args, [{'verbose', 0}]) of
                {'error', 'arguments', Msg1} ->
                    io:format("~s: ~s\n", [?APP_STRING, Msg1]);
                Opts -> cliAux(Opts)
            end
    end.

cliAux(Options) ->
    %% Initialize timer table.
    concuerror_util:timer_init(),
    %% Start the log manager.
    _ = concuerror_log:start(),
    %% Create table to save options
    ?NT_OPTIONS = ets:new(?NT_OPTIONS, [named_table, public, set]),
    ets:insert(?NT_OPTIONS, Options),
    %% Handle options
    case lists:keyfind('pa', 1, Options) of
        false -> ok;
        {'pa', PAs} -> addToCodePath(fun code:add_patha/1, PAs)
    end,
    case lists:keyfind('pz', 1, Options) of
        false -> ok;
        {'pz', PZs} -> addToCodePath(fun code:add_pathz/1, PZs)
    end,
    case lists:keyfind('gui', 1, Options) of
        {'gui'} -> gui(Options);
        false ->
            %% Attach the event handler below.
            case lists:keyfind('quiet', 1, Options) of
                false ->
                    _ = concuerror_log:attach(?MODULE, Options),
                    ok;
                {'quiet'} -> ok
            end,
            %% Run analysis
            case analyzeAux(Options) of
                {'error', 'arguments', Msg1} ->
                    io:format("~s: ~s\n", [?APP_STRING, Msg1]);
                Result ->
                    %% Set output file
                    Output =
                        case lists:keyfind(output, 1, Options) of
                            {output, O} -> O;
                            false -> ?EXPORT_FILE
                        end,
                    concuerror_log:log(0,
                        "\nWriting output to file ~s... ", [Output]),
                    case export(Result, Output) of
                        {'error', Msg2} ->
                            concuerror_log:log(0,
                                "~s\n", [file:format_error(Msg2)]);
                        ok ->
                            concuerror_log:log(0, "done\n")
                    end
            end
    end,
    %% Remove options table
    ets:delete(?NT_OPTIONS),
    %% Stop event handler
    concuerror_log:stop(),
    %% Destroy timer table.
    concuerror_util:timer_destroy(),
    'true'.

addToCodePath(_Fun, []) ->
    ok;
addToCodePath(Fun, [Path|Paths]) ->
    case Fun(Path) of
        true -> addToCodePath(Fun, Paths);
        {error, bad_directory} ->
            io:format("~s: cannot add bad_directory \"~s\" to code path\n",
                      [?APP_STRING, Path]),
            addToCodePath(Fun, Paths)
    end.

%% Parse command line arguments
parse([], Options) ->
    Options;
parse([{Opt, Param} | Args], Options) ->
    case atom_to_list(Opt) of
        T when T=:="t"; T=:="-target" ->
            case Param of
                [Module,Func|Pars] ->
                    AtomModule = erlang:list_to_atom(Module),
                    AtomFunc   = erlang:list_to_atom(Func),
                    case validateTerms(Pars, []) of
                        {'error',_,_}=Error -> Error;
                        AtomParams ->
                            Target = {AtomModule, AtomFunc, AtomParams},
                            NewOptions = lists:keystore(target, 1,
                                Options, {target, Target}),
                            parse(Args, NewOptions)
                    end;
                %% Run Eunit tests for specific module
                [Module] ->
                    AtomModule = ?REP_MOD,
                    AtomFunc   = 'rep_eunit',
                    Pars = [Module],
                    case validateTerms(Pars, []) of
                        {'error',_,_}=Error -> Error;
                        AtomParams ->
                            Target = {AtomModule, AtomFunc, AtomParams},
                            NewOptions = lists:keystore(target, 1,
                                Options, {target, Target}),
                            NewArgs = [{'D',["TEST"]} | Args],
                            parse(NewArgs, NewOptions)
                    end;
                _Other -> wrongArgument('number', Opt)
            end;

        F when F=:="f"; F=:="-files" ->
            case Param of
                [] -> wrongArgument('number', Opt);
                Files ->
                    NewOptions = keyAppend(files, 1, Options, Files),
                    parse(Args, NewOptions)
            end;

        O when O=:="o"; O=:="-output" ->
            case Param of
                [File] ->
                    NewOptions = lists:keystore(output, 1,
                        Options, {output, File}),
                    parse(Args, NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;

        "I" ->
            case Param of
                [Par] ->
                    NewOptions = keyAppend('include', 1,
                        Options, [Par]),
                    parse(Args, NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;
        "I" ++ Include ->
            case Param of
                [] -> parse([{'I', [Include]} | Args], Options);
                _Other -> wrongArgument('number', Opt)
            end;

        "D" ->
            case Param of
                [Par] ->
                    case string:tokens(Par, "=") of
                        [Name, Term] ->
                            AtomName = erlang:list_to_atom(Name),
                            case validateTerms([Term], []) of
                                {'error',_,_}=Error -> Error;
                                [AtomTerm] ->
                                    NewOptions = keyAppend('define', 1,
                                        Options, [{AtomName, AtomTerm}]),
                                    parse(Args, NewOptions)
                            end;
                        [Name] ->
                            AtomName = erlang:list_to_atom(Name),
                            case validateTerms(["true"], []) of
                                {'error',_,_}=Error -> Error;
                                [AtomTerm] ->
                                    NewOptions = keyAppend('define', 1,
                                        Options, [{AtomName, AtomTerm}]),
                                    parse(Args, NewOptions)
                            end;
                        _Other -> wrongArgument('type', Opt)
                    end;
                _Other -> wrongArgument('number', Opt)
            end;
        "D" ++ Define ->
            case Param of
                [] -> parse([{'D', [Define]} | Args], Options);
                _Other -> wrongArgument('number', Opt)
            end;

        "-noprogress" ->
            case Param of
                [] ->
                    NewOptions = lists:keystore(noprogress, 1,
                        Options, {noprogress}),
                    parse(Args, NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;

        Q when Q=:="q"; Q=:="-quiet" ->
            case Param of
                [] ->
                    NewOptions = lists:keystore(quiet, 1,
                        Options, {quiet}),
                    parse(Args, NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;

        P when P=:="p"; P=:="-preb" ->
            case Param of
                [Preb] ->
                    case string:to_integer(Preb) of
                        {I, []} when I>=0 ->
                            NewOptions = lists:keystore(preb, 1, Options,
                                {preb, I}),
                            parse(Args, NewOptions);
                        _ when Preb=:="inf"; Preb=:="off" ->
                            NewOptions = lists:keystore(preb, 1, Options,
                                {preb, inf}),
                            parse(Args, NewOptions);
                        _Other -> wrongArgument('type', Opt)
                    end;
                _Other -> wrongArgument('number', Opt)
            end;

        "-gui" ->
            case Param of
                [] ->
                    NewOptions = lists:keystore(gui, 1,
                        Options, {gui}),
                    parse(Args, NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;

        "v" ->
            case Param of
                [] ->
                    NewOptions = keyIncrease('verbose', 1, Options),
                    parse(Args, NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;

        "-keep-tmp-files" ->
            case Param of
                [] ->
                    NewOptions = lists:keystore('keep_temp', 1,
                        Options, {'keep_temp'}),
                    parse(Args, NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;

        "-fail-uninstrumented" ->
            case Param of
                [] ->
                    NewOptions = lists:keystore('fail_uninstrumented', 1,
                        Options, {'fail_uninstrumented'}),
                    parse(Args, NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;

        "-app-controller" ->
            case Param of
                [] ->
                    NewOptions = lists:keystore('app_controller', 1,
                        Options, {'app_controller'}),
                    parse(Args, NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;

        "-ignore" ->
            case Param of
                [] -> wrongArgument('number', Opt);
                Ignores ->
                    AtomIgns = [list_to_atom(Ign) || Ign <- Ignores],
                    NewOptions = keyAppend('ignore', 1, Options, AtomIgns),
                    parse(Args, NewOptions)
            end;

        "-show-output" ->
            case Param of
                [] ->
                    NewOptions = lists:keystore('show_output', 1,
                        Options, {'show_output'}),
                    %% Disable progress
                    parse([{'-noprogress', []} | Args], NewOptions);
                _Other -> wrongArgument('number', Opt)
            end;

        "-wait-messages" ->
            case Param of
                [] ->
                    NewOptions = lists:keystore('wait_messages', 1,
                        Options, {'wait_messages'}),
                    parse(Args, NewOptions);
                _Ohter -> wrongArgument('number', Opt)
            end;

        T when T =:= "T"; T =:= "-ignore-timeout" ->
            case Param of
                [Timeout] ->
                    case string:to_integer(Timeout) of
                        {Timeout_Int, []} when Timeout_Int > 0 ->
                            NewOptions = lists:keystore('ignore_timeout',
                                1, Options, {'ignore_timeout', Timeout_Int}),
                            parse(Args, NewOptions);
                        _Other -> wrongArgument('type', Opt)
                    end;
                _Other -> wrongArgument('number', Opt)
            end;

        "-help" ->
            help(),
            erlang:halt();

        DPOR when
              DPOR =:= "-dpor";
              DPOR =:= "-dpor_optimal";
              DPOR =:= "-dpor_source";
              DPOR =:= "-dpor_classic" ->
            Flavor =
                case DPOR of
                    "-dpor"         -> full;
                    "-dpor_optimal" -> full;
                    "-dpor_source"  -> source;
                    "-dpor_classic" -> classic
                end,
            case lists:keysearch(dpor, 1, Options) of
                false ->
                    NewOptions = [{dpor, Flavor}|Options],
                    parse(Args, NewOptions);
                _ ->
                    Msg = "multiple DPOR algorithms specified",
                    {'error', 'arguments', Msg}
            end;

        EF when EF=:="root"; EF=:="progname"; EF=:="home"; EF=:="smp";
            EF=:="noshell"; EF=:="noinput"; EF=:="sname"; EF=:="pa";
            EF=:="cookie" ->
                %% erl flag (ignore it)
                parse(Args, Options);

        "pa" ->
            NewOptions = keyAppend('pa', 1, Options, Param),
            parse(Args, NewOptions);

        "pz" ->
            NewOptions = keyAppend('pa', 1, Options, Param),
            parse(Args, NewOptions);

        Other ->
            Msg = io_lib:format("unrecognised concuerror flag: -~s", [Other]),
            {'error', 'arguments', Msg}
    end.


%% Validate user provided terms.
validateTerms([], Terms) ->
    lists:reverse(Terms);
validateTerms([String|Strings], Terms) ->
    case erl_scan:string(String ++ ".") of
        {ok, T, _} ->
            case erl_parse:parse_term(T) of
                {ok, Term} -> validateTerms(Strings, [Term|Terms]);
                {error, {_, _, Info}} ->
                    Msg1 = io_lib:format("arg ~s - ~s", [String, Info]),
                    {'error', 'arguments', Msg1}
            end;
        {error, {_, _, Info}, _} ->
            Msg2 = io_lib:format("info ~s", [Info]),
            {'error', 'arguments', Msg2}
    end.

keyAppend(Key, Pos, TupleList, Value) ->
    case lists:keytake(Key, Pos, TupleList) of
        {value, {Key, PrevValue}, TupleList2} ->
            [{Key, Value ++ PrevValue} | TupleList2];
        false ->
            [{Key, Value} | TupleList]
    end.

keyIncrease(Key, Pos, TupleList) ->
    case lists:keytake(Key, Pos, TupleList) of
        {value, {Key, PrevValue}, TupleList2} ->
            [{Key, PrevValue+1} | TupleList2];
        false ->
            [{Key, ?DEFAULT_VERBOSITY + 1} | TupleList]
    end.

wrongArgument('number', Option) ->
    Msg = io_lib:format("wrong number of arguments for option -~s", [Option]),
    {'error', 'arguments', Msg};
wrongArgument('type', Option) ->
    Msg = io_lib:format("wrong type of argument for option -~s", [Option]),
    {'error', 'arguments', Msg}.

help() ->
    io:format(
     ?INFO_MSG
     "\n"
     "usage: concuerror [<args>]\n"
     "Arguments:\n"
     "  -t|--target module      Run eunit tests for this module\n"
     "  -t|--target module function [args]\n"
     "                          Specify the function to execute\n"
     "  -f|--files  modules     Specify the files (modules) to instrument (quoted wildcards allowed)\n"
     "  -pa         Dir         Add Dir to the beginning of the code path\n"
     "  -pz         Dir         Add Dir to the end of the code path\n"
     "  -o|--output file        Specify the output file (default results.txt)\n"
     "  -p|--preb   number|inf  Set preemption bound (default is 2)\n"
     "  -I          include_dir Pass the include_dir to concuerror\n"
     "  -D          name=value  Define a macro\n"
     "  --noprogress            Disable progress bar\n"
     "  -q|--quiet              Disable logging (implies --noprogress)\n"
     "  -v                      Verbose [use twice to be more verbose]\n"
     "  --keep-tmp-files        Retain all intermediate temporary files\n"
     "  --fail-uninstrumented   Fail if there are uninstrumented modules\n"
     "  --ignore    modules     It is OK for these modules to be uninstrumented\n"
     "  --show-output           Allow program under test to print to stdout\n"
     "  --wait-messages         Wait for uninstrumented messages to arrive\n"
     "  --app-controller        Start an (instrumented) application controller\n"
     "  -T|--ignore-timeout bound\n"
     "                          Treat big after Timeouts as infinity timeouts\n"
     "  --gui                   Run concuerror with a graphical interface\n"
     "  --help                  Show this help message\n"
     "\n"
     " DPOR algorithms:\n"
     "  --dpor|--dpor_optimal   Enables the optimal DPOR algorithm\n"
     "  --dpor_classic          Enables the classic DPOR algorithm\n"
     "  --dpor_source           Enables the DPOR algorithm based on source sets\n"
     "\n"
     "Examples:\n"
     "  concuerror -DVSN=\\\"1.0\\\" --target foo bar arg1 arg2 "
        "--files \"foo.erl\" -o out.txt\n"
     "  concuerror --gui -I./include --files foo.erl --preb inf\n\n").


%%%----------------------------------------------------------------------
%%% Analyze Command
%%%----------------------------------------------------------------------

%% @spec analyze(options()) -> analysis_ret()
%% @doc: Run Concuerror analysis with the given options.
-spec analyze(options()) -> analysis_ret().
analyze(Options) ->
    %% Disable error logging messages.
    ?tty(),
    %% Start the log manager.
    _ = concuerror_log:start(),
    Res = analyzeAux(Options),
    %% Stop event handler
    concuerror_log:stop(),
    Res.

analyzeAux(Options) ->
    %% Get target
    Result =
        case lists:keyfind(target, 1, Options) of
            false ->
                Msg1 = "no target specified",
                {'error', 'arguments', Msg1};
            {target, Target} ->
                %% Get input files
                case lists:keyfind(files, 1, Options) of
                    false ->
                        Msg2 = "no input files specified",
                        {'error', 'arguments', Msg2};
                    {files, Files} ->
                        %% Retrieve file paths
                        Files1 = concuerror_util:wildcards_to_filenames(Files),
                        %% Start the analysis
                        concuerror_sched:analyze(Target, Files1, Options)
                end
        end,
    %% Return result
    Result.


%%%----------------------------------------------------------------------
%%% Export Analysis results into a file
%%%----------------------------------------------------------------------

%% @spec export(concuerror_sched:analysis_ret(), file:filename()) ->
%%              'ok' | {'error', file:posix() | badarg | system_limit}
%% @doc: Export the analysis results into a text file.
-spec export(concuerror_sched:analysis_ret(), file:filename()) ->
    'ok' | {'error', file:posix() | badarg | system_limit | terminated}.
export(Results, File) ->
    case file:open(File, ['write']) of
        {ok, IoDevice} ->
            case exportAux(Results, IoDevice) of
                ok -> file:close(IoDevice);
                Error -> Error
            end;
        Error -> Error
    end.

exportAux({'ok', {_Target, RunCount, SBlocked}}, IoDevice) ->
    Msg = io_lib:format("Checked ~w interleaving(s). No errors found.\n",
        [RunCount]),
    SBMsg =
        case SBlocked of
            0 -> "";
            _ -> io_lib:format("  Encountered ~w sleep-set blocked trace(s).\n",
                    [SBlocked])
        end,
    file:write(IoDevice, Msg++SBMsg);
exportAux({error, instr,
        {_Target, _RunCount, _SBlocked}}, IoDevice) ->
    Msg = "Instrumentation error.\n",
    file:write(IoDevice, Msg);
exportAux({error, analysis,
        {_Target, RunCount, SBlocked}, Tickets}, IoDevice) ->
    TickLen = length(Tickets),
    Msg = io_lib:format("Checked ~w interleaving(s). ~w errors found.\n",
        [RunCount, TickLen]),
    SBMsg =
        case SBlocked of
            0 -> "\n";
            _ -> io_lib:format(
                    "  Encountered ~w sleep-set blocked trace(s).\n\n",
                    [SBlocked])
        end,
    case file:write(IoDevice, Msg++SBMsg) of
        ok ->
            case lists:foldl(fun writeDetails/2, {1, IoDevice},
                             concuerror_ticket:sort(Tickets)) of
                {'error', _Reason}=Error -> Error;
                _Ok -> ok
            end;
        Error -> Error
    end.

%% Write details about each ticket
writeDetails(_Ticket, {'error', _Reason}=Error) ->
    Error;
writeDetails(Ticket, {Count, IoDevice}) ->
    Error = concuerror_ticket:get_error(Ticket),
    Description = io_lib:format("~p\n~s\n",
        [Count, concuerror_error:long(Error)]),
    Details = ["  " ++ M ++ "\n"
            || M <- concuerror_ticket:details_to_strings(Ticket)],
    Msg = lists:flatten([Description | Details]),
    case file:write(IoDevice, Msg ++ "\n\n") of
        ok -> {Count+1, IoDevice};
        WriteError -> WriteError
    end.


%%%----------------------------------------------------------------------
%%% Log event handler callback functions
%%%----------------------------------------------------------------------

-type state() :: {non_neg_integer(), %% Verbose level
                  concuerror_util:progress() | 'noprogress'}.

-spec init(term()) -> {'ok', state()}.

%% @doc: Initialize the event handler.
init(Options) ->
    Progress =
        case lists:keyfind(noprogress, 1, Options) of
            {noprogress} -> noprogress;
            false -> concuerror_util:init_state()
        end,
    Verbosity =
        case lists:keyfind('verbose', 1, Options) of
            {'verbose', V} -> V;
            false -> 0
        end,
    {ok, {Verbosity, Progress}}.

-spec terminate(term(), state()) -> 'ok'.
terminate(_Reason, {_Verb, 'noprogress'}) ->
    ok;
terminate(_Reason, {_Verb, {_RunCnt, _Errors, _Elapsed, Timer}}) ->
    concuerror_util:timer_stop(Timer),
    ok.

-spec handle_event(concuerror_log:event(), state()) -> {'ok', state()}.
handle_event({msg, String, MsgVerb}, {Verb, _Progress}=State) ->
    if
        Verb >= MsgVerb ->
            io:format("~s", [String]);
        true ->
            ok
    end,
    {ok, State};

handle_event({progress, _Type}, {_Verb, 'noprogress'}=State) ->
    {ok, State};
handle_event({progress, Type}, {Verb, Progress}) ->
    case concuerror_util:progress_bar(Type, Progress) of
        {NewProgress, ""} ->
            {ok, {Verb, NewProgress}};
        {NewProgress, Msg} ->
            io:fwrite("\r\033[K" ++ Msg),
            {ok, {Verb, NewProgress}}
    end;

handle_event('reset', {_Verb, 'noprogress'}=State) ->
    {ok, State};
handle_event('reset', {Verb, _Progress}) ->
    {ok, {Verb, concuerror_util:init_state()}}.
