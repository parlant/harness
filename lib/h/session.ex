defmodule H.Session do
  @moduledoc """
  Pure session history: a working directory, conversations, and immutable entries.

  Conversation 1 is the root. Forks reference visible entry cutoffs rather than
  copying transcripts. Conversation and entry IDs come from one strictly monotonic
  session-local sequence (`next_id`), which fork prefix traversal relies on
  (`entry.id <= cutoff`). All functions return new values; this module performs no
  persistence, process management, model requests, or tool execution.

  This is the trusted in-memory core. External data validation and durable
  command admission belong to the daemon boundary, not these constructors.
  """

  alias H.{Conversation, Entry}

  @enforce_keys [:id, :cwd]
  defstruct [:id, :cwd, conversations: %{1 => %Conversation{id: 1}}, entries: %{}, next_id: 2]

  @opaque t :: %__MODULE__{
            id: String.t(),
            cwd: String.t(),
            conversations: %{pos_integer() => Conversation.t()},
            entries: %{pos_integer() => Entry.t()},
            next_id: pos_integer()
          }

  @type error :: :conversation_not_found | :entry_not_visible

  @doc "Creates an empty root conversation. The working directory must be absolute."
  @spec new(String.t(), String.t()) :: t()
  def new(id, cwd) when is_binary(id) and is_binary(cwd) do
    if Path.type(cwd) != :absolute, do: raise(ArgumentError, "working directory must be absolute")

    %__MODULE__{id: id, cwd: Path.expand(cwd)}
  end

  @doc "Creates another independent conversation in the session."
  @spec create_conversation(t()) :: {:ok, t(), Conversation.t()}
  def create_conversation(%__MODULE__{} = session) do
    conversation = %Conversation{id: session.next_id}

    updated = %{
      session
      | conversations: Map.put(session.conversations, conversation.id, conversation),
        next_id: session.next_id + 1
    }

    {:ok, updated, conversation}
  end

  @doc "Appends a raw entry to a conversation's own segment."
  @spec append(t(), pos_integer(), String.t(), map()) :: {:ok, t(), Entry.t()} | {:error, error()}
  def append(%__MODULE__{} = session, conversation_id, kind, data)
      when is_binary(kind) and is_map(data) do
    case Map.fetch(session.conversations, conversation_id) do
      :error ->
        {:error, :conversation_not_found}

      {:ok, conversation} ->
        entry = %Entry{
          id: session.next_id,
          conversation_id: conversation_id,
          kind: kind,
          data: data
        }

        conversation = %{conversation | entry_ids: [entry.id | conversation.entry_ids]}

        updated = %{
          session
          | conversations: Map.put(session.conversations, conversation_id, conversation),
            entries: Map.put(session.entries, entry.id, entry),
            next_id: session.next_id + 1
        }

        {:ok, updated, entry}
    end
  end

  @doc "Forks through a concrete entry visible in the source conversation, inclusively."
  @spec fork(t(), pos_integer(), pos_integer()) ::
          {:ok, t(), Conversation.t()} | {:error, error()}
  def fork(%__MODULE__{} = session, conversation_id, at) do
    with {:ok, visible} <- entries(session, conversation_id),
         true <- Enum.any?(visible, &(&1.id == at)) do
      conversation = %Conversation{
        id: session.next_id,
        parent: %{conversation_id: conversation_id, at: at}
      }

      updated = %{
        session
        | conversations: Map.put(session.conversations, conversation.id, conversation),
          next_id: session.next_id + 1
      }

      {:ok, updated, conversation}
    else
      false -> {:error, :entry_not_visible}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns visible entries oldest first, respecting every ancestor's fork cutoff."
  @spec entries(t(), pos_integer()) :: {:ok, [Entry.t()]} | {:error, error()}
  def entries(%__MODULE__{} = session, conversation_id) do
    case Map.fetch(session.conversations, conversation_id) do
      :error -> {:error, :conversation_not_found}
      {:ok, conversation} -> {:ok, collect_entries(session, conversation, nil, [])}
    end
  end

  defp collect_entries(session, conversation, cutoff, tail) do
    entries =
      Enum.reduce(conversation.entry_ids, tail, fn id, acc ->
        if is_nil(cutoff) or id <= cutoff, do: [Map.fetch!(session.entries, id) | acc], else: acc
      end)

    case conversation.parent do
      nil ->
        entries

      %{conversation_id: parent_id, at: at} ->
        collect_entries(
          session,
          Map.fetch!(session.conversations, parent_id),
          if(is_nil(cutoff), do: at, else: min(at, cutoff)),
          entries
        )
    end
  end
end
