defmodule VfsSpike.MixProject do
  use Mix.Project

  def project do
    [
      app: :vfs_spike,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {VfsSpike.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # File system watcher (uses FSEvents on macOS, inotify on Linux)
      {:file_system, "~> 1.0"},

      # Distributed PubSub
      {:phoenix_pubsub, "~> 2.1"},

      # Clustering for Fly.io
      {:libcluster, "~> 3.4"},
      {:dns_cluster, "~> 0.1"}
    ]
  end

  defp releases do
    [
      vfs_spike: [
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
