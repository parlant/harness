defmodule H.Storage do
  @moduledoc """
  Pluggable persistence boundary for a single `H` session.

  Every backend (`H.Storage.Memory`, `H.Storage.File`, and later `H.Storage.SQLite`)
  implements atomic multi-batch commits with per-batch `seq` revisions and
  prefix-refusal semantics: if batch `k` fails a domain check, batches `0..(k - 1)`
  remain durably stored and `refused` reports `{k, reason}`; any storage I/O error
  returns `{:error, reason}` without advancing committed state.
  """

  @type seq :: non_neg_integer()
  @type id :: pos_integer()

  @type doc_address ::
          {:session, kind :: String.t()}
          | {:conversation, conversation_id :: id(), kind :: String.t()}
          | {:task, task_id :: id(), kind :: String.t()}

  @type check ::
          {:unique_request_id, request_id :: String.t(), fingerprint :: String.t()}
          | {:conversation_exists, conversation_id :: id()}

  @type write ::
          {:check, check()}
          | {:put_session_meta, map()}
          | {:put_conversation, map()}
          | {:append_entry, map()}
          | {:put_submission, map()}
          | {:put_task, map()}
          | {:put_doc, doc_address(), map()}
          | {:retire_doc, doc_address()}

  @type commit_result :: %{
          stored: non_neg_integer(),
          seqs: [seq()],
          refused: nil | {non_neg_integer(), term()}
        }

  @type entry_query :: %{
          required(:conversation_id) => id(),
          optional(:cutoff) => nil | id(),
          optional(:order) => :asc | :desc,
          optional(:cursor) => nil | id(),
          optional(:limit) => pos_integer()
        }

  @type t :: {module(), state :: term()}

  @callback open(keyword()) :: {:ok, state :: term()} | {:error, term()}
  @callback close(state :: term()) :: :ok
  @callback mint_id(state :: term()) :: {:ok, id(), state :: term()} | {:error, term()}
  @callback commit(state :: term(), batches :: [[write()]]) ::
              {:ok, commit_result(), state :: term()} | {:error, term()}
  @callback read_bootstrap(state :: term()) :: {:ok, map(), state :: term()} | {:error, term()}
  @callback get_submission(state :: term(), request_id :: String.t()) ::
              {:ok, nil | map(), state :: term()} | {:error, term()}
  @callback get_entry(state :: term(), entry_id :: id()) ::
              {:ok, nil | map(), state :: term()} | {:error, term()}
  @callback get_doc(state :: term(), doc_address(), opts :: keyword()) ::
              {:ok, nil | map(), state :: term()} | {:error, term()}
  @callback scan_entries(state :: term(), entry_query()) ::
              {:ok, %{items: [map()], next_cursor: nil | id()}, state :: term()}
              | {:error, term()}

  @spec open(module(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(mod, opts \\ []) when is_atom(mod) and is_list(opts) do
    with {:ok, state} <- mod.open(opts), do: {:ok, {mod, state}}
  end

  @spec close(t()) :: :ok
  def close({mod, state}), do: mod.close(state)

  @spec mint_id(t()) :: {:ok, id(), t()} | {:error, term()}
  def mint_id({mod, state}) do
    with {:ok, id, next_state} <- mod.mint_id(state), do: {:ok, id, {mod, next_state}}
  end

  @spec commit(t(), [[write()]]) :: {:ok, commit_result(), t()} | {:error, term()}
  def commit({mod, state}, batches) when is_list(batches) do
    with {:ok, result, next_state} <- mod.commit(state, batches),
         do: {:ok, result, {mod, next_state}}
  end

  @spec read_bootstrap(t()) :: {:ok, map(), t()} | {:error, term()}
  def read_bootstrap({mod, state}) do
    with {:ok, data, next_state} <- mod.read_bootstrap(state), do: {:ok, data, {mod, next_state}}
  end

  @spec get_submission(t(), String.t()) :: {:ok, nil | map(), t()} | {:error, term()}
  def get_submission({mod, state}, request_id) when is_binary(request_id) do
    with {:ok, sub, next_state} <- mod.get_submission(state, request_id),
         do: {:ok, sub, {mod, next_state}}
  end

  @spec get_entry(t(), id()) :: {:ok, nil | map(), t()} | {:error, term()}
  def get_entry({mod, state}, entry_id) when is_integer(entry_id) and entry_id > 0 do
    with {:ok, entry, next_state} <- mod.get_entry(state, entry_id),
         do: {:ok, entry, {mod, next_state}}
  end

  @spec get_doc(t(), doc_address(), keyword()) :: {:ok, nil | map(), t()} | {:error, term()}
  def get_doc({mod, state}, address, opts \\ []) do
    with {:ok, doc, next_state} <- mod.get_doc(state, address, opts),
         do: {:ok, doc, {mod, next_state}}
  end

  @spec scan_entries(t(), entry_query()) ::
          {:ok, %{items: [map()], next_cursor: nil | id()}, t()} | {:error, term()}
  def scan_entries({mod, state}, query) when is_map(query) do
    with {:ok, page, next_state} <- mod.scan_entries(state, query),
         do: {:ok, page, {mod, next_state}}
  end
end
