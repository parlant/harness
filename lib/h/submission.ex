defmodule H.Submission do
  @moduledoc """
  Idempotent command receipt keyed by `request_id` with deterministic payload
  fingerprinting and status transitions (`queued`, `placed`, `done`, `unanswered`, `withdrawn`).
  """

  @type status :: String.t()

  @doc """
  Computes a deterministic SHA-256 fingerprint over a command payload
  (excluding `request_id`).
  """
  @spec fingerprint(String.t(), pos_integer(), map()) :: String.t()
  def fingerprint(command, conversation_id, args)
      when is_binary(command) and is_integer(conversation_id) and is_map(args) do
    canonical =
      canonicalize(%{"command" => command, "conversation_id" => conversation_id, "args" => args})

    encoded = IO.iodata_to_binary(JSON.encode_to_iodata!(canonical))

    :crypto.hash(:sha256, encoded)
    |> Base.encode16(case: :lower)
  end

  @doc "Constructs a new submission map for durable storage."
  @spec new(map()) :: map()
  def new(attrs) when is_map(attrs) do
    now = Map.get(attrs, :created_at) || System.system_time(:millisecond)

    %{
      id: Map.fetch!(attrs, :id),
      request_id: Map.fetch!(attrs, :request_id),
      fingerprint: Map.fetch!(attrs, :fingerprint),
      kind: Map.fetch!(attrs, :kind),
      status: Map.get(attrs, :status, "queued"),
      conversation_id: Map.fetch!(attrs, :conversation_id),
      entry_id: Map.get(attrs, :entry_id),
      answer_entry_id: Map.get(attrs, :answer_entry_id),
      reason: Map.get(attrs, :reason),
      notify: Map.get(attrs, :notify),
      when_busy: Map.get(attrs, :when_busy),
      when_idle: Map.get(attrs, :when_idle),
      withdrawn: Map.get(attrs, :withdrawn),
      seq: Map.get(attrs, :seq),
      created_at: now,
      updated_at: Map.get(attrs, :updated_at, now)
    }
  end

  @doc "Normalizes a stored submission map (atom or string keys after file reload)."
  @spec from_storage(map()) :: map()
  def from_storage(raw) when is_map(raw) do
    %{
      id: field(raw, :id, "id") || field(raw, :entry_id, "entry_id"),
      request_id: field(raw, :request_id, "request_id"),
      fingerprint: field(raw, :fingerprint, "fingerprint"),
      kind: field(raw, :kind, "kind"),
      status: field(raw, :status, "status"),
      conversation_id: field(raw, :conversation_id, "conversation_id"),
      entry_id: field(raw, :entry_id, "entry_id"),
      answer_entry_id: field(raw, :answer_entry_id, "answer_entry_id"),
      reason: field(raw, :reason, "reason"),
      notify: field(raw, :notify, "notify"),
      when_busy: field(raw, :when_busy, "when_busy"),
      when_idle: field(raw, :when_idle, "when_idle"),
      withdrawn: field(raw, :withdrawn, "withdrawn"),
      seq: field(raw, :seq, "seq"),
      created_at: field(raw, :created_at, "created_at"),
      updated_at: field(raw, :updated_at, "updated_at")
    }
  end

  @doc "Transitions a submission to `placed` with its concrete entry ID."
  @spec mark_placed(map(), pos_integer(), integer()) :: map()
  def mark_placed(sub, entry_id, now \\ System.system_time(:millisecond)) do
    sub
    |> from_storage()
    |> Map.merge(%{status: "placed", entry_id: entry_id, updated_at: now})
  end

  @doc "Transitions a submission to `done` with its answer entry ID."
  @spec mark_done(map(), pos_integer(), integer()) :: map()
  def mark_done(sub, answer_entry_id, now \\ System.system_time(:millisecond)) do
    sub
    |> from_storage()
    |> Map.merge(%{status: "done", answer_entry_id: answer_entry_id, updated_at: now})
  end

  @doc "Transitions a submission to `unanswered` with a failure reason."
  @spec mark_unanswered(map(), String.t(), integer()) :: map()
  def mark_unanswered(sub, reason, now \\ System.system_time(:millisecond)) do
    sub
    |> from_storage()
    |> Map.merge(%{status: "unanswered", reason: reason, updated_at: now})
  end

  @doc "Transitions a queued submission to `withdrawn`."
  @spec mark_withdrawn(map(), integer()) :: map()
  def mark_withdrawn(sub, now \\ System.system_time(:millisecond)) do
    sub
    |> from_storage()
    |> Map.merge(%{status: "withdrawn", updated_at: now})
  end

  @doc "Formats a submission into a wire command receipt."
  @spec to_receipt(map(), non_neg_integer()) :: map()
  def to_receipt(sub, current_seq) when is_map(sub) do
    s = from_storage(sub)
    seq = s.seq || current_seq

    base = %{
      version: 1,
      request_id: s.request_id,
      seq: seq
    }

    case s.kind do
      "fork" ->
        Map.put(base, :conversation_id, to_string(s.conversation_id))

      "fork_and_submit" ->
        base
        |> Map.put(:conversation_id, to_string(s.conversation_id))
        |> Map.put(:submission_id, to_string(s.id))
        |> Map.put(:status, s.status)

      "configure" ->
        Map.put(base, :status, s.status)

      "abort" ->
        Map.put(base, :status, s.status)

      "withdraw" ->
        base
        |> Map.put(:status, s.status)
        |> Map.put(:withdrawn, s.withdrawn || [])

      _submit_kind ->
        base
        |> Map.put(:submission_id, to_string(s.id))
        |> Map.put(:status, s.status)
        |> maybe_put(:reason, s.reason)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp field(map, atom_key, str_key) do
    case Map.fetch(map, atom_key) do
      {:ok, val} -> val
      :error -> Map.get(map, str_key)
    end
  end

  defp canonicalize(val) when is_struct(val), do: val |> Map.from_struct() |> canonicalize()

  defp canonicalize(val) when is_map(val) do
    val
    |> Enum.map(fn {k, v} -> [to_string(k), canonicalize(v)] end)
    |> Enum.sort_by(&hd/1)
  end

  defp canonicalize(val) when is_list(val), do: Enum.map(val, &canonicalize/1)

  defp canonicalize(val) when is_atom(val) and val not in [nil, true, false],
    do: Atom.to_string(val)

  defp canonicalize(val), do: val
end
