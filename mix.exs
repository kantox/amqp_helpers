defmodule AmqpHelpers.MixProject do
  use Mix.Project

  def project do
    [
      app: :amqp_helpers,
      version: "0.1.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: test_coverage(),
      preferred_cli_env: preferred_cli_env()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:amqp, "~> 2.1"},
      {:excoveralls, "~> 0.14", only: :test, optional: true},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp test_coverage do
    [tool: ExCoveralls]
  end

  defp preferred_cli_env do
    [coveralls: :test, "coveralls.github": :test, "coveralls.html": :test]
  end
end
