# VFS Spike

Distributed file sync over Erlang distribution. Drag a file into a folder on your Mac, watch it appear on a Fly.io server instantly.

## What It Does

```
Local Mac                              Fly.io (or any BEAM node)
~/vfs-local/                           /app/vfs/
     │                                      │
     ├── hello.txt ──── PubSub ────────────>├── hello.txt
     │                  (instant)           │
     │<──────────────── PubSub ─────────────├── from-cloud.txt
     ├── from-cloud.txt                     │
```

- **File watcher** (FSEvents/inotify) detects changes
- **Phoenix.PubSub** broadcasts over Erlang distribution
- **Bidirectional** - changes sync both ways
- **~200 lines of Elixir**

## Quick Start

### Local-to-Local (Two Terminals)

```bash
# Terminal 1
cd ~/code/vfs_spike
VFS_SYNC_DIR=~/vfs-a iex --name a@127.0.0.1 --cookie secret -S mix

# Terminal 2
VFS_SYNC_DIR=~/vfs-b iex --name b@127.0.0.1 --cookie secret -S mix
Node.connect(:"a@127.0.0.1")

# Now drag files into ~/vfs-a/ - they appear in ~/vfs-b/!
```

### Local-to-Fly.io

```bash
# Deploy to Fly
fly apps create vfs-spike
fly secrets set RELEASE_COOKIE=your-secret-cookie
fly deploy

# Connect via WireGuard
fly wireguard create
sudo wg-quick up ./fly-vfs-spike.conf

# Start local node with IPv6 distribution
VFS_SYNC_DIR=~/vfs-local \
ERL_AFLAGS="-proto_dist inet6_tcp" \
iex --name "local@YOUR_WIREGUARD_IP" \
    --cookie your-secret-cookie \
    -S mix

# Connect to Fly
Node.connect(:"vfs-spike@FLY_PRIVATE_IP")

# Sync!
VfsSpike.write("hello.txt", "Hello from Mac!")
```

## API

```elixir
VfsSpike.write("file.txt", "content")  # Write and auto-sync
VfsSpike.read("file.txt")              # Read local file
VfsSpike.ls()                          # List files
VfsSpike.sync_all()                    # Force sync all files to other nodes
VfsSpike.sync("file.txt")              # Force sync specific file
VfsSpike.nodes()                       # List connected nodes
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        VfsSpike.Watcher                      │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │ file_system  │───>│   GenServer  │───>│ Phoenix.PubSub│  │
│  │  (FSEvents)  │    │  (state: ETS)│    │  (broadcast)  │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│         │                   │                    │          │
│         ▼                   ▼                    ▼          │
│    Local Disk          In-Memory           Erlang Distrib   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Limitations (Current)

- **Ephemeral on Fly** - Files lost on restart (need Fly Volumes)
- **No conflict resolution** - Last write wins
- **Full file sync** - No deltas/chunks for large files
- **Rename = duplicate** - Old file not deleted on remote
- **Manual reconnect** - No auto-reconnect on disconnect

## Future Specs

### 1. Fly Volumes (Persistence)

Add persistent storage so files survive restarts.

```toml
# fly.toml
[mounts]
  source = "vfs_data"
  destination = "/app/vfs"
```

```bash
fly volumes create vfs_data --size 1 --region iad
fly deploy
```

### 2. Delete Event Handling

Properly handle file deletions and renames.

```elixir
# In Watcher, handle :removed events
def handle_info({:file_event, _pid, {path, events}}, state) when :removed in events do
  broadcast({:delete, relative_path})
end

# Track moves with :renamed event
def handle_info({:file_event, _pid, {path, [:renamed]}}, state) do
  # FSEvents gives us both old and new path
  broadcast({:rename, old_path, new_path})
end
```

### 3. Auto-Reconnect

Detect disconnection and reconnect automatically.

```elixir
defmodule VfsSpike.ClusterMonitor do
  use GenServer

  def init(_) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{known_nodes: []}}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.warning("Lost connection to #{node}, attempting reconnect...")
    Process.send_after(self(), {:reconnect, node}, 5_000)
    {:noreply, state}
  end

  def handle_info({:reconnect, node}, state) do
    case Node.connect(node) do
      true -> Logger.info("Reconnected to #{node}")
      false -> Process.send_after(self(), {:reconnect, node}, 5_000)
    end
    {:noreply, state}
  end
