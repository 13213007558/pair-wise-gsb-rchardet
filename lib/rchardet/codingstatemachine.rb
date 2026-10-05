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
  class CodingStateMachine
    attr_accessor :active

    def initialize(sm)
      @model = sm
      @currentBytePos = 0
      @currentCharLen = 0
      reset()
    end

    def reset
      @currentState = EStart
      @currentBytePos = 0
      @currentCharLen = 0
    end

    def next_state(c)
      # for each byte we get its class
      # if it is first byte, we also get byte length
      b = c.bytes.first
      byteCls = @model['classTable'][b]
      if @currentState == EStart
        @currentBytePos = 0
        @currentCharLen = @model['charLenTable'][byteCls]
      end
      # from byte's class and stateTable, we get its next state
      @currentState = @model['stateTable'][@currentState * @model['classFactor'] + byteCls]
      @currentBytePos += 1
      return @currentState
    end

    def get_current_charlen
      return @currentCharLen
    end

    def get_coding_state_machine
      return @model['name']
    end

    # Plain state needed to resume an unfinished multibyte character in
    # another process.
    def snapshot_state
      {
        "model" => @model['name'],
        "state" => @currentState,
        "byte_pos" => @currentBytePos,
        "char_len" => @currentCharLen
      }
    end

    def restore_state(state, active = true)
      Snapshot.assert!(state.is_a?(Hash), "coding state machine entry must be a Hash")
      model_name = state["model"]
      Snapshot.assert!(model_name == @model['name'],
        "coding state machine model #{model_name.inspect} does not match #{@model['name'].inspect}")
      class_factor = @model['classFactor']
      state_count = (@model['stateTable'].length / class_factor)
      current_state = Snapshot.int_field(state, "state", 0, state_count - 1)
      Snapshot.assert!(@model['stateTable'].include?(current_state),
        "coding state machine state #{current_state} is not a valid model state")
      byte_pos = Snapshot.int_field(state, "byte_pos", 0, 4)
      char_len = Snapshot.int_field(state, "char_len", 0, 4)
      char_len_table = @model['charLenTable']
      Snapshot.assert!(char_len_table.include?(char_len),
        "coding state machine char_len #{char_len} is not part of the model")
      max_pos = char_len.zero? ? 4 : [char_len, 1].max
      Snapshot.assert!(byte_pos >= 0 && byte_pos <= max_pos,
        "coding state machine byte_pos #{byte_pos} is out of range for char_len #{char_len}")
      unless active
        # A deactivated machine is one that reached its error state.
        Snapshot.assert!(current_state == EError,
          "an inactive coding state machine must be in the error state")
      end
      Snapshot.assert!(!active || current_state != EError,
        "an active coding state machine must not be in the error state")
      if current_state == EStart && !char_len.zero?
        # byte_pos is reset to 0 when the next character starts; a value
        # equal to char_len is the boundary of a just-completed character.
        Snapshot.assert!(byte_pos == 0 || byte_pos == char_len,
          "coding state machine start position is inconsistent with char_len")
      end
      @currentState = current_state
      @currentBytePos = byte_pos
      @currentCharLen = char_len
    end
  end
end
