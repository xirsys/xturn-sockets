### ----------------------------------------------------------------------
###
### Copyright (c) 2013 - 2020 Jahred Love and Xirsys LLC <experts@xirsys.com>
###
### All rights reserved.
###
### XTurn is licensed by Xirsys under the Apache
### License, Version 2.0. (the "License");
###
### you may not use this file except in compliance with the License.
### You may obtain a copy of the License at
###
###      http://www.apache.org/licenses/LICENSE-2.0
###
### Unless required by applicable law or agreed to in writing, software
### distributed under the License is distributed on an "AS IS" BASIS,
### WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
### See the License for the specific language governing permissions and
### limitations under the License.
###
### See LICENSE for the full license text.
###
### ----------------------------------------------------------------------

defmodule Xirsys.Sockets.Socket do
  @moduledoc """
  Socket protocol helpers optimized for TURN server usage.

  This module provides a unified interface for handling different socket types
  including UDP, TCP, TLS, DTLS, and SCTP protocols. It's specifically optimized
  for TURN server operations with features like:

  - Rate limiting and connection management
  - Enhanced error handling and telemetry
  - Multi-protocol support with consistent API
  - Performance optimizations for media relay
  - Security features and validation

  ## Socket Types

  - `:udp` - User Datagram Protocol for connectionless communication
  - `:tcp` - Transmission Control Protocol for reliable connections
  - `:tls` - Transport Layer Security over TCP
  - `:dtls` - Datagram Transport Layer Security over UDP
  - `:sctp` - Stream Control Transmission Protocol with multi-streaming

  ## Examples

      # Open a UDP socket
      {:ok, socket} = Socket.open_port({127, 0, 0, 1}, :random, [])

      # Send a message
      :ok = Socket.send(socket, "Hello", {192, 168, 1, 1}, 5000)

      # Perform handshake for connection-oriented protocols
      {:ok, client_socket} = Socket.handshake(tcp_socket)

  """
  require Logger

  defstruct type: :udp, sock: nil

  @type t :: %__MODULE__{
          type: :udp | :tcp | :dtls | :tls | :sctp,
          sock: port()
        }

  @type socket_type :: :udp | :tcp | :dtls | :tls | :sctp
  @type ip_address :: tuple()
  @type port_number :: non_neg_integer()
  @type policy :: :random | {:preferred, port_number()} | {:range, port_number(), port_number()}
  @type socket_options :: list()

  # TURN server specific configurations
  @connection_timeout 30_000  # 30 seconds for TURN connections
  @ssl_handshake_timeout 10_000  # 10 seconds for SSL handshake
  @max_connections_per_ip 100  # Reasonable limit for TURN clients
  @rate_limit_window 60_000  # 1 minute window
  @max_requests_per_window 1000  # Max requests per IP per minute

  # Enhanced buffer sizes for media relay
  @default_buffer_size 256 * 1024  # 256KB for better media performance

  @setopts_default [{:active, :once}, :binary]

  @doc """
  Returns TURN server configuration values.

  Looks up configuration values in the following order:
  1. `:xturn_sockets` application config
  2. `:xturn` application config
  3. Default value

  ## Parameters

  - `key` - Configuration key to lookup
  - `default` - Default value if key not found

  ## Examples

      iex> Socket.get_config(:connection_timeout, 5000)
      30000

  """
  @spec get_config(atom(), any()) :: any()
  def get_config(key, default \\ nil) do
    Application.get_env(:xturn_sockets, key,
      Application.get_env(:xturn, key, default))
  end

  @doc "Returns the configured connection timeout in milliseconds"
  @spec connection_timeout() :: pos_integer()
  def connection_timeout(), do: get_config(:connection_timeout, @connection_timeout)

  @doc "Returns the configured SSL handshake timeout in milliseconds"
  @spec ssl_handshake_timeout() :: pos_integer()
  def ssl_handshake_timeout(), do: get_config(:ssl_handshake_timeout, @ssl_handshake_timeout)

  @doc "Returns the maximum connections allowed per IP address"
  @spec max_connections_per_ip() :: pos_integer()
  def max_connections_per_ip(), do: get_config(:max_connections_per_ip, @max_connections_per_ip)

  @doc "Returns whether rate limiting is enabled"
  @spec rate_limit_enabled?() :: boolean()
  def rate_limit_enabled?(), do: get_config(:rate_limit_enabled, true)

  @doc """
  Returns the server IP address from configuration.

  Used for packet processing and response generation.
  """
  @spec server_ip() :: ip_address()
  def server_ip(),
    do: Application.get_env(:xturn, :server_ip, {0, 0, 0, 0})

  @doc """
  Returns the client message hooks from configuration.

  Client hooks are GenServer processes that receive client messages
  for processing or logging.
  """
  @spec client_hooks() :: [module()]
  def client_hooks() do
    case Application.get_env(:xturn, :client_hooks, []) do
      hooks when is_list(hooks) -> hooks
      _ -> []
    end
  end

  @doc """
  Returns the peer message hooks from configuration.

  Peer hooks are GenServer processes that receive peer messages
  for processing or logging.
  """
  @spec peer_hooks() :: [module()]
  def peer_hooks() do
    case Application.get_env(:xturn, :peer_hooks, []) do
      hooks when is_list(hooks) -> hooks
      _ -> []
    end
  end

  @doc """
  Returns the server's local IP address from configuration.

  Used for binding sockets to specific network interfaces.
  """
  @spec server_local_ip() :: ip_address()
  def server_local_ip(),
    do: Application.get_env(:xturn, :server_local_ip, {0, 0, 0, 0})

  @doc """
  Enhanced rate limiting check for TURN server protection.

  Checks if a client IP is within the rate limit thresholds.
  Creates an ETS table for tracking if it doesn't exist.

  ## Parameters

  - `client_ip` - The client's IP address tuple

  ## Returns

  - `:ok` - Request is within rate limits
  - `{:error, :rate_limited}` - Client has exceeded rate limits

  ## Examples

      iex> Socket.check_rate_limit({192, 168, 1, 1})
      :ok

  """
  @spec check_rate_limit(ip_address()) :: :ok | {:error, :rate_limited}
  def check_rate_limit(client_ip) do
    if rate_limit_enabled?() do
      case :ets.whereis(:turn_rate_limits) do
        :undefined ->
          # Create ETS table if it doesn't exist
          :ets.new(:turn_rate_limits, [:named_table, :public, {:write_concurrency, true}])
          :ok
        _ ->
          now = System.monotonic_time(:millisecond)
          window_start = now - @rate_limit_window

          # Clean old entries and count current requests
          case :ets.lookup(:turn_rate_limits, client_ip) do
            [{^client_ip, timestamps}] ->
              recent_timestamps = Enum.filter(timestamps, &(&1 > window_start))

              if length(recent_timestamps) >= @max_requests_per_window do
                {:error, :rate_limited}
              else
                :ets.insert(:turn_rate_limits, {client_ip, [now | recent_timestamps]})
                :ok
              end
            [] ->
              :ets.insert(:turn_rate_limits, {client_ip, [now]})
              :ok
          end
      end
    else
      :ok
    end
  end

  @doc """
  Opens a new port for UDP TURN transport with enhanced options.

  Creates a UDP socket with optimized buffer sizes and TURN-specific
  configuration. Supports different port allocation policies.

  ## Parameters

  - `sip` - Server IP address tuple (IPv4)
  - `policy` - Port allocation policy (`:random`, `{:preferred, port}`, `{:range, min, max}`)
  - `opts` - Additional socket options

  ## Returns

  - `{:ok, socket}` - Successfully opened socket
  - `{:error, reason}` - Failed to open socket

  ## Examples

      iex> Socket.open_port({127, 0, 0, 1}, :random, [])
      {:ok, %Socket{type: :udp, sock: #Port<...>}}

  """
  @spec open_port(ip_address(), policy(), socket_options()) :: {:ok, t()} | {:error, atom()}
  def open_port({_, _, _, _} = sip, policy, opts) do
    buffer_size = get_config(:buffer_size, @default_buffer_size)

    udp_options =
      [
        {:ip, sip},
        {:active, :once},
        {:buffer, buffer_size},
        {:recbuf, buffer_size},
        {:sndbuf, buffer_size},
        {:reuseaddr, true},  # Important for TURN server restarts
        :binary
      ] ++ opts

    case open_free_udp_port(policy, udp_options) do
      {:ok, _socket} = result ->
        emit_telemetry(:socket_opened, %{protocol: :udp}, %{ip: sip})
        result
      {:error, reason} = error ->
        emit_telemetry(:socket_error, %{protocol: :udp, error: reason}, %{ip: sip})
        error
    end
  end

  @doc """
  Enhanced handshake with timeout and better error handling.

  Performs protocol-specific handshakes for connection-oriented sockets.
  Includes proper timeout handling and telemetry emission.

  ## Parameters

  - `socket` - The listening socket to accept connections on

  ## Returns

  - `{:ok, client_socket}` - Successfully accepted connection
  - `{:error, reason}` - Failed to accept or handshake

  ## Examples

      iex> Socket.handshake(%Socket{type: :tcp, sock: listening_socket})
      {:ok, %Socket{type: :tcp, sock: client_socket}}

  """
  @spec handshake(t()) :: {:ok, t()} | {:error, any()}
  def handshake(%__MODULE__{type: :tcp, sock: socket}) do
    case :gen_tcp.accept(socket, connection_timeout()) do
      {:ok, cli_socket} ->
        emit_telemetry(:connection_accepted, %{protocol: :tcp}, %{})
        {:ok, %__MODULE__{type: :tcp, sock: cli_socket}}
      {:error, :timeout} ->
        Logger.warning("TCP accept timeout")
        {:error, :accept_timeout}
      {:error, reason} = error ->
        Logger.warning("TCP accept failed: #{inspect(reason)}")
        error
    end
  end

  def handshake(%__MODULE__{type: :sctp, sock: socket}) do
    try do
      case :gen_sctp.accept(socket, connection_timeout()) do
        {:ok, cli_socket} ->
          emit_telemetry(:connection_accepted, %{protocol: :sctp}, %{})
          {:ok, %__MODULE__{type: :sctp, sock: cli_socket}}
        {:error, :timeout} ->
          Logger.warning("SCTP accept timeout")
          {:error, :accept_timeout}
        {:error, reason} = error ->
          Logger.warning("SCTP accept failed: #{inspect(reason)}")
          error
      end
    rescue
      error ->
        Logger.warning("SCTP handshake failed: #{inspect(error)}")
        {:error, :sctp_not_supported}
    end
  end

  def handshake(%__MODULE__{type: type, sock: socket}) when type in [:tls, :dtls] do
    timeout = ssl_handshake_timeout()

    with {:ok, cli_socket} <- :ssl.transport_accept(socket, timeout),
         {:ok, cli_socket} <- :ssl.handshake(cli_socket, timeout) do
      emit_telemetry(:ssl_handshake_success, %{protocol: type}, %{})
      {:ok, %__MODULE__{type: type, sock: cli_socket}}
    else
      {:error, :timeout} ->
        Logger.warning("#{type} handshake timeout")
        emit_telemetry(:ssl_handshake_timeout, %{protocol: type}, %{})
        {:error, :ssl_handshake_timeout}
      {:error, reason} = error ->
        Logger.warning("#{type} handshake failed: #{inspect(reason)}")
        emit_telemetry(:ssl_handshake_error, %{protocol: type, error: reason}, %{})
        error
    end
  end

  @doc """
  Sends a message over an open socket with enhanced error handling.

  Supports all socket types (UDP, TCP, TLS, DTLS, SCTP) with protocol-specific
  optimizations. Includes telemetry emission for monitoring.

  ## Parameters

  - `socket` - The socket to send over
  - `msg` - Binary message to send
  - `ip` - Destination IP (for UDP only)
  - `port` - Destination port (for UDP only)

  ## Returns

  - `:ok` - Message sent successfully
  - `{:error, reason}` - Failed to send message

  ## Examples

      # UDP send
      iex> Socket.send(udp_socket, "hello", {192, 168, 1, 1}, 5000)
      :ok

      # TCP send
      iex> Socket.send(tcp_socket, "hello")
      :ok

  """
  @spec send(t(), binary(), ip_address() | nil, port_number() | nil) ::
          :ok | {:error, term()}
  def send(socket, msg, ip \\ nil, port \\ nil)

  def send(%__MODULE__{type: :udp, sock: socket}, msg, ip, port) do
    case :gen_udp.send(socket, ip, port, msg) do
      :ok ->
        emit_telemetry(:message_sent, %{protocol: :udp, bytes: byte_size(msg)}, %{ip: ip, port: port})
        :ok
      {:error, reason} = error ->
        emit_telemetry(:send_error, %{protocol: :udp, error: reason}, %{ip: ip, port: port})
        Logger.warning("UDP send failed: #{inspect(reason)}")
        error
    end
  end

  def send(%__MODULE__{type: :tcp, sock: socket}, msg, _, _) do
    case :gen_tcp.send(socket, msg) do
      :ok ->
        emit_telemetry(:message_sent, %{protocol: :tcp, bytes: byte_size(msg)}, %{})
        :ok
      {:error, reason} = error ->
        emit_telemetry(:send_error, %{protocol: :tcp, error: reason}, %{})
        Logger.warning("TCP send failed: #{inspect(reason)}")
        error
    end
  end

  def send(%__MODULE__{type: :dtls, sock: socket}, msg, _, _) do
    case :ssl.send(socket, msg) do
      :ok ->
        emit_telemetry(:message_sent, %{protocol: :dtls, bytes: byte_size(msg)}, %{})
        :ok
      {:error, reason} = error ->
        emit_telemetry(:send_error, %{protocol: :dtls, error: reason}, %{})
        Logger.warning("DTLS send failed: #{inspect(reason)}")
        error
    end
  end

  def send(%__MODULE__{type: :tls, sock: socket}, msg, _, _) do
    case :ssl.send(socket, msg) do
      :ok ->
        emit_telemetry(:message_sent, %{protocol: :tls, bytes: byte_size(msg)}, %{})
        :ok
      {:error, reason} = error ->
        emit_telemetry(:send_error, %{protocol: :tls, error: reason}, %{})
        Logger.warning("TLS send failed: #{inspect(reason)}")
        error
    end
  end

  def send(%__MODULE__{type: :sctp, sock: socket}, msg, _, _) do
    # SCTP supports message-oriented communication with streams
    # Using default association and stream 0 for basic operation
    try do
      case :gen_sctp.send(socket, 0, 0, msg) do
        :ok ->
          emit_telemetry(:message_sent, %{protocol: :sctp, bytes: byte_size(msg)}, %{})
          :ok
        {:error, reason} = error ->
          emit_telemetry(:send_error, %{protocol: :sctp, error: reason}, %{})
          Logger.warning("SCTP send failed: #{inspect(reason)}")
          error
      end
    rescue
      error ->
        Logger.warning("SCTP send failed: #{inspect(error)}")
        emit_telemetry(:send_error, %{protocol: :sctp, error: :sctp_not_supported}, %{})
        {:error, :sctp_not_supported}
    end
  end

  @doc """
  Sends data to peer hooks with error handling.

  Dispatches messages to configured peer hook processes for
  processing or logging. Includes error recovery.

  ## Parameters

  - `data` - The data to send to peer hooks

  ## Examples

      iex> Socket.send_to_peer_hooks(%{message: "hello"})
      :ok

  """
  @spec send_to_peer_hooks(any()) :: :ok
  def send_to_peer_hooks(data) do
    try do
      peer_hooks()
      |> Enum.each(&GenServer.cast(&1, {:process_message, :peer, data}))
    rescue
      error ->
        Logger.warning("Failed to send to peer hooks: #{inspect(error)}")
        emit_telemetry(:hook_error, %{type: :peer, error: inspect(error)}, %{})
    end
  end

  @doc """
  Sends data to client hooks with error handling.

  Dispatches messages to configured client hook processes for
  processing or logging. Includes error recovery.

  ## Parameters

  - `data` - The data to send to client hooks

  ## Examples

      iex> Socket.send_to_client_hooks(%{message: "hello"})
      :ok

  """
  @spec send_to_client_hooks(any()) :: :ok
  def send_to_client_hooks(data) do
    try do
      client_hooks()
      |> Enum.each(&GenServer.cast(&1, {:process_message, :client, data}))
    rescue
      error ->
        Logger.warning("Failed to send to client hooks: #{inspect(error)}")
        emit_telemetry(:hook_error, %{type: :client, error: inspect(error)}, %{})
    end
  end

  @doc """
  Sets one or more options for a socket.

  Configures socket options with protocol-aware handling.
  Supports both raw ports and Socket structs.

  ## Parameters

  - `socket` - Socket or port to configure
  - `opts` - List of socket options to set

  ## Returns

  - `:ok` - Options set successfully
  - `{:error, reason}` - Failed to set options

  ## Examples

      iex> Socket.setopts(socket, [{:active, :once}, :binary])
      :ok

  """
  @spec setopts(port() | t(), socket_options()) :: :ok | {:error, term()}
  def setopts(socket, opts \\ @setopts_default)

  def setopts(%__MODULE__{type: type, sock: socket}, opts) when type in [:udp, :tcp, :sctp],
    do: :inet.setopts(socket, opts)

  def setopts(%__MODULE__{type: _, sock: socket}, opts),
    do: :ssl.setopts(socket, opts)

  def setopts(socket, opts),
    do: :inet.setopts(socket, opts)

  @doc """
  Gets socket options with protocol-aware handling.

  Retrieves current socket options based on the socket type.
  Different protocols expose different option sets.

  ## Parameters

  - `socket` - Socket to query options from

  ## Returns

  - `{:ok, options}` - Successfully retrieved options
  - `{:error, reason}` - Failed to retrieve options

  ## Examples

      iex> Socket.getopts(socket)
      {:ok, [active: :once, buffer: 65536]}

  """
  @spec getopts(t()) :: {:ok, socket_options()} | {:error, term()}
  def getopts(%__MODULE__{type: type, sock: socket}) when type in [:tls, :dtls],
    do:
      :ssl.getopts(socket, [
        :active,
        :nodelay,
        :keepalive,
        :delay_send,
        :priority,
        :tos,
        :buffer,
        :recbuf,
        :sndbuf
      ])

  def getopts(%__MODULE__{type: :sctp, sock: socket}),
    do:
      :inet.getopts(socket, [
        :active,
        :nodelay,
        :priority,
        :tos,
        :buffer,
        :recbuf,
        :sndbuf,
        :sctp_rtoinfo,
        :sctp_associnfo,
        :sctp_initmsg
      ])

  def getopts(%__MODULE__{sock: socket}),
    do:
      :inet.getopts(socket, [
        :active,
        :nodelay,
        :keepalive,
        :delay_send,
        :priority,
        :tos,
        :buffer,
        :recbuf,
        :sndbuf
      ])

  @doc """
  Enhanced socket option setting with better error handling.

  Transfers socket options from a listening socket to a client socket.
  Includes protocol-specific handling and proper error recovery.

  ## Parameters

  - `list_sock` - The listening socket to copy options from
  - `cli_socket` - The client socket to apply options to

  ## Returns

  - `:ok` - Options transferred successfully
  - `{:error, reason}` - Failed to transfer options

  ## Examples

      iex> Socket.set_sockopt(listener, client)
      :ok

  """
  @spec set_sockopt(t(), t()) :: :ok | {:error, term()}
  def set_sockopt(%__MODULE__{type: type} = list_sock, %__MODULE__{type: type} = cli_socket)
      when type in [:tls, :dtls] do
    case getopts(list_sock) do
      {:ok, opts} ->
        case setopts(cli_socket, opts) do
          :ok ->
            :ok
          {:error, reason} = error ->
            Logger.warning("Failed to set SSL socket options: #{inspect(reason)}")
            emit_telemetry(:sockopt_error, %{protocol: type, error: reason}, %{})
            close(cli_socket, reason)
            error
        end
      {:error, reason} = error ->
        Logger.warning("Failed to get SSL socket options: #{inspect(reason)}")
        emit_telemetry(:sockopt_error, %{protocol: type, error: reason}, %{})
        error
    end
  end

  def set_sockopt(%__MODULE__{type: :tcp} = list_sock, %__MODULE__{type: :tcp} = cli_socket) do
    case register_socket(cli_socket) do
      true ->
        case getopts(list_sock) do
          {:ok, opts} ->
            case setopts(cli_socket, opts) do
              :ok ->
                :ok
              {:error, reason} = error ->
                Logger.warning("Failed to set TCP socket options: #{inspect(reason)}")
                emit_telemetry(:sockopt_error, %{protocol: :tcp, error: reason}, %{})
                close(cli_socket, reason)
                error
            end
          {:error, reason} = error ->
            Logger.warning("Failed to get TCP socket options: #{inspect(reason)}")
            emit_telemetry(:sockopt_error, %{protocol: :tcp, error: reason}, %{})
            error
        end
      false ->
        error = {:error, :socket_registration_failed}
        Logger.warning("Failed to register TCP socket")
        emit_telemetry(:sockopt_error, %{protocol: :tcp, error: :registration_failed}, %{})
        error
    end
  end

  def set_sockopt(%__MODULE__{type: :sctp} = list_sock, %__MODULE__{type: :sctp} = cli_socket) do
    case register_socket(cli_socket) do
      true ->
        case getopts(list_sock) do
          {:ok, opts} ->
            case setopts(cli_socket, opts) do
              :ok ->
                :ok
              {:error, reason} = error ->
                Logger.warning("Failed to set SCTP socket options: #{inspect(reason)}")
                emit_telemetry(:sockopt_error, %{protocol: :sctp, error: reason}, %{})
                close(cli_socket, reason)
                error
            end
          {:error, reason} = error ->
            Logger.warning("Failed to get SCTP socket options: #{inspect(reason)}")
            emit_telemetry(:sockopt_error, %{protocol: :sctp, error: reason}, %{})
            error
        end
      false ->
        error = {:error, :socket_registration_failed}
        Logger.warning("Failed to register SCTP socket")
        emit_telemetry(:sockopt_error, %{protocol: :sctp, error: :registration_failed}, %{})
        error
    end
  end

  @doc """
  Registers a socket with the inet database.

  Required for proper socket management in the Erlang inet system.

  ## Parameters

  - `socket` - Socket to register

  ## Returns

  - `true` - Socket registered successfully
  - `false` - Failed to register socket
  """
  @spec register_socket(t()) :: boolean()
  def register_socket(%__MODULE__{type: :tcp, sock: socket}),
    do: :inet_db.register_socket(socket, :inet_tcp)

  def register_socket(%__MODULE__{type: :sctp, sock: socket}),
    do: :inet_db.register_socket(socket, :inet_sctp)

  @doc """
  Returns the local address and port number for a socket.

  Gets the local binding information for the socket with protocol-aware handling.

  ## Parameters

  - `socket` - Socket to query

  ## Returns

  - `{:ok, {ip, port}}` - Successfully retrieved local address
  - `{:local, path}` - Unix domain socket path
  - `{:unspec, <<>>}` - Unspecified address
  - `{:undefined, term}` - Undefined address
  - `{:error, reason}` - Failed to get address

  ## Examples

      iex> Socket.sockname(socket)
      {:ok, {{127, 0, 0, 1}, 8080}}

  """
  @spec sockname(t()) ::
          {:ok, {ip_address(), port_number()}}
          | {:local, binary()}
          | {:unspec, <<>>}
          | {:undefined, any()}
          | {:error, term()}
  def sockname(%__MODULE__{type: type, sock: socket}) when type in [:udp, :tcp, :sctp],
    do: :inet.sockname(socket)

  def sockname(%__MODULE__{type: type, sock: socket}) when type in [:dtls, :tls],
    do: :ssl.sockname(socket)

  @doc """
  Returns the peer address and port number for a socket.

  Gets the remote peer information for connected sockets with protocol-aware handling.

  ## Parameters

  - `socket` - Socket to query

  ## Returns

  - `{:ok, {ip, port}}` - Successfully retrieved peer address
  - `{:local, path}` - Unix domain socket path
  - `{:unspec, <<>>}` - Unspecified address
  - `{:undefined, term}` - Undefined address
  - `{:error, reason}` - Failed to get peer address

  ## Examples

      iex> Socket.peername(socket)
      {:ok, {{192, 168, 1, 100}, 45678}}

  """
  @spec peername(t()) ::
          {:ok, {ip_address(), port_number()}}
          | {:local, binary()}
          | {:unspec, <<>>}
          | {:undefined, any()}
          | {:error, term()}
  def peername(%__MODULE__{type: type, sock: socket}) when type in [:udp, :tcp, :sctp],
    do: :inet.peername(socket)

  def peername(%__MODULE__{type: type, sock: socket}) when type in [:dtls, :tls],
    do: :ssl.peername(socket)

  @doc """
  Returns the port number for a UDP socket.

  Gets the local port number that the socket is bound to.

  ## Parameters

  - `socket` - UDP socket to query

  ## Returns

  - `{:ok, port}` - Successfully retrieved port number
  - `{:error, reason}` - Failed to get port

  ## Examples

      iex> Socket.port(udp_socket)
      {:ok, 8080}

  """
  @spec port(t()) :: {:ok, port_number()} | {:error, term()}
  def port(%__MODULE__{type: :udp, sock: sock}),
    do: :inet.port(sock)

  @doc """
  Enhanced socket close with proper logging and cleanup.

  Closes sockets with protocol-specific handling and telemetry emission.
  Includes graceful error handling for unsupported protocols.

  ## Parameters

  - `socket` - Socket to close
  - `reason` - Reason for closing (for logging)

  ## Returns

  - `:ok` - Socket closed successfully

  ## Examples

      iex> Socket.close(socket, "connection_timeout")
      :ok

  """
  @spec close(t() | any(), any()) :: :ok
  def close(sock, reason \\ "")

  def close(%__MODULE__{type: :udp, sock: socket}, reason) do
    :gen_udp.close(socket)
    emit_telemetry(:socket_closed, %{protocol: :udp}, %{reason: reason})
    Logger.debug("UDP socket closed: #{inspect(reason)}")
    :ok
  end

  def close(%__MODULE__{type: :tcp, sock: socket}, reason) do
    :gen_tcp.close(socket)
    emit_telemetry(:socket_closed, %{protocol: :tcp}, %{reason: reason})
    Logger.debug("TCP socket closed: #{inspect(reason)}")
    :ok
  end

  def close(%__MODULE__{type: :dtls, sock: socket}, reason) do
    :ssl.close(socket)
    emit_telemetry(:socket_closed, %{protocol: :dtls}, %{reason: reason})
    Logger.debug("DTLS socket closed: #{inspect(reason)}")
    :ok
  end

  def close(%__MODULE__{type: :tls, sock: socket}, reason) do
    :ssl.close(socket)
    emit_telemetry(:socket_closed, %{protocol: :tls}, %{reason: reason})
    Logger.debug("TLS socket closed: #{inspect(reason)}")
    :ok
  end

  def close(%__MODULE__{type: :sctp, sock: socket}, reason) do
    try do
      :gen_sctp.close(socket)
    rescue
      _ -> :ok  # Ignore errors when SCTP is not available
    end
    emit_telemetry(:socket_closed, %{protocol: :sctp}, %{reason: reason})
    Logger.debug("SCTP socket closed: #{inspect(reason)}")
    :ok
  end

  def close(_, reason) do
    Logger.debug("Attempted to close nil socket: #{inspect(reason)}")
    :ok
  end

  @doc """
  Emit telemetry events for monitoring TURN server performance.

  Emits telemetry events with the `:xturn_sockets` prefix for monitoring
  and observability. Gracefully handles cases where telemetry is unavailable.

  ## Parameters

  - `event_name` - Name of the event to emit
  - `measurements` - Map of numeric measurements
  - `metadata` - Map of additional metadata

  ## Returns

  - `:ok` - Event emitted successfully

  ## Examples

      iex> Socket.emit_telemetry(:connection_opened, %{count: 1}, %{ip: {127, 0, 0, 1}})
      :ok

  """
  @spec emit_telemetry(atom(), map(), map()) :: :ok
  def emit_telemetry(event_name, measurements, metadata) do
    if get_config(:telemetry_enabled, true) do
      :telemetry.execute(
        [:xturn_sockets, event_name],
        measurements,
        metadata
      )
    end
  rescue
    _ ->
      # Fail silently if telemetry is not available
      :ok
  end

  # ----------------------------
  # Private functions
  # ----------------------------

  # Opens an available UDP port as per requirement.
  # See RFC's
  defp open_free_udp_port(:random, udp_options) do
    ## BUGBUG: Should be a random port
    case :gen_udp.open(0, udp_options) do
      {:ok, socket} ->
        {:ok, %__MODULE__{type: :udp, sock: socket}}

      {:error, reason} ->
        Logger.error("UDP open #{inspect(udp_options)} -> #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp open_free_udp_port({:range, min_port, max_port}, udp_options) when min_port <= max_port do
    case :gen_udp.open(min_port, udp_options) do
      {:ok, socket} ->
        {:ok, %__MODULE__{type: :udp, sock: socket}}

      {:error, :eaddrinuse} ->
        policy2 = {:range, min_port + 1, max_port}
        open_free_udp_port(policy2, udp_options)

      {:error, reason} ->
        Logger.error("UDP open #{inspect([0 | udp_options])} -> #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp open_free_udp_port({:range, _min_port, _max_port}, udp_options) do
    reason = "Port range exhausted"
    Logger.error("UDP open #{inspect([0 | udp_options])} -> #{inspect(reason)}")
    {:error, reason}
  end

  defp open_free_udp_port({:preferred, port}, udp_options) do
    case :gen_udp.open(port, udp_options) do
      {:ok, socket} ->
        {:ok, %__MODULE__{type: :udp, sock: socket}}

      {:error, :eaddrinuse} ->
        policy2 = :random
        open_free_udp_port(policy2, udp_options)

      {:error, reason} ->
        Logger.error("UDP open #{inspect([0 | udp_options])} -> #{inspect(reason)}")
        {:error, reason}
    end
  end
end
