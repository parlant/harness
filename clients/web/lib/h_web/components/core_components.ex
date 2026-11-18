defmodule HWeb.CoreComponents do
  @moduledoc """
  Minimal shared UI components for `HWeb`.
  """
  use Phoenix.Component

  attr(:flash, :map, required: true)
  attr(:kind, :atom, values: [:info, :error], required: true)

  def flash_banner(assigns) do
    msg = Phoenix.Flash.get(assigns.flash, assigns.kind)
    assigns = assign(assigns, :msg, msg)

    ~H"""
    <div
      :if={@msg}
      role="alert"
      class={["flash-banner", if(@kind == :error, do: "flash-error", else: "flash-info")]}
    >
      <span>{@msg}</span>
    </div>
    """
  end

  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <div class="flash-group" aria-live="polite">
      <.flash_banner kind={:info} flash={@flash} />
      <.flash_banner kind={:error} flash={@flash} />
    </div>
    """
  end
end
