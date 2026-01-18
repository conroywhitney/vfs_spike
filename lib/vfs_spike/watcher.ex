defmodule VfsSpike.Watcher do
  @moduledoc """
  Watches a directory for changes and syncs them via PubSub.

  When a file is created/modified locally:
  1. file_system detects the change
  2. We read the file content
  3. We broadcast via PubSub
  4. Remote nodes receive and write to their local dir
  """

  use GenServer
  require Logger

  @pubsub VfsSpike.PubSub
  @topic "vfs:sync"

  # Client API

  def start_link(opts) do
    dir = Keyword.fetch!(opts, :dir)
    GenServer.start_link(__MODULE__, dir, name: __MODULE__)
  end

  def sync_dir do
    GenServer.call(__MODULE__, :get_dir)
  end

  @doc "Force sync all files in the directory to other nodes"
  def sync_all do
    GenServer.call(__MODULE__, :sync_all)
  end

  @doc "Force sync a specific file"
  def sync_file(relative_path) do
    GenServer.call(__MODULE__, {:sync_file, relative_path})
  end

  # Server callbacks

  @impl true
  def init(dir) do
    # Ensure directory exists
    File.mkdir_p!(dir)

    # Start file system watcher
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [dir])
    FileSystem.subscribe(watcher_pid)

    # Subscribe to PubSub for remote changes
    Phoenix.PubSub.subscribe(@pubsub, @topic)

    Logger.info("[VfsSpike.Watcher] Watching: #{dir}")
    Logger.info("[VfsSpike.Watcher] Node: #{node()}")

    {:ok, %{dir: dir, watcher_pid: watcher_pid, syncing: MapSet.new()}}
  end

  @impl true
  def handle_call(:get_dir, _from, state) do
    {:reply, state.dir, state}
  end

  @impl true
  def handle_call(:sync_all, _from, state) do
    count = sync_directory(state.dir, state.dir)
    Logger.info("[VfsSpike.Watcher] Synced #{count} files")
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_call({:sync_file, relative_path}, _from, state) do
    full_path = Path.join(state.dir, relative_path)

    result =
      cond do
        File.dir?(full_path) ->
          broadcast({:mkdir, relative_path})
          :ok

        File.regular?(full_path) ->
          case File.read(full_path) do
            {:ok, content} ->
              broadcast({:write, relative_path, content})
              :ok

            {:error, reason} ->
              {:error, reason}
          end

        true ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  # Local file system events
  @impl true
  def handle_info({:file_event, _pid, {path, events}}, state) do
    relative_path = Path.relative_to(path, state.dir)

    # Skip if we're currently syncing this file (from remote)
    if MapSet.member?(state.syncing, relative_path) do
      {:noreply, state}
    else
      handle_local_event(path, relative_path, events, state)
    end
  end

  # Remote sync events from PubSub
  @impl true
  def handle_info({:vfs_sync, event, from_node}, state) when from_node != node() do
    state = handle_remote_event(event, state)
    {:noreply, state}
  end

  # Ignore our own broadcasts
  @impl true
  def handle_info({:vfs_sync, _event, _from_node}, state) do
    {:noreply, state}
  end

  # Clear syncing flag after write completes
  @impl true
  def handle_info({:clear_syncing, path}, state) do
    {:noreply, %{state | syncing: MapSet.delete(state.syncing, path)}}
  end

  # Private helpers

  defp handle_local_event(path, relative_path, events, state) do
    cond do
      # File/dir deleted
      :removed in events ->
        Logger.info("[Local] Deleted: #{relative_path}")
        broadcast({:delete, relative_path})
        {:noreply, state}

      # Directory created
      :created in events and File.dir?(path) ->
        Logger.info("[Local] Dir created: #{relative_path}")
        broadcast({:mkdir, relative_path})
        {:noreply, state}

      # File created or modified
      (:created in events or :modified in events) and File.regular?(path) ->
        case File.read(path) do
          {:ok, content} ->
            Logger.info("[Local] File sync: #{relative_path} (#{byte_size(content)} bytes)")
            broadcast({:write, relative_path, content})

          {:error, reason} ->
            Logger.warning("[Local] Failed to read #{relative_path}: #{reason}")
        end

        {:noreply, state}

      # Ignore other events (renamed, etc for now)
      true ->
        {:noreply, state}
    end
  end

  defp handle_remote_event({:write, relative_path, content}, state) do
    full_path = Path.join(state.dir, relative_path)

    # Mark as syncing to avoid echo
    state = %{state | syncing: MapSet.put(state.syncing, relative_path)}

    # Ensure parent directory exists
    full_path |> Path.dirname() |> File.mkdir_p!()

    # Write the file
    File.write!(full_path, content)
    Logger.info("[Remote] Wrote: #{relative_path} (#{byte_size(content)} bytes)")

    # Clear syncing flag after a short delay
    Process.send_after(self(), {:clear_syncing, relative_path}, 100)

    state
  end

  defp handle_remote_event({:mkdir, relative_path}, state) do
    full_path = Path.join(state.dir, relative_path)
    state = %{state | syncing: MapSet.put(state.syncing, relative_path)}

    File.mkdir_p!(full_path)
    Logger.info("[Remote] Mkdir: #{relative_path}")

    Process.send_after(self(), {:clear_syncing, relative_path}, 100)
    state
  end

  defp handle_remote_event({:delete, relative_path}, state) do
    full_path = Path.join(state.dir, relative_path)
    state = %{state | syncing: MapSet.put(state.syncing, relative_path)}

    if File.dir?(full_path) do
      File.rm_rf!(full_path)
    else
      File.rm(full_path)
    end

    Logger.info("[Remote] Deleted: #{relative_path}")

    Process.send_after(self(), {:clear_syncing, relative_path}, 100)
    state
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:vfs_sync, event, node()})
  end

  defp sync_directory(base_dir, current_dir) do
    case File.ls(current_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, 0, fn entry, count ->
          full_path = Path.join(current_dir, entry)
          relative_path = Path.relative_to(full_path, base_dir)

          cond do
            # Skip hidden files/dirs
            String.starts_with?(entry, ".") ->
              count

            File.dir?(full_path) ->
              broadcast({:mkdir, relative_path})
              count + 1 + sync_directory(base_dir, full_path)

            File.regular?(full_path) ->
              case File.read(full_path) do
                {:ok, content} ->
                  broadcast({:write, relative_path, content})
                  count + 1

                _ ->
                  count
              end

            true ->
              count
          end
        end)

      _ ->
        0
    end
  end
end
