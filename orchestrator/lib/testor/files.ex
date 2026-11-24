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
    with {:ok, text} <- File.read(path),
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

  def size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  def mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
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

  @doc "Every file under `dir`: %{full, rel, size, mtime}."
  def walk(dir), do: walk(dir, dir)

  defp walk(dir, base) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          full = Path.join(dir, name)

          case File.stat(full, time: :posix) do
            {:ok, %{type: :directory}} ->
              walk(full, base)

            {:ok, %{type: :regular, size: size, mtime: mtime}} ->
              [%{full: full, rel: Path.relative_to(full, base), size: size, mtime: mtime}]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  def iso(nil), do: nil
  def iso(posix), do: posix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  @doc "A run's screenshots, each matched to a spec when its path names one."
  def screenshots(id, specs \\ []) do
    Path.join(Config.shots_dir(), id)
    |> walk()
    |> Enum.filter(&image_type(&1.rel))
    |> Enum.sort_by(& &1.rel)
    |> Enum.map(fn file ->
      %{
        "path" => file.rel,
        "url" =>
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
  def artifacts(id), do: list_artifacts(Path.join(Config.artifacts_dir(), id), "/artifacts/" <> encode(id))

  @doc false
  def list_artifacts(root, base_url) do
    root
    |> collect_artifacts(root)
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

  defp collect_artifacts(dir, root) do
    case File.ls(dir) do
      {:ok, names} ->
        if dir != root and "index.html" in names do
          files = walk(dir)
          rel = Path.relative_to(dir, root)

          [
            %{
              rel: rel,
              target: Path.join(rel, "index.html"),
              kind: "report",
              size: files |> Enum.map(& &1.size) |> Enum.sum(),
              files: length(files),
              mtime: files |> Enum.map(& &1.mtime) |> Enum.max(fn -> nil end)
            }
          ]
        else
          Enum.flat_map(names, fn name ->
            full = Path.join(dir, name)

            case File.stat(full, time: :posix) do
              {:ok, %{type: :directory}} ->
                collect_artifacts(full, root)

              {:ok, %{type: :regular, size: size, mtime: mtime}} ->
                rel = Path.relative_to(full, root)
                [%{rel: rel, target: rel, kind: artifact_kind(rel), size: size, files: 1, mtime: mtime}]

              _ ->
                []
            end
          end)
        end

      _ ->
        []
    end
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
    case File.read(Config.log_file(id)) do
      {:ok, text} -> SpecParser.parse(text)
      _ -> []
    end
  end
end
