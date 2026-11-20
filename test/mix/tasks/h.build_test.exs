defmodule Mix.Tasks.H.BuildTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "--release publishes a smoke-tested installable bundle", %{tmp_dir: dir} do
    File.mkdir!(Path.join(dir, "scripts"))
    builder = Path.join(dir, "scripts/build-bundle.sh")
    File.write!(builder, "#!/bin/sh\nmkdir \"$1\"\nprintf release > \"$1/version\"\n")
    File.chmod!(builder, 0o700)
    File.write!(Path.join(dir, "scripts/smoke-bundle.py"), "import sys\nsys.exit(0)\n")

    File.cd!(dir, fn ->
      assert :ok = Mix.Tasks.H.Build.run(["--release"])
      assert File.read!("dist/harness/version") == "release"
    end)
  end
end
