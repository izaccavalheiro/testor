import Config

config :logger, :default_formatter, format: "$date $time [$level] $message\n", colors: [enabled: false]

if config_env() == :test do
  config :testor, start_server: false
  config :logger, level: :warning
end
