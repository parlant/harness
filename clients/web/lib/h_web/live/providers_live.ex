defmodule HWeb.ProvidersLive do
  use HWeb, :live_view

  alias H.Accounts
  alias HWeb.Backend

  @example_model %{
    "vendor/model-id" => %{
      "name" => "Model display name",
      "context_window" => 128_000,
      "max_output_tokens" => 8_192,
      "supports_reasoning" => false,
      "supports_images" => false,
      "price_per_million_tokens" => %{
        "input" => 0,
        "output" => 0,
        "cache_read" => 0,
        "cache_write" => 0
      }
    }
  }

  @impl true
  def mount(params, _session, socket) do
    opts = Backend.InVM.daemon_opts()

    server = opts[:accounts]

    profiles =
      case Accounts.api_keys(server) do
        {:ok, %{providers: providers}} -> providers
        _ -> []
      end

    {catalog, editor} =
      case Accounts.provider_catalog(server) do
        {:ok, catalog} ->
          selected = params["provider"]

          selected =
            if is_binary(selected) and is_map_key(catalog.providers, selected), do: selected

          {catalog, edit_form(catalog, selected)}

        {:error, _} ->
          {nil, nil}
      end

    {:ok,
     assign(socket,
       running: Map.keys(opts[:compatible_providers] || %{}),
       model_groups: Backend.list_models() |> Enum.group_by(& &1.provider),
       profiles: profiles,
       catalog: catalog,
       editor: editor
     )}
  end

  defp edit_form(catalog, selected) do
    provider = catalog.providers[selected] || %{}

    to_form(
      %{
        "id" => selected || "",
        "name" => provider["name"] || "",
        "base_url" => provider["base_url"] || "",
        "models" => Jason.encode!(provider["models"] || @example_model, pretty: true),
        "revision" => catalog.revision
      },
      as: :provider
    )
  end
end
