defmodule HWeb.Extension.Page do
  @moduledoc """
  Behaviour for owner-authenticated custom LiveView pages contributed by `:web`
  extensions at `/ext/:slug` and `/ext/:slug/*subpath`.

  `render/1` is required. `mount/3`, `handle_params/3`, `handle_event/3`, and
  `handle_info/2` are optional and follow standard `Phoenix.LiveView` return
  shapes when exported.
  """

  @callback mount(params :: map(), session :: map(), socket :: Phoenix.LiveView.Socket.t()) ::
              {:ok, Phoenix.LiveView.Socket.t()}
  @callback handle_params(
              params :: map(),
              uri :: String.t(),
              socket :: Phoenix.LiveView.Socket.t()
            ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  @callback handle_event(
              event :: String.t(),
              params :: map(),
              socket :: Phoenix.LiveView.Socket.t()
            ) ::
              {:noreply, Phoenix.LiveView.Socket.t()}
              | {:reply, map(), Phoenix.LiveView.Socket.t()}
  @callback handle_info(msg :: term(), socket :: Phoenix.LiveView.Socket.t()) ::
              {:noreply, Phoenix.LiveView.Socket.t()}
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @optional_callbacks mount: 3, handle_params: 3, handle_event: 3, handle_info: 2
end

defmodule HWeb.Extension do
  @moduledoc """
  Shared UI helpers for `HWeb` extension pages and components.
  """
  use HWeb, :html

  alias HWeb.Layouts

  attr :title, :string, required: true
  attr :section, :any, required: true
  attr :inbox_path, :string, default: nil
  slot :leading
  slot :before_title
  slot :after_title
  slot :actions
  slot :menu_actions
  slot :inner_block, required: true

  @doc """
  Renders a standard `hiweb` chrome shell around an extension page body.
  """
  def shell(assigns) do
    ~H"""
    <div class="workbench-shell">
      <Layouts.app_bar title={@title} section={@section} inbox_path={@inbox_path}>
        <:leading :if={@leading != []}>{render_slot(@leading)}</:leading>
        <:before_title :if={@before_title != []}>{render_slot(@before_title)}</:before_title>
        <:after_title :if={@after_title != []}>{render_slot(@after_title)}</:after_title>
        <:actions :if={@actions != []}>{render_slot(@actions)}</:actions>
        <:menu_actions :if={@menu_actions != []}>{render_slot(@menu_actions)}</:menu_actions>
      </Layouts.app_bar>
      <main class="ext-page-main">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end
end
