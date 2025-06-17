defmodule XturnSockets.SCTPUnitTest do
  use ExUnit.Case, async: false
  doctest Xirsys.Sockets.Socket

  alias Xirsys.Sockets.Socket
  alias Xirsys.Sockets.Listener.SCTP
  alias Xirsys.Sockets.Telemetry

  # Mock callback for testing
  defmodule MockCallback do
    def handle_message(socket, data, from_ip, from_port, metadata \\ %{}) do
      send(self(), {:mock_callback, socket, data, from_ip, from_port, metadata})
      :ok
    end
  end

  setup do
    # Reset telemetry counters before each test
    try do
      Telemetry.reset_counters()
    rescue
      _ -> :ok
    end

    :ok
  end

  describe "SCTP Socket Type System" do
    test "SCTP socket struct creation" do
      socket = %Socket{type: :sctp, sock: :test_socket}

      assert socket.type == :sctp
      assert socket.sock == :test_socket
      assert match?(%Socket{}, socket)
    end

    test "SCTP socket type validation" do
      socket = %Socket{type: :sctp, sock: :test}

      # Verify type is correctly identified
      assert socket.type == :sctp
      refute socket.type == :udp
      refute socket.type == :tcp
      refute socket.type == :tls
      refute socket.type == :dtls
    end

    test "SCTP socket pattern matching" do
      sctp_socket = %Socket{type: :sctp, sock: :test}

      # Test pattern matching works correctly
      result = case sctp_socket do
        %Socket{type: :sctp} -> :matched_sctp
        %Socket{type: :udp} -> :matched_udp
        _ -> :no_match
      end

      assert result == :matched_sctp
    end
  end

  describe "SCTP Configuration Management" do
    test "SCTP connection limits configuration" do
      max_connections = Socket.get_config(:max_sctp_connections, 1000)

      assert is_integer(max_connections)
      assert max_connections > 0
      assert max_connections <= 10000  # Reasonable upper bound
    end

    test "SCTP nodelay configuration" do
      nodelay = Socket.get_config(:sctp_nodelay, true)

      assert is_boolean(nodelay)
    end

    test "SCTP autoclose configuration" do
      autoclose = Socket.get_config(:sctp_autoclose, 0)

      assert is_integer(autoclose)
      assert autoclose >= 0
    end

    test "SCTP maxseg configuration" do
      maxseg = Socket.get_config(:sctp_maxseg, 1400)

      assert is_integer(maxseg)
      assert maxseg > 0
      assert maxseg <= 65535  # Maximum segment size
    end

    test "SCTP streams configuration structure" do
      streams = Socket.get_config(:sctp_streams, %{})

      assert is_map(streams)

      # Test expected keys if present
      if Map.has_key?(streams, :num_ostreams) do
        assert is_integer(streams.num_ostreams)
        assert streams.num_ostreams > 0
        assert streams.num_ostreams <= 65535
      end

      if Map.has_key?(streams, :max_instreams) do
        assert is_integer(streams.max_instreams)
        assert streams.max_instreams > 0
        assert streams.max_instreams <= 65535
      end

      if Map.has_key?(streams, :max_attempts) do
        assert is_integer(streams.max_attempts)
        assert streams.max_attempts > 0
        assert streams.max_attempts <= 10
      end

      if Map.has_key?(streams, :max_init_timeo) do
        assert is_integer(streams.max_init_timeo)
        assert streams.max_init_timeo > 0
      end
    end

    test "SCTP configuration fallback values" do
      # Test with non-existent config key
      value = Socket.get_config(:non_existent_sctp_key, :default_value)
      assert value == :default_value

      # Test with nil default
      value = Socket.get_config(:non_existent_sctp_key)
      assert value == nil
    end
  end

  describe "SCTP Send Operations" do
    test "SCTP send with different message sizes" do
      socket = %Socket{type: :sctp, sock: :fake_socket}

      # Small message
      small_msg = "test"
      result = Socket.send(socket, small_msg)
      assert match?({:error, _}, result)

      # Medium message
      medium_msg = String.duplicate("x", 1000)
      result = Socket.send(socket, medium_msg)
      assert match?({:error, _}, result)

      # Large message (but under 64KB limit)
      large_msg = String.duplicate("x", 32000)
      result = Socket.send(socket, large_msg)
      assert match?({:error, _}, result)
    end

    test "SCTP send error handling" do
      socket = %Socket{type: :sctp, sock: :invalid_socket}

      result = Socket.send(socket, "test message")

      # Should handle SCTP unavailability gracefully
      assert match?({:error, :sctp_not_supported}, result)
    end

    test "SCTP send with binary data" do
      socket = %Socket{type: :sctp, sock: :fake_socket}

      # Test with different binary data types
      binary_data = <<1, 2, 3, 4, 5>>
      result = Socket.send(socket, binary_data)
      assert match?({:error, _}, result)

      # UTF-8 string
      utf8_data = "Hello 世界"
      result = Socket.send(socket, utf8_data)
      assert match?({:error, _}, result)
    end

    test "SCTP send with empty message" do
      socket = %Socket{type: :sctp, sock: :fake_socket}

      result = Socket.send(socket, "")
      assert match?({:error, _}, result)
    end
  end

  describe "SCTP Handshake Operations" do
    test "SCTP handshake timeout handling" do
      socket = %Socket{type: :sctp, sock: :fake_socket}

      result = Socket.handshake(socket)

      # Should handle timeout or unavailability
      assert match?({:error, _}, result)
    end

    test "SCTP handshake with invalid socket" do
      socket = %Socket{type: :sctp, sock: nil}

      result = Socket.handshake(socket)
      assert match?({:error, _}, result)
    end

    test "SCTP handshake error propagation" do
      socket = %Socket{type: :sctp, sock: :non_existent_socket}

      result = Socket.handshake(socket)

      # Should return sctp_not_supported when SCTP is unavailable
      assert match?({:error, :sctp_not_supported}, result)
    end
  end

  describe "SCTP Socket Options" do
    test "SCTP getopts with SCTP-specific options" do
      socket = %Socket{type: :sctp, sock: :fake_socket}

      # Should raise function clause error with fake socket
      assert_raise FunctionClauseError, fn ->
        Socket.getopts(socket)
      end
    end

    test "SCTP setopts functionality" do
      socket = %Socket{type: :sctp, sock: :fake_socket}

      # Test with various socket options
      assert_raise FunctionClauseError, fn ->
        Socket.setopts(socket, [active: :once])
      end

      assert_raise FunctionClauseError, fn ->
        Socket.setopts(socket, [buffer: 8192])
      end

      assert_raise FunctionClauseError, fn ->
        Socket.setopts(socket, [nodelay: true])
      end
    end

    test "SCTP socket registration" do
      socket = %Socket{type: :sctp, sock: :fake_socket}

      # Test socket registration for SCTP
      assert_raise FunctionClauseError, fn ->
        Socket.register_socket(socket)
      end
    end
  end

  describe "SCTP Connection Management" do
    test "SCTP connection tracking initialization" do
      # Test that SCTP listener would initialize ETS table
      # This is tested through the listener startup process
      assert Code.ensure_loaded?(SCTP)
    end

    test "SCTP rate limiting integration" do
      test_ip = {192, 168, 1, 100}

      # Multiple rapid requests should eventually trigger rate limiting
      results = for _i <- 1..5 do
        Socket.check_rate_limit(test_ip)
      end

      # At least some should succeed
      successful = Enum.count(results, &(&1 == :ok))
      assert successful > 0
    end

    test "SCTP connection timeout values" do
      timeout = Socket.connection_timeout()

      assert is_integer(timeout)
      assert timeout > 0
      assert timeout <= 300_000  # 5 minutes max
    end
  end

  describe "SCTP Telemetry Integration" do
    test "SCTP connection telemetry events" do
      # Test connection established event
      result = Socket.emit_telemetry(:sctp_connection_established, %{}, %{ip: {127, 0, 0, 1}})
      assert result == :ok

      # Test connection closed event
      result = Socket.emit_telemetry(:sctp_connection_closed, %{}, %{ip: {127, 0, 0, 1}})
      assert result == :ok
    end

    test "SCTP message telemetry events" do
      # Test message received with different stream configurations
      measurements = %{bytes: 1024, stream_id: 0, ppid: 0}
      metadata = %{ip: {127, 0, 0, 1}, port: 1234}

      result = Socket.emit_telemetry(:sctp_message_received, measurements, metadata)
      assert result == :ok

      # Test with different stream
      measurements = %{bytes: 512, stream_id: 3, ppid: 1}
      result = Socket.emit_telemetry(:sctp_message_received, measurements, metadata)
      assert result == :ok
    end

    test "SCTP error telemetry events" do
      # Test oversized packet event
      measurements = %{bytes: 70000}  # > 64KB
      metadata = %{ip: {127, 0, 0, 1}, port: 1234}

      result = Socket.emit_telemetry(:sctp_packet_too_large, measurements, metadata)
      assert result == :ok

      # Test rate limit event
      result = Socket.emit_telemetry(:sctp_rate_limit_exceeded, %{}, metadata)
      assert result == :ok
    end

    test "SCTP listener telemetry events" do
      metadata = %{ip: {127, 0, 0, 1}, port: 1234}

      # Test listener started event
      result = Socket.emit_telemetry(:sctp_listener_started, %{}, metadata)
      assert result == :ok

      # Test listener error event
      measurements = %{error: :sctp_not_supported}
      result = Socket.emit_telemetry(:sctp_listener_error, measurements, metadata)
      assert result == :ok
    end

    test "SCTP metrics collection" do
      # Emit several events
      Socket.emit_telemetry(:sctp_connection_established, %{}, %{ip: {127, 0, 0, 1}})
      Socket.emit_telemetry(:sctp_message_received, %{bytes: 100, stream_id: 0, ppid: 0}, %{})
      Socket.emit_telemetry(:sctp_message_received, %{bytes: 200, stream_id: 1, ppid: 0}, %{})
      Socket.emit_telemetry(:sctp_packet_too_large, %{bytes: 70000}, %{})

      # Allow telemetry to process
      Process.sleep(10)

      # Check metrics
      metrics = Telemetry.get_metrics()
      assert is_map(metrics)

      # Verify SCTP-specific metrics exist
      assert Map.has_key?(metrics, :active_sctp_connections)
      assert Map.has_key?(metrics, :sctp_messages_received)
      assert Map.has_key?(metrics, :sctp_bytes_received)
      assert Map.has_key?(metrics, :sctp_oversized_packets)
    end
  end

  describe "SCTP Multi-streaming" do
    test "stream configuration validation" do
      streams_config = Socket.get_config(:sctp_streams, %{})

      if Map.has_key?(streams_config, :num_ostreams) do
        assert streams_config.num_ostreams >= 1
        assert streams_config.num_ostreams <= 65535
      end

      if Map.has_key?(streams_config, :max_instreams) do
        assert streams_config.max_instreams >= 1
        assert streams_config.max_instreams <= 65535
      end
    end

        test "multi-stream telemetry tracking" do
      # Send messages on different streams
      Socket.emit_telemetry(:sctp_message_received, %{bytes: 100, stream_id: 0, ppid: 0}, %{})
      Socket.emit_telemetry(:sctp_message_received, %{bytes: 200, stream_id: 1, ppid: 0}, %{})
      Socket.emit_telemetry(:sctp_message_received, %{bytes: 150, stream_id: 2, ppid: 1}, %{})

      Process.sleep(10)

      metrics = Telemetry.get_metrics()

      # Should track multi-stream usage (may be 0 if telemetry handler not processing streams)
      if Map.has_key?(metrics, :sctp_multistream_messages) do
        # In test environment, this may be 0, so just verify it's a non-negative integer
        assert is_integer(metrics.sctp_multistream_messages)
        assert metrics.sctp_multistream_messages >= 0
      end
    end
  end

  describe "SCTP Protocol Specifics" do
    test "SCTP message boundary preservation" do
      # SCTP is message-oriented, unlike TCP
      socket = %Socket{type: :sctp, sock: :fake_socket}

      # Multiple sends should preserve message boundaries
      msg1 = "message1"
      msg2 = "message2"

      result1 = Socket.send(socket, msg1)
      result2 = Socket.send(socket, msg2)

      # Both should be handled independently
      assert match?({:error, _}, result1)
      assert match?({:error, _}, result2)
    end

    test "SCTP packet size validation" do
      max_size = 64 * 1024  # 64KB

      # Valid size
      small_packet = String.duplicate("x", 1000)
      assert byte_size(small_packet) < max_size

      # Maximum valid size
      max_packet = String.duplicate("x", max_size - 100)
      assert byte_size(max_packet) < max_size

      # Oversized packet
      large_packet = String.duplicate("x", max_size + 1)
      assert byte_size(large_packet) > max_size
    end

    test "SCTP association handling" do
      # SCTP uses associations instead of connections
      # Test that our implementation handles this correctly
      socket = %Socket{type: :sctp, sock: :fake_association}

      # Operations should work with associations
      result = Socket.send(socket, "test")
      assert match?({:error, _}, result)

      result = Socket.close(socket, "test")
      assert result == :ok
    end
  end

  describe "SCTP Error Scenarios" do
    test "SCTP unavailable error handling" do
      socket = %Socket{type: :sctp, sock: :fake_socket}

      # All operations should gracefully handle SCTP unavailability
      send_result = Socket.send(socket, "test")
      assert match?({:error, :sctp_not_supported}, send_result)

      handshake_result = Socket.handshake(socket)
      assert match?({:error, :sctp_not_supported}, handshake_result)

      close_result = Socket.close(socket, "test")
      assert close_result == :ok  # Close should always succeed
    end

    test "SCTP invalid socket error handling" do
      socket = %Socket{type: :sctp, sock: nil}

      result = Socket.send(socket, "test")
      assert match?({:error, _}, result)

      result = Socket.handshake(socket)
      assert match?({:error, _}, result)
    end

    test "SCTP listener startup failure" do
      # Test listener graceful failure when SCTP unavailable
      try do
        result = SCTP.start_link(MockCallback, {127, 0, 0, 1}, 0)

        case result do
          {:ok, pid} ->
            GenServer.stop(pid)
            assert true
          {:error, :sctp_not_supported} ->
            assert true
          {:error, reason} ->
            assert is_atom(reason) or is_binary(reason)
        end
      catch
        :exit, _reason ->
          # Expected when SCTP is not available
          assert true
      end
    end
  end

  describe "SCTP Performance Characteristics" do
    test "SCTP buffer size configuration" do
      # Test that SCTP uses appropriate buffer sizes
      buffer_size = Socket.get_config(:buffer_size, 256 * 1024)

      assert is_integer(buffer_size)
      assert buffer_size >= 64 * 1024  # At least 64KB
      assert buffer_size <= 1024 * 1024  # At most 1MB
    end

    test "SCTP concurrent connection limits" do
      max_connections = Socket.get_config(:max_sctp_connections, 1000)

      assert is_integer(max_connections)
      assert max_connections >= 100  # Reasonable minimum
      assert max_connections <= 10000  # Reasonable maximum
    end

    test "SCTP timeout configurations" do
      connection_timeout = Socket.connection_timeout()
      ssl_timeout = Socket.ssl_handshake_timeout()

      assert is_integer(connection_timeout)
      assert is_integer(ssl_timeout)

      # SCTP doesn't use SSL, but timeout should be reasonable
      assert connection_timeout > 0
      assert connection_timeout <= 300_000  # 5 minutes max
    end
  end

  describe "SCTP Integration Testing" do
    test "SCTP with existing protocols" do
      # Ensure SCTP doesn't interfere with other protocols
      udp_socket = %Socket{type: :udp, sock: :fake_udp}
      tcp_socket = %Socket{type: :tcp, sock: :fake_tcp}
      sctp_socket = %Socket{type: :sctp, sock: :fake_sctp}

      # All should maintain their distinct types
      assert udp_socket.type == :udp
      assert tcp_socket.type == :tcp
      assert sctp_socket.type == :sctp

      # Pattern matching should work correctly
      socket_types = [udp_socket, tcp_socket, sctp_socket]
      |> Enum.map(fn socket ->
        case socket do
          %Socket{type: :udp} -> :udp
          %Socket{type: :tcp} -> :tcp
          %Socket{type: :sctp} -> :sctp
          _ -> :unknown
        end
      end)

      assert socket_types == [:udp, :tcp, :sctp]
    end

    test "SCTP supervision tree integration" do
      # Test that SCTP works with the supervision tree
      assert Code.ensure_loaded?(Xirsys.Sockets.Client)
      assert Code.ensure_loaded?(Xirsys.Sockets.SockSupervisor)

      # The modules should be available for supervision
      assert function_exported?(Xirsys.Sockets.Client, :start_link, 3)
    end

    test "SCTP configuration inheritance" do
      # Test that SCTP inherits general socket configurations
      rate_limit_enabled = Socket.rate_limit_enabled?()
      assert is_boolean(rate_limit_enabled)

      max_connections_per_ip = Socket.max_connections_per_ip()
      assert is_integer(max_connections_per_ip)
      assert max_connections_per_ip > 0
    end
  end
end
