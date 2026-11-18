defmodule H.ExecutionEnv.HostTest do
  use ExUnit.Case, async: false
  use H.ExecutionEnv.Conformance, factory: &H.ExecutionEnv.Host.new/1

  alias H.ExecutionEnv
  alias H.ExecutionEnv.Host

  describe "Host.new/2" do
    test "defaults cwd to System.user_home!() and env_id to \"host\"" do
      env = Host.new()
      assert ExecutionEnv.cwd(env) == Path.expand(System.user_home!())
      assert ExecutionEnv.env_id(env) == "host"
      assert ExecutionEnv.kind(env) == "host"
    end

    test "supports custom :env_id and rejects relative cwd", %{tmp_dir: tmp_dir} do
      env = Host.new(tmp_dir, env_id: "local-dev")
      assert ExecutionEnv.env_id(env) == "local-dev"
      assert ExecutionEnv.kind(env) == "host"

      assert_raise ArgumentError, fn ->
        Host.new("relative/dir")
      end

      assert_raise ArgumentError, fn ->
        Host.new(tmp_dir, env_id: "")
      end
    end
  end

  describe "Host.bind_cwd/2" do
    test "follows symlinked directories and preserves env_id and env_overrides", %{
      tmp_dir: tmp_dir
    } do
      real_dir = Path.join(tmp_dir, "real_project")
      File.mkdir_p!(real_dir)
      link_dir = Path.join(tmp_dir, "project_link")
      File.ln_s!(real_dir, link_dir)

      env = Host.new(tmp_dir, env_id: "host-custom", env_overrides: %{"FOO" => "bar"})
      assert {:ok, rebound} = ExecutionEnv.bind_cwd(env, "project_link")
      assert ExecutionEnv.cwd(rebound) == link_dir
      assert ExecutionEnv.env_id(rebound) == "host-custom"

      assert {:ok, %{exit_code: 0, output: "bar"}} =
               ExecutionEnv.exec(rebound, {:shell, "printf '%s' \"$FOO\""})
    end
  end

  describe "Host.list_dir/3" do
    test "combines include_hidden: false, only_dirs: true, and markers cleanly", %{
      env: env,
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      File.mkdir_p!(Path.join(tmp_dir, ".hidden_project/.git"))
      :ok = ExecutionEnv.write_file(env, "a_notes.txt", "hi")
      :ok = ExecutionEnv.write_file(env, "b_cargo/Cargo.toml", "[package]")
      :ok = ExecutionEnv.write_file(env, "c_py/pyproject.toml", "[project]")

      assert {:ok, %{entries: entries, next_cursor: nil}} =
               ExecutionEnv.list_dir(env, ".",
                 include_hidden: false,
                 only_dirs: true,
                 markers: ExecutionEnv.default_markers()
               )

      assert [
               %{name: "b_cargo", type: "dir", markers: ["Cargo.toml"]},
               %{name: "c_py", type: "dir", markers: ["pyproject.toml"]}
             ] = entries
    end
  end
end
