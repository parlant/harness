# frozen_string_literal: true

require "socket"
require_relative "serve"

occupied = TCPServer.new("127.0.0.1", 0)
occupied_port = occupied.local_address.ip_port
selected_port = LocalServer.available_port(occupied_port)

abort "Expected port after #{occupied_port}, got #{selected_port}" unless selected_port > occupied_port

occupied.close

begin
  LocalServer.available_port(0)
  abort "Expected port 0 to be rejected"
rescue ArgumentError
  # Expected.
end

puts "Port selection skips occupied port #{occupied_port}, selects #{selected_port}, and rejects invalid ports."
