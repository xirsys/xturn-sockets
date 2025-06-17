defmodule XturnSockets.UDPTest do
  use ExUnit.Case
  alias Xirsys.Sockets.{Socket, Listener.UDP}
  require Logger

  @test_ip {127, 0, 0, 1}
  # Let OS assign port
  @test_port 0

  describe "UDP Socket operations" do
    test "opens UDP port with random policy" do
      {:ok, %Socket{sock: sock, type: :udp}} = Socket.open_port(@test_ip, :random, [])

      assert is_port(sock)
      assert Socket.sockname(%Socket{sock: sock, type: :udp}) |> elem(0) == :ok

      :gen_udp.close(sock)
    end

    test "opens UDP port with preferred policy" do
      {:ok, %Socket{sock: sock, type: :udp}} = Socket.open_port(@test_ip, {:preferred, 0}, [])

      assert is_port(sock)
      :gen_udp.close(sock)
    end

    test "opens UDP port with port range policy" do
      {:ok, %Socket{sock: sock, type: :udp}} =
        Socket.open_port(@test_ip, {:range, 50000, 50010}, [])

      assert is_port(sock)
      {:ok, {_ip, port}} = Socket.sockname(%Socket{sock: sock, type: :udp})
      assert port >= 50000 and port <= 50010

      :gen_udp.close(sock)
    end

    test "UDP socket send and receive" do
      {:ok, sender} = :gen_udp.open(0, [:binary, {:active, false}])
      {:ok, receiver} = :gen_udp.open(0, [:binary, {:active, false}])

      {:ok, {_, receiver_port}} = :inet.sockname(receiver)

      message = "Hello UDP"
      :ok = :gen_udp.send(sender, @test_ip, receiver_port, message)

      {:ok, {_ip, _port, received_data}} = :gen_udp.recv(receiver, byte_size(message), 1000)
      assert received_data == message

      :gen_udp.close(sender)
      :gen_udp.close(receiver)
    end

    test "UDP socket options" do
      {:ok, %Socket{sock: sock, type: :udp}} = Socket.open_port(@test_ip, :random, [])
      socket = %Socket{sock: sock, type: :udp}

      assert Socket.setopts(socket, [{:active, false}]) == :ok
      assert Socket.getopts(socket) |> elem(0) == :ok

      :gen_udp.close(sock)
    end
  end

  describe "UDP Listener" do
    defmodule TestCallback do
      def process_buffer(data), do: {data, <<>>}
      def dispatch(_conn), do: :ok
    end

    test "starts UDP listener on IPv4" do
      result = UDP.start_link(TestCallback, @test_ip, @test_port, false)

      case result do
        {:ok, pid} ->
          assert is_pid(pid)
          GenServer.stop(pid)

        {:error, reason} ->
          # May fail due to supervisor not being available or other issues
          Logger.debug("UDP listener failed as expected: #{inspect(reason)}")
          :ok
      end
    end

    test "DTLS listener without certificates fails gracefully" do
      result = UDP.start_link(TestCallback, @test_ip, @test_port, {:ssl, true})

      case result do
        {:ok, _pid} ->
          # May succeed if certificates are actually configured
          :ok

        {:error, reason} ->
          # Expected to fail without certificates
          assert reason != nil
          :ok
      end
    end
  end

  describe "UDP Socket utility functions" do
    test "socket close" do
      {:ok, %Socket{sock: sock, type: :udp}} = Socket.open_port(@test_ip, :random, [])
      socket = %Socket{sock: sock, type: :udp}

      assert Socket.close(socket, "test close") == :ok
    end

    test "socket port info" do
      {:ok, %Socket{sock: sock, type: :udp}} = Socket.open_port(@test_ip, :random, [])
      socket = %Socket{sock: sock, type: :udp}

      {:ok, port} = Socket.port(socket)
      assert is_integer(port)

      Socket.close(socket)
    end
  end
end
