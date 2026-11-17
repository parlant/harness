defmodule H.Storage.MemoryTest do
  use H.Storage.Conformance

  def open_store(opts \\ []) do
    H.Storage.open(H.Storage.Memory, opts)
  end
end
