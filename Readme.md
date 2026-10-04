Encoding detection for ruby.

```Bash
gem install rchardet
```

Usage
=====

```Ruby
require 'rubygems'
require 'rchardet'

cd = CharDet.detect(some_data)
encoding = cd['encoding']
confidence = cd['confidence'] # 0.0 <= confidence <= 1.0
```

Training custom single-byte models
==================================

Offline models for `CharDet::SingleByteCharSetProber` can be trained from
annotated single-byte text instead of editing the fixed `lang*model.rb`
tables.

```Ruby
model = CharDet::SingleByteModelTrainer.train(
  documents,                 # Array/Enumerable of binary String documents
  charset_name: "X-MY-ENC",  # name reported by the prober
  model_version: "2026-10-01",
  language: "my-language",
  sample_size: 64,           # explicit settings (all have defaults)
  positive_rank_cutoff: 512,
  likely_rank_cutoff: 1024,
  rare_min_count: 5
)

File.binwrite("my-model.json", CharDet::SingleByteModelTrainer.train_json(
  documents, charset_name: "X-MY-ENC", model_version: "2026-10-01"
))
loaded = CharDet::SingleByteModelLoader.load_file("my-model.json")
prober = CharDet::SingleByteCharSetProber.new(loaded)
prober.feed(binary_text)
prober.get_confidence
```

Guarantees:
- pairs are counted only within a document, never across document
  boundaries (use `add_document` or `feed_chunk`/`end_document`),
- output is independent of document order and chunk size; ties are broken
  deterministically,
- rare bytes (below `rare_min_count`) get a fixed rare order, unseen
  candidate bytes get a fixed unseen order, and never-observed letter pairs
  remain category 0 (negative),
- non-String input raises `ArgumentError`; malformed model files raise
  `CharDet::ModelLoadError`.

### [Contributors](http://github.com/grosser/pru/contributors)
 - [Jeff Hodges](http://github.com/jmhodges)
 - [Denis Savitsky](https://github.com/sadfuzzy)
 - [Sam Rose](https://github.com/samwho)
 - [Cole Thompson](https://github.com/coledot)
 - [KITAITI Makoto](https://github.com/KitaitiMakoto)

Maintained by [Michael Grosser](http://grosser.it)<br/>
michael@grosser.it<br/>
License: LGPL<br/>
[![Build Status](https://travis-ci.org/jmhodges/rchardet.png)](https://travis-ci.org/jmhodges/rchardet)
Made for [rFeedParser](https://github.com/jmhodges/rfeedparser)
