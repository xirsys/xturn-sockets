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

defmodule Xirsys.Sockets.Listener.UDP do
  @moduledoc """
  Enhanced UDP protocol socket handler optimized for TURN server usage.

  Includes rate limiting, connection tracking, and robust error handling.
  Designed specifically for STUN/TURN protocols (RFC 5389, RFC 5766) which
  require 5-tuple information for proper operation.

      ## Callback Interface

  Your callback module must implement:

      def process_buffer(data, client_ip, client_port, server_ip, server_port)

  Where:
  - `data` - Binary packet data received
  - `client_ip` - Client IP address tuple
  - `client_port` - Client port number
  - `server_ip` - Server IP address tuple
  - `server_port` - Server port number

  And:

      def dispatch(conn)

  Where:
  - `conn` - `%Xirsys.Sockets.Conn{}` struct with parsed message and connection info

  The 5-tuple information during `process_buffer` is essential for:
  - STUN XOR-MAPPED-ADDRESS responses (RFC 5389)
  - TURN allocation and permission management (RFC 5766)
  - Proper WebRTC compatibility

  ## Example

      defmodule MySTUNHandler do
        def process_buffer(data, client_ip, client_port, server_ip, server_port) do
          # Parse STUN/TURN packet with full connection context
          case parse_stun_packet(data, client_ip, client_port, server_ip, server_port) do
            {:ok, packet} -> {packet, <<>>}
            {:error, _} -> {nil, <<>>}
          end
        end

        def dispatch(conn) do
          # Handle processed STUN/TURN message
          send_stun_response(conn)
        end
      end

  """
  use GenServer
  require Logger

  @buf_size 256 * 1024  # Reduced from 1GB for better memory management
  @opts [active: false, buffer: @buf_size, recbuf: @buf_size, sndbuf: @buf_size]

  alias Xirsys.Sockets.{Socket, Conn}

  # TURN-specific enhancements
  @max_packet_size 64 * 1024  # 64KB max packet for TURN
  @connection_cleanup_interval 300_000  # 5 minutes

  #####
  # External API

  @doc """
  Standard OTP module startup with enhanced configuration
  """
  def start_link(cb, ip, port) do
    GenServer.start_link(__MODULE__, [cb, ip, port, false])
  end

  def start_link(cb, ip, port, ssl) do
    GenServer.start_link(__MODULE__, [cb, ip, port, ssl], debug: [:statistics])
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

    # Schedule periodic cleanup
    if Socket.get_config(:connection_cleanup_enabled, true) do
      Process.send_after(self(), :cleanup_connections, @connection_cleanup_interval)
    end

    case open_socket(cb, ip, port, ssl, opts) do
      {:ok, state} ->
        Socket.emit_telemetry(:udp_listener_started, %{}, %{ip: ip, port: port, ssl: ssl})
        {:ok, Map.put(state, :connections, %{})}

      {:ok, state, timeout} ->
        Socket.emit_telemetry(:udp_listener_started, %{}, %{ip: ip, port: port, ssl: ssl})
        {:ok, Map.put(state, :connections, %{}), timeout}

      {:error, reason} = error ->
        Socket.emit_telemetry(:udp_listener_error, %{error: reason}, %{ip: ip, port: port})
        Logger.error("UDP listener failed to start: #{inspect(reason)}")
        error
    end
  end

  def handle_call({:get_connection_count}, _from, state) do
    count = map_size(Map.get(state, :connections, %{}))
    {:reply, count, state}
  end

  def handle_call(other, _from, state) do
    Logger.warning("UDP listener: unexpected call: #{inspect(other)}")
    {:noreply, state}
  end

  @doc """
  Enhanced asynchronous socket response handler with rate limiting
  """
  def handle_cast({msg, ip, port}, state) do
    case Socket.check_rate_limit(ip) do
      :ok ->
        case Map.get(state, :socket) do
          nil ->
            Logger.warning("Attempted to send on closed UDP socket")
            {:noreply, state}

          socket ->
            case Socket.send(socket, msg, ip, port) do
              :ok ->
                Socket.emit_telemetry(:udp_message_relayed, %{bytes: byte_size(msg)}, %{ip: ip, port: port})
                {:noreply, state}

              {:error, reason} ->
                Logger.warning("UDP send failed: #{inspect(reason)}")
                Socket.emit_telemetry(:udp_send_error, %{error: reason}, %{ip: ip, port: port})
                {:noreply, state}
            end
        end

      {:error, :rate_limited} ->
        Logger.info("Rate limited UDP client: #{inspect(ip)}")
        Socket.emit_telemetry(:rate_limit_exceeded, %{}, %{ip: ip, port: port})
        {:noreply, state}
    end
  end

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  def handle_cast(other, state) do
    Logger.warning("UDP listener: unexpected cast: #{inspect(other)}")
    {:noreply, state}
  end

  def handle_info(:cleanup_connections, state) do
    # Clean up stale connection tracking data
    now = System.monotonic_time(:second)
    cutoff = now - 300  # 5 minutes ago

    connections =
      state
      |> Map.get(:connections, %{})
      |> Enum.filter(fn {_, last_seen} -> last_seen > cutoff end)
      |> Map.new()

    cleaned_count = map_size(Map.get(state, :connections, %{})) - map_size(connections)

    if cleaned_count > 0 do
      Logger.debug("Cleaned up #{cleaned_count} stale UDP connections")
      Socket.emit_telemetry(:connections_cleaned, %{count: cleaned_count}, %{})
    end

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_connections, @connection_cleanup_interval)

    {:noreply, %{state | connections: connections}}
  end

  def handle_info(:timeout, state) do
    case Map.get(state, :socket) do
      nil -> {:noreply, state}
      socket ->
        Socket.setopts(socket)
        :erlang.process_flag(:priority, :high)
        {:noreply, state}
    end
  end

  @doc """
  Enhanced message handler for incoming UDP packets with security checks
  """
  def handle_info({:udp, _fd, fip, fport, msg}, state) do
    # Basic security checks
    cond do
      byte_size(msg) > @max_packet_size ->
        Logger.warning("Oversized UDP packet from #{inspect(fip)}:#{fport} (#{byte_size(msg)} bytes)")
        Socket.emit_telemetry(:oversized_packet, %{bytes: byte_size(msg)}, %{ip: fip, port: fport})
        {:noreply, state}

      byte_size(msg) == 0 ->
        Logger.debug("Empty UDP packet from #{inspect(fip)}:#{fport}")
        {:noreply, state}

      true ->
        process_udp_packet(fip, fport, msg, state)
    end
  end

  def handle_info(info, state) do
    Logger.warning("UDP listener: unexpected info: #{inspect(info)}")
    {:noreply, state}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(reason, state) do
    Logger.info("UDP listener terminating: #{inspect(reason)}")

    case Map.get(state, :socket) do
      nil -> :ok
      socket -> Socket.close(socket, reason)
    end

    Socket.emit_telemetry(:udp_listener_stopped, %{}, %{reason: reason})
    :ok
  end

  # Private functions

  defp process_udp_packet(fip, fport, msg, state) do
    # Rate limiting check
    case Socket.check_rate_limit(fip) do
      :ok ->
        handle_valid_packet(fip, fport, msg, state)

      {:error, :rate_limited} ->
        Logger.debug("Rate limited UDP packet from #{inspect(fip)}:#{fport}")
        Socket.emit_telemetry(:rate_limit_exceeded, %{}, %{ip: fip, port: fport})
        {:noreply, state}
    end
  end

  defp handle_valid_packet(fip, fport, msg, state) do
    Logger.debug("UDP received #{byte_size(msg)} bytes from #{inspect(fip)}:#{fport}")

    socket = Map.get(state, :socket)
    callback = Map.get(state, :callback)

    # Update connection tracking
    now = System.monotonic_time(:second)
    connections = Map.put(Map.get(state, :connections, %{}), {fip, fport}, now)

    # Get socket name for response
    case Socket.sockname(socket) do
      {:ok, {_, tport}} ->
        # Process the packet with 5-tuple information for STUN/TURN protocols
        case callback.process_buffer(msg, fip, fport, Socket.server_ip(), tport) do
          {packet, _} when not is_nil(packet) ->
            conn = %Conn{
              message: packet,
              listener: self(),
              client_socket: socket,
              client_ip: fip,
              client_port: fport,
              server_ip: Socket.server_ip(),
              server_port: tport
            }

            # Dispatch asynchronously to avoid blocking the listener
            Task.start(fn ->
              try do
                callback.dispatch(conn)
                Socket.send_to_client_hooks(conn)
              rescue
                error ->
                  Logger.warning("UDP packet processing error: #{inspect(error)}")
                  Socket.emit_telemetry(:packet_processing_error, %{error: inspect(error)}, %{ip: fip, port: fport})
              end
            end)

            Socket.emit_telemetry(:udp_packet_processed, %{bytes: byte_size(msg)}, %{ip: fip, port: fport})

          {nil, _} ->
            Logger.debug("Incomplete UDP packet from #{inspect(fip)}:#{fport}")
            Socket.emit_telemetry(:incomplete_packet, %{}, %{ip: fip, port: fport})
        end

        # Reset socket options
        Socket.setopts(socket)
        :erlang.process_flag(:priority, :high)

        {:noreply, %{state | connections: connections}}

      {:error, reason} ->
        Logger.warning("Failed to get socket name: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp open_socket(cb, ip, port, ssl, opts) do
    unless valid_ip?(ip) do
      {:error, :invalid_ip_address}
    else
      case ssl do
        {:ssl, true} ->
          case :application.get_env(:certs) do
            {:ok, certs} ->
              nopts = opts ++ certs ++ [protocol: :dtls]

              case :ssl.listen(port, nopts) do
                {:ok, fd} ->
                  fd = %Socket{type: :dtls, sock: fd}

                  try do
                    Xirsys.Sockets.Client.create(fd, cb, ssl)
                  catch
                    :exit, _reason ->
                      # Supervisor not available, continue without client process
                      Logger.debug("Supervisor not available, continuing without client process")
                  end

                  case resolve_addr(fd, ip, port) do
                    {:ok, {nip, nport}} ->
                      Logger.info(
                        "UDP listener #{inspect(self())} started at [#{:inet_parse.ntoa(nip)}:#{nport}]"
                      )

                      {:ok, %{listener: fd, ssl: ssl}}

                    error ->
                      error
                  end

                error ->
                  error
              end

            :undefined ->
              {:error, :no_certificates_configured}
          end

        _ ->
          {:ok, fd} = :gen_udp.open(port, opts)
          {:ok, {nip, nport}} = resolve_addr(fd, ip, port)

          Logger.info(
            "UDP listener #{inspect(self())} started at [#{:inet_parse.ntoa(nip)}:#{nport}]"
          )

          {:ok, %{socket: %Socket{type: :udp, sock: fd}, callback: cb, ssl: ssl}, 0}
      end
    end
  end

  defp resolve_addr(fd, ip, port) do
    case :inet.sockname(fd) do
      {:ok, {_, _}} = addr -> addr
      _ -> {:ok, {ip, port}}
    end
  end

  defp valid_ip?(ip),
    do: Enum.reduce(Tuple.to_list(ip), true, &(is_integer(&1) and &1 >= 0 and &1 <= 255 and &2))
end
