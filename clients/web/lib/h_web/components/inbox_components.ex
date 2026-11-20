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
  attr :show_subsessions, :boolean, default: false
  attr :toggle_subsessions_event, :string, default: nil
  attr :compact, :boolean, default: false

  def filter_bar(assigns) do
    subsessions_count = Map.get(assigns.counts, :subsessions, 0)
    assigns = assign(assigns, :subsessions_count, subsessions_count)

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

        <button
          :if={@toggle_subsessions_event && (@subsessions_count > 0 or @show_subsessions)}
          id={"#{@id}-subsessions"}
          type="button"
          aria-pressed={to_string(@show_subsessions)}
          class={["inbox-pill inbox-subsessions-pill", if(@show_subsessions, do: "is-active")]}
          phx-click={@toggle_subsessions_event}
        >
          <span>Subsessions</span>
          <span class="inbox-pill-count mono">{@subsessions_count}</span>
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
            <.session_node
              session={s}
              current_session_id={@current_session_id}
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
  attr :current_session_id, :string, default: nil
  attr :from_inbox, :boolean, default: true
  attr :compact, :boolean, default: false
  attr :parent_cwd, :string, default: nil

  defp session_node(assigns) do
    children = Map.get(assigns.session, :children, [])
    assigns = assign(assigns, :children, children)

    ~H"""
    <.session_row
      session={@session}
      current?={@current_session_id == @session.session_id}
      from_inbox={@from_inbox}
      compact={@compact}
      parent_cwd={@parent_cwd}
    />
    <ul :if={@children != []} class="inbox-subsession-list">
      <li :for={child <- @children} class="inbox-subsession-item">
        <.session_node
          session={child}
          current_session_id={@current_session_id}
          from_inbox={@from_inbox}
          compact={@compact}
          parent_cwd={@session.cwd}
        />
      </li>
    </ul>
    """
  end

  attr :session, :map, required: true
  attr :current?, :boolean, default: false
  attr :from_inbox, :boolean, default: true
  attr :compact, :boolean, default: false
  attr :parent_cwd, :string, default: nil

  def session_row(assigns) do
    session = assigns.session
    detail = CatalogState.status_detail(session)
    subsession? = CatalogState.subsession?(session)
    needs_attention? = CatalogState.needs_attention?(session)
    processing? = CatalogState.processing?(session)
    error? = session.attention in ["error", "quarantined"]
    parent = Map.get(session, :parent)
    at_entry_id = if is_map(parent), do: parent.at_entry_id, else: nil

    worktree_label =
      if subsession? and is_binary(assigns.parent_cwd) and assigns.parent_cwd != session.cwd do
        CatalogState.format_workspace_label(session.env_id, session.cwd, System.user_home())
      else
        nil
      end

    href =
      if assigns.from_inbox do
        ~p"/sessions/#{session.session_id}?from=inbox"
      else
        ~p"/sessions/#{session.session_id}"
      end

    assigns =
      assigns
      |> assign(:detail, detail)
      |> assign(:subsession?, subsession?)
      |> assign(:needs_attention?, needs_attention?)
      |> assign(:processing?, processing?)
      |> assign(:error?, error?)
      |> assign(:at_entry_id, at_entry_id)
      |> assign(:worktree_label, worktree_label)
      |> assign(:href, href)

    ~H"""
    <.link
      navigate={@href}
      data-inbox-row="true"
      data-session-id={@session.session_id}
      data-attention={@session.attention}
      data-needs-attention={to_string(@needs_attention?)}
      data-subsession={to_string(@subsession?)}
      class={[
        "inbox-row",
        if(@compact, do: "is-compact"),
        if(@subsession?, do: "is-subsession"),
        if(@current?, do: "is-current"),
        if(@error?, do: "is-error"),
        if(@needs_attention?, do: "needs-attention"),
        if(@processing?, do: "is-processing")
      ]}
    >
      <.status_indicator attention={@session.attention} subsession?={@subsession?} />

      <div class="inbox-row-main">
        <div class="inbox-row-top">
          <span :if={@subsession?} class="inbox-lineage-prefix mono muted" aria-hidden="true">↳</span>
          <span class="inbox-row-name">
            {@session.title || @session.session_id}
          </span>
          <span :if={@session.title} class="inbox-row-sid mono muted">
            {@session.session_id}
          </span>
          <span
            :if={@subsession? && @at_entry_id}
            class="inbox-step-badge mono muted"
            title={"Spawned at parent entry ##{@at_entry_id}"}
          >
            @{@at_entry_id}
          </span>
          <span
            :if={@worktree_label}
            class="inbox-worktree-badge mono muted"
            title={@session.cwd}
          >
            {@worktree_label}
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

        <span
          :if={@session.attention == "idle"}
          class={["inbox-ready-tag mono", if(@subsession?, do: "is-subsession-idle")]}
        >
          idle
        </span>
      </div>
    </.link>
    """
  end

  attr :attention, :string, required: true
  attr :subsession?, :boolean, default: false

  def status_indicator(%{attention: att} = assigns) when att in ["error", "quarantined"] do
    ~H"""
    <span
      class="inbox-status inbox-status-error mono"
      title={if @attention == "quarantined", do: "Quarantined", else: "Error — needs attention"}
      aria-label={@attention}
    >!</span>
    """
  end

  def status_indicator(%{attention: "idle", subsession?: true} = assigns) do
    ~H"""
    <span
      class="inbox-status inbox-status-subsession-idle"
      title="Subsession idle"
      aria-label="idle"
    >○</span>
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
