######################## BEGIN LICENSE BLOCK ########################
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
  # Offline trainer for single-byte sequence models consumed by
  # SingleByteCharSetProber. Feed it raw byte documents in the target
  # encoding, then build a model hash with the same layout as the
  # bundled lang*model.rb tables, plus a format version.
  #
  # Handling rules:
  # - document boundaries never leak: the last byte of one document is
  #   never paired with the first byte of the next document
  # - output depends only on the multiset of training bytes and pairs,
  #   so document order and feed chunk sizes do not change the model
  # - letter bytes ranked below the top sample_size become rare orders
  #   (sample_size...SYMBOL_CAT_ORDER): counted as totalChar but never
  #   as freqChar or sequence members
  # - bytes that never appeared in training map to CONTROL_ORDER and
  #   are ignored by the prober, like control bytes
  # - sequences never observed get precedence category 0
  class SBCSModelTrainer
    MODEL_VERSION = 1

    CONTROL_ORDER = 255
    LINE_BREAK_ORDER = 254
    SYMBOL_ORDER = 253
    DIGIT_ORDER = 252

    DEFAULT_SEQUENCES_PER_CATEGORY = 512

    MODEL_KEYS = %w[
      version charToOrderMap precedenceMatrix
      mTypicalPositiveRatio keepEnglishLetter charsetName
    ].freeze

    attr_reader :char_counts, :pair_counts, :sample_size, :sequences_per_category

    def initialize(sample_size: SAMPLE_SIZE, sequences_per_category: DEFAULT_SEQUENCES_PER_CATEGORY)
      @sample_size = sample_size
      @sequences_per_category = sequences_per_category
      @char_counts = Hash.new(0)
      @pair_counts = Hash.new(0)
      @last_byte = nil
    end

    def feed(chunk)
      raise ArgumentError, "training data must be a String, got #{chunk.class}" unless chunk.is_a?(String)
      chunk = chunk.b
      chunk.each_byte do |byte|
        @char_counts[byte] += 1
        @pair_counts[[@last_byte, byte]] += 1 if @last_byte
        @last_byte = byte
      end
      self
    end

    def end_document
      @last_byte = nil
      self
    end

    def add_document(document)
      feed(document)
      end_document
    end

    def build_model(charset_name:, keep_english_letter: false)
      order_map = build_char_to_order_map
      matrix, positive_ratio = build_precedence_matrix(order_map)
      {
        'version' => MODEL_VERSION,
        'charToOrderMap' => order_map.freeze,
        'precedenceMatrix' => matrix.freeze,
        'mTypicalPositiveRatio' => positive_ratio,
        'keepEnglishLetter' => keep_english_letter,
        'charsetName' => charset_name
      }.freeze
    end

    def self.save_model(model, path)
      File.binwrite(path, Marshal.dump(model))
      model
    end

    def self.load_model(path)
      model = Marshal.load(File.binread(path))
      unless model.is_a?(Hash) && (MODEL_KEYS - model.keys).empty?
        raise ArgumentError, "#{path} does not contain a trained SBCS model"
      end
      unless model['version'] == MODEL_VERSION
        raise ArgumentError, "unsupported SBCS model version #{model['version'].inspect} (expected #{MODEL_VERSION})"
      end
      model
    end

    private

    def letter_byte?(byte)
      (0x41..0x5A).cover?(byte) || (0x61..0x7A).cover?(byte) || byte >= 0x80
    end

    def build_char_to_order_map
      map = Array.new(256, CONTROL_ORDER)
      256.times do |byte|
        map[byte] =
          if byte == 0x0A || byte == 0x0D
            LINE_BREAK_ORDER
          elsif (0x30..0x39).cover?(byte)
            DIGIT_ORDER
          elsif letter_byte?(byte)
            CONTROL_ORDER
          elsif (0x20..0x7E).cover?(byte)
            SYMBOL_ORDER
          else
            CONTROL_ORDER
          end
      end
      ranked_letters = @char_counts.keys
        .select { |byte| letter_byte?(byte) }
        .sort_by { |byte| [-@char_counts[byte], byte] }
      ranked_letters.each_with_index do |byte, rank|
        map[byte] = rank if rank < SYMBOL_CAT_ORDER
      end
      map
    end

    def build_precedence_matrix(order_map)
      matrix = [0] * (@sample_size * @sample_size)
      counted = {}
      total = 0
      @pair_counts.each do |(prev_byte, cur_byte), count|
        prev_order = order_map[prev_byte]
        cur_order = order_map[cur_byte]
        next unless prev_order < @sample_size && cur_order < @sample_size
        counted[[prev_order, cur_order]] = count
        total += count
      end
      ranked = counted.sort_by { |(prev_order, cur_order), count| [-count, prev_order, cur_order] }
      ranked.each_with_index do |((prev_order, cur_order), _), rank|
        category = POSITIVE_CAT - (rank / @sequences_per_category)
        matrix[(prev_order * @sample_size) + cur_order] = category if category > 0
      end
      positive_count = ranked.first(@sequences_per_category).sum { |_, count| count }
      ratio = total.zero? ? 0.0 : positive_count.to_f / total
      [matrix, ratio]
    end
  end
end
