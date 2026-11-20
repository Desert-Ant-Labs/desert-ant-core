#!/usr/bin/env python3
"""Explicit reference capture. Never run automatically during tests."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
texts = ['Pay my bills', 'café', 'cafe\u0301', 'Ａ ﬁ ①', 'مرحبا', 'नमस्ते', '你好', '안녕', 'γειά', '👩\u200d💻', '', 'a\0b']
source = (root / 'Sources/Emo/Tokenizer.swift').read_text().split('final class SemTokenizer')[0].replace('import DesertAnt', 'import Foundation\nextension String { var nfkc: String { precomposedStringWithCompatibilityMapping } }')
adapter = (root / 'Sources/Emo/UnicodeCompatibility.swift').read_text().replace('#if DAL_ANDROID_UNICODE_TESTS', '').replace('#endif', '').replace('import DesertAnt', '').replace('@_spi(AndroidUnicodeTests)', '')
with tempfile.TemporaryDirectory() as temporary:
    main = Path(temporary) / 'main.swift'
    # JSON is also valid Swift for these string literals except its escaped slash.
    literals = ','.join('"' + ''.join('\\u{%x}' % ord(c) for c in text) + '"' for text in texts)
    main.write_text(source + adapter + '\nfor text in [' + literals + '] { print(emoUnicodeFeatures(text)) }\n')
    binary = Path(temporary) / 'capture'
    subprocess.run(['swiftc', str(main), '-o', str(binary)], check=True)
    rows = subprocess.check_output([str(binary)], text=True).splitlines()
result = {'schema': 1, 'reference': 'Swift NGram reference capture, fixed test parameters 65536/3/1024/256; not a training-accuracy oracle',
          'cases': [{'input': text, 'features': json.loads(row)} for text, row in zip(texts, rows)]}
assert len(result['cases']) == len(texts)
(root / 'Tests/AndroidUnicodeFixtures/emo-features.json').write_text(json.dumps(result, ensure_ascii=True, indent=2) + '\n')
