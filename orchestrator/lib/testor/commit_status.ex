defmodule Testor.CommitStatus do
  @moduledoc """
  Commit statuses: a run of a commit shows on its pull request, as CI's checks do. When a run
  whose `source.commit` testor knows (from a clean tree) starts, its commit gets a pending
  `testor/<kind>` status; when it ends, success or failure, with a link to the run.

  `statuses.json` in the secrets folder (it holds tokens: never set through the API):

      {"baseUrl": "https://testor.example.com",
       "providers": {
         "github": {"type": "github", "token": "github_pat_..."},
         "gitlab": {"type": "gitlab", "api": "https://gitlab.example.com/api/v4", "tokenEnv": "GITLAB_TOKEN"}},
       "projects": {
         "web": {"provider": "github", "repository": "acme/web"},
         "lib": {"provider": "gitlab", "repository": "acme/lib"}}}

  A GitHub token needs the commit statuses permission (`statuses: write` on a fine-grained token,
  or a GitHub App's); a GitLab one the `api` scope. `api` defaults to `https://api.github.com`
  and `https://gitlab.com/api/v4`; `tokenEnv` reads the token from that environment variable.
  A status is tried three times; one that fails is logged.
  """
  require Logger
  alias Testor.{Config, Store, Webhooks}

  def file, do: Path.join(Config.secrets_dir(), "statuses.json")

  @doc "Sets the status of run `id`'s commit, in the background, when its project has a provider."
  def notify(id) do
    with %{} = run <- Store.get(id),
         %{"commit" => commit} = source when is_binary(commit) <- run["source"],
         false <- source["dirty"] == true,
         {:ok, target} <- target(run["project"]) do
      backoff = Application.get_env(:testor, :status_backoff, [1_000, 5_000])
      Task.Supervisor.start_child(Testor.TaskSupervisor, fn -> deliver(target, commit, run, backoff) end)
      :ok
    else
      _ -> :ok
    end
  end

  @doc "Where `project`'s statuses go: `{:ok, %{type, api, token, repository, base}}` or `:none`."
  def target(project) do
    with {:ok, text} <- File.read(file()),
         {:ok, %{} = config} <- JSON.decode(Config.strip_bom(text)),
         %{"provider" => name, "repository" => repository} when is_binary(repository) <-
           get_in(config, ["projects", project]),
         %{"type" => type} = provider when type in ["github", "gitlab"] <- get_in(config, ["providers", name]),
         token when is_binary(token) and token != "" <- token(provider) do
      {:ok,
       %{
         type: type,
         api: String.trim_trailing(provider["api"] || default_api(type), "/"),
         token: token,
         repository: repository,
         base: if(is_binary(config["baseUrl"]), do: String.trim_trailing(config["baseUrl"], "/"))
       }}
    else
      _ -> :none
    end
  end

  defp token(%{"tokenEnv" => name}) when is_binary(name), do: System.get_env(name)
  defp token(provider), do: provider["token"]

  defp default_api("github"), do: "https://api.github.com"
  defp default_api("gitlab"), do: "https://gitlab.com/api/v4"

  @doc "The request that sets `run`'s status on `commit`: `{url, headers, body}`."
  def request(%{type: "github"} = target, commit, run) do
    url = "#{target.api}/repos/#{target.repository}/statuses/#{commit}"

    body =
      %{
        "state" => github_state(run["status"]),
        "context" => "testor/#{run["kind"]}",
        "description" => description(run)
      }
      |> with_link(target, run)

    {url,
     [
       {~c"authorization", String.to_charlist("Bearer " <> target.token)},
       {~c"accept", ~c"application/vnd.github+json"},
       {~c"x-github-api-version", ~c"2022-11-28"}
     ], body}
  end

  def request(%{type: "gitlab"} = target, commit, run) do
    url = "#{target.api}/projects/#{URI.encode_www_form(target.repository)}/statuses/#{commit}"

    body =
      %{
        "state" => gitlab_state(run["status"]),
        "name" => "testor/#{run["kind"]}",
        "description" => description(run)
      }
      |> with_link(target, run)

    {url, [{~c"private-token", String.to_charlist(target.token)}], body}
  end

  defp with_link(body, %{base: nil}, _run), do: body
  defp with_link(body, %{base: base}, run), do: Map.put(body, "target_url", link(base, run))

  defp link(base, run), do: "#{base}/#/run/#{URI.encode_www_form(run["id"])}"

  defp github_state("running"), do: "pending"
  defp github_state("passed"), do: "success"
  defp github_state("failed"), do: "failure"
  defp github_state(_cancelled_or_aborted), do: "error"

  defp gitlab_state("running"), do: "running"
  defp gitlab_state("passed"), do: "success"
  defp gitlab_state("cancelled"), do: "canceled"
  defp gitlab_state(_failed_or_aborted), do: "failed"

  defp description(%{"status" => "running"}), do: "running on testor"

  defp description(run) do
    summary = run["summary"] || %{}

    counts =
      for key <- ["passed", "failed", "skipped"],
          is_integer(summary[key]) and summary[key] > 0,
          do: "#{summary[key]} #{key}"

    String.slice("#{run["status"]}#{if counts != [], do: ": " <> Enum.join(counts, ", ")}", 0, 140)
  end

  defp deliver(target, commit, run, backoff) do
    {url, headers, body} = request(target, commit, run)
    headers = [{~c"user-agent", ~c"testor/#{Application.spec(:testor, :vsn)}"} | headers]
    request = {String.to_charlist(url), headers, ~c"application/json", JSON.encode!(body)}

    case :httpc.request(:post, request, Webhooks.http_options(), body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        :ok

      other ->
        why =
          case other do
            {:ok, {{_, status, _}, _, _}} -> "answered #{status}"
            {:error, reason} -> "failed (#{inspect(reason)})"
          end

        case backoff do
          [wait | rest] ->
            Process.sleep(wait)
            deliver(target, commit, run, rest)

          [] ->
            Logger.warning(
              "statuses: #{run["id"]} on #{target.repository}@#{String.slice(commit, 0, 12)} #{why}"
            )

            {:error, why}
        end
    end
  end
end
