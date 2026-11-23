defmodule H.Daemon.CLI do
  @moduledoc false

  @usage "Usage: h-daemon [-ne | --no-extensions] [--data-dir DIR] [--port PORT] [--check-config]"

  def main(args) do
    case parse(args) do
      :help ->
        IO.puts(@usage)

      {:ok, [{:check_config, true} | opts]} ->
        dir = Path.expand(opts[:data_dir] || System.get_env("H_DATA_DIR") || "~/.local/share/h")

        with {:ok, addresses} <- H.Daemon.Network.load(dir),
             result when result in [:ok, :disabled] <- web(:configure, addresses),
             {:ok, opts, _} <- H.Extensions.load(Keyword.put(opts, :data_dir, dir)),
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
          await_shutdown(ref, false, shutdown_timeout_ms())
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

  defp await_shutdown(ref, draining?, timeout_ms) do
    receive do
      msg when msg in [:shutdown_when_idle, :shutdown_drained] ->
        stop_cleanly()

      {:os_signal, :sigterm} when not draining? ->
        case initiate_drain() do
          {:ok, %{state: "stopping"}} ->
            await_shutdown(ref, true, timeout_ms)

          {:ok, %{state: "draining"}} ->
            timer = Process.send_after(self(), :drain_timeout, timeout_ms)

            try do
              await_shutdown(ref, true, timeout_ms)
            after
              Process.cancel_timer(timer)
            end

          _ ->
            stop_cleanly()
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

  defp shutdown_timeout_ms do
    case System.get_env("H_SHUTDOWN_TIMEOUT_MS") do
      nil ->
        300_000

      raw ->
        case Integer.parse(String.trim(raw)) do
          {ms, ""} when ms > 0 -> ms
          _ -> 300_000
        end
    end
  end

  # Core-only checkouts still run without Phoenix on their code path.
  defp web(action, addresses) do
    if Code.ensure_loaded?(HWeb.Standalone),
      do: apply(HWeb.Standalone, action, [addresses]),
      else: :ok
  end

  def parse(args) when args in [["-h"], ["--help"]], do: :help

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
end
