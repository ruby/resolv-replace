# frozen_string_literal: true

require 'test/unit'
require 'resolv-replace'
require 'tempfile'

class TestResolvReplace < Test::Unit::TestCase
  TIMEOUT_ERROR = RUBY_VERSION >= "4" ? IO::TimeoutError : Errno::ETIMEDOUT

  # Records the arguments TCPSocket#initialize hands to the original C
  # implementation instead of connecting.
  class RecordingSocket < TCPSocket
    attr_reader :args

    def original_resolv_initialize(*args)
      @args = args
    end
  end

  class SlowResolver
    def initialize(delay)
      @delay = delay
    end

    def each_address(name)
      sleep @delay
      yield "127.0.0.1"
    end
  end

  def setup
    @resolvers = Resolv::DefaultResolver.instance_variable_get(:@resolvers)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
  end

  def teardown
    Resolv::DefaultResolver.replace_resolvers(@resolvers)
    @server.close
    @nameserver.close if @nameserver
    @hosts.close! if @hosts
  end

  def test_open_timeout
    omit_unless_open_timeout
    use_unresponsive_nameserver
    assert_timeout_after(1) { TCPSocket.new("resolv-replace.test", 80, open_timeout: 1) }
  end

  def test_open_timeout_zero
    omit_unless_open_timeout
    use_unresponsive_nameserver
    assert_timeout_after(0) { TCPSocket.new("resolv-replace.test", 80, open_timeout: 0) }
  end

  def test_open_timeout_counts_lookup_time
    omit_unless_open_timeout
    Resolv::DefaultResolver.replace_resolvers([SlowResolver.new(0.5)])
    args = RecordingSocket.new("resolv-replace.test", 80, open_timeout: 2, fast_fallback: false).args
    assert_equal(["127.0.0.1", 80], args[0, 2])
    assert_equal([:open_timeout, :fast_fallback], args[2].keys)
    assert_equal(false, args[2][:fast_fallback])
    assert_operator(args[2][:open_timeout], :>, 0)
    assert_operator(args[2][:open_timeout], :<=, 1.5)
  end

  def test_resolv_timeout
    use_unresponsive_nameserver
    assert_timeout_after(1) { TCPSocket.new("resolv-replace.test", 80, resolv_timeout: 1) }
  end

  def test_resolv_timeout_covers_local_host
    use_unresponsive_nameserver
    assert_timeout_after(1) do
      TCPSocket.new("127.0.0.1", @port, "resolv-replace.test", nil, resolv_timeout: 1)
    end
  end

  def test_resolv_timeout_passed_through
    use_hosts
    args = RecordingSocket.new("resolv-replace.test", 80, resolv_timeout: 5, connect_timeout: 1).args
    assert_equal(["127.0.0.1", 80, {resolv_timeout: 5, connect_timeout: 1}], args)
  end

  def test_connect
    use_hosts
    sock = TCPSocket.new("resolv-replace.test", @port)
    assert_equal("127.0.0.1", sock.remote_address.ip_address)
    assert_equal(@port, sock.remote_address.ip_port)
  ensure
    sock.close if sock
  end

  def test_keywords_passed_through
    use_hosts
    args = RecordingSocket.new("resolv-replace.test", 80, connect_timeout: 1, fast_fallback: false).args
    assert_equal(["127.0.0.1", 80, {connect_timeout: 1, fast_fallback: false}], args)
  end

  def test_no_keywords
    use_hosts
    args = RecordingSocket.new("resolv-replace.test", 80, "resolv-replace.test", 0).args
    assert_equal(["127.0.0.1", 80, "127.0.0.1", 0], args)
  end

  def test_outer_timeout_not_converted
    use_unresponsive_nameserver
    outer_error = Class.new(Timeout::Error)
    assert_raise(outer_error) do
      Timeout.timeout(0.5, outer_error) { TCPSocket.new("resolv-replace.test", 80, resolv_timeout: 5) }
    end
  end

  private

  def omit_unless_open_timeout
    TCPSocket.new("127.0.0.1", @port, open_timeout: 1).close
  rescue ArgumentError, TypeError # Ruby < 3.0 takes the Hash as local_host
    omit "TCPSocket.new doesn't accept open_timeout: on this Ruby"
  end

  # Swaps in a nameserver that receives queries and never answers.
  def use_unresponsive_nameserver
    @nameserver = UDPSocket.new
    @nameserver.bind("127.0.0.1", 0)
    dns = Resolv::DNS.new(nameserver_port: [["127.0.0.1", @nameserver.addr[1]]])
    Resolv::DefaultResolver.replace_resolvers([dns])
  end

  def use_hosts
    @hosts = Tempfile.new("hosts")
    @hosts.puts("127.0.0.1 resolv-replace.test")
    @hosts.close
    Resolv::DefaultResolver.replace_resolvers([Resolv::Hosts.new(@hosts.path)])
  end

  def assert_timeout_after(sec)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raise(TIMEOUT_ERROR) { yield }
    assert_in_delta(sec, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at, 0.5)
  end
end
