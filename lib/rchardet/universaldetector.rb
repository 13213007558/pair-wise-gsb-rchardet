# encoding: US-ASCII
######################## BEGIN LICENSE BLOCK ########################
# The Original Code is Mozilla Universal charset detector code.
#
# The Initial Developer of the Original Code is
# Netscape Communications Corporation. Portions created by the Initial
# Developer are Copyright (C) 2001 the Initial Developer.
# All Rights Reserved.
#
# Contributor(s):
#   Jeff Hodges - port to Ruby
#   Mark Pilgrim - port to Python
#   Shy Shalom - original C code
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301  USA
######################### END LICENSE BLOCK #########################

module CharDet
  MINIMUM_DATA_THRESHOLD = 4
  MINIMUM_THRESHOLD = 0.20
  EPureAscii = 0
  EEscAscii = 1
  EHighbyte = 2

  class UniversalDetector
    attr_reader :done, :result

    # BOM/declaration signatures recognized at the very start of the stream.
    # Ordered longest-first so 4-byte signatures win over prefixes.
    BOM_SIGNATURES = [
      ["\xEF\xBB\xBF", "UTF-8", 1.0],
      ["\xFF\xFE\x00\x00", "UTF-32LE", 1.0],
      ["\x00\x00\xFE\xFF", "UTF-32BE", 1.0],
      ["\xFE\xFF\x00\x00", "X-ISO-10646-UCS-4-3412", 1.0],
      ["\x00\x00\xFF\xFE", "X-ISO-10646-UCS-4-2143", 1.0],
      ["\x2B\x2F\x76\x38", "UTF-7", 0.99],
      ["\x2B\x2F\x76\x39", "UTF-7", 0.99],
      ["\x2B\x2F\x76\x2B", "UTF-7", 0.99],
      ["\x2B\x2F\x76\x2F", "UTF-7", 0.99],
      ["\xFF\xFE", "UTF-16LE", 1.0],
      ["\xFE\xFF", "UTF-16BE", 1.0]
    ].freeze

    def initialize
      @highBitDetector = /[\x80-\xFF]/n
      @escDetector = /(\033|\~\{)/n
      reset()
    end

    def reset
      @result = {'encoding' => nil, 'confidence' => 0.0}
      @done = false
      @closed = false
      @gotData = false
      @inputState = EPureAscii
      @lastChar = ''.b
      # Prefix bytes of the first chunk that could still become a BOM.
      @bomLead = ''.b
      @bomResolved = false
      @escTriggerPending = false
      @replayLastByte = nil
      @sbcsBootstrap = ''.b
      @bootstrapEndsLetter = false
      @bootstrapLastRawWasLetter = false
      @firstHighbyteChunk = true
      @escCharSetProber = nil
      @utf1632prober = nil
      @charSetProbers = []
    end

    def feed(aBuf)
      return if @done || @closed

      aBuf = aBuf.to_s.dup.force_encoding(Encoding::BINARY)
      aLen = aBuf.length
      return if aLen == 0

      unless @gotData
        @gotData = true
      end

      # A BOM may itself be split across arbitrary feed boundaries.
      flush = resolve_bom_prefix(aBuf)
      return if @done
      process(flush) unless flush.empty?
    end

    def close
      return if @done
      if !@gotData
        $stderr << "no data received!\n" if $debug
        @closed = true
        return
      end
      # Flush bytes that were held back waiting for a possible BOM.
      unless @bomResolved || @bomLead.empty?
        pending = @bomLead
        @bomLead = ''.b
        @bomResolved = true
        process(pending) unless pending.empty?
      end
      @closed = true
      return if @done

      if @inputState == EPureAscii
        @result = {'encoding' => 'ascii', 'confidence' => 1.0}
        @done = true
        return @result
      end

      if @inputState == EHighbyte
        confidences = {}
        @charSetProbers.each{ |prober| confidences[prober] = prober.get_confidence }
        maxProber = @charSetProbers.max{ |a,b| confidences[a] <=> confidences[b] }
        if maxProber and maxProber.get_confidence > MINIMUM_THRESHOLD
          @result = {'encoding' =>  maxProber.get_charset_name(),
            'confidence' =>  maxProber.get_confidence()}
          @done = true
          return @result
        end
      end

      if $debug
        $stderr << "no probers hit minimum threshhold\n" if $debug
        if @charSetProbers && !@charSetProbers.empty? && @charSetProbers[0].respond_to?(:probers)
          for prober in @charSetProbers[0].probers
            next if !prober
            $stderr << "#{prober.get_charset_name} confidence = #{prober.get_confidence}\n" if $debug
          end
        end
      end
      nil
    end

    def closed?
      @closed
    end

    # Plain-data, JSON-compatible snapshot. Never contains the raw input.
    def snapshot
      snapshot = {
        "format_version" => Snapshot::FORMAT_VERSION,
        "rchardet_version" => CharDet::VERSION,
        "model_id" => Snapshot.model_id,
        "closed" => @closed,
        "detector" => {
          "done" => @done,
          "got_data" => @gotData,
          "input_state" => @inputState,
          "last_char" => Snapshot.binary(@lastChar.dup),
          "bom_lead" => Snapshot.binary(@bomLead.dup),
          "bom_resolved" => @bomResolved,
          "esc_trigger_pending" => @escTriggerPending,
          "replay_last_byte" => @replayLastByte.nil? ? nil : Snapshot.binary(@replayLastByte.dup),
          "first_highbyte_chunk" => @firstHighbyteChunk,
          "sbcs_bootstrap" => Snapshot.binary(@sbcsBootstrap.dup),
          "bootstrap_ends_raw_letter" => @bootstrapLastRawWasLetter,
          "result" => {
            "encoding" => @result['encoding'],
            "confidence" => @result['confidence']
          }
        }
      }

      if @utf1632prober
        snapshot["utf1632_prober"] = @utf1632prober.snapshot_state
      end
      if @escCharSetProber
        snapshot["esc_prober"] = @escCharSetProber.snapshot_state
      end
      if @inputState == EHighbyte
        probers = @charSetProbers.empty? ?
          [MBCSGroupProber.new, SBCSGroupProber.new, Latin1Prober.new] : @charSetProbers
        snapshot["charset_probers"] = probers.map(&:snapshot_state)
      end
      snapshot
    end

    # Build a new, independent detector from a validated snapshot Hash.
    def self.restore_snapshot(snapshot)
      Snapshot.check_version_and_model(snapshot)
      detector_state = Snapshot.hash_field(snapshot, "detector")

      detector = UniversalDetector.allocate
      detector.send(:init_from_snapshot, snapshot, detector_state)
      detector
    end

    private

    def init_from_snapshot(snapshot, detector_state)
      @highBitDetector = /[\x80-\xFF]/n
      @escDetector = /(\033|\~\{)/n

      @closed = Snapshot.bool_field(snapshot, "closed")
      @done = Snapshot.bool_field(detector_state, "done")
      @gotData = Snapshot.bool_field(detector_state, "got_data")
      @inputState = Snapshot.int_field(detector_state, "input_state", EPureAscii, EHighbyte)
      @lastChar = Snapshot.binary_field(detector_state, "last_char", 1)
      @bomLead = Snapshot.binary_field(detector_state, "bom_lead", 3)
      @bomResolved = Snapshot.bool_field(detector_state, "bom_resolved")
      @escTriggerPending = Snapshot.bool_field(detector_state, "esc_trigger_pending")
      replay_value = detector_state["replay_last_byte"]
      if replay_value.nil?
        @replayLastByte = nil
      else
        @replayLastByte = Snapshot.binary_field(detector_state, "replay_last_byte", 1)
        Snapshot.assert!(@replayLastByte.bytesize == 1,
          "replay_last_byte must be exactly 1 byte")
      end
      @firstHighbyteChunk = Snapshot.bool_field(detector_state, "first_highbyte_chunk")
      # High-byte probers are born only when high bytes appear. If they were
      # not present in the snapshot because the stream had only reached pure
      # ASCII/escape mode at that point, their first chunk needs the filtered
      # ASCII prefix replayed instead of a normal whole-chunk feed.
      @resumedBeforeHighbyte = @gotData && @inputState != EHighbyte
      @sbcsBootstrap = Snapshot.binary_field(detector_state, "sbcs_bootstrap", 65536)
      @bootstrapLastRawWasLetter = Snapshot.bool_field(detector_state, "bootstrap_ends_raw_letter")
      result = Snapshot.hash_field(detector_state, "result")
      encoding = result["encoding"]
      Snapshot.assert!(encoding.nil? || encoding.is_a?(String),
        "result encoding must be nil or a String")
      confidence = Snapshot.float_field(result, "confidence", 0.0, 1.0)
      @result = {'encoding' => encoding, 'confidence' => confidence}

      if @done
        Snapshot.assert!(confidence > 0.0 && !encoding.nil?,
          "a done detector must carry a detection result")
      elsif confidence > 0.0
        raise SnapshotError, "a non-done detector must not carry a positive result"
      end
      Snapshot.assert!(!@closed || !@escTriggerPending,
        "a closed detector cannot have an unprocessed escape trigger")
      if @gotData
        Snapshot.assert!(@done || !@bomResolved || @lastChar.bytesize == 1,
          "a feedable, resolved detector must carry its last byte")
      else
        Snapshot.assert!(@lastChar.empty? && @bomLead.empty? && @inputState == EPureAscii,
          "a detector without data must not carry detection progress")
      end
      unless @bomLead.empty?
        Snapshot.assert!(!@bomResolved,
          "pending BOM lead requires unresolved BOM detection")
        Snapshot.assert!(BOM_SIGNATURES.any? { |signature, _, _| signature.start_with?(@bomLead) },
          "pending BOM lead is not a prefix of any known signature")
      end

      @utf1632prober = nil
      if snapshot.key?("utf1632_prober")
        @utf1632prober = UTF1632Prober.new
        @utf1632prober.restore_state(Snapshot.hash_field(snapshot, "utf1632_prober"))
      end

      Snapshot.assert!(@inputState != EEscAscii || snapshot.key?("esc_prober"),
        "escape input state requires an escape prober snapshot")
      Snapshot.assert!(@inputState != EHighbyte || snapshot.key?("charset_probers"),
        "high-byte input state requires charset prober snapshots")

      @escCharSetProber = nil
      if snapshot.key?("esc_prober")
        Snapshot.assert!(@inputState == EEscAscii,
          "escape prober snapshot requires escape input state")
        @escCharSetProber = EscCharSetProber.new
        @escCharSetProber.restore_state(Snapshot.hash_field(snapshot, "esc_prober"))
      end

      @charSetProbers = []
      if snapshot.key?("charset_probers")
        Snapshot.assert!(@inputState == EHighbyte,
          "charset prober snapshots require high-byte input state")
        entries = snapshot["charset_probers"]
        Snapshot.assert!(entries.is_a?(Array) && entries.length == 3,
          "charset_probers must contain 3 entries")
        groups = [MBCSGroupProber.new, SBCSGroupProber.new, Latin1Prober.new]
        entries.each_with_index do |entry, index|
          groups[index].restore_state(entry)
        end
        @charSetProbers = groups
      end
      self
    end

    def declare_result(encoding, confidence)
      @result = {'encoding' => encoding, 'confidence' => confidence}
      @done = true
    end

    # Hold back only the bytes that could still begin a BOM. Returns the
    # bytes that are safe to feed through the normal probers.
    def resolve_bom_prefix(aBuf)
      head = @bomLead + aBuf
      @bomLead = ''.b

      unless @bomResolved
        # Only hold bytes back while they can still become a signature. Any
        # exact signature declares immediately; everything else flows through.
        exact = BOM_SIGNATURES.find { |signature, _, _| signature.bytesize <= head.bytesize && head.start_with?(signature) }
        if exact && (exact[0].bytesize == 4 || exact[0].bytesize == 3 ||
                     !extendable_to_longer?(head, exact[0]))
          @bomResolved = true
          declare_result(exact[1], exact[2])
          return ''.b
        end
        if head.bytesize < 4 && extendable_bom_prefix?(head)
          # Only hold prefixes that are themselves the start of a signature
          # (e.g. \x00\x00 or \xFF\xFE); a lone \x00 that is merely a prefix
          # of a 4-byte signature's second position is not held back.
          anchored = BOM_SIGNATURES.any? { |signature, _, _| signature.start_with?(head) }
          if anchored
            @bomLead = head.dup
            @bomResolved = false
            return ''.b
          end
        end

        @bomResolved = true
      end

      head
    end

    def extendable_bom_prefix?(head)
      BOM_SIGNATURES.any? do |signature, _, _|
        next false if signature.bytesize <= head.bytesize
        signature.byteslice(0, head.bytesize) == head
      end
    end

    # True when a matched short signature could still be the beginning of a
    # longer signature given the bytes seen so far.
    def extendable_to_longer?(head, matched_signature)
      BOM_SIGNATURES.any? do |signature, _, _|
        next false unless signature.bytesize > matched_signature.bytesize
        signature.byteslice(0, head.bytesize) == head
      end
    end

    def letter_ascii?(byte)
      byte && ((65..90).include?(byte) || (97..122).include?(byte))
    end

    # Append the filtered form of an ASCII chunk to @sbcsBootstrap.
    # @bootstrapLastRawWasLetter remembers whether the previous RAW byte was
    # an English letter; when both sides are letters the continuous gsub
    # emits one collapsed space, so this chunk's leading space is dropped.
    def append_filtered_prefix(previous_raw_byte, chunk)
      filtered = chunk.gsub(/([A-Za-z])+/n, ' ')
      # gsub only replaces letter runs with spaces; a run split across a
      # chunk boundary collapses to one space, so drop a duplicate leading
      # space when both the prefix tail and this chunk produced one.
      if @bootstrapLastRawWasLetter && !chunk.empty? && letter_ascii?(chunk.getbyte(0)) &&
         filtered.start_with?(' '.b) && @sbcsBootstrap.end_with?(' '.b)
        filtered = filtered.byteslice(1, filtered.bytesize - 1)
      end
      @sbcsBootstrap = @sbcsBootstrap + filtered
      @bootstrapLastRawWasLetter = !chunk.empty? && letter_ascii?(chunk.getbyte(-1))
      @sbcsBootstrap
    end

    def process(aBuf)
      if @result['encoding'] && (@result['confidence'] > 0.0)
        @done = true
        return
      end

      previousLastChar = @lastChar
      fullBuf = aBuf
      if @inputState == EPureAscii
        if @highBitDetector =~ aBuf
          @inputState = EHighbyte
          @firstHighbyteChunk = true
          high_index = aBuf.index(@highBitDetector)
          leading = aBuf.byteslice(0, high_index)
          append_filtered_prefix(previousLastChar, leading)
          # For SBCS replay of the whole chunk: did a raw letter immediately
          # precede the chunk's first byte?
          before_chunk_letter = !previousLastChar.empty? && letter_ascii?(previousLastChar.getbyte(0))
          chunk_first_letter = letter_ascii?(aBuf.getbyte(0))
          @bootstrapEndsLetter = before_chunk_letter && chunk_first_letter
          @bootstrapLastRawWasLetter = letter_ascii?(fullBuf.getbyte(-1))
        elsif @escDetector =~ (@lastChar + aBuf)
          @inputState = EEscAscii
          @escTriggerPending = true
        else
          append_filtered_prefix(previousLastChar, aBuf)
        end
      end

      @lastChar = fullBuf[-1, 1]

      if !@utf1632prober
        @utf1632prober = UTF1632Prober.new()
      end

      if @utf1632prober.get_state == EDetecting
        if @utf1632prober.feed(fullBuf) == EFoundIt
          @result = {
            "encoding" => @utf1632prober.get_charset_name(),
            "confidence" => @utf1632prober.get_confidence()
          }
          @done = true
          return
        end
      end

      if @inputState == EEscAscii
        if !@escCharSetProber
          @escCharSetProber = EscCharSetProber.new()
        end
        # When the escape byte itself was the last byte of the previous chunk,
        # replay it so escape state machines see the uninterrupted sequence.
        escBuf = @escTriggerPending ? previousLastChar + fullBuf : fullBuf
        @escTriggerPending = false
        if @escCharSetProber.feed(escBuf) == EFoundIt
          @result = {'encoding' =>  @escCharSetProber.get_charset_name(),
            'confidence' =>  @escCharSetProber.get_confidence()
          }
          @done = true
        end
      elsif @inputState == EHighbyte
        if @charSetProbers.nil? || @charSetProbers.empty?
          mbcs = MBCSGroupProber.new()
          sbcs = SBCSGroupProber.new()
          latin1 = Latin1Prober.new()
          @charSetProbers = [mbcs, sbcs, latin1]
          @probersSawHighbyteSetup = true
        end
        @charSetProbers.each_with_index do |prober, index|
          fed = if index == 1
            if @firstHighbyteChunk
              if @resumedBeforeHighbyte
                # Resumed from a pure-ASCII snapshot: give the prober the
                # whole chunk plus the filtered prefix for correct pairing.
                prober.feed_first_highbyte(aBuf, aBuf.index(@highBitDetector) || 0,
                  @sbcsBootstrap, @bootstrapEndsLetter)
              else
                # Continuous stream: prober is born seeing the whole chunk.
                prober.feed(aBuf)
              end
            else
              prober.feed_with_replay(aBuf, @replayLastByte,
                !@replayLastByte.nil? && @replayLastByte.match?(/[A-Za-z]/n))
            end
          else
            prober.feed(aBuf)
          end
          if fed == EFoundIt
            @result = {'encoding' =>  prober.get_charset_name(),
              'confidence' =>  prober.get_confidence()}
            @done = true
            break
          end
        end
        @firstHighbyteChunk = false
      end
      # Always keep the raw previous byte; it lets single-byte probers see the
      # pair that crosses a chunk boundary (including the pure-ASCII to
      # high-byte transition where they did not yet exist).
      @replayLastByte = fullBuf.byteslice(-1, 1)
    end
  end
end
