defmodule HWeb.InboxComponents do
  @moduledoc """
  Shared stateless function components for rendering the directory-rooted
  multi-session inbox tree, status indicators, and attention filter controls
  across `InboxLive`, `WorkspaceLive`, and `SessionLive`.
  """

  use Phoenix.Component
  use HWeb, :verified_routes

  alias HWeb.CatalogState

  attr :id, :string, default: "inbox-filter-bar"
  attr :counts, :map, required: true
  attr :filter_mode, :string, default: "all"
  attr :search, :string, default: ""
  attr :filter_event, :string, default: "set_filter"
  attr :search_event, :string, default: "search"
  attr :show_search, :boolean, default: true
  attr :compact, :boolean, default: false

  def filter_bar(assigns) do
    ~H"""
    <div id={@id} class={["inbox-filter-bar", if(@compact, do: "is-compact")]}>
      <div class="inbox-filter-pills" role="tablist" aria-label="Session filter">
        <button
          id={"#{@id}-attention"}
          type="button"
          role="tab"
          aria-selected={to_string(@filter_mode == "attention")}
          class={[
            "inbox-pill",
            if(@filter_mode == "attention", do: "is-active"),
            if(@counts.attention > 0, do: "has-attention")
          ]}
          phx-click={@filter_event}
          phx-value-mode="attention"
        >
          <span>Needs Attention</span>
          <span class={["inbox-pill-count mono", if(@counts.error > 0, do: "is-error")]}>
            {@counts.attention}
          </span>
        </button>

        <button
          id={"#{@id}-all"}
          type="button"
          role="tab"
          aria-selected={to_string(@filter_mode != "attention")}
          class={["inbox-pill", if(@filter_mode != "attention", do: "is-active")]}
          phx-click={@filter_event}
          phx-value-mode="all"
        >
          <span>All Sessions</span>
          <span class="inbox-pill-count mono">{@counts.all}</span>
        </button>

        <span :if={@counts.processing > 0} class="inbox-running-pill mono">
          <span class="inbox-spinner inbox-spinner-xs" aria-hidden="true"></span>
          <span>Running {@counts.processing}</span>
        </span>
      </div>

      <form
        :if={@show_search}
        id={"#{@id}-search-form"}
        phx-change={@search_event}
        class="inbox-search-form"
      >
        <input
          id={"#{@id}-search-input"}
          type="search"
          name="q"
          value={@search}
          placeholder="Filter sessions or folders…"
          aria-label="Filter sessions or folders"
          class="input inbox-search-input"
          autocomplete="off"
        />
      </form>
    </div>
    """
  end

  attr :id, :string, default: "inbox-tree"
  attr :groups, :list, required: true
  attr :current_session_id, :string, default: nil
  attr :from_inbox, :boolean, default: true
  attr :compact, :boolean, default: false
  attr :new_session_event, :string, default: nil
  attr :empty_message, :string, default: "No sessions match the current filter."

  def workspace_tree(assigns) do
    ~H"""
    <div id={@id} class={["inbox-tree", if(@compact, do: "is-compact")]}>
      <p :if={@groups == []} class="muted inbox-empty">
        {@empty_message}
      </p>

      <section
        :for={group <- @groups}
        class={[
          "inbox-group",
          if(group.counts.error > 0, do: "has-error"),
          if(group.counts.attention == 0 and group.counts.processing > 0, do: "is-processing-only")
        ]}
        data-workspace-root={group.cwd}
        data-env-id={group.env_id}
      >
        <header class="inbox-group-header">
          <div class="inbox-group-title">
            <span class="inbox-group-path mono" title={group.cwd}>{group.label}</span>
            <span class="inbox-group-meta mono">
              <span :if={group.counts.error > 0} class="inbox-meta-error">
                {group.counts.error}!
              </span>
              <span :if={group.counts.idle > 0} class="inbox-meta-idle">
                {group.counts.idle} ready
              </span>
              <span :if={group.counts.processing > 0} class="inbox-meta-running">
                {group.counts.processing} running
              </span>
            </span>
          </div>

          <button
            :if={@new_session_event}
            type="button"
            class="btn btn-sm btn-ghost inbox-new-btn"
            phx-click={@new_session_event}
            phx-value-cwd={group.cwd}
            phx-value-env_id={group.env_id}
            title={"Start new session in #{group.label}"}
          >
            + New
          </button>
        </header>

        <ul class="inbox-session-list">
          <li :for={s <- group.sessions} class="inbox-session-item">
            <.session_row
              session={s}
              current?={@current_session_id == s.session_id}
              from_inbox={@from_inbox}
              compact={@compact}
            />
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :current?, :boolean, default: false
  attr :from_inbox, :boolean, default: true
  attr :compact, :boolean, default: false

  def session_row(assigns) do
    detail = CatalogState.status_detail(assigns.session)
    needs_attention? = CatalogState.needs_attention?(assigns.session)
    processing? = CatalogState.processing?(assigns.session)
    error? = assigns.session.attention in ["error", "quarantined"]

    href =
      if assigns.from_inbox do
        ~p"/sessions/#{assigns.session.session_id}?from=inbox"
      else
        ~p"/sessions/#{assigns.session.session_id}"
      end

    assigns =
      assigns
      |> assign(:detail, detail)
      |> assign(:needs_attention?, needs_attention?)
      |> assign(:processing?, processing?)
      |> assign(:error?, error?)
      |> assign(:href, href)

    ~H"""
    <.link
      navigate={@href}
      data-inbox-row="true"
      data-session-id={@session.session_id}
      data-attention={@session.attention}
      data-needs-attention={to_string(@needs_attention?)}
      class={[
        "inbox-row",
        if(@compact, do: "is-compact"),
        if(@current?, do: "is-current"),
        if(@error?, do: "is-error"),
        if(@needs_attention?, do: "needs-attention"),
        if(@processing?, do: "is-processing")
      ]}
    >
      <.status_indicator attention={@session.attention} />

      <div class="inbox-row-main">
        <div class="inbox-row-top">
          <span class="inbox-row-name">
            {@session.title || @session.session_id}
          </span>
          <span :if={@session.title} class="inbox-row-sid mono muted">
            {@session.session_id}
          </span>
        </div>
      </div>

      <div class="inbox-row-tail">
        <span :if={@session.queued_count > 0} class="inbox-queued-badge mono" title="Queued messages">
          +{@session.queued_count}
        </span>

        <span
          :if={@detail}
          class={[
            "inbox-detail-badge mono",
            if(@error?, do: "is-error"),
            if(@processing?, do: "is-processing")
          ]}
        >
          {@detail}
        </span>

        <span :if={@session.attention == "idle"} class="inbox-ready-tag mono">
          idle
        </span>
      </div>
    </.link>
    """
  end

  attr :attention, :string, required: true

  def status_indicator(%{attention: att} = assigns) when att in ["error", "quarantined"] do
    ~H"""
    <span
      class="inbox-status inbox-status-error mono"
      title={if @attention == "quarantined", do: "Quarantined", else: "Error — needs attention"}
      aria-label={@attention}
    >!</span>
    """
  end

  def status_indicator(%{attention: "idle"} = assigns) do
    ~H"""
    <span
      class="inbox-status inbox-status-idle"
      title="Idle — ready for direction"
      aria-label="idle"
    >●</span>
    """
  end

  def status_indicator(%{attention: "running"} = assigns) do
    ~H"""
    <span class="inbox-status inbox-status-running" title="Running" aria-label="running">
      <span class="inbox-spinner" aria-hidden="true"></span>
    </span>
    """
  end

  def status_indicator(%{attention: "sleeping"} = assigns) do
    ~H"""
    <span class="inbox-status inbox-status-sleeping" title="Retrying / sleeping" aria-label="sleeping">◷</span>
    """
  end

  def status_indicator(assigns) do
    ~H"""
    <span class="inbox-status inbox-status-idle" aria-label={@attention}>○</span>
    """
  end
end
