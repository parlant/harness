defmodule Mix.Tasks.H.BundleTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.H.Bundle

  @moduletag :tmp_dir

  test "publishes only smoke-tested default builds and leaves explicit paths independent", %{
    tmp_dir: dir
  } do
    File.mkdir!(Path.join(dir, "scripts"))

    builder = Path.join(dir, "scripts/build-bundle.sh")
    File.write!(builder, "#!/bin/sh\nset -eu\nmkdir \"$1\"\ncp version \"$1/version\"\n")
    File.chmod!(builder, 0o700)

    File.write!(Path.join(dir, "scripts/smoke-bundle.py"), """
    import sys
    from pathlib import Path
    sys.exit(1 if (Path(sys.argv[1]) / "version").read_text() == "bad" else 0)
    """)

    File.cd!(dir, fn ->
      output = "dist/harness"
      File.write!("version", "first")
      assert :ok = Bundle.run([])
      first = File.read_link!(output)
      assert File.read!(Path.join(output, "version")) == "first"

      File.write!("version", "bad")
      assert_raise Mix.Error, ~r/Bundle smoke test failed \(exit 1\)/, fn -> Bundle.run([]) end
      assert File.read_link!(output) == first
      assert File.ls!("dist/.harness-builds") == [Path.basename(Path.dirname(first))]

      File.write!("version", "second")
      assert :ok = Bundle.run([])
      refute File.read_link!(output) == first
      assert File.read!(Path.join(output, "version")) == "second"
      assert File.read!(Path.join(["dist", first, "version"])) == "first"

      File.write!("version", "export")
      assert :ok = Bundle.run(["dist/export"])
      assert File.read!("dist/export/version") == "export"
      assert File.read!(Path.join(output, "version")) == "second"
    end)
  end

  test "refuses to replace a real directory or an unrelated symlink", %{tmp_dir: dir} do
    File.cd!(dir, fn ->
      File.mkdir_p!("dist/harness")
      File.write!("dist/harness/keep", "fixture")
      assert_raise Mix.Error, ~r/Refusing to replace .*dist\/harness/, fn -> Bundle.run([]) end
      assert File.read!("dist/harness/keep") == "fixture"

      File.rename!("dist/harness", "dist/other")
      File.ln_s!("other", "dist/harness")
      assert_raise Mix.Error, ~r/Refusing to replace unrelated symlink/, fn -> Bundle.run([]) end
      assert File.read_link!("dist/harness") == "other"
    end)
  end
end
