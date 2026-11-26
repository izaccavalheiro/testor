defmodule Testor.Blob do
  @moduledoc """
  The object store port: where a run's files are kept (`Testor.Storage`), with two adapters.

    * `Testor.Blob.Files`: a folder (`%{root: dir}`). The home itself in the default setup,
      where nothing changes: run.ps1 writes there and testor reads it in place.
    * `Testor.Blob.S3`: an S3-compatible bucket (AWS S3, MinIO, Cloudflare R2, Google Cloud
      Storage's XML API, Ceph, versitygw), signed with SigV4 (`Testor.Aws`).

  Keys are `/`-separated relative paths (`runs/<id>.json`, `logs/<id>.log`,
  `screenshots/<id>/<path>`); a key with an empty, `.` or `..` segment, a backslash or a NUL is
  refused. Every call takes the adapter's config first.

    * `put(cfg, key, source)`: `source` is `{:file, path}` (streamed; S3 sends a large one in
      parts) or a binary. `:ok` or `{:error, why}`.
    * `get(cfg, key, dest)`: `dest` is `{:file, path}` (written whole, then renamed into place)
      or `:binary` (`{:ok, data}`). `:not_found` when there is no such object.
    * `head(cfg, key)`: `{:ok, %{size: bytes}}` or `:not_found`.
    * `list(cfg, prefix)`: `{:ok, [%{key, size}]}`, every object whose key starts with
      `prefix`, sorted by key.
    * `delete(cfg, keys)`: `{:ok, deleted, kept}`; `kept` are the keys the store refused to
      delete (S3: under legal hold or Object Lock), left as they are.
    * `presign(cfg, key, seconds, opts)`: `{:ok, url}` a browser may GET for `seconds`
      (`opts`: `:filename` for an attachment, `:type` for the content type), or `:none`
      (a folder: testor serves the file itself).
  """

  @type cfg :: map()
  @type key :: String.t()
  @callback put(cfg, key, {:file, Path.t()} | binary()) :: :ok | {:error, term()}
  @callback get(cfg, key, {:file, Path.t()} | :binary) ::
              :ok | {:ok, binary()} | :not_found | {:error, term()}
  @callback head(cfg, key) :: {:ok, %{size: non_neg_integer()}} | :not_found | {:error, term()}
  @callback list(cfg, String.t()) :: {:ok, [%{key: key, size: non_neg_integer()}]} | {:error, term()}
  @callback delete(cfg, [key]) :: {:ok, [key], [key]} | {:error, term()}
  @callback presign(cfg, key, pos_integer(), keyword()) :: {:ok, String.t()} | :none

  @doc "Whether `key` is a key this port takes."
  def key?(key) when is_binary(key) and key != "" do
    segments = String.split(key, "/")
    not String.contains?(key, ["\\", <<0>>]) and Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  def key?(_key), do: false

  @doc "Every key under `prefix` deleted (retention, a deleted run): `{:ok, deleted, kept}`."
  def delete_prefix(adapter, cfg, prefix) do
    with {:ok, objects} <- adapter.list(cfg, prefix) do
      case Enum.map(objects, & &1.key) do
        [] -> {:ok, [], []}
        keys -> adapter.delete(cfg, keys)
      end
    end
  end
end
