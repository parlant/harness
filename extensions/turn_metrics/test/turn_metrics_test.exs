defmodule Extensions.TurnMetricsTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Extensions.TurnMetrics
  alias Extensions.TurnMetrics.Sidebar

  setup do
    id = System.unique_integer([:positive])
    tmp_base = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(tmp_base, "h-turn-metrics-#{System.pid()}-#{id}")
    data_dir = Path.join(root, "data")
    dist_dir = Path.join(root, "dist/turn_metrics")

    File.mkdir_p!(data_dir)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    {:ok, root: root, data_dir: data_dir, dist_dir: dist_dir}
  end

  describe "configure/2" do
    test "returns default sidebar item and stylesheet and validates against H.Extensions.Web" do
      assert {:ok,
              %{
                web: %{
                  session_sidebar: [
                    %{
                      id: "turn-metrics",
                      position: {:after, "session-agent"},
                      order: 10,
                      module: Sidebar,
                      function: :render
                    }
                  ],
                  stylesheets: ["turn_metrics.css"]
                }
              } = contributions} =
               TurnMetrics.configure(%{}, %{id: "turn_metrics", data_dir: "/tmp"})

      pkg_root = Path.expand("..", __DIR__)

      assert {:ok,
              %{
                ext_id: "turn_metrics",
                session_sidebar: [%{id: "turn-metrics", position: {:after, "session-agent"}}],
                stylesheets: [
                  %{
                    ext_id: "turn_metrics",
                    file: "turn_metrics.css",
                    href: "/ext-assets/turn_metrics/turn_metrics.css"
                  }
                ]
              }} =
               H.Extensions.Web.validate(contributions.web, %{id: "turn_metrics", path: pkg_root})
    end

    test "accepts custom max_turns and position formats" do
      assert {:ok, %{web: %{session_sidebar: [%{position: :top, function: :render_12}]}}} =
               TurnMetrics.configure(%{"max_turns" => 12, "position" => "top"}, %{})

      assert {:ok, %{web: %{session_sidebar: [%{position: :bottom, function: :render}]}}} =
               TurnMetrics.configure(%{"position" => "bottom"}, %{})

      assert {:ok, %{web: %{session_sidebar: [%{position: {:before, "session-conversations"}}]}}} =
               TurnMetrics.configure(%{"position" => %{"before" => "session-conversations"}}, %{})

      assert {:ok, %{web: %{session_sidebar: [%{position: {:after, "session-tags"}}]}}} =
               TurnMetrics.configure(%{"position" => "after:session-tags"}, %{})

      assert {:ok, %{web: %{session_sidebar: [%{position: {:before, "session-meta"}}]}}} =
               TurnMetrics.configure(%{"position" => ["before", "session-meta"]}, %{})
    end

    test "rejects unknown keys and invalid settings types or bounds" do
      for bad <- [
            %{"unknown" => true},
            %{"max_turns" => 3},
            %{"max_turns" => 41},
            %{"max_turns" => "24"},
            %{"position" => "middle"},
            %{"position" => %{"after" => "../evil"}},
            %{"position" => %{"before" => "a", "after" => "b"}},
            %{"position" => 123}
          ] do
        assert {:error, :invalid_turn_metrics_settings} = TurnMetrics.configure(bad, %{})
      end
    end
  end

  describe "Sidebar.build_chart/2" do
    test "returns nil for empty or non-list input" do
      assert Sidebar.build_chart([]) == nil
      assert Sidebar.build_chart(nil) == nil
      assert Sidebar.build_chart([%{entry_id: "1"}], 0) == nil
    end

    test "scales single and multi-turn metrics, handles missing tps, and formats labels" do
      single =
        Sidebar.build_chart([
          %{
            entry_id: "2",
            input_tokens: 450,
            output_tokens: 150,
            total_tokens: 600,
            duration_ms: 1_500,
            tps: 100.4
          }
        ])

      assert single.turns == 1
      assert single.has_tps? == true
      assert single.max_tps_label == "100"
      assert single.max_tokens_label == "600"
      assert single.latest_tps_label == "100 tok/s"
      assert [pt] = single.points
      assert pt.tooltip == "Entry #2: 450 in / 150 out · 1.5s · 100 tok/s"
      assert single.line_points == "#{pt.cx},#{pt.tps_y}"

      multi =
        Sidebar.build_chart([
          %{
            entry_id: "1",
            input_tokens: 1_200,
            output_tokens: 300,
            total_tokens: 1_500,
            duration_ms: 800,
            tps: nil
          },
          %{
            entry_id: "2",
            input_tokens: 1_500_000,
            output_tokens: 500_000,
            total_tokens: 2_000_000,
            duration_ms: nil,
            tps: 42.34
          }
        ])

      assert multi.turns == 2
      assert multi.has_tps? == true
      assert multi.max_tps_label == "42.3"
      assert multi.max_tokens_label == "2.0M"
      assert multi.latest_tps_label == "42.3 tok/s"
      assert [p1, p2] = multi.points
      assert p1.tps_y == nil
      assert p1.tooltip == "Entry #1: 1200 in / 300 out · 800ms"
      assert is_number(p2.tps_y)
      assert p2.tooltip == "Entry #2: 1500000 in / 500000 out · 42.3 tok/s"
      assert multi.line_points == "#{p2.cx},#{p2.tps_y}"
    end

    test "handles turns without any tok/s values and truncates to max_turns" do
      metrics =
        for i <- 1..30 do
          %{
            entry_id: Integer.to_string(i),
            input_tokens: 1_000,
            output_tokens: 500,
            total_tokens: 1_500,
            duration_ms: nil,
            tps: nil
          }
        end

      chart = Sidebar.build_chart(metrics)
      assert chart.turns == 24
      assert chart.has_tps? == false
      assert chart.line_points == ""
      assert chart.max_tokens_label == "1.5k"
      assert chart.max_tps_label == "1.0"
      assert chart.latest_tps_label == "—"
      assert hd(chart.points).entry_id == "7"
      assert List.last(chart.points).entry_id == "30"
    end
  end

  describe "Sidebar.render/1 and built extension artifact loading" do
    test "renders nothing when turn_metrics is empty and renders accessible SVG when present" do
      empty_html =
        render_component(&Sidebar.render/1, %{
          id: "turn-metrics",
          ext_id: "turn_metrics",
          sidebar: %{turn_metrics: []}
        })

      assert String.trim(empty_html) == ""

      html =
        render_component(&Sidebar.render/1, %{
          id: "turn-metrics",
          ext_id: "turn_metrics",
          sidebar: %{
            turn_metrics: [
              %{
                entry_id: "5",
                input_tokens: 200,
                output_tokens: 80,
                total_tokens: 280,
                duration_ms: 2_000,
                tps: 40.0
              }
            ]
          }
        })

      assert html =~ ~s(id="session-metrics-chart")
      assert html =~ ~s(role="img")
      assert html =~ "40.0 tok/s"
      assert html =~ "Entry #5: 200 in / 80 out · 2.0s · 40.0 tok/s"
    end

    test "builds dist artifact, loads via H.Extensions.load_state/1, registers stylesheet, and orders after session-agent",
         ctx do
      Mix.Task.reenable("extension.build")
      Mix.Tasks.Extension.Build.run([ctx.dist_dir])

      assert File.regular?(Path.join(ctx.dist_dir, "extension.json"))
      assert File.regular?(Path.join([ctx.dist_dir, "priv", "static", "turn_metrics.css"]))

      File.write!(
        Path.join(ctx.data_dir, "extensions.json"),
        JSON.encode!(%{
          version: 1,
          extensions: [%{path: ctx.dist_dir}]
        })
      )

      script = """
      {:ok, opts, ext_state} = H.Extensions.load_state(data_dir: #{inspect(ctx.data_dir)})
      [%{id: "turn_metrics"}] = ext_state.packages

      [%{href: "/ext-assets/turn_metrics/turn_metrics.css"}] =
        HWeb.Extensions.stylesheets(opts)

      builtins = [
        %{id: "session-meta", kind: :builtin},
        %{id: "session-lineage", kind: :builtin},
        %{id: "session-tags", kind: :builtin},
        %{id: "session-agent", kind: :builtin},
        %{id: "session-conversations", kind: :builtin},
        %{id: "session-inbox-switcher", kind: :builtin}
      ]

      ordered =
        HWeb.Extensions.order_sidebar_items(builtins, HWeb.Extensions.sidebar_items(opts))

      [
        "session-meta",
        "session-lineage",
        "session-tags",
        "session-agent",
        "turn-metrics",
        "session-conversations",
        "session-inbox-switcher"
      ] = Enum.map(ordered, & &1.id)

      [%{module: mod, function: fun}] = HWeb.Extensions.sidebar_items(opts)

      rendered =
        Phoenix.LiveViewTest.rendered_to_string(
          apply(mod, fun, [
            %{
              id: "turn-metrics",
              ext_id: "turn_metrics",
              sidebar: %{
                turn_metrics: [
                  %{
                    entry_id: "9",
                    input_tokens: 120,
                    output_tokens: 60,
                    total_tokens: 180,
                    duration_ms: 1_500,
                    tps: 40.0
                  }
                ]
              }
            }
          ])
        )

      true = rendered =~ ~s(id="session-metrics-chart")
      true = rendered =~ "40.0 tok/s"
      IO.puts("TURN_METRICS_DIST_OK")
      """

      {output, status} = launch_clean_vm(script)
      assert status == 0, "Subprocess failed:\n#{output}"
      assert output =~ "TURN_METRICS_DIST_OK"
    end
  end

  defp launch_clean_vm(script) do
    own_ebin = Path.expand(Mix.Project.compile_path())

    pa_args =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.reject(&(&1 == own_ebin))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&["-pa", &1])

    System.cmd(
      System.find_executable("elixir"),
      pa_args ++ ["--erl", "+S 2:2", "-e", script],
      stderr_to_stdout: true,
      env: [{"H_DATA_DIR", nil}]
    )
  end
end
