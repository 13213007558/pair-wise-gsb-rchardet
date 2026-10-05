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
  SAMPLE_SIZE = 64
  SB_ENOUGH_REL_THRESHOLD = 1024
  POSITIVE_SHORTCUT_THRESHOLD = 0.95
  NEGATIVE_SHORTCUT_THRESHOLD = 0.05
  SYMBOL_CAT_ORDER = 250
  NUMBER_OF_SEQ_CAT = 4
  POSITIVE_CAT = NUMBER_OF_SEQ_CAT - 1
  #NEGATIVE_CAT = 0

  class SingleByteCharSetProber < CharSetProber
    attr_accessor :prefixEndsRawLetter
    def initialize(model, reversed=false, nameProber=nil)
      super()
      @model = model
      @reversed = reversed # TRUE if we need to reverse every pair in the model lookup
      @nameProber = nameProber # Optional auxiliary prober for name decision
      reset()
    end

    def reset
      super()
      @lastOrder = 255 # char order of last character
      @replayEndsLetterRun = false
      @prefixEndsRawLetter = false
      @seqCounters = [0] * NUMBER_OF_SEQ_CAT
      @totalSeqs = 0
      @totalChar = 0
      @freqChar = 0 # characters that fall in our sampling range
    end

    def get_charset_name
      if @nameProber
        return @nameProber.get_charset_name()
      else
        return @model['charsetName']
      end
    end

    def feed(aBuf)
      unless @model['keepEnglishLetter']
        aBuf = filter_without_english_letters(aBuf)
      end
      aLen = aBuf.length
      return get_state() if aLen == 0
      replayLastOrder = @lastOrder
      aBuf.each_byte do |b|
        order = @model['charToOrderMap'][b]
        if order < SYMBOL_CAT_ORDER
          @totalChar += 1
        end
        if order < SAMPLE_SIZE
          @freqChar += 1
          if replayLastOrder < SAMPLE_SIZE
            @totalSeqs += 1
            if !@reversed
              @seqCounters[@model['precedenceMatrix'][(replayLastOrder * SAMPLE_SIZE) + order]] += 1
            else
              @seqCounters[@model['precedenceMatrix'][(order * SAMPLE_SIZE) + replayLastOrder]] += 1
            end
          end
        end
        replayLastOrder = order
      end
      @lastOrder = replayLastOrder

      if get_state() == EDetecting && @totalSeqs > SB_ENOUGH_REL_THRESHOLD
        cf = get_confidence()
        if cf > POSITIVE_SHORTCUT_THRESHOLD
          $stderr << "#{@model['charsetName']} confidence = #{cf}, we have a winner\n" if $debug
          @state = EFoundIt
        elsif cf < NEGATIVE_SHORTCUT_THRESHOLD
          $stderr << "#{@model['charsetName']} confidence = #{cf}, below negative threshold\n" if $debug
          @state = ENotMe
        end
      end
      get_state()
    end

    # First high-byte chunk in a resumed detector: filtered_prefix is the
    # already-filtered pure-ASCII prefix from before this prober existed.
    # Feed it plus this chunk as one continuous filtered stream, skipping
    # counters for the prefix bytes.
    def feed_first_highbyte(aBuf, _high_index, filtered_prefix, prefix_ends_raw_letter = false)
      return feed(aBuf) if @model['keepEnglishLetter']
      if filtered_prefix.nil? || filtered_prefix.empty?
        return feed(aBuf)
      end
      # Resumed case: the filtered pure-ASCII prefix was seen before this
      # prober existed. A continuous stream would have fed the whole data
      # filtered once, so process the counted prefix, then only this chunk's
      # high-byte tail (the chunk's leading ASCII is already in the prefix).
      high_index = aBuf.index(/[\x80-\xFF]/n) || aBuf.bytesize
      high_part = aBuf.byteslice(high_index, aBuf.bytesize - high_index)
      high_filtered = filter_without_english_letters(high_part)
      combined = filtered_prefix + high_filtered
      # Count everything: prefix bytes count exactly as a continuous stream
      # would, and the tail starts the high-byte statistics.
      analyze_filtered(combined, 0)
      get_state()
    end

    def analyze_filtered(filtered, skip)
      replayLastOrder = @lastOrder
      filtered.each_byte.with_index do |b, index|
        if index < skip
          replayLastOrder = @model['charToOrderMap'][b]
          next
        end
        order = @model['charToOrderMap'][b]
        if order < SYMBOL_CAT_ORDER
          @totalChar += 1
        end
        if order < SAMPLE_SIZE
          @freqChar += 1
          if replayLastOrder < SAMPLE_SIZE
            @totalSeqs += 1
            if !@reversed
              @seqCounters[@model['precedenceMatrix'][(replayLastOrder * SAMPLE_SIZE) + order]] += 1
            else
              @seqCounters[@model['precedenceMatrix'][(order * SAMPLE_SIZE) + replayLastOrder]] += 1
            end
          end
        end
        replayLastOrder = order
      end
      @lastOrder = replayLastOrder
    end

    # feed_with_replay accepts either:
    # * a single replay byte (normal chunk boundary): that byte is paired
    #   with the first byte of this chunk but never counted, or
    # * a pre-filtered prefix String (the first high-byte chunk): it is
    #   processed exactly as a normal filtered chunk.
    def feed_with_replay(aBuf, replay, ends_letter_run = false)
      return feed(aBuf) if @model['keepEnglishLetter'] || replay.nil?
      @replayEndsLetterRun = ends_letter_run
      replay_string = replay.to_s.dup.force_encoding(Encoding::BINARY)
      chunk_filtered = @model['keepEnglishLetter'] ? aBuf : filter_without_english_letters(aBuf)
      if @model['keepEnglishLetter']
        filtered = replay_string + chunk_filtered
        skip = replay_string.bytesize
      else
        if ends_letter_run && chunk_filtered.start_with?(' '.b) && replay_string.end_with?(' '.b)
          chunk_filtered = chunk_filtered.byteslice(1, chunk_filtered.bytesize - 1)
        end
        filtered = replay_string + chunk_filtered
        # When the boundary merged two spaces into one, that one space is the
        # prefix's; the chunk's own bytes start after it.
        skip = replay_string.bytesize
      end
      return get_state() if filtered.length <= skip

      replayLastOrder = @lastOrder
      filtered.each_byte.with_index do |b, index|
        if index < skip
          replayLastOrder = @model['charToOrderMap'][b]
          next
        end
        order = @model['charToOrderMap'][b]
        if order < SYMBOL_CAT_ORDER
          @totalChar += 1
        end
        if order < SAMPLE_SIZE
          @freqChar += 1
          if replayLastOrder < SAMPLE_SIZE
            @totalSeqs += 1
            if !@reversed
              @seqCounters[@model['precedenceMatrix'][(replayLastOrder * SAMPLE_SIZE) + order]] += 1
            else
              @seqCounters[@model['precedenceMatrix'][(order * SAMPLE_SIZE) + replayLastOrder]] += 1
            end
          end
        end
        replayLastOrder = order
      end
      @lastOrder = replayLastOrder
      @replayEndsLetterRun = false

      if get_state() == EDetecting && @totalSeqs > SB_ENOUGH_REL_THRESHOLD
        cf = get_confidence()
        if cf > POSITIVE_SHORTCUT_THRESHOLD
          @state = EFoundIt
        elsif cf < NEGATIVE_SHORTCUT_THRESHOLD
          @state = ENotMe
        end
      end
      get_state()
    end

    def get_confidence
      r = 0.01
      if @totalSeqs > 0
        r = (1.0 * @seqCounters[POSITIVE_CAT]) / @totalSeqs / @model['mTypicalPositiveRatio']
        r = r * @freqChar / @totalChar
        if r >= 1.0
          r = 0.99
        end
      end
      return r
    end

    def snapshot_state
      super.merge(
        "model" => @model['charsetName'],
        "reversed" => @reversed,
        "last_order" => @lastOrder,
        "seq_counters" => @seqCounters.dup,
        "total_seqs" => @totalSeqs,
        "total_char" => @totalChar,
        "freq_char" => @freqChar
      )
    end

    def restore_state(state)
      super
      model_name = Snapshot.string_field(state, "model", [@model['charsetName']])
      reversed = Snapshot.bool_field(state, "reversed")
      Snapshot.assert!(reversed == @reversed,
        "prober model #{model_name.inspect} reversed flag does not match")
      @lastOrder = Snapshot.int_field(state, "last_order", 0, 255)
      @seqCounters = Snapshot.int_array(state, "seq_counters", NUMBER_OF_SEQ_CAT, 0, (1 << 31) - 1)
      @totalSeqs = Snapshot.int_field(state, "total_seqs", 0, (1 << 31) - 1)
      @totalChar = Snapshot.int_field(state, "total_char", 0, (1 << 31) - 1)
      @freqChar = Snapshot.int_field(state, "freq_char", 0, (1 << 31) - 1)
      Snapshot.assert!(@freqChar <= @totalChar, "freq_char exceeds total_char")
      Snapshot.assert!(@seqCounters.inject(0, :+) <= @totalSeqs,
        "seq_counters entries sum exceeds total_seqs")
    end
  end
end
