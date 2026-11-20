defmodule H.Storage.Memory do
  @moduledoc """
  In-memory reference backend implementing `H.Storage`.
  """

  @behaviour H.Storage

  alias H.Storage.Engine

  defstruct seq: 0,
            next_id: 2,
            session_meta: %{},
            conversations: %{1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}},
            entries: %{},
            submissions: %{},
            tasks: %{},
            doc_histories: %{}

  @impl true
  def open(opts \\ []) when is_list(opts) do
    session_meta =
      opts
      |> Keyword.take([:session_id, :cwd])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    {:ok, %__MODULE__{session_meta: session_meta}}
  end

  @impl true
  def close(%__MODULE__{}), do: :ok

  @impl true
  def mint_id(%__MODULE__{next_id: id} = state) do
    {:ok, id, %{state | next_id: id + 1}}
  end

  @impl true
  def commit(%__MODULE__{} = state, []), do: {:ok, %{stored: 0, seqs: [], refused: nil}, state}

  def commit(%__MODULE__{} = state, batches) when is_list(batches) do
    {next_state, accepted, refused} = Engine.run_batches(batches, state)
    seqs = Enum.map(accepted, fn {seq, _writes} -> seq end)
    {:ok, %{stored: length(seqs), seqs: seqs, refused: refused}, next_state}
  end

  @impl true
  def read_bootstrap(%__MODULE__{} = state) do
    {:ok, Engine.read_bootstrap(state), state}
  end

  @impl true
  def get_submission(%__MODULE__{} = state, request_id) when is_binary(request_id) do
    {:ok, Map.get(state.submissions, request_id), state}
  end

  @impl true
  def get_entry(%__MODULE__{} = state, entry_id) when is_integer(entry_id) and entry_id > 0 do
    {:ok, Map.get(state.entries, entry_id), state}
  end

  @impl true
  def get_doc(%__MODULE__{} = state, address, opts \\ []) do
    {:ok, Engine.get_doc(state, address, opts), state}
  end

  @impl true
  def scan_entries(%__MODULE__{} = state, query) when is_map(query) do
    with {:ok, page} <- Engine.scan_entries(state, query) do
      {:ok, page, state}
    end
  end
end
