defmodule Testor.Config do
  @moduledoc "Paths of the data folder, the retention policy and maintenance settings (defaults, overridden by config.json)."

  @defaults %{
    "screenshots" => %{"maxAgeDays" => 7, "maxTotalMB" => 1024},
    "artifacts" => %{"maxAgeDays" => 7, "maxTotalMB" => 2048, "maxRunMB" => 256},
    "runs" => %{"maxRuns" => 500, "maxAgeDays" => 30},
    "cleanupIntervalMinutes" => 30,
    "maintenance" => %{"enabled" => false, "tempMinAgeDays" => 7, "snapshotIdleDays" => 14},
    # Jobs (Testor.Jobs): off until enabled; an agent's lease lasts leaseSeconds without a
    # heartbeat, and a job is tried maxAttempts times when its agents stop answering.
    # warmSeconds: how long a queued job waits for the agent that ran its project last.
    "execution" => %{
      "enabled" => false,
      "leaseSeconds" => 30,
      "maxAttempts" => 3,
      "warmSeconds" => 2,
      "watchIdleMinutes" => 15
    },
    # Content-addressed snapshots (Testor.Snapshots) and the incremental state (Testor.States).
    "snapshots" => %{"maxFiles" => 100_000, "maxFileMB" => 256, "maxMB" => 4096, "keepDays" => 14},
    "state" => %{"maxMB" => 16, "keepDays" => 30, "defaultBranch" => "main"}
  }

  def data_dir, do: Application.fetch_env!(:testor, :data_dir)

  @doc "Where auth.json and the keys live: `TESTOR_SECRETS_DIR`, else the data folder."
  def secrets_dir, do: Application.get_env(:testor, :secrets_dir) || data_dir()

  @doc "Host names answered besides IP literals, localhost and this machine's names."
  def allowed_hosts, do: Testor.Net.parse_hosts(Application.get_env(:testor, :allowed_hosts))

  @doc "CIDR ranges of reverse proxies trusted to name the client in X-Forwarded-For."
  def trusted_proxies, do: Testor.Net.parse_cidrs(Application.get_env(:testor, :trusted_proxies))

  @doc "Who is answered while authentication is off: \"private\", \"loopback\" or \"any\"."
  def anonymous, do: Application.get_env(:testor, :anonymous, "private")

  @doc "The folder that holds one snapshot folder per project."
  def workspaces, do: Application.get_env(:testor, :workspaces, Path.dirname(data_dir()))

  @doc "The workspace folder's name, as it appears in remote command lines (`$HOME\\test-run\\x`)."
  def workspaces_name, do: Path.basename(workspaces())
  def runs_dir, do: Path.join(data_dir(), "runs")
  def logs_dir, do: Path.join(data_dir(), "logs")
  def shots_dir, do: Path.join(data_dir(), "screenshots")
  def artifacts_dir, do: Path.join(data_dir(), "artifacts")
  def reports_dir, do: Path.join(data_dir(), "reports")
  @doc "Cancel requests: `cancel/<id>`, which run.ps1 watches for to end its own run."
  def cancel_dir, do: Path.join(data_dir(), "cancel")
  @doc "Signed attestations of finished runs: `attestations/<id>.dsse.json`."
  def attestations_dir, do: Path.join(data_dir(), "attestations")
  def run_file(id), do: Path.join(runs_dir(), id <> ".json")
  def log_file(id), do: Path.join(logs_dir(), id <> ".log")

  @doc "The retention policy; config.json in the data folder overrides any key of the defaults."
  def retention do
    user = user()

    Map.new(@defaults, fn
      {key, value} when is_map(value) -> {key, Map.merge(value, Map.get(user, key, %{}))}
      {key, value} -> {key, Map.get(user, key, value)}
    end)
  end

  @doc "Where config.json is: `TESTOR_CONFIG_FILE`, else the data folder's."
  def config_file, do: Application.get_env(:testor, :config_file) || Path.join(data_dir(), "config.json")

  @doc "config.json as written, `%{}` when there is none or it is not an object."
  def user do
    with {:ok, text} <- File.read(config_file()),
         {:ok, map} when is_map(map) <- JSON.decode(strip_bom(text)) do
      map
    else
      _ -> %{}
    end
  end

  def strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  def strip_bom(text), do: text
end
