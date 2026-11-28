-module(workspace_scan_probe).
-export([run/0, open/2, next/2, close/1, gate_waiting/0, release_gate/0]).

open(_, _) -> erlang:nif_error(not_loaded).
next(_, _) -> erlang:nif_error(not_loaded).
close(_) -> erlang:nif_error(not_loaded).
gate_waiting() -> erlang:nif_error(not_loaded).
release_gate() -> erlang:nif_error(not_loaded).

run() ->
    ok = erlang:load_nif(os:getenv("SCAN_NIF"), 0),
    Root = os:getenv("SCAN_FIXTURE"),
    Wide = filename:join(Root, "wide"),
    Other = filename:join(Root, "other"),
    Store = filename:join(Root, "store"),
    Gated = filename:join(Root, "gated"),
    Width = 20000,
    ok = file:make_dir(Wide),
    ok = file:make_dir(Other),
    ok = file:make_dir(Gated),
    ok = file:make_dir(filename:join(Other, "projects")),
    ok = file:make_dir(filename:join(Gated, "grant-visible")),
    ok = file:write_file(filename:join(Other, "ordinary-file"), <<>>),
    ok = file:make_symlink("projects", filename:join(Other, "project-link")),
    ok = file:write_file(Store, <<"alive">>),
    lists:foreach(fun(I) ->
        Path = filename:join(Wide, integer_to_list(I)),
        case I rem 4 of
            0 -> ok = file:make_dir(Path);
            _ -> ok = file:write_file(Path, <<>>)
        end
    end, lists:seq(1, Width)),
    io:format("~p OTP ~s, ~p dirty I/O schedulers, ~p entries~n",
              [os:type(), erlang:system_info(otp_release),
               erlang:system_info(dirty_io_schedulers), Width]),
    wide_scan(Wide, Width),
    stalled_scan(Gated, Other, Store),
    io:format("All probe assertions passed.~n").

wide_scan(Wide, Width) ->
    {ListingUs, {ok, Names}} = timer:tc(fun() -> prim_file:list_dir(Wide) end),
    Width = length(Names),
    {BaselineUs, Dirs} = timer:tc(fun() ->
        [Name || Name <- lists:sort(Names), is_dir(Wide, Name)]
    end),
    5000 = length(Dirs),
    {ShortPageUs, Page} = timer:tc(fun() -> first_dirs(Wide, lists:sort(Names), 33, []) end),
    Page = lists:sublist(Dirs, 33),
    {FirstUs, {Cursor, First}} = timer:tc(fun() ->
        {ok, C} = open(list_to_binary(Wide), normal),
        {ok, Rows, more} = next(C, 128),
        {C, Rows}
    end),
    true = length(First) > 0 andalso length(First) =< 128,
    {RestUs, Rest} = timer:tc(fun() -> collect(Cursor, []) end),
    ok = close(Cursor),
    {error, closed} = next(Cursor, 128),
    Width = length(First) + length(Rest),
    true = lists:sort([Name || {Name, _} <- First ++ Rest]) =:=
        lists:sort([list_to_binary(Name) || Name <- Names]),
    io:format("wide: OTP enumerate ~B us; sort + stat all ~B us; "
              "sort + stat to 33 directory matches ~B us; "
              "NIF open + first ~B names ~B us; NIF remaining names ~B us~n",
              [ListingUs, BaselineUs, ShortPageUs, length(First), FirstUs, RestUs]).

is_dir(Wide, Name) ->
    filelib:is_dir(filename:join(Wide, Name), prim_file).

first_dirs(_, _, 0, Acc) -> lists:reverse(Acc);
first_dirs(_, [], _, Acc) -> lists:reverse(Acc);
first_dirs(Wide, [Name | Names], Limit, Acc) ->
    case is_dir(Wide, Name) of
        true -> first_dirs(Wide, Names, Limit - 1, [Name | Acc]);
        false -> first_dirs(Wide, Names, Limit, Acc)
    end.

collect(Cursor, Acc) ->
    case next(Cursor, 128) of
        {ok, Rows, more} -> collect(Cursor, lists:reverse(Rows, Acc));
        {ok, Rows, eof} -> lists:reverse(Rows, Acc)
    end.

stalled_scan(Gated, Other, Store) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        {ok, Cursor} = open(list_to_binary(Gated), gated),
        try Parent ! {Ref, collect(Cursor, [])}
        after ok = close(Cursor) end
    end),
    try
        await_gate(erlang:monotonic_time(millisecond) + 2000),
        % Simulate a caller that stops waiting. The worker must still occupy a slot.
        receive {Ref, _} -> error(published_before_grant) after 30 -> ok end,
        true = erlang:is_process_alive(Pid),
        {Us, ok} = timer:tc(fun() ->
            {ok, <<"alive">>} = file:read_file(Store),
            {ok, Cursor} = open(list_to_binary(Other), normal),
            try
                [{<<"ordinary-file">>, regular}, {<<"project-link">>, symlink},
                 {<<"projects">>, directory}] = lists:sort(collect(Cursor, []))
            after ok = close(Cursor) end,
            {error, eacces} = open(list_to_binary(Gated), denied),
            {error, enoent} = open(list_to_binary(filename:join(Other, "missing")), normal),
            ok
        end),
        true = gate_waiting(),
        receive {Ref, _} -> error(published_before_grant) after 0 -> ok end,
        ok = release_gate(),
        receive {Ref, [{<<"grant-visible">>, directory}]} -> ok
        after 2000 -> error(no_result_after_grant) end,
        receive {'DOWN', Monitor, process, Pid, normal} -> ok
        after 2000 -> error(worker_did_not_exit) end,
        io:format("gated: no rows before grant; unrelated OTP file-server read + "
                  "sibling scan + error checks ~B us; scan resumed after grant~n", [Us])
    after
        % Also unblock the worker if an assertion fails.
        case gate_waiting() of true -> release_gate(); false -> ok end
    end.

await_gate(Deadline) ->
    case gate_waiting() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> error(gate_not_reached);
                false -> timer:sleep(1), await_gate(Deadline)
            end
    end.
