defmodule Testor.Gates do
  @moduledoc """
  Release gates: whether a commit may ship, from signed results. `gates` in config.json name
  what a release needs:

      "gates": {
        "web-release": {"project": "web", "kinds": ["test", "e2e"],
                        "requireAgentSignature": true, "maxAgeHours": 72}
      }

  `GET /api/v1/gates/web-release?commit=<sha>` answers, for each kind, from its latest finished
  run of that commit (from a clean tree, `source.commit` and `source.dirty: false`):

    * it passed;
    * testor's attestation of it holds (`Testor.Attestation`, checked again now with testor's
      key, not taken from a flag), and its signed record names that commit, that run and
      `passed`;
    * with `requireAgentSignature`, its agent signed it too (`agentAttested`, checked when
      testor received it);
    * with `maxAgeHours`, it ended within that time.

  The answer is `pass` and the reason of each check that fails, for a pipeline to stop on, or
  for a policy engine (OPA) to take as its input.
  """
  alias Testor.{Attestation, Config, Store}

  @name ~r/^[A-Za-z0-9_.-]{1,64}$/
  @commit ~r/^[0-9a-fA-F]{7,64}$/

  @doc "The gates of config.json: each valid one, the others with why not."
  def list do
    for {name, raw} <- gates() |> Enum.sort() do
      case check(raw) do
        {:ok, gate} -> Map.put(gate, "name", name)
        {:error, why} -> %{"name" => name, "error" => why}
      end
    end
  end

  @doc "The gate `name` as configured: `{:ok, gate}`, `{:error, :not_found}` or `{:error, why}`."
  def get(name) do
    case gates()[name] do
      nil -> {:error, :not_found}
      raw -> with {:ok, gate} <- check(raw), do: {:ok, Map.put(gate, "name", name)}
    end
  end

  @doc "Whether `commit` passes `gate`, with each kind's check."
  def evaluate(gate, commit, now \\ DateTime.utc_now()) do
    if is_binary(commit) and Regex.match?(@commit, commit) do
      commit = String.downcase(commit)
      checks = for kind <- gate["kinds"], do: check_kind(gate, kind, commit, now)

      {:ok,
       %{
         "gate" => gate["name"],
         "project" => gate["project"],
         "commit" => commit,
         "pass" => Enum.all?(checks, & &1["pass"]),
         "checks" => checks,
         "checkedAt" => DateTime.to_iso8601(now)
       }}
    else
      {:error, "commit is a git commit id (7 to 64 hex characters)"}
    end
  end

  defp check_kind(gate, kind, commit, now) do
    case latest(gate["project"], kind, commit) do
      nil ->
        %{"kind" => kind, "pass" => false, "reason" => "no finished run of #{kind} at this commit from a clean tree"}

      run ->
        reason = reason(gate, run, commit, now)

        %{
          "kind" => kind,
          "pass" => reason == nil,
          "runId" => run["id"],
          "status" => run["status"],
          "endedAt" => run["endedAt"],
          "attestation" => "/api/v1/runs/#{run["id"]}/attestation"
        }
        |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))
    end
  end

  # The finished run of project and kind at `commit`, from a clean tree, started last (ids hold
  # the second and random characters: two of one second do not sort by time).
  defp latest(project, kind, commit) do
    Store.all()
    |> Enum.filter(fn run ->
      source = run["source"] || %{}

      run["project"] == project and run["kind"] == kind and run["status"] != "running" and
        source["dirty"] != true and same_commit?(source["commit"], commit)
    end)
    # ISO 8601 times in UTC sort as text.
    |> Enum.max_by(&(&1["startedAt"] || ""), fn -> nil end)
  end

  defp same_commit?(recorded, commit),
    do: is_binary(recorded) and String.starts_with?(String.downcase(recorded), commit)

  defp reason(gate, run, commit, now) do
    cond do
      run["status"] != "passed" ->
        "its latest run #{run["id"]} #{run["status"]}"

      too_old?(gate["maxAgeHours"], run["endedAt"], now) ->
        "its latest run ended more than #{gate["maxAgeHours"]} hours ago"

      true ->
        attested(run, commit) || agent_signed(gate, run)
    end
  end

  defp agent_signed(%{"requireAgentSignature" => true}, %{"agentAttested" => true}), do: nil
  defp agent_signed(%{"requireAgentSignature" => true}, _run), do: "its latest run is not signed by its agent"
  defp agent_signed(_gate, _run), do: nil

  @doc false
  def too_old?(nil, _ended, _now), do: false

  def too_old?(hours, ended, now) do
    case Store.parse_time(ended) do
      {:ok, at} -> DateTime.diff(now, at) > hours * 3600
      _ -> true
    end
  end

  # nil when testor's attestation holds and its signed record is this run, passed, at this commit.
  defp attested(run, commit) do
    {public, _} = Attestation.keypair()

    with {:ok, text} <- File.read(Attestation.file(run["id"])),
         {:ok, envelope} <- JSON.decode(text),
         {:ok, %{"predicate" => %{"run" => signed}}} <- Attestation.verify(envelope, public) do
      cond do
        signed["id"] != run["id"] or signed["status"] != "passed" ->
          "its attestation does not sign this run as passed"

        not same_commit?(get_in(signed, ["source", "commit"]), commit) ->
          "its attestation does not name this commit"

        true ->
          nil
      end
    else
      {:error, :enoent} -> "its latest run is not signed by testor"
      _ -> "its attestation does not hold"
    end
  end

  defp gates do
    case Config.user()["gates"] do
      %{} = gates -> gates
      _ -> %{}
    end
  end

  defp check(%{} = raw) do
    cond do
      not name?(raw["project"]) ->
        {:error, "project is a name"}

      not (is_list(raw["kinds"]) and raw["kinds"] != [] and Enum.all?(raw["kinds"], &name?/1)) ->
        {:error, "kinds is a list of task names"}

      raw["requireAgentSignature"] not in [nil, true, false] ->
        {:error, "requireAgentSignature is true or false"}

      raw["maxAgeHours"] != nil and not (is_number(raw["maxAgeHours"]) and raw["maxAgeHours"] > 0) ->
        {:error, "maxAgeHours is a number of hours"}

      true ->
        {:ok, Map.take(raw, ["project", "kinds", "requireAgentSignature", "maxAgeHours"])}
    end
  end

  defp check(_raw), do: {:error, "a gate is an object"}

  defp name?(value), do: is_binary(value) and Regex.match?(@name, value)
end
