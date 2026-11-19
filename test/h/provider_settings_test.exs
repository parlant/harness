defmodule H.Provider.SettingsTest do
  use ExUnit.Case, async: true

  alias H.Provider.Settings

  describe "read/1" do
    @tag :tmp_dir
    test "reads only the versioned private file in the H data directory", %{tmp_dir: dir} do
      other = Path.join(dir, "other")
      File.mkdir!(other)
      File.write!(Path.join(other, "settings.json"), ~s({"defaultProvider":"openai-codex"}))

      File.write!(
        Path.join(other, "auth.json"),
        ~s({"openai-codex":{"type":"oauth","access":"fixture-token","expires":9999}})
      )

      assert {:error, _} =
               H.Credentials.resolve(:openai_codex,
                 env: %{"PI_CODING_AGENT_DIR" => other},
                 now_fn: fn -> 0 end
               )

      File.write!(Path.join(dir, "auth.json"), ~s({"openai-codex":{"type":"oauth"}}))
      assert Settings.read(%{data_dir: dir}) == %{}

      path = Path.join(dir, "providers.json")
      settings = %{"version" => 1, "default_model" => "openai_codex:gpt-6.1-sol"}
      File.write!(path, JSON.encode!(settings))
      File.chmod!(path, 0o644)
      assert Settings.read(%{data_dir: dir}) == %{}

      File.chmod!(path, 0o600)
      assert Settings.read(%{data_dir: dir}) == settings

      target = Path.join(other, "providers.json")
      File.rename!(path, target)
      File.ln_s!(target, path)
      assert Settings.read(%{data_dir: dir}) == %{}
    end
  end
end
