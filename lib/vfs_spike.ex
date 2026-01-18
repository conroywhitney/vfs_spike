defmodule VfsSpike do
  @moduledoc """
  Distributed file sync spike.

  Watches a local directory and syncs changes to all connected nodes.

  ## Quick Start

      # Terminal 1:
      iex --name a@127.0.0.1 -S mix
      # Creates ~/vfs-a/

      # Terminal 2:
      iex --name b@127.0.0.1 -S mix
      # Creates ~/vfs-b/

      # Connect the nodes:
      Node.connect(:"a@127.0.0.1")

      # Now drag a file into ~/vfs-a/ in Finder
      # Watch it appear in ~/vfs-b/!
  """

  @doc "Returns the sync directory for this node"
  def sync_dir do
    VfsSpike.Watcher.sync_dir()
  end

  @doc "List connected nodes"
  def nodes do
    [node() | Node.list()]
  end

  @doc "Write a file to the sync directory (triggers sync)"
  def write(filename, content) do
    path = Path.join(sync_dir(), filename)
    File.write(path, content)
  end

  @doc "Read a file from the sync directory"
  def read(filename) do
    path = Path.join(sync_dir(), filename)
    File.read(path)
  end

  @doc "List files in the sync directory"
  def ls(subdir \\ "") do
    path = Path.join(sync_dir(), subdir)
    File.ls(path)
  end

  @doc "Force sync all files to other nodes"
  def sync_all do
    VfsSpike.Watcher.sync_all()
  end

  @doc "Force sync a specific file"
  def sync(filename) do
    VfsSpike.Watcher.sync_file(filename)
  end
end
