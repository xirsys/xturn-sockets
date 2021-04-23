defmodule XturnSocketsTest do
  use ExUnit.Case
  alias Xirsys.Sockets.Socket
  doctest Socket

  test "opens a port" do
    {:ok, %Xirsys.Sockets.Socket{sock: sock, type: :udp}} =
      Socket.open_port({0, 0, 0, 0}, :random, [])

    assert is_port(sock)
  end
end
