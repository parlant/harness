defmodule H.ExecutionEnv.Host.Fs do
  @moduledoc """
  Local host filesystem operations for `H.ExecutionEnv.Host`: symlink-hop-bounded
  `canonical_path`, UTF-8 line scanning, bounded byte reads, atomic file writes,
  directory listing, and bounded BFS file discovery.
  """

  alias H.ExecutionEnv.Host.FileSystem

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
  @read_chunk_bytes 65_536

  def resolve_path(cwd, path) when is_binary(path) do
    if String.contains?(path, <<0>>) do
      {:error, :einval}
    else
      {:ok, Path.expand(path, cwd)}
    end
  end

  def canonical_path(cwd, path) when is_binary(path) do
    with {:ok, resolved} <- resolve_path(cwd, path) do
      ["/" | segments] = Path.split(resolved)
      resolve_realpath_segments(segments, "/", @max_symlink_hops)
    end
  end

  def read_file_lines(cwd, path, opts \\ []) when is_binary(path) and is_list(opts) do
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
        with {:ok, resolved} <- resolve_path(cwd, path),
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

  def read_file_bytes(cwd, path, opts \\ []) when is_binary(path) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_byte_read_limit)
    no_follow = Keyword.get(opts, :no_follow, false)

    if not (is_integer(max_bytes) and max_bytes >= 0) do
      {:error, :invalid_max_bytes}
    else
      with {:ok, resolved} <- resolve_path(cwd, path),
           :ok <- check_stat_for_read(resolved, no_follow),
           {:ok, fd} <- :file.open(resolved, [:read, :raw, :binary]) do
        try do
          case :file.read(fd, max_bytes + 1) do
            {:ok, bytes} when byte_size(bytes) > max_bytes -> {:error, :file_too_large}
            {:ok, bytes} -> {:ok, bytes}
            :eof -> {:ok, <<>>}
            {:error, reason} -> {:error, reason}
          end
        after
          :file.close(fd)
        end
      end
    end
  end

  def write_file(cwd, path, content) when is_binary(path) do
    with {:ok, resolved} <- resolve_path(cwd, path),
         {:ok, existing_mode} <- existing_file_mode(resolved),
         :ok <- FileSystem.mkdir_p(Path.dirname(resolved)) do
      write_atomic(resolved, content, existing_mode)
    end
  end

  def list_dir(cwd, path, opts \\ []) when is_binary(path) and is_list(opts) do
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
        with {:ok, resolved} <- resolve_path(cwd, path),
             {:ok, names} <- FileSystem.ls(resolved) do
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

  def list_files(cwd, path, opts \\ []) when is_binary(path) and is_list(opts) do
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
        with {:ok, resolved} <- resolve_path(cwd, path),
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

  # --- Directory listing helpers ---

  defp inspect_entry(dir_path, name) do
    full = Path.join(dir_path, name)

    case FileSystem.lstat(full) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        %{name: name, path: full, type: "file", size: size}

      {:ok, %File.Stat{type: :directory, size: size}} ->
        %{name: name, path: full, type: "dir", size: size}

      {:ok, %File.Stat{type: :symlink, size: size}} ->
        target_type =
          case FileSystem.stat(full) do
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
      if dir_entry?(entry) and FileSystem.automatic_probe?(entry.path) do
        matched = Enum.filter(valid_markers, &FileSystem.exists?(Path.join(entry.path, &1)))
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

    case FileSystem.read_link(candidate) do
      {:ok, target} when hops > 0 ->
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
        case FileSystem.lstat(candidate) do
          {:ok, _stat} -> resolve_realpath_segments(tail, candidate, hops)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_dir_for_list_files(resolved, true) do
    case FileSystem.lstat(resolved) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_not_followed}
      {:ok, _other} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_dir_for_list_files(resolved, false) do
    case FileSystem.stat(resolved) do
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
            case FileSystem.ls(dir_abs) do
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

        case FileSystem.lstat(full) do
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
    case FileSystem.lstat(resolved) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_not_followed}
      {:ok, %File.Stat{type: :directory}} -> {:error, :eisdir}
      {:ok, _other} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_stat_for_read(resolved, false) do
    case FileSystem.stat(resolved) do
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

  defp process_valid_chunk(ctx, <<>>), do: scan_loop(ctx)

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

  defp collect_from_chunk(ctx, <<>>), do: scan_loop(ctx)

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
    case FileSystem.stat(resolved) do
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
           :ok <- FileSystem.rename(tmp_path, resolved) do
        :ok
      else
        {:error, reason} ->
          FileSystem.rm(tmp_path)
          {:error, reason}
      end
    end
  end

  defp maybe_chmod(_path, nil), do: :ok
  defp maybe_chmod(path, mode), do: FileSystem.chmod(path, Bitwise.band(mode, 0o777))
end
