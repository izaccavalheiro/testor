defmodule Testor.Badge do
  @moduledoc """
  Status badges: the latest result of a project (or one task of it) as an SVG to embed in a
  README, a wiki or a Backstage entity page: `GET /api/v1/projects/<p>/badge.svg?kind=test`.

  A badge needs the `read` scope like the rest of the API, unless config.json lists the project
  in `publicBadges` (`["web", "docs"]`): its badge then answers without credentials, as a
  public repository's CI badge does. It shows one word (passed, failed...), nothing else.

  `?metric=mutation` shows the latest mutation score instead (`87.5%`, of the latest run that
  has one), `?metric=coverage` the latest line coverage: green from 80, orange from 60, red
  below.
  """
  alias Testor.{Config, Store}

  @colors %{
    "passed" => "#2e7d32",
    "failed" => "#c62828",
    "running" => "#1565c0",
    "cancelled" => "#757575",
    "aborted" => "#757575"
  }

  @doc "Whether `project`'s badge is public (config.json's `publicBadges`)."
  def public?(project) do
    case Config.user()["publicBadges"] do
      list when is_list(list) -> project in list
      _ -> false
    end
  end

  @doc "The badge of `project`'s latest run (of `kind` when given), or its mutation score."
  def svg(project, kind, metric \\ nil)

  def svg(project, kind, metric) when metric in ["mutation", "coverage"] do
    path = if metric == "mutation", do: ["mutation", "score"], else: ["coverage", "lines"]

    score =
      Enum.find_value(Store.all(), fn run ->
        run["project"] == project and (kind == nil or run["kind"] == kind) and
          get_in(run, path)
      end)

    {message, color} =
      cond do
        not is_number(score) -> {"no score", "#757575"}
        score >= 80 -> {"#{score}%", "#2e7d32"}
        score >= 60 -> {"#{score}%", "#e65100"}
        true -> {"#{score}%", "#c62828"}
      end

    render(metric, message, color)
  end

  def svg(project, kind, _metric) do
    latest =
      Enum.find(Store.all(), &(&1["project"] == project and (kind == nil or &1["kind"] == kind)))

    status = (latest && latest["status"]) || "no runs"
    render(kind || "tests", status, Map.get(@colors, status, "#757575"))
  end

  @doc "A flat badge: `label` on grey, `message` on `color`."
  def render(label, message, color) do
    {label, message} = {String.slice(label, 0, 60), String.slice(message, 0, 60)}
    {left, right} = {width(label), width(message)}
    total = left + right
    {label, message} = {escape(label), escape(message)}

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{total}" height="20" role="img" aria-label="#{label}: #{message}">
    <title>#{label}: #{message}</title>
    <linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
    <clipPath id="r"><rect width="#{total}" height="20" rx="3" fill="#fff"/></clipPath>
    <g clip-path="url(#r)"><rect width="#{left}" height="20" fill="#555"/><rect x="#{left}" width="#{right}" height="20" fill="#{color}"/><rect width="#{total}" height="20" fill="url(#s)"/></g>
    <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
    <text x="#{div(left, 2)}" y="14">#{label}</text><text x="#{left + div(right, 2)}" y="14">#{message}</text>
    </g>
    </svg>
    """
  end

  # Verdana 11px is about 7 pixels a character; 10 of padding.
  defp width(text), do: String.length(text) * 7 + 10

  defp escape(text), do: text |> String.slice(0, 60) |> Plug.HTML.html_escape()
end
