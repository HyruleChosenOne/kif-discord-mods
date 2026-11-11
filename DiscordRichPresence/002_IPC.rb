#===============================================================================
# Discord Rich Presence - 002_IPC.rb
# Handles Discord IPC named pipe communication on Windows
#===============================================================================
module DiscordRichPresence
  class PipeClient
    attr_reader :connected, :username

    def initialize
      @file = nil
      @connected = false
      @username = nil
      @pipe_warned = false
    end

    def connect(client_id)
      return true if @connected
      close

      10.times do |i|
        pipe_name = "\\\\.\\pipe\\discord-ipc-#{i}"
        if try_connect_file(pipe_name)
          if perform_handshake(client_id)
            @connected = true
            @pipe_warned = false
            return true
          else
            close
            return false
          end
        end
      end

      DiscordRichPresence.log("Discord named pipe not found. Make sure Discord desktop is open.") unless @pipe_warned
      @pipe_warned = true
      false
    rescue StandardError => e
      DiscordRichPresence.log("Connect exception: #{e.message}")
      close
      false
    end

    def try_connect_file(pipe_name)
      @file = File.open(pipe_name, "r+b") rescue nil
      if @file
        @file.sync = true rescue nil
        return true
      end
      false
    end

    def perform_handshake(client_id)
      payload = { "v" => 1, "client_id" => client_id.to_s }
      return false unless send_packet(0, payload)

      header = read_bytes(8)
      return false unless header && header.bytesize == 8

      opcode, len = header.unpack("V2")
      return false if len <= 0 || len > 65536

      resp_data = read_bytes(len)
      return false if resp_data.nil?

      parsed = DiscordRichPresence.parse_json(resp_data)
      if opcode == 1
        user_obj = (parsed.is_a?(Hash) && parsed["data"].is_a?(Hash)) ? parsed["data"]["user"] : nil
        @username = (user_obj.is_a?(Hash) ? (user_obj["global_name"] || user_obj["username"]) : nil)
        DiscordRichPresence.log("Connected to Discord as '#{@username || "user"}' (App ID: #{client_id})")
        return true
      elsif opcode == 2
        err_msg = (parsed && parsed["message"]) || "Unknown error"
        err_code = (parsed && parsed["code"]) || 0
        DiscordRichPresence.log("Discord rejected connection: #{err_msg} (Code #{err_code}). Please check 'client_id' in config.json!")
        return false
      else
        DiscordRichPresence.log("Unexpected Discord IPC handshake opcode: #{opcode}")
        return false
      end
    rescue StandardError => e
      DiscordRichPresence.log("Handshake exception: #{e.message}")
      false
    end

    def send_activity(activity_hash)
      return false unless @connected

      frame = {
        "cmd" => "SET_ACTIVITY",
        "args" => {
          "pid" => Process.pid,
          "activity" => activity_hash
        },
        "nonce" => "#{Time.now.to_i}_#{rand(10000)}"
      }

      success = send_packet(1, frame)
      if success
        header = read_bytes(8)
        if header && header.bytesize == 8
          op, len = header.unpack("V2")
          read_bytes(len) if len && len > 0 && len <= 65536
          if op == 1
            details = activity_hash["details"] || "In Game"
            state = activity_hash["state"] || ""
            DiscordRichPresence.log("Status updated -> #{details}#{" | " + state unless state.empty?}")
          end
        end
      else
        DiscordRichPresence.log("Failed to send activity packet; pipe disconnected.")
        close
      end

      success
    rescue StandardError => e
      DiscordRichPresence.log("Send activity failed: #{e.message}")
      close
      false
    end

    def clear_activity
      return false unless @connected
      frame = {
        "cmd" => "SET_ACTIVITY",
        "args" => {
          "pid" => Process.pid,
          "activity" => nil
        },
        "nonce" => "#{Time.now.to_i}_clear"
      }
      send_packet(1, frame) rescue nil
      close
      DiscordRichPresence.log("Discord Rich Presence cleared.")
      true
    rescue StandardError
      close
      false
    end

    def send_packet(opcode, payload_hash)
      json = DiscordRichPresence.to_json(payload_hash)
      return false unless json

      json_bin = json.to_s.b
      header = [opcode, json_bin.bytesize].pack("V2")
      packet = header + json_bin
      write_bytes(packet)
    rescue StandardError => e
      DiscordRichPresence.log("send_packet exception: #{e.class}: #{e.message}")
      close
      false
    end

    def write_bytes(data)
      data_bin = data.to_s.b
      if @file && !@file.closed?
        @file.write(data_bin)
        @file.flush
        return true
      end
      false
    rescue StandardError => e
      DiscordRichPresence.log("write_bytes exception: #{e.class}: #{e.message}")
      close
      false
    end

    def read_bytes(len)
      buf = "".b
      while buf.bytesize < len
        needed = len - buf.bytesize
        chunk = read_chunk(needed)
        break if chunk.nil? || chunk.empty?
        buf << chunk.b
      end
      buf.bytesize == len ? buf : nil
    rescue StandardError => e
      DiscordRichPresence.log("read_bytes exception: #{e.class}: #{e.message}")
      close
      nil
    end

    def read_chunk(len)
      if @file && !@file.closed?
        ready = (IO.select([@file], nil, nil, 2) rescue :not_supported)
        if ready == :not_supported || (ready && ready[0])
          return @file.read(len) rescue nil
        end
      end
      nil
    rescue StandardError
      nil
    end

    def close
      @connected = false
      if @file
        @file.close rescue nil
        @file = nil
      end
    end
  end
end
