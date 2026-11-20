defmodule H.Daemon.ReviewTest do
  use ExUnit.Case, async: true

  alias H.{Daemon.Review, RemoteAgent}
  alias H.ExecutionEnv.{Host, Remote}

  setup do
    dir = Path.join(System.tmp_dir!(), "h-review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "browse/2" do
    test "non-git folders skip symlinks", %{dir: dir} do
      File.mkdir!(Path.join(dir, "src"))
      File.write!(Path.join(dir, "file"), "data")
      File.ln_s!("file", Path.join(dir, "link"))
      env = Host.new(dir)

      assert {:ok,
              %{
                git: :not_git,
                next?: false,
                entries: [
                  %{name: "file", path: "file", type: "file"},
                  %{name: "src", path: "src", type: "dir"}
                ]
              }} == Review.browse(%{env: env}, %{dir: "", page: 0, changes?: true})

      assert {:error, :invalid_path} ==
               Review.browse(%{env: env}, %{dir: "../", page: 0, changes?: false})
    end

    test "paginates directories without scanning descendants", %{dir: dir} do
      File.mkdir!(Path.join(dir, "src"))
      for n <- 100..299, do: File.write!(Path.join(dir, "#{n}.txt"), "data")
      File.write!(Path.join(dir, "src/nested.txt"), "nested")
      ws = %{env: Host.new(dir)}

      assert {:ok, %{next?: true, entries: entries}} =
               Review.browse(ws, %{dir: "", page: 0, changes?: false})

      assert length(entries) == 200

      assert {:ok, %{next?: false, entries: [%{type: "dir", path: "src"}]}} =
               Review.browse(ws, %{dir: "", page: 1, changes?: false})

      assert {:ok, %{next?: false, entries: [%{type: "file", path: "src/nested.txt"}]}} =
               Review.browse(ws, %{dir: "src", page: 0, changes?: false})
    end

    test "tracks staged, unstaged, untracked and deleted paths in the requested worktree and subdir",
         %{dir: dir} do
      git(dir, ~w(init --quiet))
      File.mkdir!(Path.join(dir, "src"))

      for path <- ["src/edited.txt", "src/deleted.txt", "outside.txt"] do
        File.write!(Path.join(dir, path), "HEAD\r\n")
      end

      File.write!(Path.join(dir, ".gitignore"), "*.ignored\n")
      git(dir, ~w(add .))
      git(dir, ~w(commit -qm initial))
      tree = Path.join(dir, "linked")
      git(dir, ["worktree", "add", "--quiet", "--detach", tree])
      cwd = Path.join(tree, "src")
      File.write!(Path.join(cwd, "edited.txt"), "staged\r\n")
      git(cwd, ~w(add edited.txt))
      File.write!(Path.join(cwd, "edited.txt"), "unstaged\r\n")
      File.rm!(Path.join(cwd, "deleted.txt"))
      File.write!(Path.join(cwd, "new file.txt"), "new")
      File.write!(Path.join(cwd, "local.ignored"), "ignored")
      File.write!(Path.join(tree, "outside.txt"), "irrelevant")

      # Exercise the execution adapter, not the Phoenix machine's cwd.
      agent = start_supervised!({RemoteAgent, id: "review-remote", env: Host.new(tree)})
      workspace = %{env: Remote.new(agent, cwd)}

      assert {:ok, %{git: %{entries: entries, truncated?: false}}} =
               Review.browse(workspace, %{dir: "", page: 0, changes?: true})

      assert entries == [
               %{path: "deleted.txt", working: "D"},
               %{path: "edited.txt", staged: "M", working: "M"},
               %{path: "new file.txt", untracked: "?"}
             ]

      assert {:ok, %{kind: :text, text: "HEAD\r\n"}} =
               Review.read(workspace, "deleted.txt", :head)

      assert {:ok, %{kind: :text, text: "unstaged\r\n"}} =
               Review.read(workspace, "edited.txt", :working)

      assert {:error, :not_in_head} == Review.read(workspace, "new file.txt", :head)
    end

    test "does not execute repository clean filters or fsmonitor commands", %{dir: dir} do
      git(dir, ~w(init --quiet))
      File.write!(Path.join(dir, ".gitattributes"), "test.txt filter=review\n")
      File.write!(Path.join(dir, "test.txt"), "original")
      git(dir, ~w(add .))
      git(dir, ~w(commit -qm initial))
      git(dir, ["config", "filter.review.clean", "printf ran > FILTER_RAN; cat"])
      git(dir, ["config", "core.fsmonitor", "./fixture-fsmonitor"])
      File.write!(Path.join(dir, "fixture-fsmonitor"), "#!/bin/sh\nprintf ran > FSMONITOR_RAN\n")
      File.chmod!(Path.join(dir, "fixture-fsmonitor"), 0o700)
      File.write!(Path.join(dir, "test.txt"), "changed")

      assert {:ok,
              %{
                git: %{entries: [%{path: "fixture-fsmonitor"}, %{path: "test.txt", working: "M"}]}
              }} =
               Review.browse(%{env: Host.new(dir)}, %{dir: "", page: 0, changes?: true})

      refute File.exists?(Path.join(dir, "FILTER_RAN"))
      refute File.exists?(Path.join(dir, "FSMONITOR_RAN"))
    end
  end

  defp git(dir, args) do
    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-c",
                 "core.hooksPath=/dev/null",
                 "-c",
                 "core.fsmonitor=false",
                 "-c",
                 "commit.gpgsign=false",
                 "-c",
                 "user.name=H Review Test",
                 "-c",
                 "user.email=test@example.invalid" | args
               ],
               cd: dir,
               stderr_to_stdout: true,
               env: [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}]
             )
  end
end
