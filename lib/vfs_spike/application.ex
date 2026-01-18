defmodule VfsSpike.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])
    sync_dir = Application.get_env(:vfs_spike, :sync_dir, default_sync_dir())

    children = [
      # Clustering
      {Cluster.Supervisor, [topologies, [name: VfsSpike.ClusterSupervisor]]},

      # PubSub for distributed file sync
      {Phoenix.PubSub, name: VfsSpike.PubSub},

      # File watcher + sync
      {VfsSpike.Watcher, dir: sync_dir}
    ]

    opts = [strategy: :one_for_one, name: VfsSpike.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp default_sync_dir do
    Path.expand("~/vfs")
  end
end
