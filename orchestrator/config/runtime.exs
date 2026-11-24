import Config

# TESTOR_WORKSPACES: the folder that holds one snapshot folder per project (default
# ~/test-run). TESTOR_HOME: testor's own folder, where run.ps1 writes runs\, logs\ and
# screenshots\ and config.json may override the retention (default <workspaces>/.testor).
home = System.user_home!()
workspaces = System.get_env("TESTOR_WORKSPACES") || Path.join(home, "test-run")
data_dir = System.get_env("TESTOR_HOME") || Path.join(workspaces, ".testor")

config :testor,
  data_dir: data_dir,
  workspaces: workspaces,
  port: String.to_integer(System.get_env("TESTOR_PORT", "6767"))

if config_env() == :prod do
  # Run by a scheduled task, nobody reads stdout: log to a file next to the data.
  config :logger, :default_handler,
    config: [
      file: String.to_charlist(Path.join(data_dir, "testor.log")),
      max_no_bytes: 1_000_000,
      max_no_files: 2
    ]
end
