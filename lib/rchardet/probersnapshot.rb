# encoding: US-ASCII
######################## BEGIN LICENSE BLOCK ########################
# Snapshot/restore methods for the individual probers. All state loaded from
# a snapshot is validated against ranges and model identities before it is
# installed on freshly constructed prober objects.
######################### END LICENSE BLOCK #########################

module CharDet
  module StateSnapshot
    SBCS_MODELS = [
      Win1251CyrillicModel, Koi8rModel, Latin5CyrillicModel,
      MacCyrillicModel, Ibm866Model, Ibm855Model,
      Latin7GreekModel, Win1253GreekModel,
      Latin5BulgarianModel, Win1251BulgarianModel,
      Latin2HungarianModel, Win1250HungarianModel,
      TIS620ThaiModel, Win1255HebrewModel
    ].freeze
    SBCS_MODEL_REGISTRY =
      SBCS_MODELS.map { |m| [m['charsetName'], m] }.to_h.freeze

    MBCS_MODEL_NAMES = {
      'UTF8Prober' => 'UTF-8',
      'SJISProber' => 'Shift_JIS',
      'EUCJPProber' => 'EUC-JP',
      'GB18030Prober' => 'GB18030',
      'EUCKRProber' => 'EUC-KR',
      'Big5Prober' => 'Big5',
      'EUCTWProber' => 'x-euc-tw',
    }.freeze

    def self.check_state(value)
      int_field({'state' => value}, 'state', EDetecting, ENotMe)
    end

    def self.check_counter_array(value, length, field, max = (1 << 30))
      expect_class(value, Array, field)
      unless value.length == length
        raise SnapshotError, "#{field} must have #{length} entries"
      end
      value.each_with_index do |v, i|
        unless v.is_a?(Integer) && v >= 0 && v <= max
          raise SnapshotError, "#{field}[#{i}] invalid"
        end
      end
      value
    end

    def self.restore_common_state(prober, data)
      check_state(data['state'])
      prober.instance_variable_set(:@state, data['state'])
      prober.active = data.key?('active') ? bool_field(data, 'active') : true
    end

    def self.validate_esc(data)
      machines = expect_class(data['machines'], Array, 'EscCharSetProber.machines')
      unless machines.length == 4
        raise SnapshotError, 'EscCharSetProber must have 4 state machines'
      end
      expected = ['HZ-GB-2312', 'ISO-2022-CN', 'ISO-2022-JP', 'ISO-2022-KR']
      machines.each_with_index do |m, i|
        expect_class(m, Hash, "machines[#{i}]")
        unless m['model'] == expected[i]
          raise SnapshotError, "machine #{i} model mismatch"
        end
        restore_machine(m, EItsMe)
      end
      active = int_field(data, 'activeSM', 0, 4)
      actual = machines.count { |m| m['active'] }
      unless active == actual
        raise SnapshotError, 'activeSM does not match active machines'
      end
      detected = data['detectedCharset']
      unless detected.nil? || expected.include?(detected)
        raise SnapshotError, "unknown detectedCharset #{detected.inspect}"
      end
    end

    def self.restore_esc(prober, data)
      validate_esc(data)
      prober.instance_variable_set(:@codingSM,
        data['machines'].map { |m| restore_machine(m, EItsMe) })
      prober.instance_variable_set(:@activeSM, data['activeSM'])
      prober.instance_variable_set(:@detectedCharset, data['detectedCharset'])
      prober.instance_variable_set(:@state, data['state'])
    end

    def self.restore_utf8(prober, data)
      sm = expect_class(data['codingSM'], Hash, 'UTF8Prober.codingSM')
      unless sm['model'] == 'UTF-8'
        raise SnapshotError, 'UTF8Prober model mismatch'
      end
      machine = restore_machine(sm, EItsMe)
      num = int_field(data, 'numMBChar', 0, (1 << 30))
      prober.instance_variable_set(:@codingSM, machine)
      prober.instance_variable_set(:@numOfMBChar, num)
      prober.instance_variable_set(:@state, data['state'])
    end

    def self.restore_mbcs(prober, data, expected_model)
      sm = expect_class(data['codingSM'], Hash, 'codingSM')
      unless sm['model'] == expected_model
        raise SnapshotError, "#{prober.get_charset_name} state machine mismatch"
      end
      machine = restore_machine(sm, EItsMe)
      last = decode_bytes(data['lastChar'], 'lastChar', 2)
      unless last.bytesize.between?(1, 2)
        raise SnapshotError, 'lastChar must be 1-2 bytes'
      end
      prober.instance_variable_set(:@codingSM, machine)
      prober.instance_variable_set(:@lastChar, last.dup)
      dist = prober.distributionAnalyzer
      ddata = data['distribution']
      if dist
        expect_class(ddata, Hash, 'distribution')
        total = int_field(ddata, 'totalChars', 0, (1 << 30))
        freq = int_field(ddata, 'freqChars', 0, total)
        dist.instance_variable_set(:@totalChars, total)
        dist.instance_variable_set(:@freqChars, freq)
        dist.instance_variable_set(:@done, false)
      elsif ddata
        raise SnapshotError, 'unexpected distribution data'
      end
      ctx = prober.contextAnalyzer
      cdata = data['context']
      if ctx
        restore_context(ctx, cdata)
      elsif cdata
        raise SnapshotError, 'unexpected context data'
      end
      prober.instance_variable_set(:@state, data['state'])
    end

    def self.restore_context(ctx, cdata)
      expect_class(cdata, Hash, 'context')
      total = int_field(cdata, 'totalRel', 0, MAX_REL_THRESHOLD + 1)
      sample = check_counter_array(cdata['relSample'], NUM_OF_CATEGORY, 'relSample')
      unless sample.inject(:+) <= total
        raise SnapshotError, 'relSample sum exceeds totalRel'
      end
      skip = int_field(cdata, 'needToSkipCharNum', 0, 2)
      order = int_field(cdata, 'lastCharOrder', -1, 255)
      done = bool_field(cdata, 'done')
      if done && total <= MAX_REL_THRESHOLD
        raise SnapshotError, 'context done flag inconsistent with totalRel'
      end
      ctx.instance_variable_set(:@totalRel, total)
      ctx.instance_variable_set(:@relSample, sample)
      ctx.instance_variable_set(:@needToSkipCharNum, skip)
      ctx.instance_variable_set(:@lastCharOrder, order)
      ctx.instance_variable_set(:@done, done)
    end

    def self.restore_sbcs(prober, data)
      unless prober.model_name == expect_class(data['model'], String, 'model')
        raise SnapshotError, 'single byte model mismatch'
      end
      unless prober.reversed == bool_field(data, 'reversed')
        raise SnapshotError, 'single byte reversed flag mismatch'
      end
      last_order = int_field(data, 'lastOrder', 0, 255)
      counters = check_counter_array(data['seqCounters'], NUMBER_OF_SEQ_CAT, 'seqCounters')
      total_seqs = int_field(data, 'totalSeqs', 0, (1 << 30))
      unless counters.inject(:+) <= total_seqs
        raise SnapshotError, 'seqCounters sum exceeds totalSeqs'
      end
      total_char = int_field(data, 'totalChar', 0, (1 << 30))
      freq_char = int_field(data, 'freqChar', 0, total_char)
      name_prober = data['nameProber']
      unless name_prober.nil? || name_prober == 'HebrewProber'
        raise SnapshotError, "unexpected nameProber #{name_prober.inspect}"
      end
      unless !prober.nameProber.nil? == !name_prober.nil?
        raise SnapshotError, 'nameProber presence mismatch'
      end
      prober.instance_variable_set(:@lastOrder, last_order)
      prober.instance_variable_set(:@seqCounters, counters)
      prober.instance_variable_set(:@totalSeqs, total_seqs)
      prober.instance_variable_set(:@totalChar, total_char)
      prober.instance_variable_set(:@freqChar, freq_char)
      prober.instance_variable_set(:@state, data['state'])
    end

    def self.restore_latin1(prober, data)
      last = int_field(data, 'lastCharClass', 0, CLASS_NUM - 1)
      counters = check_counter_array(data['freqCounter'], FREQ_CAT_NUM, 'freqCounter')
      prober.instance_variable_set(:@lastCharClass, last)
      prober.instance_variable_set(:@freqCounter, counters)
      prober.instance_variable_set(:@state, data['state'])
    end

    def self.restore_hebrew(prober, data)
      logical = int_field(data, 'finalCharLogicalScore', 0, (1 << 30))
      visual = int_field(data, 'finalCharVisualScore', 0, (1 << 30))
      prev = decode_bytes(data['prev'], 'prev', 4096)
      before = decode_bytes(data['beforePrev'], 'beforePrev', 4096)
      if prev.empty? || before.empty?
        raise SnapshotError, 'hebrew prev words must be present'
      end
      prober.instance_variable_set(:@finalCharLogicalScore, logical)
      prober.instance_variable_set(:@finalCharVisualScore, visual)
      prober.instance_variable_set(:@prev, prev)
      prober.instance_variable_set(:@beforePrev, before)
      prober.instance_variable_set(:@state, data['state'])
    end

    def self.restore_group(group, data)
      children = expect_class(data['probers'], Array, 'probers')
      unless children.length == group.probers.length
        raise SnapshotError, 'group prober count changed'
      end
      active_num = int_field(data, 'activeNum', 0, children.length)
      group.probers.each_with_index do |existing, i|
        snapshot_type = children[i]['type']
        unless existing.class.name.split('::').last == snapshot_type
          raise SnapshotError, "group layout mismatch at #{i}"
        end
        child_data = children[i]
        child_active = child_data.key?('active') ?
          bool_field(child_data, 'active') : true
        if child_data['inactive'] == true
          unless child_active == false
            raise SnapshotError, 'inactive placeholder marked active'
          end
          existing.instance_variable_set(:@state, ENotMe)
          existing.active = false
        else
          validate_and_restore_child(existing, child_data)
          existing.active = child_active
        end
      end
      actual_active = group.probers.count(&:active)
      unless active_num == actual_active
        raise SnapshotError, 'activeNum does not match restored probers'
      end
      best = data['bestGuess']
      if best
        match = group.probers.find { |p| p.class.name.split('::').last == best ||
                                      (best == 'SingleByteCharSetProber' &&
                                       p.is_a?(SingleByteCharSetProber)) }
        raise SnapshotError, 'bestGuess prober not present' if match.nil?
        group.instance_variable_set(:@bestGuessProber, match)
      else
        group.instance_variable_set(:@bestGuessProber, nil)
      end
      group.instance_variable_set(:@activeNum, active_num)
      group.instance_variable_set(:@state, data['state'])
    end

    def self.validate_and_restore_child(existing, child_data)
      case existing
      when SBCSGroupProber, MBCSGroupProber
        restore_group(existing, child_data)
      when SingleByteCharSetProber
        unless child_data['model'] == existing.model_name &&
               child_data['reversed'] == existing.reversed
          raise SnapshotError, 'single byte prober identity changed'
        end
        existing.restore_from_snapshot(child_data)
      when HebrewProber
        existing.restore_from_snapshot(child_data)
      else
        existing.restore_from_snapshot(child_data)
      end
      existing.active = true
    end

    def self.restore_utf1632(prober, data)
      position = int_field(data, 'position', 0, (1 << 30))
      zeros = check_counter_array(data['zerosAtMod'], 4, 'zerosAtMod')
      nonzeros = check_counter_array(data['nonzerosAtMod'], 4, 'nonzerosAtMod')
      4.times do |i|
        unless zeros[i] + nonzeros[i] == (position / 4) + (i < position % 4 ? 1 : 0)
          raise SnapshotError, "mod-4 counters inconsistent at #{i}"
        end
      end
      quad = check_counter_array(data['quad'], 4, 'quad', 255)
      flags = {}
      %w[invalidUtf16be invalidUtf16le invalidUtf32be invalidUtf32le
         firstHalf16be firstHalf16le].each do |key|
        flags[key] = bool_field(data, key)
      end
      prober.restore_counters(position, zeros, nonzeros, quad, flags)
      prober.instance_variable_set(:@state, data['state'])
    end
  end
end
