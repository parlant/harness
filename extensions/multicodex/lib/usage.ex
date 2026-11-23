defmodule Extensions.MultiCodex.Usage do
  @moduledoc false

  @url "https://chatgpt.com/backend-api/wham/usage"
  @workspace_limits ~w(workspace_owner_credits_depleted workspace_member_credits_depleted workspace_owner_usage_limit_reached workspace_member_usage_limit_reached)

  def fetch(%{access_token: access, account_id: account}) do
    case Req.get(@url,
           headers: [{"authorization", "Bearer " <> access}, {"chatgpt-account-id", account}],
           redirect: false,
           retry: false,
           receive_timeout: 5_000,
           connect_options: [timeout: 3_000]
         ) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        parse_detailed(body, System.system_time(:second))

      _ ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  end

  # Field names follow Codex's pinned RateLimitStatusPayload model. This is
  # compatibility parsing, not a contract that usage is reserved for a request.
  def parse(body, now) do
    case parse_detailed(body, now) do
      {:ok, capacity, valid_ms, _meta} -> {:ok, capacity, valid_ms}
      :unavailable -> :unavailable
    end
  end

  def parse_detailed(%{"rate_limit" => %{} = limit} = body, now) do
    reached_type =
      case body["rate_limit_reached_type"] do
        %{"type" => type} -> type
        type -> type
      end

    windows = Enum.map(["primary_window", "secondary_window"], &window(limit[&1], now))
    headroom = for {:ok, percent, _} <- windows, do: percent
    resets = for {:ok, _, reset} <- windows, do: reset
    valid_ms = Enum.min([300 | resets]) * 1000
    reset_ms = reset_ms(windows, resets)

    cond do
      reached_type in @workspace_limits or match?(%{"reached" => true}, body["spend_control"]) ->
        blocked_reset_ms = spend_control_reset_ms(body["spend_control"], now) || reset_ms
        {:ok, :blocked, valid_ms, %{reset_ms: blocked_reset_ms}}

      reached_type not in [nil, "rate_limit_reached"] ->
        :unavailable

      limit["allowed"] == true and limit["limit_reached"] == false and length(headroom) == 2 and
          Enum.max(headroom) < 100 ->
        {:ok, {:quota, Enum.max(headroom)}, valid_ms, %{reset_ms: nil}}

      (limit["limit_reached"] == true or Enum.any?(headroom, &(&1 >= 100))) and
          explicit_credit?(body["credits"]) ->
        {:ok, :credits, valid_ms, %{reset_ms: reset_ms}}

      (limit["limit_reached"] == true or Enum.any?(headroom, &(&1 >= 100))) and
          length(headroom) == 2 ->
        {:ok, :exhausted, valid_ms, %{reset_ms: reset_ms}}

      true ->
        :unavailable
    end
  end

  def parse_detailed(_, _), do: :unavailable

  defp reset_ms(windows, resets) do
    exhausted_resets = for {:ok, percent, reset} <- windows, percent >= 100, do: reset

    cond do
      exhausted_resets != [] -> Enum.max(exhausted_resets) * 1000
      resets != [] -> Enum.min(resets) * 1000
      true -> nil
    end
  end

  defp spend_control_reset_ms(%{"individual_limit" => %{} = individual}, now) do
    candidates =
      [
        individual,
        individual["window"],
        individual["primary_window"],
        individual["secondary_window"]
      ]
      |> Enum.flat_map(&reset_seconds(&1, now))

    case candidates do
      [] -> nil
      list -> Enum.min(list) * 1000
    end
  end

  defp spend_control_reset_ms(_, _), do: nil

  defp reset_seconds(%{"reset_after_seconds" => reset}, _now)
       when is_integer(reset) and reset > 0,
       do: [reset]

  defp reset_seconds(%{"reset_at" => reset}, now)
       when is_integer(reset) and reset > now,
       do: [reset - now]

  defp reset_seconds(_, _), do: []

  defp window(%{"used_percent" => p, "reset_after_seconds" => reset}, _now)
       when is_number(p) and p >= 0 and p <= 100 and is_integer(reset) and reset > 0,
       do: {:ok, p, reset}

  defp window(%{"used_percent" => p, "reset_at" => reset}, now)
       when is_number(p) and p >= 0 and p <= 100 and is_integer(reset) and reset > now,
       do: {:ok, p, reset - now}

  defp window(_, _), do: :unknown

  defp explicit_credit?(%{"has_credits" => true}), do: true
  defp explicit_credit?(%{"unlimited" => true}), do: true
  defp explicit_credit?(_), do: false
end
