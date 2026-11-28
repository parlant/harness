defmodule Extensions.Analytics.Live do
  @moduledoc """
  Full Analytics LiveView page for `Extensions.Analytics`, supporting
  Overview, Models, Tools, Workspaces, and Session Waterfall drill-downs.
  """

  @behaviour HWeb.Extension.Page

  use Phoenix.Component

  import Phoenix.LiveView, only: [push_patch: 2]

  alias Extensions.Analytics.{Charts, Query, Store}

  @filter_query_keys [
    {:window, "window"},
    {:source, "source"},
    {:subsessions, "subsessions"},
    {:provider, "provider"},
    {:model, "model"},
    {:cwd, "cwd"},
    {:cache, "cache"},
    {:sort_by, "sort_by"},
    {:sort_dir, "sort_dir"}
  ]
  @windows ~w(24h 7d 30d 90d all)
  @sources [
    {"all", "All sources"},
    {"native", "Native (all)"},
    {"native_active", "Native active"},
    {"native_archived", "Native archived"},
    {"imported_archive", "Imported archive"}
  ]
  @subsession_modes [
    {"all", "All sessions"},
    {"roots_only", "Root sessions"},
    {"subsessions_only", "Subsessions"}
  ]
  @cache_modes [
    {"all", "All cache"},
    {"hit", "Cache hit"},
    {"miss", "Cache miss"}
  ]
  @sort_columns [
    {"updated_at", "Updated"},
    {"cost", "Cost"},
    {"tokens", "Prompt Tokens"},
    {"p90_ms", "p90 Latency"},
    {"errors", "Errors"}
  ]

  @impl HWeb.Extension.Page
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       daemon_opts: HWeb.Backend.InVM.daemon_opts(),
       tab: :overview,
       filters: Query.default_filters(),
       query_result: nil,
       index_stats: %{status: :offline, total: 0, cached: 0, dirty: 0, errors: 0},
       focus_model: nil,
       focus_tool: nil,
       session_detail: nil,
       session_error: nil,
       charts: %{}
     )}
  end

  @impl HWeb.Extension.Page
  def handle_params(params, _uri, socket) do
    subpath = Map.get(params, "subpath", [])
    filters = Query.normalize_filters(params)
    focus_model = non_empty(params["focus_model"])
    focus_tool = non_empty(params["focus_tool"])

    tab =
      case subpath do
        [] ->
          :overview

        ["models"] ->
          :models

        ["tools"] ->
          :tools

        ["workspaces"] ->
          :workspaces

        ["sessions", session_id] when is_binary(session_id) and session_id != "" ->
          :session_detail

        _ ->
          :overview
      end

    query_opts = query_opts_for(socket.assigns.daemon_opts)

    effective_filters =
      if tab == :models and focus_model, do: Map.put(filters, :model, focus_model), else: filters

    query_result = Store.query(effective_filters, query_opts)
    index_stats = Store.stats(store_server(socket.assigns.daemon_opts))

    {session_detail, session_error} =
      case {tab, subpath} do
        {:session_detail, ["sessions", session_id]} ->
          case Store.inspect_session(session_id, query_opts) do
            {:ok, detail} -> {detail, nil}
            {:error, reason} -> {nil, inspect(reason)}
          end

        _ ->
          {nil, nil}
      end

    charts = build_charts(tab, query_result, session_detail)

    {:noreply,
     assign(socket,
       tab: tab,
       filters: filters,
       focus_model: focus_model,
       focus_tool: focus_tool,
       query_result: query_result,
       index_stats: index_stats,
       session_detail: session_detail,
       session_error: session_error,
       charts: charts
     )}
  end

  @impl HWeb.Extension.Page
  def handle_event("refresh_index", _params, socket) do
    server = store_server(socket.assigns.daemon_opts)

    if resolve_store_running?(server) do
      _ = Store.sync_now(server)
    end

    query_opts = query_opts_for(socket.assigns.daemon_opts)

    effective_filters =
      if socket.assigns.tab == :models and socket.assigns.focus_model do
        Map.put(socket.assigns.filters, :model, socket.assigns.focus_model)
      else
        socket.assigns.filters
      end

    query_result = Store.query(effective_filters, query_opts)
    index_stats = Store.stats(server)

    {session_detail, session_error} =
      case {socket.assigns.tab, socket.assigns.session_detail} do
        {:session_detail, %{session: %{session_id: sid}}} ->
          case Store.inspect_session(sid, query_opts) do
            {:ok, detail} -> {detail, nil}
            {:error, reason} -> {nil, inspect(reason)}
          end

        _ ->
          {socket.assigns.session_detail, socket.assigns.session_error}
      end

    {:noreply,
     assign(socket,
       query_result: query_result,
       index_stats: index_stats,
       session_detail: session_detail,
       session_error: session_error,
       charts: build_charts(socket.assigns.tab, query_result, session_detail)
     )}
  end

  def handle_event("filter_change", params, socket) do
    next_filters =
      socket.assigns.filters
      |> merge_filter_params(params)
      |> Query.normalize_filters()

    {:noreply,
     push_patch(socket,
       to:
         path_with_filters(
           current_base_path(socket.assigns),
           next_filters,
           extra_params(socket.assigns)
         )
     )}
  end

  def handle_event("set_window", %{"window" => window}, socket) do
    next_filters = Query.normalize_filters(Map.put(socket.assigns.filters, :window, window))

    {:noreply,
     push_patch(socket,
       to:
         path_with_filters(
           current_base_path(socket.assigns),
           next_filters,
           extra_params(socket.assigns)
         )
     )}
  end

  def handle_event("reset_filters", _params, socket) do
    {:noreply, push_patch(socket, to: current_base_path(socket.assigns))}
  end

  def handle_event("sort_sessions", %{"col" => col}, socket) do
    cur = socket.assigns.filters

    next_dir =
      if cur.sort_by == col do
        if cur.sort_dir == "desc", do: "asc", else: "desc"
      else
        "desc"
      end

    next_filters = Query.normalize_filters(%{cur | sort_by: col, sort_dir: next_dir})

    {:noreply,
     push_patch(socket,
       to:
         path_with_filters(
           current_base_path(socket.assigns),
           next_filters,
           extra_params(socket.assigns)
         )
     )}
  end

  def handle_event("filter_cwd", %{"cwd" => cwd}, socket) do
    next_filters = Query.normalize_filters(Map.put(socket.assigns.filters, :cwd, cwd))
    {:noreply, push_patch(socket, to: path_with_filters("/ext/analytics", next_filters))}
  end

  def handle_event("drill_workspace", %{"cwd" => cwd}, socket) do
    next_filters = Query.normalize_filters(Map.put(socket.assigns.filters, :cwd, cwd))

    {:noreply,
     push_patch(socket, to: path_with_filters("/ext/analytics/workspaces", next_filters))}
  end

  def handle_event("focus_model", %{"model" => model}, socket) do
    next = if socket.assigns.focus_model == model, do: nil, else: model
    extra = if next, do: %{"focus_model" => next}, else: %{}

    {:noreply,
     push_patch(socket,
       to: path_with_filters("/ext/analytics/models", socket.assigns.filters, extra)
     )}
  end

  def handle_event("chart_select_model", %{"datum" => %{"model" => model}}, socket)
      when is_binary(model) do
    {:noreply,
     push_patch(socket,
       to:
         path_with_filters("/ext/analytics/models", socket.assigns.filters, %{
           "focus_model" => model
         })
     )}
  end

  def handle_event("chart_select_model", _params, socket), do: {:noreply, socket}

  def handle_event("focus_tool", %{"tool" => tool}, socket) do
    next = if socket.assigns.focus_tool == tool, do: nil, else: tool
    extra = if next, do: %{"focus_tool" => next}, else: %{}

    {:noreply,
     push_patch(socket,
       to: path_with_filters("/ext/analytics/tools", socket.assigns.filters, extra)
     )}
  end

  def handle_event("chart_select_tool", %{"datum" => %{"name" => tool}}, socket)
      when is_binary(tool) do
    {:noreply,
     push_patch(socket,
       to:
         path_with_filters("/ext/analytics/tools", socket.assigns.filters, %{"focus_tool" => tool})
     )}
  end

  def handle_event("chart_select_tool", _params, socket), do: {:noreply, socket}

  @impl HWeb.Extension.Page
  def render(assigns) do
    assigns =
      assigns
      |> assign(:windows, @windows)
      |> assign(:sources, @sources)
      |> assign(:subsession_modes, @subsession_modes)
      |> assign(:cache_modes, @cache_modes)
      |> assign(:sort_columns, @sort_columns)
      |> assign(:non_default?, non_default_filters?(assigns.filters))
      |> assign(:indexed_count, indexed_session_count(assigns.index_stats, assigns.query_result))

    ~H"""
    <HWeb.Extension.shell title="Analytics" section={@ext_section}>
      <:actions>
        <span id="analytics-index-badge" class="badge">
          Indexed {@indexed_count} sessions
        </span>
        <button
          id="analytics-refresh-btn"
          type="button"
          class="btn btn-sm"
          phx-click="refresh_index"
        >
          Refresh
        </button>
      </:actions>

      <div class="analytics-page">
        <nav class="analytics-tabs" aria-label="Analytics sections">
          <.link
            id="analytics-tab-overview"
            patch={path_with_filters("/ext/analytics", @filters)}
            class={["analytics-tab", @tab == :overview && "is-active"]}
          >
            Overview
          </.link>
          <.link
            id="analytics-tab-models"
            patch={path_with_filters("/ext/analytics/models", @filters)}
            class={["analytics-tab", @tab == :models && "is-active"]}
          >
            Models
          </.link>
          <.link
            id="analytics-tab-tools"
            patch={path_with_filters("/ext/analytics/tools", @filters)}
            class={["analytics-tab", @tab == :tools && "is-active"]}
          >
            Tools
          </.link>
          <.link
            id="analytics-tab-workspaces"
            patch={path_with_filters("/ext/analytics/workspaces", @filters)}
            class={["analytics-tab", @tab == :workspaces && "is-active"]}
          >
            Workspaces
          </.link>
          <.link
            :if={@tab == :session_detail and @session_detail}
            id="analytics-tab-session"
            patch={path_with_filters("/ext/analytics/sessions/#{@session_detail.session.session_id}", @filters)}
            class="analytics-tab is-active"
          >
            Session #{short_id(@session_detail.session.session_id)}
          </.link>
        </nav>

        <section :if={@tab != :session_detail} class="analytics-card analytics-filters-card">
          <div class="analytics-window-pills" role="group" aria-label="Time window">
            <button
              :for={win <- @windows}
              id={"analytics-window-#{win}"}
              type="button"
              class={["analytics-pill", @filters.window == win && "is-active"]}
              phx-click="set_window"
              phx-value-window={win}
            >
              {window_label(win)}
            </button>
          </div>

          <form id="analytics-filter-form" class="analytics-filter-form" phx-change="filter_change">
            <label class="analytics-filter-field">
              <span>Source</span>
              <select name="source" class="analytics-select">
                <option :for={{val, label} <- @sources} value={val} selected={@filters.source == val}>
                  {label}
                </option>
              </select>
            </label>

            <label class="analytics-filter-field">
              <span>Hierarchy</span>
              <select name="subsessions" class="analytics-select">
                <option
                  :for={{val, label} <- @subsession_modes}
                  value={val}
                  selected={@filters.subsessions == val}
                >
                  {label}
                </option>
              </select>
            </label>

            <label class="analytics-filter-field">
              <span>Provider</span>
              <select name="provider" class="analytics-select">
                <option value="all" selected={is_nil(@filters.provider)}>All providers</option>
                <option
                  :for={p <- @query_result.filter_options.providers}
                  value={p}
                  selected={@filters.provider == p}
                >
                  {p}
                </option>
              </select>
            </label>

            <label class="analytics-filter-field">
              <span>Model</span>
              <select name="model" class="analytics-select">
                <option value="all" selected={is_nil(@filters.model)}>All models</option>
                <option
                  :for={m <- @query_result.filter_options.models}
                  value={m}
                  selected={@filters.model == m}
                >
                  {m}
                </option>
              </select>
            </label>

            <label class="analytics-filter-field">
              <span>Workspace</span>
              <select name="cwd" class="analytics-select">
                <option value="all" selected={is_nil(@filters.cwd)}>All workspaces</option>
                <option
                  :for={w <- @query_result.filter_options.workspaces}
                  value={w}
                  selected={@filters.cwd == w}
                >
                  {w}
                </option>
              </select>
            </label>

            <label class="analytics-filter-field">
              <span>Cache</span>
              <select name="cache" class="analytics-select">
                <option :for={{val, label} <- @cache_modes} value={val} selected={@filters.cache == val}>
                  {label}
                </option>
              </select>
            </label>

            <button
              :if={@non_default?}
              id="analytics-reset-filters-btn"
              type="button"
              class="btn btn-sm"
              phx-click="reset_filters"
            >
              Reset
            </button>
          </form>
        </section>

        <%= case @tab do %>
          <% :overview -> %>
            <.render_overview
              query_result={@query_result}
              filters={@filters}
              charts={@charts}
              sort_columns={@sort_columns}
            />
          <% :models -> %>
            <.render_models
              query_result={@query_result}
              filters={@filters}
              focus_model={@focus_model}
              charts={@charts}
            />
          <% :tools -> %>
            <.render_tools
              query_result={@query_result}
              filters={@filters}
              focus_tool={@focus_tool}
              charts={@charts}
            />
          <% :workspaces -> %>
            <.render_workspaces query_result={@query_result} filters={@filters} />
          <% :session_detail -> %>
            <.render_session_detail
              session_detail={@session_detail}
              session_error={@session_error}
              filters={@filters}
              charts={@charts}
            />
        <% end %>
      </div>
    </HWeb.Extension.shell>
    """
  end

  defp render_overview(assigns) do
    k = assigns.query_result.kpis
    assigns = assign(assigns, :kpis, k)

    ~H"""
    <section id="analytics-kpis" class="analytics-kpis">
      <div class="analytics-card analytics-kpi">
        <div class="analytics-kpi-label">Sessions</div>
        <div class="analytics-kpi-value">{@kpis.session_count}</div>
        <div class="analytics-kpi-sub">
          {@kpis.sessions_by_source["native_active"]} active ·
          {@kpis.sessions_by_source["native_archived"]} archived ·
          {@kpis.sessions_by_source["imported_archive"]} imported
        </div>
      </div>

      <div class="analytics-card analytics-kpi">
        <div class="analytics-kpi-label">Turns &amp; Reliability</div>
        <div class="analytics-kpi-value">{@kpis.completed_turns} / {@kpis.turn_count}</div>
        <div class="analytics-kpi-sub">
          {format_tokens(@kpis.output_tokens)} out ·
          {@kpis.error_turns + @kpis.aborted_turns} err/abort ·
          {format_ms(@kpis.wasted_ms)} wasted
        </div>
      </div>

      <div class="analytics-card analytics-kpi">
        <div class="analytics-kpi-label">Total Cost</div>
        <div class="analytics-kpi-value">{format_cost(@kpis.cost_usd)}</div>
        <div class="analytics-kpi-sub">
          {if @kpis.cost_usd == 0.0 and @kpis.turn_count > 0,
            do: "Includes zero-cost / subscription turns",
            else: "Recorded provider usage cost"}
        </div>
      </div>

      <div class="analytics-card analytics-kpi">
        <div class="analytics-kpi-label">Prompt &amp; Cache</div>
        <div class="analytics-kpi-value">{format_pct(@kpis.cache_hit_pct)}</div>
        <div class="analytics-kpi-sub">
          {format_tokens(@kpis.prompt_tokens)} prompt ·
          {format_tokens(@kpis.cached_tokens)} cached ·
          {format_tokens(@kpis.uncached_tokens)} uncached
        </div>
      </div>

      <div class="analytics-card analytics-kpi">
        <div class="analytics-kpi-label">Response Speed</div>
        <div class="analytics-kpi-value">{format_seconds(@kpis.p50_turn_ms)} p50</div>
        <div class="analytics-kpi-sub">
          {format_seconds(@kpis.p90_turn_ms)} p90 ·
          {format_tps(@kpis.median_tps)} median
        </div>
      </div>

      <div class="analytics-card analytics-kpi">
        <div class="analytics-kpi-label">Tool Calls</div>
        <div class="analytics-kpi-value">{@kpis.tool_calls}</div>
        <div class="analytics-kpi-sub">
          {format_pct(@kpis.tool_error_pct)} error ({@kpis.tool_errors}) ·
          {format_ms(@kpis.p50_tool_ms)} p50 · {format_ms(@kpis.p90_tool_ms)} p90
        </div>
      </div>
    </section>

    <section class="analytics-charts-grid">
      <div class="analytics-card analytics-chart-card">
        <div class="analytics-card-header">
          <h3>Daily Spend &amp; Output Tokens</h3>
        </div>
        <div
          id="chart-daily-spend"
          class="analytics-chart-host"
          phx-hook="AnalyticsVegaChart"
          phx-update="ignore"
          data-spec={@charts.daily_spend}
        >
        </div>
      </div>

      <div class="analytics-card analytics-chart-card">
        <div class="analytics-card-header">
          <h3>Model Speed &amp; Latency</h3>
          <span class="muted">Click bar to drill down</span>
        </div>
        <div
          id="chart-model-speed"
          class="analytics-chart-host"
          phx-hook="AnalyticsVegaChart"
          phx-update="ignore"
          data-click-event="chart_select_model"
          data-spec={@charts.model_speed}
        >
        </div>
      </div>

      <div class="analytics-card analytics-chart-card">
        <div class="analytics-card-header">
          <h3>Context Band × Cache Hit Latency</h3>
        </div>
        <div
          id="chart-context-band"
          class="analytics-chart-host"
          phx-hook="AnalyticsVegaChart"
          phx-update="ignore"
          data-spec={@charts.context_band}
        >
        </div>
      </div>

      <div class="analytics-card analytics-chart-card">
        <div class="analytics-card-header">
          <h3>Tool Volume &amp; Error Rate</h3>
          <span class="muted">Click bar to drill down</span>
        </div>
        <div
          id="chart-tool-volume"
          class="analytics-chart-host"
          phx-hook="AnalyticsVegaChart"
          phx-update="ignore"
          data-click-event="chart_select_tool"
          data-spec={@charts.tool_volume}
        >
        </div>
      </div>
    </section>

    <section class="analytics-card">
      <div class="analytics-card-header">
        <h3>Sessions ({length(@query_result.sessions)})</h3>
        <div class="analytics-sort-bar">
          <span class="muted">Sort:</span>
          <button
            :for={{col, label} <- @sort_columns}
            type="button"
            class={["analytics-sort-btn", @filters.sort_by == col && "is-active"]}
            phx-click="sort_sessions"
            phx-value-col={col}
          >
            {label}{if @filters.sort_by == col, do: sort_arrow(@filters.sort_dir), else: ""}
          </button>
        </div>
      </div>

      <div class="analytics-table-wrap">
        <table id="analytics-sessions-table" class="analytics-table">
          <thead>
            <tr>
              <th>Session</th>
              <th>Source</th>
              <th>Workspace</th>
              <th>Models</th>
              <th class="num">Turns</th>
              <th class="num">Prompt</th>
              <th class="num">Cache %</th>
              <th class="num">p90</th>
              <th class="num">Errors</th>
              <th class="num">Cost</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@query_result.sessions == []}>
              <td colspan="11" class="muted">No sessions match the active filters.</td>
            </tr>
            <tr :for={s <- @query_result.sessions} data-session-id={s.session_id}>
              <td>
                <div class="analytics-sess-title">{s.title || short_id(s.session_id)}</div>
                <div class="mono muted analytics-sub-id">
                  {s.session_id}
                  <span :if={s.is_subsession} class="badge">sub</span>
                </div>
              </td>
              <td>
                <span class={["badge", source_badge_class(s.source_kind)]}>
                  {source_label(s.source_kind)}
                </span>
              </td>
              <td>
                <button
                  :if={s.cwd != ""}
                  type="button"
                  class="analytics-link-btn mono"
                  phx-click="filter_cwd"
                  phx-value-cwd={s.cwd}
                  title="Filter by workspace"
                >
                  {s.cwd}
                </button>
                <span :if={s.cwd == ""} class="muted">—</span>
              </td>
              <td class="mono">{Enum.join(s.models, ", ")}</td>
              <td class="num">{s.turn_count}</td>
              <td class="num">{format_tokens(s.prompt_tokens)}</td>
              <td class="num">{format_pct(session_cache_pct(s))}</td>
              <td class="num">{format_seconds(s.p90_turn_ms)}</td>
              <td class="num">{s.total_errors}</td>
              <td class="num">{format_cost(s.cost_usd)}</td>
              <td class="analytics-row-actions">
                <.link
                  patch={path_with_filters("/ext/analytics/sessions/#{s.session_id}", @filters)}
                  class="btn btn-sm"
                >
                  Inspect
                </.link>
                <.link navigate={"/sessions/#{s.session_id}"} class="btn btn-sm">
                  Open →
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp render_models(assigns) do
    ~H"""
    <section class="analytics-card analytics-chart-card">
      <div class="analytics-card-header">
        <h3>Model Speed &amp; Latency</h3>
        <span class="muted">p50 (solid) vs p90 (shaded) in seconds</span>
      </div>
      <div
        id="chart-models-tab"
        class="analytics-chart-host"
        phx-hook="AnalyticsVegaChart"
        phx-update="ignore"
        data-click-event="chart_select_model"
        data-spec={@charts.model_speed}
      >
      </div>
    </section>

    <section class="analytics-card">
      <div class="analytics-card-header">
        <h3>Models Breakdown ({length(@query_result.model_breakdown)})</h3>
        <span class="muted">Click a row to inspect thinking &amp; context-band drill-down</span>
      </div>
      <div class="analytics-table-wrap">
        <table id="analytics-models-table" class="analytics-table">
          <thead>
            <tr>
              <th>Provider</th>
              <th>Model</th>
              <th class="num">Turns</th>
              <th class="num">Cost</th>
              <th class="num">Prompt</th>
              <th class="num">Cache %</th>
              <th class="num">Output</th>
              <th class="num">Reasoning</th>
              <th class="num">p50</th>
              <th class="num">p90</th>
              <th class="num">tok/s</th>
              <th class="num">Errors</th>
              <th class="num">Aborts</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@query_result.model_breakdown == []}>
              <td colspan="13" class="muted">No model turns match the active filters.</td>
            </tr>
            <tr
              :for={m <- @query_result.model_breakdown}
              class={["analytics-clickable-row", @focus_model == m.model && "is-focused"]}
              phx-click="focus_model"
              phx-value-model={m.model}
            >
              <td class="mono">{m.provider}</td>
              <td class="mono"><strong>{m.model}</strong></td>
              <td class="num">{m.turns}</td>
              <td class="num">{format_cost(m.cost_usd)}</td>
              <td class="num">{format_tokens(m.prompt_tokens)}</td>
              <td class="num">{format_pct(m.cache_pct)}</td>
              <td class="num">{format_tokens(m.output_tokens)}</td>
              <td class="num">{format_tokens(m.reasoning_tokens)}</td>
              <td class="num">{format_seconds(m.p50_ms)}</td>
              <td class="num">{format_seconds(m.p90_ms)}</td>
              <td class="num">{format_tps(m.median_tps)}</td>
              <td class="num">{m.errors}</td>
              <td class="num">{m.aborted}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section
      :if={@focus_model && @query_result.focused_model_breakdown}
      id="analytics-focused-model"
      class="analytics-card"
    >
      <div class="analytics-card-header">
        <h3>Focused Model Drill-Down: <span class="mono">{@focus_model}</span></h3>
        <button
          type="button"
          class="btn btn-sm"
          phx-click="focus_model"
          phx-value-model={@focus_model}
        >
          Clear focus
        </button>
      </div>

      <div class="analytics-drill-grid">
        <div>
          <h4>By Thinking Level</h4>
          <table class="analytics-table">
            <thead>
              <tr>
                <th>Thinking</th>
                <th class="num">Turns</th>
                <th class="num">p50</th>
                <th class="num">p90</th>
                <th class="num">tok/s</th>
                <th class="num">Cost</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @query_result.focused_model_breakdown.by_thinking}>
                <td class="mono">{row.thinking}</td>
                <td class="num">{row.turns}</td>
                <td class="num">{format_seconds(row.p50_ms)}</td>
                <td class="num">{format_seconds(row.p90_ms)}</td>
                <td class="num">{format_tps(row.median_tps)}</td>
                <td class="num">{format_cost(row.cost_usd)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div>
          <h4>By Context Band × Cache Hit</h4>
          <table class="analytics-table">
            <thead>
              <tr>
                <th>Band</th>
                <th>Cache</th>
                <th class="num">Turns</th>
                <th class="num">p50</th>
                <th class="num">p90</th>
                <th class="num">tok/s</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @query_result.focused_model_breakdown.by_context_cache}>
                <td class="mono">{row.context_band}</td>
                <td>{if row.cache_hit, do: "Hit", else: "Miss"}</td>
                <td class="num">{row.turns}</td>
                <td class="num">{format_seconds(row.p50_ms)}</td>
                <td class="num">{format_seconds(row.p90_ms)}</td>
                <td class="num">{format_tps(row.median_tps)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  defp render_tools(assigns) do
    focused =
      if assigns.focus_tool do
        Enum.find(assigns.query_result.tool_breakdown, &(&1.name == assigns.focus_tool))
      end

    assigns = assign(assigns, :focused_tool_row, focused)

    ~H"""
    <section class="analytics-card analytics-chart-card">
      <div class="analytics-card-header">
        <h3>Tool Volume &amp; Reliability</h3>
      </div>
      <div
        id="chart-tools-tab"
        class="analytics-chart-host"
        phx-hook="AnalyticsVegaChart"
        phx-update="ignore"
        data-click-event="chart_select_tool"
        data-spec={@charts.tool_volume}
      >
      </div>
    </section>

    <section class="analytics-card">
      <div class="analytics-card-header">
        <h3>Tools Breakdown ({length(@query_result.tool_breakdown)})</h3>
        <span class="muted">Click a tool to inspect slowest &amp; failing sessions</span>
      </div>
      <div class="analytics-table-wrap">
        <table id="analytics-tools-table" class="analytics-table">
          <thead>
            <tr>
              <th>Tool</th>
              <th class="num">Calls</th>
              <th class="num">Errors</th>
              <th class="num">Error %</th>
              <th class="num">p50</th>
              <th class="num">p90</th>
              <th class="num">Max</th>
              <th class="num">Total Time</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@query_result.tool_breakdown == []}>
              <td colspan="8" class="muted">No tool calls match the active filters.</td>
            </tr>
            <tr
              :for={t <- @query_result.tool_breakdown}
              class={["analytics-clickable-row", @focus_tool == t.name && "is-focused"]}
              phx-click="focus_tool"
              phx-value-tool={t.name}
            >
              <td class="mono"><strong>{t.name}</strong></td>
              <td class="num">{t.count}</td>
              <td class="num">{t.errors}</td>
              <td class="num">{format_pct(t.error_pct)}</td>
              <td class="num">{format_ms(t.p50_ms)}</td>
              <td class="num">{format_ms(t.p90_ms)}</td>
              <td class="num">{format_ms(t.max_ms)}</td>
              <td class="num">{format_ms(t.total_ms)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section :if={@focused_tool_row} id="analytics-focused-tool" class="analytics-card">
      <div class="analytics-card-header">
        <h3>Focused Tool Drill-Down: <span class="mono">{@focused_tool_row.name}</span></h3>
        <button
          type="button"
          class="btn btn-sm"
          phx-click="focus_tool"
          phx-value-tool={@focused_tool_row.name}
        >
          Clear focus
        </button>
      </div>

      <div class="analytics-drill-grid">
        <div>
          <h4>Top Failing Sessions</h4>
          <table class="analytics-table">
            <thead>
              <tr>
                <th>Session</th>
                <th class="num">Errors</th>
                <th class="num">Calls</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@focused_tool_row.top_failing_sessions == []}>
                <td colspan="4" class="muted">Zero tool errors recorded.</td>
              </tr>
              <tr :for={s <- @focused_tool_row.top_failing_sessions}>
                <td class="mono">{s.title || s.session_id}</td>
                <td class="num">{s.errors}</td>
                <td class="num">{s.count}</td>
                <td>
                  <.link
                    patch={path_with_filters("/ext/analytics/sessions/#{s.session_id}", @filters)}
                    class="btn btn-sm"
                  >
                    Inspect
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div>
          <h4>Slowest Sessions</h4>
          <table class="analytics-table">
            <thead>
              <tr>
                <th>Session</th>
                <th class="num">Max</th>
                <th class="num">Total</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@focused_tool_row.top_slow_sessions == []}>
                <td colspan="4" class="muted">No duration timings recorded.</td>
              </tr>
              <tr :for={s <- @focused_tool_row.top_slow_sessions}>
                <td class="mono">{s.title || s.session_id}</td>
                <td class="num">{format_ms(s.max_ms)}</td>
                <td class="num">{format_ms(s.total_ms)}</td>
                <td>
                  <.link
                    patch={path_with_filters("/ext/analytics/sessions/#{s.session_id}", @filters)}
                    class="btn btn-sm"
                  >
                    Inspect
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  defp render_workspaces(assigns) do
    focused_cwd = assigns.filters.cwd
    assigns = assign(assigns, :focused_cwd, focused_cwd)

    ~H"""
    <section class="analytics-card">
      <div class="analytics-card-header">
        <h3>Workspaces Breakdown ({length(@query_result.workspace_breakdown)})</h3>
        <span class="muted">Click a workspace to drill down or filter Overview</span>
      </div>
      <div class="analytics-table-wrap">
        <table id="analytics-workspaces-table" class="analytics-table">
          <thead>
            <tr>
              <th>Workspace cwd</th>
              <th class="num">Sessions</th>
              <th class="num">Turns</th>
              <th class="num">Cost</th>
              <th class="num">Prompt Tokens</th>
              <th class="num">Cache %</th>
              <th class="num">Errors</th>
              <th>Last Active</th>
              <th>Action</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@query_result.workspace_breakdown == []}>
              <td colspan="9" class="muted">No workspaces match the active filters.</td>
            </tr>
            <tr
              :for={w <- @query_result.workspace_breakdown}
              class={["analytics-clickable-row", @focused_cwd == w.cwd && "is-focused"]}
            >
              <td class="mono">
                <button
                  :if={w.cwd != ""}
                  type="button"
                  class="analytics-link-btn mono"
                  phx-click="drill_workspace"
                  phx-value-cwd={w.cwd}
                >
                  {w.cwd}
                </button>
                <span :if={w.cwd == ""} class="muted">(unspecified)</span>
              </td>
              <td class="num">{w.sessions}</td>
              <td class="num">{w.turns}</td>
              <td class="num">{format_cost(w.cost_usd)}</td>
              <td class="num">{format_tokens(w.prompt_tokens)}</td>
              <td class="num">{format_pct(workspace_cache_pct(w))}</td>
              <td class="num">{w.errors}</td>
              <td class="mono muted">{format_day(Map.get(w, :last_active_at))}</td>
              <td>
                <button
                  :if={w.cwd != ""}
                  type="button"
                  class="btn btn-sm"
                  phx-click="filter_cwd"
                  phx-value-cwd={w.cwd}
                >
                  Filter
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section :if={@focused_cwd} id="analytics-focused-workspace" class="analytics-card">
      <div class="analytics-card-header">
        <h3>Workspace Sessions: <span class="mono">{@focused_cwd}</span></h3>
        <.link patch={path_with_filters("/ext/analytics", @filters)} class="btn btn-sm">
          View in Overview
        </.link>
      </div>
      <div class="analytics-table-wrap">
        <table class="analytics-table">
          <thead>
            <tr>
              <th>Session</th>
              <th>Source</th>
              <th class="num">Turns</th>
              <th class="num">Cost</th>
              <th class="num">Errors</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @query_result.sessions}>
              <td class="mono">{s.title || s.session_id}</td>
              <td>
                <span class={["badge", source_badge_class(s.source_kind)]}>
                  {source_label(s.source_kind)}
                </span>
              </td>
              <td class="num">{s.turn_count}</td>
              <td class="num">{format_cost(s.cost_usd)}</td>
              <td class="num">{s.total_errors}</td>
              <td>
                <.link
                  patch={path_with_filters("/ext/analytics/sessions/#{s.session_id}", @filters)}
                  class="btn btn-sm"
                >
                  Inspect
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp render_session_detail(assigns) do
    ~H"""
    <section :if={@session_error} class="analytics-card">
      <h3>Session unavailable</h3>
      <p class="muted">Could not inspect session: {@session_error}</p>
      <.link patch={path_with_filters("/ext/analytics", @filters)} class="btn btn-sm">
        ← Back to Overview
      </.link>
    </section>

    <section :if={@session_detail} id="analytics-session-detail" class="analytics-detail-stack">
      <div class="analytics-card analytics-detail-header">
        <div>
          <div class="analytics-detail-title">
            <h2>{@session_detail.session.title || @session_detail.session.session_id}</h2>
            <span class={["badge", source_badge_class(@session_detail.session.source_kind)]}>
              {source_label(@session_detail.session.source_kind)}
            </span>
          </div>
          <div class="mono muted analytics-sub-id">
            {@session_detail.session.session_id} · {@session_detail.session.cwd}
          </div>
        </div>

        <div class="analytics-row-actions">
          <.link patch={path_with_filters("/ext/analytics", @filters)} class="btn btn-sm">
            ← Overview
          </.link>
          <.link
            :if={@session_detail.session.parent_session_id}
            patch={path_with_filters("/ext/analytics/sessions/#{@session_detail.session.parent_session_id}", @filters)}
            class="btn btn-sm"
          >
            Parent Session
          </.link>
          <.link navigate={"/sessions/#{@session_detail.session.session_id}"} class="btn btn-sm btn-primary">
            Open Session
          </.link>
        </div>
      </div>

      <section class="analytics-kpis">
        <div class="analytics-card analytics-kpi">
          <div class="analytics-kpi-label">Turns</div>
          <div class="analytics-kpi-value">{@session_detail.session.totals.turn_count}</div>
          <div class="analytics-kpi-sub">
            {@session_detail.session.totals.completed_turns} ok ·
            {@session_detail.session.totals.error_turns} err ·
            {@session_detail.session.totals.aborted_turns} abort
          </div>
        </div>

        <div class="analytics-card analytics-kpi">
          <div class="analytics-kpi-label">Cost</div>
          <div class="analytics-kpi-value">{format_cost(@session_detail.session.totals.cost_usd)}</div>
          <div class="analytics-kpi-sub">
            {format_tokens(@session_detail.session.totals.prompt_tokens)} prompt ·
            {format_tokens(@session_detail.session.totals.output_tokens)} out
          </div>
        </div>

        <div class="analytics-card analytics-kpi">
          <div class="analytics-kpi-label">Tools</div>
          <div class="analytics-kpi-value">{@session_detail.session.totals.tool_calls}</div>
          <div class="analytics-kpi-sub">
            {@session_detail.session.totals.tool_errors} errors ·
            {format_ms(@session_detail.session.totals.tool_duration_ms)} total
          </div>
        </div>

        <div class="analytics-card analytics-kpi">
          <div class="analytics-kpi-label">Restarts</div>
          <div class="analytics-kpi-value">{@session_detail.session.totals.restarts}</div>
          <div class="analytics-kpi-sub">
            {format_ms(@session_detail.session.totals.wasted_ms)} wasted on errors/aborts
          </div>
        </div>
      </section>

      <section class="analytics-card analytics-chart-card">
        <div class="analytics-card-header">
          <h3>Per-Turn Token &amp; Latency Waterfall</h3>
        </div>
        <div
          id="chart-session-waterfall"
          class="analytics-chart-host"
          phx-hook="AnalyticsVegaChart"
          phx-update="ignore"
          data-spec={@charts.session_waterfall}
        >
        </div>
      </section>

      <section class="analytics-card">
        <div class="analytics-card-header">
          <h3>Chronological Waterfall ({length(@session_detail.events)} events)</h3>
        </div>
        <div class="analytics-table-wrap">
          <table id="analytics-waterfall-table" class="analytics-table">
            <thead>
              <tr>
                <th>#</th>
                <th>Kind</th>
                <th>Model / Tool</th>
                <th>Thinking</th>
                <th class="num">Prompt (in / cache / out)</th>
                <th class="num">Cost</th>
                <th class="num">Duration</th>
                <th class="num">tok/s</th>
                <th>Outcome</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={ev <- @session_detail.events}>
                <td class="mono">#{ev.entry_id || "—"}</td>
                <td>
                  <span class={["badge", event_badge_class(ev.kind, ev)]}>{ev.kind}</span>
                </td>
                <td class="mono">
                  <%= case ev.kind do %>
                    <% "assistant" -> %>
                      {ev.provider}:{ev.model}
                    <% "tool_result" -> %>
                      {ev.name}
                    <% _ -> %>
                      <span class="muted">{Map.get(ev, :preview, "")}</span>
                  <% end %>
                </td>
                <td class="mono">{if ev.kind == "assistant", do: ev.thinking, else: "—"}</td>
                <td class="num mono">
                  <%= if ev.kind == "assistant" do %>
                    {format_tokens(ev.prompt_tokens)} / {format_tokens(ev.cache_read_tokens)} / {format_tokens(ev.output_tokens)}
                  <% else %>
                    —
                  <% end %>
                </td>
                <td class="num">
                  {if ev.kind == "assistant", do: format_cost(ev.cost_usd), else: "—"}
                </td>
                <td class="num">
                  {if ev.kind in ["assistant", "tool_result"], do: format_ms(Map.get(ev, :duration_ms)), else: "—"}
                </td>
                <td class="num">
                  {if ev.kind == "assistant", do: format_tps(ev.tps), else: "—"}
                </td>
                <td>
                  <%= case ev.kind do %>
                    <% "assistant" -> %>
                      <span class={["badge", outcome_badge_class(ev.outcome)]}>
                        {ev.finish_reason}
                      </span>
                    <% "tool_result" -> %>
                      <span class={["badge", if(ev.is_error, do: "badge-danger", else: "badge-active")]}>
                        {if ev.is_error, do: ev.diagnostic || "error", else: "ok"}
                      </span>
                    <% _ -> %>
                      <span class="muted">—</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </section>
    """
  end

  # Helpers

  defp query_opts_for(daemon_opts) do
    base = [
      data_dir: Keyword.get(daemon_opts, :data_dir),
      catalog_table: Keyword.get(daemon_opts, :catalog_table, :h_catalog)
    ]

    case Keyword.get(daemon_opts, :analytics_store) do
      nil -> base
      server -> Keyword.put(base, :server, server)
    end
  end

  defp store_server(daemon_opts), do: Keyword.get(daemon_opts, :analytics_store, Store)

  defp resolve_store_running?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp resolve_store_running?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp resolve_store_running?({:via, _, _} = via), do: GenServer.whereis(via) != nil
  defp resolve_store_running?(_), do: false

  defp build_charts(:overview, res, _detail) do
    %{
      daily_spend: res.daily_series |> Charts.daily_spend_and_tokens() |> Jason.encode!(),
      model_speed: res.model_breakdown |> Charts.model_speed_and_latency() |> Jason.encode!(),
      context_band:
        res.context_band_breakdown |> Charts.context_band_latency() |> Jason.encode!(),
      tool_volume: res.tool_breakdown |> Charts.tool_volume_and_latency() |> Jason.encode!()
    }
  end

  defp build_charts(:models, res, _detail) do
    %{model_speed: res.model_breakdown |> Charts.model_speed_and_latency() |> Jason.encode!()}
  end

  defp build_charts(:tools, res, _detail) do
    %{tool_volume: res.tool_breakdown |> Charts.tool_volume_and_latency() |> Jason.encode!()}
  end

  defp build_charts(:session_detail, _res, %{events: events}) do
    %{session_waterfall: events |> Charts.session_turn_waterfall() |> Jason.encode!()}
  end

  defp build_charts(_, _res, _detail), do: %{}

  defp merge_filter_params(current, params) do
    Enum.reduce(@filter_query_keys, current, fn {atom_key, str_key}, acc ->
      if Map.has_key?(params, str_key) do
        Map.put(acc, atom_key, params[str_key])
      else
        acc
      end
    end)
  end

  defp current_base_path(%{tab: :models}), do: "/ext/analytics/models"
  defp current_base_path(%{tab: :tools}), do: "/ext/analytics/tools"
  defp current_base_path(%{tab: :workspaces}), do: "/ext/analytics/workspaces"

  defp current_base_path(%{tab: :session_detail, session_detail: %{session: %{session_id: sid}}}),
    do: "/ext/analytics/sessions/#{sid}"

  defp current_base_path(_), do: "/ext/analytics"

  defp extra_params(%{tab: :models, focus_model: m}) when is_binary(m), do: %{"focus_model" => m}
  defp extra_params(%{tab: :tools, focus_tool: t}) when is_binary(t), do: %{"focus_tool" => t}
  defp extra_params(_), do: %{}

  defp path_with_filters(base_path, filters, extra \\ %{}) do
    defaults = Query.default_filters()

    params =
      []
      |> maybe_param("window", filters.window, defaults.window)
      |> maybe_param("source", filters.source, defaults.source)
      |> maybe_param("subsessions", filters.subsessions, defaults.subsessions)
      |> maybe_param("provider", filters.provider, nil)
      |> maybe_param("model", filters.model, nil)
      |> maybe_param("cwd", filters.cwd, nil)
      |> maybe_param("cache", filters.cache, defaults.cache)
      |> maybe_param("sort_by", filters.sort_by, defaults.sort_by)
      |> maybe_param("sort_dir", filters.sort_dir, defaults.sort_dir)

    extra_pairs =
      extra
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    all_pairs = params ++ extra_pairs

    case all_pairs do
      [] -> base_path
      pairs -> base_path <> "?" <> URI.encode_query(pairs)
    end
  end

  defp maybe_param(acc, _key, val, default) when val == default or is_nil(val), do: acc
  defp maybe_param(acc, key, val, _default), do: [{key, val} | acc]

  defp non_default_filters?(filters), do: filters != Query.default_filters()

  defp non_empty(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty(_), do: nil

  defp indexed_session_count(%{status: :ready, total: total}, _res) when is_integer(total),
    do: total

  defp indexed_session_count(_, %{kpis: %{session_count: count}}), do: count
  defp indexed_session_count(_, _), do: 0

  defp window_label("all"), do: "All"
  defp window_label(w), do: w

  defp short_id(sid) when is_binary(sid), do: String.slice(sid, 0, 12)
  defp short_id(_), do: ""

  defp source_label("native_active"), do: "active"
  defp source_label("native_archived"), do: "archived"
  defp source_label("imported_archive"), do: "imported"
  defp source_label(other), do: other || "unknown"

  defp source_badge_class("native_active"), do: "badge-active"
  defp source_badge_class("native_archived"), do: "badge-warn"
  defp source_badge_class("imported_archive"), do: "badge-attention"
  defp source_badge_class(_), do: ""

  defp event_badge_class("assistant", %{outcome: outcome}), do: outcome_badge_class(outcome)
  defp event_badge_class("tool_result", %{is_error: true}), do: "badge-danger"
  defp event_badge_class("tool_result", _), do: "badge-active"
  defp event_badge_class(_, _), do: ""

  defp outcome_badge_class("completed"), do: "badge-active"
  defp outcome_badge_class("aborted"), do: "badge-warn"
  defp outcome_badge_class("error"), do: "badge-danger"
  defp outcome_badge_class(_), do: ""

  defp sort_arrow("asc"), do: " ↑"
  defp sort_arrow(_), do: " ↓"

  defp session_cache_pct(%{prompt_tokens: pt, cache_read_tokens: cr}) when pt > 0,
    do: Float.round(cr * 100.0 / pt, 1)

  defp session_cache_pct(_), do: 0.0

  defp workspace_cache_pct(%{prompt_tokens: pt, cached_tokens: cr}) when pt > 0,
    do: Float.round(cr * 100.0 / pt, 1)

  defp workspace_cache_pct(_), do: 0.0

  defp format_cost(val) when is_number(val) do
    :io_lib.format("$~.2f", [val * 1.0]) |> IO.iodata_to_binary()
  end

  defp format_cost(_), do: "$0.00"

  defp format_pct(val) when is_number(val), do: "#{Float.round(val * 1.0, 1)}%"
  defp format_pct(_), do: "0.0%"

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000.0, 2)}M"

  defp format_tokens(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000.0, 1)}k"

  defp format_tokens(n) when is_integer(n), do: Integer.to_string(n)
  defp format_tokens(_), do: "0"

  defp format_seconds(ms) when is_number(ms) and ms > 0,
    do: "#{Float.round(ms / 1000.0, 2)}s"

  defp format_seconds(_), do: "—"

  defp format_ms(ms) when is_number(ms) and ms >= 1000,
    do: "#{Float.round(ms / 1000.0, 2)}s"

  defp format_ms(ms) when is_number(ms) and ms > 0, do: "#{round(ms)}ms"
  defp format_ms(_), do: "0ms"

  defp format_tps(tps) when is_number(tps) and tps > 0, do: "#{Float.round(tps * 1.0, 1)} tok/s"
  defp format_tps(_), do: "—"

  defp format_day(ts) when is_integer(ts) and ts > 0 do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> "—"
    end
  end

  defp format_day(_), do: "—"
end
