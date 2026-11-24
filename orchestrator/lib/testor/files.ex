defmodule Testor.Files do
  @moduledoc "File helpers: JSON records, tails of logs, directory walks and screenshots."
  alias Testor.{Config, SpecParser}

  @images %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }

  def image_type(path), do: Map.get(@images, path |> Path.extname() |> String.downcase())

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

  @doc "Specs of a finished run, from its whole log."
  def log_specs(id) do
    case File.read(Config.log_file(id)) do
      {:ok, text} -> SpecParser.parse(text)
      _ -> []
    end
  end
end
