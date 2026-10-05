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
  class CharSetProber
    attr_accessor :active
    def initialize
    end

    def reset
      @state = EDetecting
    end

    def get_charset_name
      return nil
    end

    def feed(aBuf)
    end

    # Feed a chunk while optionally replaying one raw byte from the end of
    # the previous chunk. Probers whose statistics pair bytes implement this
    # to stay equivalent to a single continuous buffer.
    def feed_with_replay(aBuf, _replay_byte, _ends_letter_run = false)
      feed(aBuf)
    end

    # First chunk containing a high byte. filtered_prefix is the filtered
    # pure-ASCII prefix already seen (it must not be double counted).
    def feed_first_highbyte(aBuf, _high_index, _filtered_prefix, _prefix_ends_raw_letter = false)
      feed(aBuf)
    end

    def get_state
      return @state
    end

    def get_confidence
      return 0.0
    end

    # Default snapshot: only the prober decision state.
    def snapshot_state
      {"state" => @state}
    end

    def restore_state(state)
      Snapshot.assert!(state.is_a?(Hash), "prober state must be a Hash")
      @state = Snapshot.int_field(state, "state", EDetecting, ENotMe)
    end

    def filter_high_bit_only(aBuf)
      newBuf = aBuf.gsub(/([\x00-\x7F])+/, ' ')
      return newBuf
    end

    def filter_without_english_letters(aBuf)
      newBuf = aBuf.gsub(/([A-Za-z])+/,' ')
      return newBuf
    end

    def filter_with_english_letters(aBuf)
      # TODO
      return aBuf
    end
  end
end
