defmodule Regenerator.MixProject do
  use Mix.Project

  def project do
    [app: :regenerator, version: "0.1.0", elixir: "~> 1.20", deps: []]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Regenerator.Application, []}]
  end
end
