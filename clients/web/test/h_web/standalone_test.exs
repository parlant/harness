defmodule HWeb.StandaloneTest do
  use ExUnit.Case, async: false

  setup do
    endpoint = Application.get_env(:harness_web, HWeb.Endpoint)
    env = Map.new(["H_WEB", "H_WEB_PORT"], &{&1, System.get_env(&1)})
    System.delete_env("H_WEB")
    System.delete_env("H_WEB_PORT")

    on_exit(fn ->
      Application.put_env(:harness_web, HWeb.Endpoint, endpoint)

      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  @loopback {127, 0, 0, 1}

  describe "configure/1" do
    test "configures all listeners without starting a second Phoenix server" do
      assert :ok = HWeb.Standalone.configure([@loopback, {10, 10, 10, 4}])
      config = Application.fetch_env!(:harness_web, HWeb.Endpoint)
      refute config[:server]
      assert config[:standalone_listeners] == [{@loopback, 4200}, {{10, 10, 10, 4}, 4200}]
      assert byte_size(config[:secret_key_base]) >= 64
      assert config[:check_origin] == :conn
      refute Process.whereis(HWeb.Endpoint)
      refute Process.whereis(H.Daemon.Instance)
    end

    test "accepts an ephemeral port and rejects invalid ports" do
      System.put_env("H_WEB_PORT", "0")
      assert :ok = HWeb.Standalone.configure([@loopback])

      assert Application.fetch_env!(:harness_web, HWeb.Endpoint)[:standalone_listeners] == [
               {@loopback, 0}
             ]

      for port <- ["no", "-1", "65536", "4000extra"] do
        System.put_env("H_WEB_PORT", port)
        assert {:error, :invalid_web_port} = HWeb.Standalone.configure([@loopback])
      end
    end

    test "can disable web startup" do
      System.put_env("H_WEB", "0")
      assert :disabled = HWeb.Standalone.configure([@loopback])
    end
  end
end
