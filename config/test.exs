import Config

# Test: use a temp directory
config :vfs_spike, sync_dir: Path.expand("./tmp/test_vfs")

# No clustering in tests
config :libcluster, topologies: []
