defmodule Extensions.EditorHostTest do
  use ExUnit.Case, async: false

  alias Extensions.EditorHost
  alias Extensions.EditorHost.{Broker, BufferSummaryTool, Harness}
  alias H.{ExecutionEnv, StoreLock}

  setup do
    id = System.unique_integer([:positive])
    tmp_base = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(tmp_base, "h-editor-host-#{System.pid()}-#{id}")
    data_dir = Path.join(root, "data")
    dist_dir = Path.join(root, "dist/editor_host")
    cwd = Path.join(root, "workspace")
    other_cwd = Path.join(root, "other_workspace")

    Enum.each([data_dir, cwd, other_cwd], &File.mkdir_p!/1)
    File.write!(Path.join(cwd, "main.ex"), "defmodule Main do\nend\n")
    File.write!(Path.join(other_cwd, "other.ex"), "defmodule Other do\nend\n")

    on_exit(fn ->
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf!(root)
    end)

    {:ok,
     id: id, root: root, data_dir: data_dir, dist_dir: dist_dir, cwd: cwd, other_cwd: other_cwd}
  end

  describe "configure/2 and harness/tool metadata" do
    test "validates settings and rejects unknown keys or out-of-range bounds" do
      assert {:ok,
              %{
                harnesses: [Harness],
                status_projections: [%{namespace: "editor_host", module: EditorHost}],
                children: [{Broker, broker_opts}]
              }} =
               EditorHost.configure(
                 %{
                   "grant_ttl_ms" => 5_000,
                   "invocation_timeout_ms" => 1_500,
                   "max_summary_bytes" => 2_048,
                   "max_concurrency" => 2
                 },
                 %{id: "editor_host", data_dir: "/tmp"}
               )

      assert broker_opts[:grant_ttl_ms] == 5_000
      assert broker_opts[:invocation_timeout_ms] == 1_500
      assert broker_opts[:max_summary_bytes] == 2_048
      assert broker_opts[:max_concurrency] == 2

      assert {:error, :invalid_editor_host_settings} =
               EditorHost.configure(%{"unknown" => 1}, %{})

      assert {:error, :invalid_editor_host_settings} =
               EditorHost.configure(%{"grant_ttl_ms" => 500}, %{})

      assert {:error, :invalid_editor_host_settings} =
               EditorHost.configure(%{"invocation_timeout_ms" => 100}, %{})

      assert {:error, :invalid_editor_host_settings} =
               EditorHost.configure(%{"max_summary_bytes" => 100}, %{})

      assert {:error, :invalid_editor_host_settings} =
               EditorHost.configure(%{"socket_path" => "relative.sock"}, %{})
    end

    test "defines editor_coding harness and editor_buffer_summary tool schema" do
      assert Harness.id() == "editor_coding"
      assert BufferSummaryTool in Harness.tools()
      assert H.Tools.Read in Harness.tools()
      assert BufferSummaryTool.name() == "editor_buffer_summary"
      assert BufferSummaryTool.mutating?() == false
      assert BufferSummaryTool.replay() == :safe

      schema = BufferSummaryTool.parameters_schema()
      assert schema["required"] == ["path", "expected_revision"]
      assert {:ok, _} = JSV.build(schema)

      assert {:error, _} = H.Tool.validate_args(BufferSummaryTool, %{"path" => "main.ex"})

      assert {:error, _} =
               H.Tool.validate_args(BufferSummaryTool, %{
                 "path" => "main.ex",
                 "expected_revision" => ""
               })

      assert {:ok, _} =
               H.Tool.validate_args(BufferSummaryTool, %{
                 "path" => "main.ex",
                 "expected_revision" => "rev-1",
                 "max_lines" => 50
               })
    end
  end

  describe "Broker grant pairing, fencing, validation, timeouts, and disconnect handling" do
    test "enforces single-claim grants, owner-token isolation, workspace match, and generation fencing",
         ctx do
      broker = start_supervised!({Broker, name: nil, grant_ttl_ms: 1_000, max_summary_bytes: 256})

      # Missing/invalid grant rejected
      assert {:error, :unauthorized} =
               Broker.claim_grant(
                 "not-a-valid-grant",
                 self(),
                 %{
                   cwd: ctx.cwd,
                   capabilities: ["editor_buffer_summary"]
                 },
                 server: broker
               )

      # Owner token is never accepted as a host grant
      assert {:ok, grant} = Broker.issue_grant(ctx.cwd, server: broker)
      assert is_binary(grant.grant_token)

      # Even an explicit daemon owner token string is rejected as a grant
      assert {:error, :unauthorized} =
               Broker.claim_grant(
                 "h-owner-token-should-never-work",
                 self(),
                 %{cwd: ctx.cwd, capabilities: ["editor_buffer_summary"]},
                 server: broker
               )

      assert {:ok, canonical_cwd} =
               ExecutionEnv.canonical_path(ExecutionEnv.Host.new(ctx.cwd), ctx.cwd)

      assert grant.cwd == canonical_cwd

      # Workspace mismatch rejected without consuming grant
      assert {:error, :workspace_mismatch} =
               Broker.claim_grant(
                 grant.grant_token,
                 self(),
                 %{cwd: ctx.other_cwd, capabilities: ["editor_buffer_summary"]},
                 server: broker
               )

      # Unsupported capability rejected
      assert {:error, :unsupported_capabilities} =
               Broker.claim_grant(
                 grant.grant_token,
                 self(),
                 %{cwd: ctx.cwd, capabilities: ["bash"]},
                 server: broker
               )

      # First live host claims grant -> generation 1
      host1 =
        spawn_fake_host(broker, fn payload ->
          %{
            "invocation_id" => payload["invocation_id"],
            "host_generation" => payload["host_generation"],
            "status" => "ok",
            "revision" => payload["args"]["expected_revision"],
            "summary" => "host1 summary"
          }
        end)

      on_exit(fn -> stop_pid(host1) end)

      assert {:ok, %{host_generation: 1, cwd: ^canonical_cwd}} =
               Broker.claim_grant(
                 grant.grant_token,
                 host1,
                 %{cwd: ctx.cwd, capabilities: ["editor_buffer_summary"]},
                 server: broker
               )

      # Duplicate claim on the same grant rejected
      assert {:error, :grant_already_claimed} =
               Broker.claim_grant(
                 grant.grant_token,
                 self(),
                 %{cwd: ctx.cwd, capabilities: ["editor_buffer_summary"]},
                 server: broker
               )

      # Expired grant rejected
      assert {:ok, short_grant} = Broker.issue_grant(ctx.cwd, server: broker, grant_ttl_ms: 1_000)

      # Test normal invocation on gen 1 first
      assert {:ok, res1} =
               Broker.invoke_buffer_summary(
                 ctx.cwd,
                 %{"path" => "main.ex", "expected_revision" => "rev-1", "max_lines" => 20},
                 server: broker
               )

      assert res1.is_error == false
      assert [%{"type" => "text", "text" => "host1 summary"}] = res1.content
      assert res1.details["host_generation"] == 1

      # Second host claims a new grant -> generation 2 supersedes generation 1
      assert {:ok, grant2} = Broker.issue_grant(ctx.cwd, server: broker)

      host2 =
        spawn_fake_host(broker, fn payload ->
          %{
            "invocation_id" => payload["invocation_id"],
            "host_generation" => payload["host_generation"],
            "status" => "ok",
            "revision" => payload["args"]["expected_revision"],
            "summary" => "host2 summary"
          }
        end)

      on_exit(fn -> stop_pid(host2) end)

      assert {:ok, %{host_generation: 2}} =
               Broker.claim_grant(
                 grant2.grant_token,
                 host2,
                 %{cwd: ctx.cwd, capabilities: ["editor_buffer_summary"]},
                 server: broker
               )

      # Stale generation 1 reply is fenced/rejected
      assert {:error, :stale_or_unknown_invocation} =
               Broker.complete_invocation("missing", 1, %{"summary" => "late"}, server: broker)

      # Active invocation goes only to host2 (gen 2)
      assert {:ok, res2} =
               Broker.invoke_buffer_summary(
                 ctx.cwd,
                 %{"path" => "main.ex", "expected_revision" => "rev-2", "max_lines" => 10},
                 server: broker
               )

      assert [%{"type" => "text", "text" => "host2 summary"}] = res2.content
      assert res2.details["host_generation"] == 2

      # Expired grant rejected (using internal state expiry via :sys.replace_state for deterministic instant check)
      :sys.replace_state(broker, fn st ->
        grants =
          Map.update!(st.grants, short_grant.grant_id, fn g ->
            %{g | expires_at_mono: System.monotonic_time(:millisecond) - 1}
          end)

        %{st | grants: grants}
      end)

      assert {:error, :grant_expired} =
               Broker.claim_grant(
                 short_grant.grant_token,
                 self(),
                 %{cwd: ctx.cwd, capabilities: ["editor_buffer_summary"]},
                 server: broker
               )
    end

    test "enforces expected_revision, sanitizes output, rejects oversized replies, and handles timeouts/disconnects",
         ctx do
      broker =
        start_supervised!(
          {Broker,
           name: nil, invocation_timeout_ms: 500, max_summary_bytes: 256, max_concurrency: 1}
        )

      # Before any host pairs -> prompt tool_unavailable
      assert {:error, %{diagnostic: "tool_unavailable", is_error: true}} =
               Broker.invoke_buffer_summary(
                 ctx.cwd,
                 %{"path" => "main.ex", "expected_revision" => "rev-1", "max_lines" => 10},
                 server: broker
               )

      test_pid = self()
      {:ok, grant} = Broker.issue_grant(ctx.cwd, server: broker)

      host_pid =
        spawn(fn ->
          loop_host(broker, test_pid)
        end)

      on_exit(fn -> stop_pid(host_pid) end)

      assert {:ok, %{host_generation: 1}} =
               Broker.claim_grant(
                 grant.grant_token,
                 host_pid,
                 %{cwd: ctx.cwd, capabilities: ["editor_buffer_summary"]},
                 server: broker
               )

      # 1. Revision mismatch
      send(host_pid, {:mode, :revision_mismatch, "rev-9"})

      assert {:error, %{diagnostic: "revision_mismatch", details: details}} =
               Broker.invoke_buffer_summary(
                 ctx.cwd,
                 %{"path" => "main.ex", "expected_revision" => "rev-1", "max_lines" => 10},
                 server: broker
               )

      assert details["actual_revision"] == "rev-9"

      # 2. Sanitization of active HTML, ANSI controls, and credentials
      send(
        host_pid,
        {:mode, :custom_summary,
         "<script>alert(1)</script>\e[31mOK\e[0m\x07 Bearer supersecret123 sk-ant-secret123456"}
      )

      assert {:ok, %{content: [%{"text" => clean}], is_error: false}} =
               Broker.invoke_buffer_summary(
                 ctx.cwd,
                 %{"path" => "main.ex", "expected_revision" => "rev-1", "max_lines" => 10},
                 server: broker
               )

      refute clean =~ "<script>"
      refute clean =~ "\e["
      refute clean =~ "\x07"
      refute clean =~ "supersecret123"
      refute clean =~ "sk-ant-secret123456"
      assert clean =~ "OK"
      assert clean =~ "[REDACTED]"

      # 3. Oversized reply rejected
      send(host_pid, {:mode, :custom_summary, String.duplicate("x", 300)})

      assert {:error, %{diagnostic: "response_too_large", is_error: true}} =
               Broker.invoke_buffer_summary(
                 ctx.cwd,
                 %{"path" => "main.ex", "expected_revision" => "rev-1", "max_lines" => 10},
                 server: broker
               )

      # 4. Stale generation reply during in-flight invocation is ignored; timeout triggers cleanly
      send(host_pid, {:mode, :wrong_gen_then_hang})

      assert {:error, %{diagnostic: "tool_timeout", is_error: true}} =
               Broker.invoke_buffer_summary(
                 ctx.cwd,
                 %{"path" => "main.ex", "expected_revision" => "rev-1", "max_lines" => 10},
                 server: broker,
                 timeout_ms: 500
               )

      assert_receive {:wrong_gen_reply_result, {:error, :stale_host_generation}}, 1_000

      # 5. Mid-dispatch host drop triggers host_disconnected immediately
      send(host_pid, {:mode, :crash_on_invoke})

      assert {:error, %{diagnostic: "host_disconnected", is_error: true}} =
               Broker.invoke_buffer_summary(
                 ctx.cwd,
                 %{"path" => "main.ex", "expected_revision" => "rev-1", "max_lines" => 10},
                 server: broker
               )

      # After crash, status projection reports disconnected
      assert {:ok, %{"state" => "disconnected", "paired_hosts" => 0}, _} =
               Broker.project_status(%{}, server: broker)
    end

    test "supports optional private loopback HTTP / UDS broker endpoint without accepting daemon owner token",
         ctx do
      sock_path = Path.join(ctx.root, "eh.sock")

      broker =
        start_supervised!(
          {Broker,
           name: nil,
           socket_path: sock_path,
           http_port: 0,
           invocation_timeout_ms: 1_000,
           max_summary_bytes: 1_024}
        )

      {:ok, %{socket_path: ^sock_path, http_port: http_port}} =
        Broker.endpoint_info(server: broker)

      assert is_integer(http_port) and http_port > 0
      assert File.exists?(sock_path)

      {:ok, _} = Application.ensure_all_started(:req)
      {:ok, grant} = Broker.issue_grant(ctx.cwd, server: broker)

      # Invalid/owner token over HTTP transport is rejected (401)
      resp_bad =
        Req.post!("http://127.0.0.1:#{http_port}/editor-host/v1/connect",
          json: %{
            "grant_token" => "daemon-owner-token",
            "cwd" => ctx.cwd,
            "capabilities" => ["editor_buffer_summary"]
          },
          retry: false
        )

      assert resp_bad.status == 401

      # Connect a live host over the private UDS endpoint, receive invoke event, and reply over UDS
      test_pid = self()

      host_task =
        Task.async(fn ->
          Req.post!("http://localhost/editor-host/v1/connect",
            unix_socket: sock_path,
            json: %{
              "grant_token" => grant.grant_token,
              "cwd" => ctx.cwd,
              "capabilities" => ["editor_buffer_summary"]
            },
            into: fn {:data, chunk}, {req, resp} ->
              send(test_pid, {:uds_chunk, chunk})

              if String.contains?(chunk, "event: invoke") do
                [_, json] = String.split(chunk, "data: ", parts: 2)
                payload = json |> String.split("\n", parts: 2) |> hd() |> JSON.decode!()

                Req.post!(
                  "http://localhost/editor-host/v1/invocations/#{payload["invocation_id"]}/result",
                  unix_socket: sock_path,
                  json: %{
                    "invocation_id" => payload["invocation_id"],
                    "host_generation" => payload["host_generation"],
                    "status" => "ok",
                    "revision" => payload["args"]["expected_revision"],
                    "summary" => "uds live summary"
                  },
                  retry: false
                )
              end

              {:cont, {req, resp}}
            end,
            receive_timeout: 5_000
          )
        end)

      assert_receive {:uds_chunk, connected_chunk}, 2_000
      assert connected_chunk =~ "event: connected"

      assert {:ok, res} =
               Broker.invoke_buffer_summary(
                 ctx.cwd,
                 %{"path" => "main.ex", "expected_revision" => "rev-uds", "max_lines" => 10},
                 server: broker
               )

      assert [%{"type" => "text", "text" => "uds live summary"}] = res.content
      Task.shutdown(host_task, :brutal_kill)
    end
  end

  describe "built artifact + full H.Daemon / Bandit / Dual-Client SSE integration" do
    test "dual SSE clients receive identical committed tool_result while paired host gets exactly 1 invocation",
         ctx do
      # Build the real extension artifact with mix extension.build into a disposable dist dir
      # and boot a clean subprocess VM so H.Extensions.load_state loads the BEAMs from dist_dir
      # rather than from Mix's _build compile path.
      Mix.Tasks.Extension.Build.run([ctx.dist_dir])
      assert File.regular?(Path.join(ctx.dist_dir, "extension.json"))
      assert File.regular?(Path.join(ctx.dist_dir, "ebin/Elixir.Extensions.EditorHost.beam"))

      File.write!(
        Path.join(ctx.data_dir, "extensions.json"),
        JSON.encode!(%{
          "version" => 1,
          "extensions" => [
            %{
              "path" => ctx.dist_dir,
              "settings" => %{
                "grant_ttl_ms" => 30_000,
                "invocation_timeout_ms" => 3_000,
                "max_summary_bytes" => 8_192
              }
            }
          ]
        })
      )

      script = """
      {:ok, _} = Application.ensure_all_started(:req)

      {:ok, fake} =
        H.Provider.Fake.start_link(
          name: H.Provider.Fake,
          script: [
            {:reply, [],
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "tc_buf_1",
                   name: "editor_buffer_summary",
                   arguments: %{
                     "path" => "main.ex",
                     "expected_revision" => "rev-42",
                     "max_lines" => 25
                   }
                 }
               ],
               finish_reason: "tool_calls"
             }},
            {:expect,
             fn req ->
               tool_msg =
                 Enum.find(req.messages, fn m ->
                   m.role == "tool" and m[:tool_call_id] == "tc_buf_1"
                 end)

               true = hd(tool_msg.content).text =~ "unsaved buffer main.ex @ rev-42"
               true
             end,
             {:reply, [],
              %{
                content: [%{type: "text", text: "Buffer summary checked."}],
                finish_reason: "stop"
              }}}
          ]
        )

      {:ok, %{url: base_url}} =
        H.serve(
          data_dir: #{inspect(ctx.data_dir)},
          port: 0,
          api_socket: false,
          provider: H.Provider.Fake,
          provider_config: %{server: fake},
          default_model: "fake:coder",
          storage_opts: [sync: :none]
        )

      opts = H.Daemon.instance_options()
      true = opts[:harnesses]["editor_coding"] == Extensions.EditorHost.Harness
      true = Enum.any?(opts[:status_projections], &(&1.namespace == "editor_host"))
      true = is_pid(Process.whereis(Extensions.EditorHost.Broker))

      owner_token = H.Auth.owner_token()
      bearer_headers = [{"authorization", "Bearer " <> owner_token}]

      # Browser cookie client (simulating HWeb) + Bearer client (simulating hi)
      auth_resp =
        Req.post!(base_url <> "/api/v1/auth/session",
          headers: [{"origin", base_url}],
          json: %{"token" => owner_token},
          retry: false
        )

      200 = auth_resp.status
      [set_cookie] = Req.Response.get_header(auth_resp, "set-cookie")
      cookie_pair = set_cookie |> String.split(";", parts: 2) |> hd()
      web_headers = [{"cookie", cookie_pair}, {"origin", base_url}]

      # Create session using editor_coding harness
      create_resp =
        Req.post!(base_url <> "/api/v1/sessions",
          headers: web_headers,
          json: %{
            "session_id" => "ed-sess",
            "cwd" => #{inspect(ctx.cwd)},
            "harness_id" => "editor_coding"
          },
          retry: false
        )

      200 = create_resp.status
      "editor_coding" = create_resp.body["session"]["harness_id"]

      # Before pairing -> extension-status reports disconnected
      status_before =
        Req.get!(base_url <> "/api/v1/sessions/ed-sess/conversations/1/extension-status",
          headers: bearer_headers,
          retry: false
        )

      200 = status_before.status

      %{"state" => "disconnected", "paired_hosts" => 0, "generation" => 0} =
        status_before.body["extensions"]["editor_host"]

      # Pair ONE live editor host (separate from both SSE clients!)
      {:ok, grant} = Extensions.EditorHost.issue_grant(#{inspect(ctx.cwd)})
      false = grant.grant_token == owner_token

      test_pid = self()
      dispatch_count = :atomics.new(1, [])

      loop_host = fn loop_fn ->
        receive do
          {:editor_host_invoke, payload} ->
            :atomics.add(dispatch_count, 1, 1)
            send(test_pid, {:host_invoked, payload})

            :ok =
              Extensions.EditorHost.Broker.complete_invocation(
                payload["invocation_id"],
                payload["host_generation"],
                %{
                  "invocation_id" => payload["invocation_id"],
                  "host_generation" => payload["host_generation"],
                  "status" => "ok",
                  "revision" => payload["args"]["expected_revision"],
                  "summary" =>
                    "unsaved buffer " <>
                      payload["args"]["path"] <> " @ " <> payload["args"]["expected_revision"],
                  "line_count" => 12,
                  "dirty" => true
                }
              )

            loop_fn.(loop_fn)
        end
      end

      editor_host_pid = spawn_link(fn -> loop_host.(loop_host) end)

      {:ok, %{host_generation: 1}} =
        Extensions.EditorHost.claim_grant(grant.grant_token, editor_host_pid, %{
          cwd: #{inspect(ctx.cwd)},
          capabilities: ["editor_buffer_summary"]
        })

      # After pairing -> extension-status reports connected + generation 1
      status_after =
        Req.get!(base_url <> "/api/v1/sessions/ed-sess/conversations/1/extension-status",
          headers: bearer_headers,
          retry: false
        )

      200 = status_after.status

      %{"state" => "connected", "paired_hosts" => 1, "generation" => 1} =
        status_after.body["extensions"]["editor_host"]

      # Attach TWO independent SSE subscribers (simulating hi + HWeb)
      hi_sse =
        Task.async(fn ->
          Req.get!(base_url <> "/api/v1/sessions/ed-sess/conversations/1/events",
            headers: bearer_headers,
            into: fn {:data, chunk}, {req, resp} ->
              send(test_pid, {:hi_sse, chunk})
              {:cont, {req, resp}}
            end,
            receive_timeout: 5_000
          )
        end)

      web_sse =
        Task.async(fn ->
          Req.get!(base_url <> "/api/v1/sessions/ed-sess/conversations/1/events",
            headers: [{"cookie", cookie_pair}],
            into: fn {:data, chunk}, {req, resp} ->
              send(test_pid, {:web_sse, chunk})
              {:cont, {req, resp}}
            end,
            receive_timeout: 5_000
          )
        end)

      hi_init =
        receive do
          {:hi_sse, chunk} -> chunk
        after
          2_000 -> raise "missing hi_sse snapshot"
        end

      web_init =
        receive do
          {:web_sse, chunk} -> chunk
        after
          2_000 -> raise "missing web_sse snapshot"
        end

      true = hi_init =~ "event: snapshot"
      true = web_init =~ "event: snapshot"

      # Trigger model turn calling editor_buffer_summary
      sub_resp =
        Req.post!(base_url <> "/api/v1/sessions/ed-sess/commands",
          headers: bearer_headers,
          json: %{
            "version" => 1,
            "request_id" => "ed-req-1",
            "command" => "submit",
            "conversation_id" => "1",
            "args" => %{"type" => "input", "content" => "Inspect unsaved main.ex buffer"}
          },
          retry: false
        )

      200 = sub_resp.status

      receive do
        {:host_invoked, payload} ->
          "main.ex" = payload["args"]["path"]
          "rev-42" = payload["args"]["expected_revision"]
          1 = payload["host_generation"]
      after
        2_000 -> raise "host was not invoked"
      end

      wait_until = fn wait_fn, n ->
        if n == 0, do: raise("timed out waiting for assistant completion")
        {:ok, %{items: items}} = H.Daemon.scan_entries("ed-sess", "1", %{}, opts)

        done? =
          Enum.any?(items, fn item ->
            item.kind == "assistant" and
              Enum.any?(item.data["content"] || [], &(&1["text"] == "Buffer summary checked."))
          end)

        if done? do
          items
        else
          Process.sleep(20)
          wait_fn.(wait_fn, n - 1)
        end
      end

      _items = wait_until.(wait_until, 150)

      1 = :atomics.get(dispatch_count, 1)

      receive do
        {:host_invoked, _} -> raise "unexpected duplicate host invocation"
      after
        50 -> :ok
      end

      drain = fn drain_fn, tag, acc ->
        receive do
          {^tag, chunk} -> drain_fn.(drain_fn, tag, [chunk | acc])
        after
          50 -> Enum.reverse(acc)
        end
      end

      fold = fn chunks ->
        chunks
        |> IO.iodata_to_binary()
        |> String.split("\\n\\n", trim: true)
        |> Enum.reduce(H.Transcript.new(), fn raw_event, acc ->
          lines = String.split(raw_event, "\\n")

          event =
            Enum.find_value(lines, fn
              "event: " <> name -> name
              _ -> nil
            end)

          data =
            lines
            |> Enum.flat_map(fn
              "data: " <> json -> [json]
              _ -> []
            end)
            |> Enum.join("\\n")

          case {event, data} do
            {"snapshot", json} when json != "" ->
              {:ok, next} = H.Transcript.apply_snapshot(acc, JSON.decode!(json))
              next

            {"commit", json} when json != "" ->
              {:ok, next, _meta} = H.Transcript.apply_commit(acc, JSON.decode!(json))
              next

            _ ->
              acc
          end
        end)
      end

      hi_t = fold.([hi_init | drain.(drain, :hi_sse, [])])
      web_t = fold.([web_init | drain.(drain, :web_sse, [])])

      true = hi_t.seq == web_t.seq
      true = hi_t.entries == web_t.entries

      [tool_result] = Enum.filter(hi_t.entries, &(&1["kind"] == "tool_result"))
      "editor_buffer_summary" = tool_result["data"]["name"]
      false = tool_result["data"]["is_error"]
      "unsaved buffer main.ex @ rev-42" = hd(tool_result["data"]["content"])["text"]

      Task.shutdown(hi_sse, :brutal_kill)
      Task.shutdown(web_sse, :brutal_kill)
      Process.unlink(editor_host_pid)
      Process.exit(editor_host_pid, :kill)
      :ok = Supervisor.stop(Process.whereis(H.Daemon.Instance))
      IO.puts("EDITOR_HOST_FULL_STACK_OK")
      """

      {output, status} = launch_clean_vm(script)
      assert status == 0, "Subprocess failed:\n#{output}"
      assert output =~ "EDITOR_HOST_FULL_STACK_OK"
    end
  end

  # --- Test helpers ---

  defp spawn_fake_host(broker, reply_fn) do
    spawn_link(fn ->
      fake_host_loop(broker, reply_fn)
    end)
  end

  defp fake_host_loop(broker, reply_fn) do
    receive do
      {:editor_host_invoke, payload} ->
        reply = reply_fn.(payload)

        Broker.complete_invocation(
          payload["invocation_id"],
          payload["host_generation"],
          reply,
          server: broker
        )

        fake_host_loop(broker, reply_fn)

      :stop ->
        :ok
    end
  end

  defp loop_host(broker, test_pid, mode \\ :ok) do
    receive do
      {:mode, new_mode} ->
        loop_host(broker, test_pid, new_mode)

      {:mode, new_mode, arg} ->
        loop_host(broker, test_pid, {new_mode, arg})

      {:editor_host_invoke, payload} ->
        case mode do
          {:revision_mismatch, actual} ->
            Broker.complete_invocation(
              payload["invocation_id"],
              payload["host_generation"],
              %{
                "invocation_id" => payload["invocation_id"],
                "host_generation" => payload["host_generation"],
                "status" => "revision_mismatch",
                "actual_revision" => actual
              },
              server: broker
            )

            loop_host(broker, test_pid, mode)

          {:custom_summary, text} ->
            Broker.complete_invocation(
              payload["invocation_id"],
              payload["host_generation"],
              %{
                "invocation_id" => payload["invocation_id"],
                "host_generation" => payload["host_generation"],
                "status" => "ok",
                "revision" => payload["args"]["expected_revision"],
                "summary" => text
              },
              server: broker
            )

            loop_host(broker, test_pid, mode)

          :wrong_gen_then_hang ->
            res =
              Broker.complete_invocation(
                payload["invocation_id"],
                payload["host_generation"] + 99,
                %{
                  "invocation_id" => payload["invocation_id"],
                  "host_generation" => payload["host_generation"] + 99,
                  "status" => "ok",
                  "revision" => payload["args"]["expected_revision"],
                  "summary" => "wrong generation"
                },
                server: broker
              )

            send(test_pid, {:wrong_gen_reply_result, res})
            loop_host(broker, test_pid, mode)

          :crash_on_invoke ->
            exit(:kill)

          :ok ->
            loop_host(broker, test_pid, mode)
        end
    end
  end

  defp stop_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp launch_clean_vm(script) do
    # Exclude editor_host_extension's own ebin so H.Extensions.load_state loads
    # Extensions.EditorHost.* solely from the built dist_dir artifact.
    own_ebin = Path.expand(Mix.Project.compile_path())

    pa_args =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.reject(&(&1 == own_ebin))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&["-pa", &1])

    System.cmd(
      System.find_executable("elixir"),
      pa_args ++
        [
          "--erl",
          "+S 2:2",
          "-e",
          "Application.put_env(:req_llm, :load_dotenv, false)\n" <> script
        ],
      stderr_to_stdout: true,
      env: [{"H_DATA_DIR", nil}]
    )
  end
end
