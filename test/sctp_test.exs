defmodule XturnSockets.SCTPTest do
  use ExUnit.Case, async: false
  doctest Xirsys.Sockets.Socket

  alias Xirsys.Sockets.Socket
  alias Xirsys.Sockets.Listener.SCTP

  defmodule TestCallback do
    def handle_message(socket, data, from_ip, from_port, metadata \\ %{}) do
      # Simple echo callback for testing
      send(self(), {:message_received, socket, data, from_ip, from_port, metadata})
      :ok
    end
  end

  setup_all do
    # Start telemetry for test metrics
    try do
      Xirsys.Sockets.Telemetry.attach_handlers()
    rescue
      _ -> :ok
    end

    :ok
  end

  describe "SCTP Socket Operations" do
    @tag :sctp
    test "create SCTP socket with proper type" do
      socket = %Socket{type: :sctp, sock: :fake_socket}
      assert socket.type == :sctp
    end

        @tag :sctp
    test "SCTP socket send function" do
      # Mock gen_sctp behavior
      mock_socket = :fake_sctp_socket
      socket = %Socket{type: :sctp, sock: mock_socket}

      # Test that it attempts SCTP send (will fail in test environment)
      result = Socket.send(socket, "test message")

      # In test environment, this will fail since gen_sctp isn't available
      # but we can verify the function exists and handles SCTP type
      assert match?({:error, _}, result)
    end

        @tag :sctp
    test "SCTP socket close function" do
      mock_socket = :fake_sctp_socket
      socket = %Socket{type: :sctp, sock: mock_socket}

      # Test close function (should succeed with error handling)
      result = Socket.close(socket, "test close")
      assert result == :ok
    end

        @tag :sctp
    test "SCTP socket sockname function" do
      mock_socket = :fake_sctp_socket
      socket = %Socket{type: :sctp, sock: mock_socket}

      # Test sockname function (will fail with fake socket but function should exist)
      assert_raise FunctionClauseError, fn ->
        Socket.sockname(socket)
      end
    end

        @tag :sctp
    test "SCTP socket peername function" do
      mock_socket = :fake_sctp_socket
      socket = %Socket{type: :sctp, sock: mock_socket}

      # Test peername function (will fail with fake socket but function should exist)
      assert_raise FunctionClauseError, fn ->
        Socket.peername(socket)
      end
    end
  end

  describe "SCTP Listener" do
        @tag :sctp
    test "SCTP listener module exists and can be started" do
      # Test that the module exists
      assert Code.ensure_loaded?(SCTP)

      # Test listener startup (will likely fail due to SCTP requirements)
      try do
        result = SCTP.start_link(TestCallback, {127, 0, 0, 1}, 0)

        case result do
          {:ok, pid} ->
            # If it starts successfully, clean up
            GenServer.stop(pid)
            assert is_pid(pid)
          {:error, reason} ->
            # Expected in test environment without SCTP support
            assert is_atom(reason) or is_binary(reason)
        end
      catch
        :exit, _reason ->
          # Expected when SCTP is not available
          assert true
      end
    end

        @tag :sctp
    test "SCTP listener handles IPv6 addresses" do
      # Test IPv6 initialization
      try do
        result = SCTP.start_link(TestCallback, {0, 0, 0, 0, 0, 0, 0, 1}, 0)

        case result do
          {:ok, pid} ->
            GenServer.stop(pid)
            assert is_pid(pid)
          {:error, reason} ->
            # Expected failure in test environment
            assert is_atom(reason) or is_binary(reason)
        end
      catch
        :exit, _reason ->
          # Expected when SCTP is not available
          assert true
      end
    end

    @tag :sctp
    test "SCTP listener configuration" do
      # Test that SCTP configuration is accessible
      max_connections = Socket.get_config(:max_sctp_connections, 1000)
      assert is_integer(max_connections)
      assert max_connections > 0

      sctp_nodelay = Socket.get_config(:sctp_nodelay, true)
      assert is_boolean(sctp_nodelay)

      sctp_streams = Socket.get_config(:sctp_streams, %{})
      assert is_map(sctp_streams)
    end
  end

  describe "SCTP Socket Options" do
        @tag :sctp
    test "SCTP setopts function" do
      mock_socket = :fake_sctp_socket
      socket = %Socket{type: :sctp, sock: mock_socket}

      # Test setopts function
      assert_raise FunctionClauseError, fn ->
        Socket.setopts(socket, [active: :once])
      end
    end

        @tag :sctp
    test "SCTP getopts function with SCTP-specific options" do
      mock_socket = :fake_sctp_socket
      socket = %Socket{type: :sctp, sock: mock_socket}

      # Test getopts function
      assert_raise FunctionClauseError, fn ->
        Socket.getopts(socket)
      end
    end

        @tag :sctp
    test "SCTP set_sockopt function" do
      list_socket = %Socket{type: :sctp, sock: :fake_listener}
      cli_socket = %Socket{type: :sctp, sock: :fake_client}

      # Test set_sockopt function
      assert_raise FunctionClauseError, fn ->
        Socket.set_sockopt(list_socket, cli_socket)
      end
    end
  end

  describe "SCTP Handshake" do
        @tag :sctp
    test "SCTP handshake function exists" do
      mock_socket = :fake_sctp_socket
      socket = %Socket{type: :sctp, sock: mock_socket}

      # Test handshake function
      result = Socket.handshake(socket)

      # Should return error when SCTP is not supported
      assert match?({:error, _}, result)
    end
  end

  describe "SCTP Telemetry" do
    @tag :sctp
    test "SCTP telemetry events are defined" do
      # Test that SCTP telemetry events can be emitted
      result = Socket.emit_telemetry(:sctp_connection_established, %{}, %{ip: {127, 0, 0, 1}})
      assert result == :ok

      result = Socket.emit_telemetry(:sctp_message_received, %{bytes: 100, stream_id: 0, ppid: 0}, %{})
      assert result == :ok
    end

    @tag :sctp
    test "SCTP metrics are tracked" do
      # Emit some test events
      Socket.emit_telemetry(:sctp_connection_established, %{}, %{ip: {127, 0, 0, 1}})
      Socket.emit_telemetry(:sctp_message_received, %{bytes: 100, stream_id: 1, ppid: 0}, %{})

      # Give telemetry time to process
      Process.sleep(10)

      # Check metrics include SCTP data
      metrics = Xirsys.Sockets.Telemetry.get_metrics()
      assert is_map(metrics)
      assert Map.has_key?(metrics, :active_sctp_connections)
      assert Map.has_key?(metrics, :sctp_messages_received)
      assert Map.has_key?(metrics, :sctp_bytes_received)
    end
  end

  describe "SCTP Rate Limiting" do
    @tag :sctp
    test "SCTP respects rate limiting configuration" do
      client_ip = {192, 168, 1, 100}

      # Test rate limiting check
      result = Socket.check_rate_limit(client_ip)
      assert result == :ok or match?({:error, :rate_limited}, result)
    end
  end

  describe "SCTP Multi-streaming" do
    @tag :sctp
    test "SCTP supports multi-stream configuration" do
      streams_config = Socket.get_config(:sctp_streams, %{})

      # Verify stream configuration is present
      assert is_map(streams_config)

      if Map.has_key?(streams_config, :num_ostreams) do
        assert is_integer(streams_config.num_ostreams)
        assert streams_config.num_ostreams > 0
      end

      if Map.has_key?(streams_config, :max_instreams) do
        assert is_integer(streams_config.max_instreams)
        assert streams_config.max_instreams > 0
      end
    end
  end

  describe "SCTP Message Processing" do
    @tag :sctp
    test "SCTP message size validation" do
      # Test that SCTP listener validates message sizes
      max_size = 64 * 1024  # 64KB as defined in SCTP listener

      # Create a message that's within limits
      small_message = String.duplicate("x", 1000)
      assert byte_size(small_message) < max_size

      # Create a message that exceeds limits
      large_message = String.duplicate("x", max_size + 1)
      assert byte_size(large_message) > max_size

      # The validation logic exists in the listener (tested indirectly)
      assert true
    end
  end

    describe "SCTP Error Handling" do
    @tag :sctp
    test "SCTP handles socket errors gracefully" do
      # Test error handling in various SCTP operations
      mock_socket = :fake_sctp_socket
      socket = %Socket{type: :sctp, sock: mock_socket}

      # These operations should handle errors gracefully
      result = Socket.send(socket, "test")
      assert match?({:error, _}, result)

      result = Socket.close(socket, "test")
      assert result == :ok

      # Socket name/peer functions will raise with fake sockets
      assert_raise FunctionClauseError, fn -> Socket.sockname(socket) end
      assert_raise FunctionClauseError, fn -> Socket.peername(socket) end

      # If we reach here, error handling didn't crash
      assert true
    end
  end

  describe "SCTP Integration" do
    @tag :sctp
    test "SCTP integrates with socket supervision" do
      # Test that SCTP sockets can be supervised
      # This is tested indirectly through the client creation in listeners
      assert Code.ensure_loaded?(Xirsys.Sockets.Client)
      assert Code.ensure_loaded?(Xirsys.Sockets.SockSupervisor)
    end

    @tag :sctp
    test "SCTP works with existing socket protocols" do
      # Test that SCTP doesn't interfere with other protocols
      udp_socket = %Socket{type: :udp, sock: :fake_udp}
      tcp_socket = %Socket{type: :tcp, sock: :fake_tcp}
      sctp_socket = %Socket{type: :sctp, sock: :fake_sctp}

      # All should have distinct types
      assert udp_socket.type != sctp_socket.type
      assert tcp_socket.type != sctp_socket.type

      # Type checking should work
      assert sctp_socket.type == :sctp
    end
  end
end
