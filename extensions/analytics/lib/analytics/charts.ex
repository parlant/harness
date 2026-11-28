defmodule Extensions.Analytics.Charts do
  @moduledoc """
  Pure JSON-serializable Vega-Lite v5/v6 specification builders for
  `Extensions.Analytics`.

  All specs embed inline data (`"data" => %{"values" => [...]}`) with zero
  external URLs, keeping them compliant with strict CSP and `blockedLoader`.
  """

  @schema "https://vega.github.io/schema/vega-lite/v5.json"

  @doc """
  Builds a Vega-Lite spec for daily spend (`cost_usd`) and token activity over `day`.
  """
  @spec daily_spend_and_tokens([map()]) :: map()
  def daily_spend_and_tokens(daily_series) when is_list(daily_series) do
    values =
      Enum.map(daily_series, fn row ->
        %{
          "day" => row.day,
          "turns" => row.turns,
          "cost_usd" => Float.round((row.cost_usd || 0.0) * 1.0, 4),
          "prompt_tokens" => row.prompt_tokens,
          "cache_read_tokens" => row.cached_tokens,
          "uncached_tokens" => row.uncached_tokens,
          "output_tokens" => row.output_tokens,
          "error_turns" => (row.error_turns || 0) + (row.aborted_turns || 0)
        }
      end)

    %{
      "$schema" => @schema,
      "width" => "container",
      "height" => 220,
      "data" => %{"values" => values},
      "layer" => [
        %{
          "mark" => %{"type" => "bar", "cornerRadiusTopLeft" => 3, "cornerRadiusTopRight" => 3},
          "encoding" => %{
            "x" => %{
              "field" => "day",
              "type" => "ordinal",
              "title" => "Day",
              "axis" => %{"labelAngle" => -30}
            },
            "y" => %{
              "field" => "cost_usd",
              "type" => "quantitative",
              "title" => "Spend ($)",
              "axis" => %{"format" => "$.2f"}
            },
            "color" => %{"value" => "#0969da"},
            "tooltip" => [
              %{"field" => "day", "type" => "ordinal", "title" => "Day"},
              %{"field" => "turns", "type" => "quantitative", "title" => "Turns"},
              %{
                "field" => "cost_usd",
                "type" => "quantitative",
                "title" => "Spend ($)",
                "format" => "$.4f"
              },
              %{
                "field" => "prompt_tokens",
                "type" => "quantitative",
                "title" => "Prompt tokens",
                "format" => ","
              },
              %{
                "field" => "cache_read_tokens",
                "type" => "quantitative",
                "title" => "Cached tokens",
                "format" => ","
              },
              %{
                "field" => "output_tokens",
                "type" => "quantitative",
                "title" => "Output tokens",
                "format" => ","
              },
              %{"field" => "error_turns", "type" => "quantitative", "title" => "Errors/Aborts"}
            ]
          }
        },
        %{
          "mark" => %{"type" => "line", "point" => true, "strokeWidth" => 2},
          "encoding" => %{
            "x" => %{"field" => "day", "type" => "ordinal"},
            "y" => %{
              "field" => "output_tokens",
              "type" => "quantitative",
              "title" => "Output tokens",
              "axis" => %{"orient" => "right", "format" => "~s"}
            },
            "color" => %{"value" => "#2da44e"},
            "tooltip" => [
              %{"field" => "day", "type" => "ordinal", "title" => "Day"},
              %{
                "field" => "output_tokens",
                "type" => "quantitative",
                "title" => "Output tokens",
                "format" => ","
              },
              %{"field" => "turns", "type" => "quantitative", "title" => "Turns"}
            ]
          }
        }
      ],
      "resolve" => %{"scale" => %{"y" => "independent"}}
    }
  end

  @doc """
  Builds a horizontal Vega-Lite spec comparing models' `p50_ms` and `p90_ms` latency
  (in seconds) with `median_tps`, `turns`, `cache_hit_pct`, and `cost_usd` tooltips.
  """
  @spec model_speed_and_latency([map()]) :: map()
  def model_speed_and_latency(model_rows) when is_list(model_rows) do
    values =
      model_rows
      |> Enum.take(12)
      |> Enum.map(fn row ->
        p50_s = ms_to_seconds(row.p50_ms) || 0.0
        p90_s = ms_to_seconds(row.p90_ms) || p50_s

        %{
          "model" => row.model,
          "provider" => row.provider,
          "p50_s" => p50_s,
          "p90_s" => p90_s,
          "median_tps" => row.median_tps || 0.0,
          "turns" => row.turns,
          "cache_hit_pct" => row.cache_pct,
          "cost_usd" => Float.round((row.cost_usd || 0.0) * 1.0, 4)
        }
      end)

    %{
      "$schema" => @schema,
      "width" => "container",
      "height" => max(180, min(320, max(length(values), 1) * 34 + 40)),
      "data" => %{"values" => values},
      "encoding" => %{
        "y" => %{
          "field" => "model",
          "type" => "nominal",
          "sort" => %{"field" => "p90_s", "order" => "descending"},
          "title" => nil
        },
        "tooltip" => [
          %{"field" => "provider", "type" => "nominal", "title" => "Provider"},
          %{"field" => "model", "type" => "nominal", "title" => "Model"},
          %{"field" => "turns", "type" => "quantitative", "title" => "Turns"},
          %{
            "field" => "p50_s",
            "type" => "quantitative",
            "title" => "p50 (s)",
            "format" => ".2f"
          },
          %{
            "field" => "p90_s",
            "type" => "quantitative",
            "title" => "p90 (s)",
            "format" => ".2f"
          },
          %{"field" => "median_tps", "type" => "quantitative", "title" => "Median tok/s"},
          %{"field" => "cache_hit_pct", "type" => "quantitative", "title" => "Cache %"},
          %{
            "field" => "cost_usd",
            "type" => "quantitative",
            "title" => "Spend ($)",
            "format" => "$.4f"
          }
        ]
      },
      "layer" => [
        %{
          "mark" => %{"type" => "bar", "height" => 12, "opacity" => 0.35, "cornerRadius" => 3},
          "encoding" => %{
            "x" => %{"field" => "p90_s", "type" => "quantitative", "title" => "Latency (s)"},
            "color" => %{"value" => "#bf8700"}
          }
        },
        %{
          "mark" => %{"type" => "bar", "height" => 12, "cornerRadius" => 3},
          "encoding" => %{
            "x" => %{"field" => "p50_s", "type" => "quantitative"},
            "color" => %{"value" => "#0969da"}
          }
        }
      ]
    }
  end

  @doc """
  Builds a grouped bar chart across context bands (`0-50k`, `50k-250k`, `250k-400k`, `400k+`)
  split by `cache_status` (`"Cache hit"` vs `"Uncached"`), plotting `p50_s` and `p90_s` latency.
  """
  @spec context_band_latency([map()]) :: map()
  def context_band_latency(context_band_rows) when is_list(context_band_rows) do
    values =
      Enum.map(context_band_rows, fn row ->
        %{
          "context_band" => row.context_band,
          "cache_status" => if(row.cache_hit, do: "Cache hit", else: "Uncached"),
          "p50_s" => ms_to_seconds(row.p50_ms) || 0.0,
          "p90_s" => ms_to_seconds(row.p90_ms) || 0.0,
          "turns" => row.turns,
          "median_tps" => row.median_tps || 0.0
        }
      end)

    %{
      "$schema" => @schema,
      "width" => "container",
      "height" => 220,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "cornerRadiusTopLeft" => 3, "cornerRadiusTopRight" => 3},
      "encoding" => %{
        "x" => %{
          "field" => "context_band",
          "type" => "nominal",
          "sort" => ["0-50k", "50k-250k", "250k-400k", "400k+"],
          "title" => "Prompt Context Band"
        },
        "xOffset" => %{"field" => "cache_status"},
        "y" => %{
          "field" => "p90_s",
          "type" => "quantitative",
          "title" => "p90 Latency (s)"
        },
        "color" => %{
          "field" => "cache_status",
          "type" => "nominal",
          "title" => "Cache",
          "scale" => %{
            "domain" => ["Cache hit", "Uncached"],
            "range" => ["#2da44e", "#cf222e"]
          }
        },
        "tooltip" => [
          %{"field" => "context_band", "type" => "nominal", "title" => "Context"},
          %{"field" => "cache_status", "type" => "nominal", "title" => "Cache"},
          %{"field" => "turns", "type" => "quantitative", "title" => "Turns"},
          %{
            "field" => "p50_s",
            "type" => "quantitative",
            "title" => "p50 (s)",
            "format" => ".2f"
          },
          %{
            "field" => "p90_s",
            "type" => "quantitative",
            "title" => "p90 (s)",
            "format" => ".2f"
          },
          %{"field" => "median_tps", "type" => "quantitative", "title" => "Median tok/s"}
        ]
      }
    }
  end

  @doc """
  Builds a horizontal bar chart of tool invocations, `p90_ms` (in seconds), and `error_rate_pct`
  by tool `name`, supporting click-to-drill-down (`datum.name`).
  """
  @spec tool_volume_and_latency([map()]) :: map()
  def tool_volume_and_latency(tool_rows) when is_list(tool_rows) do
    values =
      tool_rows
      |> Enum.take(12)
      |> Enum.map(fn row ->
        %{
          "name" => row.name,
          "count" => row.count,
          "errors" => row.errors,
          "error_rate_pct" => row.error_pct,
          "p50_ms" => row.p50_ms || 0,
          "p90_ms" => row.p90_ms || 0
        }
      end)

    %{
      "$schema" => @schema,
      "width" => "container",
      "height" => max(180, min(320, max(length(values), 1) * 30 + 40)),
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar", "cornerRadiusTopRight" => 3, "cornerRadiusBottomRight" => 3},
      "encoding" => %{
        "y" => %{
          "field" => "name",
          "type" => "nominal",
          "sort" => %{"field" => "count", "order" => "descending"},
          "title" => nil
        },
        "x" => %{
          "field" => "count",
          "type" => "quantitative",
          "title" => "Invocations"
        },
        "color" => %{
          "field" => "error_rate_pct",
          "type" => "quantitative",
          "title" => "Error %",
          "scale" => %{"domain" => [0, 50], "range" => ["#0969da", "#cf222e"], "clamp" => true}
        },
        "tooltip" => [
          %{"field" => "name", "type" => "nominal", "title" => "Tool"},
          %{"field" => "count", "type" => "quantitative", "title" => "Calls"},
          %{"field" => "errors", "type" => "quantitative", "title" => "Errors"},
          %{"field" => "error_rate_pct", "type" => "quantitative", "title" => "Error %"},
          %{"field" => "p50_ms", "type" => "quantitative", "title" => "p50 (ms)"},
          %{"field" => "p90_ms", "type" => "quantitative", "title" => "p90 (ms)"}
        ]
      }
    }
  end

  @doc """
  Builds a per-turn stacked token waterfall chart across assistant turns for the
  single-session drill-down page.
  """
  @spec session_turn_waterfall([map()]) :: map()
  def session_turn_waterfall(waterfall_events) when is_list(waterfall_events) do
    assistant_turns =
      waterfall_events
      |> Enum.filter(&(&1.kind == "assistant"))
      |> Enum.with_index(1)

    values =
      Enum.flat_map(assistant_turns, fn {turn, idx} ->
        turn_label = "##{turn.entry_id || idx}"
        dur_s = ms_to_seconds(turn.duration_ms) || 0.0

        base = %{
          "turn" => turn_label,
          "order" => idx,
          "model" => turn.model,
          "outcome" => turn.outcome,
          "duration_s" => dur_s,
          "tps" => turn.tps || 0.0,
          "cost_usd" => Float.round((turn.cost_usd || 0.0) * 1.0, 5)
        }

        [
          Map.merge(base, %{"segment" => "Cached prompt", "tokens" => turn.cache_read_tokens}),
          Map.merge(base, %{"segment" => "Uncached prompt", "tokens" => turn.uncached_tokens}),
          Map.merge(base, %{"segment" => "Output", "tokens" => turn.output_tokens})
        ]
      end)

    %{
      "$schema" => @schema,
      "width" => "container",
      "height" => 220,
      "data" => %{"values" => values},
      "mark" => %{"type" => "bar"},
      "encoding" => %{
        "x" => %{
          "field" => "turn",
          "type" => "ordinal",
          "sort" => %{"field" => "order"},
          "title" => "Assistant Turn"
        },
        "y" => %{
          "field" => "tokens",
          "type" => "quantitative",
          "title" => "Tokens",
          "axis" => %{"format" => "~s"}
        },
        "color" => %{
          "field" => "segment",
          "type" => "nominal",
          "title" => "Tokens",
          "scale" => %{
            "domain" => ["Cached prompt", "Uncached prompt", "Output"],
            "range" => ["#2da44e", "#bf8700", "#0969da"]
          }
        },
        "tooltip" => [
          %{"field" => "turn", "type" => "ordinal", "title" => "Turn"},
          %{"field" => "model", "type" => "nominal", "title" => "Model"},
          %{"field" => "segment", "type" => "nominal", "title" => "Segment"},
          %{
            "field" => "tokens",
            "type" => "quantitative",
            "title" => "Tokens",
            "format" => ","
          },
          %{"field" => "duration_s", "type" => "quantitative", "title" => "Duration (s)"},
          %{"field" => "tps", "type" => "quantitative", "title" => "tok/s"},
          %{"field" => "outcome", "type" => "nominal", "title" => "Outcome"},
          %{
            "field" => "cost_usd",
            "type" => "quantitative",
            "title" => "Cost ($)",
            "format" => "$.4f"
          }
        ]
      }
    }
  end

  defp ms_to_seconds(ms) when is_integer(ms) and ms >= 0, do: Float.round(ms / 1000.0, 2)
  defp ms_to_seconds(_), do: nil
end
