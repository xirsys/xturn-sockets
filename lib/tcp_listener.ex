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

defmodule Xirsys.Sockets.Listener.TCP do
  @moduledoc """
  Enhanced TCP protocol socket listener optimized for TURN server usage
  Includes connection management, rate limiting, and robust error handling
  """
  use GenServer
  require Logger
  alias Xirsys.Sockets.Socket

  # Enhanced buffer sizes for TURN server performance
  @buf_size 64 * 1024  # 64KB for TCP connections
  @opts [
    reuseaddr: true,
    keepalive: true,
    backlog: 100,  # Increased backlog for TURN server
    active: false,
    buffer: @buf_size,
    recbuf: @buf_size,
    sndbuf: @buf_size,
    nodelay: true  # Important for low-latency TURN
  ]

  # TURN-specific connection management
  @max_connections 1000  # Max concurrent TCP connections
  @connection_timeout 300_000  # 5 minutes idle timeout
  @cleanup_interval 60_000  # 1 minute cleanup cycle

  #####
  # External API

  @doc """
  Enhanced OTP module startup with connection tracking
  """
  def start_link(cb, ip, port) do
    GenServer.start_link(__MODULE__, [cb, ip, port, false])
  end

  def start_link(cb, ip, port, ssl) do
    GenServer.start_link(__MODULE__, [cb, ip, port, ssl])
  end

  @doc """
  Initialises connection with IPv6 address and enhanced options
  """
  def init([cb, {_, _, _, _, _, _, _, _} = ip, port, ssl]) do
    opts = @opts ++ [ip: ip] ++ [:binary, :inet6]
    initialize_listener(cb, ip, port, ssl, opts)
  end

  def init([cb, {_, _, _, _} = ip, port, ssl]) do
    opts = @opts ++ [ip: ip] ++ [:binary]
    initialize_listener(cb, ip, port, ssl, opts)
  end

  defp initialize_listener(cb, ip, port, ssl, opts) do
    # Initialize connection tracking
    Process.flag(:trap_exit, true)

    # Initialize ETS table for connection tracking
    :ets.new(:tcp_connections, [:named_table, :public, {:write_concurrency, true}])

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_connections, @cleanup_interval)

    case open_socket(cb, ip, port, ssl, opts) do
      {:ok, state} ->
        Socket.emit_telemetry(:tcp_listener_started, %{}, %{ip: ip, port: port, ssl: ssl})
        {:ok, Map.put(state, :connection_count, 0)}

      {:error, reason} = error ->
        Socket.emit_telemetry(:tcp_listener_error, %{error: reason}, %{ip: ip, port: port})
        Logger.error("TCP listener failed to start: #{inspect(reason)}")
        error
    end
  end

  def handle_call({:get_connection_count}, _from, state) do
    count = Map.get(state, :connection_count, 0)
    {:reply, count, state}
  end

  def handle_call({:get_active_connections}, _from, state) do
    connections = :ets.tab2list(:tcp_connections)
    {:reply, length(connections), state}
  end

  def handle_call(other, _from, state) do
    Logger.warning("TCP listener: unexpected call: #{inspect(other)}")
    {:noreply, state}
  end

  def handle_cast({:connection_established, client_ip}, state) do
    # Track new connection
    now = System.monotonic_time(:second)
    :ets.insert(:tcp_connections, {client_ip, now})
    Socket.emit_telemetry(:tcp_connection_established, %{}, %{ip: client_ip})
    {:noreply, state}
  end

  def handle_cast({:connection_closed, client_ip}, state) do
    # Remove connection tracking
    :ets.delete(:tcp_connections, client_ip)
    Socket.emit_telemetry(:tcp_connection_closed, %{}, %{ip: client_ip})
    {:noreply, state}
  end

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  def handle_cast(other, state) do
    Logger.warning("TCP listener: unexpected cast: #{inspect(other)}")
    {:noreply, state}
  end

  def handle_info(:cleanup_connections, state) do
    # Clean up stale connections
    now = System.monotonic_time(:second)
    timeout_ms = Socket.get_config(:connection_timeout, @connection_timeout)
    cutoff = now - div(timeout_ms, 1000)  # Convert to seconds

    stale_connections =
      :ets.select(:tcp_connections, [
        {{'$1', '$2'}, [{:<, '$2', cutoff}], ['$1']}
      ])

    Enum.each(stale_connections, fn ip ->
      :ets.delete(:tcp_connections, ip)
      Logger.debug("Cleaned up stale TCP connection: #{inspect(ip)}")
    end)

    if length(stale_connections) > 0 do
      Socket.emit_telemetry(:tcp_connections_cleaned, %{count: length(stale_connections)}, %{})
    end

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_connections, @cleanup_interval)

    {:noreply, state}
  end

  def handle_info({:check_connection_limit, client_ip}, state) do
    # Check if we should accept this connection
    case Socket.check_rate_limit(client_ip) do
      :ok ->
        current_connections = :ets.info(:tcp_connections, :size) || 0
        max_allowed = Socket.get_config(:max_tcp_connections, @max_connections)

        if current_connections >= max_allowed do
          Logger.warning("TCP connection limit exceeded (#{current_connections}/#{max_allowed})")
          Socket.emit_telemetry(:tcp_connection_limit_exceeded, %{count: current_connections}, %{ip: client_ip})
          {:noreply, state}
        else
          # Connection is allowed
          {:noreply, state}
        end

      {:error, :rate_limited} ->
        Logger.info("Rate limited TCP connection from: #{inspect(client_ip)}")
        Socket.emit_telemetry(:tcp_rate_limit_exceeded, %{}, %{ip: client_ip})
        {:noreply, state}
    end
  end

  def handle_info(other, state) do
    Logger.warning("TCP listener: unexpected info: #{inspect(other)}")
    {:noreply, state}
  end

  def terminate(reason, %{:listener => listener} = _state) do
    Logger.info("TCP listener terminating: #{inspect(reason)}")

    # Clean up ETS table
    case :ets.whereis(:tcp_connections) do
      :undefined -> :ok
      _ -> :ets.delete(:tcp_connections)
    end

    Socket.close(listener, reason)
    Socket.emit_telemetry(:tcp_listener_stopped, %{}, %{reason: reason})
    :ok
  end

  def terminate(reason, _state) do
    Logger.info("TCP listener terminating without listener: #{inspect(reason)}")
    :ok
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  # Enhanced SSL/TLS configuration for TURN servers
  @secure_ssl_options [
    {:versions, [:'tlsv1.2', :'tlsv1.3']},
    {:secure_renegotiate, true},
    {:reuse_sessions, false},  # Disable for better security
    {:honor_cipher_order, true},
    {:fail_if_no_peer_cert, false},  # Allow anonymous clients for TURN
    {:verify, :verify_none},  # TURN servers often handle verification at app level
    {:depth, 2}
  ]

  defp open_socket(cb, ip, port, ssl, opts) do
    unless valid_ip?(ip) do
      {:error, :invalid_ip_address}
    else
      socket_result =
        case ssl do
          true ->
            case :application.get_env(:certs) do
              {:ok, certs} ->
                # Merge with secure options for TURN server
                secure_opts = Socket.get_config(:ssl_options, @secure_ssl_options)
                nopts = opts ++ certs ++ secure_opts

                case :ssl.listen(port, nopts) do
                  {:ok, sock} ->
                    Socket.emit_telemetry(:tls_listener_created, %{}, %{ip: ip, port: port})
                    {:ok, %Socket{type: :tls, sock: sock}}
                  {:error, reason} = error ->
                    Socket.emit_telemetry(:tls_listener_error, %{error: reason}, %{ip: ip, port: port})
                    error
                end
              :undefined ->
                {:error, :no_certificates_configured}
            end

          _ ->
            case :gen_tcp.listen(port, opts) do
              {:ok, sock} ->
                Socket.emit_telemetry(:tcp_listener_created, %{}, %{ip: ip, port: port})
                {:ok, %Socket{type: :tcp, sock: sock}}
              {:error, reason} = error ->
                Socket.emit_telemetry(:tcp_listener_error, %{error: reason}, %{ip: ip, port: port})
                error
            end
        end

      case socket_result do
        {:ok, socket} ->
          try do
            Xirsys.Sockets.Client.create(socket, cb, ssl)
          catch
            :exit, reason ->
              # Supervisor not available, continue without client process
              Logger.debug("Supervisor not available, continuing without client process: #{inspect(reason)}")
              Socket.emit_telemetry(:supervisor_unavailable, %{reason: reason}, %{})
          end

          Logger.info("TCP listener started at [#{:inet_parse.ntoa(ip)}:#{port}]")
          {:ok, %{listener: socket, ssl: ssl, callback: cb}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp valid_ip?(ip),
    do: Enum.reduce(Tuple.to_list(ip), true, &(is_integer(&1) and &1 >= 0 and &1 <= 255 and &2))
end
