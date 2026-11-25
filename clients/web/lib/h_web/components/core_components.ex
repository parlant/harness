defmodule HWeb.CoreComponents do
  @moduledoc """
  Minimal shared UI components for `HWeb`.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :tags, :list, required: true
  attr :error, :string, default: nil

  def tag_input(assigns) do
    ~H"""
    <form id={@id <> "-form"} class="tag-editor" phx-submit="add_session_tags" phx-hook="SessionTags">
      <label class="field-label" for={@id <> "-input"}>Session tags</label>
      <div class="tag-editor-field">
        <span :for={tag <- @tags} class="tag-chip">
          <span>{tag}</span>
          <button
            type="button"
            phx-click="remove_session_tag"
            phx-value-tag={tag}
            aria-label={"Remove tag #{tag}"}
            title={"Remove #{tag}"}
          >×</button>
        </span>
        <input
          id={@id <> "-input"}
          name="tags"
          class="input"
          placeholder="Add a tag…"
          aria-describedby={@id <> "-hint"}
          autocomplete="off"
        />
        <button type="submit" class="bar-button tag-add" aria-label="Add tag" title="Add tag">+</button>
      </div>
      <small id={@id <> "-hint"} class="muted">Enter or comma adds a tag. Changes save automatically.</small>
      <small :if={@error} role="alert" class="tag-error">{@error}</small>
    </form>
    """
  end

  attr(:id, :string, required: true)

  def completion_layer(assigns) do
    ~H"""
    <div id={@id} class="completion-layer" phx-update="ignore"></div>
    """
  end

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
