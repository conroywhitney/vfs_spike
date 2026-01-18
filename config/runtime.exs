import Config

# Runtime config - loaded at runtime, after compilation

# Sync directory from environment
if sync_dir = System.get_env("VFS_SYNC_DIR") do
  config :vfs_spike, sync_dir: sync_dir
end

# Fly.io clustering configuration
if config_env() == :prod do
  app_name = System.get_env("FLY_APP_NAME")

  if app_name do
    config :libcluster,
      topologies: [
        fly6pn: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [
            polling_interval: 5_000,
            query: "#{app_name}.internal",
            node_basename: app_name
          ]
        ]
      ]
  end
end
