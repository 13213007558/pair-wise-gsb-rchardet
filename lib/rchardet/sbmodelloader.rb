######################## BEGIN LICENSE BLOCK ########################
#
# Loader for data-driven single-byte sequence models trained offline with
# CharDet::SingleByteModelTrainer. A loaded model can be handed directly to
# CharDet::SingleByteCharSetProber, just like the fixed Win1253GreekModel.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
######################### END LICENSE BLOCK #########################

require 'json'
require 'rchardet/charsetprober'
require 'rchardet/sbcharsetprober'
require 'rchardet/sbmodeltrainer'

module CharDet
  class ModelLoadError < StandardError; end

  module SingleByteModelLoader
    # Loads a model previously produced by SingleByteModelTrainer#to_json.
    # Raises ModelLoadError on malformed, incomplete or incompatible data.
    def self.load_json(json_string)
      raise ModelLoadError, "model data must be a String" unless json_string.is_a?(String)

      data =
        begin
          JSON.parse(json_string)
        rescue JSON::ParserError => error
          raise ModelLoadError, "invalid model JSON: #{error.message}"
        end
      from_hash(data)
    end

    def self.load_file(path)
      load_json(File.binread(path))
    end

    def self.from_hash(data)
      raise ModelLoadError, "model root must be a Hash" unless data.is_a?(Hash)
      unless data['formatVersion'] == MODEL_FORMAT_VERSION
        raise ModelLoadError,
              "unsupported formatVersion #{data['formatVersion'].inspect}, expected #{MODEL_FORMAT_VERSION}"
      end

      sample_size = integer_field(data, 'sampleSize')
      unless sample_size.between?(1, 256)
        raise ModelLoadError, "sampleSize must be in 1..256"
      end

      char_map = array_field(data, 'charToOrderMap', 256)
      unless char_map.all? { |order| order.is_a?(Integer) && order.between?(0, 255) }
        raise ModelLoadError, "charToOrderMap entries must be integers in 0..255"
      end

      matrix_size = sample_size * sample_size
      matrix = array_field(data, 'precedenceMatrix', matrix_size)
      unless matrix.all? { |category| category.is_a?(Integer) && category.between?(0, 3) }
        raise ModelLoadError, "precedenceMatrix entries must be sequence categories in 0..3"
      end

      ratio = numeric_field(data, 'mTypicalPositiveRatio')
      unless ratio > 0 && ratio <= 1
        raise ModelLoadError, "mTypicalPositiveRatio must be in (0, 1]"
      end

      unless data['keepEnglishLetter'] == true || data['keepEnglishLetter'] == false
        raise ModelLoadError, "keepEnglishLetter must be a boolean"
      end
      unless data['charsetName'].is_a?(String) && !data['charsetName'].empty?
        raise ModelLoadError, "charsetName must be a non-empty String"
      end
      unless data['modelVersion'].is_a?(String) && !data['modelVersion'].empty?
        raise ModelLoadError, "modelVersion must be a non-empty String"
      end

      model = {
        'charToOrderMap' => char_map.freeze,
        'precedenceMatrix' => matrix.freeze,
        'mTypicalPositiveRatio' => ratio,
        'keepEnglishLetter' => data['keepEnglishLetter'],
        'charsetName' => data['charsetName'],
        'language' => data['language'],
        'modelVersion' => data['modelVersion'],
        'formatVersion' => data['formatVersion'],
        'sampleSize' => sample_size,
        'parameters' => data['parameters'].is_a?(Hash) ? deep_freeze(data['parameters']) : nil,
        'trainStats' => data['trainStats'].is_a?(Hash) ? deep_freeze(data['trainStats']) : nil,
      }.freeze

      # Ensure a model produced with a non-standard sample_size is usable:
      # the prober derives its limits from SAMPLE_SIZE, so reject mismatches
      # loudly rather than silently misclassifying pairs.
      unless sample_size == SAMPLE_SIZE
        raise ModelLoadError,
              "sampleSize #{sample_size} is incompatible with this prober (expects #{SAMPLE_SIZE})"
      end

      model
    end

    class << self
      private

      def integer_field(data, name)
        value = data[name]
        unless value.is_a?(Integer)
          raise ModelLoadError, "#{name} must be an integer"
        end
        value
      end

      def numeric_field(data, name)
        value = data[name]
        unless value.is_a?(Numeric)
          raise ModelLoadError, "#{name} must be a number"
        end
        value
      end

      def array_field(data, name, expected_size)
        value = data[name]
        unless value.is_a?(Array) && value.length == expected_size
          raise ModelLoadError, "#{name} must be an Array of #{expected_size} entries"
        end
        value
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
