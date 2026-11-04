"""Make a station-list update from the user's current GIS export."""
from pathlib import Path
import copy, hashlib, json

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path('D:/Users/SunYufei/Downloads/gis-stations.json')
DEST = Path('D:/Users/SunYufei/Downloads/03-GIS红光美苑首站-导入站点专用.json')
original_bytes = SOURCE.read_bytes()
original = json.loads(original_bytes.decode('utf-8-sig'))
assert original['format'] == 'universal-hmi-gis-stations' and original['version'] == 1
matches = [s for s in original['stations'] if s['id'] == 'zh-gis-0ce1f3bc25a4cc51']
assert len(matches) == 1 and matches[0]['name'] == '红光美苑首站'
before = matches[0]
after = copy.deepcopy(before)
replacements = {
    'zh-m5': ('pt_d35cccc5b35f79b4ea3f1ec9', 'pt_8daa523a649821c8bad49c03', '中节能_西站_供水_温度'),
    'zh-m6': ('pt_3e5405a7f5b5c029ac3d811a', 'pt_474b6cd854b3f34cf2b2d7d8', '中节能_西站_回水_温度'),
}
snapshot = json.loads((ROOT/'.local/update-1104/verified-points.json').read_text('utf-8-sig'))
points = {p['id']: p for p in snapshot}
for key, (old, new, path) in replacements.items():
    assert before['bindings'][key] == old
    assert points[new]['source_path'] == path
    assert points[new]['source_id'] == 'source-1793013239860'
    after['bindings'][key] = new
copyback = copy.deepcopy(after)
copyback['bindings'] = before['bindings']
assert copyback == before
result = {'format': original['format'], 'version': 1, 'stations': [after]}
DEST.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
assert SOURCE.read_bytes() == original_bytes
print(json.dumps({'file': str(DEST), 'stations_in_file': 1, 'current_stations': len(original['stations']),
                  'changed_bindings': 2, 'sha256': hashlib.sha256(DEST.read_bytes()).hexdigest()}, ensure_ascii=False))
