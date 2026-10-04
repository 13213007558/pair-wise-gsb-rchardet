# frozen_string_literal: true

module CharDet
  class SegmentDetector
    MODEL_SPECS = {
      "UTF-8" => [UTF8SMModel, UTF8Prober, false],
      "GB18030" => [GB18030SMModel, GB18030Prober, false],
      "Big5" => [Big5SMModel, Big5Prober, false],
      "EUC-JP" => [EUCJPSMModel, EUCJPProber, false],
      "EUC-KR" => [EUCKRSMModel, EUCKRProber, false],
      "EUC-TW" => [EUCTWSMModel, EUCTWProber, false],
      "SHIFT_JIS" => [SJISSMModel, SJISProber, false],
      "UTF-16BE" => [UCS2BESMModel, nil, false],
      "UTF-16LE" => [UCS2LESMModel, nil, false],
      "HZ-GB-2312" => [HZSMModel, nil, true],
      "ISO-2022-CN" => [ISO2022CNSMModel, nil, true],
      "ISO-2022-JP" => [ISO2022JPSMModel, nil, true],
      "ISO-2022-KR" => [ISO2022KRSMModel, nil, true]
    }.freeze

    ENCODING_ALIASES = {
      "UTF8" => "UTF-8",
      "UTF_8" => "UTF-8",
      "GB" => "GB18030",
      "GBK" => "GB18030",
      "GB_18030" => "GB18030",
      "SHIFT-JIS" => "SHIFT_JIS"
    }.freeze

    MAX_CHARACTER_BYTES = {
      "UTF-8" => 6,
      "GB18030" => 4,
      "Big5" => 2,
      "EUC-JP" => 3,
      "EUC-KR" => 2,
      "EUC-TW" => 3,
      "SHIFT_JIS" => 2,
      "UTF-16BE" => 2,
      "UTF-16LE" => 2,
      "HZ-GB-2312" => 64,
      "ISO-2022-CN" => 64,
      "ISO-2022-JP" => 64,
      "ISO-2022-KR" => 64
    }.freeze

    Path = Struct.new(:cost, :score, :segments, :rank, :encoding, :segment_start, :back_position, :back_key, :initial_score, keyword_init: true) do
      def key
        [encoding, segment_start, back_position]
      end

      def better?(other)
        ([cost, score, segments, rank, initial_score] <=> [other.cost, other.score, other.segments, other.rank, other.initial_score]) == -1
      end
    end

    def initialize(allowed_encodings:, minimum_segment_length: 8, switch_penalty: 1.0)
      @minimum_segment_length = Integer(minimum_segment_length)
      @switch_penalty = Float(switch_penalty)
      raise ArgumentError, "minimum_segment_length must be positive" if @minimum_segment_length < 1
      raise ArgumentError, "switch_penalty cannot be negative" if @switch_penalty.negative?

      @allowed_encodings = normalize_encodings(allowed_encodings)
      reset
    end

    def reset
      @buffer = +""
      @result = nil
      self
    end

    def feed(data)
      @buffer << data.to_s.dup.force_encoding(Encoding::BINARY)
      @result = nil
      self
    end

    def close
      @result = detect(@buffer)
    end

    attr_reader :result

    private

    def normalize_encodings(encodings)
      raw_names = Array(encodings).map(&:to_s)
      raise ArgumentError, "allowed_encodings cannot be empty" if raw_names.empty?

      raw_names.map do |name|
        canonical = ENCODING_ALIASES.fetch(name.upcase, name.upcase.tr("_", "-"))
        canonical = "SHIFT_JIS" if canonical == "SHIFT-JIS"
        unless MODEL_SPECS.key?(canonical)
          raise ArgumentError, "unsupported allowed encoding: #{name}"
        end
        canonical
      end.uniq
    end

    def detect(data)
      @buffer = data.dup.force_encoding(Encoding::BINARY)
      ascii_runs = build_ascii_runs(@buffer)
      scan = scan_encoded_chars
      dp = Array.new(@buffer.bytesize + 1) { {} }
      dp[0][:start] = Path.new(
        cost: 0.0, score: 0.0, segments: 0, rank: -1, encoding: :start,
        segment_start: 0, back_position: nil, back_key: nil, initial_score: 0.0
      )

      (1..@buffer.bytesize).each do |finish|
        add_unknown(dp, finish)
        add_ascii(dp, finish, ascii_runs)
        @allowed_encodings.each_with_index do |encoding, rank|
          add_encoding(dp, finish, encoding, rank, ascii_runs, scan.fetch(encoding))
        end
      end

      final_path = dp.last.values.reject { |path| path.encoding == :start }.min_by { |path| [path.cost, path.score, path.segments, path.rank] }
      return empty_result if @buffer.empty?
      raise "unreachable: no segmentation found" unless final_path
      build_result(reconstruct(dp, final_path))
    end

    def empty_result
      {"encoding" => nil, "confidence" => 0.0, "segments" => [], "total_cost" => 0.0}
    end

    def build_ascii_runs(data)
      runs = []
      start = nil
      data.each_byte.with_index do |byte, index|
        if byte < 0x80
          start ||= index
        elsif start
          runs << [start, index]
          start = nil
        end
      end
      runs << [start, data.bytesize] if start
      runs
    end

    def scan_encoded_chars
      @allowed_encodings.to_h do |encoding|
        model, prober_class, stateful = MODEL_SPECS.fetch(encoding)
        active = {0 => new_scan_state(encoding)}
        characters = Hash.new { |hash, key| hash[key] = [] }

        @buffer.each_byte.with_index do |byte, index|
          completed = []
          active.each do |start, state|
            machine_state = state[:machine].next_state(byte.chr(Encoding::BINARY))
            if machine_state == EError
              state[:invalid] = true
              next
            end

            state[:state] = machine_state
            if machine_state == EStart
              state[:high] += 1 if byte >= 0x80
              state[:multibyte] += 1 if byte >= 0x80 && encoding == "UTF-8" && state[:machine].get_current_charlen >= 2
              if byte >= 0x80 && prober_class && state[:machine].get_current_charlen == 2
                state[:analyzer].feed(@buffer[index - 1, 2], 2) if index.positive? && state[:analyzer]
              end
            end
            next unless boundary_state?(machine_state, stateful)
            next unless stateful || byte >= 0x80
            next if stateful && !reset_escape_finish?(@buffer, start, index + 1)

            completed << {
              start: start,
              high: state[:high],
              total: state[:analyzer] ? state[:analyzer].instance_variable_get(:@totalChars) : 0,
              frequent: state[:analyzer] ? state[:analyzer].instance_variable_get(:@freqChars) : 0,
              multibyte: state[:multibyte]
            }
          end

          active.reject! { |_start, state| state[:invalid] }
          can_start = stateful || byte < 0x80 || active.key?(index)
          add_scan_start(active, index + 1, encoding, stateful) if can_start
          completed.each { |candidate| characters[index + 1] << candidate }
        end

        [encoding, {characters: characters, stateful: stateful}]
      end
    end

    def new_scan_state(encoding)
      model, _prober_class, _stateful = MODEL_SPECS.fetch(encoding)
      prober_class = MODEL_SPECS.fetch(encoding)[1]
      prober = prober_class&.new
      {
        machine: CodingStateMachine.new(model),
        analyzer: prober&.instance_variable_get(:@distributionAnalyzer),
        state: EStart,
        high: 0,
        multibyte: 0,
        invalid: false
      }
    end

    def add_scan_start(active, start, encoding, stateful)
      max_width = MAX_CHARACTER_BYTES.fetch(encoding)
      active[start] = new_scan_state(encoding)
      active.entries.sort_by(&:first).reverse.each do |candidate_start, state|
        next if candidate_start == start
        next if state[:state] == EStart && start - candidate_start < max_width
        break if start - candidate_start < max_width
        active.delete(candidate_start)
      end
    end

    def boundary_state?(state, stateful)
      stateful ? state == EItsMe : state == EStart
    end

    def reset_escape_finish?(buffer, start, finish)
      bytes = buffer.byteslice(start, finish - start)
      bytes.end_with?("\x1b(B".b) || bytes.end_with?("\x1b(J".b)
    end

    def utf8_confidence(multibyte_chars)
      return 1.0 - (0.99 * (ONE_CHAR_PROB**multibyte_chars)) if multibyte_chars < 6
      SURE_YES
    end

    def add_unknown(dp, finish)
      start = finish - 1
      dp[start].values.each do |predecessor|
        add_path(dp[finish], Path.new(
          cost: predecessor.cost + 1.0,
          score: predecessor.score,
          segments: predecessor.segments + 1,
          rank: @allowed_encodings.length + 2,
        encoding: :unknown,
        segment_start: start,
        back_position: start,
        back_key: back_key_for(predecessor),
        initial_score: predecessor.initial_score
        ))
      end
    end

    def add_ascii(dp, finish, runs)
      run = runs.find do |start, ending|
        ending == finish && finish - start >= @minimum_segment_length
      end
      return unless run

      start = run[0]
      predecessor = best_transition(dp[start], "ASCII")
      return unless predecessor

      add_path(dp[finish], Path.new(
        cost: predecessor.cost,
        score: predecessor.score,
        segments: predecessor.segments + 1,
        rank: -2,
        encoding: "ASCII",
        segment_start: start,
        back_position: start,
        back_key: back_key_for(predecessor),
        initial_score: predecessor.initial_score
      ))
    end

    def add_encoding(dp, finish, encoding, rank, runs, scan)
      stateful = scan[:stateful]
      scan[:characters].fetch(finish, []).each do |start|
        candidate_start = start.is_a?(Hash) ? start.fetch(:start) : start
        next if !stateful && contains_forced_ascii?(candidate_start, finish, runs)
        extend_or_start_encoding(dp, candidate_start, finish, encoding, rank, runs, stateful, start)
      end
    end

    def read_character(model, start, finish, stateful)
      machine = CodingStateMachine.new(model)
      state = nil
      (start...finish).each do |index|
        state = machine.next_state(@buffer.getbyte(index).chr(Encoding::BINARY))
        return false if state == EError
      end
      return state == EStart unless stateful
      bytes = @buffer.byteslice(start, finish - start)
      state == EItsMe && bytes.end_with?("\x1b(B".b) || bytes.end_with?("\x1b(J".b)
    end

    def contains_forced_ascii?(start, finish, runs)
      runs.any? do |run_start, run_finish|
        run_finish - run_start >= @minimum_segment_length &&
          start <= run_start && finish >= run_finish
      end
    end

    def extend_or_start_encoding(dp, start, finish, encoding, rank, runs, stateful, evidence = nil)
      same = dp[start].values.select do |path|
        path.encoding == encoding && path.back_position == start && path.segment_start == start
      end
      same.each do |path|
        score_delta = segment_score(path.segment_start, finish, encoding, stateful, evidence) - path.initial_score
        add_path(dp[finish], Path.new(
          cost: path.cost + score_delta,
          score: path.score + score_delta,
          segments: path.segments,
          rank: rank,
          encoding: encoding,
          segment_start: path.segment_start,
          back_position: start,
          back_key: path.back_key,
        initial_score: path.initial_score + score_delta
        ))
      end

      return if finish - start < @minimum_segment_length
      return unless segment_has_evidence?(start, finish, encoding, stateful)
      starters = dp[start].values.reject do |path|
        path.encoding == encoding || concrete_switch_inside_ascii?(path, start, runs)
      end
      predecessor = starters.min_by do |path|
        [transition_cost(path, encoding), path.cost, path.score, path.segments, path.rank]
      end
      return unless predecessor

      initial_score = segment_score(start, finish, encoding, stateful, evidence)
      add_path(dp[finish], Path.new(
        cost: predecessor.cost + transition_cost(predecessor, encoding) + initial_score,
        score: predecessor.score + initial_score,
        segments: predecessor.segments + 1,
        rank: rank,
        encoding: encoding,
        segment_start: start,
        back_position: start,
        back_key: back_key_for(predecessor),
        initial_score: initial_score
      ))
    end

    def back_key_for(path)
      [path.encoding, path.segment_start, path.back_position]
    end

    def segment_has_evidence?(start, finish, encoding, stateful)
      bytes = @buffer.byteslice(start, finish - start)
      return bytes.bytes.any? { |byte| byte >= 0x80 } unless stateful

      bytes.bytes.any? { |byte| byte == 0x1B }
    end

    def concrete_switch_inside_ascii?(path, position, runs)
      return false unless path.encoding.is_a?(String) && path.encoding != "ASCII"
      runs.any? { |start, finish| position > start && position < finish - 1 }
    end

    def segment_score(start, finish, encoding, stateful, evidence)
      return 1.0 if stateful && !evidence
      return 0.0 if stateful

      high_bytes = evidence ? evidence.fetch(:high, 0).to_f : @buffer.byteslice(start, finish - start).bytes.count { |byte| byte >= 0x80 }.to_f
      prober_class = MODEL_SPECS.fetch(encoding)[1]
      return high_bytes.to_f unless prober_class

      if encoding == "UTF-8"
        multibyte = evidence ? evidence.fetch(:multibyte, 0) : 0
        return 1.0 - utf8_confidence(multibyte) if multibyte.positive?
        return high_bytes
      end

      observed = evidence ? evidence.fetch(:total, 0).to_f * 2.0 : 0.0
      high_bytes - observed
    end

    def best_transition(paths, encoding)
      paths.values.min_by do |path|
        [transition_cost(path, encoding), path.cost, path.score, path.segments, path.rank]
      end
    end

    def transition_cost(path, encoding)
      return 0.0 if path.encoding == :start || path.encoding == encoding
      return 0.0 if path.encoding == :unknown && encoding.nil?
      @switch_penalty
    end

    def add_path(paths, candidate)
      existing = paths[candidate.key]
      if existing.nil? || candidate.better?(existing)
        paths[candidate.key] = candidate
      end
    end

    def reconstruct(dp, final_path)
      segments = []
      finish = @buffer.bytesize
      path = final_path

      while path && path.encoding != :start
        start = path.back_position
        segments << {
          start: start,
          finish: finish,
          encoding: path.encoding,
          score: path.score - ((dp[start][path.back_key] && dp[start][path.back_key].score) || 0.0)
        }
        path = dp[start][path.back_key]
        finish = start
      end

      segments.reverse
    end

    def build_result(raw_segments)
      switch_count = 0
      previous_concrete = nil
      segments = raw_segments.map do |segment|
        encoding = segment[:encoding]
        candidates = candidates_for(segment)
        concrete = concrete_encoding(encoding)

        if concrete
          switch_count += 1 if previous_concrete && previous_concrete != concrete
          previous_concrete = concrete
        elsif encoding != "ASCII"
          previous_concrete = nil
        end

        {
          "byte_start" => segment[:start],
          "byte_end" => segment[:finish],
          "encoding" => encoding == :unknown ? nil : encoding,
          "undecidable" => encoding == :unknown,
          "candidates" => candidates,
          "reason" => reason_for(segment, raw_segments)
        }
      end

      confidence = segments.filter_map do |segment|
        segment["candidates"].first&.fetch("confidence", nil)
      end.max.to_f

      {
        "encoding" => segments.reject { |segment| segment["undecidable"] }.first&.fetch("encoding"),
        "confidence" => confidence,
        "segments" => segments,
        "total_cost" => final_total_cost(segments, switch_count)
      }
    end

    def final_total_cost(segments, switch_count)
      undecidable = segments.count { |segment| segment["undecidable"] }.to_f
      score_total = segments.sum { |segment| segment[:score].to_f }
      undecidable + score_total + switch_count * @switch_penalty
    end

    def concrete_encoding(encoding)
      return nil unless encoding.is_a?(String)
      return nil if encoding == "ASCII"
      encoding
    end

    def candidates_for(segment)
      encoding = segment[:encoding]
      return [] if encoding == :unknown
      return [{"encoding" => "ASCII", "confidence" => 1.0}] if encoding == "ASCII"

      [{
        "encoding" => encoding,
        "confidence" => confidence_for(segment, encoding)
      }]
    end

    def confidence_for(segment, encoding)
      bytes = @buffer.byteslice(
        segment[:start], segment[:finish] - segment[:start]
      )
      prober_class = MODEL_SPECS.fetch(encoding)[1]
      if prober_class
        prober = prober_class.new
        prober.feed(bytes)
        confidence = prober.get_confidence.to_f
        return confidence unless confidence.zero?
      end
      MODEL_SPECS.fetch(encoding)[2] ? 0.99 : 0.5
    end

    def reason_for(segment, all_segments)
      index = all_segments.index(segment)
      return "initial segment" if index.zero?

      case segment[:encoding]
      when :unknown
        "no allowed encoding accepts this byte at a character boundary"
      when "ASCII"
        "common ASCII region kept intact"
      else
        "encoding boundary at a complete-character state"
      end
    end
  end

  def CharDet.detect_segments(data, allowed_encodings:, minimum_segment_length: 8, switch_penalty: 1.0)
    detector = SegmentDetector.new(
      allowed_encodings: allowed_encodings,
      minimum_segment_length: minimum_segment_length,
      switch_penalty: switch_penalty
    )
    detector.feed(data)
    detector.close
    detector.result
  end
end
