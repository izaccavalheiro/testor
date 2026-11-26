defmodule Testor.Snapshots do
  @moduledoc """
  Content-addressed snapshots of a working tree (`runner/snapshot.ps1`).

  A client sends a manifest of `{path, sha256, mode, size}` (`POST
  /api/v1/projects/:p/snapshots`); testor answers with the contents it lacks, the client
  uploads those (`PUT /api/v1/blobs/sha256:<hex>`, checked against their hash), then sends the
  manifest again. Once every content is there, the manifest is kept and its own SHA-256 is the
  snapshot's id. A job names it (`"snapshot"`) instead of a git ref, and its agent fetches only
  the contents its cache lacks: a one-line change moves one blob.

  Keys, in the home or the bucket (`Testor.Storage`): `cas/sha256/<ab>/<hex>` for contents,
  `snapshots/<project>/<hex>.json` for manifests. The janitor deletes manifests not sent again
  for `snapshots.keepDays`, then contents no manifest names (a day old at least, so an upload in
  progress keeps its blobs).

  A path is relative, `/`-separated, without `.`, `..` or empty segments, `.git`, a backslash,
  a colon, control characters or a segment ending in a dot or a space; two paths that differ
  only by case, or a file that is also another's folder, are refused: what Windows and macOS
  could not hold apart. A manifest holds files only: the client follows symbolic links inside
  the tree and refuses the others.
  """
  require Logger
  alias Testor.{Config, Storage}

  @hex ~r/\A[0-9a-f]{64}\z/
  @modes ["644", "755"]
  @day 86_400

  def settings, do: Config.retention()["snapshots"]

  @doc "A content's SHA-256 from `sha256:<hex>`: `{:ok, hex}` or `:error`."
  def parse_id("sha256:" <> hex), do: if(Regex.match?(@hex, hex), do: {:ok, hex}, else: :error)
  def parse_id(_), do: :error

  def blob_key(hex), do: "cas/sha256/#{binary_part(hex, 0, 2)}/#{hex}"
  def manifest_key(project, hex), do: "snapshots/#{project}/#{hex}.json"

  # --- manifests -----------------------------------------------------------------------------

  @doc """
  Checks the manifest `params` (`files`, optional `branch` and `commit`) of `project`:
  `{:ok, %{"id", "missing", "stored"}}`, where `missing` are the hashes to upload and `stored`
  says the manifest is kept (nothing missing), or `{:error, message}`.
  """
  def offer(project, params) do
    with {:ok, files} <- files(params["files"]),
         :ok <- meta(params) do
      hex = files |> canonical() |> sha256()
      missing = missing(files)

      if missing == [] do
        manifest =
          %{
            "id" => "sha256:" <> hex,
            "project" => project,
            "createdAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
            "bytes" => Enum.sum_by(files, & &1["size"]),
            "files" => files
          }
          |> put_if("branch", params["branch"])
          |> put_if("commit", params["commit"])

        {adapter, cfg} = Storage.blob()

        with :ok <- adapter.put(cfg, manifest_key(project, hex), JSON.encode!(manifest)),
             :ok <- point(adapter, cfg, project, params["branch"], "sha256:" <> hex) do
          {:ok, %{"id" => "sha256:" <> hex, "missing" => [], "stored" => true}}
        else
          {:error, why} -> {:error, {:store, why}}
        end
      else
        {:ok, %{"id" => "sha256:" <> hex, "missing" => missing, "stored" => false}}
      end
    end
  end

  @doc "The manifest of snapshot `hex` of `project`: `{:ok, map}` or `:not_found`."
  def manifest(project, hex) do
    {adapter, cfg} = Storage.blob()

    with {:ok, data} <- adapter.get(cfg, manifest_key(project, hex), :binary),
         {:ok, %{} = manifest} <- JSON.decode(data) do
      {:ok, manifest}
    else
      _ -> :not_found
    end
  end

  # The branch's latest snapshot and the one before it: the base its changes are counted from.
  defp point(_adapter, _cfg, _project, nil, _id), do: :ok

  defp point(adapter, cfg, project, branch, id) do
    case pointer(project, branch) do
      %{"current" => ^id} ->
        :ok

      was ->
        adapter.put(
          cfg,
          pointer_key(project, branch),
          JSON.encode!(%{"current" => id, "previous" => was["current"]})
        )
    end
  end

  defp pointer_key(project, branch),
    do: "snapshots/#{project}/branches/#{Base.url_encode64(branch, padding: false)}.json"

  defp pointer(project, branch) do
    {adapter, cfg} = Storage.blob()

    with {:ok, data} <- adapter.get(cfg, pointer_key(project, branch), :binary),
         {:ok, %{} = map} <- JSON.decode(data) do
      map
    else
      _ -> %{}
    end
  end

  @doc """
  The files of snapshot `hex` that differ from its base (`branch`'s previous snapshot, else the
  default branch's latest): `{:ok, paths}`, or `:none` when there is no base to compare with or
  more than `Testor.Select.max_files/0` changed (a full run then).
  """
  def changed(project, hex, branch) do
    id = "sha256:" <> hex
    mine = if branch, do: pointer(project, branch), else: %{}
    default = pointer(project, Testor.States.settings()["defaultBranch"])

    base =
      Enum.find(
        [mine["current"], mine["previous"], default["current"], default["previous"]],
        &(&1 && &1 != id)
      )

    with "sha256:" <> base_hex <- base,
         {:ok, %{"files" => before}} <- manifest(project, base_hex),
         {:ok, %{"files" => now}} <- manifest(project, hex) do
      known = Map.new(before, &{&1["path"], &1["sha256"]})
      paths = for file <- now, known[file["path"]] != file["sha256"], do: file["path"]
      if length(paths) <= Testor.Select.max_files(), do: {:ok, paths}, else: :none
    else
      _ -> :none
    end
  end

  defp meta(params) do
    commit = params["commit"]

    cond do
      params["branch"] != nil and not Testor.Jobs.ref?(params["branch"]) ->
        {:error, "branch is a git branch name"}

      commit != nil and not (is_binary(commit) and Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, commit)) ->
        {:error, "commit is a git commit's full hash"}

      true ->
        :ok
    end
  end

  defp files(list) when is_list(list) do
    cfg = settings()

    if length(list) > cfg["maxFiles"] do
      {:error, "a snapshot has #{cfg["maxFiles"]} files at most (snapshots.maxFiles)"}
    else
      list
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
        case entry(item, cfg["maxFileMB"] * 1_048_576) do
          {:ok, file} -> {:cont, {:ok, [file | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> then(fn
        {:ok, files} -> whole(Enum.sort_by(files, & &1["path"]), cfg["maxMB"] * 1_048_576)
        error -> error
      end)
    end
  end

  defp files(_), do: {:error, "files is a list of {path, sha256, mode, size}"}

  defp entry(%{"path" => path, "sha256" => hex, "size" => size} = item, max) do
    mode = Map.get(item, "mode", "644")

    cond do
      not path?(path) -> {:error, "#{inspect(path)} is not a path inside the tree"}
      not (is_binary(hex) and Regex.match?(@hex, hex)) -> {:error, "sha256 of #{path} is 64 hex digits"}
      mode not in @modes -> {:error, "mode of #{path} is \"644\" or \"755\""}
      not (is_integer(size) and size >= 0) -> {:error, "size of #{path} is a number of bytes"}
      size > max -> {:error, "#{path} is over snapshots.maxFileMB"}
      true -> {:ok, %{"path" => path, "sha256" => hex, "mode" => mode, "size" => size}}
    end
  end

  defp entry(_, _), do: {:error, "files is a list of {path, sha256, mode, size}"}

  # The tree as a whole: within maxMB, no two paths one on a case-insensitive disk, no file that
  # is another's folder.
  defp whole(files, max) do
    names = Enum.map(files, &String.downcase(&1["path"]))
    set = MapSet.new(names)

    folder =
      Enum.find(names, fn name ->
        parts = String.split(name, "/")
        Enum.any?(1..(length(parts) - 1)//1, &MapSet.member?(set, parts |> Enum.take(&1) |> Enum.join("/")))
      end)

    cond do
      Enum.sum_by(files, & &1["size"]) > max -> {:error, "a snapshot is snapshots.maxMB at most"}
      MapSet.size(set) < length(names) -> {:error, "two paths differ only by case"}
      folder != nil -> {:error, "#{folder} is below a path that is a file"}
      true -> {:ok, files}
    end
  end

  @doc false
  def path?(path) do
    is_binary(path) and byte_size(path) in 1..1024 and String.valid?(path) and
      not String.contains?(path, ["\\", ":"]) and not Regex.match?(~r/[\x00-\x1f\x7f]/, path) and
      Enum.all?(String.split(path, "/"), fn segment ->
        segment not in ["", ".", ".."] and String.downcase(segment) != ".git" and
          not String.ends_with?(segment, [".", " "])
      end)
  end

  # One line per file: the bytes the id is the hash of.
  defp canonical(files),
    do: Enum.map_join(files, "", &"#{&1["mode"]} #{&1["size"]} #{&1["sha256"]} #{&1["path"]}\n")

  defp missing(files) do
    {adapter, cfg} = Storage.blob()

    files
    |> Enum.map(& &1["sha256"])
    |> Enum.uniq()
    |> Task.async_stream(&{&1, adapter.head(cfg, blob_key(&1))}, max_concurrency: 32, timeout: 60_000)
    |> Enum.flat_map(fn {:ok, {hex, found}} -> if match?({:ok, _}, found), do: [], else: [hex] end)
    |> Enum.sort()
  end

  # --- contents ------------------------------------------------------------------------------

  @doc """
  Keeps the file at `path` as content `hex`, once its SHA-256 matches: `:ok`,
  `{:error, :digest}` or `{:error, :too_large}`.
  """
  def put_blob(hex, path) do
    size = File.stat!(path).size

    cond do
      size > settings()["maxFileMB"] * 1_048_576 ->
        {:error, :too_large}

      file_sha256(path) != hex ->
        {:error, :digest}

      true ->
        {adapter, cfg} = Storage.blob()
        key = blob_key(hex)
        if match?({:ok, _}, adapter.head(cfg, key)), do: :ok, else: adapter.put(cfg, key, {:file, path})
    end
  end

  @doc """
  How content `hex` is served to an agent: `{:redirect, url}` (a presigned link to the bucket),
  `{:file, path}` or `:not_found`.
  """
  def blob(hex) do
    {adapter, cfg} = Storage.blob()
    key = blob_key(hex)
    local = Storage.local_path(key)

    cond do
      not Storage.s3?() ->
        if File.regular?(local), do: {:file, local}, else: :not_found

      cfg.presign and match?({:ok, _}, adapter.head(cfg, key)) ->
        {:ok, url} = adapter.presign(cfg, key, 300, filename: hex)
        {:redirect, url}

      adapter.get(cfg, key, {:file, local}) == :ok ->
        {:file, local}

      true ->
        :not_found
    end
  end

  @doc false
  def file_sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # --- retention -----------------------------------------------------------------------------

  @doc """
  Deletes manifests older than `snapshots.keepDays`, then contents no manifest names that are a
  day old. `%{"snapshots" => n, "blobs" => n}`.
  """
  def sweep(now \\ System.os_time(:second)) do
    {adapter, cfg} = Storage.blob()
    keep = settings()["keepDays"] * @day

    with {:ok, manifests} <- adapter.list(cfg, "snapshots/"),
         {old, kept} = Enum.split_with(manifests, &old?(&1, now, keep)),
         {:ok, deleted, _} <- adapter.delete(cfg, Enum.map(old, & &1.key)),
         {:ok, blobs} <- adapter.list(cfg, "cas/sha256/"),
         named = named(adapter, cfg, kept),
         orphans =
           for(b <- blobs, old?(b, now, @day), not MapSet.member?(named, Path.basename(b.key)), do: b.key),
         {:ok, gone, _} <- adapter.delete(cfg, orphans) do
      %{"snapshots" => length(deleted), "blobs" => length(gone)}
    else
      error ->
        Logger.warning("snapshots: retention skipped: #{inspect(error)}")
        %{"snapshots" => 0, "blobs" => 0}
    end
  end

  # The contents the kept manifests name.
  defp named(adapter, cfg, manifests) do
    for %{key: key} <- manifests,
        {:ok, data} <- [adapter.get(cfg, key, :binary)],
        {:ok, %{"files" => files}} <- [JSON.decode(data)],
        file <- files,
        into: MapSet.new(),
        do: file["sha256"]
  end

  defp old?(%{modified: at}, now, age), do: is_integer(at) and now - at > age

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
