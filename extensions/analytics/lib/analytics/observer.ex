defmodule Extensions.Analytics.Observer do
  @moduledoc """
  Advisory post-commit `H.Extension.Observer` that marks updated sessions dirty
  in `Extensions.Analytics.Store` without blocking `H.Session.Server`.
  """

  @behaviour H.Extension.Observer

  alias Extensions.Analytics.Store

  @impl H.Extension.Observer
  def command_committed(%{session_id: sid}) when is_binary(sid) do
    Store.mark_dirty(sid)
  end

  def command_committed(_), do: :ok

  @impl H.Extension.Observer
  def work_settled(%{session_id: sid}) when is_binary(sid) do
    Store.mark_dirty(sid)
  end

  def work_settled(_), do: :ok
end
