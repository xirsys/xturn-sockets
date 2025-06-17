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
  UDP protocol socket handler
  """
  use GenServer
  require Logger

  @buf_size 1024 * 1024 * 1024
  @opts [active: false, buffer: @buf_size, recbuf: @buf_size, sndbuf: @buf_size]

  alias Xirsys.Sockets.{Socket, Conn}

  #####
  # External API

  @doc """
  Standard OTP module startup
  """
  def start_link(cb, ip, port) do
    GenServer.start_link(__MODULE__, [cb, ip, port, false])
  end

  def start_link(cb, ip, port, ssl) do
    GenServer.start_link(__MODULE__, [cb, ip, port, ssl], debug: [:statistics])
  end

  @doc """
  Initialises connection with IPv6 address
  """
  def init([cb, {_, _, _, _, _, _, _, _} = ip, port, ssl]) do
    opts = @opts ++ [ip: ip] ++ [:binary, :inet6]
    open_socket(cb, ip, port, ssl, opts)
  end

  def init([cb, {_, _, _, _} = ip, port, ssl]) do
    opts = @opts ++ [ip: ip] ++ [:binary]
    open_socket(cb, ip, port, ssl, opts)
  end

  def handle_call(other, _from, state) do
    Logger.error("UDP listener: strange call: #{inspect(other)}")
    {:noreply, state}
  end

  @doc """
  Asynchronous socket response handler
  """
  def handle_cast({msg, ip, port}, state) do
    Socket.send(state.socket, msg, ip, port)
    {:noreply, state}
  end

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  def handle_cast(other, state) do
    Logger.error("UDP listener: strange cast: #{inspect(other)}")
    {:noreply, state}
  end

  def handle_info(:timeout, state) do
    Socket.setopts(state.socket)
    :erlang.process_flag(:priority, :high)
    {:noreply, state}
  end

  @doc """
  Message handler for incoming UDP packets
  """
  def handle_info({:udp, _fd, fip, fport, msg}, state) do
    Logger.debug("UDP called #{inspect(byte_size(msg))} bytes")
    {:ok, {_, tport}} = Socket.sockname(state.socket)

    {packet, _} = state.callback.process_buffer(msg)

    conn = %Conn{
      message: packet,
      listener: self(),
      client_socket: state.socket,
      client_ip: fip,
      client_port: fport,
      server_ip: Socket.server_ip(),
      server_port: tport
    }

    spawn(state.callback, :process_buffer, [packet])
    state.callback.dispatch(conn)
    Socket.send_to_client_hooks(conn)
    Socket.setopts(state.socket)
    :erlang.process_flag(:priority, :high)
    {:noreply, state}
  end

  def handle_info(info, state) do
    Logger.error("UDP listener: strange info: #{inspect(info)}")
    {:noreply, state}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(reason, state) do
    Socket.close(state.socket, reason)
    :ok
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
