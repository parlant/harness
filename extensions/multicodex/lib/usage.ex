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
        parse(body, System.system_time(:second))

      _ ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  end

  # Field names follow Codex's pinned RateLimitStatusPayload model. This is
  # compatibility parsing, not a contract that usage is reserved for a request.
  def parse(%{"rate_limit" => %{} = limit} = body, now) do
    reached_type =
      case body["rate_limit_reached_type"] do
        %{"type" => type} -> type
        type -> type
      end

    windows = Enum.map(["primary_window", "secondary_window"], &window(limit[&1], now))
    headroom = for {:ok, percent, _} <- windows, do: percent
    resets = for {:ok, _, reset} <- windows, do: reset
    valid_ms = Enum.min([300 | resets]) * 1000

    cond do
      reached_type in @workspace_limits or match?(%{"reached" => true}, body["spend_control"]) ->
        {:ok, :blocked, valid_ms}

      reached_type not in [nil, "rate_limit_reached"] ->
        :unavailable

      limit["allowed"] == true and limit["limit_reached"] == false and length(headroom) == 2 and
          Enum.max(headroom) < 100 ->
        {:ok, {:quota, Enum.max(headroom)}, valid_ms}

      (limit["limit_reached"] == true or Enum.any?(headroom, &(&1 >= 100))) and
          explicit_credit?(body["credits"]) ->
        {:ok, :credits, valid_ms}

      true ->
        :unavailable
    end
  end

  def parse(_, _), do: :unavailable

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
