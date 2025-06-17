defmodule Xirsys.XTurn.Sockets.MixProject do
  use Mix.Project

  def project do
    [
      app: :xturn_sockets,
      version: "1.1.0",
      elixir: "~> 1.15",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Enhanced flexible sockets library optimized for TURN server usage with robust error handling, rate limiting, and monitoring.",
      source_url: "https://github.com/xirsys/xturn-sockets",
      homepage_url: "https://xturn.me",
      package: package(),
      docs: [
        extras: ["README.md", "LICENSE.md"],
        main: "readme"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:ex_doc, ">= 0.0.0", only: :dev}
    ]
  end

  defp package do
    %{
      files: ["lib", "mix.exs", "README.md", "LICENSE.md", "config"],
      maintainers: ["Jahred Love"],
      licenses: ["Apache 2.0"],
      links: %{"Github" => "https://github.com/xirsys/xturn-sockets"}
    }
  end
end
