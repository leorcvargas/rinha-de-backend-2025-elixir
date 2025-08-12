import Config

config :rinhex,
  processor_default_url: System.get_env("PAYMENT_PROCESSOR_DEFAULT_URL"),
  processor_fallback_url: System.get_env("PAYMENT_PROCESSOR_FALLBACK_URL")
