defmodule Hotline.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nyo16/hotline"

  def project do
    [
      app: :hotline,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Hotline",
      description: "Telegram Bot API client and framework for Elixir",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Hotline.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.0", optional: true},
      {:phoenix_pubsub, "~> 2.1"},
      {:mime, "~> 2.0", optional: true},
      {:broadway, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      "hotline.gen": ["run priv/generator/generate.exs"]
    ]
  end

  defp docs do
    [
      main: "Hotline",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"] ++ Path.wildcard("examples/*.exs")
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv examples .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
