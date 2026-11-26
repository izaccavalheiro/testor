defmodule Testor.States do
  @moduledoc """
  The incremental state store: files a tool keeps from one run to the next (Stryker's
  incremental file, coverage baselines, test timings), per project and branch, so they follow a
  branch from one agent to another.

  `GET /api/v1/projects/:p/state/:name?branch=b` reads one, falling back to the default
  branch's (`state.defaultBranch`) on a branch's first run; `PUT` writes it, only for an agent
  holding a job of that project. The agent restores the paths a command's `"state"` lists before
  it runs, and saves them after.

  Keys (`Testor.Storage`): `state/<project>/<branch, base64url>/<name>`. Values are
  `state.maxMB` at most; the janitor deletes a branch's states not written for
  `state.keepDays`, never the default branch's. State is data the next run reads: it is scoped
  to its project and branch, so another project's job cannot write it.
  """
  alias Testor.{Config, Storage}

  @name ~r/\A[A-Za-z0-9_.-]{1,100}\z/
  @day 86_400

  def settings, do: Config.retention()["state"]

  @doc "Whether `name` names a state: letters, digits, `_ . -`, not only dots."
  def name?(name), do: is_binary(name) and Regex.match?(@name, name) and String.trim(name, ".") != ""

  defp key(project, branch, name), do: "state/#{project}/#{Base.url_encode64(branch, padding: false)}/#{name}"

  @doc """
  State `name` of `project` on `branch`, else on the default branch: `{:ok, data, branch}` or
  `:not_found`.
  """
  def get(project, branch, name) do
    {adapter, cfg} = Storage.blob()
    default = settings()["defaultBranch"]

    [branch, default]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value(:not_found, fn branch ->
      case adapter.get(cfg, key(project, branch, name), :binary) do
        {:ok, data} -> {:ok, data, branch}
        _ -> nil
      end
    end)
  end

  @doc "Writes state `name` of `project` on `branch`: `:ok`, `{:error, :too_large}` or the store's error."
  def put(project, branch, name, data) do
    if byte_size(data) > settings()["maxMB"] * 1_048_576 do
      {:error, :too_large}
    else
      {adapter, cfg} = Storage.blob()
      adapter.put(cfg, key(project, branch, name), data)
    end
  end

  @doc "Deletes the states of branches other than the default not written for `state.keepDays`: how many."
  def sweep(now \\ System.os_time(:second)) do
    {adapter, cfg} = Storage.blob()
    cfg_state = settings()
    default = Base.url_encode64(cfg_state["defaultBranch"], padding: false)
    age = cfg_state["keepDays"] * @day

    with {:ok, states} <- adapter.list(cfg, "state/"),
         old =
           for(
             %{key: key, modified: at} <- states,
             is_integer(at) and now - at > age,
             match?([_, _, branch, _] when branch != default, String.split(key, "/")),
             do: key
           ),
         {:ok, deleted, _} <- adapter.delete(cfg, old) do
      length(deleted)
    else
      _ -> 0
    end
  end
end
