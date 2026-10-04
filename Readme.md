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

### Segmented detection

```Ruby
result = CharDet.detect_segments(
  some_data,
  allowed_encodings: ["UTF-8", "GB18030"],
  minimum_segment_length: 8,
  switch_penalty: 1.0
)

result["segments"].each do |segment|
  segment["byte_start"]
  segment["byte_end"]
  segment["encoding"]
  segment["candidates"]
  segment["reason"]
end

result["total_cost"]
```

Regions that none of the allowed encodings can decode at a complete-character
boundary are returned with `encoding` set to `nil` and `undecidable` set to true.

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
