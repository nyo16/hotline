defmodule Hotline.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Hotline.PubSub},
      {Registry, keys: :unique, name: Hotline.Registry}
    ]

    opts = [strategy: :one_for_one, name: Hotline.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
