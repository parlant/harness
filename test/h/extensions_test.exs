defmodule H.ExtensionsTest do
  use ExUnit.Case, async: false

  alias H.Daemon.CLI
  alias H.Provider.Fake

  setup do
    root =
      Path.join(
        local_tmp("/private/tmp"),
        "h-ext-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    data_dir = Path.join(root, "data")
    package = Path.join(root, "pkg")
    cwd = Path.join(root, "work")
    Enum.each([data_dir, package, cwd], &File.mkdir_p!/1)

    on_exit(fn ->
      File.rm(H.StoreLock.socket_path(data_dir))
      File.rm_rf!(root)
    end)

    {:ok, data_dir: data_dir, package: package, cwd: cwd}
  end

  describe "CLI.parse/1" do
    test "accepts both bypass flags and rejects invalid daemon options" do
      for flag <- ["-ne", "--no-extensions"] do
        assert {:ok, opts} = CLI.parse([flag, "--port", "0", "--data-dir", "/store"])
        assert opts == [no_extensions: true, port: 0, data_dir: "/store"]
      end

      assert {:ok, [no_extensions: false]} = CLI.parse([])
      assert {:error, :usage} = CLI.parse(["--port", "70000"])
      assert {:error, :usage} = CLI.parse(["--unknown"])
      assert :help = CLI.parse(["--help"])
    end
  end

  describe "daemon startup" do
    test "rejects missing, incompatible, duplicate and corrupt packages before serving", ctx do
      configure(ctx, [%{"path" => "../pkg"}])
      assert_boot_failure(ctx, ~r/manifest.*enoent/)

      manifest(ctx.package, 999)
      assert_boot_failure(ctx, ~r/incompatible_extension_api/)

      manifest(ctx.package, 1)
      configure(ctx, [%{"path" => "../pkg"}, %{"path" => ctx.package}])
      assert_boot_failure(ctx, ~r/duplicate.*extension_id/)

      configure(ctx, [%{"path" => "../pkg"}])
      File.mkdir_p!(Path.join(ctx.package, "ebin"))
      File.write!(Path.join(ctx.package, "ebin/Elixir.Fixture.BootExtension.beam"), "not a beam")
      assert_boot_failure(ctx, ~r/invalid_or_conflicting_beam/)
    end

    test "starts stock with absent or disabled packages and bypasses invalid config entirely",
         ctx do
      for config <- [
            :absent,
            %{"version" => 1, "extensions" => [%{"path" => "missing", "enabled" => false}]},
            :malformed
          ] do
        config_path = Path.join(ctx.data_dir, "extensions.json")

        unless config == :absent,
          do:
            File.write!(config_path, if(is_map(config), do: JSON.encode!(config), else: "broken"))

        if config == :malformed do
          File.rm!(Path.join(ctx.data_dir, "daemon.json"))
          assert_boot_failure(ctx, ~r/invalid_extensions_json/)
        end

        args = if config == :malformed, do: ["-ne"], else: []

        assert {output, 0} =
                 launch(
                   """
                   {:ok, opts} = H.Daemon.CLI.parse(System.argv())
                   {:ok, _} = H.serve(Keyword.merge([data_dir: #{inspect(ctx.data_dir)}, port: 0, provider: H.Provider.Fake], opts))
                   boot = H.Daemon.instance_options()
                   false = :code.is_loaded(Fixture.BootExtension)
                   {:ok, %{session: %{harness_id: "coding"}}} = H.Daemon.create_session(%{"cwd" => #{inspect(ctx.cwd)}}, boot)
                   IO.puts("STOCK")
                   """,
                   args
                 )

        assert output =~ "STOCK"
      end
    end

    test "stock account configuration is available without a policy extension",
         ctx do
      path = Path.join(ctx.data_dir, "accounts.json")

      File.write!(
        path,
        JSON.encode!(%{version: 1, openai_codex: %{sources: ["personal", "work"]}})
      )

      assert {output, 0} =
               launch("""
               {:ok, %{url: url, api_socket: socket}} = H.serve(data_dir: #{inspect(ctx.data_dir)}, port: 0)
               token = H.Auth.owner_token()
               opts = [headers: [{"authorization", "Bearer " <> token}], retry: false]
               %{status: 200, body: %{"providers" => [%{"sources" => [%{"id" => "personal"}, %{"id" => "work"}]}]}} =
                 Req.get!(url <> "/api/v1/provider-logins", opts)
               %{status: 200, body: %{"providers" => [_]}} =
                 Req.get!("http://localhost/api/v1/provider-logins", [unix_socket: socket] ++ opts)
               IO.puts("ACCOUNTS_BOOTED")
               """)

      assert output =~ "ACCOUNTS_BOOTED"
      File.rm!(Path.join(ctx.data_dir, "daemon.json"))
      File.write!(path, "broken")
      assert_boot_failure(ctx, ~r/invalid_accounts_json/)
    end

    test "loads the real MultiCodex artifact only by path and validates its pool", ctx do
      source = Path.expand("extensions/multicodex")
      File.cp!(Path.join(source, "extension.json"), Path.join(ctx.package, "extension.json"))
      ebin = Path.join(ctx.package, "ebin")
      File.mkdir!(ebin)

      assert {_, 0} =
               launch("""
               {:ok, _, []} = Kernel.ParallelCompiler.compile_to_path(#{inspect(Path.wildcard(Path.join(source, "lib/*.ex")))}, #{inspect(ebin)})
               """)

      pool = %{"path" => "../pkg", "settings" => %{"sources" => ["personal", "work"]}}
      path = Path.join(ctx.data_dir, "accounts.json")
      configure(ctx, [pool])
      # Neither alias is signed in; the real package cannot contact a provider.
      assert {output, 0} =
               launch("""
               {:ok, _} = H.serve(data_dir: #{inspect(ctx.data_dir)}, port: 0)
               opts = H.Daemon.instance_options()
               %{module: Extensions.MultiCodex, sources: ["personal", "work"]} = opts[:codex_account_policy]
               true = is_pid(Process.whereis(Extensions.MultiCodex))
               [] = Extensions.MultiCodex.order("test-model", ["personal", "work"])
               false = File.exists?(Path.join(boot_dir = opts[:data_dir], "accounts.json"))
               :ok = H.Auth.owner_token() |> then(fn token ->
                 opts = [headers: [{"authorization", "Bearer " <> token}], retry: false]
                 url = JSON.decode!(File.read!(Path.join(boot_dir, "daemon.json")))["http_url"]
                 %{status: 200, body: %{"providers" => [%{"sources" => []}]}} = Req.get!(url <> "/api/v1/provider-logins", opts)
                 :ok
               end)
               models = H.Daemon.list_models(opts)
               true = Enum.any?(models, &match?(%{provider: "openai_codex", unavailable_reason: "Codex sign-in required (/login)"}, &1))
               {:error, %{code: "codex_accounts_unavailable"}} = H.Provider.ReqLLM.stream_turn(Map.new(Keyword.take(opts, [:accounts, :codex_account_policy])), %{model: "openai_codex:gpt-6.1-sol"}, fn _ -> :ok end)
               IO.puts("MULTICODEX_LOADED")
               """)

      assert output =~ "MULTICODEX_LOADED"

      File.write!(
        path,
        JSON.encode!(%{version: 1, openai_codex: %{sources: ["personal", "work"]}})
      )

      assert {output, 0} =
               launch("""
               {:ok, _} = H.serve(data_dir: #{inspect(ctx.data_dir)}, port: 0, no_extensions: true)
               opts = H.Daemon.instance_options()
               nil = opts[:codex_account_policy]
               nil = Process.whereis(Extensions.MultiCodex)
               true = is_pid(Process.whereis(H.Accounts))
               {:ok, %{providers: [%{sources: [%{id: "personal", active: true}, %{id: "work", active: false}]}]}} = H.Accounts.discover(H.Accounts)
               IO.puts("STOCK_ACCOUNTS")
               """)

      assert output =~ "STOCK_ACCOUNTS"
    end

    test "pooled inference interrupted in a separate VM is not replayed after stock boot", ctx do
      path = Path.join(ctx.data_dir, "accounts.json")

      File.write!(
        path,
        JSON.encode!(%{version: 1, openai_codex: %{sources: ["fixture", "other"]}})
      )

      assert {first, 0} =
               launch("""
               dir = #{inspect(ctx.data_dir)}
               File.chmod!(dir, 0o700)
               {:ok, vault, %{}} = H.Accounts.Vault.open(dir, [])
               :ok = H.Accounts.Vault.write(vault, "fixture", %{
                 "access_token" => "fixture-access", "refresh_token" => "fixture-grant",
                 "account_id" => "fixture-account", "subject" => "fixture-user",
                 "expires_at_ms" => System.system_time(:millisecond) + 120_000
               })
               defmodule PoolFixture do
                 def order(_, candidates), do: candidates
                 def rejected(_, _, _), do: :ok
               end
               policy = %{module: PoolFixture, sources: ["fixture", "other"]}
               owner = self()
               stream = fn _, _, _ ->
                 send(owner, :dispatched)
                 receive do
                   :unreached -> {:error, "unreached"}
                 end
               end
               {:ok, _} = H.serve(data_dir: dir, port: 0, provider_config: %{stream_fn: stream}, codex_account_policy: policy,
                                  default_model: "openai_codex:gpt-6.1-sol", storage_opts: [sync: :datasync])
               boot = H.Daemon.instance_options()
               {:ok, _} = H.Daemon.create_session(%{"session_id" => "managed-vm", "cwd" => #{inspect(ctx.cwd)}}, boot)
               {:ok, _} = H.Daemon.execute_command("managed-vm", %{"version" => 1, "request_id" => "first", "command" => "submit", "conversation_id" => "1", "args" => %{"type" => "input", "content" => "test"}}, boot)
               receive do
                 :dispatched -> :ok
               after
                 3000 -> raise "managed request not dispatched"
               end
               [{server, _}] = Registry.lookup(boot[:registry], {:session, "managed-vm"})
               {:ok, %{tasks: tasks}} = H.Session.Server.get_detail(server)
               true = Enum.any?(tasks, &match?(%{kind: "generation", status: "running", checkpoint: %{"dispatch_policy" => %{"max_dispatches" => 2}}}, &1))
               IO.puts("IN_FLIGHT")
               System.halt(0)
               """)

      assert first =~ "IN_FLIGHT"

      assert {second, 0} =
               launch("""
               boot = #{boot_script(ctx, "[]", no_extensions: true)}
               {:ok, %{tasks: tasks}} = H.Daemon.get_session_detail("managed-vm", boot)
               true = Enum.any?(tasks, &match?(%{kind: "generation", status: "terminal", outcome: %{"reason" => "interrupted"}}, &1))
               [] = H.Provider.Fake.requests()
               IO.puts("NOT_REPLAYED")
               """)

      assert second =~ "NOT_REPLAYED"
    end

    test "loads a built extension once for TCP, UDS and a new VM's boot recovery", ctx do
      compile_fixture(ctx.package)
      configure(ctx, [package_entry("extension booted")])

      assert {first, 0} =
               launch("""
               boot = #{boot_script(ctx, "[{ :gate, self(), :never }]")}
               url = JSON.decode!(File.read!(Path.join(boot[:data_dir], "daemon.json")))["http_url"]
               token = H.Auth.owner_token()
               headers = [{"authorization", "Bearer " <> token}]
               create = %{"session_id" => "extension", "harness_id" => "fixture.profile", "env_id" => "fixture.env", "cwd" => #{inspect(ctx.cwd)}}
               %{status: 200, body: %{"session" => %{"harness_id" => "fixture.profile", "env_id" => "fixture.env"}}} =
                 Req.post!(url <> "/api/v1/sessions", json: create, headers: headers, retry: false)
               unix = [url: "http://localhost/api/v1/sessions", unix_socket: H.api_socket_path(boot[:data_dir]), headers: headers, retry: false]
               %{status: 200, body: %{"session" => %{"harness_id" => "fixture.profile"}}} =
                 Req.post!([json: Map.drop(create, ["harness_id", "env_id"])] ++ unix)
               %{status: 409} = Req.post!([json: %{create | "harness_id" => "coding"}] ++ unix)
               %{status: 409} = Req.post!([json: %{create | "env_id" => "host"}] ++ unix)
               %{status: 200} = Req.post!(url <> "/api/v1/sessions", json: %{create | "session_id" => "profile-only", "env_id" => "host"}, headers: headers, retry: false)
               {:ok, _} = H.Daemon.execute_command("extension", %{"version" => 1, "request_id" => "first", "command" => "submit", "conversation_id" => "1", "args" => %{"type" => "input", "content" => "test"}}, boot)
               receive do
                 {:gate_entered, :never, _worker} -> :ok
               after
                 3000 -> raise "fake effect never started"
               end
               { :ok, %{active: true} } = H.Catalog.get_session("extension")
               [%{messages: [%{role: "system", content: [%{text: "extension booted"}]} | _], tools: [%{name: "fixture_constant"}]}] = H.Provider.Fake.requests()
               IO.puts("FIRST")
               System.halt(0)
               """)

      assert first =~ "FIRST"

      # No extension identity is silently replaced during recovery, including
      # when an operator explicitly asks for stock startup on the same store.
      assert {disabled, 0} =
               launch("""
               boot = #{boot_script(ctx, "[]", no_extensions: true)}
               [] = Registry.lookup(boot[:registry], {:session, "extension"})
               {:error, :workspace_unavailable} = H.Daemon.get_session_detail("extension", boot)
               {:error, :harness_unavailable} = H.Daemon.get_session_detail("profile-only", boot)
               {:ok, %{active: true, env_id: "fixture.env", harness_id: "fixture.profile"}} = H.Catalog.get_session("extension")
               false = :code.is_loaded(Fixture.BootExtension)
               [] = H.Provider.Fake.requests()
               """)

      assert disabled =~ "boot recovery unavailable (workspace_unavailable)"

      assert {recovered, 0} =
               launch("""
               boot = #{boot_script(ctx, ~s([{:reply, [], %{content: [%{type: "text", text: "Recovered"}]}}]))}
               [{pid, _}] = Registry.lookup(boot[:registry], {:session, "extension"})
               true = Process.alive?(pid)
               true = is_pid(Process.whereis(Fixture.BootExtension.Probe))
               poll = fn poll, n ->
                 {:ok, page} = H.Daemon.scan_entries("extension", "1", %{}, boot)
                 if Enum.any?(page.items, &String.contains?(JSON.encode!(&1), "Recovered")) do
                   :ok
                 else
                   if n == 0, do: raise("did not recover")
                   Process.sleep(20)
                   poll.(poll, n - 1)
                 end
               end
               :ok = poll.(poll, 150)
               [%{messages: [%{role: "system", content: [%{text: "extension booted"}]} | _], tools: [%{name: "fixture_constant"}]}] = H.Provider.Fake.requests()
               probe = Process.whereis(Fixture.BootExtension.Probe)
               supervisor = Process.whereis(H.Daemon.Instance)
               :ok = Supervisor.stop(supervisor)
               false = Process.alive?(probe)
               [] = H.Provider.Fake.remaining()
               IO.puts("RECOVERED")
               """)

      assert recovered =~ "RECOVERED"
    end

    test "does not dispatch an installed tool excluded by the agent's selection", ctx do
      compile_fixture(ctx.package)
      configure(ctx, [package_entry("extension booted")])

      assert {output, 0} =
               launch("""
               boot = #{boot_script(ctx, ~s|[
                 {:reply, [], %{tool_calls: [%{id: "denied", name: "fixture_constant", arguments: %{}}], finish_reason: "tool_calls"}},
                 {:gate, self(), :seen}
               ]|)}
               {:ok, _} = H.Daemon.create_session(%{"session_id" => "no-tools", "cwd" => #{inspect(ctx.cwd)}, "harness_id" => "fixture.profile", "agent" => %{"tools" => []}}, boot)
               {:ok, _} = H.Daemon.execute_command("no-tools", %{"version" => 1, "request_id" => "req", "command" => "submit", "conversation_id" => "1", "args" => %{"type" => "input", "content" => "test"}}, boot)
               receive do
                 {:gate_entered, :seen, _worker} -> :ok
               after
                 3000 -> raise "fake follow-up never started"
               end
               [%{tools: []}, %{messages: messages, tools: []}] = H.Provider.Fake.requests()
               true = Enum.any?(messages, &match?(%{role: "tool", is_error: true, tool_call_id: "denied"}, &1))
               IO.puts("DENIED")
               """)

      assert output =~ "DENIED"
    end

    test "invalid contributions or a failing child prevent serving; bootstrap failures don't create sessions",
         ctx do
      compile_fixture(ctx.package)
      configure(ctx, [%{"path" => ctx.package}])
      assert_boot_failure(ctx, ~r/invalid_settings/)

      configure(ctx, [package_entry("duplicate profile")])
      assert_boot_failure(ctx, ~r/duplicate.*harness_id/)

      configure(ctx, [package_entry("fail to start")])
      assert_boot_failure(ctx, ~r/probe_start_failed/)

      configure(ctx, [package_entry("bad bootstrap")])

      assert {output, 0} =
               launch("""
               boot = #{boot_script(ctx, "[]")}
               {:error, :harness_unavailable} = H.Daemon.create_session(%{"cwd" => #{inspect(ctx.cwd)}, "harness_id" => "fixture.profile"}, boot)
               [] = H.Daemon.list_sessions(boot)
               IO.puts("REJECTED")
               """)

      assert output =~ "REJECTED"
    end
  end

  defp local_tmp(path), do: if(File.dir?(path), do: path, else: System.tmp_dir!())

  defp configure(ctx, entries),
    do:
      File.write!(
        Path.join(ctx.data_dir, "extensions.json"),
        JSON.encode!(%{"version" => 1, "extensions" => entries})
      )

  defp manifest(dir, version) do
    File.write!(
      Path.join(dir, "extension.json"),
      JSON.encode!(%{
        "id" => "fixture.boot",
        "api_version" => version,
        "module" => "Elixir.Fixture.BootExtension"
      })
    )
  end

  defp package_entry(text), do: %{"path" => "../pkg", "settings" => %{"instructions" => text}}

  defp compile_fixture(dir) do
    manifest(dir, 1)
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)

    assert {_, 0} =
             launch("""
             {:ok, _, []} = Kernel.ParallelCompiler.compile_to_path([#{inspect(Path.expand("fixtures/extensions/boot.ex"))}], #{inspect(ebin)})
             """)
  end

  defp assert_boot_failure(ctx, regex) do
    assert {output, 0} =
             launch("""
             {:error, reason} = H.serve(data_dir: #{inspect(ctx.data_dir)}, port: 0, provider: H.Provider.Fake)
             nil = Process.whereis(H.Daemon.HTTP)
             nil = H.Daemon.instance_options()
             false = File.exists?(Path.join(#{inspect(ctx.data_dir)}, "daemon.json"))
             IO.inspect(reason)
             """)

    assert output =~ regex
  end

  defp boot_script(ctx, script, opts \\ []) do
    """
    (fn ->
      {:ok, _} = H.Provider.Fake.start_link(name: H.Provider.Fake, script: #{script})
      {:ok, _} = H.serve(#{inspect([data_dir: ctx.data_dir, port: 0, provider: Fake, default_model: "fake:coder", retry_backoff_ms: 5] ++ opts)})
      H.Daemon.instance_options()
    end).()
    """
  end

  defp launch(script, args \\ []) do
    # Finite scripts in fresh VMs, with no inherited H_DATA_DIR and no real provider calls.
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
          "Application.put_env(:req_llm, :load_dotenv, false)\n" <> script,
          "--" | args
        ],
      stderr_to_stdout: true,
      env: [{"H_DATA_DIR", nil}]
    )
  end
end
