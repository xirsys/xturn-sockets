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

defmodule Xirsys.Sockets.Conn do
  @moduledoc """
  Socket connection object for TURN
  """
  require Logger

  alias Xirsys.Sockets.{Conn, Response, Socket}

  @type t :: {
          listener :: :gen_tcp.socket() | :gen_udp.socket() | :ssl.sslsocket(),
          message :: binary(),
          decoded_message :: any(),
          client_socket :: :gen_tcp.socket() | :gen_udp.socket() | :ssl.sslsocket(),
          client_ip :: tuple(),
          client_port :: integer(),
          server_ip :: tuple(),
          server_port :: integer(),
          is_control :: boolean(),
          force_auth :: boolean(),
          response :: Response.t(),
          halt :: boolean()
        }

  defstruct listener: nil,
            message: nil,
            decoded_message: nil,
            client_socket: nil,
            client_ip: nil,
            client_port: nil,
            server_ip: nil,
            server_port: nil,
            is_control: false,
            force_auth: false,
            response: nil,
            halt: nil

  @doc """
  Flags a connection object as halted, so it
  shouldn't be processed any further
  """
  @spec halt(Conn.t()) :: Conn.t()
  def halt(%Conn{} = conn),
    do: %Conn{conn | halt: true}

  @spec response(%Conn{}, atom() | integer(), binary() | any()) :: %Conn{}
  def response(conn, class, attrs \\ nil)

  def response(%Conn{} = conn, class, attrs) when is_atom(class),
    do: %Conn{conn | response: %Response{class: class, attrs: attrs}}

  def response(%Conn{} = conn, err, msg) when is_integer(err),
    do: %Conn{conn | response: %Response{err_no: err, message: msg}} |> Conn.halt()

  @doc """
  If a response message has been set, then we must notify the client accordingly
  """
  @spec send(%Conn{}) :: %Conn{}
  def send(%Conn{message: msg} = conn) when not is_nil(msg) do
    case conn.client_socket do
      nil ->
        conn

      client_socket ->
        Socket.send(client_socket, msg, conn.client_ip, conn.client_port)
        conn
    end
  end
end
