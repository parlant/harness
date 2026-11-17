defmodule H.Application do
  @moduledoc """
  OTP application entry point for `:harness`.

  Unit tests run with `--no-start` and start isolated children via `start_supervised!`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: H.Registry},
      {Registry, keys: :duplicate, name: H.PubSub}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: H.Supervisor)
  end
end
