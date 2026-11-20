defmodule H.Application do
  @moduledoc """
  OTP application entry point. Embedded hosts can opt into the same daemon
  instance as `H.serve/1` by configuring `:harness, :data_dir`.
  """
  use Application

  @impl true
  def start(_type, args) do
    Supervisor.start_link(children(args),
      strategy: :one_for_one,
      max_restarts: 0,
      name: H.Supervisor
    )
  end

  @doc false
  def children(args \\ []) do
    data_dir = Keyword.get(args, :data_dir) || Application.get_env(:harness, :data_dir)

    daemon? =
      Keyword.get(
        args,
        :daemon,
        Application.get_env(:harness, :start_daemon, not is_nil(data_dir))
      )

    if daemon? and is_binary(data_dir) do
      embedded_opts = [
        data_dir: data_dir,
        api_socket: Application.get_env(:harness, :api_socket, false),
        http_port: Application.get_env(:harness, :http_port),
        no_extensions: Application.get_env(:harness, :no_extensions, false)
      ]

      args =
        if Keyword.has_key?(args, :auth),
          do: Keyword.put_new(args, :auth_server, args[:auth]),
          else: args

      [{H.Daemon.Instance, Keyword.merge(embedded_opts, args)}]
    else
      []
    end
  end
end
