defmodule H.ExecutionEnv.Host.FileSystemTest do
  use ExUnit.Case, async: false

  alias H.ExecutionEnv.Host.FileSystem

  describe "Fs.list_dir/3" do
    test "do not send workspace access through the shared OTP file server" do
      root = Path.join(System.tmp_dir!(), "h-fs-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "hello"), "hello")
      File.ln_s!("hello", Path.join(root, "link"))
      on_exit(fn -> File.rm_rf!(root) end)

      # Warm code loading before tracing; only filesystem calls are under test.
      assert {:ok, _} = FileSystem.stat(root)
      assert {:ok, _} = FileSystem.lstat(root)
      assert {:ok, _} = FileSystem.ls(root)
      assert {:ok, _} = FileSystem.read_link(Path.join(root, "link"))
      assert :ok = H.ExecutionEnv.Host.Fs.write_file(root, "hello", "hello")
      file_server = Process.whereis(:file_server_2)
      parent = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          receive do
            :go ->
              send(
                parent,
                {:results,
                 [
                   FileSystem.stat(root),
                   FileSystem.lstat(Path.join(root, "link")),
                   FileSystem.ls(root),
                   FileSystem.read_link(Path.join(root, "link")),
                   H.ExecutionEnv.Host.Fs.canonical_path(root, "link"),
                   H.ExecutionEnv.Host.Fs.list_dir(root, ".", markers: ["mix.exs"]),
                   H.ExecutionEnv.Host.Fs.write_file(root, "hello", "changed"),
                   H.ExecutionEnv.Host.Fs.write_file(root, "nested/new", "created")
                 ]}
              )
          end
        end)

      :erlang.trace(pid, true, [:send])
      send(pid, :go)

      assert_receive {:results,
                      [
                        {:ok, %File.Stat{type: :directory}},
                        {:ok, %File.Stat{type: :symlink}},
                        {:ok, names},
                        {:ok, "hello"},
                        {:ok, canonical},
                        {:ok, _},
                        :ok,
                        :ok
                      ]},
                     1_000

      assert Enum.sort(names) == ["hello", "link"]
      assert String.ends_with?(canonical, "/hello")
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      refute_receive {:trace, ^pid, :send, _, ^file_server}
    end
  end

  describe "automatic_probe?/3" do
    test "does not inspect protected macOS children merely for marker decoration" do
      home = "/disposable/home"

      for folder <- ["Desktop", "Documents", "Downloads", "Library"] do
        refute FileSystem.automatic_probe?(Path.join(home, folder), home, {:unix, :darwin})

        refute FileSystem.automatic_probe?(
                 Path.join([home, folder, "project"]),
                 home,
                 {:unix, :darwin}
               )
      end

      assert FileSystem.automatic_probe?(home <> "/Projects", home, {:unix, :darwin})
      assert FileSystem.automatic_probe?(home <> "/Desktop-other", home, {:unix, :darwin})
      assert FileSystem.automatic_probe?(home <> "/Desktop", home, {:unix, :linux})
    end
  end

  describe "ls/1" do
    test "uses the configured helper and returns finite, actionable errors" do
      root = Path.join(System.tmp_dir!(), "h-fs-helper-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      helper = Path.join(root, "helper")
      previous = System.get_env("H_FS_EXECUTABLE")
      System.put_env("H_FS_EXECUTABLE", helper)

      on_exit(fn ->
        if previous,
          do: System.put_env("H_FS_EXECUTABLE", previous),
          else: System.delete_env("H_FS_EXECUTABLE")

        File.rm_rf!(root)
      end)

      for {response, expected} <- [
            {~s({"ok":["native"]}), {:ok, ["native"]}},
            {~s({"error":"timeout"}), {:error, :timeout}},
            {~s({"error":"eperm"}), {:error, :eperm}},
            {~s({"error":"not_an_atom"}), {:error, :eio}},
            {~s({"ok":[1]}), {:error, :eio}},
            {"invalid json", {:error, :eio}}
          ] do
        File.write!(helper, "#!/bin/sh\nprintf '%s' '#{response}'\n")
        File.chmod!(helper, 0o700)
        assert FileSystem.ls(root) == expected
      end
    end
  end
end
