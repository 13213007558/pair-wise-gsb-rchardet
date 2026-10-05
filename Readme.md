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

Resumable detection across processes
===================================

An upload may pause at any byte. `UniversalDetector#snapshot` returns a
JSON-compatible Hash (no original input, no `Marshal`) that captures the active
probers, unfinished character/escape sequences, counters and the terminal
state, together with a format version and a model identifier. Hand the same
snapshot to several detectors to branch independent probes.

```Ruby
detector = CharDet::UniversalDetector.new
detector.feed(first_chunk)

json = detector.snapshot_json      # portable to another process

a = CharDet::UniversalDetector.restore_json(json)
b = CharDet::UniversalDetector.restore_json(json)  # independent branch
a.feed(second_chunk_variant_a)
b.feed(second_chunk_variant_b)
a.close
b.close
```

Restoration validates field ranges and model compatibility before any further
data is read; tampered counters or snapshots produced against different models
raise `CharDet::SnapshotError`. A detector already finished via `close`
(`closed? == true`) is distinguished from one that can still accept `feed`.

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
