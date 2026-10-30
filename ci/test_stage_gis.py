"""Regress the shipped-map failure, including stale generated-site scripts."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import stage_gis
from build_release import sources


class GISStagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.source, self.site, self.web = root/'source', root/'site', root/'web'
        for folder in (self.source, self.site, self.web):
            folder.mkdir()
        for name in stage_gis.PRESENTATION_FILES:
            (self.source/name).write_bytes((stage_gis.SOURCE/name).read_bytes())
            (self.site/name).write_text('obsolete map without live bindings', encoding='utf-8')
        for name, data in {
            'imagery/manifest.json': json.dumps({'layers': [{'id': 'demo', 'tileCount': 1}]}),
            'imagery/demo/tile.webp': 'offline imagery fixture',
            'vendor/cesium/Cesium.js': 'vendor fixture',
            'vendor/cesium/LICENSE.md': 'license fixture',
        }.items():
            path = self.site/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data, encoding='utf-8')
        (self.web/'flutter_bootstrap.js').write_text('fixture', encoding='utf-8')
        self.inventory = {'examples/gis-flight/'+name: stage_gis.digest(self.source/name)
                          for name in stage_gis.PRESENTATION_FILES}

    def stage(self):
        with patch.object(stage_gis, 'SOURCE', self.source):
            stage_gis.stage(self.site, self.web)

    def test_generated_site_cannot_override_binding_code(self):
        self.stage()
        for name in stage_gis.PRESENTATION_FILES:
            if name != 'index.html':
                self.assertEqual((self.web/'gis'/name).read_bytes(), (self.source/name).read_bytes())
        self.assertIn('gis-readings', (self.web/'gis/flight.js').read_text('utf-8'))
        self.assertIn('setReadings', (self.web/'gis/stations.js').read_text('utf-8'))
        entry = (self.web/'gis/map.html').read_text('utf-8')
        expected = stage_gis.digest(self.source/'stations.js')[:16]
        self.assertIn('stations.js?v='+expected, entry)
        stage_gis.verify_staged(self.web, self.inventory)

    def test_stale_script_rejected_even_if_other_artifact_hashes_are_updated(self):
        self.stage()
        (self.web/'gis/stations.js').write_text('obsolete map', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'Stale GIS'):
            stage_gis.verify_staged(self.web, self.inventory)

    def test_missing_or_different_source_provenance_rejected(self):
        self.stage()
        with self.assertRaisesRegex(ValueError, 'release source'):
            stage_gis.verify_staged(self.web, {})
        changed = dict(self.inventory)
        changed['examples/gis-flight/flight.js'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'release source'):
            stage_gis.verify_staged(self.web, changed)

    def test_cached_entry_without_script_versions_rejected(self):
        self.stage()
        (self.web/'gis/map.html').write_bytes((self.source/'index.html').read_bytes())
        with self.assertRaisesRegex(ValueError, 'current scripts'):
            stage_gis.verify_staged(self.web, self.inventory)

    def test_release_inventory_includes_map_sources(self):
        inventory = sources()
        for name in stage_gis.PRESENTATION_FILES:
            self.assertEqual(inventory['examples/gis-flight/'+name], stage_gis.digest(stage_gis.SOURCE/name))


if __name__ == '__main__':
    unittest.main()
