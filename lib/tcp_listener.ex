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
  TCP protocol socket listener. Dispatches to TCP
  clients once listener socket has been set up.
  """
  use GenServer
  require Logger
  alias Xirsys.Sockets.Socket

  @buf_size 1024 * 1024 * 16
  @opts [
    reuseaddr: true,
    keepalive: true,
    backlog: 30,
    active: false,
    buffer: @buf_size,
    recbuf: @buf_size,
    sndbuf: @buf_size
  ]

  #####
  # External API

  @doc """
  Standard OTP module startup
  """
  def start_link(cb, ip, port) do
    GenServer.start_link(__MODULE__, [cb, ip, port, false])
  end

  def start_link(cb, ip, port, ssl) do
    GenServer.start_link(__MODULE__, [cb, ip, port, ssl])
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

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  def terminate(_reason, %{:listener => listener} = _state) do
    Socket.close(listener)
    :ok
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  defp open_socket(cb, ip, port, ssl, opts) do
    with true <- valid_ip?(ip) do
      socket_result =
        case ssl do
          true ->
            case :application.get_env(:certs) do
              {:ok, certs} ->
                nopts = opts ++ certs

                case :ssl.listen(port, nopts) do
                  {:ok, sock} -> {:ok, %Socket{type: :tls, sock: sock}}
                  error -> error
                end

              :undefined ->
                {:error, :no_certificates_configured}
            end

          _ ->
            case :gen_tcp.listen(port, opts) do
              {:ok, sock} -> {:ok, %Socket{type: :tcp, sock: sock}}
              error -> error
            end
        end

      case socket_result do
        {:ok, socket} ->
          try do
            Xirsys.Sockets.Client.create(socket, cb, ssl)
          catch
            :exit, _reason ->
              # Supervisor not available, continue without client process
              Logger.debug("Supervisor not available, continuing without client process")
          end

          Logger.info("TCP listener started at [#{:inet_parse.ntoa(ip)}:#{port}]")
          {:ok, %{listener: socket, ssl: ssl}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :invalid_ip_address}
    end
  end

  defp valid_ip?(ip),
    do: Enum.reduce(Tuple.to_list(ip), true, &(is_integer(&1) and &1 >= 0 and &1 <= 255 and &2))
end
