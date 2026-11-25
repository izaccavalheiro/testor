defmodule Testor.Cron do
  @moduledoc """
  Cron expressions of five fields (minute, hour, day of month, month, day of week), in UTC:
  `*`, numbers, ranges `a-b`, lists `a,b`, steps `*/n` and `a-b/n`; days of the week 0 to 7 (0
  and 7 are Sunday). As in cron, when both the day of the month and the day of the week are
  restricted, a day matching either one matches. Shorthands: `@hourly`, `@daily`, `@weekly`,
  `@monthly`, `@yearly`.
  """

  @fields [minute: 0..59, hour: 0..23, day: 1..31, month: 1..12, weekday: 0..7]
  @shorthands %{
    "@hourly" => "0 * * * *",
    "@daily" => "0 0 * * *",
    "@weekly" => "0 0 * * 0",
    "@monthly" => "0 0 1 * *",
    "@yearly" => "0 0 1 1 *",
    "@annually" => "0 0 1 1 *"
  }

  @doc "A parsed expression, or why it is not one."
  def parse(expression) when is_binary(expression) do
    expression = Map.get(@shorthands, String.trim(expression), expression)

    with parts when length(parts) == 5 <- String.split(expression, ~r/\s+/, trim: true),
         {:ok, sets} <- parse_fields(Enum.zip(@fields, parts)) do
      spec = Map.new(sets)
      # Sunday is 0 and 7.
      weekday = if 7 in spec.weekday, do: MapSet.put(spec.weekday, 0), else: spec.weekday

      {:ok,
       %{
         spec
         | weekday: MapSet.delete(weekday, 7)
       }
       |> Map.put(:any_day, hd(Enum.drop(parts, 2)) == "*")
       |> Map.put(:any_weekday, List.last(parts) == "*")}
    else
      {:error, why} -> {:error, why}
      _ -> {:error, "a cron expression has five fields: minute hour day month weekday"}
    end
  end

  def parse(_), do: {:error, "a cron expression is a string"}

  defp parse_fields(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn {{name, range}, text}, {:ok, acc} ->
      case parse_field(text, range) do
        {:ok, set} -> {:cont, {:ok, [{name, set} | acc]}}
        :error -> {:halt, {:error, "#{name} #{inspect(text)} is not valid (#{range.first}-#{range.last})"}}
      end
    end)
  end

  defp parse_field(text, range) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, set} ->
      case part_values(part, range) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(set, MapSet.new(values))}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp part_values(part, range) do
    {base, step} =
      case String.split(part, "/") do
        [base] -> {base, "1"}
        [base, step] -> {base, step}
        _ -> {nil, nil}
      end

    with {step, ""} when step > 0 <- Integer.parse(step || ""),
         {:ok, first, last} <- bounds(base, range),
         true <- first in range and last in range and first <= last do
      {:ok, Enum.take_every(first..last, step)}
    else
      _ -> :error
    end
  end

  defp bounds("*", range), do: {:ok, range.first, range.last}

  defp bounds(text, _range) when is_binary(text) do
    case String.split(text, "-") do
      [single] -> with {:ok, n} <- int(single), do: {:ok, n, n}
      [first, last] -> with {:ok, a} <- int(first), {:ok, b} <- int(last), do: {:ok, a, b}
      _ -> :error
    end
  end

  defp int(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  @doc "Whether `datetime` (UTC, to the minute) matches."
  def matches?(spec, %DateTime{} = at) do
    at.minute in spec.minute and at.hour in spec.hour and day?(spec, DateTime.to_date(at))
  end

  defp day?(spec, date) do
    day = date.day in spec.day
    week = rem(Date.day_of_week(date), 7) in spec.weekday

    date.month in spec.month and
      cond do
        spec.any_day and spec.any_weekday -> true
        spec.any_day -> week
        spec.any_weekday -> day
        true -> day or week
      end
  end

  @doc "The first minute after `from` that matches, within a year and a day (nil if none: 30 February)."
  def next(spec, %DateTime{} = from) do
    start = %{from | second: 0, microsecond: {0, 0}} |> DateTime.add(60, :second)
    first = DateTime.to_date(start)
    times = for hour <- Enum.sort(spec.hour), minute <- Enum.sort(spec.minute), do: Time.new!(hour, minute, 0)

    Enum.find_value(0..366, fn offset ->
      date = Date.add(first, offset)

      if day?(spec, date) do
        Enum.find_value(times, fn time ->
          at = DateTime.new!(date, time, "Etc/UTC")
          if DateTime.compare(at, start) != :lt, do: at
        end)
      end
    end)
  end
end
