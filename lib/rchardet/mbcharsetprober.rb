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
#   Proofpoint, Inc.
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
  class MultiByteCharSetProber < CharSetProber
    def initialize
      super
      @distributionAnalyzer = nil
      @codingSM = nil
      @lastChar = +"\x00\x00"
    end

    def reset
      super
      if @codingSM
        @codingSM.reset()
      end
      if @distributionAnalyzer
        @distributionAnalyzer.reset()
      end
      @lastChar = +"\x00\x00"
    end

    def get_charset_name
    end

    def feed(aBuf)
      aLen = aBuf.length
      for i in (0...aLen)
        codingState = @codingSM.next_state(aBuf[i, 1])
        if codingState == EError
          $stderr << "#{get_charset_name} prober hit error at byte #{i}\n" if $debug
          @state = ENotMe
          break
        elsif codingState == EItsMe
          @state = EFoundIt
          break
        elsif codingState == EStart
          charLen = @codingSM.get_current_charlen()
          if i == 0
            @lastChar[1] = aBuf[0, 1]
            @distributionAnalyzer.feed(@lastChar, charLen)
          else
            @distributionAnalyzer.feed(aBuf[i-1, 2], charLen)
          end
        end
      end
      @lastChar[0] = aBuf[aLen-1, 1]

      if get_state() == EDetecting
        if @distributionAnalyzer.got_enough_data() and (get_confidence() > SHORTCUT_THRESHOLD)
          @state = EFoundIt
        end
      end
      return get_state()
    end

    def get_confidence
      return @distributionAnalyzer.get_confidence()
    end

    def snapshot_state
      super.merge(
        "coding_state_machine" => @codingSM.snapshot_state,
        "distribution" => @distributionAnalyzer.snapshot_state,
        "last_char" => Snapshot.binary(@lastChar.dup)
      )
    end

    def restore_state(state)
      super
      coding_active = state.key?("active") ? Snapshot.bool_field(state, "active") : true
      @codingSM.restore_state(Snapshot.hash_field(state, "coding_state_machine"), coding_active)
      @distributionAnalyzer.restore_state(Snapshot.hash_field(state, "distribution"))
      last_char = Snapshot.binary_field(state, "last_char", 2)
      Snapshot.assert!(last_char.bytesize == 2, "field last_char must be exactly 2 bytes")
      @lastChar = last_char.dup
    end
  end
end
