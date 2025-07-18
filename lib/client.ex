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

defmodule Xirsys.Sockets.Client do
  @moduledoc """
  TCP protocol socket client for TURN server usage.

  Handles TCP connections with buffering and provides 5-tuple information
  to callbacks for proper STUN/TURN protocol processing.

    ## Callback Interface

  Your callback module must implement:

      def process_buffer(data, client_ip, client_port, server_ip, server_port)

  Where:
  - `data` - Binary data from TCP stream (may be partial packets)
  - `client_ip` - Client IP address tuple
  - `client_port` - Client port number
  - `server_ip` - Server IP address tuple
  - `server_port` - Server port number

  The function should return `{parsed_packet, remaining_buffer}` where:
  - `parsed_packet` - Complete packet ready for processing (or `nil` if incomplete)
  - `remaining_buffer` - Any remaining unparsed data

  The 5-tuple information is essential for STUN/TURN over TCP (RFC 5389, RFC 5766).

  ## Example

      defmodule MyTCPHandler do
        def process_buffer(data, client_ip, client_port, server_ip, server_port) do
          case parse_stun_packet(data, client_ip, client_port, server_ip, server_port) do
            {:ok, packet, rest} -> {packet, rest}
            {:partial, _} -> {nil, data}  # Wait for more data
          end
        end

        def dispatch(conn) do
          # Process complete STUN/TURN packet
          handle_packet(conn.message, conn)
        end
      end

  """
  use GenServer
  require Logger

  alias Xirsys.Sockets.{Conn, Socket}

  #####
  # External API

  @type callback() :: (pid(), any(), binary(), binary() -> :ok)

  @doc """
  Standard OTP module startup
  """
  @spec start_link(pid(), callback(), boolean()) :: :ok
  def start_link(socket, callback, ssl) do
    GenServer.start_link(__MODULE__, [socket, callback, ssl])
  end

  def create(socket, callback, ssl) do
    Xirsys.Sockets.SockSupervisor.start_child(socket, callback, ssl)
  end

  def init([socket, callback, ssl]) do
    Logger.debug("Client init")

    {:ok,
     %{
       callback: callback,
       accepted: false,
       list_socket: socket,
       cli_socket: nil,
       addr: nil,
       buffer: <<>>,
       ssl: ssl,
       cache: %{}
     }, 0}
  end

  @doc """
  Asynchronous socket response handler
  """
  def handle_cast({msg, ip, port}, %{cli_socket: socket} = state) do
    # Select proper client
    Logger.debug(
      "Dispatching TCP to #{inspect(ip)}:#{inspect(port)} | #{inspect(byte_size(msg))} bytes"
    )

    Socket.send(socket, msg)
    {:noreply, state}
  end

  def handle_cast(:stop, state),
    do: {:stop, :normal, state}

  def handle_cast(other, state) do
    Logger.debug("TCP client: strange cast: #{inspect(other)}")
    {:noreply, state}
  end

  def handle_call(other, _from, state) do
    Logger.debug("TCP client: strange call: #{inspect(other)}")
    {:noreply, state}
  end

  def handle_info(:timeout, %{list_socket: list_socket, callback: cb} = state) do
    Logger.debug("handle_info timeout #{inspect(cb)}")

    with {:ok, cli_socket} <- Socket.handshake(list_socket),
         {:ok, client_ip_port} <- Socket.peername(cli_socket),
         {:ok, {_, sport}} <- Socket.sockname(cli_socket) do
      Logger.debug("#{inspect(list_socket)}")
      create(list_socket, cb, false)
      Socket.set_sockopt(list_socket, cli_socket)
      Socket.setopts(cli_socket)
      Logger.debug("returning from timeout")

      {:noreply,
       %{
         state
         | accepted: true,
           cli_socket: cli_socket,
           addr: {client_ip_port, {Socket.server_ip(), sport}}
       }}
    end
  end

  @doc """
  Message handler to update cache
  """
  def handle_info({:cache, cache}, state) do
    {:noreply, %{state | :cache => cache}}
  end

  def handle_info(
        {_, _client, data},
        %{cli_socket: socket, addr: {{fip, fport}, {_, tport}}, buffer: buffer, cache: cache} =
          state
      ) do
    Logger.debug("handle_info tcp")

    with {:ok, ip_port} <- Socket.peername(socket) do
      Logger.debug("TCP called from #{inspect(ip_port)} with #{inspect(byte_size(data))} BYTES")

      buffer =
        case state.callback.process_buffer(<<buffer::binary, data::binary>>, fip, fport, Socket.server_ip(), tport) do
          {nil, buffer} ->
            buffer

          {packet, buffer} ->
            conn = %Conn{
              message: packet,
              listener: self(),
              client_socket: socket,
              client_ip: fip,
              client_port: fport,
              server_ip: Socket.server_ip(),
              server_port: tport,
              cache: cache
            }

            state.callback.dispatch(conn)
            Socket.send_to_client_hooks(conn)
            buffer
        end

      Socket.setopts(socket)
      {:noreply, %{state | :buffer => buffer}}
    end
  end

  def handle_info({:ssl_closed, client}, state) do
    Logger.debug("Client #{inspect(client)} closed connection")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_closed, client}, state) do
    Logger.debug("Client #{inspect(client)} closed connection")
    {:stop, :normal, state}
  end

  def handle_info(info, state) do
    Logger.debug("TCP client: strange info: #{inspect(info)}")
    {:noreply, state}
  end

  def terminate(
        reason,
        %{cli_socket: socket, list_socket: list_socket, callback: cb, accepted: false, ssl: ssl} =
          _state
      ) do
    create(list_socket, cb, ssl)
    Socket.close(socket)
    Logger.debug("TCP client closed: #{inspect(reason)}")
    :ok
  end

  def terminate(reason, %{cli_socket: socket} = _state) do
    Socket.close(socket)
    Logger.debug("TCP client closed: #{inspect(reason)}")
    :ok
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end
end
