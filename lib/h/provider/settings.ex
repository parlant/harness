defmodule H.Provider.Settings do
  @moduledoc false

  # Owner-provisioned settings, separate from the session and catalog stores.
  def read(%{data_dir: dir}) when is_binary(dir) do
    path = Path.join(Path.expand(dir), "providers.json")

    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, body} <- File.read(path),
         {:ok, %{"version" => 1} = settings} <- JSON.decode(body) do
      settings
    else
      _ -> %{}
    end
  end

  def read(_config), do: %{}
end
