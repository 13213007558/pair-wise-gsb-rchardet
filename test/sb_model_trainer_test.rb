# encoding: utf-8
require_relative "test_helper"
require "tmpdir"
require "fileutils"

describe "SingleByteModelTrainer" do
  # Two deliberately artificial single-byte "languages". They share the same
  # 48 letter bytes (0xC0..0xEF) and identical unigram frequencies, but have
  # disjoint bigram transition patterns, so selection can only succeed via
  # the adjacent-sequence statistics -- not letter frequency.
  LETTER_BYTES = (0xC0..0xEF).to_a.freeze
  SPACE = 0x20
  NEWLINE = 0x0A
  DIGITS = (0x30..0x39).to_a.freeze
  RARE_BYTE = 0xF0

  # Deterministic weighted choice generator, so the synthetic corpora are
  # reproducible and the test never depends on Kernel#rand.
  def make_rng(seed)
    state = seed
    proc do |weights|
      total = weights.sum
      raise ArgumentError, "weights must be positive" if total <= 0
      state = (state * 1_103_515_245 + 12_345) % (2**31)
      target = state % total
      chosen = weights.length - 1
      index = 0
      while index < weights.length
        if target < weights[index]
          chosen = index
          break
        end
        target -= weights[index]
        index += 1
      end
      chosen
    end
  end

  # language == :a  -> follower clusters near the leader
  # language == :b  -> follower clusters opposite the leader
  def transition_weight(language, leader, follower)
    distance = (follower - leader).abs
    if language == :a
      50 - distance * 2
    else
      offset = (follower - leader + LETTER_BYTES.length) % LETTER_BYTES.length
      forward = (offset - LETTER_BYTES.length / 2).abs
      50 - forward * 2
    end
  end

  def generate_document(language:, seed:, length:, include_rare: false)
    rng = make_rng(seed)
    bytes = []
    leader = rng.call(Array.new(LETTER_BYTES.length, 1))
    length.times do |position|
      if position > 0 && (position % 17).zero?
        bytes << SPACE
        if (position % 51).zero?
          bytes << DIGITS[rng.call(Array.new(10, 1))]
          bytes << SPACE
        end
        next
      end
      weights = LETTER_BYTES.map { |follower| transition_weight(language, leader, LETTER_BYTES.index(follower)) }
      follower = rng.call(weights)
      bytes << LETTER_BYTES[follower]
      leader = follower
    end
    bytes << NEWLINE
    if include_rare
      # Seen exactly twice: must be classified as a rare byte.
      bytes << RARE_BYTE << 0x20 << RARE_BYTE
    end
    bytes.pack("C*").b
  end

  def training_documents(language)
    Array.new(8) do |index|
      generate_document(language: language, seed: 1000 + language.hash.abs + index,
                        length: 400, include_rare: index.zero?)
    end
  end

  def train_model(language, documents)
    CharDet::SingleByteModelTrainer.train(
      documents,
      charset_name: "X-TOY-#{language == :a ? "A" : "B"}",
      model_version: "1.0.0",
      language: language.to_s,
      sample_size: 64,
      # Cutoffs chosen so the toy matrices exercise categories 3, 2 and 1.
      positive_rank_cutoff: 100,
      likely_rank_cutoff: 600,
      rare_min_count: 5
    )
  end

  def prober_for(model)
    CharDet::SingleByteCharSetProber.new(model)
  end

  def feed_chunked(prober, string, chunk_size)
    string.bytes.each_slice(chunk_size) do |slice|
      prober.feed(slice.pack("C*").b)
    end
  end

  before do
    @docs_a = training_documents(:a)
    @docs_b = training_documents(:b)
    @model_a = train_model(:a, @docs_a)
    @model_b = train_model(:b, @docs_b)
    @held_out_a = generate_document(language: :a, seed: 424_242, length: 500)
    @held_out_b = generate_document(language: :b, seed: 909_090, length: 500)
  end

  it "records char mapping, sequence categories, stats and version metadata" do
    _(@model_a["charToOrderMap"].length).must_equal 256
    _(@model_a["precedenceMatrix"].length).must_equal 64 * 64
    _(@model_a["modelVersion"]).must_equal "1.0.0"
    _(@model_a["formatVersion"]).must_equal CharDet::MODEL_FORMAT_VERSION
    _(@model_a["charsetName"]).must_equal "X-TOY-A"
    _(@model_a["language"]).must_equal "a"
    _(@model_a["trainStats"]["documents"]).must_equal 8
    _(@model_a["trainStats"]["letterBytes"]).must_equal LETTER_BYTES.length
    categories = @model_a["precedenceMatrix"].uniq.sort
    _(categories).must_include 3
    _(categories).must_include 2
  end

  it "selects the matching language on held-out short corpora" do
    prober_aa = prober_for(@model_a)
    prober_ab = prober_for(@model_b)
    prober_aa.feed(@held_out_a)
    prober_ab.feed(@held_out_a)
    assert_operator prober_aa.get_confidence, :>, prober_ab.get_confidence

    prober_ba = prober_for(@model_a)
    prober_bb = prober_for(@model_b)
    prober_ba.feed(@held_out_b)
    prober_bb.feed(@held_out_b)
    assert_operator prober_bb.get_confidence, :>, prober_ba.get_confidence
  end

  it "does not pair the end of one document with the start of the next" do
    boundary_documents = ["\x80\x81", "\x82\x83"].map(&:b)
    merged_document = boundary_documents.join

    separate = CharDet::SingleByteModelTrainer.new(
      charset_name: "X-BOUNDARY", model_version: "1.0.0",
      positive_rank_cutoff: 4, likely_rank_cutoff: 16, rare_min_count: 1
    )
    boundary_documents.each { |document| separate.add_document(document) }
    separate.finalize

    merged = CharDet::SingleByteModelTrainer.train(
      [merged_document],
      charset_name: "X-MERGED", model_version: "1.0.0",
      positive_rank_cutoff: 4, likely_rank_cutoff: 16, rare_min_count: 1
    )

    # Separate documents share pairs C0C1 and C2C3; the merged document adds
    # the cross-boundary pair C1C2, producing one more observed pair.
    _(separate.statistics["observedPairs"]).must_equal 2
    _(merged["trainStats"]["observedPairs"]).must_equal 3
  end

  it "is invariant to document order and feed chunk size" do
    shuffled = train_model(:a, @docs_a.shuffle(random: Random.new(7)))
    _(shuffled["charToOrderMap"]).must_equal @model_a["charToOrderMap"]
    _(shuffled["precedenceMatrix"]).must_equal @model_a["precedenceMatrix"]
    _(shuffled["mTypicalPositiveRatio"]).must_equal @model_a["mTypicalPositiveRatio"]

    prober_one = prober_for(@model_a)
    prober_chunks = prober_for(@model_a)
    prober_one.feed(@held_out_a)
    feed_chunked(prober_chunks, @held_out_a, 13)
    _(prober_chunks.seqCounters).must_equal prober_one.seqCounters
    _(prober_chunks.totalSeqs).must_equal prober_one.totalSeqs
    _(prober_chunks.freqChar).must_equal prober_one.freqChar
    _(prober_chunks.totalChar).must_equal prober_one.totalChar
  end

  it "marks rare bytes and unseen candidate bytes explicitly" do
    rare_order = @model_a["charToOrderMap"][RARE_BYTE]
    _(rare_order).must_equal 253
    # 0xF1 never appears in training and stays an unseen candidate.
    _(@model_a["charToOrderMap"][0xF1]).must_equal 255
    _(@model_a["trainStats"]["rareBytes"]).must_be :>=, 1
    # Spaces, digits and line breaks keep their explicit categories.
    _(@model_a["charToOrderMap"][SPACE]).must_equal 253
    _(@model_a["charToOrderMap"][0x30]).must_equal 252
    _(@model_a["charToOrderMap"][NEWLINE]).must_equal 254
  end

  it "treats never-observed letter pairs as the negative category 0" do
    # Letter order 0 never follows letter order 63 in language A data by
    # construction of the local clustering; verify a 0 cell exists and that
    # feeding such a pair increments the negative counter, not confidence.
    assert_includes @model_a["precedenceMatrix"], 0
    prober = prober_for(@model_a)
    negative_pair = [LETTER_BYTES[0], LETTER_BYTES.last].pack("C*").b
    prober.feed(negative_pair)
    _(prober.seqCounters[0]).must_equal 1
    _(prober.seqCounters[3]).must_equal 0
  end

  it "rejects invalid trainer and prober input" do
    assert_raises(ArgumentError) do
      CharDet::SingleByteModelTrainer.new(charset_name: "", model_version: "1")
    end
    assert_raises(ArgumentError) do
      CharDet::SingleByteModelTrainer.new(charset_name: "X", model_version: "x",
                                          positive_rank_cutoff: 10, likely_rank_cutoff: 2)
    end
    trainer = CharDet::SingleByteModelTrainer.new(charset_name: "X", model_version: "1")
    assert_raises(ArgumentError) { trainer.feed_chunk(1234) }
    assert_raises(ArgumentError) { trainer.feed_chunk(nil) }

    prober = prober_for(@model_a)
    assert_raises(NoMethodError) { prober.feed(nil) }
  end

  it "produces parameters from data plus explicit settings" do
    custom = CharDet::SingleByteModelTrainer.train(
      @docs_a,
      charset_name: "X-CUSTOM", model_version: "9",
      sample_size: 64, positive_rank_cutoff: 100, likely_rank_cutoff: 600,
      rare_min_count: 5, typical_positive_ratio: 0.42
    )
    _(custom["mTypicalPositiveRatio"]).must_equal 0.42
    _(custom["parameters"]["positiveRankCutoff"]).must_equal 100
    _(custom["parameters"]["likelyRankCutoff"]).must_equal 600
    # Without any observed positive pair and no explicit ratio, training fails
    # loudly instead of emitting a bogus ratio.
    assert_raises(ArgumentError) do
      CharDet::SingleByteModelTrainer.train(
        ["\x80\x81".b],
        charset_name: "X-NOSEQ", model_version: "1",
        positive_rank_cutoff: 0, likely_rank_cutoff: 0
      )
    end
  end

  it "round-trips through JSON and a file with identical counts and confidence" do
    Dir.mktmpdir("rchardet-model", ".tmp") do |directory|
      path = File.join(directory, "model_a.json")
      File.binwrite(path, @model_a.then { |model| JSON.generate(model) })

      [CharDet::SingleByteModelLoader.load_json(JSON.generate(@model_a)),
       CharDet::SingleByteModelLoader.load_file(path)].each do |loaded|
        _(loaded["charToOrderMap"]).must_equal @model_a["charToOrderMap"]
        _(loaded["precedenceMatrix"]).must_equal @model_a["precedenceMatrix"]
        _(loaded["mTypicalPositiveRatio"]).must_equal @model_a["mTypicalPositiveRatio"]
        _(loaded["modelVersion"]).must_equal "1.0.0"

        trained_prober = prober_for(@model_a)
        loaded_prober = prober_for(loaded)
        trained_prober.feed(@held_out_a)
        loaded_prober.feed(@held_out_a)
        _(loaded_prober.seqCounters).must_equal trained_prober.seqCounters
        _(loaded_prober.totalSeqs).must_equal trained_prober.totalSeqs
        _(loaded_prober.totalChar).must_equal trained_prober.totalChar
        _(loaded_prober.freqChar).must_equal trained_prober.freqChar
        _(loaded_prober.get_confidence).must_equal trained_prober.get_confidence
        _(loaded_prober.get_charset_name).must_equal "X-TOY-A"
      end
    end
  end

  it "rejects malformed serialized models with ModelLoadError" do
    loader = CharDet::SingleByteModelLoader
    assert_raises(CharDet::ModelLoadError) { loader.load_json("{not json") }
    assert_raises(CharDet::ModelLoadError) { loader.load_json("[]") }
    bad_version = JSON.generate(@model_a).then { |json| json.sub('"formatVersion":1', '"formatVersion":999') }
    assert_raises(CharDet::ModelLoadError) { loader.load_json(bad_version) }
    truncated = @model_a.dup
    truncated["precedenceMatrix"] = truncated["precedenceMatrix"][0, 10]
    assert_raises(CharDet::ModelLoadError) { loader.load_json(JSON.generate(truncated)) }
    assert_raises(CharDet::ModelLoadError) { loader.load_json(123) }
  end

  it "reports stable confidence for both languages and zero data safely" do
    empty_prober = prober_for(@model_a)
    _(empty_prober.get_confidence).must_equal 0.01

    [@model_a, @model_b].each do |model|
      prober = prober_for(model)
      prober.feed(model["charsetName"] == "X-TOY-A" ? @held_out_a : @held_out_b)
      confidence = prober.get_confidence
      _(confidence).must_be :>, 0.2
      _(confidence).must_be :<=, 0.99
    end
  end
end
