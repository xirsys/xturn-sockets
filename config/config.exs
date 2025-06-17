# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
import Config

# TURN Server Socket Configuration
config :xturn_sockets,
  # Connection Management
  connection_timeout: 30_000,  # 30 seconds
  ssl_handshake_timeout: 10_000,  # 10 seconds
  max_connections_per_ip: 100,
  max_tcp_connections: 1000,

  # Rate Limiting (for DDoS protection)
  rate_limit_enabled: true,
  rate_limit_window: 60_000,  # 1 minute
  max_requests_per_window: 1000,

  # Buffer Sizes (optimized for media relay)
  buffer_size: 256 * 1024,  # 256KB default
  large_buffer_size: 1024 * 1024,  # 1MB for high-bandwidth

  # Security Settings
  ssl_options: [
    {:versions, [:'tlsv1.2', :'tlsv1.3']},
    {:secure_renegotiate, true},
    {:reuse_sessions, false},
    {:honor_cipher_order, true},
    {:fail_if_no_peer_cert, false},  # TURN allows anonymous clients
    {:verify, :verify_none}  # TURN handles verification at app level
  ],

  # Monitoring & Telemetry
  telemetry_enabled: true,
  connection_cleanup_enabled: true,

  # Logging
  log_level: :info

# This configuration is loaded before any dependency and is restricted
# to this project. If another project depends on this project, this
# file won't be loaded nor affect the parent project. For this reason,
# if you want to provide default values for your application for
# 3rd-party users, it should be done in your "mix.exs" file.

# You can configure your application as:
#
#     config :xturn_sockets, key: :value
#
# and access this configuration in your application as:
#
#     Application.get_env(:xturn_sockets, :key)
#
# You can also configure a 3rd-party app:
#
#     config :logger, level: :info
#

# It is also possible to import configuration files, relative to this
# directory. For example, you can emulate configuration per environment
# by uncommenting the line below and defining dev.exs, test.exs and such.
# Configuration from the imported file will override the ones defined
# here (which is why it is important to import them last).
#
#     import_config "#{Mix.env()}.exs"
