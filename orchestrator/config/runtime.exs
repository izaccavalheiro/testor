import Config

# TESTOR_WORKSPACES: the folder that holds one snapshot folder per project (default
# ~/test-run). TESTOR_HOME: testor's own folder, where run.ps1 writes runs\, logs\ and
# screenshots\ and config.json may override the retention (default <workspaces>/.testor).
home = System.user_home!()
workspaces = System.get_env("TESTOR_WORKSPACES") || Path.join(home, "test-run")
data_dir = System.get_env("TESTOR_HOME") || Path.join(workspaces, ".testor")

# TESTOR_BIND: the address to listen on (default 0.0.0.0, every interface); 127.0.0.1 keeps
# testor local, for a reverse proxy that terminates TLS in front of it.
ip =
  case :inet.parse_address(String.to_charlist(System.get_env("TESTOR_BIND", "0.0.0.0"))) do
    {:ok, ip} -> ip
    {:error, _} -> raise "TESTOR_BIND is not an IP address: #{System.get_env("TESTOR_BIND")}"
  end

# TESTOR_ANONYMOUS: who is answered while authentication is off (no user in auth.json):
# "private" (default: loopback, private, link-local and Tailscale addresses), "loopback", or
# "any" (every address, as before 0.3: only on a network you trust).
anonymous =
  case System.get_env("TESTOR_ANONYMOUS", "private") do
    value when value in ["private", "loopback", "any"] -> value
    value -> raise "TESTOR_ANONYMOUS is private, loopback or any, not #{inspect(value)}"
  end

config :testor,
  data_dir: data_dir,
  # TESTOR_SECRETS_DIR: where auth.json and the keys live (unset: the data folder). Point it at
  # a folder the account that runs the tests cannot read.
  secrets_dir: System.get_env("TESTOR_SECRETS_DIR"),
  workspaces: workspaces,
  ip: ip,
  port: String.to_integer(System.get_env("TESTOR_PORT", "6767")),
  # TESTOR_ALLOWED_HOSTS: host names the server answers besides IP addresses, localhost and
  # this machine's name (DNS rebinding protection): "testor.example.com, .example.com" or "*".
  allowed_hosts: System.get_env("TESTOR_ALLOWED_HOSTS"),
  # TESTOR_TRUSTED_PROXIES: addresses or CIDR ranges of reverse proxies whose X-Forwarded-For
  # names the client (for rate limiting, audit and the anonymous-access check).
  trusted_proxies: System.get_env("TESTOR_TRUSTED_PROXIES"),
  anonymous: anonymous,
  # TESTOR_TLS_CERT, TESTOR_TLS_KEY: PEM files of a certificate (with its chain) and its key;
  # with both, testor serves HTTPS only.
  tls_cert: System.get_env("TESTOR_TLS_CERT"),
  tls_key: System.get_env("TESTOR_TLS_KEY")

# TESTOR_LOG: "file" (default for a release: <home>/testor.log, as a service nobody reads stdout
# of) or "stdout" (containers, whose runtime collects it).
if config_env() == :prod and System.get_env("TESTOR_LOG", "file") == "file" do
  # Run by a scheduled task, nobody reads stdout: log to a file next to the data.
  config :logger, :default_handler,
    config: [
      file: String.to_charlist(Path.join(data_dir, "testor.log")),
      max_no_bytes: 1_000_000,
      max_no_files: 2
    ]
end
