# encoding: utf-8
require_relative "test_helper"

module SnapshotTestHelpers
  def continuous_result(data)
    detector = CharDet::UniversalDetector.new
    detector.feed(data)
    detector.close
    detector.result
  end

  # Take a portable, JSON round-tripped snapshot at every cut point and
  # finish detection in a freshly restored detector.
  def snapshot_result(data, cut)
    head = data.byteslice(0, cut)
    tail = data.byteslice(cut, data.bytesize - cut)
    detector = CharDet::UniversalDetector.new
    detector.feed(head) unless head.empty?
    json = CharDet::Snapshot.dump(detector.snapshot)
    assert_operator json.bytesize, :<, 8192, "snapshot must stay small"
    if head.bytesize >= 4
      refute_includes json, head, "snapshot must not contain the raw input"
    end
    restored = CharDet::UniversalDetector.restore_snapshot(CharDet::Snapshot.load(json))
    restored.feed(tail) unless tail.empty?
    restored.close
    restored.result
  end

  def each_cut(data)
    (0..data.bytesize).each { |cut| yield cut }
  end
end

describe "Snapshot" do
  include SnapshotTestHelpers

  it "exposes a format version, gem version and model identifier" do
    detector = CharDet::UniversalDetector.new
    snapshot = detector.snapshot
    assert_equal 1, snapshot["format_version"]
    assert_equal CharDet::VERSION, snapshot["rchardet_version"]
    assert_match(/\Acrc32-[0-9a-f]{8}\z/, snapshot["model_id"])
  end

  it "does not use Marshal and survives another process" do
    refute_operator CharDet::Snapshot, :<, Marshal
    detector = CharDet::UniversalDetector.new
    detector.feed("hello")
    json = CharDet::Snapshot.dump(detector.snapshot)
    assert_kind_of String, json
    assert_kind_of Hash, CharDet::Snapshot.load(json)
  end

  it "recovers every UTF-8 multibyte split identically to continuous input" do
    samples = [
      "\xC3\xA9".b * 8,
      "é".encode("UTF-8") * 20,
      ("€".encode("UTF-8") + "abc") * 10,
      "日本語テキスト".encode("UTF-8") * 8,
      File.binread("test/simple_assets/UTF-8.txt").byteslice(0, 400),
      File.binread("test/assets/utf-8/linuxbox.hu.xml").byteslice(0, 400)
    ]
    samples.each do |data|
      expected = continuous_result(data)
      each_cut(data) do |cut|
        assert_equal expected, snapshot_result(data, cut),
          "UTF-8 split at byte #{cut} of #{data.bytesize}"
      end
    end
  end

  it "recovers every ISO-2022 escape sequence split identically to continuous input" do
    data = File.binread("test/simple_assets/ISO-2022-JP.txt").byteslice(0, 300)
    expected = continuous_result(data)
    assert_equal "ISO-2022-JP", expected["encoding"]
    each_cut(data) do |cut|
      assert_equal expected, snapshot_result(data, cut),
        "ISO-2022-JP split at byte #{cut} of #{data.bytesize}"
    end
  end

  it "recovers an escape sequence split exactly on the ESC byte" do
    data = "abc\x1B$B$$\x1B(B".b
    expected = continuous_result(data)
    (0...data.bytesize).each do |cut|
      assert_equal expected, snapshot_result(data, cut),
        "escape split at byte #{cut}"
    end
  end

  it "recovers every BOM split for each supported signature" do
    boms = {
      "\xEF\xBB\xBF".b => "UTF-8",
      "\xFF\xFE\x00\x00".b => "UTF-32LE",
      "\x00\x00\xFE\xFF".b => "UTF-32BE",
      "\xFE\xFF\x00\x00".b => "X-ISO-10646-UCS-4-3412",
      "\x00\x00\xFF\xFE".b => "X-ISO-10646-UCS-4-2143",
      "\xFF\xFE".b => "UTF-16LE",
      "\xFE\xFF".b => "UTF-16BE",
      "\x2B\x2F\x76\x38".b => "UTF-7"
    }
    boms.each do |bom, encoding|
      data = bom + "rest-of-stream".b
      expected = continuous_result(data)
      assert_equal encoding, expected["encoding"]
      (0..data.bytesize).each do |cut|
        assert_equal expected, snapshot_result(data, cut),
          "#{encoding} BOM split at byte #{cut}"
      end
    end
  end

  it "recovers mid-character splits for multibyte highbyte probers" do
    file = File.binread("test/assets/EUC-JP/yukiboh.moo.jp.xml")
    data = file.byteslice(0, 600)
    expected = continuous_result(data)
    each_cut(data) do |cut|
      assert_equal expected, snapshot_result(data, cut),
        "EUC-JP split at byte #{cut}"
    end
  end

  it "allows two independent branches from one snapshot" do
    data = "日本語データ".encode("UTF-8")
    detector = CharDet::UniversalDetector.new
    detector.feed(data.byteslice(0, 4))
    json = CharDet::Snapshot.dump(detector.snapshot)

    branch_a = CharDet::UniversalDetector.restore_snapshot(CharDet::Snapshot.load(json))
    branch_b = CharDet::UniversalDetector.restore_snapshot(CharDet::Snapshot.load(json))
    branch_a.feed(data.byteslice(4, data.bytesize - 4))
    branch_a.close
    branch_b.feed("plain ascii continuation")
    branch_b.close

    assert_equal continuous_result(data), branch_a.result
    assert_equal continuous_result(data.byteslice(0, 4) + "plain ascii continuation".b),
      branch_b.result
  end

  it "can restart a fully closed detector through a snapshot" do
    data = File.binread("test/simple_assets/UTF-8.txt")
    detector = CharDet::UniversalDetector.new
    detector.feed(data)
    detector.close
    snapshot = detector.snapshot
    assert snapshot["closed"]
    restored = CharDet::UniversalDetector.restore_snapshot(snapshot)
    assert restored.closed?
    assert restored.done
    assert_equal detector.result, restored.result
    restored.feed("more data")
    assert_equal detector.result, restored.result
  end

  it "distinguishes a closed state from a still-feedable state" do
    open_detector = CharDet::UniversalDetector.new
    open_detector.feed("abc")
    refute open_detector.closed?
    refute open_detector.done
    assert_equal false, open_detector.snapshot["closed"]

    closed_detector = CharDet::UniversalDetector.restore_snapshot(
      CharDet::Snapshot.load(CharDet::Snapshot.dump(open_detector.snapshot)))
    closed_detector.close
    assert closed_detector.closed?
    assert closed_detector.done
    assert_equal true, closed_detector.snapshot["closed"]

    restored_open = CharDet::UniversalDetector.restore_snapshot(open_detector.snapshot)
    refute restored_open.closed?
    restored_open.feed("def")
    restored_open.close
    assert_equal({"encoding" => "ascii", "confidence" => 1.0}, restored_open.result)
  end

  it "rejects snapshots with a corrupted count before reading more data" do
    detector = CharDet::UniversalDetector.new
    detector.feed("é".encode("UTF-8"))
    snapshot = detector.snapshot
    utf8 = snapshot["charset_probers"][0]["probers"][0]
    utf8["num_mb_char"] = -1
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end

    utf8["num_mb_char"] = "two"
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end
  end

  it "rejects corrupted counters and unfinished sequence state" do
    data = File.binread("test/assets/Big5/digitalwall.com.xml").byteslice(0, 800)
    detector = CharDet::UniversalDetector.new
    detector.feed(data)
    snapshot = detector.snapshot

    # freq_chars must never exceed total_chars
    big5 = snapshot["charset_probers"][0]["probers"][5]
    original = big5["distribution"]["freq_chars"]
    big5["distribution"]["freq_chars"] = big5["distribution"]["total_chars"] + 1
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end
    big5["distribution"]["freq_chars"] = original

    # coding state machine position must be within the model
    big5["coding_state_machine"]["state"] = 999
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end
  end

  it "rejects snapshots restored with changed models" do
    detector = CharDet::UniversalDetector.new
    detector.feed("abc")
    snapshot = detector.snapshot
    snapshot["model_id"] = "crc32-deadbeef"
    error = assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end
    assert_match(/model_id/, error.message)
  end

  it "rejects snapshots from other gem and format versions" do
    detector = CharDet::UniversalDetector.new
    detector.feed("abc")
    snapshot = detector.snapshot

    snapshot["rchardet_version"] = "0.0.1"
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end

    snapshot["rchardet_version"] = CharDet::VERSION
    snapshot["format_version"] = 999
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end
  end

  it "rejects malformed JSON and structurally invalid snapshots" do
    assert_raises(CharDet::SnapshotError) { CharDet::Snapshot.load("{") }
    assert_raises(CharDet::SnapshotError) { CharDet::Snapshot.load("[]") }

    detector = CharDet::UniversalDetector.new
    detector.feed("abc")
    snapshot = detector.snapshot
    snapshot["detector"]["input_state"] = 42
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end

    snapshot["detector"]["input_state"] = 1
    snapshot.delete("esc_prober")
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end
  end

  it "rejects pending BOM leads that are not signature prefixes" do
    detector = CharDet::UniversalDetector.new
    detector.feed("\xFF".b)
    snapshot = detector.snapshot
    assert_equal 1, snapshot["detector"]["bom_lead"].bytesize
    snapshot["detector"]["bom_lead"] = "\x42".b
    assert_raises(CharDet::SnapshotError) do
      CharDet::UniversalDetector.restore_snapshot(snapshot)
    end
  end

  it "does not mutate the caller's buffer" do
    detector = CharDet::UniversalDetector.new
    buffer = "é".encode("UTF-8").dup
    detector.feed(buffer)
    detector.close
    assert_equal Encoding::UTF_8, buffer.encoding
  end
end
