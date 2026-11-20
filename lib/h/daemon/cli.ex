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

        with {:ok, addresses} <- H.Daemon.Network.load(dir),
             :ok <- web(:start, addresses),
             {:ok, _} <-
               H.serve(opts ++ [data_dir: dir, bind_addresses: addresses, shutdown_owner: self()]) do
          ref = Process.monitor(H.Daemon.Instance)

          receive do
            :shutdown_when_idle ->
              Application.stop(:harness_web)
              :ok = Supervisor.terminate_child(H.Supervisor, H.Daemon.Instance)
              System.stop(0)

            {:DOWN, ^ref, :process, _, _} ->
              System.stop(1)
          end
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
