defmodule Mix.Tasks.H.LocalTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.H.Local

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir!(Path.join(dir, "scripts"))
    builder = Path.join(dir, "scripts/build-bundle.sh")
    File.write!(builder, "#!/bin/sh\nset -eu\nmkdir \"$1\"\nprintf fresh > \"$1/version\"\n")
    File.chmod!(builder, 0o700)

    File.write!(
      Path.join(dir, "scripts/smoke-bundle.py"),
      "from pathlib import Path\nPath('tested').touch()\n"
    )

    File.write!(Path.join(dir, "scripts/install-bundle.py"), """
    import json, sys
    from pathlib import Path
    assert Path('tested').is_file()
    assert Path('dist/harness/version').read_text() == 'fresh'
    Path('installed').write_text(json.dumps(sys.argv[1:]))
    """)

    :ok
  end

  describe "run/1" do
    test "builds and tests the bundle before installing with the selected options", %{
      tmp_dir: dir
    } do
      File.cd!(dir, fn ->
        assert :ok = Local.run(["--service", "--data-dir", "test store", "--bin-dir", "test bin"])

        assert JSON.decode!(File.read!("installed")) ==
                 ["--service", "--data-dir", "test store", "--bin-dir", "test bin"]
      end)
    end

    test "does not install a previous bundle after a smoke failure", %{tmp_dir: dir} do
      File.cd!(dir, fn ->
        Mix.Tasks.H.Bundle.run([])
        previous = File.read_link!("dist/harness")
        File.write!("scripts/smoke-bundle.py", "raise SystemExit(1)\n")

        assert_raise Mix.Error, "Bundle smoke test failed (exit 1)", fn -> Local.run([]) end
        refute File.exists?("installed")
        assert File.read_link!("dist/harness") == previous
      end)
    end

    test "rejects alternate bundles and rollback flags before building", %{tmp_dir: dir} do
      File.cd!(dir, fn ->
        assert_raise Mix.Error, ~r/usage: mix h.local/, fn -> Local.run(["--activate", "old"]) end
        assert_raise Mix.Error, ~r/usage: mix h.local/, fn -> Local.run(["old"]) end
        refute File.exists?("dist/harness")
        refute File.exists?("installed")
      end)
    end
  end
end
