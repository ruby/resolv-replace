# frozen_string_literal: true

require 'socket'
require 'resolv'
require 'timeout'

class << IPSocket
  # :stopdoc:
  alias original_resolv_getaddress getaddress
  # :startdoc:
  def getaddress(host)
    begin
      return Resolv.getaddress(host).to_s
    rescue Resolv::ResolvError
      raise SocketError, "Hostname not known: #{host}"
    end
  end
end

class TCPSocket < IPSocket
  # :stopdoc:
  alias original_resolv_initialize initialize

  # What TCPSocket.new raises when name resolution times out: IO::TimeoutError
  # since Ruby 4.0, Errno::ETIMEDOUT before (IO::TimeoutError needs 3.2+).
  RESOLV_TIMEOUT_ERROR = RUBY_VERSION >= "4" ? IO::TimeoutError : Errno::ETIMEDOUT

  # Interrupts the lookup. Not a StandardError, so Resolv's own rescue
  # clauses can't swallow it, and distinct from any Timeout::Error raised
  # by a caller's Timeout.timeout around TCPSocket.new.
  class LookupTimeout < Exception; end
  private_constant :RESOLV_TIMEOUT_ERROR, :LookupTimeout
  # :startdoc:

  def initialize(host, serv, *rest, **kwargs)
    # Honor TCPSocket.new's own timeout keywords for the Resolv lookup:
    # resolv_timeout (Ruby 3.0+) bounds name resolution, and open_timeout
    # (Ruby 4.0+) is a deadline covering both resolution and connect.
    open_timeout = kwargs[:open_timeout]
    timeout = open_timeout || kwargs[:resolv_timeout]
    if open_timeout
      raise RESOLV_TIMEOUT_ERROR, "user specified timeout for #{host} port #{serv}" if open_timeout <= 0
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    begin
      addr = Timeout.timeout(timeout, LookupTimeout) do
        rest[0] = IPSocket.getaddress(rest[0]) if rest[0]
        IPSocket.getaddress(host)
      end
    rescue LookupTimeout
      raise RESOLV_TIMEOUT_ERROR, "user specified timeout for #{host} port #{serv}"
    end

    if open_timeout
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      kwargs = kwargs.merge(open_timeout: [open_timeout - elapsed, 0].max)
    end

    if kwargs.empty?
      # Ruby < 2.7 passes an empty **kwargs as a positional Hash.
      original_resolv_initialize(addr, serv, *rest)
    else
      original_resolv_initialize(addr, serv, *rest, **kwargs)
    end
  end
end

class UDPSocket < IPSocket
  # :stopdoc:
  alias original_resolv_bind bind
  # :startdoc:
  def bind(host, port)
    host = IPSocket.getaddress(host) if host != ""
    original_resolv_bind(host, port)
  end

  # :stopdoc:
  alias original_resolv_connect connect
  # :startdoc:
  def connect(host, port)
    original_resolv_connect(IPSocket.getaddress(host), port)
  end

  # :stopdoc:
  alias original_resolv_send send
  # :startdoc:
  def send(mesg, flags, *rest)
    if rest.length == 2
      host, port = rest
      begin
        addrs = Resolv.getaddresses(host)
      rescue Resolv::ResolvError
        raise SocketError, "Hostname not known: #{host}"
      end
      addrs[0...-1].each {|addr|
        begin
          return original_resolv_send(mesg, flags, addr, port)
        rescue SystemCallError
        end
      }
      original_resolv_send(mesg, flags, addrs[-1], port)
    else
      original_resolv_send(mesg, flags, *rest)
    end
  end
end

class SOCKSSocket < TCPSocket
  # :stopdoc:
  alias original_resolv_initialize initialize
  # :startdoc:
  def initialize(host, serv)
    original_resolv_initialize(IPSocket.getaddress(host), port)
  end
end if defined? SOCKSSocket
