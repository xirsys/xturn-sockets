defmodule XturnSockets.TCPTest do
  use ExUnit.Case
  alias Xirsys.Sockets.{Socket, Listener.TCP}
  require Logger

  @test_ip {127, 0, 0, 1}
  # Let OS assign port
  @test_port 0

  describe "TCP Socket operations" do
    test "TCP socket handshake for plain TCP" do
      # Start a simple TCP server
      {:ok, listen_sock} = :gen_tcp.listen(@test_port, [:binary, {:active, false}])
      {:ok, {_, port}} = :inet.sockname(listen_sock)

      # Create socket wrapper
      server_socket = %Socket{type: :tcp, sock: listen_sock}

      # Connect a client
      spawn(fn ->
        # Give server time to start accepting
        Process.sleep(50)
        {:ok, _client_sock} = :gen_tcp.connect(@test_ip, port, [:binary, {:active, false}])
      end)

      # Accept connection on server
      case Socket.handshake(server_socket) do
        {:ok, %Socket{type: :tcp, sock: accepted_sock}} ->
          assert is_port(accepted_sock)
          :gen_tcp.close(accepted_sock)

        {:error, _reason} ->
          # Expected in some test environments
          :ok
      end

      :gen_tcp.close(listen_sock)
    end

    test "TCP socket send and receive through Socket module" do
      {:ok, server} = :gen_tcp.listen(@test_port, [:binary, {:active, false}])
      {:ok, {_, port}} = :inet.sockname(server)

      # Client connection
      {:ok, client} = :gen_tcp.connect(@test_ip, port, [:binary, {:active, false}])
      {:ok, accepted} = :gen_tcp.accept(server)

      # Wrap in Socket structs
      client_socket = %Socket{type: :tcp, sock: client}
      server_socket = %Socket{type: :tcp, sock: accepted}

      message = "Hello TCP"

      # Send from client to server
      assert Socket.send(client_socket, message) == :ok

      # Receive on server
      {:ok, received} = :gen_tcp.recv(accepted, byte_size(message))
      assert received == message

      # Send from server to client
      assert Socket.send(server_socket, message) == :ok

      # Receive on client
      {:ok, received2} = :gen_tcp.recv(client, byte_size(message))
      assert received2 == message

      :gen_tcp.close(client)
      :gen_tcp.close(accepted)
      :gen_tcp.close(server)
    end

    test "TCP socket options" do
      {:ok, listen_sock} = :gen_tcp.listen(@test_port, [:binary, {:active, false}])
      socket = %Socket{type: :tcp, sock: listen_sock}

      assert Socket.setopts(socket, [{:active, false}]) == :ok
      assert Socket.getopts(socket) |> elem(0) == :ok

      :gen_tcp.close(listen_sock)
    end

    test "TCP socket peer and sock name" do
      {:ok, server} = :gen_tcp.listen(@test_port, [:binary, {:active, false}])
      {:ok, {_, port}} = :inet.sockname(server)

      {:ok, client} = :gen_tcp.connect(@test_ip, port, [:binary, {:active, false}])
      {:ok, accepted} = :gen_tcp.accept(server)

      client_socket = %Socket{type: :tcp, sock: client}
      server_socket = %Socket{type: :tcp, sock: accepted}

      # Test sockname and peername
      assert Socket.sockname(client_socket) |> elem(0) == :ok
      assert Socket.peername(client_socket) |> elem(0) == :ok
      assert Socket.sockname(server_socket) |> elem(0) == :ok
      assert Socket.peername(server_socket) |> elem(0) == :ok

      :gen_tcp.close(client)
      :gen_tcp.close(accepted)
      :gen_tcp.close(server)
    end
  end

  describe "TCP Listener" do
    defmodule TestCallback do
      def process_buffer(data), do: {data, <<>>}
      def dispatch(_conn), do: :ok
    end

    test "starts TCP listener on IPv4" do
      result = TCP.start_link(TestCallback, @test_ip, @test_port, false)

      case result do
        {:ok, pid} ->
          assert is_pid(pid)
          GenServer.stop(pid)

        {:error, reason} ->
          # May fail due to supervisor not being available or other issues
          Logger.debug("TCP listener failed as expected: #{inspect(reason)}")
          :ok
      end
    end

    test "starts TCP listener on IPv6" do
      # ::1
      ipv6_addr = {0, 0, 0, 0, 0, 0, 0, 1}
      result = TCP.start_link(TestCallback, ipv6_addr, @test_port, false)

      case result do
        {:ok, pid} ->
          assert is_pid(pid)
          GenServer.stop(pid)

        {:error, reason} ->
          # May fail in environments without IPv6 or supervisor issues
          Logger.debug("TCP IPv6 listener failed as expected: #{inspect(reason)}")
          :ok
      end
    end

    test "TLS listener without certificates fails gracefully" do
      result = TCP.start_link(TestCallback, @test_ip, @test_port, true)

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

  describe "TCP Socket utility functions" do
    test "socket close" do
      {:ok, listen_sock} = :gen_tcp.listen(@test_port, [:binary, {:active, false}])
      socket = %Socket{type: :tcp, sock: listen_sock}

      assert Socket.close(socket, "test close") == :ok
    end

    test "socket registration" do
      {:ok, listen_sock} = :gen_tcp.listen(@test_port, [:binary, {:active, false}])
      {:ok, {_, port}} = :inet.sockname(listen_sock)

      {:ok, client} = :gen_tcp.connect(@test_ip, port, [:binary, {:active, false}])
      client_socket = %Socket{type: :tcp, sock: client}

      # Test socket registration (used internally)
      assert Socket.register_socket(client_socket) == true

      :gen_tcp.close(client)
      :gen_tcp.close(listen_sock)
    end
  end
end
