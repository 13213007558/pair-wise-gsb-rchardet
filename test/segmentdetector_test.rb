require_relative "test_helper"

describe "SegmentDetector" do
  ALLOWED = ["UTF-8", "GB18030"]

  def detect_stream(data, chunk_sizes, penalty: 1.0, minimum: 1)
    detector = CharDet::SegmentDetector.new(
      allowed_encodings: ALLOWED,
      minimum_segment_length: minimum,
      switch_penalty: penalty
    )
    position = 0
    chunk_sizes.cycle do |size|
      break if position >= data.bytesize
      detector.feed(data.byteslice(position, size))
      position += size
    end
    detector.close
    detector.result
  end

  def labels(result)
    result["segments"].map do |segment|
      [segment["byte_start"], segment["byte_end"], segment["encoding"]]
    end
  end

  it "detects a direct UTF-8 to GB18030 switch on character boundaries" do
    data = "启动".encode("UTF-8").b + "日志".encode("GB18030").b
    result = CharDet.detect_segments(
      data,
      allowed_encodings: ALLOWED,
      minimum_segment_length: 1,
      switch_penalty: 1.0
    )

    _(labels(result)).must_equal [
      [0, 6, "UTF-8"],
      [6, 10, "GB18030"]
    ]
    result["segments"].each_cons(2) do |left, right|
      _(right["reason"]).must_include "complete-character"
      _(left["byte_end"]).must_equal right["byte_start"]
    end
  end

  it "keeps a pure ASCII bridge as one common segment" do
    data = "启动".encode("UTF-8").b + "LOG:".b + "日志".encode("GB18030").b
    result = CharDet.detect_segments(
      data,
      allowed_encodings: ALLOWED,
      minimum_segment_length: 1,
      switch_penalty: 1.0
    )

    _(labels(result)).must_equal [
      [0, 6, "UTF-8"],
      [6, 10, "ASCII"],
      [10, 14, "GB18030"]
    ]
    _(result["segments"][1]["candidates"]).must_equal [{"encoding" => "ASCII", "confidence" => 1.0}]
  end

  it "marks an unrecognized byte as an undecidable one-byte region" do
    data = "启动".encode("UTF-8").b + "日志记录".encode("GB18030").b + "\xff".b
    result = CharDet.detect_segments(
      data,
      allowed_encodings: ALLOWED,
      minimum_segment_length: 1,
      switch_penalty: 1.0
    )

    _(labels(result)).must_equal [
      [0, 6, "UTF-8"],
      [6, 14, "GB18030"],
      [14, 15, nil]
    ]
    _(result["segments"].last["undecidable"]).must_equal true
    _(result["total_cost"]).must_equal 2.0
  end

  it "returns identical segmentation for different input chunkings" do
    data = "启动".encode("UTF-8").b + "LOG:".b + "日志".encode("GB18030").b + "\xfe".b
    one_shot = detect_stream(data, [data.bytesize])
    chunked = detect_stream(data, [1, 2, 3, 7])
    split_multibyte = detect_stream(data, [2, 5, 1, 4])

    _(labels(chunked)).must_equal labels(one_shot)
    _(labels(split_multibyte)).must_equal labels(one_shot)
    _(chunked["total_cost"]).must_equal one_shot["total_cost"]
  end

  it "requires stateful encodings to finish in reset state" do
    complete = "あ".encode("ISO-2022-JP").b
    without_reset = complete.byteslice(0, complete.bytesize - 3)
    detector = CharDet::SegmentDetector.new(
      allowed_encodings: ["ISO-2022-JP"],
      minimum_segment_length: 1,
      switch_penalty: 1.0
    )
    detector.feed(complete + without_reset)

    _(detector.send(:read_character, CharDet::ISO2022JPSMModel, 0, complete.bytesize, true)).must_equal true
    _(detector.send(:read_character, CharDet::ISO2022JPSMModel, complete.bytesize, complete.bytesize + without_reset.bytesize, true)).must_equal false
  end

  it "rejects invalid options" do
    _(-> { CharDet.detect_segments("abc".b, allowed_encodings: [], minimum_segment_length: 1) }).must_raise ArgumentError
    _(-> { CharDet.detect_segments("abc".b, allowed_encodings: ALLOWED, minimum_segment_length: 0) }).must_raise ArgumentError
    _(-> { CharDet.detect_segments("abc".b, allowed_encodings: ALLOWED, switch_penalty: -1) }).must_raise ArgumentError
    _(-> { CharDet.detect_segments("abc".b, allowed_encodings: ["UTF-32BE"], minimum_segment_length: 1) }).must_raise ArgumentError
  end

  it "returns an empty result for empty input" do
    result = CharDet.detect_segments(
      "".b,
      allowed_encodings: ALLOWED,
      minimum_segment_length: 1,
      switch_penalty: 1.0
    )
    _(result["segments"]).must_equal []
    _(result["total_cost"]).must_equal 0.0
  end

  it "matches an exhaustive enumeration of character-aligned segmentations" do
    data = "启".encode("UTF-8").b + "中".encode("GB18030").b
    penalty = 2.0
    result = CharDet.detect_segments(
      data,
      allowed_encodings: ALLOWED,
      minimum_segment_length: 1,
      switch_penalty: penalty
    )

    detector = CharDet::SegmentDetector.new(
      allowed_encodings: ALLOWED,
      minimum_segment_length: 1,
      switch_penalty: penalty
    )
    detector.feed(data)
    models = {
      "UTF-8" => CharDet::UTF8SMModel,
      "GB18030" => CharDet::GB18030SMModel
    }
    cuts = (1...data.bytesize).to_a
    best = Float::INFINITY

    (0..cuts.length).each do |count|
      cuts.combination(count).each do |selected|
        boundaries = [0] + selected + [data.bytesize]
        concrete = []
        valid = boundaries.each_cons(2).all? do |start, finish|
          if data.byteslice(start, finish - start).bytes.all? { |byte| byte < 0x80 }
            true
          else
            models.any? do |candidate, model|
              detector.send(:read_character, model, start, finish, false) &&
                (candidate == "UTF-8" || data.byteslice(start, finish - start).bytes.last >= 0x80)
            end
          end
        end
        next unless valid

        boundaries.each_cons(2) do |start, finish|
          bytes = data.byteslice(start, finish - start)
          if bytes.bytes.any? { |byte| byte >= 0x80 }
          concrete << (detector.send(:read_character, models["UTF-8"], start, finish, false) ? "UTF-8" : "GB18030")
          end
        end
        switches = concrete.each_cons(2).count { |left, right| left != right }
        best = [best, switches * penalty].min
      end
    end

    _(result["total_cost"]).must_equal best
    _(labels(result)).must_equal [[0, 3, "UTF-8"], [3, 5, "GB18030"]]
  end
end
