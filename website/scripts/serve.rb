# frozen_string_literal: true

require "socket"

module LocalServer
  HOST = "127.0.0.1"
  DEFAULT_PORT = 8080
  MAX_PORT = 65_535

  def self.available_port(start_port = DEFAULT_PORT, host: HOST)
    start_port = Integer(start_port)
    raise ArgumentError unless (1..MAX_PORT).cover?(start_port)

    (start_port..MAX_PORT).find do |port|
      server = TCPServer.new(host, port)
      server.close
      true
    rescue Errno::EADDRINUSE, Errno::EACCES
      false
    end || raise("No available port found from #{start_port} to #{MAX_PORT}")
  end

  def self.run
    port = available_port(ENV.fetch("PORT", DEFAULT_PORT))
    puts "Starting Jekyll at http://#{HOST}:#{port}"
    $stdout.flush
    exec "bundle", "exec", "jekyll", "serve", "--livereload", "--port", port.to_s, *ARGV
  rescue ArgumentError
    abort "PORT must be an integer between 1 and #{MAX_PORT}"
  end
end

LocalServer.run if $PROGRAM_NAME == __FILE__
