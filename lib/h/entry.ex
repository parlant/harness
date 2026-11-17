defmodule H.Entry do
  @moduledoc """
  An immutable transcript record. IDs are ordered and unique within a session.

  Data is owned by the entry; provider context and client views are projections,
  not alternate copies of the transcript.
  """

  @enforce_keys [:id, :conversation_id, :kind, :data]
  defstruct [:id, :conversation_id, :kind, :data]

  @type t :: %__MODULE__{
          id: pos_integer(),
          conversation_id: pos_integer(),
          kind: String.t(),
          data: map()
        }
end
