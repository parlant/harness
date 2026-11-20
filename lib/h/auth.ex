defmodule H.Auth do
  @moduledoc """
  Owner bearer token and browser session cookie manager backed by a `:protected`
  ETS table and `<data_dir>/auth.token` (`0600`).

  Provides constant-time token/cookie verification via `Plug.Crypto.secure_compare/2`
  and strict `Host` / `Origin` checks against DNS rebinding and CSRF.
  """

  use GenServer

  @default_table :h_auth
  @max_cookies 64

  @doc """
  Starts the auth manager.

  Options:
    * `:data_dir` (required) - root storage directory holding `auth.token`
    * `:name` - GenServer registration name (default `H.Auth`, pass `nil` for unnamed)
    * `:table` - ETS table name (default `:h_auth`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    _data_dir = Keyword.fetch!(opts, :data_dir)
    gen_opts = if name = Keyword.get(opts, :name, __MODULE__), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns the current owner token from ETS.
  """
  @spec owner_token(atom()) :: String.t()
  def owner_token(table \\ @default_table) do
    :ets.lookup_element(table, :owner_token, 2)
  end

  @doc """
  Constant-time comparison of `candidate` against the stored owner token.
  """
  @spec verify_bearer(term(), atom()) :: boolean()
  def verify_bearer(candidate, table \\ @default_table)

  def verify_bearer(candidate, table) when is_binary(candidate) do
    Plug.Crypto.secure_compare(candidate, owner_token(table))
  end

  def verify_bearer(_candidate, _table), do: false

  @doc """
  Verifies `owner_token_candidate` in constant time and, if valid, mints a fresh
  32-byte browser session cookie stored in ETS.
  """
  @spec create_browser_session(term(), GenServer.server(), atom()) ::
          {:ok, String.t()} | {:error, :unauthorized}
  def create_browser_session(owner_token_candidate, server \\ __MODULE__, table \\ @default_table) do
    if verify_bearer(owner_token_candidate, table) do
      GenServer.call(server, :create_browser_session)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Constant-time comparison of `cookie_candidate` against active browser session cookies.
  """
  @spec verify_cookie(term(), atom()) :: boolean()
  def verify_cookie(cookie_candidate, table \\ @default_table)

  def verify_cookie(cookie_candidate, table) when is_binary(cookie_candidate) do
    table
    |> :ets.match({{:cookie, :"$1"}, :_})
    |> Enum.reduce(false, fn [stored], matched? ->
      if Plug.Crypto.secure_compare(cookie_candidate, stored), do: true, else: matched?
    end)
  end

  def verify_cookie(_cookie_candidate, _table), do: false

  @doc """
  Validates the HTTP `Host` header against the listener's literal `:bind_address`
  (defaults to loopback literals when omitted). Pass `allow_localhost: true`
  to additionally allow `localhost:<port>`.
  """
  @spec allowed_host?(term(), pos_integer(), keyword()) :: boolean()
  def allowed_host?(host_header, port, opts \\ [])

  def allowed_host?(host_header, port, opts)
      when is_binary(host_header) and is_integer(port) and port > 0 and is_list(opts) do
    hosts =
      case opts[:bind_address] do
        nil -> ["127.0.0.1", "[::1]"]
        ip -> [to_string(:inet.ntoa(ip))]
      end

    hosts = if opts[:allow_localhost], do: ["localhost" | hosts], else: hosts
    Enum.any?(hosts, &(host_header == "#{&1}:#{port}"))
  end

  def allowed_host?(_host_header, _port, _opts), do: false

  @doc """
  Validates the HTTP `Origin` as an HTTP URL using the same host policy as `allowed_host?/3`.
  """
  @spec allowed_origin?(term(), pos_integer(), keyword()) :: boolean()
  def allowed_origin?(origin_header, port, opts \\ [])

  def allowed_origin?("http://" <> host, port, opts), do: allowed_host?(host, port, opts)

  def allowed_origin?(_origin_header, _port, _opts), do: false

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir) |> Path.expand()
    table_name = Keyword.get(opts, :table, @default_table)

    File.mkdir_p!(data_dir)
    File.chmod!(data_dir, 0o700)

    token_path = Path.join(data_dir, "auth.token")
    token = load_or_create_token!(token_path)

    table = :ets.new(table_name, [:set, :protected, :named_table, read_concurrency: true])
    :ets.insert(table, {:owner_token, token})

    {:ok, %{table: table, token_path: token_path, cookie_order: :queue.new()}}
  end

  @impl true
  def handle_call(:create_browser_session, _from, state) do
    cookie = generate_secret()
    :ets.insert(state.table, {{:cookie, cookie}, true})

    cookie_order = :queue.in(cookie, state.cookie_order)

    cookie_order =
      if :queue.len(cookie_order) > @max_cookies do
        {{:value, oldest}, rest} = :queue.out(cookie_order)
        :ets.delete(state.table, {:cookie, oldest})
        rest
      else
        cookie_order
      end

    {:reply, {:ok, cookie}, %{state | cookie_order: cookie_order}}
  end

  defp load_or_create_token!(token_path) do
    case File.read(token_path) do
      {:ok, content} ->
        token = String.trim(content)

        if token == "" do
          write_new_token!(token_path)
        else
          File.chmod!(token_path, 0o600)
          token
        end

      {:error, :enoent} ->
        write_new_token!(token_path)
    end
  end

  defp write_new_token!(token_path) do
    token = generate_secret()
    tmp_path = token_path <> ".tmp"
    File.write!(tmp_path, token <> "\n")
    File.chmod!(tmp_path, 0o600)
    File.rename!(tmp_path, token_path)
    token
  end

  defp generate_secret do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
