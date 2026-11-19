defmodule HWeb.Workbench do
  @moduledoc """
  Two resizable, independently scrolling panes. Slots render in the caller's
  LiveView: a pane can contain ordinary HEEx, a live_component, or live_render.
  Layout never owns subscriptions, routes or session state.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :sidebar_label, :string, required: true
  attr :main_label, :string, required: true
  slot :sidebar, required: true
  slot :main, required: true

  def split(assigns) do
    ~H"""
    <div id={@id} class={["workbench", @class]}>
      <aside id={@id <> "-sidebar"} class="workbench-sidebar" aria-label={@sidebar_label}>
        {render_slot(@sidebar)}
      </aside>
      <div
        id={@id <> "-splitter"}
        class="pane-splitter"
        role="separator"
        aria-label={"Resize " <> @sidebar_label}
        aria-orientation="vertical"
        aria-controls={@id <> "-sidebar"}
        aria-valuemin="200"
        aria-valuemax="440"
        aria-valuenow="272"
        tabindex="0"
        phx-hook="PaneSplitter"
      >
      </div>
      <main id={@id <> "-main"} class="workbench-main" aria-label={@main_label}>
        {render_slot(@main)}
      </main>
    </div>
    """
  end
end
