defmodule H.HTTP.UnixListener do
  @moduledoc false

  def child_spec({path, router_opts}) do
    %{id: :h_http_unix, start: {__MODULE__, :start_link, [path, router_opts]}, type: :supervisor}
  end

  # This child must be started after the store lock. Only replace a stale socket,
  # never a live listener, file, or symlink.
  def start_link(path, router_opts) do
    with :ok <- remove_stale_socket(path),
         {:ok, pid} <-
           Bandit.start_link(
             plug: {H.HTTP.Router, Keyword.put(router_opts, :unix_socket, true)},
             ip: {:local, path},
             port: 0
           ) do
      case File.chmod(path, 0o600) do
        :ok ->
          {:ok, pid}

        {:error, reason} ->
          Supervisor.stop(pid)
          {:error, reason}
      end
    end
  end

  defp remove_stale_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o170000) == 0o140000 ->
        case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 100) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            {:error, :eaddrinuse}

          {:error, reason} when reason in [:enoent, :econnrefused] ->
            File.rm(path)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _} ->
        {:error, :eexist}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
