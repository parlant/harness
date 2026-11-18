defmodule H.WorkspaceBrowserIntegrationTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon, StoreLock, Transcript, WorkspaceLease}
  alias H.Provider.Fake

  test "Slice 5 end-to-end: /api/v1/fs folder browser, AGENTS.md discovery, auto session_id + title, and Unix-socket + TCP dual-client sync" do
    {:ok, _} = Application.ensure_all_started(:req)
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-s5-#{id}")
    data_dir = Path.join(tmp_root, "data")
    projects_dir = Path.join(tmp_root, "projects")
    repo_dir = Path.join(projects_dir, "alpha-app")
    sub_dir = Path.join(repo_dir, "packages/core")

    File.mkdir_p!(data_dir)
    File.mkdir_p!(Path.join(repo_dir, ".git"))
    File.mkdir_p!(sub_dir)
    File.write!(Path.join(projects_dir, "AGENTS.md"), "Parent workspace rule: keep it simple.")
    File.write!(Path.join(repo_dir, "mix.exs"), "defmodule Alpha.MixProject, do: nil\n")
    File.write!(Path.join(repo_dir, "AGENTS.md"), "Repo rule: run mix test.")

    sock_path = H.api_socket_path(data_dir)

    on_exit(fn ->
      File.rm(sock_path)
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    registry = :"H.S5.Reg.#{id}"
    pubsub = :"H.S5.Pub.#{id}"
    catalog = :"H.S5.Cat.#{id}"
    catalog_table = :"h_s5_cat_#{id}"
    auth = :"H.S5.Auth.#{id}"
    auth_table = :"h_s5_auth_#{id}"
    lease = :"H.S5.Lease.#{id}"
    runtime_sup = :"H.S5.Sup.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.S5.Lock.#{id}"})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    fake =
      start_supervised!(
        {Fake,
         name: :"H.S5.Fake.#{id}",
         script: [
           {:expect,
            fn req ->
              sys = hd(req.messages)
              assert sys.role == "system"
              sys_text = hd(sys.content).text
              assert sys_text =~ "Parent workspace rule: keep it simple."
              assert sys_text =~ "Repo rule: run mix test."
              true
            end,
            {:reply,
             [
               %{type: :thinking_delta, text: "Inspecting alpha-app...", metadata: %{}},
               %{type: :text_delta, text: "Alpha ready!", metadata: %{}}
             ], %{content: [%{type: "text", text: "Alpha ready!"}], finish_reason: "stop"}}}
         ]}
      )

    daemon_opts = [
      data_dir: data_dir,
      default_cwd: projects_dir,
      stop_dir: projects_dir,
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      workspace_lease: lease,
      runtime_sup: runtime_sup,
      provider: Fake,
      provider_config: %{server: fake},
      storage_mod: H.Storage.File,
      storage_opts: [sync: :none],
      default_model: "fake:coder"
    ]

    router_opts = [
      auth_server: auth,
      auth_table: auth_table,
      daemon: Daemon,
      daemon_opts: daemon_opts,
      sse_keepalive_ms: 100
    ]

    tcp_pid =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {H.HTTP.Router, router_opts},
           ip: {127, 0, 0, 1},
           port: 0,
           thousand_island_options: [num_acceptors: 2, shutdown_timeout: 200]},
          id: :s5_tcp
        )
      )

    # A stale socket can be rebound without unlinking a live listener.
    {:ok, stale} = :gen_tcp.listen(0, ip: {:local, sock_path}, active: false)
    :ok = :gen_tcp.close(stale)
    start_supervised!({H.HTTP.UnixListener, {sock_path, router_opts}})
    assert Bitwise.band(File.stat!(sock_path).mode, 0o777) == 0o600
    assert {:error, :eaddrinuse} = H.HTTP.UnixListener.start_link(sock_path, router_opts)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(tcp_pid)
    base_url = "http://127.0.0.1:#{port}"
    token = Auth.owner_token(auth_table)
    bearer_headers = [{"authorization", "Bearer #{token}"}]

    # 1. Authenticate Web client over TCP cookie exchange
    auth_resp =
      Req.post!("#{base_url}/api/v1/auth/session",
        headers: [{"origin", base_url}],
        json: %{"token" => token}
      )

    [set_cookie] = Req.Response.get_header(auth_resp, "set-cookie")
    cookie_pair = set_cookie |> String.split(";", parts: 2) |> hd()
    web_headers = [{"cookie", cookie_pair}, {"origin", base_url}]

    # 2. Browse workspace via GET /api/v1/fs (before any session exists)
    fs0 = Req.get!("#{base_url}/api/v1/fs", headers: web_headers).body
    assert fs0["env_id"] == "host"
    assert fs0["path"] == Path.expand(projects_dir)
    [alpha_dir] = fs0["directories"]
    assert alpha_dir["name"] == "alpha-app"
    assert ".git" in alpha_dir["markers"]
    assert "mix.exs" in alpha_dir["markers"]
    assert "AGENTS.md" in alpha_dir["markers"]
    assert alpha_dir["direct_session_count"] == 0

    # 3. Create session from folder WITHOUT session_id (auto-minted slug + AGENTS.md discovery!)
    create_resp =
      Req.post!("#{base_url}/api/v1/sessions",
        headers: web_headers,
        json: %{"cwd" => repo_dir}
      )

    assert create_resp.status == 200
    minted_sid = create_resp.body["session"]["session_id"]
    assert String.starts_with?(minted_sid, "alpha-app-")
    assert create_resp.body["session"]["env_id"] == "host"
    assert create_resp.body["session"]["title"] == nil

    # 4. Attach BOTH Web client (TCP Cookie SSE) AND Cooperative TUI client (Unix Socket Bearer SSE)
    parent = self()

    web_sse =
      Task.async(fn ->
        Req.get!("#{base_url}/api/v1/sessions/#{minted_sid}/conversations/1/events",
          headers: [{"cookie", cookie_pair}],
          into: fn {:data, chunk}, {req, resp} ->
            send(parent, {:web_sse, chunk})
            {:cont, {req, resp}}
          end,
          receive_timeout: 5_000
        )
      end)

    tui_sse =
      Task.async(fn ->
        Req.get!("http://localhost/api/v1/sessions/#{minted_sid}/conversations/1/events",
          unix_socket: sock_path,
          headers: bearer_headers,
          into: fn {:data, chunk}, {req, resp} ->
            send(parent, {:tui_sse, chunk})
            {:cont, {req, resp}}
          end,
          receive_timeout: 5_000
        )
      end)

    assert_receive {:web_sse, web_init}, 1_000
    assert_receive {:tui_sse, tui_init}, 1_000
    assert web_init =~ "event: snapshot"
    assert tui_init =~ "event: snapshot"

    # 5. Submit prompt from TUI over Unix domain socket (`api.sock`)!
    tui_sub =
      Req.post!("http://localhost/api/v1/sessions/#{minted_sid}/commands",
        unix_socket: sock_path,
        headers: bearer_headers,
        json: %{
          "version" => 1,
          "request_id" => "tui-req-1",
          "command" => "submit",
          "conversation_id" => "1",
          "args" => %{
            "type" => "input",
            "content" => "Verify workspace rules and boot Alpha\nExtra details on line 2"
          }
        }
      )

    assert tui_sub.status == 200

    # Wait for run completion and verify auto-derived title + folder annotations + H.Transcript convergence
    wait_until(fn ->
      {:ok, [s]} = Daemon.list_sessions(%{"env_id" => "host", "cwd" => repo_dir}, daemon_opts)

      if s.title == "Verify workspace rules and boot Alpha" and s.active == false do
        s
      else
        nil
      end
    end)

    # Check GET /api/v1/fs annotations on parent projects_dir AND GET /api/v1/sessions?cwd=... over Unix socket!
    fs1 =
      Req.get!("http://localhost/api/v1/fs",
        unix_socket: sock_path,
        headers: bearer_headers
      ).body

    [annotated_alpha] = fs1["directories"]
    assert annotated_alpha["direct_session_count"] == 1
    assert annotated_alpha["subtree_session_count"] == 1
    assert annotated_alpha["latest_session"]["session_id"] == minted_sid
    assert annotated_alpha["latest_session"]["title"] == "Verify workspace rules and boot Alpha"

    pwd_sessions =
      Req.get!("http://localhost/api/v1/sessions",
        unix_socket: sock_path,
        headers: bearer_headers,
        params: [env_id: "host", cwd: repo_dir]
      ).body["sessions"]

    assert [
             %{
               "session_id" => ^minted_sid,
               "title" => "Verify workspace rules and boot Alpha"
             }
           ] = pwd_sessions

    # Fold SSE streams from both Web and TUI through H.Transcript and prove identical convergence!
    web_t = fold_sse_chunks([web_init | drain_chunks(:web_sse, [])], Transcript.new())
    tui_t = fold_sse_chunks([tui_init | drain_chunks(:tui_sse, [])], Transcript.new())

    assert web_t.seq == tui_t.seq
    assert length(web_t.entries) == 2
    assert web_t.entries == tui_t.entries
    assert web_t.docs == tui_t.docs

    Task.shutdown(web_sse, :brutal_kill)
    Task.shutdown(tui_sse, :brutal_kill)

    # An existing catalog entry must not silently run against the host filesystem
    # when its configured execution environment is absent.
    {:ok, _} =
      Catalog.put_session(catalog, %{session_id: "offline-vm", cwd: repo_dir, env_id: "vm"})

    assert {:error, :workspace_unavailable} = Daemon.get_session_detail("offline-vm", daemon_opts)
  end

  defp fold_sse_chunks(chunks, transcript) do
    raw = Enum.join(chunks, "")

    raw
    |> String.split("\n\n", trim: true)
    |> Enum.reduce(transcript, fn block, acc ->
      lines = String.split(block, "\n", trim: true)
      event = find_sse_field(lines, "event:")
      data = find_sse_field(lines, "data:")

      case {event, data} do
        {"snapshot", bin} when is_binary(bin) ->
          {:ok, next} = Transcript.apply_snapshot(acc, bin)
          next

        {"commit", bin} when is_binary(bin) ->
          case Transcript.apply_commit(acc, bin) do
            {:ok, next, _} -> next
            _ -> acc
          end

        {"ephemeral", bin} when is_binary(bin) ->
          case Transcript.apply_ephemeral(acc, bin) do
            {:ok, next} -> next
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp find_sse_field(lines, prefix) do
    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, prefix) do
        line |> String.replace_prefix(prefix, "") |> String.trim()
      end
    end)
  end

  defp drain_chunks(tag, acc) do
    receive do
      {^tag, chunk} -> drain_chunks(tag, [chunk | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp wait_until(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if res = fun.() do
      res
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for condition")
      else
        Process.sleep(15)
        do_wait_until(fun, deadline)
      end
    end
  end
end
