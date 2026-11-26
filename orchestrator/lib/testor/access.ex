defmodule Testor.Access do
  @moduledoc """
  Which projects a request may see. A user in `auth.json` may list `projects` (names, `*` as a
  wildcard: `["web", "lib-*"]`); without the list, every project. Tokens carry their user's.

  Applied everywhere data of a project leaves testor:

    * a run, job or project named in the path (`/api/v1/runs/<id>/...`, `/events/runs/<id>`,
      `/shots/<id>/...`, ...) of a project the request may not see answers `404`, as if it did
      not exist (`plug/2`);
    * lists (runs, projects, jobs, galleries, the dashboard's state, MCP's tools) leave out
      the others, before paging;
    * event streams drop the others' events;
    * what spans every project (maintenance, the audit trail, metrics, PowerShell sessions,
      the agents' keys) needs access to every project: `403` otherwise.

  An agent user restricted to projects only takes their jobs.

  A user may also hold **a role per project** (`"projects": {"web*": "operator", "docs":
  "viewer"}`): what a request does to a project it names (cancelling a run, queuing a job,
  taking one) needs a scope that project's roles grant (`permits?/3`, `403` otherwise), and
  lists show the projects one of its roles may read. A token still carries no more than the
  scopes asked for.
  """
  import Plug.Conn
  alias Testor.{Jobs, Store}
  alias Testor.Web.Reply

  @doc "The projects of a principal: `nil` for all of them, else a list of patterns."
  def projects(%{projects: projects}) when is_list(projects), do: projects
  def projects(_principal), do: nil

  def restricted?(principal), do: projects(principal) != nil

  @doc "Whether `principal` may see `project`."
  def allowed?(principal, project) do
    cond do
      project_roles(principal) != nil -> permits?(principal, project, "read")
      projects(principal) == nil -> true
      true -> is_binary(project) and Enum.any?(projects(principal), &matches?(&1, project))
    end
  end

  @doc """
  Whether `principal` may act with `scope` on `project`: it holds the scope, and, with a role per
  project, a role of a pattern matching the project grants it.
  """
  def permits?(principal, project, scope) do
    held = principal |> Map.get(:scopes, []) |> Enum.member?(scope)

    case project_roles(principal) do
      nil ->
        held and allowed?(principal, project)

      roles ->
        held and is_binary(project) and
          Enum.any?(roles, &(scope in &1.scopes and matches?(&1.pattern, project)))
    end
  end

  @doc "The roles per project of a principal, or nil when its scopes apply to every project it sees."
  def project_roles(%{project_roles: roles}) when is_list(roles), do: roles
  def project_roles(_principal), do: nil

  @doc "A pattern (letters, digits, `_ . -`, and `*`), as the auth file holds them."
  def valid_pattern?(pattern), do: is_binary(pattern) and Regex.match?(~r/^[A-Za-z0-9_.*-]{1,100}$/, pattern)

  defp matches?(pattern, project) do
    regex = "^" <> (pattern |> Regex.escape() |> String.replace("\\*", ".*")) <> "$"
    Regex.match?(Regex.compile!(regex), project)
  end

  @doc "The items of `list` whose project (`project_of`, by default `item[\"project\"]`) `principal` may see."
  def filter(list, principal, project_of \\ & &1["project"]) do
    if restricted?(principal), do: Enum.filter(list, &allowed?(principal, project_of.(&1))), else: list
  end

  @doc "Whether an event of the global stream may go to `principal`."
  def event?(principal, name, data) do
    cond do
      not restricted?(principal) -> true
      name in ["run", "job", "approval"] -> allowed?(principal, data["project"])
      name == "live" -> allowed?(principal, run_project(data["id"]))
      name in ["sessions", "maintenance"] -> false
      true -> true
    end
  end

  @doc "The dashboard's state with what `principal` may see."
  def state(state, principal) do
    if restricted?(principal) do
      state
      |> Map.update("running", [], &filter(&1, principal))
      |> Map.update("history", [], &filter(&1, principal))
      |> Map.put("sessions", [])
      |> Map.delete("maintenance")
    else
      state
    end
  end

  defp run_project(id), do: get_in(Store.get(id) || %{}, ["project"])

  # --- the plug ----------------------------------------------------------------------------

  def init(opts), do: opts

  @doc "Refuses a request for something of a project its principal may not see (see the moduledoc)."
  def call(conn, _opts) do
    principal = conn.assigns[:principal]

    cond do
      not restricted?(principal) ->
        conn

      everywhere?(conn.path_info) ->
        refuse(conn, 403, "every_project", "this needs access to every project")

      not allowed_or_none?(principal, named_project(conn.path_info)) ->
        refuse(conn, 404, "not_found", "not found")

      not permitted_or_none?(conn, principal) ->
        scope = Testor.Web.Auth.required_scope(conn)

        refuse(
          conn,
          403,
          "forbidden",
          "#{Testor.Auth.who(principal)} lacks the #{scope} scope on that project"
        )

      true ->
        conn
    end
  end

  # With a role per project, the request's scope on the project it names.
  defp permitted_or_none?(conn, principal) do
    case {project_roles(principal), named_project(conn.path_info)} do
      {nil, _} -> true
      {_, :none} -> true
      {_, project} -> permits?(principal, project, Testor.Web.Auth.required_scope(conn))
    end
  end

  # What spans every project.
  defp everywhere?(path) do
    case path do
      ["metrics"] -> true
      ["api", "maintenance" | _] -> true
      ["api", "cleanup"] -> true
      ["api", "v1", area | _] when area in ["maintenance", "cleanup", "audit", "agents", "sessions"] -> true
      _ -> false
    end
  end

  # The project of the run, job or project a path names; :none when it names none.
  defp named_project(path) do
    case path do
      ["api", "runs", id | _] -> run_or_none(id)
      ["api", "v1", "runs", id | _] -> run_or_none(id)
      ["events", "runs", id | _] -> run_or_none(id)
      ["shots", id | _] -> run_or_none(id)
      ["artifacts", id | _] -> run_or_none(id)
      ["api", "v1", "jobs", id | _] -> job_or_none(id)
      ["api", "v1", "watches", id | _] -> job_or_none(id)
      ["api", "v1", "projects", project | _] -> project
      _ -> :none
    end
  end

  # Something that does not exist is left to its route (a 404 anyway).
  defp run_or_none(id), do: if(run = Store.get(id), do: run["project"], else: :none)
  defp job_or_none(id), do: if(job = Jobs.get(id), do: job["project"], else: :none)

  defp refuse(conn, status, code, message), do: conn |> Reply.error(status, code, message) |> halt()

  defp allowed_or_none?(_principal, :none), do: true
  defp allowed_or_none?(principal, project), do: allowed?(principal, project)
end
