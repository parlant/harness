defmodule HWeb.ExtensionLive do
  @moduledoc """
  Owner-authenticated LiveView host for `:web` extension pages registered at
  `/ext/:slug` and `/ext/:slug/*subpath`.

  Delegates lifecycle callbacks (`mount/3`, `handle_params/3`, `handle_event/3`,
  `handle_info/2`) and `render/1` to the registered `HWeb.Extension.Page`
  module, and renders a clean `"Extension not found"` state when no matching
  slug is active.
  """
  use HWeb, :live_view

  alias HWeb.{Extensions, Layouts}

  @impl true
  def mount(%{"slug" => slug} = params, session, socket) do
    case Extensions.find_page(slug) do
      {:ok, page} ->
        socket =
          assign(socket,
            __ext_page__: page,
            ext_slug: page.slug,
            ext_section: {:ext, page.slug},
            ext_subpath: Map.get(params, "subpath", [])
          )

        delegate_mount(page.module, params, session, socket)

      :error ->
        {:ok, assign(socket, __ext_page__: nil, ext_slug: slug)}
    end
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, __ext_page__: nil, ext_slug: nil)}
  end

  @impl true
  def handle_params(params, uri, %{assigns: %{__ext_page__: %{module: mod} = page}} = socket) do
    socket =
      assign(socket,
        ext_slug: page.slug,
        ext_section: {:ext, page.slug},
        ext_subpath: Map.get(params, "subpath", [])
      )

    if Code.ensure_loaded?(mod) and function_exported?(mod, :handle_params, 3) do
      mod.handle_params(params, uri, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event(event, params, %{assigns: %{__ext_page__: %{module: mod}}} = socket) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :handle_event, 3) do
      mod.handle_event(event, params, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(msg, %{assigns: %{__ext_page__: %{module: mod}}} = socket) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :handle_info, 2) do
      mod.handle_info(msg, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(%{__ext_page__: %{module: mod}} = assigns) do
    mod.render(assigns)
  end

  def render(assigns) do
    ~H"""
    <div class="workbench-shell">
      <Layouts.app_bar title="Not found" section={:extension} />
      <main class="ext-page-main">
        <section class="empty-state">
          <h2>Extension not found</h2>
          <p class="muted">No active web extension page is registered at this route.</p>
          <.link navigate={~p"/inbox"} class="btn">Back to Inbox</.link>
        </section>
      </main>
    </div>
    """
  end

  defp delegate_mount(mod, params, session, socket) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :mount, 3) do
      mod.mount(params, session, socket)
    else
      {:ok, socket}
    end
  end
end
