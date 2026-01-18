import Config

# Default sync directory (can be overridden via VFS_SYNC_DIR env var)
config :vfs_spike, sync_dir: System.get_env("VFS_SYNC_DIR") || Path.expand("~/vfs")

# Libcluster: no automatic clustering by default
config :libcluster, topologies: []

# Import environment specific config
import_config "#{config_env()}.exs"
