defmodule H.Daemon.NetworkTest do
  use ExUnit.Case, async: true

  alias H.Daemon.Network

  @moduletag :tmp_dir

  describe "load/1" do
    test "defaults to loopback if the file is absent", %{tmp_dir: dir} do
      assert Network.load(dir) == {:ok, [{127, 0, 0, 1}]}
    end

    test "loads both configured addresses, prioritizing loopback for discovery", %{tmp_dir: dir} do
      File.write!(
        Path.join(dir, "network.json"),
        ~s({"bind_addresses":["10.10.10.4","127.0.0.1"]})
      )

      assert Network.load(dir) == {:ok, [{127, 0, 0, 1}, {10, 10, 10, 4}]}
    end

    test "refuses malformed, wildcard, duplicate and nonliteral settings", %{tmp_dir: dir} do
      for body <- [
            "not JSON",
            ~s({"bind_adresses":["127.0.0.1"]}),
            ~s({"bind_addresses":[]}),
            ~s({"bind_addresses":["0.0.0.0"]}),
            ~s({"bind_addresses":["localhost"]}),
            ~s({"bind_addresses":["127.0.0.1","127.0.0.1"]})
          ] do
        File.write!(Path.join(dir, "network.json"), body)
        assert {:error, {:network_config, _}} = Network.load(dir)
      end
    end
  end
end
