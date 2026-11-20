defmodule Mix.Tasks.H.InstallTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.H.Install

  @moduletag :tmp_dir

  describe "run/1" do
    test "includes the installer diagnostic in the Mix error", %{tmp_dir: dir} do
      File.mkdir!(Path.join(dir, "scripts"))

      File.write!(Path.join(dir, "scripts/install-bundle.py"), """
      import sys
      print("Installation refused or incomplete: Daemon is busy", file=sys.stderr)
      sys.exit(1)
      """)

      File.cd!(dir, fn ->
        assert_raise Mix.Error,
                     "Bundle installation exited with status 1:\nInstallation refused or incomplete: Daemon is busy",
                     fn -> Install.run([]) end
      end)
    end
  end
end
