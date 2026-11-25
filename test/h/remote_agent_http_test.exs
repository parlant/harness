defmodule H.RemoteAgent.HTTPTest do
  use ExUnit.Case, async: false

  alias H.ExecutionEnv
  alias H.ExecutionEnv.Remote
  alias H.RemoteAgent
  alias H.RemoteAgent.{Client, HTTP}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defmodule ConformanceRunner do
    use ExUnit.Case, async: false

    use H.ExecutionEnv.Conformance,
      factory: fn tmp_dir ->
        token = "conf-token-#{System.unique_integer([:positive])}"

        sup =
          ExUnit.Callbacks.start_supervised!(
            {H.RemoteAgent.HTTP, cwd: tmp_dir, id: "http-conformance", token: token, port: 0}
          )

        url = H.RemoteAgent.HTTP.endpoint_url(sup)
        {:ok, env} = H.ExecutionEnv.Remote.connect_http(url, tmp_dir, token: token)
        env
      end
  end

  setup do
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    tmp_dir =
      Path.join(
        "/private/tmp",
        "h-remote-http-#{System.unique_integer([:positive, :monotonic])}-#{rand}"
      )
      |> Path.expand()

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    token = "secret-bearer-token-#{rand}"
    sup = start_supervised!({HTTP, cwd: tmp_dir, id: "http-test", token: token, port: 0})
    url = HTTP.endpoint_url(sup)
    client = Client.new(url, token: token)

    {:ok, tmp_dir: tmp_dir, sup: sup, url: url, token: token, client: client}
  end

  describe "H.RemoteAgent.Client Inspect redaction" do
    test "redacts bearer token via %H.Credentials.Redacted{}", %{client: client, token: token} do
      inspected = inspect(client)
      assert inspected =~ "#H.Credentials.Redacted<[REDACTED]>"
      refute inspected =~ token
    end
  end

  describe "H.RemoteAgent.HTTP bearer authentication and endpoints" do
    test "rejects missing and wrong bearer tokens with 401 and cache-control: no-store", %{
      url: url,
      tmp_dir: tmp_dir
    } do
      unauth = Req.get!("#{url}/v1/descriptor", retry: false)
      assert unauth.status == 401
      assert Req.Response.get_header(unauth, "cache-control") == ["no-store"]
      assert unauth.body == %{"error" => "unauthorized"}

      wrong =
        Req.post!("#{url}/v1/fs/resolve_path",
          headers: [{"authorization", "Bearer wrong-token"}],
          json: %{"path" => "a.txt"},
          retry: false
        )

      assert wrong.status == 401
      assert Req.Response.get_header(wrong, "cache-control") == ["no-store"]

      assert {:error, :unauthorized} =
               Remote.connect_http(url, tmp_dir, token: "wrong-token")
    end

    test "supports descriptor, cwd, base64 binary fs ops, and RemoteAgent delegation", %{
      client: client,
      tmp_dir: tmp_dir
    } do
      assert %{id: "http-test", kind: "remote", cwd: ^tmp_dir} = RemoteAgent.descriptor(client)
      assert RemoteAgent.cwd(client) == tmp_dir

      bin = <<0, 1, 2, 255, 254, 128, 10, 13, 42>>
      assert :ok = RemoteAgent.write_file(client, "raw/bytes.bin", bin)
      assert {:ok, ^bin} = RemoteAgent.read_file_bytes(client, "raw/bytes.bin")

      assert {:ok, "/virtual/remote/src/app.ex"} =
               RemoteAgent.resolve_path(client, "src/../src/app.ex", cwd: "/virtual/remote")

      sub = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(sub)
      assert {:ok, ^sub} = RemoteAgent.bind_cwd(client, "workspace")
      assert {:ok, ^sub} = RemoteAgent.canonical_path(client, ".", cwd: sub)
    end

    test "returns error when remote agent is unreachable or down" do
      {:error, {:agent_down, _}} =
        Remote.connect_http("http://127.0.0.1:1", "/tmp", token: "tok")
    end

    test "supports both TCP HTTP and Unix domain socket concurrently when both configured", %{
      tmp_dir: tmp_dir,
      token: token
    } do
      sock_path = Path.join(tmp_dir, "both.sock")

      sup =
        start_supervised!(
          {HTTP, cwd: tmp_dir, id: "both-test", token: token, port: 0, socket_path: sock_path},
          id: :both_http_agent
        )

      url = HTTP.endpoint_url(sup)
      assert is_binary(url)
      assert File.exists?(sock_path)

      {:ok, tcp_env} = Remote.connect_http(url, tmp_dir, token: token)
      {:ok, uds_env} = Remote.connect_http([unix_socket: sock_path], tmp_dir, token: token)

      :ok = ExecutionEnv.write_file(tcp_env, "shared.txt", "hello-both\n")
      assert {:ok, %{lines: ["hello-both"]}} = ExecutionEnv.read_file_lines(uds_env, "shared.txt")
    end

    test "supports Unix domain socket transport via connect_http/3 and env_spec_for_http/3", %{
      tmp_dir: tmp_dir,
      token: token
    } do
      sock_path = Path.join(tmp_dir, "agent.sock")

      _uds_sup =
        start_supervised!(
          {HTTP,
           cwd: tmp_dir, id: "uds-test", token: token, ip: nil, port: nil, socket_path: sock_path},
          id: :uds_http_agent
        )

      assert File.exists?(sock_path)
      assert Bitwise.band(File.stat!(sock_path).mode, 0o777) == 0o600

      {:ok, env} = Remote.connect_http([unix_socket: sock_path], tmp_dir, token: token)
      assert ExecutionEnv.env_id(env) == "uds-test"
      assert ExecutionEnv.kind(env) == "remote"

      :ok = ExecutionEnv.write_file(env, "uds.txt", "via-uds\n")
      assert {:ok, %{lines: ["via-uds"]}} = ExecutionEnv.read_file_lines(env, "uds.txt")

      assert {:ok, %{exit_code: 0, output: "uds-ok"}} =
               ExecutionEnv.exec(env, {:shell, "printf uds-ok"})

      spec =
        Remote.env_spec_for_http("uds.env", [unix_socket: sock_path],
          token: token,
          default_cwd: tmp_dir
        )

      assert %{id: "uds.env", kind: "remote", default_cwd: ^tmp_dir} = spec
      built = spec.build.(tmp_dir)
      assert ExecutionEnv.env_id(built) == "uds.env"

      assert {:ok, %{exit_code: 0, output: "spec-ok"}} =
               ExecutionEnv.exec(built, {:shell, "printf spec-ok"})
    end
  end

  describe "fencing, heartbeats, abort, and stream disconnect PGID reaping" do
    test "returns 409 stale_fence before spawning any OS process on duplicate or older fences", %{
      url: url,
      token: token,
      client: client,
      tmp_dir: tmp_dir
    } do
      marker = Path.join(tmp_dir, "should-not-exist")

      assert {:ok, %{exit_code: 0, output: "first"}} =
               RemoteAgent.exec(client, {:shell, "printf first"},
                 session_id: "s-http-1",
                 incarnation: 2,
                 task_id: 10,
                 attempt_id: 2
               )

      # Direct HTTP call verifies 409 status + "stale_fence" and no process side effect
      dup_resp =
        Req.post!("#{url}/v1/exec/stream",
          headers: [{"authorization", "Bearer #{token}"}],
          json: %{
            "command" => %{"type" => "shell", "command" => "touch #{marker}; echo dup"},
            "fence" => %{
              "session_id" => "s-http-1",
              "incarnation" => 2,
              "task_id" => 10,
              "attempt_id" => 2
            }
          },
          retry: false
        )

      assert dup_resp.status == 409
      assert dup_resp.body == %{"error" => "stale_fence"}
      refute File.exists?(marker)

      # Older attempt and older incarnation also rejected with :stale_fence
      assert {:error, :stale_fence} =
               RemoteAgent.exec(client, {:shell, "touch #{marker}"},
                 session_id: "s-http-1",
                 incarnation: 2,
                 task_id: 10,
                 attempt_id: 1
               )

      assert {:error, :stale_fence} =
               RemoteAgent.exec(client, {:shell, "touch #{marker}"},
                 session_id: "s-http-1",
                 incarnation: 1,
                 task_id: 99,
                 attempt_id: 1
               )

      refute File.exists?(marker)
    end

    test "active heartbeat loop keeps execution alive past initial lease_ms", %{
      url: url,
      token: token
    } do
      client = Client.new(url, token: token, lease_ms: 250, heartbeat_ms: 50)
      parent = self()

      assert {:ok, %{exit_code: 0, output: output}} =
               RemoteAgent.exec(
                 client,
                 {:shell, "echo step1; sleep 0.6; printf step2"},
                 session_id: "s-hb",
                 incarnation: 1,
                 task_id: 1,
                 attempt_id: 1,
                 on_output: fn chunk -> send(parent, {:chunk, chunk}) end
               )

      assert_receive {:chunk, "step1\n"}, 2_000
      assert output == "step1\nstep2"
      assert RemoteAgent.active_fences(client) == []
    end

    test "lease expiry without renewal reaps remote grandchild PGID", %{url: url, token: token} do
      # Use direct HTTP stream request without client heartbeat so the server lease expires
      resp =
        Req.post!("#{url}/v1/exec/stream",
          headers: [{"authorization", "Bearer #{token}"}],
          json: %{
            "command" => %{
              "type" => "shell",
              "command" => "sleep 120 & echo child_pid=$!; sleep 120"
            },
            "fence" => %{
              "session_id" => "s-exp",
              "incarnation" => 1,
              "task_id" => 1,
              "attempt_id" => 1
            },
            "lease_ms" => 150,
            "timeout_ms" => 10_000
          },
          into: :self,
          retry: false
        )

      assert resp.status == 200
      frames = read_all_ndjson_frames(resp)
      output = collect_output(frames)
      [_, child_pid] = Regex.run(~r/child_pid=(\d+)/, output)

      terminal = List.last(frames)
      assert terminal["type"] == "error"
      assert terminal["error"]["reason"] == "lease_expired"

      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0
    end

    test "abort_ref cancels active exec via POST /v1/exec/abort and reaps PGID", %{
      client: client
    } do
      parent = self()
      abort_ref = make_ref()

      task =
        Task.async(fn ->
          RemoteAgent.exec(
            client,
            {:shell, "sleep 120 & echo child_pid=$!; sleep 120"},
            session_id: "s-abort-http",
            incarnation: 1,
            task_id: 1,
            attempt_id: 1,
            timeout_ms: 10_000,
            abort_ref: abort_ref,
            on_output: fn chunk -> send(parent, {:chunk, chunk}) end
          )
        end)

      child_pid = receive_child_pid!()
      assert [{"s-abort-http", 1, 1, 1}] = RemoteAgent.active_fences(client)

      send(task.pid, {:abort_exec, abort_ref})

      assert {:error, %{reason: :aborted, output: output}} = Task.await(task, 5_000)
      assert String.contains?(output, "child_pid=#{child_pid}")
      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0
      assert RemoteAgent.active_fences(client) == []
    end

    test "HTTP stream socket disconnect immediately aborts and reaps remote PGID", %{
      url: url,
      token: token,
      client: client
    } do
      parent = self()

      {caller_pid, caller_mon} =
        spawn_monitor(fn ->
          resp =
            Req.post!("#{url}/v1/exec/stream",
              headers: [{"authorization", "Bearer #{token}"}],
              json: %{
                "command" => %{
                  "type" => "shell",
                  "command" => "sleep 120 & echo child_pid=$!; sleep 120"
                },
                "fence" => %{
                  "session_id" => "s-disc",
                  "incarnation" => 1,
                  "task_id" => 1,
                  "attempt_id" => 1
                },
                "lease_ms" => 30_000,
                "timeout_ms" => 30_000
              },
              into: :self,
              retry: false
            )

          send(parent, {:stream_started, resp})

          Stream.repeatedly(fn ->
            receive do
              msg ->
                case Req.parse_message(resp, msg) do
                  {:ok, parts} ->
                    Enum.each(parts, fn
                      {:data, chunk} ->
                        for line <- String.split(chunk, "\n", trim: true) do
                          case JSON.decode(line) do
                            {:ok, %{"type" => "output", "data_b64" => b64}} ->
                              send(parent, {:chunk, Base.decode64!(b64)})

                            _ ->
                              :ok
                          end
                        end

                      _ ->
                        :ok
                    end)

                  _ ->
                    :ok
                end
            end
          end)
          |> Stream.run()
        end)

      assert_receive {:stream_started, _resp}, 2_000
      child_pid = receive_child_pid!()

      # Kill client process mid-stream -> socket closes -> server must reap child PGID promptly
      Process.exit(caller_pid, :kill)
      assert_receive {:DOWN, ^caller_mon, :process, ^caller_pid, :killed}, 2_000

      wait_until(fn -> RemoteAgent.active_fences(client) == [] end, 3_000)
      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0
    end
  end

  defp receive_child_pid!(acc \\ "") do
    receive do
      {:chunk, chunk} ->
        combined = acc <> chunk

        case Regex.run(~r/child_pid=(\d+)/, combined) do
          [_, pid] -> pid
          nil -> receive_child_pid!(combined)
        end
    after
      2_000 ->
        flunk("did not receive child_pid within timeout, got: #{inspect(acc)}")
    end
  end

  defp read_all_ndjson_frames(resp, buffer \\ "", acc \\ []) do
    %{body: %Req.Response.Async{ref: ref}} = resp

    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, parts} ->
            {next_buf, next_acc, done?} =
              Enum.reduce(parts, {buffer, acc, false}, fn
                {:data, chunk}, {buf, frames, d?} ->
                  {rem_buf, new_frames} = parse_lines(buf <> chunk)
                  {rem_buf, frames ++ new_frames, d?}

                :done, {buf, frames, _} ->
                  {_, tail_frames} = parse_lines(buf <> "\n")
                  {"", frames ++ tail_frames, true}

                _, state ->
                  state
              end)

            if done?, do: next_acc, else: read_all_ndjson_frames(resp, next_buf, next_acc)

          {:error, reason} ->
            flunk("stream error: #{inspect(reason)}")
        end
    after
      5_000 ->
        flunk("timed out reading NDJSON frames")
    end
  end

  defp parse_lines(buf) do
    case String.split(buf, "\n") do
      [single] ->
        {single, []}

      parts ->
        {rest, complete} = List.pop_at(parts, -1)

        decoded =
          complete
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&JSON.decode!/1)

        {rest, decoded}
    end
  end

  defp collect_output(frames) do
    frames
    |> Enum.filter(&(&1["type"] == "output"))
    |> Enum.map_join("", fn %{"data_b64" => b64} -> Base.decode64!(b64) end)
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(15)
        do_wait_until(fun, deadline)
      end
    end
  end
end
