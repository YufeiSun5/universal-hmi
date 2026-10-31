"""Committed process symbols must match their provenance and remain static."""
import hashlib
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

from vendor_process_symbols import ALLOWED, DEST, REVISION, sanitize
from process_symbol_geometry import OUTPUT, rendered, sizes


class ProcessSymbolTests(unittest.TestCase):
    def test_connection_viewports_match_every_committed_svg(self):
        self.assertEqual(len(sizes()), 474)
        self.assertEqual(OUTPUT.read_text(encoding='utf-8'), rendered())

    def test_catalog_integrity_and_static_geometry(self):
        manifest = json.loads((DEST / 'catalog.json').read_text(encoding='utf-8'))
        self.assertEqual(manifest['revision'], REVISION)
        self.assertEqual(manifest['license'], 'MIT')
        self.assertEqual(len(manifest['items']), 458)
        ids = set()
        paths = set()
        for entry in manifest['items']:
            self.assertNotIn(entry['id'], ids)
            ids.add(entry['id'])
            path = DEST.parent.parent / entry['path']
            self.assertTrue(path.resolve().is_relative_to(DEST.resolve()))
            paths.add(path.name)
            data = path.read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), entry['sha256'])
            for element in ET.fromstring(data).iter():
                self.assertIn(element.tag.split('}')[-1], ALLOWED)
                for key, value in element.attrib.items():
                    self.assertFalse(key.split('}')[-1].lower().startswith('on'))
                    self.assertNotRegex(value.lower(), r'https?:|file:|javascript:|data:')
        self.assertEqual(paths, {p.name for p in (DEST / 'symbols').glob('*.svg')})
        self.assertIn('Permission is hereby granted', (DEST / 'LICENSE-FUXA.txt').read_text())

    def test_sanitizer_removes_active_and_external_content(self):
        rendered = sanitize(b'''<svg xmlns="http://www.w3.org/2000/svg" onload="evil()"><script>evil()</script><foreignObject/><image href="https://example.org/a"/><defs/><path style="fill:#123456;stroke:url(https://x)" onclick="evil()" d="M0 0L1 1"/><use href="javascript:evil()"/></svg>''')
        root = ET.fromstring(rendered)
        self.assertEqual([n.tag.split('}')[-1] for n in root], ['path', 'use'])
        self.assertEqual(root[0].attrib['fill'], '#123456')
        self.assertNotIn('stroke', root[0].attrib)
        self.assertNotIn(b'evil', rendered)


if __name__ == '__main__':
    unittest.main()
