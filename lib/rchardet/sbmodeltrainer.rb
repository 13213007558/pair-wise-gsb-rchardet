######################## BEGIN LICENSE BLOCK ########################
#
# Offline trainer for data-driven single-byte sequence models used by
# SingleByteCharSetProber. The generated model hash has the same shape as the
# fixed tables in lang*model.rb, plus versioning and training metadata.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
######################### END LICENSE BLOCK #########################

require 'json'
require 'rchardet/constants'
require 'rchardet/charsetprober'
require 'rchardet/sbcharsetprober'

module CharDet
  # Version of the on-disk model format produced by this trainer.
  MODEL_FORMAT_VERSION = 1

  # Builds a single-byte language model (charToOrderMap + precedenceMatrix)
  # from annotated plain text. Every model parameter is either derived from
  # the observed counts or supplied explicitly; nothing is random.
  #
  # Character mapping policy (order values, mirroring the fixed tables):
  #   * frequent letter bytes are ranked by (count desc, byte asc) and given
  #     the first sample_size orders (0..sample_size-1),
  #   * bytes seen fewer than rare_min_count times are "rare" (rare_order),
  #   * candidate bytes never seen are "unseen" (unseen_order),
  #   * CR/LF, digits, punctuation and control bytes get explicit fixed
  #     categories (newline_order, digit_order, symbol_order, control_order).
  #
  # Adjacent-sequence policy:
  #   * byte pairs are only counted inside a document; end_document breaks the
  #     chain so the tail of one document never pairs with the next head,
  #   * pairs are ranked by (count desc, pair-index asc) and classified with
  #     the explicit positive/likely rank cutoffs:
  #       rank <  positive_cutoff -> 3 (positive),
  #       rank <  likely_cutoff   -> 2 (likely),
  #       rank <  matrix_size     -> 1 (neutral),
  #       never observed          -> 0 (negative).
  class SingleByteModelTrainer
    attr_reader :parameters, :statistics

    def initialize(charset_name:, model_version:, language: nil,
                   sample_size: SAMPLE_SIZE,
                   positive_rank_cutoff: 512,
                   likely_rank_cutoff: 1024,
                   keep_english_letters: false,
                   rare_min_count: 5,
                   high_byte_start: 0x80,
                   rare_order: 253,
                   unseen_order: 255,
                   newline_order: 254,
                   digit_order: 252,
                   symbol_order: 253,
                   control_order: 255,
                   typical_positive_ratio: nil)
      unless charset_name.is_a?(String) && !charset_name.empty?
        raise ArgumentError, "charset_name must be a non-empty String"
      end
      unless model_version.is_a?(String) && !model_version.empty?
        raise ArgumentError, "model_version must be a non-empty String"
      end
      unless sample_size.is_a?(Integer) && sample_size > 0 && sample_size <= 256
        raise ArgumentError, "sample_size must be an Integer in 1..256"
      end
      unless positive_rank_cutoff.is_a?(Integer) && likely_rank_cutoff.is_a?(Integer) &&
             positive_rank_cutoff >= 0 && likely_rank_cutoff >= positive_rank_cutoff
        raise ArgumentError, "rank cutoffs must be non-negative integers with positive <= likely"
      end
      unless rare_min_count.is_a?(Integer) && rare_min_count >= 1
        raise ArgumentError, "rare_min_count must be a positive Integer"
      end
      unless high_byte_start.is_a?(Integer) && high_byte_start.between?(0, 255)
        raise ArgumentError, "high_byte_start must be in 0..255"
      end
      orders = [rare_order, unseen_order, newline_order, digit_order, symbol_order, control_order]
      unless orders.all? { |order| order.between?(0, 255) }
        raise ArgumentError, "fixed category orders must be in 0..255"
      end
      unless typical_positive_ratio.nil? ||
             (typical_positive_ratio.is_a?(Numeric) && typical_positive_ratio > 0 && typical_positive_ratio <= 1)
        raise ArgumentError, "typical_positive_ratio must be nil or in (0, 1]"
      end

      @parameters = {
        'sampleSize' => sample_size,
        'positiveRankCutoff' => positive_rank_cutoff,
        'likelyRankCutoff' => likely_rank_cutoff,
        'keepEnglishLetters' => keep_english_letters,
        'rareMinCount' => rare_min_count,
        'highByteStart' => high_byte_start,
        'rareOrder' => rare_order,
        'unseenOrder' => unseen_order,
        'newlineOrder' => newline_order,
        'digitOrder' => digit_order,
        'symbolOrder' => symbol_order,
        'controlOrder' => control_order,
      }.freeze
      @explicit_ratio = typical_positive_ratio
      @charset_name = charset_name
      @model_version = model_version
      @language = language

      @unigram_counts = Array.new(256, 0)
      @pair_counts = Hash.new(0)
      @document_count = 0
      @total_bytes = 0
      @last_byte = nil
      @document_open = false
      @finalized = false
    end

    # Streams one chunk of a document. May be called any number of times;
    # chunk boundaries never affect the accumulated pairs.
    def feed_chunk(chunk)
      unless chunk.is_a?(String)
        raise ArgumentError, "document chunks must be Strings (binary), got #{chunk.class}"
      end
      raise ArgumentError, "trainer already finalized" if @finalized

      @document_open = true
      chunk.each_byte do |byte|
        @total_bytes += 1
        @unigram_counts[byte] += 1
        if !@last_byte.nil? && letter_candidate?(@last_byte) && letter_candidate?(byte)
          @pair_counts[(@last_byte << 8) | byte] += 1
        end
        @last_byte = byte
      end
      self
    end

    # Closes the current document. The chain is reset here, so the final byte
    # of this document can never form a pair with the first byte of the next.
    def end_document
      if @document_open || !@last_byte.nil?
        @document_count += 1
      end
      @document_open = false
      @last_byte = nil
      self
    end

    # Convenience wrapper for a complete, already-materialized document.
    def add_document(document)
      feed_chunk(document)
      end_document
    end

    # Computes and returns the frozen model hash.
    def finalize
      raise ArgumentError, "trainer already finalized" if @finalized
      end_document
      raise ArgumentError, "cannot build a model from zero documents" if @document_count.zero?

      char_to_order_map = build_char_to_order_map
      precedence_matrix, ratio, seq_stats = build_precedence_matrix(char_to_order_map)

      ratio = @explicit_ratio unless @explicit_ratio.nil?
      if ratio.nil? || ratio <= 0
        raise ArgumentError, "no positive sequences observed; supply an explicit typical_positive_ratio"
      end

      @statistics = {
        'documents' => @document_count,
        'totalBytes' => @total_bytes,
        'letterBytes' => char_to_order_map.count { |order| order < sample_size },
        'rareBytes' => char_to_order_map.count { |order| order == @parameters['rareOrder'] },
        'unseenCandidateBytes' => (0..255).count do |byte|
          letter_candidate?(byte) && @unigram_counts[byte].zero?
        end,
        'totalPairs' => seq_stats['totalPairs'],
        'observedPairs' => seq_stats['observedPairs'],
        'sequenceCategoryCounts' => seq_stats['categoryCounts'],
      }.freeze

      @model = {
        'charToOrderMap' => char_to_order_map.freeze,
        'precedenceMatrix' => precedence_matrix.freeze,
        'mTypicalPositiveRatio' => ratio,
        'keepEnglishLetter' => @parameters['keepEnglishLetters'],
        'charsetName' => @charset_name,
        'language' => @language,
        'modelVersion' => @model_version,
        'formatVersion' => MODEL_FORMAT_VERSION,
        'sampleSize' => sample_size,
        'parameters' => @parameters,
        'trainStats' => @statistics,
      }.freeze
      @finalized = true
      @model
    end
    alias train finalize

    def to_json
      raise ArgumentError, "call finalize before serializing" unless @finalized
      JSON.generate(@model)
    end

    # Trains in one call from an enumerable of documents. Document order does
    # not matter: ties are broken deterministically before emission.
    def self.train(documents, **options)
      trainer = new(**options)
      documents.each { |document| trainer.add_document(document) }
      trainer.finalize
    end

    def self.train_json(documents, **options)
      JSON.generate(train(documents, **options))
    end

    private

    def sample_size
      @parameters['sampleSize']
    end

    def letter_candidate?(byte)
      if @parameters['keepEnglishLetters']
        return true if byte.between?(0x41, 0x5A) || byte.between?(0x61, 0x7A)
      end
      byte >= @parameters['highByteStart']
    end

    def build_char_to_order_map
      map = (0..255).map do |byte|
        if byte == 0x0A || byte == 0x0D
          @parameters['newlineOrder']
        elsif byte.between?(0x30, 0x39)
          @parameters['digitOrder']
        elsif byte.between?(0x20, 0x7E)
          @parameters['symbolOrder']
        else
          @parameters['controlOrder']
        end
      end

      # ASCII letters only participate in ranking when explicitly kept.
      unless @parameters['keepEnglishLetters']
        (0x41..0x5A).each { |byte| map[byte] = @parameters['controlOrder'] }
        (0x61..0x7A).each { |byte| map[byte] = @parameters['controlOrder'] }
      end

      # Frequency ranking with a deterministic byte-ascending tie breaker.
      # Rare bytes are excluded first, so they can never occupy a sample slot.
      ranked = (0..255).select do |byte|
        letter_candidate?(byte) && @unigram_counts[byte] >= @parameters['rareMinCount']
      end
      ranked.sort_by! { |byte| [-@unigram_counts[byte], byte] }

      ranked.each_with_index do |byte, index|
        map[byte] =
          if index < sample_size
            index
          else
            @parameters['symbolOrder']
          end
      end

      # Candidate bytes that never occurred receive the explicit unseen order.
      (0..255).each do |byte|
        if letter_candidate?(byte) && @unigram_counts[byte].zero?
          map[byte] = @parameters['unseenOrder']
        end
      end

      # Seen-but-rare candidates get the explicit rare category; they are
      # handled after the unseen pass, which only touches zero-count bytes.
      (0..255).each do |byte|
        seen_rare = letter_candidate?(byte) &&
                    @unigram_counts[byte] > 0 &&
                    @unigram_counts[byte] < @parameters['rareMinCount']
        map[byte] = @parameters['rareOrder'] if seen_rare && map[byte] >= SYMBOL_CAT_ORDER
      end

      map
    end

    def build_precedence_matrix(char_to_order_map)
      matrix_size = sample_size * sample_size
      matrix = Array.new(matrix_size, 0)
      order_pair_counts = Hash.new(0)

      @pair_counts.each do |packed_pair, count|
        prev_byte = (packed_pair >> 8) & 0xFF
        byte = packed_pair & 0xFF
        prev_order = char_to_order_map[prev_byte]
        order = char_to_order_map[byte]
        next unless prev_order < sample_size && order < sample_size

        index = (prev_order * sample_size) + order
        order_pair_counts[index] += count
      end

      observed_indices = order_pair_counts.keys
      observed_indices.sort_by! { |index| [-order_pair_counts[index], index] }

      positive_cutoff = [@parameters['positiveRankCutoff'], matrix_size].min
      likely_cutoff = [@parameters['likelyRankCutoff'], matrix_size].min
      category_counts = [0, 0, 0, 0]
      total_pairs = 0
      positive_pairs = 0

      observed_indices.each_with_index do |index, rank|
        category =
          if rank < positive_cutoff
            3
          elsif rank < likely_cutoff
            2
          else
            1
          end
        matrix[index] = category
        count = order_pair_counts[index]
        category_counts[category] += count
        total_pairs += count
        positive_pairs += count if category == 3
      end

      ratio = total_pairs.zero? ? nil : positive_pairs.to_f / total_pairs
      stats = {
        'totalPairs' => total_pairs,
        'observedPairs' => observed_indices.length,
        'categoryCounts' => category_counts,
      }
      [matrix, ratio, stats]
    end
  end
end
