import Config

config :rinhex,
  generators: [timestamp_type: :utc_datetime]

import_config "#{config_env()}.exs"
