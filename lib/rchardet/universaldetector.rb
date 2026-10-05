# encoding: US-ASCII
######################## BEGIN LICENSE BLOCK ########################
# The Original Code is Mozilla Universal charset detector code.
#
# The Initial Developer of the Original Code is
# Netscape Communications Corporation.
# Portions created by the Initial Developer are Copyright (C) 2001
# the Initial Developer. All Rights Reserved.
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

    # Exact length byte order marks, longest first so that detection is
    # deterministic when one signature is a prefix of another.
    BOM_SIGNATURES = [
      ["\xFF\xFE\x00\x00", "UTF-32LE", 1.0],
      ["\x00\x00\xFE\xFF", "UTF-32BE", 1.0],
      ["\xFE\xFF\x00\x00", "X-ISO-10646-UCS-4-3412", 1.0],
      ["\x00\x00\xFF\xFE", "X-ISO-10646-UCS-4-2143", 1.0],
      ["\xEF\xBB\xBF", "UTF-8", 1.0],
      ["\xFF\xFE", "UTF-16LE", 1.0],
      ["\xFE\xFF", "UTF-16BE", 1.0],
    ].freeze
    UTF7_MARK = "\x2B\x2F\x76"
    UTF7_FOLLOWERS = ["\x38", "\x39", "\x2B", "\x2F"].freeze

    def initialize
      @highBitDetector = /[\x80-\xFF]/n
      @escDetector = /(\033|\~\{)/n
      @escCharSetProber = nil
      @utf1632prober = nil
      @charSetProbers = []
      reset()
    end

    def reset
      @result = {'encoding' => nil, 'confidence' => 0.0}
      @done = false
      @closed = false
      @start = true
      @gotData = false
      @inputState = EPureAscii
      @lastChar = ''
      @bomChecking = true
      @bomPending = +''.b
      if @escCharSetProber
        @escCharSetProber.reset()
      end
      if @utf1632prober
        @utf1632prober.reset()
      end
      for prober in @charSetProbers
        prober.reset()
      end
    end

    def feed(aBuf)
      return if @done
      aBuf = aBuf.to_s
      unless aBuf.encoding == Encoding::BINARY
        aBuf = aBuf.dup.force_encoding(Encoding::BINARY)
      end

      aLen = aBuf.length
      return if aLen == 0

      @gotData = true

      # While the very beginning of the stream could still be a BOM, retain a
      # leading fragment across feed boundaries. This makes a BOM split at any
      # byte position behave exactly like one continuous feed.
      if @bomChecking
        bom_encoding, bom_confidence, remainder =
          resolve_bom(@bomPending + aBuf, false)
        if bom_encoding
          @bomChecking = false
          @bomPending = +''.b
          @result = {'encoding' => bom_encoding, 'confidence' => bom_confidence}
          @done = true
          return
        elsif remainder.nil?
          # Whole fragment is still a strict prefix of some BOM signature.
          @bomPending = (@bomPending + aBuf).b
          return
        else
          # The prefix cannot be a BOM any more: release every retained byte,
          # in order, to the regular processing path.
          @bomChecking = false
          @bomPending = +''.b
          aBuf = remainder
          aLen = aBuf.length
        end
      end

      if @result['encoding'] and (@result['confidence'] > 0.0)
        @done = true
        return
      end
      return if aLen == 0

      process_chunk(aBuf)
    end

    def process_chunk(aBuf)
      aLen = aBuf.length
      if @inputState == EPureAscii
        if @highBitDetector =~ (aBuf)
          @inputState = EHighbyte
          ensure_highbyte_probers
        elsif (@inputState == EPureAscii) and @escDetector =~ (@lastChar + aBuf)
          @inputState = EEscAscii
        end
      end

      @lastChar = aBuf[-1, 1]

      if !@utf1632prober
        @utf1632prober = UTF1632Prober.new()
      end

      if @utf1632prober.get_state == EDetecting
        if @utf1632prober.feed(aBuf) == EFoundIt
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
        if @escCharSetProber.feed(aBuf) == EFoundIt
          @result = {'encoding' =>  @escCharSetProber.get_charset_name(),
            'confidence' =>  @escCharSetProber.get_confidence()
          }
          @done = true
        end
      elsif @inputState == EHighbyte
        ensure_highbyte_probers
        for prober in @charSetProbers
          if prober.feed(aBuf) == EFoundIt
            @result = {'encoding' =>  prober.get_charset_name(),
              'confidence' =>  prober.get_confidence()}
            @done = true
            break
          end
        end
      end

    end

    def ensure_highbyte_probers
      if @charSetProbers.nil? || @charSetProbers.empty?
        @charSetProbers = [MBCSGroupProber.new, SBCSGroupProber.new, Latin1Prober.new]
      end
    end

    def close
      return @result if @done
      @closed = true

      if @bomChecking && !@bomPending.empty?
        bom_encoding, bom_confidence, remainder =
          resolve_bom(@bomPending, true)
        @bomChecking = false
        @bomPending = +''.b
        if bom_encoding
          @gotData = true
          @result = {'encoding' => bom_encoding, 'confidence' => bom_confidence}
          @done = true
          return @result
        end
        @gotData = true
        process_chunk(remainder)
        return @result if @done
      end

      if !@gotData
        $stderr << "no data received!\n" if $debug
        @done = true
        return
      end
      @done = true

      if @inputState == EPureAscii
        @result = {'encoding' => 'ascii', 'confidence' => 1.0}
        return @result
      end

      if @inputState == EHighbyte
        confidences = {}
        @charSetProbers.each{ |prober| confidences[prober] = prober.get_confidence }
        maxProber = @charSetProbers.max{ |a,b| confidences[a] <=> confidences[b] }
        if maxProber and maxProber.get_confidence > MINIMUM_THRESHOLD
          @result = {'encoding' =>  maxProber.get_charset_name(),
            'confidence' =>  maxProber.get_confidence()}
          return @result
        end
      end

      if $debug
        $stderr << "no probers hit minimum threshhold\n" if $debug
        for prober in @charSetProbers[0].probers
          next if !prober
          $stderr << "#{prober.get_charset_name} confidence = #{prober.get_confidence}\n" if $debug
        end
      end
    end

    def closed?
      @closed
    end

    # Build a JSON-compatible, Marshal-free snapshot of every piece of state
    # required to continue detection in another process. No original input is
    # stored; only a few bytes of an unfinished character/escape/BOM prefix.
    def snapshot
      status = if @done
        @closed ? 'closed' : 'found'
      else
        'detecting'
      end
      StateSnapshot.attach_integrity({
        'formatVersion' => StateSnapshot::FORMAT_VERSION,
        'modelId' => StateSnapshot.model_id,
        'status' => status,
        'inputState' => @inputState,
        'gotData' => @gotData,
        'bomChecking' => @bomChecking,
        'bomPending' => StateSnapshot.encode_bytes(@bomPending),
        'lastChar' => StateSnapshot.encode_bytes(@lastChar),
        'result' => {
          'encoding' => @result['encoding'],
          'confidence' => @result['confidence'].to_f
        },
        'utf1632' => @utf1632prober ?
          StateSnapshot.snapshot_prober(@utf1632prober) : nil,
        'escProber' => @escCharSetProber ?
          StateSnapshot.snapshot_prober(@escCharSetProber) : nil,
        'highbyteProbers' => highbyte_probers_snapshot
      })
    end

    def snapshot_json
      StateSnapshot.serialize(snapshot)
    end

    # Restore a detector from a snapshot Hash as produced by #snapshot. The
    # whole snapshot is validated before any state is installed; on failure
    # CharDet::SnapshotError is raised and no detector is returned.
    def self.restore(snapshot)
      allocate.tap { |detector| detector.send(:install_snapshot, snapshot) }
    end

    def self.restore_json(string)
      restore(StateSnapshot.deserialize(string))
    end
    private

    def highbyte_probers_snapshot
      if @charSetProbers.nil? || @charSetProbers.empty?
        []
      else
        @charSetProbers.map { |prober| StateSnapshot.snapshot_prober(prober) }
      end
    end

    def install_snapshot(snapshot)
      StateSnapshot.validate_header(snapshot)
      StateSnapshot.verify_integrity(snapshot)
      status = snapshot['status']
      input_state = StateSnapshot.int_field(snapshot, 'inputState', EPureAscii, EHighbyte)
      got_data = StateSnapshot.bool_field(snapshot, 'gotData')
      bom_checking = StateSnapshot.bool_field(snapshot, 'bomChecking')
      bom_pending = StateSnapshot.decode_bytes(snapshot['bomPending'], 'bomPending', 3)
      last_char = StateSnapshot.decode_bytes(snapshot['lastChar'], 'lastChar', 1)
      result_data = StateSnapshot.expect_class(snapshot['result'], Hash, 'result')
      encoding = result_data['encoding']
      unless encoding.nil? || encoding.is_a?(String)
        raise SnapshotError, 'result.encoding must be a string or null'
      end
      confidence = StateSnapshot.float_field(result_data, 'confidence')
      unless confidence >= 0.0 && confidence <= 1.0
        raise SnapshotError, 'result.confidence out of range'
      end
      unless last_char.bytesize <= 1
        raise SnapshotError, 'lastChar must be at most one byte'
      end
      unless bom_pending.empty? || bom_checking
        raise SnapshotError, 'bomPending present but BOM checking is over'
      end
      if bom_checking && !bom_pending.empty?
        unless StateSnapshot.bom_prefix_pending?(bom_pending)
          raise SnapshotError, 'bomPending is not a valid BOM prefix'
        end
      end
      validate_status_consistency(status, got_data, encoding, confidence, input_state, snapshot)

      utf16 = build_validated_utf16(snapshot['utf1632'])
      esc = build_validated_esc(snapshot['escProber'], input_state)
      highbyte = build_validated_highbyte(snapshot['highbyteProbers'], input_state)

      initialize
      @inputState = input_state
      @gotData = got_data
      @bomChecking = bom_checking
      @bomPending = bom_pending.dup
      @lastChar = last_char
      @result = {'encoding' => encoding, 'confidence' => confidence}
      @utf1632prober = utf16
      @escCharSetProber = esc
      @charSetProbers = highbyte
      case status
      when 'found' then @done = true; @closed = false
      when 'closed' then @done = true; @closed = true
      when 'detecting' then @done = false; @closed = false
      end
    end

    def validate_status_consistency(status, got_data, encoding, confidence, input_state, snapshot)
      if status == 'found' && (encoding.nil? || confidence <= 0.0)
        raise SnapshotError, 'found status requires a positive result'
      end
      if status == 'closed' && got_data && input_state == EPureAscii && encoding != 'ascii'
        raise SnapshotError, 'closed pure-ascii result must be ascii'
      end
      if status == 'detecting' && !got_data && snapshot['utf1632']
        raise SnapshotError, 'prober present before any data'
      end
      if !got_data && (snapshot['escProber'] ||
                       (snapshot['highbyteProbers'].is_a?(Array) &&
                        !snapshot['highbyteProbers'].empty?))
        raise SnapshotError, 'prober present before any data'
      end
    end

    def build_validated_utf16(data)
      return nil if data.nil?
      StateSnapshot.expect_class(data, Hash, 'utf1632')
      unless data['type'] == 'UTF1632Prober'
        raise SnapshotError, 'utf1632 type mismatch'
      end
      prober = UTF1632Prober.new
      prober.restore_from_snapshot(data)
      prober
    end

    def build_validated_esc(data, input_state)
      if data.nil?
        if input_state == EEscAscii
          raise SnapshotError, 'esc input state without esc prober'
        end
        return nil
      end
      StateSnapshot.expect_class(data, Hash, 'escProber')
      unless data['type'] == 'EscCharSetProber'
        raise SnapshotError, 'escProber type mismatch'
      end
      unless input_state == EEscAscii
        raise SnapshotError, 'esc prober present without esc input state'
      end
      prober = EscCharSetProber.new
      prober.restore_from_snapshot(data)
      prober
    end

    def build_validated_highbyte(data, input_state)
      StateSnapshot.expect_class(data, Array, 'highbyteProbers')
      if data.empty?
        if input_state == EHighbyte
          raise SnapshotError, 'highbyte state without highbyte probers'
        end
        return []
      end
      unless input_state == EHighbyte
        raise SnapshotError, 'highbyte probers present without highbyte state'
      end
      unless data.length == StateSnapshot::HIGHBYTE_PROBER_NAMES.length
        raise SnapshotError, 'highbyte prober count mismatch'
      end
      StateSnapshot::HIGHBYTE_PROBER_NAMES.each_with_index do |name, i|
        unless data[i].is_a?(Hash) && data[i]['type'] == name
          raise SnapshotError, "expected highbyte prober #{name} at #{i}"
        end
      end
      groups = [MBCSGroupProber.new, SBCSGroupProber.new, Latin1Prober.new]
      groups.each_with_index { |prober, i| prober.restore_from_snapshot(data[i]) }
      groups
    end


    # Examine the leading BOM candidate. Returns one of:
    #   [encoding, confidence, remainder] when a BOM is confirmed
    #   [nil, nil, nil]                  while buf is still an ambiguous prefix
    #   [nil, nil, buf]                  when buf cannot be a BOM and must be
    #                                    processed immediately
    # Signatures are probed longest first. A signature is only committed once
    # enough bytes are present to also rule out every longer signature, so a
    # feed boundary never changes the answer relative to a continuous feed.
    def resolve_bom(buf, finishing)
      return [nil, nil, buf] if buf.empty?

      if buf.length >= 4
        if buf.start_with?(UTF7_MARK) && UTF7_FOLLOWERS.include?(buf[3])
          # NOTE: Ruby only includes "dummy" support for UTF-7.
          # A Ruby UTF-7 string can't have methods called on it, nor can it be converted to anything else, but "BINARY"/"ASCII-8BIT".
          # Still, this doesn't make detection useless, as UTF-7 encodings exist in the wild, and the scenario may need to be handled.
          # 2B 2F 76 38 / 39 / 2B / 2F  UTF-7
          return ["UTF-7", 0.99, buf[4..-1] || ''.b]
        end
      end
      if finishing && buf.length == 3 && buf == UTF7_MARK
        # 2B 2F 76 38 2D  UTF-7 with no following character (empty string)
        return ["UTF-7", 0.99, ''.b]
      end

      BOM_SIGNATURES.each do |signature, encoding, confidence|
        next unless buf.start_with?(signature)
        # Wait for the fourth byte while a longer UTF-32/UCS-4 signature
        # could still extend a UTF-16 BOM; only commit when the stream is
        # finishing. Longer signatures are listed first and return above.
        if !finishing && buf.length < 4 && extendable_prefix?(buf)
          return [nil, nil, nil]
        end
        return [encoding, confidence, buf[signature.length..-1] || ''.b]
      end

      # A complete UTF-7 mark without its deciding follower is held back for
      # one more byte; at close it is recognised as UTF-7 above.
      if !finishing && buf == UTF7_MARK
        return [nil, nil, nil]
      end

      if !finishing && bom_prefix_candidate?(buf)
        return [nil, nil, nil]
      end

      [nil, nil, buf]
    end

    def extendable_prefix?(frag)
      BOM_SIGNATURES.any? do |other, _e, _c|
        other.length > frag.length && other.start_with?(frag)
      end
    end

    def bom_prefix_candidate?(frag)
      return false if frag.length >= 4
      candidates = BOM_SIGNATURES.map { |sig, _e, _c| sig }
      candidates << UTF7_MARK
      candidates.any? do |sig|
        next false if frag.length > sig.length
        next false unless sig.start_with?(frag)
        # A strict prefix is always ambiguous. A complete mark is retained
        # only while another byte could still confirm or refute it.
        frag.length < sig.length || (frag.length < 3)
      end
    end

  end
end
