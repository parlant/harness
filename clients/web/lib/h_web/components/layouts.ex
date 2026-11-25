defmodule HWeb.Layouts do
  @moduledoc """
  Application and root HTML layouts for `HWeb`.
  """
  use HWeb, :html

  embed_templates("layouts/*")

  attr :title, :string, required: true
  attr :section, :atom, required: true
  attr :inbox_path, :string, default: nil
  slot :leading
  slot :before_title
  slot :after_title
  slot :actions
  slot :menu_actions

  def app_bar(assigns) do
    ~H"""
    <header class={["app-bar", @section == :session && "app-bar-centered"]}>
      <button
        id="app-menu-button"
        type="button"
        class="bar-button app-menu-button"
        popovertarget="app-menu"
        aria-label="Main menu"
        title="Main menu"
      >
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h16M4 12h16M4 18h16" /></svg>
      </button>
      {render_slot(@leading)}
      <div class="app-bar-heading">
        {render_slot(@before_title)}
        <h1 class="app-bar-title" title={@title}>{@title}</h1>
        {render_slot(@after_title)}
      </div>
      <div :if={@actions != []} class="app-bar-actions">{render_slot(@actions)}</div>

      <nav id="app-menu" class="app-menu" popover aria-label="Main navigation">
        <.link navigate={@inbox_path || ~p"/inbox"} aria-current={if @section == :inbox, do: "page"}>Inbox</.link>
        <.link navigate={~p"/workspaces"} aria-current={if @section == :workspaces, do: "page"}>Workspaces</.link>
        <.link navigate={~p"/settings/providers"} aria-current={if @section == :providers, do: "page"}>Providers</.link>
        <.link navigate={~p"/settings/accounts"} aria-current={if @section == :accounts, do: "page"}>Keys &amp; accounts</.link>
        <div :if={@menu_actions != []} class="app-menu-group">{render_slot(@menu_actions)}</div>
        <div class="app-menu-group">
          <button
            :if={Application.get_env(:harness_web, :inspector_workspace)}
            type="button"
            data-open-inspector
          >Inspect UI</button>
          <form action={~p"/logout"} method="post">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit">Sign out</button>
          </form>
        </div>
      </nav>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :side, :boolean, default: false
  attr :wide, :boolean, default: false
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <dialog
      id={@id}
      class={["app-panel", @side && "app-panel-side", @wide && "app-panel-wide"]}
      aria-labelledby={@id <> "-title"}
      phx-mounted={JS.ignore_attributes("open")}
    >
      <div class="app-panel-content">
        <header class="app-panel-header">
          <h2 id={@id <> "-title"} tabindex="-1" autofocus>{@title}</h2>
          <button type="button" class="bar-button" data-close-panel aria-label="Close" title="Close">×</button>
        </header>
        {render_slot(@inner_block)}
      </div>
    </dialog>
    """
  end
end
