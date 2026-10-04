require_relative "test_helper"
require "tmpdir"

describe "SBCSModelTrainer" do
  let(:alpha_docs) do
    [
      "abc abc abd bca cab abc bca dab",
      "dab abc bca cab abd abc bca",
      "bca cab abc dab abc bca abd abc",
      "cab abd abc bca dab abc bca cab",
      "abc bca cab dab abd abc bca abc"
    ]
  end

  let(:beta_docs) do
    [
      "zyx zyx wyx xzw yxz zyx wxz",
      "wxz yxz zyx xzw zyx wyx yxz",
      "yxz zyx wxz yxz xzw zyx wyx",
      "xzw wyx zyx yxz wxz zyx xzw",
      "zyx xzw yxz wxz wyx zyx yxz"
    ]
  end

  let(:alpha_test_text) { "abc bca cab abd abc dab bca" }
  let(:beta_test_text) { "zyx wyx xzw yxz zyx wxz yxz" }

  def train(docs, name, **options)
    trainer = CharDet::SBCSModelTrainer.new
    docs.each { |doc| trainer.add_document(doc) }
    trainer.build_model(charset_name: name, keep_english_letter: true, **options)
  end

  def alpha_model
    train(alpha_docs, "X-Alpha")
  end

  def beta_model
    train(beta_docs, "X-Beta")
  end

  it "records mapping, categories, sequence stats and version" do
    model = alpha_model
    _(model['version']).must_equal CharDet::SBCSModelTrainer::MODEL_VERSION
    _(model['charsetName']).must_equal "X-Alpha"
    _(model['keepEnglishLetter']).must_equal true
    _(model['charToOrderMap'].size).must_equal 256
    _(model['precedenceMatrix'].size).must_equal CharDet::SAMPLE_SIZE * CharDet::SAMPLE_SIZE
    _(model['precedenceMatrix'].uniq.sort).must_equal [0, CharDet::POSITIVE_CAT]
    _(model['precedenceMatrix'].max).must_be :<, CharDet::NUMBER_OF_SEQ_CAT
    _(model['mTypicalPositiveRatio']).must_be :>, 0.0
    _(model['mTypicalPositiveRatio']).must_be :<=, 1.0
  end

  it "does not join the last byte of a document with the first byte of the next" do
    trainer = CharDet::SBCSModelTrainer.new
    trainer.add_document("ab")
    trainer.add_document("cd")
    _(trainer.pair_counts[[?b.ord, ?c.ord]]).must_equal 0

    joined = CharDet::SBCSModelTrainer.new
    joined.add_document("abcd")
    _(joined.pair_counts[[?b.ord, ?c.ord]]).must_equal 1
  end

  it "produces the same model regardless of document order and chunk size" do
    whole = CharDet::SBCSModelTrainer.new
    alpha_docs.each { |doc| whole.add_document(doc) }

    chunked = CharDet::SBCSModelTrainer.new
    alpha_docs.reverse.each do |doc|
      doc.each_char { |char| chunked.feed(char) }
      chunked.end_document
    end

    model = whole.build_model(charset_name: "X-Alpha", keep_english_letter: true)
    _(chunked.build_model(charset_name: "X-Alpha", keep_english_letter: true)).must_equal model
  end

  it "assigns rare band orders to infrequent letters and control order to unseen bytes" do
    trainer = CharDet::SBCSModelTrainer.new
    doc = (0...74).map { |i| (0x80 + i).chr(Encoding::BINARY) * (74 - i) }.join
    trainer.add_document(doc)
    map = trainer.build_model(charset_name: "X-Rare")['charToOrderMap']

    _(map[0x80]).must_equal 0
    _(map[0x80 + 63]).must_equal 63
    _(map[0x80 + 64]).must_equal 64
    _(map[0xC9]).must_equal 73
    (64..73).each do |rank|
      _(map[0x80 + rank]).must_be :>=, CharDet::SAMPLE_SIZE
      _(map[0x80 + rank]).must_be :<, CharDet::SYMBOL_CAT_ORDER
    end
    _(map[0xFF]).must_equal CharDet::SBCSModelTrainer::CONTROL_ORDER
  end

  it "keeps never observed sequences in category 0" do
    trainer = CharDet::SBCSModelTrainer.new
    trainer.add_document("aa bb aa bb aa bb")
    model = trainer.build_model(charset_name: "X-Pairs", keep_english_letter: true)
    map = model['charToOrderMap']
    matrix = model['precedenceMatrix']
    a = map[?a.ord]
    b = map[?b.ord]

    _(matrix[(a * CharDet::SAMPLE_SIZE) + a]).must_equal CharDet::POSITIVE_CAT
    _(matrix[(b * CharDet::SAMPLE_SIZE) + b]).must_equal CharDet::POSITIVE_CAT
    _(matrix[(a * CharDet::SAMPLE_SIZE) + b]).must_equal 0
    _(matrix[(b * CharDet::SAMPLE_SIZE) + a]).must_equal 0
  end

  it "rejects non-string input but tolerates invalid byte sequences" do
    trainer = CharDet::SBCSModelTrainer.new
    _(proc { trainer.feed(42) }).must_raise ArgumentError
    _(proc { trainer.feed(nil) }).must_raise ArgumentError

    invalid = "\xC3(".dup.force_encoding(Encoding::UTF_8)
    _(invalid.valid_encoding?).must_equal false
    trainer.add_document(invalid)
    _(trainer.char_counts[0xC3]).must_equal 1
  end

  it "selects the right model for held out text of each language" do
    alpha = alpha_model
    beta = beta_model

    [[alpha_test_text, "X-Alpha"], [beta_test_text, "X-Beta"]].each do |text, expected|
      group = CharDet::CharSetGroupProber.new
      group.probers = [
        CharDet::SingleByteCharSetProber.new(alpha),
        CharDet::SingleByteCharSetProber.new(beta)
      ]
      group.reset
      group.feed(text)
      _(group.get_charset_name).must_equal expected
    end

    alpha_prober = CharDet::SingleByteCharSetProber.new(alpha)
    beta_prober = CharDet::SingleByteCharSetProber.new(beta)
    alpha_prober.feed(alpha_test_text)
    beta_prober.feed(alpha_test_text)
    _(alpha_prober.get_confidence).must_be :>, beta_prober.get_confidence
  end

  it "reloads a serialized model with identical counts and confidence" do
    model = alpha_model
    Dir.mktmpdir do |dir|
      path = File.join(dir, "alpha.sbcsmodel")
      CharDet::SBCSModelTrainer.save_model(model, path)
      loaded = CharDet::SBCSModelTrainer.load_model(path)
      _(loaded).must_equal model

      trained_prober = CharDet::SingleByteCharSetProber.new(model)
      loaded_prober = CharDet::SingleByteCharSetProber.new(loaded)
      trained_prober.feed(alpha_test_text)
      loaded_prober.feed(alpha_test_text)

      %i[@seqCounters @totalSeqs @totalChar @freqChar @lastOrder].each do |ivar|
        _(loaded_prober.instance_variable_get(ivar)).must_equal trained_prober.instance_variable_get(ivar)
      end
      _(loaded_prober.get_confidence).must_equal trained_prober.get_confidence
      _(loaded_prober.get_charset_name).must_equal trained_prober.get_charset_name
    end
  end

  it "rejects models with missing keys or wrong version on load" do
    Dir.mktmpdir do |dir|
      bad_version = File.join(dir, "bad.sbcsmodel")
      CharDet::SBCSModelTrainer.save_model(alpha_model.merge('version' => 999), bad_version)
      _(proc { CharDet::SBCSModelTrainer.load_model(bad_version) }).must_raise ArgumentError

      not_a_model = File.join(dir, "junk.sbcsmodel")
      File.binwrite(not_a_model, Marshal.dump("junk"))
      _(proc { CharDet::SBCSModelTrainer.load_model(not_a_model) }).must_raise ArgumentError
    end
  end
end
