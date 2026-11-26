defmodule Testor.Blob.Files do
  @moduledoc """
  `Testor.Blob` over a folder (`%{root: dir}`): a key is the file at that relative path. Writes
  go to a temporary file first and are renamed into place, so a reader never sees half a file.
  A symbolic link is neither followed nor listed.
  """
  @behaviour Testor.Blob
  alias Testor.{Blob, Files}

  @impl true
  def put(cfg, key, source) do
    with {:ok, path} <- path(cfg, key) do
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

      result =
        case source do
          {:file, from} -> File.cp(from, tmp)
          data -> File.write(tmp, data)
        end

      with :ok <- result, :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          File.rm(tmp)
          {:error, reason}
      end
    end
  end

  @impl true
  def get(cfg, key, dest) do
    with {:ok, path} <- path(cfg, key),
         {:file, _, _} <- Files.entry(path) do
      case dest do
        :binary -> File.read(path)
        {:file, to} -> copy(path, to)
      end
    else
      {:error, _} = error -> error
      _ -> :not_found
    end
  end

  defp copy(from, to) do
    File.mkdir_p!(Path.dirname(to))
    tmp = to <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with {:ok, _} <- File.copy(from, tmp), :ok <- File.rename(tmp, to) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  @impl true
  def head(cfg, key) do
    with {:ok, path} <- path(cfg, key),
         {:file, size, _} <- Files.entry(path) do
      {:ok, %{size: size, sha256: nil}}
    else
      {:error, _} = error -> error
      _ -> :not_found
    end
  end

  @impl true
  def list(cfg, prefix) do
    # The folder the prefix ends in (or names), walked, its files kept when their keys match.
    dir = if String.ends_with?(prefix, "/") or prefix == "", do: prefix, else: Path.dirname(prefix)
    dir = if dir == ".", do: "", else: dir
    base = Path.join(cfg.root, dir)

    objects =
      for file <- Files.walk(base),
          key = Path.join(dir, file.rel) |> String.replace("\\", "/") |> String.trim_leading("/"),
          String.starts_with?(key, prefix),
          not String.contains?(Path.basename(key), ".tmp-"),
          do: %{key: key, size: file.size}

    {:ok, Enum.sort_by(objects, & &1.key)}
  end

  @impl true
  def delete(cfg, keys) do
    deleted =
      for key <- keys, {:ok, path} <- [path(cfg, key)], File.rm(path) == :ok, do: key

    # Folders left empty go too (a run's screenshots, its log's segments).
    for key <- deleted, do: prune(cfg.root, Path.dirname(Path.join(cfg.root, key)))
    {:ok, deleted, keys -- deleted}
  end

  defp prune(root, dir) do
    if dir != root and String.starts_with?(dir, root) and File.rmdir(dir) == :ok,
      do: prune(root, Path.dirname(dir))
  end

  @impl true
  def presign(_cfg, _key, _seconds, _opts), do: :none

  defp path(cfg, key) do
    if Blob.key?(key) and no_links?(cfg.root, String.split(key, "/")),
      do: {:ok, Path.join(cfg.root, key)},
      else: {:error, :bad_key}
  end

  # Each part of the path that is there is a folder or a file, not a link; the rest may be missing.
  defp no_links?(root, segments) do
    segments
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.all?(fn path ->
      case File.lstat(path) do
        {:ok, %{type: type}} -> type in [:regular, :directory]
        {:error, reason} -> reason == :enoent
      end
    end)
  end
end
