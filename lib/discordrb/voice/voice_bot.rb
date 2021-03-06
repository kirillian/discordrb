require 'discordrb/voice/encoder'
require 'discordrb/voice/network'

# Voice support
module Discordrb::Voice
  # How long one voice packet should ideally be (20 ms as defined by Discord)
  IDEAL_LENGTH = 20.0

  # How many bytes of data to read (1920 bytes * 2 channels) from audio PCM data
  DATA_LENGTH = 1920 * 2

  # This class represents a connection to a Discord voice server and channel. It can be used to play audio files and
  # streams and to control playback on currently playing tracks. The method {Bot#voice_connect} can be used to connect
  # to a voice channel.
  #
  # discordrb does latency adjustments every now and then to improve playback quality. I made sure to put useful
  # defaults for the adjustment parameters, but if the sound is patchy or too fast (or the speed varies a lot) you
  # should check the parameters and adjust them to your connection: {VoiceBot#adjust_interval},
  # {VoiceBot#adjust_offset}, and {VoiceBot#adjust_average}.
  class VoiceBot
    # @return [Integer, nil] the amount of time the stream has been playing, or `nil` if nothing has been played yet.
    attr_reader :stream_time

    # @return [Encoder] the encoder used to encode audio files into the format required by Discord.
    attr_reader :encoder

    # discordrb will occasionally measure the time it takes to send a packet, and adjust future delay times based
    # on that data. This makes voice playback more smooth, because if packets are sent too slowly, the audio will
    # sound patchy, and if they're sent too quickly, packets will "pile up" and occasionally skip some data or
    # play parts back too fast. How often these measurements should be done depends a lot on the system, and if it's
    # done too quickly, especially on slow connections, the playback speed will vary wildly; if it's done too slowly
    # however, small errors will cause quality problems for a longer time.
    # @return [Integer] how frequently audio length adjustments should be done, in ideal packets (20 ms).
    attr_accessor :adjust_interval

    # This particular value is also important because ffmpeg may take longer to process the first few packets. It is
    # recommended to set this to 10 at maximum, otherwise it will take too long to make the first adjustment, but it
    # shouldn't be any higher than {#adjust_interval}, otherwise no adjustments will take place. If {#adjust_interval}
    # is at a value higher than 10, this value should not be changed at all.
    # @see #adjust_interval
    # @return [Integer] the packet number (1 packet = 20 ms) at which length adjustments should start.
    attr_accessor :adjust_offset

    # This value determines whether or not the adjustment length should be averaged with the previous value. This may
    # be useful on slower connections where latencies vary a lot. In general, it will make adjustments more smooth,
    # but whether that is desired behaviour should be tried on a case-by-case basis.
    # @see #adjust_interval
    # @return [true, false] whether adjustment lengths should be averaged with the respective previous value.
    attr_accessor :adjust_average

    # The factor the audio's volume should be multiplied with. `1` is no change in volume, `0` is completely silent,
    # `0.5` is half the default volume and `2` is twice the default.
    # @return [Float] the volume for audio playback, `1.0` by default.
    attr_accessor :volume

    def initialize(channel, bot, token, session, endpoint, encrypted)
      @bot = bot
      @ws = VoiceWS.new(channel, bot, token, session, endpoint)
      @udp = @ws.udp
      @udp.encrypted = encrypted

      @sequence = @time = 0
      @skips = 0

      @adjust_interval = 100
      @adjust_offset = 10
      @adjust_average = false

      @volume = 1.0

      @encoder = Encoder.new
      @ws.connect
    end

    # @return [true, false] whether audio data sent will be encrypted.
    def encrypted?
      @udp.encrypted?
    end

    # Pause playback. This is not instant; it may take up to 20 ms for this change to take effect. (This is usually
    # negligible.)
    def pause
      @paused = true
    end

    # Continue playback. This change may take up to 100 ms to take effect, which is usually negligible.
    def continue
      @paused = false
    end

    # Skips to a later time in the song. It's impossible to go back without replaying the song.
    # @param secs [Float] How many seconds to skip forwards. Skipping will always be done in discrete intervals of
    #   0.05 seconds, so if the given amount is smaller than that, it will be rounded up.
    def skip(secs)
      @skips += (secs * (1000 / IDEAL_LENGTH)).ceil
    end

    # Sets whether or not the bot is speaking (green circle around user).
    # @param value [true, false] whether or not the bot should be speaking.
    def speaking=(value)
      @playing = value
      @ws.send_speaking(value)
    end

    # Stops the current playback entirely.
    def stop_playing
      @was_playing_before = @playing
      @speaking = false
      @playing = false
      sleep IDEAL_LENGTH / 1000.0 if @was_playing_before
    end

    # Permanently disconnects from the voice channel; to reconnect you will have to call {Bot#voice_connect} again.
    def destroy
      stop_playing
      @ws.destroy
      @encoder.destroy
    end

    # Plays a stream of raw data to the channel. All playback methods are blocking, i. e. they wait for the playback to
    # finish before exiting the method. This doesn't cause a problem if you just use discordrb events/commands to
    # play stuff, as these are fully threaded, but if you don't want this behaviour anyway, be sure to call these
    # methods in separate threads.
    # @param encoded_io [IO] A stream of raw PCM data (s16le)
    def play(encoded_io)
      stop_playing if @playing
      @retry_attempts = 3

      play_internal do
        buf = nil

        # Read some data from the buffer
        begin
          buf = encoded_io.readpartial(DATA_LENGTH) if encoded_io
        rescue EOFError
          @bot.debug('EOF while reading, breaking immediately')
          break
        end

        # Check whether the buffer has enough data
        if !buf || buf.length != DATA_LENGTH
          @bot.debug("No data is available! Retrying #{@retry_attempts} more times")
          break if @retry_attempts == 0

          @retry_attempts -= 1
          next
        end

        # Adjust volume
        buf = @encoder.adjust_volume(buf, @volume) if @volume != 1.0

        # Encode data
        @encoder.encode(buf)
      end
    end

    # Plays an encoded audio file of arbitrary format to the channel.
    # @see Encoder#encode_file
    # @see #play
    def play_file(file)
      play @encoder.encode_file(file)
    end

    # Plays a stream of encoded audio data of arbitrary format to the channel.
    # @see Encoder#encode_io
    # @see #play
    def play_io(io)
      play @encoder.encode_io(io)
    end

    # Plays a stream of audio data in the DCA format. This format has the advantage that no recoding has to be
    # done - the file contains the data exactly as Discord needs it.
    # @see https://github.com/bwmarrin/dca
    # @see #play
    def play_dca(file)
      stop_playing if @playing

      @bot.debug "Reading DCA file #{file}"
      input_stream = open(file)

      # Play the data, without re-encoding it to opus
      play_internal do
        begin
          # Read header
          header = input_stream.read(2).unpack('S')[0]
        rescue EOFError
          @bot.debug 'Finished DCA parsing'
          break
        end

        # Read bytes
        input_stream.read(header)
      end
    end

    alias_method :play_stream, :play_io

    private

    # Plays the data from the @io stream as Discord requires it
    def play_internal
      count = 0
      @playing = true

      # Default play length (ms), will be adjusted later
      @length = IDEAL_LENGTH

      self.speaking = true
      loop do
        if count % @adjust_interval == @adjust_offset
          # Starting from the tenth packet, perform length adjustment every 100 packets (2 seconds)
          @length_adjust = Time.now.nsec
        end

        break unless @playing

        # If we should skip, get some data, discard it and go to the next iteration
        if @skips > 0
          @skips -= 1
          yield
          next
        end

        # Track packet count, sequence and time (Discord requires this)
        count += 1
        (@sequence + 10 < 65_535) ? @sequence += 1 : @sequence = 0
        (@time + 9600 < 4_294_967_295) ? @time += 960 : @time = 0

        # Get packet data
        buf = yield
        next unless buf

        # Send the packet
        @udp.send_audio(buf, @sequence, @time)

        # Set the stream time (for tracking how long we've been playing)
        @stream_time = count * @length / 1000

        # Perform length adjustment
        if @length_adjust
          # Difference between length_adjust and now in ms
          ms_diff = (Time.now.nsec - @length_adjust) / 1_000_000.0
          if ms_diff >= 0
            @length = if @adjust_average
                        (IDEAL_LENGTH - ms_diff + @length) / 2.0
                      else
                        IDEAL_LENGTH - ms_diff
                      end

            @bot.debug("Length adjustment: new length #{@length}")
          end
          @length_adjust = nil
        end

        # If paused, wait
        sleep 0.1 while @paused

        # Wait `length` ms, then send the next packet
        sleep @length / 1000.0
      end

      @bot.debug('Performing final cleanup after stream ended')

      # Final cleanup
      stop_playing
    end
  end
end
