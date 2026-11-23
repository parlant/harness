defmodule HWeb.SlashCommandsTest do
  use ExUnit.Case, async: true

  alias HWeb.SlashCommands

  defmodule FakeBackend do
    def list_files(params) do
      send(self(), {:list_files, params})

      case {params["cwd"], params["include_hidden"]} do
        {"/work/project", false} ->
          {:ok,
           %{
             entries: [
               %{path: "README.md", type: "file"},
               %{path: "clients", type: "dir"},
               %{path: "lib", type: "dir"},
               %{path: "mix.exs", type: "file"},
               %{path: "a b.txt", type: "file"}
             ]
           }}

        {"/work/project", true} ->
          {:ok,
           %{
             entries: [
               %{path: ".config", type: "dir"},
               %{path: ".env", type: "file"},
               %{path: "lib", type: "dir"}
             ]
           }}

        {"/work/project/clients", _} ->
          {:ok,
           %{
             entries: [
               %{path: "tui", type: "dir"},
               %{path: "web", type: "dir"}
             ]
           }}

        {"/Users/alice", false} ->
          {:ok,
           %{
             entries: [
               %{path: "Projects", type: "dir"},
               %{path: "notes.txt", type: "file"}
             ]
           }}

        {"/etc", false} ->
          {:ok, %{entries: [%{path: "hosts", type: "file"}, %{path: "ssl", type: "dir"}]}}

        _ ->
          {:error, :not_found}
      end
    end

    def list_session_files(sid, params) do
      send(self(), {:list_session_files, sid, params})

      {:ok,
       %{
         entries: [
           %{path: "lib/h_web/slash_commands.ex", type: "file"},
           %{path: "lib/h_web", type: "dir"},
           %{path: "README.md", type: "file"}
         ]
       }}
    end
  end

  describe "parse_input/1" do
    test "parses known commands, bare slash, args, escaped slash, shell, and unknown commands" do
      assert {:command, "/help", ""} = SlashCommands.parse_input("/")
      assert {:command, "/help", ""} = SlashCommands.parse_input("/help")
      assert {:command, "/tree", ""} = SlashCommands.parse_input("  /TREE  ")
      assert {:command, "/thinking", "high"} = SlashCommands.parse_input("/thinking high")
      assert {:command, "/cwd", "../other"} = SlashCommands.parse_input("/cwd   ../other ")
      assert {:unknown_command, "/bogus"} = SlashCommands.parse_input("/bogus arg")
      assert {:message, "/literal"} = SlashCommands.parse_input("//literal")
      assert {:user_shell, "git status", true} = SlashCommands.parse_input("!git status")
      assert {:user_shell, "ls -la", false} = SlashCommands.parse_input("!!ls -la")
      assert {:message, "line1\n/tree"} = SlashCommands.parse_input("line1\n/tree")
      assert {:message, "/first\nsecond"} = SlashCommands.parse_input("/first\nsecond")
    end
  end

  describe "match_commands/1 and ghost_suffix/2" do
    test "matches commands by prefix first then substring and computes ghost suffix" do
      matches = SlashCommands.match_commands("/tr")
      assert [%{name: "/tree"} | _] = matches
      assert SlashCommands.ghost_suffix("/tr", "/tree") == "ee"
      assert SlashCommands.ghost_suffix("/TR", "/tree") == "ee"
      assert SlashCommands.ghost_suffix("/tree", "/tree") == ""
      assert SlashCommands.ghost_suffix("/xyz", "/tree") == ""

      all = SlashCommands.match_commands("/")
      assert length(all) == length(SlashCommands.all())
    end
  end

  describe "complete_command_args/3" do
    test "completes thinking, attention, archive, fork, and model arguments" do
      assert [%{value: "high"}] = SlashCommands.complete_command_args("/thinking", "hi")

      assert Enum.map(SlashCommands.complete_command_args("/attention", ""), & &1.value) == [
               "on",
               "off"
             ]

      assert [%{value: "force"}] = SlashCommands.complete_command_args("/archive", "f")
      assert [%{value: "cancel"}] = SlashCommands.complete_command_args("/fork", "can")

      models = [
        %{id: "fake:coder", label: "Fake Coder", provider: "fake"},
        %{id: "fake:chat", label: "Fake Chat", provider: "fake"},
        %{id: "openai:gpt-5", label: "GPT 5", provider: "openai"}
      ]

      assert [%{value: "fake:chat"}] =
               SlashCommands.complete_command_args("/model", "fake:ch", models: models)

      assert [%{value: "openai:gpt-5"}] =
               SlashCommands.complete_command_args("/model", "gpt", models: models)
    end
  end

  describe "resolve_cwd_input/4" do
    test "resolves relative, absolute, and host tilde paths" do
      assert {:ok, "/work/project/clients"} =
               SlashCommands.resolve_cwd_input("clients", "host", "/work/project")

      assert {:ok, "/work/other"} =
               SlashCommands.resolve_cwd_input("../other", "host", "/work/project")

      assert {:ok, "/var/tmp"} =
               SlashCommands.resolve_cwd_input("/var/tmp/", "host", "/work/project")

      assert {:ok, "/Users/alice"} =
               SlashCommands.resolve_cwd_input("~", "host", "/work/project", home: "/Users/alice")

      assert {:ok, "/Users/alice/Projects"} =
               SlashCommands.resolve_cwd_input("~/Projects", "host", "/work/project",
                 home: "/Users/alice"
               )

      assert {:error, msg} =
               SlashCommands.resolve_cwd_input("~/Projects", "remote-box", "/work/project",
                 home: "/Users/alice"
               )

      assert msg =~ "non-host"
    end
  end

  describe "directory, path, and workspace file completion" do
    test "completes relative, nested, absolute, tilde, and hidden directories" do
      assert {:ok, [%{value: "clients/", label: "clients/", kind: "dir"}]} =
               SlashCommands.complete_directories("host", "/work/project", "cl",
                 backend: FakeBackend
               )

      assert_receive {:list_files,
                      %{"cwd" => "/work/project", "include_hidden" => false, "query" => "cl"}}

      assert {:ok,
              [
                %{value: "clients/tui/", label: "tui/", kind: "dir"},
                %{value: "clients/web/", label: "web/", kind: "dir"}
              ]} =
               SlashCommands.complete_directories("host", "/work/project", "clients/",
                 backend: FakeBackend
               )

      assert {:ok, [%{value: "~/Projects/", label: "Projects/", kind: "dir"}]} =
               SlashCommands.complete_directories("host", "/work/project", "~/",
                 backend: FakeBackend,
                 home: "/Users/alice"
               )

      assert {:ok, [%{value: "/etc/ssl/", label: "ssl/", kind: "dir"}]} =
               SlashCommands.complete_directories("host", "/work/project", "/etc/",
                 backend: FakeBackend
               )

      assert {:ok, [%{value: ".config/", label: ".config/", kind: "dir"}]} =
               SlashCommands.complete_directories("host", "/work/project", ".",
                 backend: FakeBackend
               )

      assert_receive {:list_files,
                      %{"cwd" => "/work/project", "include_hidden" => true, "query" => "."}}
    end

    test "completes inline paths with directories sorted before files and respects shell safety" do
      assert {:ok, items} =
               SlashCommands.complete_paths("host", "/work/project", "", backend: FakeBackend)

      assert Enum.map(items, &{&1.value, &1.kind}) == [
               {"clients/", "dir"},
               {"lib/", "dir"},
               {"README.md", "file"},
               {"a b.txt", "file"},
               {"mix.exs", "file"}
             ]

      assert {:ok, shell_items} =
               SlashCommands.complete_paths("host", "/work/project", "",
                 backend: FakeBackend,
                 shell?: true
               )

      refute Enum.any?(shell_items, &(&1.value == "a b.txt"))
    end

    test "completes workspace @files scoped to session" do
      assert {:ok, items} =
               SlashCommands.complete_session_files("sess-1", "lib", backend: FakeBackend)

      assert_receive {:list_session_files, "sess-1", %{"query" => "lib"}}

      assert Enum.map(items, &{&1.value, &1.kind}) == [
               {"lib/h_web/", "dir"},
               {"lib/h_web/slash_commands.ex", "file"},
               {"README.md", "file"}
             ]
    end
  end
end
