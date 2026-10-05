######################## BEGIN LICENSE BLOCK ########################
# The Original Code is mozilla.org code.
#
# The Initial Developer of the Original Code is
# Netscape Communications Corporation.
# Portions created by the Initial Developer are Copyright (C) 1998
# the Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Jeff Hodges - port to Ruby
#   Mark Pilgrim - port to Python
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
  class EscCharSetProber < CharSetProber
    def initialize
      super()
      @codingSM = [ 
                     CodingStateMachine.new(HZSMModel),
                     CodingStateMachine.new(ISO2022CNSMModel),
                     CodingStateMachine.new(ISO2022JPSMModel),
                     CodingStateMachine.new(ISO2022KRSMModel)
                    ]
      reset()
    end

    def reset
      super()
      for codingSM in @codingSM
        next if !codingSM
        codingSM.active = true
        codingSM.reset()
      end
      @activeSM = @codingSM.length
      @detectedCharset = nil
    end

    def get_charset_name
      return @detectedCharset
    end

    def get_confidence
      if @detectedCharset
        return 0.99
      else
        return 0.00
      end
    end

    def feed(aBuf)
      aBuf.each_byte do |b|
        c = b.chr
        for codingSM in @codingSM
          next unless codingSM
          next unless codingSM.active
          codingState = codingSM.next_state(c)
          if codingState == EError
            codingSM.active = false
            @activeSM -= 1
            if @activeSM <= 0
              @state = ENotMe
              return get_state()
            end
          elsif codingState == EItsMe
            @state = EFoundIt
            @detectedCharset = codingSM.get_coding_state_machine()
            return get_state()
          end
        end
      end

      return get_state()
    end

    def snapshot_state
      {
        "state" => @state,
        "active_sm" => @activeSM,
        "detected_charset" => @detectedCharset,
        "coding_state_machines" => @codingSM.map do |coding_sm|
          entry = coding_sm.snapshot_state
          entry.merge("active" => coding_sm.active)
        end
      }
    end

    def restore_state(state)
      Snapshot.assert!(state.is_a?(Hash), "escape prober state must be a Hash")
      @state = Snapshot.int_field(state, "state", EDetecting, EFoundIt)
      detected = state["detected_charset"]
      Snapshot.assert!(detected.nil? || Snapshot::SM_MODEL_NAMES.include?(detected),
        "escape prober detected charset is not a known escape charset")
      machines = state["coding_state_machines"]
      Snapshot.assert!(machines.is_a?(Array) && machines.length == @codingSM.length,
        "escape prober needs #{@codingSM.length} coding state machines")
      active_count = 0
      machines.each_with_index do |entry, index|
        Snapshot.assert!(entry.is_a?(Hash), "coding state machine #{index} must be an object")
        active = Snapshot.bool_field(entry, "active")
        @codingSM[index].restore_state(entry, active)
        @codingSM[index].active = active
        active_count += 1 if active
      end
      @activeSM = Snapshot.int_field(state, "active_sm", 0, @codingSM.length)
      Snapshot.assert!(@activeSM == active_count,
        "active_sm #{@activeSM} does not match active coding state machines (#{active_count})")
      if @state == EFoundIt
        Snapshot.assert!(!detected.nil?, "found escape state requires a detected charset")
        found_machine = @codingSM.find { |machine| machine.get_coding_state_machine == detected }
        Snapshot.assert!(found_machine && found_machine.active,
          "detected escape charset does not match an active coding state machine")
      else
        Snapshot.assert!(detected.nil?, "detected charset must be nil while detecting")
      end
      @detectedCharset = detected
    end
  end
end
