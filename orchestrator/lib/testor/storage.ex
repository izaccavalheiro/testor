defmodule Testor.Storage do
  @moduledoc """
  Where runs are kept. By default (`"files"`) the home is the store: run.ps1 and testor write
  `runs/`, `logs/`, `screenshots/`, `artifacts/`, `reports/` and `attestations/` there, and
  every testor sharing the home (one volume) reads them in place.

  With `storage` in config.json set to S3, the bucket is the store and the home is a cache:

      "storage": {"type": "s3", "bucket": "acme-testor", "region": "eu-west-1",
                  "endpoint": "https://minio.example.com", "pathStyle": true,
                  "publicEndpoint": "https://files.example.com",   (optional)
                  "encryption": "aws:kms", "kmsKeyId": "...",      (optional)
                  "presign": true, "cacheMB": 2048}                (the defaults)

    * A finished run's files are uploaded under the same keys as their paths in the home
      (`logs/<id>.log`...) once it is signed, then its record (with `"stored": true`).
    * A testor that lacks a stored run's files fetches them when they are first read: its log,
      reports and attestations as files in its home; its screenshots and artifacts listed from
      the bucket, images, videos and downloads sent as presigned links that last minutes (after
      the request's access check), anything shown in the browser's sandbox (HTML, text, SVG)
      fetched and served by testor with its `sandbox` policy.
    * The home is trimmed to `cacheMB`: the oldest stored runs lose their local files first.
    * Alone, a testor restores its runs' records from the bucket when it starts on an empty
      home. With `TESTOR_DATABASE_URL`, testors share no volume at all: the run index and the
      live events go through PostgreSQL (`Testor.Storage.Shared`).

  The run's keys are those its paths have in the home: `runs/<id>.json`, `logs/<id>.log`,
  `screenshots/<id>/...`, `artifacts/<id>/...`, `reports/<id>/...` with `reports/<id>.*.json`,
  `attestations/<id>.dsse.json` and `attestations/<id>.agent.dsse.json`.
  """
  use GenServer
  require Logger
  alias Testor.{Blob, Config, Files}

  @key {__MODULE__, :config}
  @listings :testor_storage_listings
  @trim_ms 600_000
  @presign_seconds 300

  # --- configuration -------------------------------------------------------------------------

  @doc "The storage config from config.json: `%{type: :files}`, an S3 bucket's or an Azure container's (logged when not valid)."
  def read_config do
    case Config.user()["storage"] do
      nil ->
        %{type: :files}

      %{"type" => "files"} ->
        %{type: :files}

      %{"type" => type} = raw when type in ["s3", "azure"] ->
        adapter = if type == "azure", do: Blob.Azure, else: Blob.S3

        case adapter.config(raw) do
          {:ok, s3} ->
            cache = raw["cacheMB"]

            Map.merge(s3, %{
              type: String.to_existing_atom(type),
              presign: raw["presign"] != false,
              cache_bytes: if(is_integer(cache) and cache > 0, do: cache, else: 2048) * 1_048_576
            })

          {:error, why} ->
            invalid(why)
        end

      _ ->
        invalid(~s(type is "files", "s3" or "azure"))
    end
  end

  defp invalid(why) do
    Logger.error("storage: config.json's storage is not valid (#{why}): runs stay in the home only")
    %{type: :files}
  end

  @doc "The storage in use, as it was when testor started (`configure/1` in tests)."
  def config, do: :persistent_term.get(@key, %{type: :files})

  @doc false
  def configure(cfg), do: :persistent_term.put(@key, cfg)

  @doc "Whether runs are kept in a bucket (S3-compatible, or an Azure Blob container)."
  def s3?, do: config().type in [:s3, :azure]

  @doc "The adapter of a bucket's config."
  def adapter_for(%{type: :azure}), do: Blob.Azure
  def adapter_for(_cfg), do: Blob.S3

  @doc "S3 with PostgreSQL: testors that share no volume (`Testor.Storage.Shared`)."
  def shared?,
    do: s3?() and Testor.Jobs.Postgres.enabled?() and Application.get_env(:testor, :storage_shared, true)

  @doc "The store's adapter and its config: the bucket, or the home as a folder."
  def blob, do: {adapter(), blob_cfg()}

  defp adapter, do: if(s3?(), do: adapter_for(config()), else: Blob.Files)
  defp blob_cfg, do: if(s3?(), do: config(), else: %{root: Config.data_dir()})

  # --- the run's keys ------------------------------------------------------------------------

  @doc "The file in the home a key is cached as."
  def local_path(key), do: Path.join(Config.data_dir(), key)

  @doc "The run's keys as they are in the home now: `[{key, path}]`."
  def local_keys(id) do
    singles =
      [
        "runs/#{id}.json",
        "logs/#{id}.log",
        "logs/#{id}.streams",
        "attestations/#{id}.dsse.json",
        "attestations/#{id}.agent.dsse.json"
      ] ++
        for(kind <- ["mutation", "tests", "specs", "coverage"], do: "reports/#{id}.#{kind}.json")

    trees =
      for area <- ["screenshots", "artifacts", "reports"],
          file <- Files.walk(local_path("#{area}/#{id}")),
          do: "#{area}/#{id}/" <> String.replace(file.rel, "\\", "/")

    for key <- singles ++ trees,
        match?({:file, _, _}, Files.entry(local_path(key))),
        do: {key, local_path(key)}
  end

  @doc false
  # The run's keys in the bucket, each area listed once.
  def stored_keys(id, adapter \\ adapter(), cfg \\ blob_cfg()) do
    prefixes = [
      "runs/#{id}.",
      "logs/#{id}.",
      "attestations/#{id}.",
      "reports/#{id}",
      "screenshots/#{id}/",
      "artifacts/#{id}/"
    ]

    Enum.reduce_while(prefixes, {:ok, []}, fn prefix, {:ok, acc} ->
      case adapter.list(cfg, prefix) do
        {:ok, objects} -> {:cont, {:ok, acc ++ objects}}
        error -> {:halt, error}
      end
    end)
  end

  # --- publishing ----------------------------------------------------------------------------

  @doc """
  Uploads finished run `id`'s files that the bucket does not hold yet (by key and size), then
  its record with `"stored": true`: `{:ok, run}`, `:off` with files, or `{:error, why}`.
  """
  def publish(id) do
    with true <- s3?() || :off,
         %{} = run <- Testor.Store.get(id) || {:error, "no such run"},
         {:ok, stored} <- stored_keys(id),
         :ok <- upload(id, Map.new(stored, &{&1.key, &1.size})) do
      run = Map.put(run, "stored", true)
      Files.write_json(local_path("runs/#{id}.json"), run)

      with :ok <- adapter().put(blob_cfg(), "runs/#{id}.json", {:file, local_path("runs/#{id}.json")}) do
        Testor.Store.refresh(id)
        # The finished log is one object now: its live segments go (Testor.Storage.Shared).
        if shared?(), do: Testor.Storage.Shared.compact(id)
        Logger.info("storage: #{id} stored in #{config().bucket}")
        {:ok, run}
      end
    end
  end

  defp upload(id, stored) do
    id
    |> local_keys()
    |> Enum.reject(fn {key, path} -> key == "runs/#{id}.json" or stored[key] == Files.size(path) end)
    |> Enum.reduce_while(:ok, fn {key, path}, :ok ->
      case adapter().put(blob_cfg(), key, {:file, path}) do
        :ok -> {:cont, :ok}
        {:error, why} -> {:halt, {:error, "#{key}: #{why}"}}
      end
    end)
  end

  @doc "Puts one file of a running run (an agent's screenshot, artifact or report) in the bucket now."
  def put_now(key) do
    if s3?(), do: adapter().put(blob_cfg(), key, {:file, local_path(key)}), else: :ok
  end

  @doc """
  Fetches the files of run `id` the bucket holds and the home does not, sent through other
  testors: to finish it (`:finish`: its log and reports) or to sign it (`:all`).
  """
  def gather(id, scope) do
    if shared?(), do: Testor.Storage.Shared.catch_up(id)

    with true <- s3?() || :ok,
         {:ok, stored} <- stored_keys(id) do
      for %{key: key, size: size} <- stored,
          scope == :all or not String.starts_with?(key, ["screenshots/", "artifacts/"]),
          Files.size(local_path(key)) != size,
          do: fetch(key)
    end

    :ok
  end

  # --- reading -------------------------------------------------------------------------------

  @doc """
  Makes sure the home holds stored run `id`'s log, reports and attestations, fetching what it
  lacks (once: a marker in `cache/` remembers it). Nothing happens with files, or for a run that
  is not stored.
  """
  def local(id) do
    marker = local_path("cache/#{id}")

    with true <- s3?(),
         %{"stored" => true} <- Testor.Store.get(id),
         false <- File.regular?(marker),
         {:ok, stored} <- stored_keys(id) do
      for %{key: key, size: size} <- stored,
          not String.starts_with?(key, ["screenshots/", "artifacts/"]),
          Files.size(local_path(key)) != size,
          do: fetch(key)

      File.mkdir_p!(Path.dirname(marker))
      File.write!(marker, "")
    end

    :ok
  end

  defp fetch(key) do
    case adapter().get(blob_cfg(), key, {:file, local_path(key)}) do
      :ok -> :ok
      other -> Logger.warning("storage: #{key} could not be fetched: #{inspect(other)}")
    end
  end

  @doc """
  A stored run's files in an area (`"screenshots"`, `"artifacts"`) as a walk lists them
  (`%{rel, size, mtime}`), with the ones in the home: none with files. A finished run's
  listing is kept in memory.
  """
  def listing(id, area) do
    if s3?() do
      remote =
        case :ets.lookup(@listings, {id, area}) do
          [{_, entries}] -> entries
          [] -> list_area(id, area)
        end

      local = Files.walk(local_path("#{area}/#{id}"))
      names = MapSet.new(local, &String.replace(&1.rel, "\\", "/"))
      local ++ Enum.reject(remote, &MapSet.member?(names, &1.rel))
    else
      Files.walk(local_path("#{area}/#{id}"))
    end
  end

  defp list_area(id, area) do
    prefix = "#{area}/#{id}/"

    case adapter().list(blob_cfg(), prefix) do
      {:ok, objects} ->
        entries =
          for o <- objects,
              do: %{rel: String.replace_prefix(o.key, prefix, ""), full: nil, size: o.size, mtime: nil}

        if match?(%{"stored" => true}, Testor.Store.get(id)),
          do: :ets.insert(@listings, {{id, area}, entries})

        entries

      {:error, why} ->
        Logger.warning("storage: #{prefix} cannot be listed: #{inspect(why)}")
        []
    end
  end

  @doc """
  How a file the home lacks is served: `{:redirect, url}` (a presigned link, for images,
  videos and downloads), `{:file, path}` once fetched (what the browser shows in a sandbox),
  or `:not_found`. `inline` is the content type to show it with, nil for a download.
  """
  def serve(key, inline) do
    cfg = config()

    media =
      is_binary(inline) and String.starts_with?(inline, ["image/", "video/", "audio/"]) and
        inline != "image/svg+xml"

    opts =
      if inline,
        do: [type: inline],
        else: [filename: key |> Path.basename() |> String.replace(~r/[^\w.-]/u, "_")]

    with true <- (s3?() and listed?(key)) || :not_found,
         true <- cfg.presign and (media or inline == nil),
         {:ok, url} <- adapter().presign(cfg, key, @presign_seconds, opts) do
      {:redirect, url}
    else
      :not_found -> :not_found
      _ -> fetched(key)
    end
  end

  # Only what the run's listing holds is served: a presigned link to nothing is never made.
  defp listed?(key) do
    case String.split(key, "/", parts: 3) do
      [area, id, rel] -> Enum.any?(listing(id, area), &(String.replace(&1.rel, "\\", "/") == rel))
      _ -> false
    end
  end

  defp fetched(key) do
    case adapter().get(blob_cfg(), key, {:file, local_path(key)}) do
      :ok -> {:file, local_path(key)}
      _ -> :not_found
    end
  end

  # --- removal -------------------------------------------------------------------------------

  @doc "Deletes run `id`'s objects from the bucket (a deleted run): what Object Lock keeps stays."
  def delete(id) do
    :ets.delete(@listings, {id, "screenshots"})
    :ets.delete(@listings, {id, "artifacts"})
    File.rm(local_path("cache/#{id}"))

    if shared?(), do: Testor.Storage.Shared.compact(id)

    with true <- s3?() || :ok,
         {:ok, stored} <- stored_keys(id),
         {:ok, _deleted, _kept} <- adapter().delete(blob_cfg(), Enum.map(stored, & &1.key)) do
      :ok
    end
  end

  # --- the cache -----------------------------------------------------------------------------

  @doc """
  Frees the home down to `cacheMB`: the local files of the oldest stored, finished runs go
  first (their records stay). The bytes freed.
  """
  def trim do
    if s3?() do
      runs =
        for run <- Testor.Store.all(), run["stored"] == true, run["status"] != "running" do
          keys = local_keys(run["id"]) |> Enum.reject(fn {key, _} -> String.starts_with?(key, "runs/") end)
          {run["id"], keys, keys |> Enum.map(fn {_, path} -> Files.size(path) end) |> Enum.sum()}
        end

      total = runs |> Enum.map(&elem(&1, 2)) |> Enum.sum()

      runs
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({total, 0}, fn {id, keys, bytes}, {left, freed} ->
        if left <= config().cache_bytes do
          {:halt, {left, freed}}
        else
          Enum.each(keys, fn {_, path} -> File.rm(path) end)

          for area <- ["screenshots", "artifacts", "reports"],
              do: File.rm_rf(local_path("#{area}/#{id}"))

          File.rm(local_path("cache/#{id}"))
          {:cont, {left - bytes, freed + bytes}}
        end
      end)
      |> elem(1)
    else
      0
    end
  end

  # --- server --------------------------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    if :ets.whereis(@listings) == :undefined,
      do: :ets.new(@listings, [:named_table, :public, read_concurrency: true])

    cfg = read_config()
    configure(cfg)

    if cfg.type in [:s3, :azure] do
      Logger.info("storage: runs are stored in #{cfg.bucket}")
      if not Testor.Jobs.Postgres.enabled?(), do: restore()
      Process.send_after(self(), :trim, @trim_ms)
    end

    {:ok, nil}
  end

  @impl true
  def handle_info(:trim, state) do
    freed = trim()
    if freed > 0, do: Logger.info("storage: #{div(freed, 1_048_576)} MB of stored runs freed from the home")
    Process.send_after(self(), :trim, @trim_ms)
    {:noreply, state}
  end

  @doc "Fetches the records of stored runs the home lacks (a testor alone, on an empty home)."
  def restore do
    case adapter().list(blob_cfg(), "runs/") do
      {:ok, objects} ->
        missing =
          for %{key: key} <- objects,
              Regex.match?(~r/^runs\/\d{8}-\d{6}-[0-9a-f]{6}\.json$/, key),
              not File.regular?(local_path(key)),
              do: key

        missing
        |> Task.async_stream(&fetch/1, max_concurrency: 16, timeout: 60_000)
        |> Stream.run()

        if missing != [], do: Logger.info("storage: #{length(missing)} runs restored from #{config().bucket}")
        :ok

      {:error, why} ->
        Logger.error("storage: the bucket's runs cannot be listed (#{inspect(why)}): none restored")
        :error
    end
  end
end
