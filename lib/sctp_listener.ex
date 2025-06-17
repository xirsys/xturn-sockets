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

defmodule Xirsys.Sockets.Listener.SCTP do
  @moduledoc """
  Enhanced SCTP protocol socket listener optimized for TURN server usage
  Provides reliable message-oriented communication with multi-streaming support
  Includes connection management, rate limiting, and robust error handling
  """
  use GenServer
  require Logger
  alias Xirsys.Sockets.Socket

  # Enhanced buffer sizes for TURN server performance
  @buf_size 256 * 1024  # 256KB for SCTP connections
  @opts [
    reuseaddr: true,
    backlog: 100,  # Increased backlog for TURN server
    active: false,
    buffer: @buf_size,
    recbuf: @buf_size,
    sndbuf: @buf_size,
    nodelay: true,  # Important for low-latency TURN
    # SCTP-specific options
    sctp_nodelay: true,
    sctp_autoclose: 0,  # Disable auto-close for persistent connections
    sctp_maxseg: 1400,  # Maximum segment size for better network efficiency
    sctp_initmsg: %{num_ostreams: 10, max_instreams: 10, max_attempts: 4, max_init_timeo: 30000}
  ]

  # TURN-specific connection management
  @max_connections 1000  # Max concurrent SCTP connections
  @connection_timeout 300_000  # 5 minutes idle timeout
  @cleanup_interval 60_000  # 1 minute cleanup cycle
  @max_packet_size 64 * 1024  # 64KB max packet size for TURN

  #####
  # External API

  @doc """
  Enhanced OTP module startup with connection tracking
  """
  def start_link(cb, ip, port) do
    GenServer.start_link(__MODULE__, [cb, ip, port])
  end

  @doc """
  Initialises connection with IPv6 address and enhanced options
  """
  def init([cb, {_, _, _, _, _, _, _, _} = ip, port]) do
    opts = @opts ++ [ip: ip] ++ [:binary, :inet6]
    initialize_listener(cb, ip, port, opts)
  end

  def init([cb, {_, _, _, _} = ip, port]) do
    opts = @opts ++ [ip: ip] ++ [:binary]
    initialize_listener(cb, ip, port, opts)
  end

  defp initialize_listener(cb, ip, port, opts) do
    # Initialize connection tracking
    Process.flag(:trap_exit, true)

    # Initialize ETS table for connection tracking
    :ets.new(:sctp_connections, [:named_table, :public, {:write_concurrency, true}])

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_connections, @cleanup_interval)

    case open_socket(cb, ip, port, opts) do
      {:ok, state} ->
        Socket.emit_telemetry(:sctp_listener_started, %{}, %{ip: ip, port: port})
        {:ok, Map.put(state, :connection_count, 0)}

      {:error, reason} = error ->
        Socket.emit_telemetry(:sctp_listener_error, %{error: reason}, %{ip: ip, port: port})
        Logger.error("SCTP listener failed to start: #{inspect(reason)}")
        error
    end
  end

  def handle_call({:get_connection_count}, _from, state) do
    count = Map.get(state, :connection_count, 0)
    {:reply, count, state}
  end

  def handle_call({:get_active_connections}, _from, state) do
    connections = :ets.tab2list(:sctp_connections)
    {:reply, length(connections), state}
  end

  def handle_call(other, _from, state) do
    Logger.warning("SCTP listener: unexpected call: #{inspect(other)}")
    {:noreply, state}
  end

  def handle_cast({:connection_established, client_ip}, state) do
    # Track new connection
    now = System.monotonic_time(:second)
    :ets.insert(:sctp_connections, {client_ip, now})
    Socket.emit_telemetry(:sctp_connection_established, %{}, %{ip: client_ip})
    {:noreply, state}
  end

  def handle_cast({:connection_closed, client_ip}, state) do
    # Remove connection tracking
    :ets.delete(:sctp_connections, client_ip)
    Socket.emit_telemetry(:sctp_connection_closed, %{}, %{ip: client_ip})
    {:noreply, state}
  end

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  def handle_cast(other, state) do
    Logger.warning("SCTP listener: unexpected cast: #{inspect(other)}")
    {:noreply, state}
  end

  def handle_info(:cleanup_connections, state) do
    # Clean up stale connections
    now = System.monotonic_time(:second)
    timeout_ms = Socket.get_config(:connection_timeout, @connection_timeout)
    cutoff = now - div(timeout_ms, 1000)  # Convert to seconds

    stale_connections =
      :ets.select(:sctp_connections, [
        {{'$1', '$2'}, [{:<, '$2', cutoff}], ['$1']}
      ])

    Enum.each(stale_connections, fn ip ->
      :ets.delete(:sctp_connections, ip)
      Logger.debug("Cleaned up stale SCTP connection: #{inspect(ip)}")
    end)

    if length(stale_connections) > 0 do
      Socket.emit_telemetry(:sctp_connections_cleaned, %{count: length(stale_connections)}, %{})
    end

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_connections, @cleanup_interval)

    {:noreply, state}
  end

  def handle_info({:check_connection_limit, client_ip}, state) do
    # Check if we should accept this connection
    case Socket.check_rate_limit(client_ip) do
      :ok ->
        current_connections = :ets.info(:sctp_connections, :size) || 0
        max_allowed = Socket.get_config(:max_sctp_connections, @max_connections)

        if current_connections >= max_allowed do
          Logger.warning("SCTP connection limit exceeded (#{current_connections}/#{max_allowed})")
          Socket.emit_telemetry(:sctp_connection_limit_exceeded, %{count: current_connections}, %{ip: client_ip})
          {:noreply, state}
        else
          # Connection is allowed
          {:noreply, state}
        end

      {:error, :rate_limited} ->
        Logger.info("Rate limited SCTP connection from: #{inspect(client_ip)}")
        Socket.emit_telemetry(:sctp_rate_limit_exceeded, %{}, %{ip: client_ip})
        {:noreply, state}
    end
  end

  def handle_info({:sctp, socket, from_ip, from_port, ancillary_data, data}, state) do
    # Handle incoming SCTP messages
    try do
      # Validate packet size for TURN server
      if byte_size(data) > @max_packet_size do
        Logger.warning("SCTP packet too large from #{inspect(from_ip)}:#{from_port}: #{byte_size(data)} bytes")
        Socket.emit_telemetry(:sctp_packet_too_large, %{bytes: byte_size(data)}, %{ip: from_ip, port: from_port})
      else
        # Check rate limiting
        case Socket.check_rate_limit(from_ip) do
          :ok ->
            # Process the message asynchronously for better performance
            Task.start(fn ->
              process_sctp_message(socket, from_ip, from_port, ancillary_data, data, state)
            end)

          {:error, :rate_limited} ->
            Logger.info("Rate limited SCTP message from: #{inspect(from_ip)}")
            Socket.emit_telemetry(:sctp_rate_limit_exceeded, %{}, %{ip: from_ip, port: from_port})
        end
      end

      # Set socket back to active mode
      :inet.setopts(socket, [active: :once])
    rescue
      error ->
        Logger.error("Error processing SCTP message: #{inspect(error)}")
        Socket.emit_telemetry(:sctp_processing_error, %{error: inspect(error)}, %{ip: from_ip, port: from_port})
    end

    {:noreply, state}
  end

  def handle_info(other, state) do
    Logger.warning("SCTP listener: unexpected info: #{inspect(other)}")
    {:noreply, state}
  end

  def terminate(reason, %{:listener => listener} = _state) do
    Logger.info("SCTP listener terminating: #{inspect(reason)}")

    # Clean up ETS table
    case :ets.whereis(:sctp_connections) do
      :undefined -> :ok
      _ -> :ets.delete(:sctp_connections)
    end

    Socket.close(listener, reason)
    Socket.emit_telemetry(:sctp_listener_stopped, %{}, %{reason: reason})
    :ok
  end

  def terminate(reason, _state) do
    Logger.info("SCTP listener terminating without listener: #{inspect(reason)}")
    :ok
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  # Private functions

  defp process_sctp_message(socket, from_ip, from_port, ancillary_data, data, state) do
    # Extract SCTP-specific information from ancillary data
    stream_id = extract_stream_id(ancillary_data)
    ppid = extract_ppid(ancillary_data)

    Logger.debug("SCTP message from #{inspect(from_ip)}:#{from_port} stream #{stream_id} ppid #{ppid}")

    # Emit telemetry for monitoring
    Socket.emit_telemetry(:sctp_message_received,
      %{bytes: byte_size(data), stream_id: stream_id, ppid: ppid},
      %{ip: from_ip, port: from_port})

    # Process the message through the callback
    callback = Map.get(state, :callback)
    if callback do
      try do
        callback.handle_message(%Socket{type: :sctp, sock: socket}, data, from_ip, from_port, %{
          stream_id: stream_id,
          ppid: ppid,
          ancillary_data: ancillary_data
        })
      rescue
        error ->
          Logger.error("SCTP callback error: #{inspect(error)}")
          Socket.emit_telemetry(:sctp_callback_error, %{error: inspect(error)}, %{ip: from_ip, port: from_port})
      end
    end
  end

  defp extract_stream_id(ancillary_data) do
    # Extract stream ID from SCTP ancillary data
    case Enum.find(ancillary_data, fn {type, _} -> type == :sctp_sndrcvinfo end) do
      {:sctp_sndrcvinfo, info} -> Map.get(info, :stream, 0)
      _ -> 0
    end
  end

  defp extract_ppid(ancillary_data) do
    # Extract Payload Protocol Identifier from SCTP ancillary data
    case Enum.find(ancillary_data, fn {type, _} -> type == :sctp_sndrcvinfo end) do
      {:sctp_sndrcvinfo, info} -> Map.get(info, :ppid, 0)
      _ -> 0
    end
  end

  defp open_socket(cb, ip, port, opts) do
    unless valid_ip?(ip) do
      {:error, :invalid_ip_address}
    else
      try do
        case :gen_sctp.open(port, opts) do
          {:ok, sock} ->
            Socket.emit_telemetry(:sctp_listener_created, %{}, %{ip: ip, port: port})

            try do
              Xirsys.Sockets.Client.create(%Socket{type: :sctp, sock: sock}, cb, false)
            catch
              :exit, reason ->
                # Supervisor not available, continue without client process
                Logger.debug("Supervisor not available, continuing without client process: #{inspect(reason)}")
                Socket.emit_telemetry(:supervisor_unavailable, %{reason: reason}, %{})
            end

            Logger.info("SCTP listener started at [#{:inet_parse.ntoa(ip)}:#{port}]")
            {:ok, %{listener: %Socket{type: :sctp, sock: sock}, callback: cb}}

          {:error, reason} = error ->
            Socket.emit_telemetry(:sctp_listener_error, %{error: reason}, %{ip: ip, port: port})
            Logger.error("SCTP listener failed to open: #{inspect(reason)}")
            error
        end
      rescue
        error ->
          reason = :sctp_not_supported
          Socket.emit_telemetry(:sctp_listener_error, %{error: reason}, %{ip: ip, port: port})
          Logger.error("SCTP not supported: #{inspect(error)}")
          {:error, reason}
      end
    end
  end

  defp valid_ip?(ip),
    do: Enum.reduce(Tuple.to_list(ip), true, &(is_integer(&1) and &1 >= 0 and &1 <= 255 and &2))
end
