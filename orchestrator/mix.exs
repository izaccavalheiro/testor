defmodule Testor.MixProject do
  use Mix.Project

  # testor: the test orchestrator of a Windows test runner. It follows the test runs that
  # run.ps1 records, streams them live over server-sent events and serves the dashboard.
  def project do
    [
      app: :testor,
      version: "0.1.0",
      source_url: "https://github.com/izaccavalheiro/testor",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        testor: [include_executables_for: [:unix, :windows]]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Testor.Application, []}]
  end

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"}
    ]
  end
end
