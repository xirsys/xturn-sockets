defmodule Xirsys.XTurn.Sockets.MixProject do
  use Mix.Project

  def project do
    [
      app: :xturn_sockets,
      version: "0.1.0",
      elixir: "~> 1.6.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  defp deps do
    [
      {:xmedialib, git: "https://github.com/xirsys/xmedialib"}
    ]
  end
end
