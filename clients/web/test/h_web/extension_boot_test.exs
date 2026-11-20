defmodule HWeb.ExtensionBootTest do
  use ExUnit.Case, async: false

  test "embedded daemon and Phoenix in-VM backend share loaded profile and effective options" do
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    dir = Path.join(base, "h-web-ext-#{System.pid()}-#{System.unique_integer([:positive])}")
    root = Path.expand("../../../..", __DIR__)
    source = Path.join(root, "examples/extension_template")
    ebin = Path.join(dir, "package/ebin")
    File.mkdir_p!(ebin)

    on_exit(fn -> File.rm_rf!(dir) end)

    File.cp!(Path.join(source, "extension.json"), Path.join(dir, "package/extension.json"))

    assert {"", 0} =
             System.cmd(
               System.find_executable("elixirc"),
               [
                 "-pa",
                 Application.app_dir(:harness, "ebin"),
                 "-o",
                 ebin,
                 Path.join(source, "lib/greeting.ex")
               ],
               stderr_to_stdout: true,
               env: [{"ERL_FLAGS", "+S 2:2"}]
             )

    File.write!(
      Path.join(dir, "extensions.json"),
      JSON.encode!(%{
        version: 1,
        extensions: [%{path: "package", settings: %{instructions: "from embedded boot"}}]
      })
    )

    assert [{H.Daemon.Instance, opts}] =
             H.Application.children(data_dir: dir, daemon: true, provider: H.Provider.Fake)

    start_supervised!({H.Daemon.Instance, opts})

    backend = HWeb.Backend.InVM
    assert H.Daemon.instance_options() == backend.daemon_opts(harnesses: %{}, data_dir: "/wrong")

    assert {:ok, %{session: %{session_id: sid, harness_id: "example.greeting.v1"}}} =
             backend.create_session(%{"cwd" => dir, "harness_id" => "example.greeting.v1"})

    assert {:ok, {:snapshot, _, payload}} = backend.subscribe_conversation(sid, "1", self())

    assert %{"docs" => %{"agent" => %{"instructions" => "from embedded boot"}}} =
             JSON.decode!(payload)
  end
end
