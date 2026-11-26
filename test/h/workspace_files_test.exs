defmodule H.WorkspaceFilesTest do
  use ExUnit.Case, async: false

  alias H.{Auth, Catalog, Daemon, RemoteAgent, StoreLock}
  alias H.ExecutionEnv.{Host, Remote}
  alias H.HTTP.Router

  setup_all do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defp setup_env(_ctx) do
    id = System.unique_integer([:positive, :monotonic])
    tmp_root = Path.join("/private/tmp", "h-ws-files-#{id}")
    data_dir = Path.join(tmp_root, "data")
    host_ws = Path.join(tmp_root, "host_ws")
    sibling_ws = Path.join(tmp_root, "host_ws2")
    outside_dir = Path.join(tmp_root, "outside")
    remote_ws = Path.join(tmp_root, "remote_ws")

    for dir <- [data_dir, host_ws, sibling_ws, outside_dir, remote_ws] do
      File.mkdir_p!(dir)
    end

    File.chmod!(data_dir, 0o700)

    # Host workspace fixture
    File.mkdir_p!(Path.join(host_ws, ".git"))
    File.write!(Path.join(host_ws, ".git/HEAD"), "ref: refs/heads/main\n")
    File.mkdir_p!(Path.join(host_ws, ".hidden"))
    File.write!(Path.join(host_ws, ".hidden/env.txt"), "SECRET=1\n")
    File.mkdir_p!(Path.join(host_ws, "lib/nested"))
    File.write!(Path.join(host_ws, "README.md"), "Host README\nLine 2\nLine 3\n")
    File.write!(Path.join(host_ws, "lib/app.ex"), "defmodule HostApp do\nend\n")
    File.write!(Path.join(host_ws, "lib/nested/util.ex"), "defmodule HostUtil do\nend\n")
    File.write!(Path.join(host_ws, "bin.dat"), <<0, 1, 2, 3>>)
    File.write!(Path.join(host_ws, "bad_utf8.txt"), <<0xFF, 0xFE, "nope">>)

    # Prefix-collision sibling and outside secret fixtures
    File.write!(Path.join(sibling_ws, "secret.txt"), "sibling-secret\n")
    File.write!(Path.join(outside_dir, "secret.txt"), "outside-secret\n")
    File.mkdir_p!(Path.join(outside_dir, "sub"))
    File.write!(Path.join(outside_dir, "sub/nested.txt"), "outside-nested\n")

    # Symlinks inside host_ws (escaping, local, broken, and loop)
    File.ln_s!(Path.join(host_ws, "README.md"), Path.join(host_ws, "readme_link.md"))
    File.ln_s!(Path.join(outside_dir, "secret.txt"), Path.join(host_ws, "file_escape.txt"))
    File.ln_s!(outside_dir, Path.join(host_ws, "dir_escape"))
    File.ln_s!(Path.join(outside_dir, "missing.txt"), Path.join(host_ws, "broken_escape.txt"))
    File.ln_s!(Path.join(host_ws, "loop_b"), Path.join(host_ws, "loop_a"))
    File.ln_s!(Path.join(host_ws, "loop_a"), Path.join(host_ws, "loop_b"))

    # Remote workspace fixture (completely distinct files from host_ws)
    File.mkdir_p!(Path.join(remote_ws, "src"))
    File.write!(Path.join(remote_ws, "README.md"), "Remote VM README\n")
    File.write!(Path.join(remote_ws, "src/server.ex"), "defmodule RemoteServer do\nend\n")
    File.ln_s!(Path.join(outside_dir, "secret.txt"), Path.join(remote_ws, "vm_escape.txt"))
    File.ln_s!(outside_dir, Path.join(remote_ws, "vm_dir_escape"))

    sock_path = H.api_socket_path(data_dir)

    on_exit(fn ->
      File.rm(sock_path)
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    catalog = :"H.WsFiles.Cat.#{id}"
    catalog_table = :"h_ws_files_cat_#{id}"
    auth = :"H.WsFiles.Auth.#{id}"
    auth_table = :"h_ws_files_auth_#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.WsFiles.Lock.#{id}"})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})

    remote_base_env = Host.new(remote_ws, env_id: "vm-1")
    remote_agent = start_supervised!({RemoteAgent, env: remote_base_env, id: "vm-1"})

    environments = %{
      "host" => %{kind: "host", label: "Local Host", default_cwd: host_ws},
      "vm-1" => %{
        kind: "remote",
        label: "Remote VM 1",
        default_cwd: remote_ws,
        build: fn cwd -> Remote.new(remote_agent, cwd, env_id: "vm-1") end
      }
    }

    daemon_opts = [
      data_dir: data_dir,
      catalog: catalog,
      catalog_table: catalog_table,
      environments: environments
    ]

    router_opts = [
      auth_server: auth,
      auth_table: auth_table,
      daemon: Daemon,
      daemon_opts: daemon_opts
    ]

    tcp_pid =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {Router, router_opts},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [shutdown_timeout: 50]},
          id: :"ws_tcp_#{id}"
        )
      )

    start_supervised!({H.HTTP.UnixListener, {sock_path, router_opts}})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(tcp_pid)
    token = Auth.owner_token(auth_table)

    {:ok,
     %{
       tmp_root: tmp_root,
       host_ws: host_ws,
       sibling_ws: sibling_ws,
       outside_dir: outside_dir,
       remote_ws: remote_ws,
       remote_agent: remote_agent,
       catalog: catalog,
       catalog_table: catalog_table,
       daemon_opts: daemon_opts,
       router_opts: router_opts,
       base_url: "http://127.0.0.1:#{port}",
       port: port,
       sock_path: sock_path,
       token: token
     }}
  end

  setup :setup_env

  describe "Daemon.list_files/2 and Daemon.read_file/2 scoping and bounds" do
    test "requires explicit env_id and absolute cwd and never falls back to local cwd", ctx do
      assert {:error, {:bad_request, "env_id is required"}} =
               Daemon.list_files(%{"cwd" => ctx.host_ws}, ctx.daemon_opts)

      assert {:error, {:bad_request, "env_id is required"}} =
               Daemon.list_files(%{"env_id" => "", "cwd" => ctx.host_ws}, ctx.daemon_opts)

      assert {:error, {:bad_request, "cwd must be an absolute path"}} =
               Daemon.list_files(%{"env_id" => "host"}, ctx.daemon_opts)

      assert {:error, {:bad_request, "cwd must be an absolute path"}} =
               Daemon.list_files(%{"env_id" => "host", "cwd" => "."}, ctx.daemon_opts)

      assert {:error, {:bad_request, "cwd must be an absolute path"}} =
               Daemon.read_file(%{"env_id" => "host", "path" => "mix.exs"}, ctx.daemon_opts)

      assert {:error, :unknown_environment} =
               Daemon.list_files(%{"env_id" => "nope", "cwd" => ctx.host_ws}, ctx.daemon_opts)

      assert {:error, :unknown_environment} =
               Daemon.read_file(
                 %{"env_id" => "nope", "cwd" => ctx.host_ws, "path" => "README.md"},
                 ctx.daemon_opts
               )
    end

    test "separates local host and remote vm environments cleanly", ctx do
      assert {:ok, host_files} =
               Daemon.list_files(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "include_dirs" => "false"},
                 ctx.daemon_opts
               )

      assert host_files.env_id == "host"
      assert host_files.cwd == ctx.host_ws
      host_paths = Enum.map(host_files.entries, & &1.path)
      assert "README.md" in host_paths
      assert "lib/app.ex" in host_paths
      refute "src/server.ex" in host_paths
      refute Enum.any?(host_paths, &String.starts_with?(&1, ".git"))
      refute Enum.any?(host_paths, &String.starts_with?(&1, ".hidden"))

      assert {:ok, vm_files} =
               Daemon.list_files(
                 %{"env_id" => "vm-1", "cwd" => ctx.remote_ws, "include_dirs" => "false"},
                 ctx.daemon_opts
               )

      assert vm_files.env_id == "vm-1"
      assert vm_files.cwd == ctx.remote_ws
      vm_paths = Enum.map(vm_files.entries, & &1.path)
      assert "README.md" in vm_paths
      assert "src/server.ex" in vm_paths
      refute "lib/app.ex" in vm_paths

      assert {:ok, host_readme} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "README.md"},
                 ctx.daemon_opts
               )

      assert host_readme.env_id == "host"
      assert host_readme.lines == ["Host README", "Line 2", "Line 3"]

      assert {:ok, vm_readme} =
               Daemon.read_file(
                 %{"env_id" => "vm-1", "cwd" => ctx.remote_ws, "path" => "README.md"},
                 ctx.daemon_opts
               )

      assert vm_readme.env_id == "vm-1"
      assert vm_readme.lines == ["Remote VM README"]
    end

    test "returns :workspace_unavailable when remote agent stops without falling back to host",
         ctx do
      # Stop the remote agent while keeping host_ws valid on local disk
      GenServer.stop(ctx.remote_agent)

      assert {:error, :workspace_unavailable} =
               Daemon.list_files(
                 %{"env_id" => "vm-1", "cwd" => ctx.host_ws},
                 ctx.daemon_opts
               )

      assert {:error, :workspace_unavailable} =
               Daemon.read_file(
                 %{"env_id" => "vm-1", "cwd" => ctx.host_ws, "path" => "README.md"},
                 ctx.daemon_opts
               )

      assert {:error, :workspace_unavailable} =
               Daemon.browse_workspace(
                 %{"env_id" => "vm-1", "path" => ctx.host_ws},
                 ctx.daemon_opts
               )
    end

    test "enforces bounded discovery and bounded line/byte reads", ctx do
      assert {:ok, page} =
               Daemon.list_files(
                 %{
                   "env_id" => "host",
                   "cwd" => ctx.host_ws,
                   "include_dirs" => "false",
                   "limit" => "2"
                 },
                 ctx.daemon_opts
               )

      assert length(page.entries) == 2
      assert page.truncated == true

      assert {:ok, read_page} =
               Daemon.read_file(
                 %{
                   "env_id" => "host",
                   "cwd" => ctx.host_ws,
                   "path" => "README.md",
                   "offset" => "2",
                   "limit" => "1"
                 },
                 ctx.daemon_opts
               )

      assert read_page.lines == ["Line 2"]
      assert read_page.start_line == 2
      assert read_page.total_lines_read == 1
      assert read_page.has_more == true
      assert read_page.truncated_by_bytes == false
    end
  end

  describe "workspace containment and read policy" do
    test "blocks path traversal, sibling prefix collisions, tilde paths, and symlink escapes on host and remote",
         ctx do
      sibling_secret = Path.join(ctx.sibling_ws, "secret.txt")
      outside_secret = Path.join(ctx.outside_dir, "secret.txt")

      for {env_id, cwd} <- [{"host", ctx.host_ws}, {"vm-1", ctx.remote_ws}] do
        for bad_path <- [
              "../outside/secret.txt",
              "sub/../../outside/secret.txt",
              outside_secret,
              sibling_secret,
              "/nonexistent/outside/path",
              "~",
              "~/secret.txt"
            ] do
          assert {:error, {:forbidden, "path outside workspace"}} =
                   Daemon.read_file(
                     %{"env_id" => env_id, "cwd" => cwd, "path" => bad_path},
                     ctx.daemon_opts
                   )
        end
      end

      # Symlink file (even local target) and escaping symlink dir on host
      assert {:error, {:forbidden, "symlinks are not followed"}} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "readme_link.md"},
                 ctx.daemon_opts
               )

      assert {:error, {:forbidden, "path outside workspace"}} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "file_escape.txt"},
                 ctx.daemon_opts
               )

      assert {:error, {:forbidden, "symlinks are not followed"}} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "broken_escape.txt"},
                 ctx.daemon_opts
               )

      assert {:error, {:forbidden, "path outside workspace"}} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "dir_escape/secret.txt"},
                 ctx.daemon_opts
               )

      assert {:error, {:forbidden, "path outside workspace"}} =
               Daemon.read_file(
                 %{
                   "env_id" => "host",
                   "cwd" => ctx.host_ws,
                   "path" => "dir_escape/missing_sub/file.txt"
                 },
                 ctx.daemon_opts
               )

      assert {:error, {:forbidden, "symlink loop detected"}} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "loop_a"},
                 ctx.daemon_opts
               )

      # Escaping symlinks on remote VM
      assert {:error, {:forbidden, "path outside workspace"}} =
               Daemon.read_file(
                 %{"env_id" => "vm-1", "cwd" => ctx.remote_ws, "path" => "vm_escape.txt"},
                 ctx.daemon_opts
               )

      assert {:error, {:forbidden, "path outside workspace"}} =
               Daemon.read_file(
                 %{
                   "env_id" => "vm-1",
                   "cwd" => ctx.remote_ws,
                   "path" => "vm_dir_escape/sub/nested.txt"
                 },
                 ctx.daemon_opts
               )
    end

    test "rejects directories, binary/non-UTF-8 files, missing files, and FIFOs", ctx do
      assert {:error, {:bad_request, "path is a directory"}} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "."},
                 ctx.daemon_opts
               )

      assert {:error, {:bad_request, "path is a directory"}} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "lib"},
                 ctx.daemon_opts
               )

      assert {:error, {:bad_request, "binary or invalid UTF-8 file"}} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "bin.dat"},
                 ctx.daemon_opts
               )

      assert {:error, {:bad_request, "binary or invalid UTF-8 file"}} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "bad_utf8.txt"},
                 ctx.daemon_opts
               )

      assert {:error, :not_found} =
               Daemon.read_file(
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "lib/missing.ex"},
                 ctx.daemon_opts
               )

      case System.find_executable("mkfifo") do
        nil ->
          :ok

        mkfifo ->
          fifo = Path.join(ctx.host_ws, "pipe.fifo")
          {_, 0} = System.cmd(mkfifo, [fifo])

          assert {:error, {:bad_request, "path is not a regular file"}} =
                   Daemon.read_file(
                     %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "pipe.fifo"},
                     ctx.daemon_opts
                   )
      end
    end
  end

  describe "session-scoped discovery and read" do
    test "uses authoritative catalog {env_id, cwd} and rejects overrides or missing envs", ctx do
      {:ok, _} =
        Catalog.put_session(ctx.catalog, %{
          session_id: "sess-vm",
          env_id: "vm-1",
          cwd: ctx.remote_ws
        })

      {:ok, _} =
        Catalog.put_session(ctx.catalog, %{
          session_id: "sess-offline-env",
          env_id: "missing-vm",
          cwd: ctx.host_ws
        })

      {:ok, _} =
        Catalog.put_session(ctx.catalog, %{
          session_id: "sess-quarantined",
          env_id: "host",
          cwd: ctx.host_ws,
          status: "quarantined",
          quarantine_reason: "corrupt"
        })

      # Attempted query override of env_id/cwd is ignored; stays bound to vm-1 + remote_ws
      assert {:ok, files} =
               Daemon.list_session_files(
                 "sess-vm",
                 %{
                   "env_id" => "host",
                   "cwd" => ctx.host_ws,
                   "include_dirs" => "false"
                 },
                 ctx.daemon_opts
               )

      assert files.env_id == "vm-1"
      assert files.cwd == ctx.remote_ws
      assert Enum.any?(files.entries, &(&1.path == "src/server.ex"))
      refute Enum.any?(files.entries, &(&1.path == "lib/app.ex"))

      assert {:ok, file_resp} =
               Daemon.read_session_file(
                 "sess-vm",
                 %{"env_id" => "host", "cwd" => ctx.host_ws, "path" => "README.md"},
                 ctx.daemon_opts
               )

      assert file_resp.env_id == "vm-1"
      assert file_resp.lines == ["Remote VM README"]

      assert {:error, :workspace_unavailable} =
               Daemon.list_session_files("sess-offline-env", %{}, ctx.daemon_opts)

      assert {:error, :workspace_unavailable} =
               Daemon.read_session_file(
                 "sess-offline-env",
                 %{"path" => "README.md"},
                 ctx.daemon_opts
               )

      assert {:error, {:quarantined, "corrupt"}} =
               Daemon.list_session_files("sess-quarantined", %{}, ctx.daemon_opts)

      assert {:error, :not_found} =
               Daemon.list_session_files("does-not-exist", %{}, ctx.daemon_opts)
    end
  end

  describe "HTTP auth, Host guard, Unix socket, and policy status mapping" do
    test "reports native folder timeouts and denials without blocking catalog storage", ctx do
      helper = Path.join(ctx.host_ws, "native-helper")
      previous = System.get_env("H_FS_EXECUTABLE")
      System.put_env("H_FS_EXECUTABLE", helper)

      on_exit(fn ->
        if previous,
          do: System.put_env("H_FS_EXECUTABLE", previous),
          else: System.delete_env("H_FS_EXECUTABLE")
      end)

      for {error, status, message} <- [
            {"timeout", 503, "Folder access timed out"},
            {"eperm", 403, "Folder access denied"}
          ] do
        File.write!(helper, "#!/bin/sh\nprintf '%s' '{\"error\":\"#{error}\"}'\n")
        File.chmod!(helper, 0o700)

        response =
          Req.get!("#{ctx.base_url}/api/v1/fs/files",
            headers: [{"authorization", "Bearer #{ctx.token}"}],
            params: [env_id: "host", cwd: ctx.host_ws],
            retry: false
          )

        assert response.status == status
        assert response.body["error"] =~ message
        assert response.body["error"] =~ "Permissions & Setup"

        assert {:ok, _} =
                 Catalog.put_session(ctx.catalog, %{
                   session_id: "after-#{error}",
                   cwd: ctx.host_ws
                 })
      end
    end

    test "enforces Host header, Bearer/Cookie auth, read-only methods, and status codes over TCP and UDS",
         ctx do
      {:ok, _} =
        Catalog.put_session(ctx.catalog, %{
          session_id: "http-vm",
          env_id: "vm-1",
          cwd: ctx.remote_ws
        })

      auth = [{"authorization", "Bearer #{ctx.token}"}]

      # 1. Host header anti-DNS-rebinding (421)
      bad_host =
        Req.get!("#{ctx.base_url}/api/v1/fs/files",
          headers: [{"host", "evil.example:#{ctx.port}"} | auth],
          params: [env_id: "host", cwd: ctx.host_ws],
          retry: false
        )

      assert bad_host.status == 421

      # 2. Unauthenticated rejected (401)
      for path <- [
            "/api/v1/fs/files?env_id=host&cwd=#{URI.encode_www_form(ctx.host_ws)}",
            "/api/v1/fs/file?env_id=host&cwd=#{URI.encode_www_form(ctx.host_ws)}&path=README.md",
            "/api/v1/sessions/http-vm/files",
            "/api/v1/sessions/http-vm/file?path=README.md"
          ] do
        assert Req.get!("#{ctx.base_url}#{path}", retry: false).status == 401

        assert Req.get!("#{ctx.base_url}#{path}",
                 headers: [{"authorization", "Bearer bad"}],
                 retry: false
               ).status == 401
      end

      # 3. Cookie auth works for GET; mutating POST is rejected
      auth_resp =
        Req.post!("#{ctx.base_url}/api/v1/auth/session",
          headers: [{"origin", ctx.base_url}],
          json: %{"token" => ctx.token},
          retry: false
        )

      [set_cookie] = Req.Response.get_header(auth_resp, "set-cookie")
      cookie_pair = set_cookie |> String.split(";", parts: 2) |> hd()

      cookie_get =
        Req.get!("#{ctx.base_url}/api/v1/sessions/http-vm/file",
          headers: [{"cookie", cookie_pair}],
          params: [path: "src/server.ex"],
          retry: false
        )

      assert cookie_get.status == 200
      assert cookie_get.body["env_id"] == "vm-1"
      assert cookie_get.body["lines"] == ["defmodule RemoteServer do", "end"]

      cookie_post_no_origin =
        Req.post!("#{ctx.base_url}/api/v1/fs/files",
          headers: [{"cookie", cookie_pair}],
          json: %{"env_id" => "host", "cwd" => ctx.host_ws},
          retry: false
        )

      assert cookie_post_no_origin.status == 403

      bearer_post =
        Req.post!("#{ctx.base_url}/api/v1/fs/files",
          headers: auth,
          json: %{"env_id" => "host", "cwd" => ctx.host_ws},
          retry: false
        )

      assert bearer_post.status == 404

      # 4. Policy and validation status mapping over TCP
      assert Req.get!("#{ctx.base_url}/api/v1/fs/file",
               headers: auth,
               params: [env_id: "host", cwd: ctx.host_ws, path: "../outside/secret.txt"],
               retry: false
             ).status == 403

      assert Req.get!("#{ctx.base_url}/api/v1/fs/file",
               headers: auth,
               params: [env_id: "host", cwd: ctx.host_ws, path: "readme_link.md"],
               retry: false
             ).status == 403

      assert Req.get!("#{ctx.base_url}/api/v1/fs/file",
               headers: auth,
               params: [env_id: "host", cwd: ctx.host_ws, path: "missing.txt"],
               retry: false
             ).status == 404

      assert Req.get!("#{ctx.base_url}/api/v1/fs/files",
               headers: auth,
               params: [env_id: "unknown", cwd: ctx.host_ws],
               retry: false
             ).status == 404

      assert Req.get!("#{ctx.base_url}/api/v1/fs/files",
               headers: auth,
               params: [env_id: "host", cwd: "relative/dir"],
               retry: false
             ).status == 422

      assert Req.get!("#{ctx.base_url}/api/v1/fs/file",
               headers: auth,
               params: [env_id: "host", cwd: ctx.host_ws, path: "bin.dat"],
               retry: false
             ).status == 422

      for bad_params <- [
            [env_id: "host", cwd: ctx.host_ws, limit: 0],
            [env_id: "host", cwd: ctx.host_ws, limit: 501],
            [env_id: "host", cwd: ctx.host_ws, max_depth: 33],
            [env_id: "host", cwd: ctx.host_ws, include_hidden: "maybe"],
            [env_id: "host", cwd: ctx.host_ws, include_dirs: "maybe"],
            [env_id: "host", cwd: ctx.host_ws, exclude: "a/b"],
            [env_id: "host", cwd: ctx.host_ws, query: String.duplicate("a", 513)]
          ] do
        assert Req.get!("#{ctx.base_url}/api/v1/fs/files",
                 headers: auth,
                 params: bad_params,
                 retry: false
               ).status == 422
      end

      for bad_read_params <- [
            [env_id: "host", cwd: ctx.host_ws, path: "README.md", offset: 0],
            [env_id: "host", cwd: ctx.host_ws, path: "README.md", limit: 2001],
            [env_id: "host", cwd: ctx.host_ws, path: "README.md", max_bytes: 65_537]
          ] do
        assert Req.get!("#{ctx.base_url}/api/v1/fs/file",
                 headers: auth,
                 params: bad_read_params,
                 retry: false
               ).status == 422
      end

      # 5. Unix domain socket parity for both local and remote environments
      uds_files =
        Req.get!("http://localhost/api/v1/fs/files",
          unix_socket: ctx.sock_path,
          headers: auth,
          params: [env_id: "vm-1", cwd: ctx.remote_ws, query: "server", include_dirs: "false"],
          retry: false
        )

      assert uds_files.status == 200
      assert uds_files.body["env_id"] == "vm-1"
      assert [%{"path" => "src/server.ex", "type" => "file"}] = uds_files.body["entries"]

      uds_session_file =
        Req.get!("http://localhost/api/v1/sessions/http-vm/file",
          unix_socket: ctx.sock_path,
          headers: auth,
          params: [path: "README.md"],
          retry: false
        )

      assert uds_session_file.status == 200
      assert uds_session_file.body["lines"] == ["Remote VM README"]

      # 6. Offline remote agent -> 503 workspace_unavailable (never falls back to host)
      GenServer.stop(ctx.remote_agent)

      offline_resp =
        Req.get!("http://localhost/api/v1/sessions/http-vm/files",
          unix_socket: ctx.sock_path,
          headers: auth,
          retry: false
        )

      assert offline_resp.status == 503
      assert offline_resp.body == %{"error" => "workspace_unavailable"}
    end
  end
end
