defmodule H.Daemon.CLI do
  @moduledoc false

  @usage """
  Usage:
    h-daemon [-ne | --no-extensions] [--data-dir DIR] [--port PORT] [--check-config]
    h-daemon remote-agent [--cwd DIR] [--id ID] [--bind IP] [--port PORT] [--socket PATH] [--token-file PATH]
  """

  @remote_usage "Usage: h-daemon remote-agent [--cwd DIR] [--id ID] [--bind IP] [--port PORT] [--socket PATH] [--token-file PATH]"

  def main(["remote-agent" | rest]) do
    case parse_remote_agent(rest) do
      :help ->
        IO.puts(@remote_usage)

      {:ok, opts} ->
        run_remote_agent(opts)

      {:error, :usage} ->
        IO.puts(:stderr, @remote_usage)
        System.halt(2)
    end
  end

  def main(args) do
    case parse(args) do
      :help ->
        IO.puts(@usage)

      {:ok, [{:check_config, true} | opts]} ->
        dir = Path.expand(opts[:data_dir] || System.get_env("H_DATA_DIR") || "~/.local/share/h")

        ext_opts =
          opts
          |> Keyword.put(:data_dir, dir)
          |> maybe_put_bundle_override()

        with {:ok, addresses} <- H.Daemon.Network.load(dir),
             result when result in [:ok, :disabled] <- web(:configure, addresses),
             {:ok, opts, _} <- H.Extensions.load(ext_opts),
             {:ok, opts} <- H.Provider.Compatible.load(opts),
             {:ok, _, _} <- H.Accounts.boot(opts) do
          IO.puts("H startup configuration OK (no services started)")
        else
          {:error, reason} ->
            IO.puts(:stderr, "Invalid H startup configuration: #{inspect(reason, limit: 15)}")
            System.halt(1)
        end

      {:ok, opts} ->
        dir = Path.expand(opts[:data_dir] || System.get_env("H_DATA_DIR") || "~/.local/share/h")
        _ = H.Daemon.SignalHandler.install(self())

        with {:ok, addresses} <- H.Daemon.Network.load(dir),
             :ok <- web(:start, addresses),
             {:ok, _} <-
               H.serve(opts ++ [data_dir: dir, bind_addresses: addresses, shutdown_owner: self()]) do
          ref = Process.monitor(H.Daemon.Instance)
          await_shutdown(ref, false)
        else
          {:error, reason} ->
            IO.puts(
              :stderr,
              "H daemon could not start: #{inspect(reason, limit: 15)}. Use --no-extensions to bypass extension configuration."
            )

            System.halt(1)
        end

      {:error, :usage} ->
        IO.puts(:stderr, @usage)
        System.halt(2)
    end
  end

  defp await_shutdown(ref, sigterm_received?) do
    receive do
      msg when msg in [:shutdown_when_idle, :shutdown_drained] ->
        stop_cleanly()

      {:os_signal, :sigterm} when not sigterm_received? ->
        case initiate_drain() do
          {:ok, _} -> await_shutdown(ref, true)
          _ -> stop_cleanly()
        end

      {:os_signal, :sigterm} ->
        stop_cleanly()

      :drain_timeout ->
        IO.puts(:stderr, "H daemon drain timed out; stopping now.")
        stop_cleanly()

      {:DOWN, ^ref, :process, _, _} ->
        System.stop(1)
    end
  end

  defp initiate_drain do
    case H.Daemon.instance_options() do
      opts when is_list(opts) -> H.Daemon.Maintenance.drain_and_stop(opts)
      _ -> {:error, :daemon_unavailable}
    end
  catch
    :exit, _ -> {:error, :daemon_unavailable}
  end

  defp stop_cleanly do
    Application.stop(:harness_web)

    case Supervisor.terminate_child(H.Supervisor, H.Daemon.Instance) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :not_running} -> :ok
    end

    System.stop(0)
  end

  # Core-only checkouts still run without Phoenix on their code path.
  defp web(action, addresses) do
    if Code.ensure_loaded?(HWeb.Standalone),
      do: apply(HWeb.Standalone, action, [addresses]),
      else: :ok
  end

  defp maybe_put_bundle_override(opts) do
    case System.get_env("H_CURRENT_BUNDLE_OVERRIDE") do
      raw when is_binary(raw) ->
        case String.split(raw, "=", parts: 2) do
          [from, to] when from != "" and to != "" ->
            Keyword.put(opts, :bundle_override, {Path.expand(from), Path.expand(to)})

          _ ->
            opts
        end

      _ ->
        opts
    end
  end

  def parse(args) when args in [["-h"], ["--help"]], do: :help

  def parse(["remote-agent" | rest]) do
    case parse_remote_agent(rest) do
      {:ok, opts} -> {:ok, [{:subcommand, :remote_agent} | opts]}
      other -> other
    end
  end

  def parse(args) do
    {disable, args} = Enum.split_with(args, &(&1 in ["-ne", "--no-extensions"]))

    case OptionParser.parse(args,
           strict: [data_dir: :string, port: :integer, check_config: :boolean]
         ) do
      {opts, [], []} ->
        if Keyword.get(opts, :port, 4100) in 0..65_535 and Keyword.get(opts, :data_dir, ".") != "" do
          {check, opts} = Keyword.pop(opts, :check_config, false)
          opts = Keyword.put(opts, :no_extensions, disable != [])
          {:ok, if(check, do: [{:check_config, true} | opts], else: opts)}
        else
          {:error, :usage}
        end

      _ ->
        {:error, :usage}
    end
  end

  def parse_remote_agent(args) when args in [["-h"], ["--help"]], do: :help

  def parse_remote_agent(args) do
    case OptionParser.parse(args,
           strict: [
             cwd: :string,
             id: :string,
             bind: :string,
             port: :integer,
             socket: :string,
             token_file: :string
           ]
         ) do
      {opts, [], []} ->
        with {:ok, ip} <- parse_bind_ip(Keyword.get(opts, :bind, "127.0.0.1")),
             true <- Keyword.get(opts, :port, 0) in 0..65_535,
             true <- Keyword.get(opts, :cwd, ".") != "",
             true <- Keyword.get(opts, :id, "remote") != "" do
          {:ok,
           opts
           |> Keyword.put(:ip, ip)
           |> Keyword.delete(:bind)}
        else
          _ -> {:error, :usage}
        end

      _ ->
        {:error, :usage}
    end
  end

  defp parse_bind_ip(raw) when is_binary(raw) do
    case :inet.parse_address(String.to_charlist(String.trim(raw))) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  defp run_remote_agent(opts) do
    case resolve_remote_token(opts[:token_file]) do
      {:ok, token} ->
        {:ok, _} = Application.ensure_all_started(:bandit)
        {:ok, _} = Application.ensure_all_started(:crypto)
        _ = H.Daemon.SignalHandler.install(self())

        cwd = Path.expand(opts[:cwd] || File.cwd!())
        id = opts[:id] || "remote"
        ip = opts[:ip]
        port = Keyword.get(opts, :port)
        socket_path = opts[:socket]

        effective_port =
          cond do
            is_integer(port) -> port
            is_binary(socket_path) and socket_path != "" -> nil
            true -> 0
          end

        http_opts =
          [
            cwd: cwd,
            id: id,
            token: token,
            ip: if(is_nil(effective_port), do: nil, else: ip),
            port: effective_port,
            socket_path: socket_path
          ]

        case H.RemoteAgent.HTTP.start_link(http_opts) do
          {:ok, sup} ->
            ref = Process.monitor(sup)

            if url = H.RemoteAgent.HTTP.endpoint_url(sup) do
              IO.puts("H remote-agent HTTP listening at #{url}")
            end

            if is_binary(socket_path) and socket_path != "" do
              IO.puts("H remote-agent socket listening at #{socket_path}")
            end

            IO.puts("READY:" <> System.pid())
            await_remote_agent_shutdown(sup, ref)

          {:error, reason} ->
            IO.puts(:stderr, "H remote-agent failed to start: #{inspect(reason, limit: 15)}")
            System.halt(1)
        end

      {:error, msg} ->
        IO.puts(:stderr, msg)
        System.halt(1)
    end
  end

  defp resolve_remote_token(nil) do
    case System.get_env("H_REMOTE_AGENT_TOKEN") do
      token when is_binary(token) ->
        trimmed = String.trim(token)
        if trimmed == "", do: {:error, "Missing remote-agent token"}, else: {:ok, trimmed}

      nil ->
        {:error, "Missing remote-agent token (set H_REMOTE_AGENT_TOKEN or pass --token-file)"}
    end
  end

  defp resolve_remote_token(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        trimmed = String.trim(content)
        if trimmed == "", do: {:error, "Token file #{path} is empty"}, else: {:ok, trimmed}

      {:error, reason} ->
        {:error, "Could not read token file #{path}: #{inspect(reason)}"}
    end
  end

  defp await_remote_agent_shutdown(sup, ref) do
    receive do
      {:os_signal, :sigterm} ->
        Process.unlink(sup)
        Process.demonitor(ref, [:flush])
        _ = Supervisor.stop(sup, :shutdown, 5_000)
        System.stop(0)

      {:DOWN, ^ref, :process, ^sup, _reason} ->
        System.stop(1)
    end
  end
end
