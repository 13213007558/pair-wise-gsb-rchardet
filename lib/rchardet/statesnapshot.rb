# encoding: US-ASCII
######################## BEGIN LICENSE BLOCK ########################
# Portable detection state for UniversalDetector.
#
# A snapshot is a plain JSON-compatible Hash of scalar values, counters and
# model identifiers. It deliberately contains no original input and never
# uses Marshal, so it can be handed to another process and validated before
# being trusted. Binary fragments (pending characters/escape sequences) are
# carried as strict Base64 strings.
######################### END LICENSE BLOCK #########################

require 'json'

module CharDet
  FORMAT_MODEL_REVISION = 1
  # Raised whenever a snapshot cannot be trusted: unknown/unsupported format,
  # a model that does not belong to this rchardet build, or a field whose
  # value is out of its legal range or inconsistent with its counters.
  class SnapshotError < StandardError; end

  module StateSnapshot
    FORMAT_VERSION = 1
    SNAPSHOT_STATUSES = %w[detecting closed found].freeze

    B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'.freeze
    B64_VALUES = Array.new(256) { |i| B64_ALPHABET.index(i.chr) }.freeze

    # Self-contained strict Base64 (RFC 4648) codec. base64 stopped being a
    # default gem in Ruby 3.4, and snapshots must not pull in a new
    # dependency just to carry a few pending bytes.
    def self.strict_base64_encode(bin)
      bytes = bin.bytes
      out = +''
      (0...bytes.length).step(3) do |i|
        chunk = bytes[i, 3]
        n = chunk.length
        triplet = (chunk[0] << 16) | ((chunk[1] || 0) << 8) | (chunk[2] || 0)
        out << B64_ALPHABET[(triplet >> 18) & 63]
        out << B64_ALPHABET[(triplet >> 12) & 63]
        out << (n >= 2 ? B64_ALPHABET[(triplet >> 6) & 63] : '=')
        out << (n == 3 ? B64_ALPHABET[triplet & 63] : '=')
      end
      out
    end

    def self.strict_base64_decode(str)
      unless str.is_a?(String) && str.ascii_only?
        raise SnapshotError, 'base64 must be ASCII'
      end
      raise SnapshotError, 'invalid base64 length' if str.length % 4 != 0
      bytes = []
      chars = str.chars
      (0...chars.length).step(4) do |i|
        c = chars[i, 4]
        raise SnapshotError, 'invalid base64 padding' unless c.length == 4
        pad = c.count('=')
        raise SnapshotError, 'invalid base64 padding' if pad > 2
        if pad == 2 && c[2] != '='
          raise SnapshotError, 'invalid base64 padding position'
        end
        if pad == 1 && c[3] != '='
          raise SnapshotError, 'invalid base64 padding position'
        end
        raise SnapshotError, 'invalid base64 padding' if pad == 2 && c[3] != '='
        vals = c.map { |ch| ch == '=' ? 0 : B64_VALUES[ch.ord] }
        if vals.include?(nil)
          raise SnapshotError, 'invalid base64 character'
        end
        triplet = (vals[0] << 18) | (vals[1] << 12) | (vals[2] << 6) | vals[3]
        bytes << ((triplet >> 16) & 255)
        bytes << ((triplet >> 8) & 255) if pad == 0 || pad == 1
        bytes << (triplet & 255) if pad == 0
      end
      bytes.pack('C*').b
    end

    # All coding state machines known to this build.
    SM_MODELS = [
      HZSMModel, ISO2022CNSMModel, ISO2022JPSMModel, ISO2022KRSMModel,
      UTF8SMModel,
      Big5SMModel, EUCJPSMModel, EUCKRSMModel, EUCTWSMModel,
      GB18030SMModel, SJISSMModel,
    ].freeze
    SM_MODEL_REGISTRY = SM_MODELS.map { |m| [m['name'], m] }.to_h.freeze

    # Canonical order and identity of the group prober trees. Restore builds
    # the same trees and refuses snapshots whose layout differs.
    MBCS_PROBER_NAMES = %w[UTF8Prober SJISProber EUCJPProber GB18030Prober
                           EUCKRProber Big5Prober EUCTWProber].freeze
    HIGHBYTE_PROBER_NAMES = ['MBCSGroupProber', 'SBCSGroupProber',
                             'Latin1Prober'].freeze

    # Identification of the prober/model configuration this snapshot came
    # from. It includes the gem version and a fingerprint of every state
    # machine table, so a snapshot built against different models cannot be
    # restored silently.
    def self.model_id
      @model_id ||= begin
        require 'digest'
        payload = +''.b
        SM_MODELS.each do |model|
          payload << model['name']
          payload << [model['classFactor'], model['classTable'].length].pack('l>l>')
          payload << model['classTable'].pack('C*')
          payload << model['stateTable'].pack('l>*')
          payload << model['charLenTable'].pack('C*')
        end
        fingerprint = Digest::SHA256.hexdigest(payload)
        "rchardet-#{VERSION}-probers-#{FORMAT_MODEL_REVISION}-#{fingerprint[0, 16]}"
      end
    end

    def self.encode_bytes(str)
      strict_base64_encode(str.to_s.dup.force_encoding(Encoding::BINARY))
    end

    def self.decode_bytes(value, field, max_length)
      expect_class(value, String, field)
      begin
        decoded = strict_base64_decode(value)
      rescue SnapshotError => e
        raise SnapshotError, "#{field} is not strict Base64 (#{e.message})"
      end
      if decoded.bytesize > max_length
        raise SnapshotError, "#{field} exceeds #{max_length} bytes"
      end
      decoded
    end

    def self.expect_class(value, klass, field)
      unless value.is_a?(klass)
        raise SnapshotError, "#{field} must be a #{klass}, got #{value.class}"
      end
      value
    end

    def self.int_field(data, field, min, max)
      value = expect_class(data[field], Integer, field)
      unless value >= min && value <= max
        raise SnapshotError, "#{field}=#{value} out of range [#{min}, #{max}]"
      end
      value
    end

    def self.bool_field(data, field)
      value = data[field]
      unless value == true || value == false
        raise SnapshotError, "#{field} must be true or false"
      end
      value
    end

    def self.float_field(data, field)
      value = data[field]
      unless value.is_a?(Numeric)
        raise SnapshotError, "#{field} must be numeric"
      end
      value.to_f
    end

    def self.serialize(snapshot)
      JSON.dump(snapshot)
    end

    # Integrity tag binding every structural field of a snapshot to the
    # model fingerprint. It is not a security boundary (there are no secrets),
    # but it rejects snapshots whose counters or state were hand-edited or
    # produced against a different build.
    def self.integrity_tag(snapshot_without_tag)
      require 'digest'
      payload = JSON.dump(snapshot_without_tag)
      Digest::SHA256.hexdigest(model_id + '|' + payload)
    end

    def self.attach_integrity(snapshot)
      tagged = snapshot.dup
      tagged.delete('integrity')
      tagged['integrity'] = integrity_tag(tagged)
      tagged
    end

    def self.verify_integrity(snapshot)
      provided = snapshot['integrity']
      unless provided.is_a?(String)
        raise SnapshotError, 'snapshot integrity tag missing'
      end
      stripped = snapshot.dup
      stripped.delete('integrity')
      expected = integrity_tag(stripped)
      unless provided == expected
        raise SnapshotError, 'snapshot integrity tag mismatch (corrupted or '
              'model-changed state)'
      end
    end

    def self.deserialize(string)
      expect_class(string, String, 'snapshot')
      begin
        data = JSON.parse(string)
      rescue JSON::ParserError => e
        raise SnapshotError, "snapshot is not valid JSON: #{e.message}"
      end
      expect_class(data, Hash, 'snapshot')
      data
    end

    def self.validate_header(snapshot)
      expect_class(snapshot, Hash, 'snapshot')
      version = int_field(snapshot, 'formatVersion', 1, FORMAT_VERSION)
      unless version == FORMAT_VERSION
        raise SnapshotError, "unsupported snapshot format version #{version}"
      end
      model = expect_class(snapshot['modelId'], String, 'modelId')
      unless model == model_id
        raise SnapshotError, "snapshot model id is incompatible with this build"
      end
      unless SNAPSHOT_STATUSES.include?(snapshot['status'])
        raise SnapshotError, "unknown snapshot status: #{snapshot['status'].inspect}"
      end
    end

    def self.model_by_name(name)
      SM_MODEL_REGISTRY.fetch(name) do
        raise SnapshotError, "unknown coding state machine: #{name.inspect}"
      end
    end

    # Whether a fragment captured across a feed boundary is a legal pending
    # BOM/UTF-7 prefix to carry in a snapshot.
    def self.bom_prefix_pending?(frag)
      return false unless frag.is_a?(String) && frag.encoding == Encoding::BINARY
      return false if frag.empty? || frag.bytesize > 3
      candidates = UniversalDetector::BOM_SIGNATURES.map { |sig, _e, _c| sig }
      candidates << UniversalDetector::UTF7_MARK
      candidates.any? do |sig|
        frag.bytesize < sig.length && sig.start_with?(frag)
      end || frag == UniversalDetector::UTF7_MARK
    end

    # Rebuild a CodingStateMachine from a validated snapshot fragment.
    def self.restore_machine(data, _max_state = nil)
      expect_class(data, Hash, 'codingSM')
      model = model_by_name(expect_class(data['model'], String, 'codingSM.model'))
      max_state = model['stateTable'].max
      state = int_field(data, 'state', 0, max_state)
      unless model['stateTable'].include?(state)
        raise SnapshotError, "codingSM.state=#{state} does not exist in #{model['name']}"
      end
      byte_pos = int_field(data, 'bytePos', 0, 4)
      char_len = int_field(data, 'charLen', 0, 4)
      unless model['charLenTable'].include?(char_len)
        raise SnapshotError, "codingSM.charLen=#{char_len} invalid for #{model['name']}"
      end
      active = data.key?('active') ? bool_field(data, 'active') : true
      machine = CodingStateMachine.new(model)
      machine.restore_state(
        'state' => state, 'bytePos' => byte_pos,
        'charLen' => char_len, 'active' => active)
      machine
    end

    def self.snapshot_machine(machine)
      data = machine.snapshot_state
      data['active'] = !!data['active']
      data
    end

    # ----- per-prober snapshots -----

    def self.snapshot_prober(prober)
      expect_class(prober, CharSetProber, 'prober')
      name = prober.class.name.split('::').last
      data = {'type' => name, 'state' => prober.get_state,
              'active' => prober.active.nil? ? true : prober.active}
      # Inactive probers are never fed again, so a compact placeholder is
      # enough; this keeps snapshots cheap when most candidates are ruled out.
      unless data['active']
        data['inactive'] = true
        return data
      end
      case prober
      when CharSetGroupProber then snapshot_group(prober, data)
      when EscCharSetProber then snapshot_esc(prober, data)
      when UTF1632Prober then snapshot_utf1632(prober, data)
      when UTF8Prober then snapshot_utf8(prober, data)
      when MultiByteCharSetProber then snapshot_mbcs(prober, data)
      when SingleByteCharSetProber then snapshot_sbcs(prober, data)
      when Latin1Prober then snapshot_latin1(prober, data)
      when HebrewProber then snapshot_hebrew(prober, data)
      else raise SnapshotError, "cannot snapshot prober #{name}"
      end
      data
    end

    def self.snapshot_group(prober, data)
      data['probers'] = prober.probers.map do |child|
        child.nil? ? nil : snapshot_prober(child)
      end
      data['activeNum'] = prober.activeNum
      best = prober.bestGuessProber
      data['bestGuess'] = best.nil? ? nil : best.class.name.split('::').last
    end

    def self.snapshot_esc(prober, data)
      data['machines'] = prober.machines.map { |m| snapshot_machine(m) }
      data['activeSM'] = prober.activeSM
      data['detectedCharset'] = prober.detectedCharset
    end

    def self.snapshot_utf8(prober, data)
      data['codingSM'] = snapshot_machine(prober.codingSM)
      data['numMBChar'] = prober.numOfMBChar
    end

    def self.snapshot_utf1632(prober, data)
      data.merge!(prober.snapshot_counters)
    end

    def self.snapshot_mbcs(prober, data)
      data['codingSM'] = snapshot_machine(prober.codingSM)
      data['lastChar'] = encode_bytes(prober.lastChar)
      dist = prober.distributionAnalyzer
      if dist
        data['distribution'] = {
          'totalChars' => dist.totalChars,
          'freqChars' => dist.freqChars
        }
      end
      ctx = prober.contextAnalyzer
      if ctx
        data['context'] = {
          'totalRel' => ctx.totalRel,
          'relSample' => ctx.relSample,
          'needToSkipCharNum' => ctx.needToSkipCharNum,
          'lastCharOrder' => ctx.lastCharOrder,
          'done' => ctx.done?
        }
      end
    end

    def self.snapshot_sbcs(prober, data)
      data['model'] = prober.model_name
      data['reversed'] = prober.reversed
      data['lastOrder'] = prober.lastOrder
      data['seqCounters'] = prober.seqCounters
      data['totalSeqs'] = prober.totalSeqs
      data['totalChar'] = prober.totalChar
      data['freqChar'] = prober.freqChar
      data['nameProber'] = prober.nameProber.nil? ? nil :
        prober.nameProber.class.name.split('::').last
    end

    def self.snapshot_latin1(prober, data)
      data['lastCharClass'] = prober.lastCharClass
      data['freqCounter'] = prober.freqCounter
    end

    def self.snapshot_hebrew(prober, data)
      data['finalCharLogicalScore'] = prober.finalCharLogicalScore
      data['finalCharVisualScore'] = prober.finalCharVisualScore
      data['prev'] = encode_bytes(prober.prev)
      data['beforePrev'] = encode_bytes(prober.beforePrev)
    end

  end
end
