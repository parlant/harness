defmodule Extensions.TurnMetrics.Sidebar do
  @moduledoc """
  Phoenix function component rendering the per-turn token and tok/s SVG chart
  inside the `hiweb` session sidebar.
  """

  use Phoenix.Component

  @default_max_turns 24

  @type metric_point :: %{
          required(:entry_id) => String.t(),
          required(:x) => float(),
          required(:cx) => float(),
          required(:bar_w) => float(),
          required(:in_y) => float(),
          required(:in_h) => float(),
          required(:out_y) => float(),
          required(:out_h) => float(),
          required(:tps) => number() | nil,
          required(:tps_y) => float() | nil,
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:total_tokens) => non_neg_integer(),
          required(:duration_ms) => non_neg_integer() | nil,
          required(:tooltip) => String.t()
        }

  @type chart :: %{
          points: [metric_point()],
          line_points: String.t(),
          has_tps?: boolean(),
          max_tps_label: String.t(),
          max_tokens_label: String.t(),
          latest_tps_label: String.t(),
          turns: pos_integer()
        }

  @doc """
  Computes scaled SVG bar and polyline geometry for the most recent `max_turns`
  turn metrics. Returns `nil` when `turn_metrics` is empty or invalid.
  """
  @spec build_chart([map()], pos_integer()) :: chart() | nil
  def build_chart(turn_metrics, max_turns \\ @default_max_turns)

  def build_chart(turn_metrics, max_turns)
      when is_list(turn_metrics) and is_integer(max_turns) and max_turns > 0 do
    points = Enum.take(turn_metrics, -max_turns)

    if points == [] do
      nil
    else
      count = length(points)
      left = 32.0
      right = 224.0
      top = 8.0
      bottom = 66.0
      plot_w = right - left
      plot_h = bottom - top

      normalized =
        Enum.map(points, fn m ->
          input = non_neg_int(Map.get(m, :input_tokens))
          output = non_neg_int(Map.get(m, :output_tokens))
          total = max(non_neg_int(Map.get(m, :total_tokens)), input + output)
          tps = Map.get(m, :tps)
          duration_ms = Map.get(m, :duration_ms)

          %{
            entry_id: to_string(Map.get(m, :entry_id) || ""),
            input_tokens: input,
            output_tokens: output,
            total_tokens: total,
            duration_ms: if(is_integer(duration_ms) and duration_ms > 0, do: duration_ms),
            tps: if(is_number(tps), do: tps)
          }
        end)

      max_tokens =
        normalized
        |> Enum.map(& &1.total_tokens)
        |> Enum.max(fn -> 1 end)
        |> max(1)

      tps_values =
        normalized
        |> Enum.map(& &1.tps)
        |> Enum.filter(&is_number/1)

      max_tps =
        case tps_values do
          [] -> 1.0
          vals -> max(Enum.max(vals), 1.0)
        end

      slot_w = plot_w / count
      bar_w = min(max(slot_w * 0.56, 3.0), 14.0)

      indexed =
        normalized
        |> Enum.with_index()
        |> Enum.map(fn {m, idx} ->
          cx = left + (idx + 0.5) * slot_w
          in_h = m.input_tokens / max_tokens * plot_h
          out_h = m.output_tokens / max_tokens * plot_h
          tot_h = min(in_h + out_h, plot_h)
          out_y = bottom - tot_h
          in_y = bottom - in_h

          tps_y =
            if is_number(m.tps) do
              bottom - min(m.tps / max_tps, 1.0) * plot_h
            end

          %{
            entry_id: m.entry_id,
            x: Float.round(cx - bar_w / 2, 2),
            cx: Float.round(cx, 2),
            bar_w: Float.round(bar_w, 2),
            in_y: Float.round(in_y, 2),
            in_h: Float.round(in_h, 2),
            out_y: Float.round(out_y, 2),
            out_h: Float.round(max(tot_h - in_h, 0.0), 2),
            tps: m.tps,
            tps_y: if(tps_y, do: Float.round(tps_y, 2)),
            input_tokens: m.input_tokens,
            output_tokens: m.output_tokens,
            total_tokens: m.total_tokens,
            duration_ms: m.duration_ms,
            tooltip: format_tooltip(m)
          }
        end)

      line_points =
        indexed
        |> Enum.filter(&is_number(&1.tps_y))
        |> Enum.map_join(" ", fn p -> "#{p.cx},#{p.tps_y}" end)

      %{
        points: indexed,
        line_points: line_points,
        has_tps?: tps_values != [],
        max_tps_label: format_tps(max_tps),
        max_tokens_label: format_compact_tokens(max_tokens),
        latest_tps_label:
          case List.last(tps_values) do
            nil -> "—"
            val -> "#{format_tps(val)} tok/s"
          end,
        turns: count
      }
    end
  end

  def build_chart(_turn_metrics, _max_turns), do: nil

  @doc """
  Renders the session sidebar turn metrics card from `assigns.sidebar[:turn_metrics]`.
  """
  def render(assigns) do
    render_with_max_turns(assigns, Map.get(assigns, :max_turns, @default_max_turns))
  end

  for max_turns <- 4..40 do
    @doc false
    def unquote(:"render_#{max_turns}")(assigns) do
      render_with_max_turns(assigns, unquote(max_turns))
    end
  end

  defp render_with_max_turns(assigns, max_turns) do
    sidebar = Map.get(assigns, :sidebar) || %{}
    metrics = Map.get(sidebar, :turn_metrics) || []
    assigns = Map.put(assigns, :chart, build_chart(metrics, max_turns))

    ~H"""
    <div :if={@chart} id="session-metrics-chart" class="session-metrics-chart sidebar-section">
      <div class="session-metrics-head mono muted">
        <span class="session-metrics-legend">
          <span class="session-metrics-swatch is-tps"></span>tok/s <span class="session-metrics-swatch is-in"></span>in <span class="session-metrics-swatch is-out"></span>out
        </span>
        <span>{@chart.latest_tps_label}</span>
      </div>
      <svg
        class="session-metrics-svg"
        viewBox="0 0 256 78"
        role="img"
        aria-label="Response speed in tokens per second and tokens in and out per turn"
      >
        <line x1="32" y1="8" x2="224" y2="8" class="metrics-grid" />
        <line x1="32" y1="37" x2="224" y2="37" class="metrics-grid" />
        <line x1="32" y1="66" x2="224" y2="66" class="metrics-axis" />
        <text x="29" y="11" text-anchor="end" class="metrics-label is-tps">
          {@chart.max_tps_label}
        </text>
        <text x="29" y="68" text-anchor="end" class="metrics-label is-tps">0</text>
        <text x="227" y="11" text-anchor="start" class="metrics-label">
          {@chart.max_tokens_label}
        </text>
        <text x="227" y="68" text-anchor="start" class="metrics-label">0</text>
        <g :for={p <- @chart.points}>
          <rect
            :if={p.in_h > 0}
            x={p.x}
            y={p.in_y}
            width={p.bar_w}
            height={p.in_h}
            rx="1"
            class="metrics-bar-in"
          >
            <title>{p.tooltip}</title>
          </rect>
          <rect
            :if={p.out_h > 0}
            x={p.x}
            y={p.out_y}
            width={p.bar_w}
            height={p.out_h}
            rx="1"
            class="metrics-bar-out"
          >
            <title>{p.tooltip}</title>
          </rect>
        </g>
        <polyline
          :if={@chart.has_tps? && @chart.line_points != ""}
          points={@chart.line_points}
          class="metrics-tps-line"
        />
        <circle
          :for={p <- @chart.points}
          :if={is_number(p.tps_y)}
          cx={p.cx}
          cy={p.tps_y}
          r="2"
          class="metrics-tps-dot"
        >
          <title>{p.tooltip}</title>
        </circle>
      </svg>
    </div>
    """
  end

  defp format_tooltip(m) do
    base = "Entry ##{m.entry_id}: #{m.input_tokens} in / #{m.output_tokens} out"

    base =
      if is_integer(m.duration_ms) and m.duration_ms > 0 do
        base <> " · #{format_duration(m.duration_ms)}"
      else
        base
      end

    if is_number(m.tps) do
      base <> " · #{format_tps(m.tps)} tok/s"
    else
      base
    end
  end

  defp format_duration(ms) when ms >= 1_000 do
    :erlang.float_to_binary(ms / 1_000, decimals: 1) <> "s"
  end

  defp format_duration(ms), do: "#{ms}ms"

  defp format_tps(val) when is_number(val) and val >= 100, do: "#{round(val)}"
  defp format_tps(val) when is_number(val), do: :erlang.float_to_binary(val * 1.0, decimals: 1)

  defp format_compact_tokens(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_compact_tokens(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}k"
  end

  defp format_compact_tokens(n) when is_integer(n), do: Integer.to_string(n)

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_), do: 0
end
