defmodule H.ExecutionEnv.Host.Exec do
  @moduledoc """
  Sanitized environment construction, OTP `Port` execution, OS `PGID` process-group
  reaping, and rolling tail/spill-file output buffering for `H.ExecutionEnv.Host`.
  """

  @default_read_lines 2_000
  @default_read_bytes 51_200
  @default_timeout_ms 120_000
  @term_grace_ms 500
  @kill_poll_interval_ms 20

  @stripped_env_prefixes ["H_AUTH", "H_TOKEN", "H_OWNER", "HARNESS_AUTH", "HARNESS_TOKEN"]
  @provider_secret_env ~w(OPENAI_CODEX_ACCESS_TOKEN GOOGLE_VERTEX_API_KEY GOOGLE_CLOUD_API_KEY)

  def normalize_env_overrides(overrides) when is_map(overrides) or is_list(overrides) do
    Enum.reduce(overrides, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), v)
    end)
  end

  def exec(state, command, opts \\ []) when is_list(opts) do
    with {:ok, exe_path, args} <- resolve_command(command),
         :ok <- ensure_cwd_dir(state.cwd) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      window_bytes = Keyword.get(opts, :window_bytes, @default_read_bytes)
      window_lines = Keyword.get(opts, :window_lines, @default_read_lines)
      abort_ref = Keyword.get(opts, :abort_ref)
      on_output = Keyword.get(opts, :on_output)
      env = build_sanitized_env(state.env_overrides, Keyword.get(opts, :env, %{}))

      output_opts = Keyword.take(opts, [:raw_output, :spill_output])

      run_port(
        exe_path,
        args,
        state.cwd,
        env,
        timeout_ms,
        window_bytes,
        window_lines,
        abort_ref,
        on_output,
        output_opts
      )
    end
  end

  # --- Command & environment preparation ---

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

    upper in @provider_secret_env or
      Enum.any?(@stripped_env_prefixes, &String.starts_with?(upper, &1))
  end

  # --- Port execution & OS PGID reaper ---

  defp run_port(
         exe_path,
         args,
         cwd,
         env,
         timeout_ms,
         window_bytes,
         window_lines,
         abort_ref,
         on_output,
         output_opts
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

      buf = new_window_buf(window_bytes, window_lines, output_opts)
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

  defp new_window_buf(window_bytes, window_lines, output_opts) do
    %{
      chunks: :queue.new(),
      tail_bytes: 0,
      tail_newlines: 0,
      total_bytes: 0,
      total_newlines: 0,
      window_bytes: window_bytes,
      window_lines: window_lines,
      raw_output?: Keyword.get(output_opts, :raw_output, false),
      spill_output?: Keyword.get(output_opts, :spill_output, true),
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

  defp ensure_spill_file(%{spill_output?: false} = buf), do: buf
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
    output = if buf.raw_output?, do: byte_trimmed, else: String.replace_invalid(byte_trimmed)

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
