# encoding: US-ASCII
######################## BEGIN LICENSE BLOCK ########################
# Portable, serializable detection state for UniversalDetector.
#
# A snapshot is a plain-data (JSON compatible) Hash. It never contains
# the raw input stream: the largest carried field is a few bytes of an
# unfinished multibyte character or escape sequence. Marshal is not used.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
######################### END LICENSE BLOCK #########################

require 'json'
require 'zlib'

module CharDet
  # Raised when a snapshot cannot be decoded, fails validation, or was
  # produced by an incompatible snapshot format or detector model.
  class SnapshotError < StandardError; end

  module Snapshot
    # Version of the snapshot *on the wire* format produced by this code.
    FORMAT_VERSION = 1

    BINARY_MARKER = "__rchardet_binary__"

    SM_MODEL_NAMES = %w[
      Big5 EUC-JP EUC-KR x-euc-tw GB18030 Shift_JIS UTF-8
      HZ-GB-2312 ISO-2022-CN ISO-2022-JP ISO-2022-KR
    ].freeze

    SBCS_MODEL_NAMES = %w[
      windows-1251 KOI8-R ISO-8859-5 ISO-8859-5 MacCyrillic IBM866 IBM855
      ISO-8859-7 windows-1253 ISO-8859-5 windows-1251 ISO-8859-2
      windows-1250 TIS-620 windows-1255
    ].freeze

    # Mark a binary string so JSON.dump encodes it losslessly.
    def self.binary(str)
      str = str.to_s.dup.force_encoding(Encoding::BINARY)
      str.instance_variable_set(:@__rchardet_binary__, true)
      str
    end

    def self.binary?(obj)
      obj.instance_variable_get(:@__rchardet_binary__) == true
    end

    # Serialize a snapshot Hash to a JSON String. Binary fields are carried
    # as base64; no Ruby objects or Marshal data are emitted.
    def self.dump(snapshot)
      raise SnapshotError, "snapshot must be a Hash" unless snapshot.is_a?(Hash)
      JSON.generate(encode(snapshot))
    end

    # Parse JSON produced by dump, restoring binary fields. The result is a
    # plain-data Hash suitable for UniversalDetector.restore_snapshot.
    def self.load(json)
      data =
        begin
          JSON.parse(json)
        rescue JSON::ParserError => e
          raise SnapshotError, "snapshot is not valid JSON: #{e.message}"
        end
      raise SnapshotError, "snapshot must be a JSON object" unless data.is_a?(Hash)
      decode(data)
    end

    def self.model_id
      @model_id ||= compute_model_id
    end

    # ---- Validation helpers ---------------------------------------------

    def self.assert!(condition, message)
      raise SnapshotError, message unless condition
    end

    def self.hash_field(hash, key)
      value = hash[key]
      assert!(value.is_a?(Hash), "field #{key.inspect} must be an object")
      value
    end

    def self.string_field(hash, key, allowed)
      value = hash[key]
      assert!(value.is_a?(String) && allowed.include?(value),
        "field #{key.inspect} must be one of: #{allowed.join(', ')}")
      value
    end

    def self.bool_field(hash, key)
      value = hash[key]
      assert!(value == true || value == false,
        "field #{key.inspect} must be true or false")
      value
    end

    def self.int_field(hash, key, min, max)
      value = hash[key]
      assert!(value.is_a?(Integer) && !value.is_a?(Float) && value >= min && value <= max,
        "field #{key.inspect} must be an Integer in #{min}..#{max}")
      value
    end

    def self.float_field(hash, key, min, max)
      value = hash[key]
      assert!(value.is_a?(Numeric) && value >= min && value <= max,
        "field #{key.inspect} must be a Number in #{min}..#{max}")
      value.to_f
    end

    def self.binary_field(hash, key, max_bytes)
      value = hash[key]
      assert!(value.is_a?(String) && value.encoding == Encoding::BINARY && value.bytesize <= max_bytes,
        "field #{key.inspect} must be a binary String of at most #{max_bytes} bytes")
      value
    end

    def self.int_array(hash, key, length, min, max)
      value = hash[key]
      assert!(value.is_a?(Array) && value.length == length,
        "field #{key.inspect} must be an Array of #{length} Integers")
      value.each_with_index do |item, idx|
        assert!(item.is_a?(Integer) && !item.is_a?(Float) && item >= min && item <= max,
          "field #{key.inspect}[#{idx}] must be an Integer in #{min}..#{max}")
      end
      value
    end

    def self.check_version_and_model(snapshot)
      assert!(snapshot.is_a?(Hash), "snapshot must be a Hash")
      assert!(snapshot["format_version"] == FORMAT_VERSION,
        "unsupported snapshot format version #{snapshot["format_version"].inspect}; expected #{FORMAT_VERSION}")
      assert!(snapshot["rchardet_version"] == CharDet::VERSION,
        "snapshot rchardet_version #{snapshot["rchardet_version"].inspect} does not match #{CharDet::VERSION.inspect}")
      assert!(snapshot["model_id"].is_a?(String),
        "field model_id must be a String")
      assert!(snapshot["model_id"] == model_id,
        "snapshot model_id does not match the detection models in this process")
    end

    # ---- Encoding / decoding ---------------------------------------------

    def self.encode(obj)
      case obj
      when Hash
        encoded = {}
        obj.each { |k, v| encoded[k.to_s] = encode(v) }
        encoded
      when Array
        obj.map { |item| encode(item) }
      when String
        if binary?(obj)
          {BINARY_MARKER => [obj].pack("m0")}
        else
          obj.encode(Encoding::UTF_8)
        end
      when nil, true, false, Integer, Float
        obj
      else
        raise SnapshotError, "cannot serialize #{obj.class} into a snapshot"
      end
    end

    def self.decode(obj)
      case obj
      when Hash
        if obj.key?(BINARY_MARKER)
          value = obj[BINARY_MARKER]
          assert!(value.is_a?(String), "binary marker must wrap a base64 String")
          begin
            value.unpack1("m0").force_encoding(Encoding::BINARY)
          rescue ArgumentError => e
            raise SnapshotError, "invalid base64 binary field: #{e.message}"
          end
        else
          obj.each_with_object({}) { |(k, v), acc| acc[k] = decode(v) }
        end
      when Array
        obj.map { |item| decode(item) }
      else
        obj
      end
    end

    # ---- Model fingerprint -----------------------------------------------

    FINGERPRINT_MODELS = [
      :Big5SMModel, :EUCJPSMModel, :EUCKRSMModel, :EUCTWSMModel,
      :GB18030SMModel, :SJISSMModel, :UCS2BESMModel, :UCS2LESMModel,
      :UTF8SMModel, :HZSMModel, :ISO2022CNSMModel, :ISO2022JPSMModel,
      :ISO2022KRSMModel,
      :Win1251CyrillicModel, :Koi8rModel, :Latin5CyrillicModel,
      :MacCyrillicModel, :Ibm866Model, :Ibm855Model,
      :Latin7GreekModel, :Win1253GreekModel, :Latin5BulgarianModel,
      :Win1251BulgarianModel, :Latin2HungarianModel,
      :Win1250HungarianModel, :TIS620ThaiModel, :Win1255HebrewModel,
      :Big5CharToFreqOrder, :EUCKRCharToFreqOrder, :EUCTWCharToFreqOrder,
      :GB18030CharToFreqOrder, :JISCharToFreqOrder, :JP2_CHAR_CONTEXT,
      :Latin1_CharToClass, :Latin1ClassModel
    ].freeze

    def self.compute_model_id
      parts = FINGERPRINT_MODELS.map do |const_name|
        model = CharDet.const_get(const_name)
        digest_value(model)
      end
      digest = Zlib.crc32(parts.join("\u0000"))
      "crc32-#{digest.to_s(16).rjust(8, '0')}"
    end

    def self.digest_value(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.map { |k| "#{k}=#{digest_value(value[k])}" }.join(",")
      when Array
        "[#{value.map { |item| digest_value(item) }.join(",")}]"
      when String
        "s#{value.bytes.map(&:to_s).join('.')}"
      when Numeric, nil, true, false
        value.inspect
      else
        value.class.to_s
      end
    end
  end
end
