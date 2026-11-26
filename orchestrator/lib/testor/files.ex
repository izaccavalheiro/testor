defmodule Testor.Files do
  @moduledoc "File helpers: JSON records, tails of logs, directory walks, screenshots and artifacts."
  alias Testor.{Config, SpecParser}

  @images %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }

  def image_type(path), do: Map.get(@images, path |> Path.extname() |> String.downcase())

  # What /artifacts serves inline; anything else is a download (application/octet-stream).
  @text "text/plain; charset=utf-8"
  @served Map.merge(@images, %{
            ".html" => "text/html; charset=utf-8",
            ".htm" => "text/html; charset=utf-8",
            ".css" => "text/css; charset=utf-8",
            ".js" => "text/javascript; charset=utf-8",
            ".mjs" => "text/javascript; charset=utf-8",
            ".json" => "application/json",
            ".map" => "application/json",
            ".svg" => "image/svg+xml",
            ".ico" => "image/x-icon",
            ".webm" => "video/webm",
            ".mp4" => "video/mp4",
            ".woff" => "font/woff",
            ".woff2" => "font/woff2",
            ".ttf" => "font/ttf",
            ".pdf" => "application/pdf",
            ".md" => @text,
            ".txt" => @text,
            ".log" => @text,
            ".xml" => @text,
            ".csv" => @text,
            ".lcov" => @text,
            ".info" => @text
          })

  @doc "The content type /artifacts serves a file with, or nil for a download."
  def served_type(path), do: Map.get(@served, path |> Path.extname() |> String.downcase())

  @doc "How the dashboard shows an artifact file: video, image, html, text or file."
  def artifact_kind(path) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      ext in [".webm", ".mp4"] -> "video"
      Map.has_key?(@images, ext) or ext == ".svg" -> "image"
      ext in [".html", ".htm"] -> "html"
      Map.get(@served, ext) == @text or ext == ".json" -> "text"
      true -> "file"
    end
  end

  def read_json(path) do
    with {:file, _, _} <- entry(path),
         {:ok, text} <- File.read(path),
         {:ok, data} when is_map(data) <- JSON.decode(Config.strip_bom(text)) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  def write_json(path, data) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, JSON.encode!(data))
    File.rename!(tmp, path)
  end

  @doc "The size of a regular file; 0 for anything else, a symbolic link included."
  def size(path) do
    case entry(path) do
      {:file, size, _} -> size
      _ -> 0
    end
  end

  @doc "The modification time of a file or a folder; nil for anything else, a symbolic link included."
  def mtime(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: type, mtime: mtime}} when type in [:regular, :directory] -> mtime
      _ -> nil
    end
  end

  @doc "Bytes `from`..`to` of a file (at most `max` bytes, from the end), without ANSI codes."
  def tail(path, max, to \\ nil) do
    to = to || size(path)
    from = max(0, to - max)

    with {:ok, io} <- File.open(path, [:read, :binary]),
         {:ok, data} <- read_at(io, from, to - from) do
      File.close(io)
      text = if from > 0, do: drop_partial_line(data), else: data
      %{text: clean(text), size: to, truncated: from > 0}
    else
      _ -> %{text: "", size: 0, truncated: false}
    end
  end

  def read_at(_io, _from, 0), do: {:ok, ""}

  def read_at(io, from, length) do
    case :file.pread(io, from, length) do
      {:ok, data} -> {:ok, data}
      :eof -> {:ok, ""}
      error -> error
    end
  end

  @doc "Strips ANSI codes and carriage returns and replaces invalid UTF-8, for JSON and browsers."
  def clean(text) do
    text = if String.valid?(text), do: text, else: String.replace_invalid(text)
    text |> SpecParser.strip_ansi() |> String.replace("\r", "")
  end

  defp drop_partial_line(data) do
    case :binary.match(data, "\n") do
      {pos, 1} -> binary_part(data, pos + 1, byte_size(data) - pos - 1)
      :nomatch -> data
    end
  end

  @doc "The names in `dir`; none when it is nil, missing or not a folder."
  def ls(nil), do: []

  def ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      _ -> []
    end
  end

  @doc "Every file under `dir`: %{full, rel, size, mtime}."
  def walk(dir), do: walk(dir, dir)

  # Symbolic links (and junctions) are never followed: a run could point one at testor's
  # secrets, or at a parent folder to make the walk endless.
  defp walk(dir, base) do
    Enum.flat_map(ls(dir), fn name ->
      full = Path.join(dir, name)

      case entry(full) do
        {:file, size, mtime} -> [%{full: full, rel: Path.relative_to(full, base), size: size, mtime: mtime}]
        :dir -> walk(full, base)
        :skip -> []
      end
    end)
  end

  @doc "What a walk does with a path, without following links: `{:file, size, mtime}`, `:dir` or `:skip`."
  def entry(path), do: path |> File.lstat(time: :posix) |> kind()

  @doc false
  def kind({:ok, %{type: :regular, size: size, mtime: mtime}}), do: {:file, size, mtime}
  def kind({:ok, %{type: :directory}}), do: :dir
  def kind(_), do: :skip

  @doc """
  Whether `segments` under `root` name a path without a symbolic link (or junction) in it:
  files are served only from inside testor's folders.
  """
  def no_links?(root, segments) do
    segments
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.all?(&(File.lstat(&1) |> kind() != :skip))
  end

  def iso(nil), do: nil
  def iso(posix), do: posix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  @doc "A run's screenshots, each matched to a spec when its path names one."
  def screenshots(id, specs \\ []) do
    prefix = Testor.Auth.file_prefix(id)

    id
    |> Testor.Storage.listing("screenshots")
    |> Enum.filter(&image_type(&1.rel))
    |> Enum.sort_by(& &1.rel)
    |> Enum.map(fn file ->
      %{
        "path" => file.rel,
        "url" =>
          prefix <>
            "/shots/" <>
            Enum.map_join(
              [id | Path.split(file.rel)],
              "/",
              &URI.encode(&1, fn c -> URI.char_unreserved?(c) end)
            ),
        "bytes" => file.size,
        "takenAt" => iso(file.mtime),
        "spec" => SpecParser.spec_of(file.rel, specs)
      }
    end)
  end

  @max_artifacts 500

  @doc """
  A run's artifacts: every file, except that a folder holding an index.html (an HTML report:
  coverage, Playwright, Vitest) is one `report` entry that links to its index.html. At most
  #{@max_artifacts} entries, sorted by path.
  """
  def artifacts(id) do
    base_url = Testor.Auth.file_prefix(id) <> "/artifacts/" <> encode(id)
    id |> Testor.Storage.listing("artifacts") |> artifact_entries(base_url)
  end

  @doc false
  def list_artifacts(root, base_url), do: root |> walk() |> artifact_entries(base_url)

  defp artifact_entries(files, base_url) do
    files
    |> Enum.map(&%{&1 | rel: String.replace(&1.rel, "\\", "/")})
    |> group_artifacts()
    |> Enum.sort_by(& &1.rel)
    |> Enum.take(@max_artifacts)
    |> Enum.map(fn entry ->
      %{
        "path" => entry.rel,
        "kind" => entry.kind,
        "url" => base_url <> "/" <> url_path(entry.target),
        "bytes" => entry.size,
        "files" => entry.files,
        "modifiedAt" => iso(entry.mtime)
      }
    end)
  end

  # A folder below the root that holds an index.html is one report: the highest such folder
  # takes in every file under it.
  defp group_artifacts(files) do
    reports =
      for file <- files,
          Path.basename(file.rel) == "index.html",
          (dir = Path.dirname(file.rel)) != ".",
          into: MapSet.new(),
          do: dir

    {singles, grouped} =
      Enum.reduce(files, {[], %{}}, fn file, {singles, grouped} ->
        case Enum.find(ancestors(file.rel), &MapSet.member?(reports, &1)) do
          nil ->
            entry = %{
              rel: file.rel,
              target: file.rel,
              kind: artifact_kind(file.rel),
              size: file.size,
              files: 1,
              mtime: file.mtime
            }

            {[entry | singles], grouped}

          dir ->
            {singles, Map.update(grouped, dir, [file], &[file | &1])}
        end
      end)

    singles ++
      for {dir, list} <- grouped do
        %{
          rel: dir,
          target: dir <> "/index.html",
          kind: "report",
          size: list |> Enum.map(& &1.size) |> Enum.sum(),
          files: length(list),
          mtime: list |> Enum.map(& &1.mtime) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
        }
      end
  end

  # "a/b/c.txt" -> ["a", "a/b"]: the folders above a file, highest first.
  defp ancestors(rel) do
    rel |> String.split("/") |> Enum.drop(-1) |> Enum.scan(&(&2 <> "/" <> &1))
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
  defp url_path(rel), do: rel |> Path.split() |> Enum.map_join("/", &encode/1)

  @doc "Files and bytes under `dir`."
  def usage(dir) do
    files = walk(dir)
    %{"files" => length(files), "bytes" => files |> Enum.map(& &1.size) |> Enum.sum()}
  end

  @doc """
  The part of a file of `size` bytes a `Range` header asks for: `:all`, `{offset, length}` or
  `:unsatisfiable`. Only single byte ranges are honoured; anything else gets the whole file.
  """
  def parse_range(header, size) when is_binary(header) and size > 0 do
    with "bytes=" <> spec <- String.trim(header),
         [one] <- String.split(spec, ",") do
      case String.split(String.trim(one), "-", parts: 2) do
        ["", suffix] ->
          case Integer.parse(suffix) do
            {n, ""} when n > 0 -> {max(size - n, 0), min(n, size)}
            _ -> :all
          end

        [first, last] ->
          with {from, ""} when from >= 0 <- Integer.parse(first),
               {:ok, to} <- range_end(last, size) do
            cond do
              from >= size -> :unsatisfiable
              to < from -> :all
              true -> {from, to - from + 1}
            end
          else
            _ -> :all
          end

        _ ->
          :all
      end
    else
      _ -> :all
    end
  end

  def parse_range(_header, _size), do: :all

  defp range_end("", size), do: {:ok, size - 1}

  defp range_end(last, size) do
    case Integer.parse(last) do
      {to, ""} when to >= 0 -> {:ok, min(to, size - 1)}
      _ -> :error
    end
  end

  @doc "Specs of a finished run, from its whole log."
  def log_specs(id) do
    path = Config.log_file(id)

    with {:file, _, _} <- entry(path), {:ok, text} <- File.read(path) do
      SpecParser.parse(text)
    else
      _ -> []
    end
  end
end
