defmodule AmqpHelpers.MixProject do
  use Mix.Project

  @app :amqp_helpers
  @version "1.5.0"

  def project do
    [
      app: @app,
      name: "AMQP Helpers",
      description: "Non opinionated AMQP helpers",
      version: @version,
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
      extras: ["README.md"],
      canonical: "http://hexdocs.pm/#{@app}",
      source_ref: "v#{@version}",
      source_url: "https://github.com/kantox/#{@app}",
      groups_for_modules: [
        Adapters: [
          AMQPHelpers.Adapter,
          AMQPHelpers.Adapters.AMQP,
          AMQPHelpers.Adapters.Stub
        ],
        Reliability: [
          AMQPHelpers.Reliability.Consumer,
          AMQPHelpers.Reliability.Producer
        ]
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md"],
      licenses: ["Kantox LTD"],
      links: %{
        "GitHub" => "https://github.com/kantox/#{@app}",
        "Docs" => "https://hexdocs.pm/#{@app}"
      }
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
      with {:error, reason} <- :dialyzer.plt_info(plt_file), do: throw(reason)
    rescue
      _error -> plt_file |> Path.dirname() |> File.rm_rf()
    catch
      _error -> plt_file |> Path.dirname() |> File.rm_rf()
    end

    Mix.Task.run("dialyzer", args)
  end
end
