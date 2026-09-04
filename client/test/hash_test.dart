import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hashlib/hashlib.dart';

void main() {
  const vectors = <String, String>{
    '': '99aa06d3014798d86001c324468d497f',
    'abc': '06b05ab6733a618578af5f94892f3950',
    'Hello, World!': '531df2844447dd5077db03842cd75395',
    'The quick brown fox jumps over the lazy dog':
        'ddd650205ca3e7fa24a1cc2e3a8a7651',
  };

  test('XXH3-128 uses canonical cross-language vectors', () async {
    for (final entry in vectors.entries) {
      final bytes = utf8.encode(entry.key);
      expect(xxh128.convert(bytes).hex(), entry.value);
      final streamed = await xxh128.bind(Stream.value(bytes)).first;
      expect(streamed.hex(), entry.value);
    }
  });
}
