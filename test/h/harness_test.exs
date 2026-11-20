defmodule H.HarnessTest do
  use ExUnit.Case, async: true

  alias H.Document
  alias H.ExecutionEnv
  alias H.ExecutionEnv.Host
  alias H.Harness
  alias H.Harness.Coding

  defmodule FakeAuditHarness do
    @behaviour H.Harness

    @impl true
    def id, do: "audit"

    @impl true
    def descriptor, do: %{id: "audit", name: "Audit", description: "Read-only audit harness"}

    @impl true
    def tools(_opts \\ []), do: [H.Tools.Read, H.Tools.SearchHistory]

    @impl true
    def bootstrap_agent(_env, overrides \\ %{}, _opts \\ []), do: {:ok, overrides}
  end

  defmodule VirtualExecutionEnv do
    @moduledoc false
    @behaviour H.ExecutionEnv

    def new(cwd, files) when is_binary(cwd) and is_map(files) do
      ExecutionEnv.new(__MODULE__, %{cwd: cwd, files: files})
    end

    @impl true
    def cwd(%{cwd: cwd}), do: cwd

    @impl true
    def resolve_path(%{cwd: cwd}, path) do
      {:ok, Path.expand(path, cwd)}
    end

    @impl true
    def read_file_lines(_state, _path, _opts), do: {:error, :enoent}

    @impl true
    def read_file_bytes(%{files: files} = state, path, opts) do
      {:ok, resolved} = resolve_path(state, path)
      max_bytes = Keyword.get(opts, :max_bytes, 65_536)

      case Map.fetch(files, resolved) do
        {:ok, content} when byte_size(content) > max_bytes -> {:error, :file_too_large}
        {:ok, content} -> {:ok, content}
        :error -> {:error, :enoent}
      end
    end

    @impl true
    def write_file(_state, _path, _content), do: {:error, :eacces}

    @impl true
    def list_dir(_state, _path, _opts), do: {:ok, %{entries: [], next_cursor: nil}}

    @impl true
    def exec(_state, _command, _opts), do: {:error, :unsupported}
  end

  setup do
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "h-harness-test-#{System.unique_integer([:positive, :monotonic])}-#{rand}"
      )
      |> Path.expand()

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "resolve/2" do
    test "resolves nil, \"coding\", and \"pi\" to H.Harness.Coding" do
      assert {:ok, Coding} = Harness.resolve(nil)
      assert {:ok, Coding} = Harness.resolve("coding")
      assert {:ok, Coding} = Harness.resolve("pi")
    end

    test "supports custom :harnesses map or module list and rejects unknown strings without creating atoms" do
      unknown = "unknown_harness_#{System.unique_integer([:positive])}"
      assert {:error, :unknown_harness} = Harness.resolve(unknown)

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(unknown)
      end

      assert {:error, :unknown_harness} = Harness.resolve("")

      assert {:ok, FakeAuditHarness} =
               Harness.resolve("audit", harnesses: %{"audit" => FakeAuditHarness})

      assert {:ok, FakeAuditHarness} =
               Harness.resolve("audit", harnesses: [FakeAuditHarness])
    end
  end

  describe "H.Harness.Coding metadata and tools/1" do
    test "declares coding id, descriptor, and full coding toolset" do
      assert Coding.id() == "coding"
      assert %{id: "coding", name: "Coding", description: desc} = Coding.descriptor()
      assert desc != ""

      assert Coding.tools() == [
               H.Tools.Read,
               H.Tools.Write,
               H.Tools.Edit,
               H.Tools.Bash,
               H.Tools.SearchHistory,
               H.Tools.Subagent
             ]

      assert Coding.tools(session_depth: 1, max_subagent_depth: 1) == [
               H.Tools.Read,
               H.Tools.Write,
               H.Tools.Edit,
               H.Tools.Bash,
               H.Tools.SearchHistory
             ]
    end
  end

  describe "H.Harness.Coding.bootstrap_agent/3" do
    test "discovers AGENTS.md from stop_dir down to cwd outermost-to-innermost on disposable host dir",
         %{tmp_dir: tmp_dir} do
      above_stop = Path.join(tmp_dir, "above")
      workspace = Path.join(above_stop, "workspace")
      sub = Path.join(workspace, "apps/api")
      File.mkdir_p!(sub)

      File.write!(Path.join(above_stop, "AGENTS.md"), "# should NOT be included\n")
      File.write!(Path.join(workspace, "AGENTS.md"), "# Workspace rules\n")
      File.write!(Path.join(workspace, "apps/AGENTS.md"), "   \n\n")
      File.write!(Path.join(sub, "AGENTS.md"), "# API rules\n")

      env = Host.new(sub)

      assert {:ok, overrides} =
               Coding.bootstrap_agent(env, %{"model" => "fake:test"}, stop_dir: workspace)

      assert overrides["model"] == "fake:test"
      assert overrides["tools"] == ["read", "write", "edit", "bash", "search_history", "subagent"]
      assert overrides["instructions"] == "# Workspace rules\n\n# API rules"

      {agent, _ops} = Document.configure_agent(Document.initial("agent"), overrides)
      assert agent["model"] == "fake:test"
      assert agent["instructions"] == "# Workspace rules\n\n# API rules"
    end

    test "discovers AGENTS.md exclusively through H.ExecutionEnv (works on non-host virtual env)" do
      env =
        VirtualExecutionEnv.new("/virtual/repo/packages/core", %{
          "/virtual/AGENTS.md" => "outermost",
          "/virtual/repo/AGENTS.md" => "repo rule",
          "/virtual/repo/packages/core/AGENTS.md" => "core rule"
        })

      assert {:ok, overrides} = Coding.bootstrap_agent(env, %{}, stop_dir: "/virtual/repo")
      assert overrides["instructions"] == "repo rule\n\ncore rule"
    end

    test "preserves explicit non-nil instructions and replaces nil instructions with discovered AGENTS.md",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "discovered rule\n")
      env = Host.new(tmp_dir)

      assert {:ok, str_override} =
               Coding.bootstrap_agent(env, %{"instructions" => "explicit string"},
                 stop_dir: tmp_dir
               )

      assert str_override["instructions"] == "explicit string"

      assert {:ok, atom_override} =
               Coding.bootstrap_agent(env, %{instructions: "explicit atom"}, stop_dir: tmp_dir)

      assert atom_override[:instructions] == "explicit atom"
      refute Map.has_key?(atom_override, "instructions")

      assert {:ok, nil_override} =
               Coding.bootstrap_agent(env, %{instructions: nil}, stop_dir: tmp_dir)

      assert nil_override["instructions"] == "discovered rule"
      refute Map.has_key?(nil_override, :instructions)
    end

    test "skips AGENTS.md files larger than 64 KiB and omits instructions when none found", %{
      tmp_dir: tmp_dir
    } do
      sub = Path.join(tmp_dir, "sub")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "AGENTS.md"), String.duplicate("x", 65_537))

      env = Host.new(sub)
      assert {:ok, overrides} = Coding.bootstrap_agent(env, %{}, stop_dir: tmp_dir)
      refute Map.has_key?(overrides, "instructions")
    end

    test "bounds ancestor traversal to at most 25 parent hops" do
      deep_segments = Enum.map(1..30, &"d#{&1}")
      deep_cwd = "/" <> Path.join(deep_segments)

      files = %{
        ("/" <> Path.join(Enum.take(deep_segments, 2)) <> "/AGENTS.md") => "too far up",
        ("/" <> Path.join(Enum.take(deep_segments, 5)) <> "/AGENTS.md") => "at 25th parent hop",
        (deep_cwd <> "/AGENTS.md") => "leaf"
      }

      env = VirtualExecutionEnv.new(deep_cwd, files)
      assert {:ok, overrides} = Coding.bootstrap_agent(env, %{})
      assert overrides["instructions"] == "at 25th parent hop\n\nleaf"
    end
  end
end
