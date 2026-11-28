defmodule Extensions.TurnMetrics do
  @moduledoc """
  Session sidebar extension (`"turn_metrics"`, API 1) that renders per-turn
  input/output token bars and response speed (`tok/s`) in `hiweb`.
  """

  @behaviour H.Extension

  @default_max_turns 24
  @default_position {:after, "session-agent"}
  @allowed_setting_keys ["max_turns", "position"]

  @impl H.Extension
  def configure(settings, context) when is_map(settings) and is_map(context) do
    with [] <- Map.keys(settings) -- @allowed_setting_keys,
         {:ok, max_turns} <- validate_max_turns(settings),
         {:ok, position} <- validate_position(settings) do
      {:ok,
       %{
         web: %{
           session_sidebar: [
             %{
               id: "turn-metrics",
               position: position,
               order: 10,
               module: Extensions.TurnMetrics.Sidebar,
               function: render_function(max_turns)
             }
           ],
           stylesheets: ["turn_metrics.css"]
         }
       }}
    else
      _ -> {:error, :invalid_turn_metrics_settings}
    end
  end

  def configure(_settings, _context), do: {:error, :invalid_turn_metrics_settings}

  defp render_function(@default_max_turns), do: :render

  for n <- 4..40, n != @default_max_turns do
    defp render_function(unquote(n)), do: unquote(:"render_#{n}")
  end

  defp validate_max_turns(settings) do
    case Map.fetch(settings, "max_turns") do
      :error -> {:ok, @default_max_turns}
      {:ok, n} when is_integer(n) and n in 4..40 -> {:ok, n}
      _ -> :error
    end
  end

  defp validate_position(settings) do
    case Map.fetch(settings, "position") do
      :error -> {:ok, @default_position}
      {:ok, pos} -> parse_position(pos)
    end
  end

  defp parse_position("top"), do: {:ok, :top}
  defp parse_position("bottom"), do: {:ok, :bottom}
  defp parse_position(pos) when pos in [:top, :bottom], do: {:ok, pos}

  defp parse_position(%{"before" => id} = map) when map_size(map) == 1 do
    if H.Extensions.Web.valid_slug?(id), do: {:ok, {:before, id}}, else: :error
  end

  defp parse_position(%{"after" => id} = map) when map_size(map) == 1 do
    if H.Extensions.Web.valid_slug?(id), do: {:ok, {:after, id}}, else: :error
  end

  defp parse_position(["before", id]) do
    if H.Extensions.Web.valid_slug?(id), do: {:ok, {:before, id}}, else: :error
  end

  defp parse_position(["after", id]) do
    if H.Extensions.Web.valid_slug?(id), do: {:ok, {:after, id}}, else: :error
  end

  defp parse_position("before:" <> id) do
    if H.Extensions.Web.valid_slug?(id), do: {:ok, {:before, id}}, else: :error
  end

  defp parse_position("after:" <> id) do
    if H.Extensions.Web.valid_slug?(id), do: {:ok, {:after, id}}, else: :error
  end

  defp parse_position({dir, id}) when dir in [:before, :after] do
    if H.Extensions.Web.valid_slug?(id), do: {:ok, {dir, id}}, else: :error
  end

  defp parse_position(_), do: :error
end
