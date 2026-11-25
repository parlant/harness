defmodule H.ExtensionsHotReloadTest do
  use ExUnit.Case, async: false

  alias H.Provider.Fake

  setup do
    root =
      Path.join(
        local_tmp("/private/tmp"),
        "h-ext-hot-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    data_dir = Path.join(root, "data")
    cwd = Path.join(root, "work")
    Enum.each([data_dir, cwd], &File.mkdir_p!/1)

    on_exit(fn ->
      File.rm(H.StoreLock.socket_path(data_dir))
      File.rm_rf!(root)
    end)

    {:ok, root: root, data_dir: data_dir, cwd: cwd}
  end

  describe "hot-code reloading extensions" do
    test "reloads extension code, tools, environments, and children live without dropping session state",
         ctx do
      pkg_v1 = Path.join(ctx.root, "pkg_v1")
      pkg_v2 = Path.join(ctx.root, "pkg_v2")
      compile_extension(pkg_v1, "v1-constant", "v1 instruction", include_second_tool?: false)
      compile_extension(pkg_v2, "v2-constant", "v2 instruction", include_second_tool?: true)

      write_extensions_json(ctx.data_dir, [
        %{"path" => pkg_v1, "settings" => %{"tag" => "first"}}
      ])

      assert {output, 0} =
               launch("""
               {:ok, _} = H.Provider.Fake.start_link(name: H.Provider.Fake, script: [
                 {:reply, [], %{tool_calls: [%{id: "c1", name: "hot_tool", arguments: %{}}], finish_reason: "tool_calls"}},
                 {:reply, [], %{content: [%{type: "text", text: "Turn 1 done"}]}},
                 {:reply, [], %{tool_calls: [%{id: "c2", name: "hot_tool", arguments: %{}}, %{id: "c3", name: "hot_extra", arguments: %{}}], finish_reason: "tool_calls"}},
                 {:reply, [], %{content: [%{type: "text", text: "Turn 2 done"}]}}
               ])

               {:ok, %{url: url}} = H.serve(
                 data_dir: #{inspect(ctx.data_dir)},
                 port: 0,
                 provider: #{inspect(Fake)},
                 default_model: "fake:coder",
                 retry_backoff_ms: 5
               )

               token = H.Auth.owner_token()
               headers = [{"authorization", "Bearer " <> token}]

               # Inspect initial extensions over HTTP
               %{status: 200, body: %{"generation" => 1, "extensions" => [%{"id" => "fixture.hot", "module_count" => 4}]}} =
                 Req.get!(url <> "/api/v1/extensions", headers: headers, retry: false)

               # Create a session using the v1 extension profile
               %{status: 200, body: %{"session" => %{"session_id" => "live-hot", "harness_id" => "fixture.hot.profile"}}} =
                 Req.post!(url <> "/api/v1/sessions",
                   json: %{"session_id" => "live-hot", "cwd" => #{inspect(ctx.cwd)}, "harness_id" => "fixture.hot.profile"},
                   headers: headers,
                   retry: false
                 )

               boot = H.Daemon.instance_options()
               [{session_pid_before, _}] = Registry.lookup(boot[:registry], {:session, "live-hot"})
               probe_pid_before = Process.whereis(Fixture.HotExt.Probe)
               true = is_pid(probe_pid_before)
               "v1 instruction:first" = Agent.get(probe_pid_before, & &1)

               # Run turn 1 -> executes v1 hot_tool
               %{status: 200} =
                 Req.post!(url <> "/api/v1/sessions/live-hot/commands",
                   json: %{
                     "version" => 1,
                     "request_id" => "turn-1",
                     "command" => "submit",
                     "conversation_id" => "1",
                     "args" => %{"type" => "input", "content" => "run v1"}
                   },
                   headers: headers,
                   retry: false
                 )

               poll = fn poll, needle, n ->
                 {:ok, page} = H.Daemon.scan_entries("live-hot", "1", %{}, H.Daemon.instance_options())
                 if Enum.any?(page.items, &String.contains?(JSON.encode!(&1), needle)) do
                   page.items
                 else
                   if n == 0, do: raise("timed out waiting for " <> needle)
                   Process.sleep(20)
                   poll.(poll, needle, n - 1)
                 end
               end

               items1 = poll.(poll, "Turn 1 done", 150)
               true = Enum.any?(items1, &String.contains?(JSON.encode!(&1), "v1-constant"))

               # Switch extensions.json to v2 and hot-reload over HTTP!
               File.write!(
                 Path.join(#{inspect(ctx.data_dir)}, "extensions.json"),
                 JSON.encode!(%{"version" => 1, "extensions" => [%{"path" => #{inspect(pkg_v2)}, "settings" => %{"tag" => "second"}}]})
               )

               %{status: 200, body: %{"generation" => 2, "extensions" => [%{"id" => "fixture.hot", "module_count" => 5}]}} =
                 Req.post!(url <> "/api/v1/extensions/reload", json: %{}, headers: headers, retry: false)

               # Same session coordinator PID is still alive (no state dropped, no daemon restart!)
               [{session_pid_after, _}] = Registry.lookup(H.Daemon.instance_options()[:registry], {:session, "live-hot"})
               ^session_pid_before = session_pid_after
               true = Process.alive?(session_pid_after)

               # Extension child was reconciled with new code & settings
               probe_pid_after = Process.whereis(Fixture.HotExt.Probe)
               true = is_pid(probe_pid_after) and probe_pid_after != probe_pid_before
               "v2 instruction:second" = Agent.get(probe_pid_after, & &1)

               # Allow the new hot_extra tool on the live session and run turn 2
               %{status: 200} =
                 Req.post!(url <> "/api/v1/sessions/live-hot/commands",
                   json: %{
                     "version" => 1,
                     "request_id" => "cfg-2",
                     "command" => "configure",
                     "conversation_id" => "1",
                     "args" => %{"tools" => ["hot_tool", "hot_extra"]}
                   },
                   headers: headers,
                   retry: false
                 )

               %{status: 200} =
                 Req.post!(url <> "/api/v1/sessions/live-hot/commands",
                   json: %{
                     "version" => 1,
                     "request_id" => "turn-2",
                     "command" => "submit",
                     "conversation_id" => "1",
                     "args" => %{"type" => "input", "content" => "run v2"}
                   },
                   headers: headers,
                   retry: false
                 )

               items2 = poll.(poll, "Turn 2 done", 150)
               # Both v1 history AND new v2 tool results exist in the same continuous conversation!
               true = Enum.any?(items2, &String.contains?(JSON.encode!(&1), "v1-constant"))
               true = Enum.any?(items2, &String.contains?(JSON.encode!(&1), "v2-constant"))
               true = Enum.any?(items2, &String.contains?(JSON.encode!(&1), "extra-from-v2"))

               # New sessions created over HTTP see v2's bootstrap immediately (router reads live opts)
               %{status: 200, body: %{"environments" => envs}} =
                 Req.get!(url <> "/api/v1/environments", headers: headers, retry: false)
               true = Enum.any?(envs, &(&1["id"] == "fixture.hot.env.v2"))

               IO.puts("HOT_RELOAD_OK")
               """)

      assert output =~ "HOT_RELOAD_OK"
    end

    test "rolls back cleanly when reload has invalid config, failing child, or lingering old-code process",
         ctx do
      pkg_v1 = Path.join(ctx.root, "pkg_v1")
      pkg_v2 = Path.join(ctx.root, "pkg_v2")
      pkg_bad_child = Path.join(ctx.root, "pkg_bad_child")
      compile_extension(pkg_v1, "v1-stable", "v1 stable", include_second_tool?: false)
      compile_extension(pkg_v2, "v2-next", "v2 next", include_second_tool?: false)
      compile_extension(pkg_bad_child, "v3-fail", "v3 fail", fail_child?: true)

      write_extensions_json(ctx.data_dir, [
        %{"path" => pkg_v1, "settings" => %{"tag" => "ok"}}
      ])

      assert {output, 0} =
               launch("""
               {:ok, %{url: url}} = H.serve(
                 data_dir: #{inspect(ctx.data_dir)},
                 port: 0,
                 provider: #{inspect(Fake)},
                 default_model: "fake:coder"
               )

               token = H.Auth.owner_token()
               headers = [{"authorization", "Bearer " <> token}]
               ext_json = Path.join(#{inspect(ctx.data_dir)}, "extensions.json")

               # 1. Broken extensions.json -> 422, v1 stays intact
               File.write!(ext_json, "{not json")
               %{status: 422, body: %{"error" => "extension_reload_failed"}} =
                 Req.post!(url <> "/api/v1/extensions/reload", json: %{}, headers: headers, retry: false)
               "v1 stable:ok" = Agent.get(Fixture.HotExt.Probe, & &1)

               # 2. Extension whose child fails to start -> 422, v1 code & child rolled back!
               File.write!(ext_json, JSON.encode!(%{"version" => 1, "extensions" => [%{"path" => #{inspect(pkg_bad_child)}, "settings" => %{"tag" => "boom"}}]}))
               %{status: 422, body: %{"error" => "extension_reload_failed"}} =
                 Req.post!(url <> "/api/v1/extensions/reload", json: %{}, headers: headers, retry: false)
               "v1 stable:ok" = Agent.get(Fixture.HotExt.Probe, & &1)
               {:ok, %{content: [%{"text" => "v1-stable"}]}} = Fixture.HotExt.Profile.Tool.execute(%{}, %{})

               # 3. Lingering process in old code -> 409 modules_in_use (never hard-kills worker!)
               parent = self()
               # Spawn a process that runs a loop inside v1 code, then reload to v2 (puts v1 in old code),
               # then attempt reload to v1 again while the process is STILL lingering in old v1 code.
               linger = spawn(fn ->
                 Fixture.HotExt.Profile.Tool.hold(parent)
               end)
               receive do :holding -> :ok after 2000 -> raise "linger did not enter" end

               # First swap v1 -> v2 succeeds (v1 moves to old code, linger keeps running safely!)
               File.write!(ext_json, JSON.encode!(%{"version" => 1, "extensions" => [%{"path" => #{inspect(pkg_v2)}, "settings" => %{"tag" => "two"}}]}))
               %{status: 200, body: %{"generation" => 2}} =
                 Req.post!(url <> "/api/v1/extensions/reload", json: %{}, headers: headers, retry: false)
               true = Process.alive?(linger)

               # Second swap while linger is STILL in old v1 code -> rejected safely with 409!
               File.write!(ext_json, JSON.encode!(%{"version" => 1, "extensions" => [%{"path" => #{inspect(pkg_v1)}, "settings" => %{"tag" => "back"}}]}))
               %{status: 409, body: %{"error" => "modules_in_use", "modules" => mods}} =
                 Req.post!(url <> "/api/v1/extensions/reload", json: %{}, headers: headers, retry: false)
               true = "Elixir.Fixture.HotExt.Profile.Tool" in mods
               true = Process.alive?(linger)

               # Once the lingering worker finishes naturally, reload succeeds cleanly
               send(linger, :release)
               receive do :released -> :ok after 2000 -> raise "linger did not exit" end
               Process.sleep(20)

               %{status: 200, body: %{"generation" => 3}} =
                 Req.post!(url <> "/api/v1/extensions/reload", json: %{}, headers: headers, retry: false)
               "v1 stable:back" = Agent.get(Fixture.HotExt.Probe, & &1)

               # 4. Disabling all extensions cleanly stops extension children & unloads modules
               File.write!(ext_json, JSON.encode!(%{"version" => 1, "extensions" => []}))
               %{status: 200, body: %{"generation" => 4, "extensions" => []}} =
                 Req.post!(url <> "/api/v1/extensions/reload", json: %{}, headers: headers, retry: false)
               nil = Process.whereis(Fixture.HotExt.Probe)
               false = :code.is_loaded(Fixture.HotExt)

               IO.puts("ROLLBACK_AND_SAFETY_OK")
               """)

      assert output =~ "ROLLBACK_AND_SAFETY_OK"
    end

    test "rejects hot reload when daemon booted with --no-extensions", ctx do
      assert {output, 0} =
               launch("""
               {:ok, %{url: url}} = H.serve(
                 data_dir: #{inspect(ctx.data_dir)},
                 port: 0,
                 provider: #{inspect(Fake)},
                 no_extensions: true
               )
               token = H.Auth.owner_token()
               headers = [{"authorization", "Bearer " <> token}]

               %{status: 200, body: %{"no_extensions" => true, "extensions" => []}} =
                 Req.get!(url <> "/api/v1/extensions", headers: headers, retry: false)

               %{status: 409, body: %{"error" => "extensions_disabled"}} =
                 Req.post!(url <> "/api/v1/extensions/reload", json: %{}, headers: headers, retry: false)

               IO.puts("DISABLED_OK")
               """)

      assert output =~ "DISABLED_OK"
    end
  end

  defp local_tmp(path), do: if(File.dir?(path), do: path, else: System.tmp_dir!())

  defp write_extensions_json(data_dir, entries) do
    File.write!(
      Path.join(data_dir, "extensions.json"),
      JSON.encode!(%{"version" => 1, "extensions" => entries})
    )
  end

  defp compile_extension(dir, tool_output, instruction_prefix, opts) do
    include_second_tool? = Keyword.get(opts, :include_second_tool?, false)
    fail_child? = Keyword.get(opts, :fail_child?, false)
    env_id = if include_second_tool?, do: "fixture.hot.env.v2", else: "fixture.hot.env.v1"

    File.mkdir_p!(Path.join(dir, "ebin"))

    File.write!(
      Path.join(dir, "extension.json"),
      JSON.encode!(%{
        "id" => "fixture.hot",
        "api_version" => 1,
        "module" => "Elixir.Fixture.HotExt"
      })
    )

    extra_tool_mod =
      if include_second_tool? do
        """
        defmodule Fixture.HotExt.Profile.Extra do
          @behaviour H.Tool
          @impl true
          def name, do: "hot_extra"
          @impl true
          def description, do: "Second tool added in v2"
          @impl true
          def parameters_schema, do: %{"type" => "object", "additionalProperties" => false}
          @impl true
          def replay, do: :safe
          @impl true
          def mutating?, do: false
          @impl true
          def execute(%{}, _ctx) do
            {:ok, %{content: [%{"type" => "text", "text" => "extra-from-v2"}], details: %{}, is_error: false, diagnostic: nil}}
          end
        end
        """
      else
        ""
      end

    tools_list =
      if include_second_tool?,
        do: "[Fixture.HotExt.Profile.Tool, Fixture.HotExt.Profile.Extra]",
        else: "[Fixture.HotExt.Profile.Tool]"

    probe_start =
      if fail_child? do
        "def start_link(_text), do: {:error, :hot_probe_failed}"
      else
        "def start_link(text), do: Agent.start_link(fn -> text end, name: __MODULE__)"
      end

    src = """
    defmodule Fixture.HotExt do
      @behaviour H.Extension

      @impl true
      def configure(%{"tag" => tag}, context) when is_binary(tag) do
        {:ok,
         %{
           harnesses: [Fixture.HotExt.Profile],
           environments: [
             %{
               id: #{inspect(env_id)},
               label: "Hot Env",
               kind: "host",
               default_cwd: context.data_dir,
               build: fn cwd -> H.ExecutionEnv.Host.new(cwd, env_id: #{inspect(env_id)}) end
             }
           ],
           children: [{Fixture.HotExt.Probe, #{inspect(instruction_prefix)} <> ":" <> tag}]
         }}
      end

      def configure(_, _), do: {:error, :invalid_settings}
    end

    defmodule Fixture.HotExt.Probe do
      use Agent
      #{probe_start}
    end

    defmodule Fixture.HotExt.Profile do
      @behaviour H.Harness

      @impl true
      def id, do: "fixture.hot.profile"

      @impl true
      def descriptor, do: %{id: id(), name: "Hot", description: "Hot-reloaded profile"}

      @impl true
      def tools(_opts), do: #{tools_list}

      @impl true
      def bootstrap_agent(_env, overrides, _opts) do
        {:ok, Map.merge(%{instructions: Agent.get(Fixture.HotExt.Probe, & &1), tools: ["hot_tool"]}, overrides)}
      end
    end

    defmodule Fixture.HotExt.Profile.Tool do
      @behaviour H.Tool
      @impl true
      def name, do: "hot_tool"
      @impl true
      def description, do: "Returns versioned text"
      @impl true
      def parameters_schema, do: %{"type" => "object", "additionalProperties" => false}
      @impl true
      def replay, do: :safe
      @impl true
      def mutating?, do: false
      @impl true
      def execute(%{}, _ctx) do
        {:ok, %{content: [%{"type" => "text", "text" => #{inspect(tool_output)}}], details: %{}, is_error: false, diagnostic: nil}}
      end

      def hold(parent) do
        send(parent, :holding)
        receive do
          :release -> send(parent, :released)
        end
      end
    end

    #{extra_tool_mod}
    """

    src_path = Path.join(dir, "hot_ext.ex")
    File.write!(src_path, src)
    ebin = Path.join(dir, "ebin")

    assert {_, 0} =
             launch("""
             {:ok, _, []} = Kernel.ParallelCompiler.compile_to_path([#{inspect(src_path)}], #{inspect(ebin)})
             """)
  end

  defp launch(script) do
    pa_args =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.map(&Path.expand/1)
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
