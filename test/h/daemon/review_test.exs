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

    test "pages history and opens old, root and detached commits by object ID", %{dir: dir} do
      git(dir, ~w(init --quiet))

      assert {:ok, %{commits: [], next?: false}} ==
               Review.browse(%{env: Host.new(dir)}, %{history: 0})

      File.write!(Path.join(dir, "notes.txt"), "initial\n")
      git(dir, ~w(add notes.txt))
      git(dir, ~w(commit -qm initial))
      first = git(dir, ~w(rev-parse HEAD)) |> String.trim()

      for _ <- 1..30, do: git(dir, ~w(commit --allow-empty -qm later))
      ws = %{env: Host.new(dir)}
      assert {:ok, %{commits: commits, next?: true}} = Review.browse(ws, %{history: 0})
      assert length(commits) == 30
      refute Enum.any?(commits, &(&1.id == first))

      assert {:ok, %{commits: [%{id: ^first, subject: "initial", parent: nil}], next?: false}} =
               Review.browse(ws, %{history: 1})

      assert {:ok,
              %{
                commit: %{id: ^first, base: "empty"},
                git: %{entries: [%{status: "A", path: "notes.txt"}]}
              }} =
               Review.browse(ws, %{commit: String.slice(first, 0, 10)})

      git(dir, ["checkout", "--quiet", "--detach", first])
      git(dir, ~w(commit --allow-empty -qm detached))
      detached = git(dir, ~w(rev-parse HEAD)) |> String.trim()
      git(dir, ~w(checkout --quiet -))

      assert {:ok, %{commit: %{id: ^detached, base: ^first}, git: %{entries: []}}} =
               Review.browse(ws, %{commit: detached})

      for ref <- ["HEAD", "--all", "../abc", first <> "^", first <> ":notes.txt"] do
        assert {:error, :invalid_commit} == Review.browse(ws, %{commit: ref})

        if ref != "HEAD",
          do: assert({:error, :invalid_commit} == Review.read(ws, "notes.txt", ref))
      end

      git(dir, ~w(branch deadbeef))
      assert {:error, :commit_unavailable} == Review.browse(ws, %{commit: "deadbeef"})

      assert {:error, :commit_unavailable} ==
               Review.browse(ws, %{commit: String.duplicate("a", 40)})
    end

    test "uses the first parent for merge commits and limits snapshots to the session directory",
         %{dir: dir} do
      git(dir, ~w(init --quiet -b trunk))
      File.mkdir_p!(Path.join(dir, "src/sub"))
      File.write!(Path.join(dir, "src/sub/old.txt"), "old\n")
      File.write!(Path.join(dir, "outside.txt"), "outside\n")
      File.ln_s!("../outside.txt", Path.join(dir, "src/link"))
      git(dir, ~w(add .))
      git(dir, ~w(commit -qm initial))
      git(dir, ~w(checkout -qb topic))
      File.rm!(Path.join(dir, "src/sub/old.txt"))
      File.write!(Path.join(dir, "src/new.txt"), "added\n")
      File.write!(Path.join(dir, "outside.txt"), "updated\n")
      git(dir, ~w(add -A))
      git(dir, ~w(commit -qm topic))
      git(dir, ~w(checkout -q trunk))
      git(dir, ~w(commit --allow-empty -qm trunk))
      parent = git(dir, ~w(rev-parse HEAD)) |> String.trim()
      git(dir, ~w(merge --no-ff -qm merged topic))
      merge = git(dir, ~w(rev-parse HEAD)) |> String.trim()
      cwd = Path.join(dir, "src")
      agent = start_supervised!({RemoteAgent, id: "review-history-remote", env: Host.new(dir)})
      ws = %{env: Remote.new(agent, cwd)}

      assert {:ok,
              %{commit: %{id: ^merge, base: ^parent}, git: %{entries: entries, truncated?: false}}} =
               Review.browse(ws, %{commit: merge})

      assert entries == [%{status: "A", path: "new.txt"}, %{status: "D", path: "sub/old.txt"}]

      # Neither browsing nor reading should resolve against the current checkout.
      File.write!(Path.join(cwd, "new.txt"), "changed in the worktree\n")

      assert {:ok, %{entries: [%{path: "new.txt", type: "file"}], next?: false}} =
               Review.browse(ws, %{commit: merge, dir: "", page: 0})

      assert {:ok, %{entries: [%{path: "sub/old.txt", type: "file"}], next?: false}} =
               Review.browse(ws, %{commit: parent, dir: "sub", page: 0})

      assert {:ok, %{text: "added\n"}} = Review.read(ws, "new.txt", merge)
      assert {:ok, %{text: "old\n"}} = Review.read(ws, "sub/old.txt", parent)
      assert {:error, :not_in_commit} == Review.read(ws, "sub/old.txt", merge)
      assert {:error, :symlink_not_followed} == Review.read(ws, "link", merge)
      assert {:error, :not_in_commit} == Review.read(ws, "outside.txt", merge)
      assert {:error, :invalid_path} == Review.read(ws, "../outside.txt", merge)
      assert {:error, :invalid_path} == Review.browse(ws, %{commit: merge, dir: "..", page: 0})
    end

    test "keeps shallow commits browseable without inventing a root diff", %{dir: dir} do
      git(dir, ~w(init --quiet))
      File.write!(Path.join(dir, "notes.txt"), "first\n")
      git(dir, ~w(add .))
      git(dir, ~w(commit -qm initial))
      git(dir, ~w(commit --allow-empty -qm later))
      head = git(dir, ~w(rev-parse HEAD)) |> String.trim()
      shallow = Path.join(dir, "shallow")
      git(dir, ["clone", "--quiet", "--depth=1", "file://#{dir}", shallow])
      ws = %{env: Host.new(shallow)}

      assert {:ok, %{commit: %{base: nil}, git: :parent_unavailable}} =
               Review.browse(ws, %{commit: head})

      assert {:ok, %{text: "first\n"}} = Review.read(ws, "notes.txt", head)
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
    assert {output, 0} =
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

    output
  end
end
