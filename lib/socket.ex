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
  Socket protocol helpers optimized for TURN server usage
  """
  require Logger

  defstruct type: :udp, sock: nil

  @type t :: {
          type :: :udp | :tcp | :dtls | :tls,
          sock :: port()
        }

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
  Returns TURN server configuration values
  """
  def get_config(key, default \\ nil) do
    Application.get_env(:xturn_sockets, key,
      Application.get_env(:xturn, key, default))
  end

  def connection_timeout(), do: get_config(:connection_timeout, @connection_timeout)
  def ssl_handshake_timeout(), do: get_config(:ssl_handshake_timeout, @ssl_handshake_timeout)
  def max_connections_per_ip(), do: get_config(:max_connections_per_ip, @max_connections_per_ip)
  def rate_limit_enabled?(), do: get_config(:rate_limit_enabled, true)

  @doc """
  Returns the server ip from config for packet use
  """
  @spec server_ip() :: tuple()
  def server_ip(),
    do: Application.get_env(:xturn, :server_ip, {0, 0, 0, 0})

  @doc """
  Returns the client message hooks from config
  """
  @spec client_hooks() :: list()
  def client_hooks() do
    case Application.get_env(:xturn, :client_hooks, []) do
      hooks when is_list(hooks) -> hooks
      _ -> []
    end
  end

  @doc """
  Returns the peer message hooks from config
  """
  @spec peer_hooks() :: list()
  def peer_hooks() do
    case Application.get_env(:xturn, :peer_hooks, []) do
      hooks when is_list(hooks) -> hooks
      _ -> []
    end
  end

  @doc """
  Returns the servers local ip from the config
  """
  @spec server_local_ip() :: tuple()
  def server_local_ip(),
    do: Application.get_env(:xturn, :server_local_ip, {0, 0, 0, 0})

  @doc """
  Enhanced rate limiting check for TURN server protection
  """
  @spec check_rate_limit(tuple()) :: :ok | {:error, :rate_limited}
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
  Opens a new port for UDP TURN transport with enhanced options
  """
  @spec open_port(tuple(), atom(), list()) :: {:ok, t()} | {:error, atom()}
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
  Enhanced handshake with timeout and better error handling
  """
  @spec handshake(%__MODULE__{}) :: {:ok, %__MODULE__{}} | {:error, any()}
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
  Sends a message over an open socket with enhanced error handling
  """
  @spec send(%__MODULE__{}, binary(), tuple() | nil, integer() | nil) ::
          :ok | {:error, term()} | no_return()
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

  @doc """
  Sends data to peer hooks with error handling
  """
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
  Sends data to client hooks with error handling
  """
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
  """
  @spec setopts(port() | %__MODULE__{}, list()) :: :ok | {:error, term()}
  def setopts(socket, opts \\ @setopts_default)

  def setopts(%__MODULE__{type: type, sock: socket}, opts) when type in [:udp, :tcp],
    do: :inet.setopts(socket, opts)

  def setopts(%__MODULE__{type: _, sock: socket}, opts),
    do: :ssl.setopts(socket, opts)

  def setopts(socket, opts),
    do: :inet.setopts(socket, opts)

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
  Enhanced socket option setting with better error handling
  """
  @spec set_sockopt(%__MODULE__{}, %__MODULE__{}) :: :ok | {:error, term()}
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

  def register_socket(%__MODULE__{type: :tcp, sock: socket}),
    do: :inet_db.register_socket(socket, :inet_tcp)

  @doc """
  Returns the local address and port number for a socket.
  """
  @spec sockname(any()) ::
          {:ok, {tuple(), integer()}}
          | {:local, binary()}
          | {:unspec, <<>>}
          | {:undefined, any()}
          | {:error, term()}
  def sockname(%__MODULE__{type: type, sock: socket}) when type in [:udp, :tcp],
    do: :inet.sockname(socket)

  def sockname(%__MODULE__{type: type, sock: socket}) when type in [:dtls, :tls],
    do: :ssl.sockname(socket)

  @doc """
  Returns the peer address and port number for a socket.
  """
  @spec peername(any()) ::
          {:ok, {tuple(), integer()}}
          | {:local, binary()}
          | {:unspec, <<>>}
          | {:undefined, any()}
          | {:error, term()}
  def peername(%__MODULE__{type: type, sock: socket}) when type in [:udp, :tcp],
    do: :inet.peername(socket)

  def peername(%__MODULE__{type: type, sock: socket}) when type in [:dtls, :tls],
    do: :ssl.peername(socket)

  def port(%__MODULE__{type: :udp, sock: sock}),
    do: :inet.port(sock)

  @doc """
  Enhanced socket close with proper logging and cleanup
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

  def close(_, reason) do
    Logger.debug("Attempted to close nil socket: #{inspect(reason)}")
    :ok
  end

  @doc """
  Emit telemetry events for monitoring TURN server performance
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
