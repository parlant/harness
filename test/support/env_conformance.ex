defmodule H.ExecutionEnv.Conformance do
  @moduledoc """
  Shared conformance test suite for `H.ExecutionEnv` implementations.

  Use in an `ExUnit.Case` module:

      use H.ExecutionEnv.Conformance, factory: &H.ExecutionEnv.Local.new/1
  """

  defmacro __using__(opts) do
    factory = Keyword.fetch!(opts, :factory)

    quote do
      setup do
        rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

        tmp_dir =
          Path.join(
            System.tmp_dir!(),
            "h-env-conf-#{System.unique_integer([:positive, :monotonic])}-#{rand}"
          )
          |> Path.expand()

        File.mkdir_p!(tmp_dir)
        on_exit(fn -> File.rm_rf(tmp_dir) end)

        env = unquote(factory).(tmp_dir)
        {:ok, tmp_dir: tmp_dir, env: env}
      end

      describe "cwd/1 and resolve_path/2" do
        test "returns canonical cwd and resolves relative and dot paths", %{
          env: env,
          tmp_dir: tmp_dir
        } do
          assert H.ExecutionEnv.cwd(env) == tmp_dir

          assert {:ok, Path.join(tmp_dir, "a/b.txt")} ==
                   H.ExecutionEnv.resolve_path(env, "a/b.txt")

          assert {:ok, tmp_dir} == H.ExecutionEnv.resolve_path(env, ".")
        end

        test "rejects paths containing NUL bytes", %{env: env} do
          assert {:error, _} = H.ExecutionEnv.resolve_path(env, "bad\0path")
        end
      end

      describe "write_file/3" do
        test "creates missing parent directories and writes atomically", %{
          env: env,
          tmp_dir: tmp_dir
        } do
          assert :ok = H.ExecutionEnv.write_file(env, "nested/dir/hello.txt", "hello world\n")
          assert File.read!(Path.join(tmp_dir, "nested/dir/hello.txt")) == "hello world\n"
        end

        test "preserves existing file permissions on overwrite", %{env: env, tmp_dir: tmp_dir} do
          target = Path.join(tmp_dir, "script.sh")
          File.write!(target, "#!/bin/sh\necho old\n")
          File.chmod!(target, 0o750)

          assert :ok = H.ExecutionEnv.write_file(env, "script.sh", "#!/bin/sh\necho new\n")
          assert File.read!(target) == "#!/bin/sh\necho new\n"
          assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o750
        end
      end

      describe "read_file_lines/3" do
        test "reads offset and limit with exact has_more", %{env: env} do
          :ok = H.ExecutionEnv.write_file(env, "lines.txt", "one\ntwo\nthree\nfour\n")

          assert {:ok,
                  %{
                    lines: ["two", "three"],
                    start_line: 2,
                    total_lines_read: 2,
                    has_more: true,
                    truncated_by_bytes: false
                  }} = H.ExecutionEnv.read_file_lines(env, "lines.txt", offset: 2, limit: 2)

          assert {:ok,
                  %{
                    lines: ["three", "four"],
                    start_line: 3,
                    total_lines_read: 2,
                    has_more: false,
                    truncated_by_bytes: false
                  }} = H.ExecutionEnv.read_file_lines(env, "lines.txt", offset: 3, limit: 2)
        end

        test "truncates by max_bytes cleanly", %{env: env} do
          :ok = H.ExecutionEnv.write_file(env, "bytes.txt", "12345\n67890\nabcde\n")

          assert {:ok,
                  %{
                    lines: ["12345", "67890"],
                    start_line: 1,
                    total_lines_read: 2,
                    has_more: true,
                    truncated_by_bytes: true
                  }} = H.ExecutionEnv.read_file_lines(env, "bytes.txt", max_bytes: 12)
        end

        test "refuses symlinks when no_follow: true and follows when false", %{
          env: env,
          tmp_dir: tmp_dir
        } do
          :ok = H.ExecutionEnv.write_file(env, "real.txt", "secret\n")
          link_path = Path.join(tmp_dir, "link.txt")
          File.ln_s!(Path.join(tmp_dir, "real.txt"), link_path)

          assert {:error, :symlink_not_followed} =
                   H.ExecutionEnv.read_file_lines(env, "link.txt", no_follow: true)

          assert {:ok, %{lines: ["secret"], has_more: false}} =
                   H.ExecutionEnv.read_file_lines(env, "link.txt", no_follow: false)
        end

        test "reads growing files cleanly", %{env: env, tmp_dir: tmp_dir} do
          log_path = Path.join(tmp_dir, "growing.log")
          File.write!(log_path, "first\n")

          assert {:ok, %{lines: ["first"], has_more: false}} =
                   H.ExecutionEnv.read_file_lines(env, "growing.log")

          File.write!(log_path, "second\nthird\n", [:append])

          assert {:ok, %{lines: ["second", "third"], start_line: 2, has_more: false}} =
                   H.ExecutionEnv.read_file_lines(env, "growing.log", offset: 2)
        end

        test "rejects NUL-byte and invalid UTF-8 files with :binary_file", %{
          env: env,
          tmp_dir: tmp_dir
        } do
          File.write!(Path.join(tmp_dir, "nul.bin"), <<1, 2, 0, 3>>)
          File.write!(Path.join(tmp_dir, "bad_utf8.bin"), <<0xFF, 0xFE, "abc">>)

          assert {:error, :binary_file} = H.ExecutionEnv.read_file_lines(env, "nul.bin")
          assert {:error, :binary_file} = H.ExecutionEnv.read_file_lines(env, "bad_utf8.bin")
        end

        test "handles empty files", %{env: env} do
          :ok = H.ExecutionEnv.write_file(env, "empty.txt", "")

          assert {:ok,
                  %{
                    lines: [],
                    start_line: 1,
                    total_lines_read: 0,
                    has_more: false,
                    truncated_by_bytes: false
                  }} = H.ExecutionEnv.read_file_lines(env, "empty.txt")
        end
      end

      describe "read_file_bytes/3" do
        test "reads bounded bytes and respects no_follow", %{env: env, tmp_dir: tmp_dir} do
          :ok = H.ExecutionEnv.write_file(env, "data.bin", <<1, 2, 3, 4, 5>>)
          File.ln_s!(Path.join(tmp_dir, "data.bin"), Path.join(tmp_dir, "data_link.bin"))

          assert {:ok, <<1, 2, 3, 4, 5>>} =
                   H.ExecutionEnv.read_file_bytes(env, "data.bin", max_bytes: 5)

          assert {:error, :file_too_large} =
                   H.ExecutionEnv.read_file_bytes(env, "data.bin", max_bytes: 4)

          assert {:error, :symlink_not_followed} =
                   H.ExecutionEnv.read_file_bytes(env, "data_link.bin", no_follow: true)
        end
      end

      describe "list_dir/3" do
        test "returns sorted paged entries with lstat types", %{env: env, tmp_dir: tmp_dir} do
          :ok = H.ExecutionEnv.write_file(env, "b_file.txt", "123")
          :ok = H.ExecutionEnv.write_file(env, "a_dir/inner.txt", "x")
          File.ln_s!(Path.join(tmp_dir, "b_file.txt"), Path.join(tmp_dir, "c_link"))

          assert {:ok, %{entries: page1, next_cursor: 2}} =
                   H.ExecutionEnv.list_dir(env, ".", limit: 2, cursor: 0)

          assert [
                   %{name: "a_dir", type: "dir"},
                   %{name: "b_file.txt", type: "file", size: 3}
                 ] = page1

          assert {:ok, %{entries: page2, next_cursor: nil}} =
                   H.ExecutionEnv.list_dir(env, ".", limit: 2, cursor: 2)

          assert [%{name: "c_link", type: "symlink"}] = page2
        end

        test "supports include_hidden: false before pagination", %{env: env} do
          :ok = H.ExecutionEnv.write_file(env, ".hidden_dir/secret.txt", "1")
          :ok = H.ExecutionEnv.write_file(env, ".hidden_file", "2")
          :ok = H.ExecutionEnv.write_file(env, "alpha.txt", "3")
          :ok = H.ExecutionEnv.write_file(env, "beta_dir/item.txt", "4")

          assert {:ok, %{entries: hidden_included}} =
                   H.ExecutionEnv.list_dir(env, ".", include_hidden: true)

          assert Enum.map(hidden_included, & &1.name) == [
                   ".hidden_dir",
                   ".hidden_file",
                   "alpha.txt",
                   "beta_dir"
                 ]

          assert {:ok, %{entries: page1, next_cursor: 1}} =
                   H.ExecutionEnv.list_dir(env, ".", include_hidden: false, limit: 1, cursor: 0)

          assert [%{name: "alpha.txt", type: "file"}] = page1

          assert {:ok, %{entries: page2, next_cursor: nil}} =
                   H.ExecutionEnv.list_dir(env, ".", include_hidden: false, limit: 1, cursor: 1)

          assert [%{name: "beta_dir", type: "dir"}] = page2
        end

        test "supports only_dirs: true and symlinked directories before pagination", %{
          env: env,
          tmp_dir: tmp_dir
        } do
          :ok = H.ExecutionEnv.write_file(env, "a_file.txt", "1")
          :ok = H.ExecutionEnv.write_file(env, "b_dir/x.txt", "x")
          :ok = H.ExecutionEnv.write_file(env, "c_file.txt", "2")
          :ok = H.ExecutionEnv.write_file(env, "z_target_dir/y.txt", "y")

          File.ln_s!(Path.join(tmp_dir, "z_target_dir"), Path.join(tmp_dir, "d_dir_link"))
          File.ln_s!(Path.join(tmp_dir, "a_file.txt"), Path.join(tmp_dir, "e_file_link"))
          File.ln_s!(Path.join(tmp_dir, "missing_target"), Path.join(tmp_dir, "f_broken_link"))

          assert {:ok, %{entries: page1, next_cursor: 2}} =
                   H.ExecutionEnv.list_dir(env, ".", only_dirs: true, limit: 2, cursor: 0)

          assert [
                   %{name: "b_dir", type: "dir"},
                   %{name: "d_dir_link", type: "symlink", target_type: "dir"}
                 ] = page1

          assert {:ok, %{entries: page2, next_cursor: nil}} =
                   H.ExecutionEnv.list_dir(env, ".", only_dirs: true, limit: 2, cursor: 2)

          assert [%{name: "z_target_dir", type: "dir"}] = page2
        end

        test "reports markers for directories and symlinked directories", %{
          env: env,
          tmp_dir: tmp_dir
        } do
          :ok = H.ExecutionEnv.write_file(env, "app_one/mix.exs", "defmodule AppOne do end")
          :ok = H.ExecutionEnv.write_file(env, "app_one/AGENTS.md", "# rules")
          File.mkdir_p!(Path.join(tmp_dir, "app_one/.git"))
          :ok = H.ExecutionEnv.write_file(env, "plain_dir/notes.txt", "hi")
          File.ln_s!(Path.join(tmp_dir, "app_one"), Path.join(tmp_dir, "app_link"))

          assert {:ok, %{entries: entries}} =
                   H.ExecutionEnv.list_dir(env, ".",
                     only_dirs: true,
                     markers: H.ExecutionEnv.default_markers()
                   )

          by_name = Map.new(entries, &{&1.name, &1})

          assert by_name["app_one"].path == Path.join(tmp_dir, "app_one")
          assert Enum.sort(by_name["app_one"].markers) == [".git", "AGENTS.md", "mix.exs"]

          assert by_name["app_link"].type == "symlink"
          assert by_name["app_link"].target_type == "dir"
          assert by_name["app_link"].path == Path.join(tmp_dir, "app_link")
          assert Enum.sort(by_name["app_link"].markers) == [".git", "AGENTS.md", "mix.exs"]

          assert by_name["plain_dir"].markers == []
        end
      end

      describe "env_id/1, kind/1, and bind_cwd/2" do
        test "reports env_id and kind and binds cwd to existing directories", %{
          env: env,
          tmp_dir: tmp_dir
        } do
          assert is_binary(H.ExecutionEnv.env_id(env))
          assert H.ExecutionEnv.env_id(env) != ""
          assert is_binary(H.ExecutionEnv.kind(env))

          sub = Path.join(tmp_dir, "sub_workspace")
          File.mkdir_p!(sub)
          :ok = H.ExecutionEnv.write_file(env, "a_file.txt", "nope")

          assert {:ok, rebound} = H.ExecutionEnv.bind_cwd(env, "sub_workspace")
          assert H.ExecutionEnv.cwd(rebound) == sub
          assert H.ExecutionEnv.env_id(rebound) == H.ExecutionEnv.env_id(env)

          assert {:error, :enotdir} = H.ExecutionEnv.bind_cwd(env, "a_file.txt")
          assert {:error, :enoent} = H.ExecutionEnv.bind_cwd(env, "does_not_exist")
        end
      end

      describe "exec/3" do
        test "runs shell and direct argv commands without shell expansion in argv", %{env: env} do
          assert {:ok,
                  %{exit_code: 0, output: shell_out, truncated: false, full_output_path: nil}} =
                   H.ExecutionEnv.exec(env, {:shell, "printf '%s' \"$((1 + 2))\""})

          assert shell_out == "3"

          assert {:ok, %{exit_code: 0, output: argv_out}} =
                   H.ExecutionEnv.exec(env, {:argv, ["echo", "$((1 + 2))"]})

          assert String.trim(argv_out) == "$((1 + 2))"
        end

        test "streams chunks and spills output exceeding window bounds to a 0600 file", %{
          env: env
        } do
          parent = self()

          on_output = fn chunk ->
            send(parent, {:chunk, chunk})
          end

          cmd = "i=1; while [ $i -le 40 ]; do echo \"line-$i-abcdef\"; i=$((i+1)); done"

          assert {:ok, res} =
                   H.ExecutionEnv.exec(env, {:shell, cmd},
                     window_bytes: 120,
                     window_lines: 10,
                     on_output: on_output
                   )

          on_exit(fn -> if res.full_output_path, do: File.rm(res.full_output_path) end)

          assert res.exit_code == 0
          assert res.truncated == true
          assert res.skipped_bytes > 0
          assert byte_size(res.output) <= 120
          assert String.ends_with?(res.output, "line-40-abcdef\n")
          assert is_binary(res.full_output_path)
          assert Bitwise.band(File.stat!(res.full_output_path).mode, 0o777) == 0o600
          full = File.read!(res.full_output_path)
          assert String.starts_with?(full, "line-1-abcdef\n")
          assert String.ends_with?(full, "line-40-abcdef\n")
          assert byte_size(full) == res.skipped_bytes + byte_size(res.output)
          assert_receive {:chunk, _}
        end

        test "reaps grandchild process group on timeout", %{env: env} do
          parent = self()

          on_output = fn chunk ->
            send(parent, {:chunk, chunk})
          end

          assert {:error, %{reason: :timeout}} =
                   H.ExecutionEnv.exec(
                     env,
                     {:shell, "sleep 120 & echo child_pid=$!; sleep 120"},
                     timeout_ms: 150,
                     on_output: on_output
                   )

          child_pid = receive_child_pid!()
          assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
          assert status != 0
        end

        test "reaps grandchild process group on abort_ref", %{env: env} do
          parent = self()
          abort_ref = make_ref()

          task =
            Task.async(fn ->
              H.ExecutionEnv.exec(
                env,
                {:shell, "sleep 120 & echo child_pid=$!; sleep 120"},
                timeout_ms: 10_000,
                abort_ref: abort_ref,
                on_output: fn chunk -> send(parent, {:chunk, chunk}) end
              )
            end)

          child_pid = receive_child_pid!()
          send(task.pid, {:abort_exec, abort_ref})

          assert {:error, %{reason: :aborted, output: output}} = Task.await(task, 5_000)
          assert String.contains?(output, "child_pid=#{child_pid}")
          assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
          assert status != 0
        end

        test "sweeps background orphan processes after normal exit", %{env: env} do
          parent = self()

          assert {:ok, %{exit_code: 0}} =
                   H.ExecutionEnv.exec(
                     env,
                     {:shell, "(sleep 120 >/dev/null 2>&1 & echo child_pid=$!)"},
                     on_output: fn chunk -> send(parent, {:chunk, chunk}) end
                   )

          child_pid = receive_child_pid!()
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
    end
  end
end
