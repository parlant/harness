defmodule H.Session.LiveOutput do
  @moduledoc false

  @preview_bytes 51_200
  @capped "\n[Live output capped]\n"

  # Bound the total per attempt before sending anything to the session mailbox.
  # The executor still collects its normal final tail and spill file separately.
  @spec limit((binary() -> term())) :: (binary() -> term())
  def limit(emit) do
    received = :atomics.new(1, signed: false)

    fn
      chunk when is_binary(chunk) and chunk != "" ->
        size = byte_size(chunk)
        total = :atomics.add_get(received, 1, size)
        remaining = @preview_bytes - (total - size)

        cond do
          remaining >= size ->
            emit.(String.replace_invalid(chunk, "?"))

          remaining >= 0 ->
            prefix = binary_part(chunk, 0, remaining)
            emit.(String.replace_invalid(prefix, "?") <> @capped)

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
