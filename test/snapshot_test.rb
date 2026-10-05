# encoding: utf-8
require_relative "test_helper"
require "json"

describe "State snapshots" do
  def run_continuous(data)
    detector = CharDet::UniversalDetector.new
    detector.feed(data)
    detector.close
    detector
  end

  def run_restored_at(data, at, json: false)
    first = CharDet::UniversalDetector.new
    first.feed(data.byteslice(0, at))
    detector = if json
      CharDet::UniversalDetector.restore_json(first.snapshot_json)
    else
      CharDet::UniversalDetector.restore(first.snapshot)
    end
    detector.feed(data.byteslice(at..-1).to_s) if at < data.bytesize
    detector.close
    detector
  end

  def assert_every_split_matches(data, label, json: false)
    expected = run_continuous(data).result
    failures = []
    (0..data.bytesize).each do |at|
      restored = run_restored_at(data, at, json: json)
      failures << at if restored.result != expected
    end
    assert failures.empty?,
      "#{label}: #{failures.length} split position(s) differed, first: #{failures.first(5)}"
  end

  it "carries a format version and a build/model identifier" do
    detector = CharDet::UniversalDetector.new
    detector.feed("abc")
    snapshot = detector.snapshot
    _(snapshot["formatVersion"]).must_equal CharDet::StateSnapshot::FORMAT_VERSION
    _(snapshot["modelId"]).must_match(/\Archardet-\d+\.\d+\.\d+-probers-\d+-[0-9a-f]{16}\z/)
    _(snapshot["status"]).must_equal "detecting"
  end

  it "is plain JSON data and never stores the original input" do
    data = File.binread("test/simple_assets/ISO-2022-JP.txt")
    detector = CharDet::UniversalDetector.new
    detector.feed(data.byteslice(0, 40))
    raw = detector.snapshot_json
    parsed = JSON.parse(raw)
    _(parsed).must_be_kind_of Hash
    _(raw).wont_include data.byteslice(0, 40)
    _(raw.bytesize).must_be :<, data.bytesize
  end

  it "distinguishes a closed detector from one that can still be fed" do
    open_detector = CharDet::UniversalDetector.new
    open_detector.feed("hello")
    _(open_detector.closed?).must_equal false
    _(open_detector.snapshot["status"]).must_equal "detecting"
    restored_open = CharDet::UniversalDetector.restore(open_detector.snapshot)
    _(restored_open.closed?).must_equal false
    _(restored_open.done).must_equal false

    closed_detector = CharDet::UniversalDetector.new
    closed_detector.feed("hello")
    closed_detector.close
    _(closed_detector.closed?).must_equal true
    _(closed_detector.snapshot["status"]).must_equal "closed"
    restored_closed = CharDet::UniversalDetector.restore(closed_detector.snapshot)
    _(restored_closed.closed?).must_equal true
    _(restored_closed.done).must_equal true

    before = restored_closed.result.dup
    restored_closed.feed("anything".b)
    _(restored_closed.result).must_equal before
  end

  it "allows two independent detection branches from one snapshot" do
    data = File.binread("test/simple_assets/ISO-2022-JP.txt")
    trunk = CharDet::UniversalDetector.new
    trunk.feed(data.byteslice(0, 100))
    snapshot = trunk.snapshot

    branch_a = CharDet::UniversalDetector.restore(snapshot)
    branch_b = CharDet::UniversalDetector.restore(snapshot)
    branch_a.feed(data.byteslice(100, 200))
    branch_b.feed(data.byteslice(100, 50))
    branch_a.feed(data.byteslice(300..-1).to_s)
    branch_b.feed(data.byteslice(150..-1).to_s)
    branch_a.close
    branch_b.close
    _(branch_a.result).must_equal run_continuous(data).result
    _(branch_b.result).must_equal run_continuous(data).result

    again = CharDet::UniversalDetector.restore(snapshot)
    again.feed(data.byteslice(100..-1).to_s)
    again.close
    _(again.result).must_equal run_continuous(data).result
  end

  it "restores UTF-8 multibyte characters identically at every split" do
    astro = ("h\u00E9llo \u65E5\u672C\u8A9E " +
             "\u{1F600}\u{1F4A1} mixed ascii \u30C6\u30AD\u30B9\u30C8").b
    assert_every_split_matches(astro, "mixed-width UTF-8")

    data = File.binread("test/simple_assets/UTF-8.txt")
    expected = run_continuous(data).result
    (0..data.bytesize).step(97).each do |at|
      _(run_restored_at(data, at).result).must_equal expected
    end
  end

  it "restores ISO-2022 escape sequences identically at every split" do
    data = File.binread("test/simple_assets/ISO-2022-JP.txt")
    assert_every_split_matches(data, "ISO-2022-JP asset")
    assert_every_split_matches(data, "ISO-2022-JP asset json", json: true)
  end

  it "restores BOM detection identically at every split" do
    samples = {
      "UTF-8 BOM" => "\u00EF\u00BB\u00BFHello".b,
      "UTF-32LE BOM" => "\u00FF\u00FE\u0000\u0000hello".b,
      "UTF-32BE BOM" => "\u0000\u0000\u00FE\u00FFhello".b,
      "UCS-4 3412 BOM" => "\u00FE\u00FF\u0000\u0000hello".b,
      "UCS-4 2143 BOM" => "\u0000\u0000\u00FF\u00FEhello".b,
      "UTF-16LE BOM" => ("\u00FF\u00FE".b + "ABCDEFGH".encode(Encoding::UTF_16LE).b.byteslice(2..-1)),
      "UTF-16BE BOM" => ("\u00FE\u00FF".b + "ABCDEFGH".encode(Encoding::UTF_16BE).b.byteslice(2..-1)),
      "UTF-7 mark" => "\u002B\u002F\u0076\u0038hello".b
    }
    samples.each do |label, data|
      assert_every_split_matches(data, label)
    end
  end

  it "carries an unfinished multibyte character across the boundary" do
    data = "\u65E5\u672C\u8A9E\u306E\u9577\u3044\u30C6\u30AD\u30B9\u30C8ABCDEFGH".b
    [1, 2].each do |at|
      first = CharDet::UniversalDetector.new
      first.feed(data.byteslice(0, at))
      snapshot = first.snapshot
      restored = CharDet::UniversalDetector.restore(snapshot)
      restored.feed(data.byteslice(at..-1))
      restored.close
      _(restored.result).must_equal run_continuous(data).result
    end
  end

  it "rejects a snapshot with a corrupted counter before reading more data" do
    detector = CharDet::UniversalDetector.new
    detector.feed("\u65E5\u672C\u8A9E text".b)
    parsed = JSON.parse(detector.snapshot_json)
    parsed["highbyteProbers"][0]["probers"][0]["numMBChar"] += 1_000_000
    error = assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore(parsed)
    end
    _(error.message).must_match(/integrity/)
  end

  it "rejects a snapshot built for a different model" do
    detector = CharDet::UniversalDetector.new
    detector.feed("\u65E5\u672C\u8A9E text".b)
    parsed = JSON.parse(detector.snapshot_json)

    changed = parsed.dup
    changed["modelId"] = changed["modelId"].sub(/[0-9a-f]\z/) { |c| c == "0" ? "1" : "0" }
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore(changed)
    end

    swapped = parsed.dup
    utf8 = swapped["highbyteProbers"][0]["probers"][0]
    utf8["codingSM"] = utf8["codingSM"].merge("model" => "Big5")
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore(swapped)
    end
  end

  it "rejects out-of-range fields and malformed snapshots" do
    detector = CharDet::UniversalDetector.new
    detector.feed("\u65E5\u672C\u8A9E text".b)

    bad_version = JSON.parse(detector.snapshot_json)
    bad_version["formatVersion"] = 999
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore(bad_version)
    end

    bad_state = JSON.parse(detector.snapshot_json)
    bad_state["inputState"] = 42
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore(bad_state)
    end

    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_json("definitely not json")
    end
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore("not-a-hash")
    end
  end
end
