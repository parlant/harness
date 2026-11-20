defmodule H.Daemon.Network do
  @moduledoc false

  @loopback {127, 0, 0, 1}

  def load(data_dir) do
    case File.read(Path.join(data_dir, "network.json")) do
      {:ok, contents} ->
        with {:ok, %{"bind_addresses" => addresses} = config} when map_size(config) == 1 <-
               JSON.decode(contents),
             {:ok, addresses} <- parse(addresses) do
          {:ok, addresses}
        else
          _ -> {:error, {:network_config, :expected_unique_literal_ipv4_bind_addresses}}
        end

      {:error, :enoent} ->
        {:ok, [@loopback]}

      {:error, reason} ->
        {:error, {:network_config, reason}}
    end
  end

  defp parse([_ | _] = addresses) do
    addresses =
      Enum.map(addresses, fn
        address when is_binary(address) ->
          case :inet.parse_ipv4strict_address(String.to_charlist(address)) do
            {:ok, {first, _, _, _} = ip} when first in 1..223 -> ip
            _ -> nil
          end

        _ ->
          nil
      end)

    if nil in addresses or Enum.uniq(addresses) != addresses do
      :error
    else
      {:ok, Enum.sort_by(addresses, &(&1 != @loopback))}
    end
  end

  defp parse(_), do: :error
end
