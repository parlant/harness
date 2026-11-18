defmodule H.ExecutionEnv.Host do
  @moduledoc """
  Local host filesystem and OTP `Port` process-group execution environment (`H.ExecutionEnv`).
  """

  @behaviour H.ExecutionEnv

  @default_read_lines 2_000
  @default_read_bytes 51_200
  @default_byte_read_limit 5_242_880
  @default_list_limit 200
  @default_list_files_limit 200
  @default_list_files_bytes 262_144
  @default_list_files_depth 32
  @default_list_files_scanned 20_000
  @default_list_files_timeout_ms 5_000
  @max_symlink_hops 40
  @default_timeout_ms 120_000
  @read_chunk_bytes 65_536
  @term_grace_ms 500
  @kill_poll_interval_ms 20

  @stripped_env_prefixes ["H_AUTH", "H_TOKEN", "H_OWNER", "HARNESS_AUTH", "HARNESS_TOKEN"]

  @spec new(String.t(), keyword()) :: H.ExecutionEnv.t()
  def new(cwd \\ System.user_home!(), opts \\ []) when is_binary(cwd) and is_list(opts) do
    if Path.type(cwd) != :absolute do
      raise ArgumentError, "expected absolute cwd, got: #{inspect(cwd)}"
    end

    env_id =
      case Keyword.get(opts, :env_id) do
        id when is_binary(id) and id != "" -> id
        nil -> "host"
        other -> raise ArgumentError, "expected non-empty string :env_id, got: #{inspect(other)}"
      end

    env_overrides =
      opts
      |> Keyword.get(:env_overrides, %{})
      |> normalize_env_overrides()

    H.ExecutionEnv.new(__MODULE__, %{
      env_id: env_id,
      cwd: Path.expand(cwd),
      env_overrides: env_overrides
    })
  end

  @impl true
  def env_id(%{env_id: env_id}), do: env_id

  @impl true
  def kind(_state), do: "host"

  @impl true
  def cwd(%{cwd: cwd}), do: cwd

  @impl true
  def bind_cwd(state, path) when is_binary(path) do
    with {:ok, resolved} <- resolve_path(state, path) do
      case File.stat(resolved) do
        {:ok, %File.Stat{type: :directory}} -> {:ok, %{state | cwd: resolved}}
        {:ok, _other} -> {:error, :enotdir}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def resolve_path(%{cwd: cwd}, path) when is_binary(path) do
    if String.contains?(path, <<0>>) do
      {:error, :einval}
    else
      {:ok, Path.expand(path, cwd)}
    end
  end

  @impl true
  def canonical_path(state, path) when is_binary(path) do
    with {:ok, resolved} <- resolve_path(state, path) do
      ["/" | segments] = Path.split(resolved)
      resolve_realpath_segments(segments, "/", @max_symlink_hops)
    end
  end

  @impl true
  def read_file_lines(state, path, opts \\ []) when is_binary(path) and is_list(opts) do
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, @default_read_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_read_bytes)
    no_follow = Keyword.get(opts, :no_follow, false)

    cond do
      not (is_integer(offset) and offset >= 1) ->
        {:error, :invalid_offset}

      not (is_integer(limit) and limit >= 1) ->
        {:error, :invalid_limit}

      not (is_integer(max_bytes) and max_bytes >= 1) ->
        {:error, :invalid_max_bytes}

      true ->
        with {:ok, resolved} <- resolve_path(state, path),
             :ok <- check_stat_for_read(resolved, no_follow),
             {:ok, fd} <-
               :file.open(resolved, [:read, :raw, :binary, {:read_ahead, @read_chunk_bytes}]) do
          try do
            scan_lines(fd, offset, limit, max_bytes)
          after
            :file.close(fd)
          end
        end
    end
  end

  @impl true
  def read_file_bytes(state, path, opts \\ []) when is_binary(path) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_byte_read_limit)
    no_follow = Keyword.get(opts, :no_follow, false)

    if not (is_integer(max_bytes) and max_bytes >= 0) do
      {:error, :invalid_max_bytes}
    else
      with {:ok, resolved} <- resolve_path(state, path),
           :ok <- check_stat_for_read(resolved, no_follow),
           {:ok, fd} <- :file.open(resolved, [:read, :raw, :binary]) do
        try do
          case :file.read(fd, max_bytes + 1) do
            {:ok, bytes} when byte_size(bytes) > max_bytes ->
              {:error, :file_too_large}

            {:ok, bytes} ->
              {:ok, bytes}

            :eof ->
              {:ok, <<>>}

            {:error, reason} ->
              {:error, reason}
          end
        after
          :file.close(fd)
        end
      end
    end
  end

  @impl true
  def write_file(state, path, content) when is_binary(path) do
    with {:ok, resolved} <- resolve_path(state, path),
         {:ok, existing_mode} <- existing_file_mode(resolved),
         :ok <- File.mkdir_p(Path.dirname(resolved)) do
      write_atomic(resolved, content, existing_mode)
    end
  end

  @impl true
  def list_dir(state, path, opts \\ []) when is_binary(path) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_list_limit)
    cursor = Keyword.get(opts, :cursor, 0)
    include_hidden = Keyword.get(opts, :include_hidden, true)
    only_dirs = Keyword.get(opts, :only_dirs, false)
    markers = Keyword.get(opts, :markers)

    cond do
      not (is_integer(limit) and limit >= 1) ->
        {:error, :invalid_limit}

      not (is_integer(cursor) and cursor >= 0) ->
        {:error, :invalid_cursor}

      not is_boolean(include_hidden) ->
        {:error, :invalid_include_hidden}

      not is_boolean(only_dirs) ->
        {:error, :invalid_only_dirs}

      not (is_nil(markers) or is_list(markers)) ->
        {:error, :invalid_markers}

      true ->
        with {:ok, resolved} <- resolve_path(state, path),
             {:ok, names} <- File.ls(resolved) do
          candidates =
            names
            |> Enum.sort()
            |> then(fn sorted ->
              if include_hidden do
                sorted
              else
                Enum.reject(sorted, &String.starts_with?(&1, "."))
              end
            end)

          {page_entries, has_more} =
            if only_dirs do
              dirs =
                candidates
                |> Enum.map(&inspect_entry(resolved, &1))
                |> Enum.filter(&dir_entry?/1)

              window = dirs |> Enum.drop(cursor) |> Enum.take(limit + 1)
              {Enum.take(window, limit), length(window) > limit}
            else
              window = candidates |> Enum.drop(cursor) |> Enum.take(limit + 1)
              entries = window |> Enum.take(limit) |> Enum.map(&inspect_entry(resolved, &1))
              {entries, length(window) > limit}
            end

          entries = maybe_attach_markers(page_entries, markers)
          next_cursor = if has_more, do: cursor + limit, else: nil
          {:ok, %{entries: entries, next_cursor: next_cursor}}
        end
    end
  end

  @impl true
  def list_files(state, path, opts \\ []) when is_binary(path) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_list_files_limit)
    max_bytes = Keyword.get(opts, :max_bytes, @default_list_files_bytes)
    max_depth = Keyword.get(opts, :max_depth, @default_list_files_depth)
    max_scanned = Keyword.get(opts, :max_scanned, @default_list_files_scanned)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_list_files_timeout_ms)
    include_hidden = Keyword.get(opts, :include_hidden, true)
    include_dirs = Keyword.get(opts, :include_dirs, true)
    exclude = Keyword.get(opts, :exclude, [".git"])
    query = Keyword.get(opts, :query)
    no_follow = Keyword.get(opts, :no_follow, false)

    cond do
      not (is_integer(limit) and limit >= 1) ->
        {:error, :invalid_limit}

      not (is_integer(max_bytes) and max_bytes >= 1) ->
        {:error, :invalid_max_bytes}

      not (is_nil(max_depth) or (is_integer(max_depth) and max_depth >= 1)) ->
        {:error, :invalid_max_depth}

      not (is_integer(max_scanned) and max_scanned >= 1) ->
        {:error, :invalid_max_scanned}

      not (is_integer(timeout_ms) and timeout_ms >= 1) ->
        {:error, :invalid_timeout_ms}

      not is_boolean(include_hidden) ->
        {:error, :invalid_include_hidden}

      not is_boolean(include_dirs) ->
        {:error, :invalid_include_dirs}

      not (is_list(exclude) and Enum.all?(exclude, &is_binary/1)) ->
        {:error, :invalid_exclude}

      not (is_nil(query) or is_binary(query)) ->
        {:error, :invalid_query}

      not is_boolean(no_follow) ->
        {:error, :invalid_no_follow}

      true ->
        with {:ok, resolved} <- resolve_path(state, path),
             :ok <- check_dir_for_list_files(resolved, no_follow) do
          exclude_set = MapSet.new([".git" | exclude])
          query_down = if is_binary(query) and query != "", do: String.downcase(query), else: nil
          deadline = System.monotonic_time(:millisecond) + timeout_ms

          walk_ctx = %{
            limit: limit,
            max_bytes: max_bytes,
            max_depth: max_depth,
            max_scanned: max_scanned,
            deadline: deadline,
            include_hidden: include_hidden,
            include_dirs: include_dirs,
            exclude_set: exclude_set,
            query_down: query_down,
            entries_rev: [],
            count: 0,
            bytes_acc: 0,
            scanned: 0,
            truncated: false
          }

          bfs_walk(:queue.in({resolved, "", 0}, :queue.new()), walk_ctx)
        end
    end
  end

  @impl true
  def exec(state, command, opts \\ []) when is_list(opts) do
    with {:ok, exe_path, args} <- resolve_command(command),
         :ok <- ensure_cwd_dir(state.cwd) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      window_bytes = Keyword.get(opts, :window_bytes, @default_read_bytes)
      window_lines = Keyword.get(opts, :window_lines, @default_read_lines)
      abort_ref = Keyword.get(opts, :abort_ref)
      on_output = Keyword.get(opts, :on_output)
      env = build_sanitized_env(state.env_overrides, Keyword.get(opts, :env, %{}))

      run_port(
        exe_path,
        args,
        state.cwd,
        env,
        timeout_ms,
        window_bytes,
        window_lines,
        abort_ref,
        on_output
      )
    end
  end

  # --- Directory listing helpers ---

  defp inspect_entry(dir_path, name) do
    full = Path.join(dir_path, name)

    case File.lstat(full) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        %{name: name, path: full, type: "file", size: size}

      {:ok, %File.Stat{type: :directory, size: size}} ->
        %{name: name, path: full, type: "dir", size: size}

      {:ok, %File.Stat{type: :symlink, size: size}} ->
        target_type =
          case File.stat(full) do
            {:ok, %File.Stat{type: :directory}} -> "dir"
            {:ok, %File.Stat{type: :regular}} -> "file"
            _ -> "other"
          end

        %{name: name, path: full, type: "symlink", target_type: target_type, size: size}

      {:ok, %File.Stat{size: size}} ->
        %{name: name, path: full, type: "other", size: size}

      {:error, _} ->
        %{name: name, path: full, type: "other", size: 0}
    end
  end

  defp dir_entry?(%{type: "dir"}), do: true
  defp dir_entry?(%{type: "symlink", target_type: "dir"}), do: true
  defp dir_entry?(_entry), do: false

  defp maybe_attach_markers(entries, nil), do: entries

  defp maybe_attach_markers(entries, markers) when is_list(markers) do
    valid_markers = Enum.filter(markers, &is_binary/1)

    Enum.map(entries, fn entry ->
      if dir_entry?(entry) do
        matched = Enum.filter(valid_markers, &File.exists?(Path.join(entry.path, &1)))
        Map.put(entry, :markers, matched)
      else
        entry
      end
    end)
  end

  # --- Recursive bounded file discovery & canonical_path ---

  defp resolve_realpath_segments([], current, _hops), do: {:ok, current}

  defp resolve_realpath_segments(["." | tail], current, hops),
    do: resolve_realpath_segments(tail, current, hops)

  defp resolve_realpath_segments([".." | tail], current, hops) do
    resolve_realpath_segments(tail, Path.dirname(current), hops)
  end

  defp resolve_realpath_segments([seg | tail], current, hops) do
    candidate = if current == "/", do: "/" <> seg, else: current <> "/" <> seg

    case :file.read_link(candidate) do
      {:ok, target_charlist} when hops > 0 ->
        target = List.to_string(target_charlist)

        if Path.type(target) == :absolute do
          ["/" | target_segs] = Path.split(target)
          resolve_realpath_segments(target_segs ++ tail, "/", hops - 1)
        else
          target_segs = Path.split(target)
          resolve_realpath_segments(target_segs ++ tail, current, hops - 1)
        end

      {:ok, _target_charlist} ->
        {:error, :eloop}

      {:error, :einval} ->
        case File.lstat(candidate) do
          {:ok, _stat} -> resolve_realpath_segments(tail, candidate, hops)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_dir_for_list_files(resolved, true) do
    case File.lstat(resolved) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_not_followed}
      {:ok, _other} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_dir_for_list_files(resolved, false) do
    case File.stat(resolved) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _other} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bfs_walk(queue, ctx) do
    if ctx.truncated do
      {:ok, %{entries: Enum.reverse(ctx.entries_rev), truncated: true}}
    else
      case :queue.out(queue) do
        {:empty, _} ->
          {:ok, %{entries: Enum.reverse(ctx.entries_rev), truncated: false}}

        {{:value, {dir_abs, rel_prefix, depth}}, rest_queue} ->
          if System.monotonic_time(:millisecond) >= ctx.deadline do
            {:ok, %{entries: Enum.reverse(ctx.entries_rev), truncated: true}}
          else
            case File.ls(dir_abs) do
              {:ok, names} ->
                filtered =
                  names
                  |> Enum.sort()
                  |> Enum.reject(fn name ->
                    MapSet.member?(ctx.exclude_set, name) or
                      (not ctx.include_hidden and String.starts_with?(name, "."))
                  end)

                {next_queue, next_ctx} =
                  process_dir_names(filtered, dir_abs, rel_prefix, depth, rest_queue, ctx)

                bfs_walk(next_queue, next_ctx)

              {:error, reason} when depth == 0 ->
                {:error, reason}

              {:error, _reason} ->
                bfs_walk(rest_queue, ctx)
            end
          end
      end
    end
  end

  defp process_dir_names([], _dir_abs, _rel_prefix, _depth, queue, ctx), do: {queue, ctx}

  defp process_dir_names(_names, _dir_abs, _rel_prefix, _depth, queue, %{truncated: true} = ctx),
    do: {queue, ctx}

  defp process_dir_names([name | rest], dir_abs, rel_prefix, depth, queue, ctx) do
    cond do
      ctx.scanned >= ctx.max_scanned ->
        {queue, %{ctx | truncated: true}}

      System.monotonic_time(:millisecond) >= ctx.deadline ->
        {queue, %{ctx | truncated: true}}

      true ->
        ctx = %{ctx | scanned: ctx.scanned + 1}
        full = Path.join(dir_abs, name)
        rel = if rel_prefix == "", do: name, else: rel_prefix <> "/" <> name

        case File.lstat(full) do
          {:ok, %File.Stat{type: :regular, size: size}} ->
            next_ctx = maybe_collect_entry(ctx, rel, "file", size)
            process_dir_names(rest, dir_abs, rel_prefix, depth, queue, next_ctx)

          {:ok, %File.Stat{type: :directory}} ->
            next_queue =
              if is_nil(ctx.max_depth) or depth + 1 < ctx.max_depth do
                :queue.in({full, rel, depth + 1}, queue)
              else
                queue
              end

            next_ctx =
              if ctx.include_dirs do
                maybe_collect_entry(ctx, rel, "dir", 0)
              else
                ctx
              end

            process_dir_names(rest, dir_abs, rel_prefix, depth, next_queue, next_ctx)

          {:ok, %File.Stat{type: :symlink, size: size}} ->
            next_ctx = maybe_collect_entry(ctx, rel, "symlink", size)
            process_dir_names(rest, dir_abs, rel_prefix, depth, queue, next_ctx)

          _ ->
            process_dir_names(rest, dir_abs, rel_prefix, depth, queue, ctx)
        end
    end
  end

  defp maybe_collect_entry(ctx, rel, type, size) do
    if matches_query?(rel, ctx.query_down) do
      entry_bytes = byte_size(rel)

      cond do
        ctx.count >= ctx.limit ->
          %{ctx | truncated: true}

        ctx.bytes_acc + entry_bytes > ctx.max_bytes ->
          %{ctx | truncated: true}

        true ->
          entry = %{path: rel, type: type, size: size}

          %{
            ctx
            | entries_rev: [entry | ctx.entries_rev],
              count: ctx.count + 1,
              bytes_acc: ctx.bytes_acc + entry_bytes
          }
      end
    else
      ctx
    end
  end

  defp matches_query?(_rel, nil), do: true
  defp matches_query?(rel, query_down), do: String.contains?(String.downcase(rel), query_down)

  # --- Line scanning ---

  defp check_stat_for_read(resolved, true) do
    case File.lstat(resolved) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_not_followed}
      {:ok, %File.Stat{type: :directory}} -> {:error, :eisdir}
      {:ok, _other} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_stat_for_read(resolved, false) do
    case File.stat(resolved) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :directory}} -> {:error, :eisdir}
      {:ok, _other} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scan_lines(fd, offset, limit, max_bytes) do
    ctx = %{
      fd: fd,
      offset: offset,
      limit: limit,
      max_bytes: max_bytes,
      current_line: 1,
      utf8_carry: <<>>,
      line_buf: <<>>,
      lines_rev: [],
      lines_count: 0,
      bytes_acc: 0,
      has_more: false,
      truncated_by_bytes: false
    }

    scan_loop(ctx)
  end

  defp scan_loop(ctx) do
    case :file.read(ctx.fd, @read_chunk_bytes) do
      {:ok, chunk} ->
        if :binary.match(chunk, <<0>>) != :nomatch do
          {:error, :binary_file}
        else
          data = ctx.utf8_carry <> chunk

          case :unicode.characters_to_binary(data, :utf8, :utf8) do
            valid when is_binary(valid) ->
              process_valid_chunk(%{ctx | utf8_carry: <<>>}, valid)

            {:incomplete, valid, rest} ->
              process_valid_chunk(%{ctx | utf8_carry: rest}, valid)

            {:error, _valid, _rest} ->
              {:error, :binary_file}
          end
        end

      :eof ->
        if ctx.utf8_carry != <<>> do
          {:error, :binary_file}
        else
          finalize_eof(ctx)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_valid_chunk(ctx, <<>>) do
    scan_loop(ctx)
  end

  defp process_valid_chunk(ctx, valid) do
    if ctx.current_line < ctx.offset do
      skip_to_offset(ctx, valid)
    else
      collect_from_chunk(ctx, valid)
    end
  end

  defp skip_to_offset(ctx, data) do
    case :binary.match(data, "\n") do
      :nomatch ->
        scan_loop(ctx)

      {nl_pos, 1} ->
        next_line = ctx.current_line + 1
        rest_start = nl_pos + 1
        rest = :binary.part(data, rest_start, byte_size(data) - rest_start)
        next_ctx = %{ctx | current_line: next_line}

        if next_line < ctx.offset do
          skip_to_offset(next_ctx, rest)
        else
          collect_from_chunk(next_ctx, rest)
        end
    end
  end

  defp collect_from_chunk(ctx, <<>>) do
    scan_loop(ctx)
  end

  defp collect_from_chunk(ctx, data) do
    if ctx.lines_count >= ctx.limit do
      {:ok, finish_result(%{ctx | has_more: true})}
    else
      case :binary.match(data, "\n") do
        :nomatch ->
          new_buf = ctx.line_buf <> data

          if line_exceeds_max_bytes?(ctx, strip_cr(new_buf)) do
            {:ok, finish_result(%{ctx | has_more: true, truncated_by_bytes: true})}
          else
            scan_loop(%{ctx | line_buf: new_buf})
          end

        {nl_pos, 1} ->
          segment = :binary.part(data, 0, nl_pos)
          full_line = strip_cr(ctx.line_buf <> segment)
          rest_start = nl_pos + 1
          rest = :binary.part(data, rest_start, byte_size(data) - rest_start)

          case append_line(ctx, full_line) do
            {:ok, next_ctx} ->
              next_ctx = %{next_ctx | line_buf: <<>>, current_line: next_ctx.current_line + 1}

              if next_ctx.lines_count >= next_ctx.limit do
                if rest != <<>> do
                  {:ok, finish_result(%{next_ctx | has_more: true})}
                else
                  check_eof_for_has_more(next_ctx)
                end
              else
                collect_from_chunk(next_ctx, rest)
              end

            {:truncated, next_ctx} ->
              {:ok, finish_result(%{next_ctx | has_more: true, truncated_by_bytes: true})}
          end
      end
    end
  end

  defp check_eof_for_has_more(ctx) do
    case :file.read(ctx.fd, 1) do
      {:ok, <<0>>} ->
        {:error, :binary_file}

      {:ok, _byte} ->
        {:ok, finish_result(%{ctx | has_more: true})}

      :eof ->
        if ctx.utf8_carry != <<>> do
          {:error, :binary_file}
        else
          {:ok, finish_result(%{ctx | has_more: false})}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_eof(ctx) do
    if ctx.current_line >= ctx.offset and ctx.line_buf != <<>> do
      line = strip_cr(ctx.line_buf)

      case append_line(ctx, line) do
        {:ok, next_ctx} ->
          {:ok, finish_result(%{next_ctx | has_more: false})}

        {:truncated, next_ctx} ->
          {:ok, finish_result(%{next_ctx | has_more: true, truncated_by_bytes: true})}
      end
    else
      {:ok, finish_result(ctx)}
    end
  end

  defp append_line(ctx, line) do
    sep = if ctx.lines_count == 0, do: 0, else: 1
    new_bytes = ctx.bytes_acc + sep + byte_size(line)

    if new_bytes > ctx.max_bytes do
      {:truncated, ctx}
    else
      {:ok,
       %{
         ctx
         | lines_rev: [line | ctx.lines_rev],
           lines_count: ctx.lines_count + 1,
           bytes_acc: new_bytes
       }}
    end
  end

  defp line_exceeds_max_bytes?(ctx, partial_line) do
    sep = if ctx.lines_count == 0, do: 0, else: 1
    ctx.bytes_acc + sep + byte_size(partial_line) > ctx.max_bytes
  end

  defp strip_cr(<<>>), do: <<>>

  defp strip_cr(bin) do
    if :binary.last(bin) == ?\r do
      :binary.part(bin, 0, byte_size(bin) - 1)
    else
      bin
    end
  end

  defp finish_result(ctx) do
    %{
      lines: Enum.reverse(ctx.lines_rev),
      start_line: ctx.offset,
      total_lines_read: ctx.lines_count,
      has_more: ctx.has_more,
      truncated_by_bytes: ctx.truncated_by_bytes
    }
  end

  # --- Atomic write ---

  defp existing_file_mode(resolved) do
    case File.stat(resolved) do
      {:ok, %File.Stat{type: :directory}} -> {:error, :eisdir}
      {:ok, %File.Stat{mode: mode}} -> {:ok, mode}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_atomic(resolved, content, existing_mode) do
    dir = Path.dirname(resolved)
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    tmp_path = Path.join(dir, ".h-tmp-#{:erlang.unique_integer([:positive, :monotonic])}-#{rand}")

    with {:ok, fd} <- :file.open(tmp_path, [:write, :binary, :raw, :exclusive]) do
      write_res =
        try do
          with :ok <- :file.write(fd, content),
               :ok <- :file.sync(fd) do
            :ok
          end
        after
          :file.close(fd)
        end

      with :ok <- write_res,
           :ok <- maybe_chmod(tmp_path, existing_mode),
           :ok <- File.rename(tmp_path, resolved) do
        :ok
      else
        {:error, reason} ->
          File.rm(tmp_path)
          {:error, reason}
      end
    end
  end

  defp maybe_chmod(_path, nil), do: :ok
  defp maybe_chmod(path, mode), do: File.chmod(path, Bitwise.band(mode, 0o777))

  # --- Exec + PGID reaping + rolling tail window ---

  defp resolve_command({:shell, cmd}) when is_binary(cmd) do
    {:ok, "/bin/sh", ["-c", cmd]}
  end

  defp resolve_command({:argv, [exe | args]}) when is_binary(exe) and is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      exe_path =
        if String.contains?(exe, "/") do
          if File.regular?(exe), do: exe, else: nil
        else
          System.find_executable(exe)
        end

      if exe_path do
        {:ok, exe_path, args}
      else
        {:error, {:enoent, exe}}
      end
    else
      {:error, :invalid_command}
    end
  end

  defp resolve_command(_), do: {:error, :invalid_command}

  defp ensure_cwd_dir(cwd) do
    if File.dir?(cwd), do: :ok, else: {:error, :enoent}
  end

  defp normalize_env_overrides(overrides) when is_map(overrides) or is_list(overrides) do
    Enum.reduce(overrides, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), v)
    end)
  end

  defp build_sanitized_env(state_overrides, opt_overrides) do
    merged_overrides = Map.merge(state_overrides, normalize_env_overrides(opt_overrides))

    unset_stripped =
      System.get_env()
      |> Enum.filter(fn {k, _v} -> stripped_env_key?(k) end)
      |> Map.new(fn {k, _v} -> {k, false} end)

    unset_stripped
    |> Map.merge(merged_overrides)
    |> Enum.reject(fn {k, _v} -> String.contains?(k, <<0>>) end)
    |> Enum.map(fn
      {k, nil} -> {String.to_charlist(k), false}
      {k, false} -> {String.to_charlist(k), false}
      {k, v} -> {String.to_charlist(k), String.to_charlist(to_string(v))}
    end)
  end

  defp stripped_env_key?(key) do
    upper = String.upcase(key)
    Enum.any?(@stripped_env_prefixes, &String.starts_with?(upper, &1))
  end

  defp run_port(
         exe_path,
         args,
         cwd,
         env,
         timeout_ms,
         window_bytes,
         window_lines,
         abort_ref,
         on_output
       ) do
    caller = self()
    reaper_pid = spawn(fn -> reaper_loop(caller, nil) end)

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: args,
      cd: String.to_charlist(cwd),
      env: env
    ]

    try do
      port = Port.open({:spawn_executable, exe_path}, port_opts)

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} ->
            send(reaper_pid, {:arm, pid})
            pid

          nil ->
            nil
        end

      buf = new_window_buf(window_bytes, window_lines)
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      try do
        case port_loop(port, buf, deadline, abort_ref, on_output) do
          {:ok, exit_code, final_buf} ->
            {result_buf, outcome_map} = finalize_window_buf(final_buf)
            close_spill_fd(result_buf)
            {:ok, Map.put(outcome_map, :exit_code, exit_code)}

          {:error, reason, final_buf} ->
            {result_buf, outcome_map} = finalize_window_buf(final_buf)
            close_spill_fd(result_buf)
            {:error, Map.put(outcome_map, :reason, reason)}
        end
      after
        close_port_safely(port)
        flush_port_messages(port)
        reap_pgid(os_pid)
      end
    rescue
      e in ErlangError ->
        {:error, e.original}
    after
      send(reaper_pid, :disarm)
    end
  end

  defp port_loop(port, buf, deadline, abort_ref, on_output) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, chunk}} ->
        if is_function(on_output, 1), do: on_output.(chunk)
        next_buf = push_window_chunk(buf, chunk)
        port_loop(port, next_buf, deadline, abort_ref, on_output)

      {^port, {:exit_status, exit_code}} ->
        drained_buf = drain_remaining_data(port, buf, on_output)
        {:ok, exit_code, drained_buf}

      {:abort_exec, ref} when not is_nil(abort_ref) and ref == abort_ref ->
        drained_buf = drain_remaining_data(port, buf, on_output)
        {:error, :aborted, drained_buf}
    after
      remaining ->
        drained_buf = drain_remaining_data(port, buf, on_output)
        {:error, :timeout, drained_buf}
    end
  end

  defp drain_remaining_data(port, buf, on_output) do
    receive do
      {^port, {:data, chunk}} ->
        if is_function(on_output, 1), do: on_output.(chunk)
        drain_remaining_data(port, push_window_chunk(buf, chunk), on_output)
    after
      0 -> buf
    end
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp close_port_safely(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end
  catch
    :error, :badarg -> :ok
  end

  defp reaper_loop(caller, os_pid) do
    ref = Process.monitor(caller)
    reaper_wait(ref, os_pid)
  end

  defp reaper_wait(ref, os_pid) do
    receive do
      {:arm, pid} ->
        reaper_wait(ref, pid)

      :disarm ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _pid, _reason} ->
        reap_pgid(os_pid)
        :ok
    end
  end

  defp reap_pgid(nil), do: :ok

  defp reap_pgid(os_pid) when is_integer(os_pid) do
    if pgid_alive?(os_pid) do
      System.cmd("/bin/kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)

      if wait_pgid_exit(os_pid, @term_grace_ms) do
        :ok
      else
        System.cmd("/bin/kill", ["-KILL", "-#{os_pid}"], stderr_to_stdout: true)
        wait_pgid_exit(os_pid, 200)
        :ok
      end
    else
      :ok
    end
  end

  defp pgid_alive?(os_pid) do
    case System.cmd("/bin/kill", ["-0", "-#{os_pid}"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp wait_pgid_exit(os_pid, max_wait_ms) do
    deadline = System.monotonic_time(:millisecond) + max_wait_ms
    poll_pgid_exit(os_pid, deadline)
  end

  defp poll_pgid_exit(os_pid, deadline) do
    if not pgid_alive?(os_pid) do
      true
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        false
      else
        Process.sleep(min(@kill_poll_interval_ms, deadline - now))
        poll_pgid_exit(os_pid, deadline)
      end
    end
  end

  # --- Rolling tail window & spill buffer ---

  defp new_window_buf(window_bytes, window_lines) do
    %{
      chunks: :queue.new(),
      tail_bytes: 0,
      tail_newlines: 0,
      total_bytes: 0,
      total_newlines: 0,
      window_bytes: window_bytes,
      window_lines: window_lines,
      spill_path: nil,
      spill_fd: nil
    }
  end

  defp push_window_chunk(buf, <<>>), do: buf

  defp push_window_chunk(buf, chunk) do
    chunk_bytes = byte_size(chunk)
    chunk_newlines = count_newlines(chunk)
    new_total_bytes = buf.total_bytes + chunk_bytes
    new_total_newlines = buf.total_newlines + chunk_newlines

    exceeds_lines? =
      new_total_newlines > buf.window_lines or
        (new_total_newlines == buf.window_lines and not String.ends_with?(chunk, "\n") and
           new_total_bytes > 0)

    exceeds? = new_total_bytes > buf.window_bytes or exceeds_lines?

    buf =
      if exceeds? do
        buf = ensure_spill_file(buf)
        if buf.spill_fd, do: :file.write(buf.spill_fd, chunk)
        buf
      else
        buf
      end

    {chunk_to_keep, keep_bytes, keep_newlines} =
      if chunk_bytes > buf.window_bytes * 2 do
        cap = buf.window_bytes + 4
        sliced = :binary.part(chunk, chunk_bytes - cap, cap)
        {sliced, byte_size(sliced), count_newlines(sliced)}
      else
        {chunk, chunk_bytes, chunk_newlines}
      end

    chunks = :queue.in({chunk_to_keep, keep_bytes, keep_newlines}, buf.chunks)
    tail_bytes = buf.tail_bytes + keep_bytes
    tail_newlines = buf.tail_newlines + keep_newlines

    {trimmed_chunks, trimmed_bytes, trimmed_newlines} =
      trim_queue(chunks, tail_bytes, tail_newlines, buf.window_bytes, buf.window_lines)

    %{
      buf
      | chunks: trimmed_chunks,
        tail_bytes: trimmed_bytes,
        tail_newlines: trimmed_newlines,
        total_bytes: new_total_bytes,
        total_newlines: new_total_newlines
    }
  end

  defp trim_queue(chunks, tail_bytes, tail_newlines, window_bytes, window_lines) do
    case :queue.peek(chunks) do
      {:value, {_c, b, nl}}
      when tail_bytes - b >= window_bytes or tail_newlines - nl >= window_lines ->
        {{:value, _}, rest} = :queue.out(chunks)
        trim_queue(rest, tail_bytes - b, tail_newlines - nl, window_bytes, window_lines)

      _ ->
        {chunks, tail_bytes, tail_newlines}
    end
  end

  defp ensure_spill_file(%{spill_fd: fd} = buf) when not is_nil(fd), do: buf

  defp ensure_spill_file(buf) do
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    spill_path =
      Path.join(
        System.tmp_dir!(),
        "h-exec-#{:erlang.unique_integer([:positive, :monotonic])}-#{rand}.log"
      )

    case :file.open(spill_path, [:write, :binary, :raw, :exclusive]) do
      {:ok, fd} ->
        File.chmod(spill_path, 0o600)

        buf.chunks
        |> :queue.to_list()
        |> Enum.each(fn {chunk, _b, _nl} -> :file.write(fd, chunk) end)

        %{buf | spill_path: spill_path, spill_fd: fd}

      {:error, _} ->
        buf
    end
  end

  defp close_spill_fd(%{spill_fd: nil} = buf), do: buf

  defp close_spill_fd(%{spill_fd: fd} = buf) do
    :file.close(fd)
    %{buf | spill_fd: nil}
  end

  defp finalize_window_buf(buf) do
    raw_tail =
      buf.chunks
      |> :queue.to_list()
      |> Enum.map(fn {chunk, _b, _nl} -> chunk end)
      |> IO.iodata_to_binary()

    line_trimmed = trim_tail_lines(raw_tail, buf.window_lines)
    byte_trimmed = trim_tail_bytes(line_trimmed, buf.window_bytes)

    skipped = max(0, buf.total_bytes - byte_size(byte_trimmed))
    truncated = skipped > 0
    buf = if truncated and is_nil(buf.spill_path), do: ensure_spill_file(buf), else: buf
    output = String.replace_invalid(byte_trimmed)

    {buf,
     %{
       output: output,
       truncated: truncated,
       skipped_bytes: skipped,
       full_output_path: buf.spill_path
     }}
  end

  defp trim_tail_lines(<<>>, _max_lines), do: <<>>

  defp trim_tail_lines(bin, max_lines) do
    nl_count = count_newlines(bin)
    line_count = if String.ends_with?(bin, "\n"), do: nl_count, else: nl_count + 1

    if line_count > max_lines do
      drop_lines(bin, line_count - max_lines)
    else
      bin
    end
  end

  defp drop_lines(bin, 0), do: bin

  defp drop_lines(bin, n) do
    case :binary.match(bin, "\n") do
      :nomatch ->
        <<>>

      {pos, 1} ->
        rest = :binary.part(bin, pos + 1, byte_size(bin) - pos - 1)
        drop_lines(rest, n - 1)
    end
  end

  defp trim_tail_bytes(bin, max_bytes) when byte_size(bin) <= max_bytes, do: bin

  defp trim_tail_bytes(bin, max_bytes) do
    total = byte_size(bin)
    sliced = :binary.part(bin, total - max_bytes, max_bytes)
    align_utf8_head(sliced, 0)
  end

  # Skip up to 3 leading UTF-8 continuation bytes (10xxxxxx) after a byte-slice cut.
  defp align_utf8_head(<<byte, rest::binary>>, skipped)
       when skipped < 3 and byte >= 0x80 and byte <= 0xBF do
    align_utf8_head(rest, skipped + 1)
  end

  defp align_utf8_head(bin, _skipped), do: bin

  defp count_newlines(bin), do: length(:binary.matches(bin, "\n"))
end
