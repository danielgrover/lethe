defmodule Lethe.Entry do
  @moduledoc """
  A single entry in a Lethe memory store.

  Tracks access metadata used by decay functions to compute relevance scores.
  """

  @enforce_keys [:key, :value, :inserted_at, :last_accessed_at]
  defstruct [
    :key,
    :value,
    :inserted_at,
    :last_accessed_at,
    access_count: 0,
    pinned: false,
    importance: 1.0,
    metadata: %{},
    summary: nil
  ]

  @type t :: %__MODULE__{
          key: term(),
          value: term(),
          inserted_at: DateTime.t(),
          last_accessed_at: DateTime.t(),
          access_count: non_neg_integer(),
          pinned: boolean(),
          importance: float(),
          metadata: map(),
          summary: term() | nil
        }
end