end
```

### 4. FUSE Mount

Add actual filesystem mount using fuserl or NIF.

```elixir
# Instead of watching ~/vfs-local, mount a FUSE filesystem
# that proxies to our GenServer

defmodule VfsSpike.Fuse do
  # FUSE callbacks write to VfsSpike.Store
  # VfsSpike.Store broadcasts via PubSub
  # True "virtual" filesystem, not watching real files
end
```

Benefits:
- No polling/watching needed
- Intercept all operations (read, write, stat, etc.)
- Can show remote files without downloading first

### 5. Multi-Region Sync

Spin up machines in multiple Fly regions.

```bash
fly scale count 3 --region iad,lax,cdg
```

```elixir
# Files sync across:
# - iad (Virginia)
# - lax (Los Angeles)
# - cdg (Paris)
#
# Erlang distribution + libcluster handles mesh networking
```

### 6. Chunked Transfer

Handle large files efficiently.

```elixir
defmodule VfsSpike.ChunkedSync do
  @chunk_size 1_048_576  # 1MB chunks

  def sync_large_file(path, content) do
    chunks = chunk_binary(content, @chunk_size)
    file_id = :crypto.hash(:sha256, content) |> Base.encode16()

    # Send metadata first
    broadcast({:file_start, path, file_id, length(chunks)})

    # Stream chunks
    chunks
    |> Enum.with_index()
    |> Enum.each(fn {chunk, idx} ->
      broadcast({:file_chunk, file_id, idx, chunk})
    end)

    broadcast({:file_complete, file_id})
  end
end
```

### 7. Conflict Resolution

Handle simultaneous edits.

```elixir
# Options:
# 1. Vector clocks - track causality
# 2. CRDTs - merge automatically
# 3. Last-write-wins with tombstones (current, but explicit)
# 4. Operational Transform (for text files)

defmodule VfsSpike.Conflict do
  # Keep both versions on conflict
  def resolve(:both_modified, local, remote) do
    {:conflict, "file.txt.local", "file.txt.remote"}
  end
end
```

### 8. Selective Sync

`.vfsignore` file to exclude patterns (like `.gitignore`).

```
# .vfsignore
*.log
node_modules/
.git/
*.tmp
```

### 9. Web Dashboard

LiveView UI showing:
- Connected nodes and their status
- Recent sync activity
- File conflicts
- Bandwidth usage

### 10. Mobile Sync

iOS/Android app that connects as a BEAM node. Photos sync instantly to your server.

### 11. End-to-End Encryption

Encrypt files before sync, decrypt on read. Only endpoints have keys.

```elixir
defmodule VfsSpike.Crypto do
  def encrypt(content, key), do: :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, content, aad, true)
  def decrypt(ciphertext, key), do: :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, false)
end
```

### 12. Version History

Git-like history for every file. Rollback, diff, branch.

```elixir
VfsSpike.history("file.txt")
# => [{:v3, "2026-01-18T00:00:00Z", "abc123"}, {:v2, ...}, {:v1, ...}]

VfsSpike.rollback("file.txt", :v2)
VfsSpike.diff("file.txt", :v2, :v3)
```

### 13. Permissions & Access Control

Role-based access: read-only nodes, write nodes, admin nodes.

```elixir
# Node capabilities
%{
  "backup-server" => [:read],
  "workstation" => [:read, :write],
  "admin" => [:read, :write, :delete, :admin]
}
```

## Tested With

- 10MB random binary files - ~1 second sync
- Text files - instant
- Finder drag-and-drop - works (after sync_all)

## Dependencies

- `file_system` - Cross-platform file watcher
- `phoenix_pubsub` - Distributed pub/sub
- `libcluster` - Automatic clustering (for Fly.io)
- `dns_cluster` - DNS-based node discovery

## License

MIT
