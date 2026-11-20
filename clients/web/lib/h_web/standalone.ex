defmodule HWeb.Standalone do
  @moduledoc "Web listeners for the bundled daemon, sharing one Phoenix endpoint."

  @behaviour Plug
  import Plug.Conn

  def configure(addresses) do
    if System.get_env("H_WEB") == "0" do
      :disabled
    else
      case Integer.parse(System.get_env("H_WEB_PORT", "4200")) do
        {port, ""} when port in 0..65_535 ->
          config = Application.get_env(:harness_web, HWeb.Endpoint, [])
          host = addresses |> hd() |> :inet.ntoa() |> to_string()

          Application.put_env(
            :harness_web,
            HWeb.Endpoint,
            Keyword.merge(config,
              server: false,
              standalone_listeners: for(ip <- addresses, do: {ip, port}),
              url: [host: host, port: port],
              check_origin: :conn,
              secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
            )
          )

          :ok

        _ ->
          {:error, :invalid_web_port}
      end
    end
  end

  def start(addresses) do
    with :ok <- configure(addresses),
         {:ok, _} <- Application.ensure_all_started(:harness_web) do
      for {{__MODULE__, _}, pid, _, _} <- Supervisor.which_children(HWeb.Supervisor) do
        {:ok, {ip, port}} = ThousandIsland.listener_info(pid)
        IO.puts("H web listening at http://#{:inet.ntoa(ip)}:#{port}/inbox")
      end

      :ok
    else
      :disabled -> :ok
      {:error, _} = error -> error
    end
  end

  def listeners do
    for {ip, port} <-
          Application.get_env(:harness_web, HWeb.Endpoint, [])[:standalone_listeners] || [] do
      Supervisor.child_spec(
        {Bandit, plug: {__MODULE__, ip}, display_plug: HWeb.Endpoint, ip: ip, port: port},
        id: {__MODULE__, ip}
      )
    end
  end

  @impl Plug
  def init(ip), do: [bind_address: ip, allow_localhost: ip == {127, 0, 0, 1}]

  @impl Plug
  def call(conn, opts) do
    %{port: port} = get_sock_data(conn)

    # Validate the effective authority before Phoenix dispatches HTTP or sockets.
    if H.Auth.allowed_host?("#{conn.host}:#{conn.port}", port, opts) do
      HWeb.Endpoint.call(conn, [])
    else
      conn |> send_resp(421, "invalid host header") |> halt()
    end
  end
end
