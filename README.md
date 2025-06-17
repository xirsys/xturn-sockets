# XTurn Sockets

A high-performance, production-ready Elixir socket library optimized for TURN server usage. Provides unified support for multiple transport protocols with advanced features like rate limiting, connection management, and comprehensive telemetry.

## 🚀 Features

- **Multi-Protocol Support**: UDP, TCP, TLS, DTLS, and SCTP protocols
- **Production Optimized**: Built specifically for TURN server requirements
- **Rate Limiting**: Per-IP rate limiting with configurable thresholds
- **Connection Management**: Automatic connection tracking and cleanup
- **Telemetry Integration**: Comprehensive metrics and monitoring
- **Security Features**: SSL/TLS support with configurable certificates
- **Error Handling**: Robust error handling with graceful degradation
- **Performance Tuned**: Optimized buffer sizes and connection pooling
- **IPv4/IPv6 Support**: Full dual-stack networking support

## 📦 Installation

Add `xturn_sockets` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:xturn_sockets, "~> 1.1.0"},
    {:telemetry, "~> 1.0"}  # For telemetry features
  ]
end
```

## 🔧 Configuration

Configure the library in your `config/config.exs`:

```elixir
config :xturn_sockets,
  # Connection Management
  connection_timeout: 30_000,           # 30 seconds
  max_udp_connections: 10_000,          # Max UDP connections
  max_tcp_connections: 1_000,           # Max TCP connections
  max_sctp_connections: 1_000,          # Max SCTP connections

  # Rate Limiting
  rate_limit_enabled: true,
  rate_limit_window: 60_000,            # 1 minute window (1000 requests per window is hardcoded)

  # Buffer Configuration
  buffer_size: 262_144,                 # 256KB buffers

  # SSL/TLS Configuration
  ssl_handshake_timeout: 10_000,        # 10 seconds

  # SCTP Configuration
  sctp_nodelay: true,
  sctp_autoclose: 0,
  sctp_maxseg: 1400,

  # Telemetry
  telemetry_enabled: true

# Certificate configuration for TLS/DTLS
config :certs,
  certfile: "path/to/cert.pem",
  keyfile: "path/to/key.pem",
  cacertfile: "path/to/ca.pem"
```

## 📖 Usage Examples

### Basic UDP Socket

```elixir
alias Xirsys.Sockets.Socket

# Open a UDP socket
{:ok, socket} = Socket.open_port({127, 0, 0, 1}, :random, [])

# Send a message
:ok = Socket.send(socket, "Hello UDP", {192, 168, 1, 100}, 5000)

# Get socket information
{:ok, {ip, port}} = Socket.sockname(socket)

# Close the socket
:ok = Socket.close(socket)
```

### UDP Listener with Callback

```elixir
defmodule MyUDPHandler do
  def process_buffer(data) do
    # Process incoming data
    {data, <<>>}  # Return {processed_data, remaining_buffer}
  end

  def dispatch(conn) do
    # Handle the processed connection
    IO.puts "Received: #{inspect(conn.message)}"
    IO.puts "From: #{inspect(conn.client_ip)}:#{conn.client_port}"
  end
end

# Start UDP listener
{:ok, pid} = Xirsys.Sockets.Listener.UDP.start_link(
  MyUDPHandler,
  {0, 0, 0, 0},  # Bind to all interfaces
  8080           # Port
)
```

### TCP Listener

```elixir
defmodule MyTCPHandler do
  def handle_message(socket, data, _from_ip, _from_port, _metadata) do
    # Echo the message back
    Socket.send(socket, data)
    :ok
  end
end

# Start TCP listener
{:ok, pid} = Xirsys.Sockets.Listener.TCP.start_link(
  MyTCPHandler,
  {0, 0, 0, 0},
  8081
)
```

### DTLS (Secure UDP) Listener

```elixir
# Start DTLS listener (requires certificate configuration)
{:ok, pid} = Xirsys.Sockets.Listener.UDP.start_link(
  MyUDPHandler,
  {0, 0, 0, 0},
  8443,
  {:ssl, true}  # Enable DTLS
)
```

### SCTP Multi-Stream Support

```elixir
defmodule MySCTPHandler do
  def handle_message(socket, data, from_ip, from_port, metadata) do
    stream_id = metadata[:stream_id] || 0
    ppid = metadata[:ppid] || 0

    IO.puts "SCTP message on stream #{stream_id}, PPID #{ppid}"
    IO.puts "Data: #{inspect(data)}"

    # Echo back on the same stream
    Socket.send(socket, "Echo: #{data}")
    :ok
  end
end

# Start SCTP listener
{:ok, pid} = Xirsys.Sockets.Listener.SCTP.start_link(
  MySCTPHandler,
  {0, 0, 0, 0},
  8082
)
```

### Advanced Socket Operations

```elixir
# Create socket with specific options
{:ok, socket} = Socket.open_port(
  {127, 0, 0, 1},
  {:range, 50000, 50100},  # Port range
  [
    {:reuseaddr, true},
    {:buffer, 65536}
  ]
)

# Set socket options
:ok = Socket.setopts(socket, [{:active, :once}, :binary])

# Get socket options
{:ok, opts} = Socket.getopts(socket)

# Check rate limiting
case Socket.check_rate_limit({192, 168, 1, 100}) do
  :ok ->
    # Process request
    :ok
  {:error, :rate_limited} ->
    # Reject request
    {:error, :too_many_requests}
end
```

## 📊 Telemetry and Monitoring

The library provides comprehensive telemetry events for monitoring:

```elixir
# Attach telemetry handlers
Xirsys.Sockets.Telemetry.attach_handlers()

