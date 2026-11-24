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
      elixirc_paths: elixirc_paths(Mix.env()),
      # mix test --cover fails below 100%: every line of lib/ runs in a test, on every OS CI
      # covers. The platform adapters are the exception: their Windows, Linux and macOS
      # branches cannot all run on one machine, so scripts/smoke.ps1 checks them end to end on
      # each OS instead (device stats, process trees, PowerShell sessions).
      test_coverage: [
        summary: [threshold: 100],
        ignore_modules: [Testor.OS, Testor.Device, Testor.Device.Unix, ~r/^Testor\.Test\./]
      ],
      releases: [
        testor: [include_executables_for: [:unix, :windows]]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
