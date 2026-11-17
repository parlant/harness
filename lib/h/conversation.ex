defmodule H.Conversation do
  @moduledoc """
  A linear transcript segment, optionally inheriting another conversation's prefix.

  `parent` describes history, never task ownership or process supervision.
  Own entry IDs are stored newest first for constant-time append.
  """

  @enforce_keys [:id]
  defstruct [:id, :parent, entry_ids: []]

  @type t :: %__MODULE__{
          id: pos_integer(),
          parent: nil | %{conversation_id: pos_integer(), at: pos_integer()},
          entry_ids: [pos_integer()]
        }
end