# Get current metrics
metrics = Xirsys.Sockets.Telemetry.get_metrics()

# Example metrics structure:
%{
  total_connections: 1500,
  active_udp_connections: 800,
  active_tcp_connections: 500,
  active_sctp_connections: 200,
  bytes_sent: 1_048_576,
  bytes_received: 2_097_152,
  rate_limit_hits: 45,
  ssl_handshake_successes: 150,
  ssl_handshake_errors: 5,
  send_errors: 12,
  last_updated: 1640995200
}

# Check health status
health = Xirsys.Sockets.Telemetry.health_status()
# Returns: :healthy | :degraded | :unhealthy | :under_attack
```

### Custom Telemetry Handlers

```elixir
# Attach custom handler for connection events
:telemetry.attach(
  "my-connection-handler",
  [:xturn_sockets, :connection_accepted],
  fn _name, measurements, metadata, _config ->
    protocol = measurements[:protocol]
    Logger.info("New #{protocol} connection from #{inspect(metadata[:ip])}")
  end,
  %{}
)
```

## 🏗️ Architecture

### Socket Types

- **UDP**: Connectionless, high-performance datagram transport
- **TCP**: Reliable, connection-oriented stream transport
- **TLS**: Secure TCP with SSL/TLS encryption
- **DTLS**: Secure UDP with datagram TLS encryption
- **SCTP**: Message-oriented transport with multi-streaming

### Components

- `Socket`: Core socket abstraction and operations
- `Listener.UDP`: UDP packet listener with DTLS support
- `Listener.TCP`: TCP connection listener with TLS support
- `Listener.SCTP`: SCTP association listener with multi-streaming
- `Telemetry`: Metrics collection and health monitoring
- `Client`: Client connection management
- `Conn`: Connection state and metadata

## 🔐 Security Features

### Rate Limiting

```elixir
# Per-IP rate limiting (1000 requests/minute by default)
case Socket.check_rate_limit(client_ip) do
  :ok ->
    # Within limits
    process_request()
  {:error, :rate_limited} ->
    # Rate limited
    send_error_response()
end
```

### SSL/TLS Configuration

```elixir
# Configure certificates
config :certs,
  certfile: "/path/to/server.crt",
  keyfile: "/path/to/server.key",
  cacertfile: "/path/to/ca.crt",
  # Additional SSL options
  versions: [:"tlsv1.2", :"tlsv1.3"],
  ciphers: [:ecdhe_ecdsa_aes_256_gcm_sha384, :ecdhe_rsa_aes_256_gcm_sha384],
  secure_renegotiate: true,
  reuse_sessions: true
```

### Connection Limits

```elixir
# Automatic connection limiting per protocol
config :xturn_sockets,
  max_udp_connections: 10_000,
  max_tcp_connections: 1_000,
  max_sctp_connections: 1_000,
  max_connections_per_ip: 100
```

## 🧪 Testing

Run the test suite:

```bash
# Run all tests
mix test

# Run tests for specific protocols
mix test --only udp
mix test --only tcp
mix test --only tls
mix test --only dtls
mix test --only sctp

# Run with coverage
mix test --cover
```

## 📈 Performance Tuning

### Buffer Sizes

```elixir
config :xturn_sockets,
  buffer_size: 262_144,        # 256KB (default)
  # For high-throughput applications:
  buffer_size: 1_048_576       # 1MB
```

### Connection Pooling

```elixir
config :xturn_sockets,
  connection_cleanup_enabled: true,
  connection_cleanup_interval: 300_000,  # 5 minutes
  connection_timeout: 30_000             # 30 seconds
```

### SCTP Optimization

```elixir
config :xturn_sockets,
  sctp_nodelay: true,           # Disable Nagle algorithm
  sctp_autoclose: 0,            # Disable auto-close
  sctp_maxseg: 1400,            # Optimal segment size
  sctp_streams: %{
    num_ostreams: 10,           # Outbound streams
    max_instreams: 10,          # Inbound streams
    max_attempts: 4,            # Connection attempts
    max_init_timeo: 30_000      # Init timeout
  }
```

## 🐛 Troubleshooting

### Common Issues

1. **SCTP Not Available**

   ```
   {:error, :sctp_not_supported}
   ```

   Solution: Ensure SCTP support is compiled into your Erlang/OTP installation.

2. **Certificate Errors**

   ```
   {:error, :no_certificates_configured}
   ```

   Solution: Configure certificates in the `:certs` application environment.

3. **Rate Limiting False Positives**
   ```
   {:error, :rate_limited}
   ```
   Solution: Adjust rate limiting configuration or disable for testing.

### Debug Mode

```elixir
# Enable debug logging
config :logger, level: :debug

# Enable socket statistics
{:ok, pid} = Xirsys.Sockets.Listener.UDP.start_link(
  MyHandler,
  {0, 0, 0, 0},
  8080,
  false,
  debug: [:statistics]
)
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass (`mix test`)
6. Commit your changes (`git commit -m 'Add amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

## 📜 License

Copyright (c) 2013 - 2020 Xirsys LLC

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE.md) for details.

## 💝 Donations

Developing libraries takes time (mostly personal), so donations are welcome. Donations can be sent via PayPal:

![Donation QR Code](./docs/assets/images/qrcode.png)

## 📞 Contact

For questions, suggestions, or support:

- Email: experts@xirsys.com
- Issues: [GitHub Issues](https://github.com/xirsys/xturn-sockets/issues)

## 🔗 Related Projects

- [XTurn](https://github.com/xirsys/xturn) - TURN/STUN server implementation
- [Xirsys Cloud](https://xirsys.com) - Managed TURN/STUN service
