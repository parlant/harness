defmodule Extensions.Analytics do
  @moduledoc """
  Read-only usage, spend, latency, cache, and tool reliability analytics
  extension (`"analytics"`, API 1).
  """

  @behaviour H.Extension

  alias Extensions.Analytics.{Live, Observer, Store}

  @allowed_setting_keys ["sync_interval_ms", "batch_size"]
  @default_sync_interval_ms 5_000
  @default_batch_size 25

  @impl H.Extension
  def configure(settings, context) when is_map(settings) and is_map(context) do
    with [] <- Map.keys(settings) -- @allowed_setting_keys,
         {:ok, sync_interval_ms} <-
           validate_int_range(
             settings,
             "sync_interval_ms",
             1_000..300_000,
             @default_sync_interval_ms
           ),
         {:ok, batch_size} <-
           validate_int_range(settings, "batch_size", 1..500, @default_batch_size),
         data_dir when is_binary(data_dir) and data_dir != "" <- Map.get(context, :data_dir) do
      {:ok,
       %{
         observers: [Observer],
         children: [
           {Store, data_dir: data_dir, sync_interval_ms: sync_interval_ms, batch_size: batch_size}
         ],
         web: %{
           pages: [
             %{slug: "analytics", module: Live, title: "Analytics"}
           ],
           nav_items: [
             %{id: "analytics", label: "Analytics", slug: "analytics", order: 30}
           ],
           stylesheets: ["analytics.css"],
           scripts: ["analytics.js"]
         }
       }}
    else
      _ -> {:error, :invalid_analytics_settings}
    end
  end

  def configure(_, _), do: {:error, :invalid_analytics_settings}

  defp validate_int_range(settings, key, range, default) do
    case Map.get(settings, key, default) do
      val when is_integer(val) ->
        if val in range, do: {:ok, val}, else: :error

      _ ->
        :error
    end
  end
end
