defmodule H.EnvRegistryTest do
  use ExUnit.Case, async: true

  alias H.EnvRegistry
  alias H.ExecutionEnv

  defmodule FakeRemoteEnv do
    @behaviour H.ExecutionEnv

    def new(cwd, env_id \\ "remote-1"),
      do: ExecutionEnv.new(__MODULE__, %{cwd: cwd, env_id: env_id})

    @impl true
    def env_id(%{env_id: id}), do: id

    @impl true
    def kind(_state), do: "remote"

    @impl true
    def cwd(%{cwd: cwd}), do: cwd

    @impl true
    def bind_cwd(state, path) do
      with {:ok, resolved} <- resolve_path(state, path) do
        if String.contains?(resolved, "missing") do
          {:error, :enoent}
        else
          {:ok, %{state | cwd: resolved}}
        end
      end
    end

    @impl true
    def resolve_path(%{cwd: cwd}, path) do
      cond do
        String.contains?(path, <<0>>) -> {:error, :einval}
        String.starts_with?(path, "/") -> {:ok, Path.expand(path)}
        true -> {:ok, Path.expand(path, cwd)}
      end
    end

    @impl true
    def read_file_lines(_state, _path, _opts), do: {:error, :enoent}

    @impl true
    def read_file_bytes(_state, _path, _opts), do: {:error, :enoent}

    @impl true
    def write_file(_state, _path, _content), do: {:error, :eacces}

    @impl true
    def list_dir(_state, _path, _opts), do: {:ok, %{entries: [], next_cursor: nil}}

    @impl true
    def exec(_state, _cmd, _opts), do: {:error, :unsupported}
  end

  setup do
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "h-env-reg-#{System.unique_integer([:positive, :monotonic])}-#{rand}"
      )
      |> Path.expand()

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "list_environments/1" do
    test "includes default \"host\" environment without function values" do
      [host] = EnvRegistry.list_environments()

      assert host == %{
               id: "host",
               kind: "host",
               label: "Local Host",
               default_cwd: System.user_home!()
             }

      refute Map.has_key?(host, :build)
    end

    test "merges custom environments from map or list and allows overriding host", %{
      tmp_dir: tmp_dir
    } do
      envs_list = [
        %{
          id: "vm-eu",
          kind: "remote",
          label: "EU VM",
          default_cwd: "/srv/app",
          build: fn cwd -> FakeRemoteEnv.new(cwd, "vm-eu") end
        },
        %{
          id: "host",
          label: "Custom Host",
          default_cwd: tmp_dir
        }
      ]

      listed = EnvRegistry.list_environments(environments: envs_list)

      assert listed == [
               %{id: "host", kind: "host", label: "Custom Host", default_cwd: tmp_dir},
               %{id: "vm-eu", kind: "remote", label: "EU VM", default_cwd: "/srv/app"}
             ]

      envs_map = %{
        "vm-us" => %{
          "kind" => "remote",
          "label" => "US VM",
          "default_cwd" => "/opt/work",
          "build" => fn cwd -> FakeRemoteEnv.new(cwd, "vm-us") end
        }
      }

      assert [
               %{id: "host", kind: "host"},
               %{id: "vm-us", kind: "remote", label: "US VM", default_cwd: "/opt/work"}
             ] = EnvRegistry.list_environments(environments: envs_map)
    end
  end

  describe "fetch_env/2" do
    test "returns live env at default_cwd and plain descriptor, or :unknown_environment", %{
      tmp_dir: tmp_dir
    } do
      opts = [
        environments: %{
          "host" => %{default_cwd: tmp_dir},
          "vm-1" => %{
            kind: "remote",
            label: "VM 1",
            default_cwd: "/workspace/repo",
            build: fn cwd -> FakeRemoteEnv.new(cwd, "vm-1") end
          }
        }
      ]

      assert {:ok, host_env, host_desc} = EnvRegistry.fetch_env("host", opts)
      assert ExecutionEnv.cwd(host_env) == tmp_dir
      assert ExecutionEnv.env_id(host_env) == "host"
      assert host_desc == %{id: "host", kind: "host", label: "Local Host", default_cwd: tmp_dir}

      assert {:ok, vm_env, vm_desc} = EnvRegistry.fetch_env("vm-1", opts)
      assert ExecutionEnv.cwd(vm_env) == "/workspace/repo"
      assert ExecutionEnv.env_id(vm_env) == "vm-1"
      assert ExecutionEnv.kind(vm_env) == "remote"

      assert vm_desc == %{
               id: "vm-1",
               kind: "remote",
               label: "VM 1",
               default_cwd: "/workspace/repo"
             }

      assert {:error, :unknown_environment} = EnvRegistry.fetch_env("does-not-exist", opts)
      assert {:error, :unknown_environment} = EnvRegistry.fetch_env(nil, opts)
      assert {:error, :unknown_environment} = EnvRegistry.fetch_env("", opts)
    end
  end

  describe "resolve_workspace/3" do
    test "defaults nil/empty env_id to \"host\" and nil/empty cwd to default_cwd", %{
      tmp_dir: tmp_dir
    } do
      sub = Path.join(tmp_dir, "proj")
      File.mkdir_p!(sub)
      opts = [environments: %{"host" => %{default_cwd: tmp_dir}}]

      assert {:ok, %{env_id: "host", kind: "host", cwd: ^tmp_dir, env: env1}} =
               EnvRegistry.resolve_workspace(nil, nil, opts)

      assert ExecutionEnv.cwd(env1) == tmp_dir

      assert {:ok, %{env_id: "host", kind: "host", cwd: ^sub, env: env2}} =
               EnvRegistry.resolve_workspace("", "proj", opts)

      assert ExecutionEnv.cwd(env2) == sub
    end

    test "delegates path resolution and cwd binding to target ExecutionEnv", %{tmp_dir: tmp_dir} do
      opts = [
        environments: %{
          "vm-1" => %{
            kind: "remote",
            label: "VM 1",
            default_cwd: "/home/dev",
            build: fn cwd -> FakeRemoteEnv.new(cwd, "vm-1") end
          }
        }
      ]

      assert {:ok, %{env_id: "vm-1", kind: "remote", cwd: "/home/dev/apps/api", env: vm_env}} =
               EnvRegistry.resolve_workspace("vm-1", "apps/api", opts)

      assert ExecutionEnv.cwd(vm_env) == "/home/dev/apps/api"
      assert ExecutionEnv.env_id(vm_env) == "vm-1"

      assert {:error, :enoent} = EnvRegistry.resolve_workspace("vm-1", "missing/dir", opts)
      assert {:error, :enoent} = EnvRegistry.resolve_workspace("host", Path.join(tmp_dir, "nope"))
      assert {:error, :unknown_environment} = EnvRegistry.resolve_workspace("nope", tmp_dir, opts)
    end
  end
end
