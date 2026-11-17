defmodule H.ExecutionEnv.LocalTest do
  use ExUnit.Case, async: false
  use H.ExecutionEnv.Conformance, factory: &H.ExecutionEnv.Local.new/1

  alias H.ExecutionEnv
  alias H.ExecutionEnv.Local

  describe "new/2" do
    test "rejects relative cwd" do
      assert_raise ArgumentError, fn ->
        Local.new("relative/dir")
      end
    end

    test "normalizes cwd with dot segments" do
      env = Local.new("/tmp/a/../b")
      assert ExecutionEnv.cwd(env) == "/tmp/b"
    end
  end

  describe "environment sanitization and overrides" do
    test "strips daemon auth env vars and applies env_overrides", %{tmp_dir: tmp_dir} do
      System.put_env("H_AUTH_TOKEN", "top-secret-token")
      on_exit(fn -> System.delete_env("H_AUTH_TOKEN") end)

      env = Local.new(tmp_dir, env_overrides: %{"CUSTOM_VAR" => "custom-val"})

      assert {:ok, %{exit_code: 0, output: output}} =
               ExecutionEnv.exec(
                 env,
                 {:shell, "printf '%s|%s' \"$H_AUTH_TOKEN\" \"$CUSTOM_VAR\""}
               )

      assert output == "|custom-val"
    end
  end

  describe "UTF-8 chunk boundary scanning" do
    test "reads multi-byte UTF-8 characters split across 64 KiB read chunks", %{env: env} do
      # Put a 3-byte UTF-8 character right across the 65536-byte boundary.
      prefix = String.duplicate("a", 65_535)
      content = prefix <> "€\nnext line\n"
      :ok = ExecutionEnv.write_file(env, "utf8_boundary.txt", content)

      assert {:ok, %{lines: [line1, "next line"], has_more: false}} =
               ExecutionEnv.read_file_lines(env, "utf8_boundary.txt", max_bytes: 100_000)

      assert line1 == prefix <> "€"
    end
  end

  describe "SIGTERM-resistant grandchild reaping" do
    test "escalates to SIGKILL when process ignores SIGTERM", %{env: env} do
      parent = self()

      assert {:error, %{reason: :timeout}} =
               ExecutionEnv.exec(
                 env,
                 {:shell, "trap '' TERM; sleep 120 & echo child_pid=$!; sleep 120"},
                 timeout_ms: 150,
                 on_output: fn chunk -> send(parent, {:chunk, chunk}) end
               )

      child_pid = receive_child_pid!()
      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0
    end
  end
end
