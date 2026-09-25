defmodule Regenerator.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Regenerator.Requests},
      {Task.Supervisor, name: Regenerator.Repairs},
      {Regenerator.Engine, Application.get_env(:regenerator, :engine, [])}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Regenerator.Supervisor)
  end
end
