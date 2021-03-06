module GELF
  class Logger
    alias HashType = Hash(String, (String | Int::Signed | Int::Unsigned | Float64 | Bool))
    alias MessageType = (Hash(String, (String | Int::Signed | Int::Unsigned | Float64 | Bool)) | String)

    property! facility : String
    property! host : String
    property level : ::Logger::Severity

    def initialize(host, port, @max_size = :wan)
      @sender = UdpSender.new(host, port)
      @level = ::Logger::INFO
    end

    def max_chunk_size
      case @max_size
      when :lan
        8154
      else
        1420
      end
    end

    def configure
      yield(self)
      self
    end

    {% for level in ["DEBUG", "INFO", "WARN", "ERROR", "FATAL", "UNKNOWN"] %}
      def {{level.id.downcase}}(message : HashType, progname : String? = nil)
        add(::Logger::{{level.id}}, message, progname)
      end

      def {{level.id.downcase}}(message : String, progname : String? = nil)
        add(::Logger::{{level.id}}, message, progname)
      end

      def {{level.id.downcase}}(progname : String? = nil)
          add(::Logger::{{level.id}}, yield, progname)
      end

      def {{level.id.downcase}}?
        ::Logger::{{level.id}} >= level
      end
    {% end %}

    private def add(level, message : Hash(String, (String | Int::Signed | Int::Unsigned | Float64 | Bool)), progname : String? = nil)
      notify_with_level(level, message.merge({"_facility" => progname || facility}))
    end

    private def add(level, message : String, progname : String? = nil)
      hash = {} of String => (String | Int::Signed | Int::Unsigned | Float64 | Bool)
      hash["short_message"] = message
      add(level, hash, progname)
    end

    private def notify_with_level(level, message : Hash(String, (String | Int::Signed | Int::Unsigned | Float64 | Bool)))
      return if level < @level

      message["version"] = "1.1"
      message["host"] = host
      message["level"] = GELF::LOGGER_MAPPING[level]
      message["timestamp"] = "%f" % Time.utc.to_unix_f
      message["short_message"] ||= "Message must be set!"

      data = serialize_message(message)

      if data.size > max_chunk_size
        msg_id = Random::Secure.hex(4)
        num_slices = (data.size / max_chunk_size.to_f).ceil.to_i

        num_slices.times do |index|
          io = IO::Memory.new

          # Magic bytes
          io.write_byte(0x1e_u8)
          io.write_byte(0x0F_u8)

          # Message id
          io.write(msg_id.to_slice)

          # Chunk info
          io.write_byte(index.to_u8)
          io.write_byte(num_slices.to_u8)

          # Bytes
          bytes_to_send = [data.size, max_chunk_size].min
          io.write(data[0, bytes_to_send])
          data += bytes_to_send

          @sender.write(io.to_slice)
        end
      else
        @sender.write(data)
      end
    rescue e : Socket::Error | IO::Error
      puts "Error sending log to server: #{e.message}"
      p message
    end

    private def serialize_message(message)
      io = IO::Memory.new
      deflater = Compress::Zlib::Writer.new(io)
      json = message.to_json
      deflater.print(json)
      deflater.close
      io.to_slice
    end
  end
end
