defmodule Extensions.EditorHost.Harness do
  @moduledoc """
  Coding harness profile (`id: "editor_coding"`) adding `editor_buffer_summary`
  to the standard `H.Harness.Coding` tools.
  """

  @behaviour H.Harness

  alias Extensions.EditorHost.BufferSummaryTool
  alias H.Harness.Coding

  @impl H.Harness
  def id, do: "editor_coding"

  @impl H.Harness
  def descriptor do
    %{
      id: "editor_coding",
      name: "Editor Coding",
      description:
        "Coding harness with filesystem, shell, history search, and live editor_buffer_summary tools."
    }
  end

  @impl H.Harness
  def tools(opts \\ []) do
    case Keyword.fetch(opts, :tools) do
      {:ok, explicit} ->
        explicit

      :error ->
        Coding.tools(opts) ++ [BufferSummaryTool]
    end
  end

  @impl H.Harness
  def bootstrap_agent(env, overrides \\ %{}, opts \\ [])
      when is_map(overrides) and is_list(opts) do
    with {:ok, merged} <- Coding.bootstrap_agent(env, overrides, opts) do
      has_tools? =
        not is_nil(Map.get(overrides, "tools")) or not is_nil(Map.get(overrides, :tools))

      if has_tools? do
        {:ok, merged}
      else
        {:ok, Map.put(merged, "tools", Enum.map(tools(opts), & &1.name()))}
      end
    end
  end
end
