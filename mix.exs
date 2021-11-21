defmodule AmqpHelpers.MixProject do
  use Mix.Project

  def project do
    [
      app: :amqp_helpers,
      name: "AMQP Helpers",
      description: "Non opinionated AMQP helpers",
      version: "1.1.1",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      dialyzer: dialyzer(),
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      package: package(),
      test_coverage: test_coverage(),
      preferred_cli_env: preferred_cli_env()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:amqp, "~> 3.0"},
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.24", only: :dev, runtime: false},
      {:excoveralls, "~> 0.14", only: :test, optional: true},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp aliases do
    [cached_dialyzer: &run_cached_dialyzer/1]
  end

  defp dialyzer do
    [
      plt_add_apps: [],
      plt_file: {:no_warn, "_build/plts/dialyzer.plt"}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md"],
      licenses: ["BSD-3-Clause"],
      links: %{"Github" => "https://github.com/kantox/amqp_helpers"}
    ]
  end

  defp test_coverage do
    [tool: ExCoveralls]
  end

  defp preferred_cli_env do
    [coveralls: :test, "coveralls.github": :test, "coveralls.html": :test]
  end

  defp run_cached_dialyzer(args) do
    {:no_warn, plt_file} = dialyzer()[:plt_file]

    try do
      :dialyzer_plt.from_file(plt_file)
    rescue
      _error -> plt_file |> Path.dirname() |> File.rm_rf()
    catch
      _error -> plt_file |> Path.dirname() |> File.rm_rf()
    end

    Mix.Task.run("dialyzer", args)
  end
end
