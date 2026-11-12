"""Build private annual templates from read-only Excel r/c/v/f cell extracts.

Output contains customer labels; keep it outside the public source tree.
No historical readings, chart sheets or old calendar rows are copied.
"""
import argparse
import base64
import json
import re
import zipfile
from xml.etree import ElementTree
from pathlib import Path


def col(n):
    out = ''
    while n >= 0:
        out = chr(n % 26 + 65) + out
        n = n // 26 - 1
    return out


def total(refs):
    args = ','.join(refs)
    return f'=IF(COUNT({args})=0,"",SUM({args}))'


def build(path, kind):
    book = json.loads(path.read_text(encoding='utf-8-sig'))
    sheet = next(s for s in book['sheets'] if s['name'].startswith('各站'))
    by = {(c['r'], c['c']): c for c in sheet['cells']}
    headers = 12 if kind == 'heat' else 13
    inputs = [c for c in range(sheet['columns']) if str(by.get((headers-1, c), {}).get('v', '')).startswith('示数')]
    assert inputs, 'No meter input columns'
    leaves = [c+1 for c in inputs]
    columns = max(leaves) + 1
    source_row = 19 if kind == 'heat' else 32
    daily_formula = {c: by[(source_row, c)]['f'] for c in range(3, columns) if by.get((source_row, c), {}).get('f')}
    cells = []
    for r in range(headers):
        for c in range(columns):
            old = by.get((r, c), {})
            if old.get('v') is None and not old.get('f'):
                continue
            v = old.get('v')
            cell = {'r': r, 'c': c}
            if r == 4 and kind != 'heat':
                continue
            if old.get('f'):
                if kind == 'water' and c == 3:
                    cell['f'] = old['f']
                elif 5 <= r <= 10:
                    month = [11, 12, 1, 2, 3, 4][r-5]
                    cell['f'] = total([f'{col(c)}{{m{month}first}}:{col(c)}{{m{month}last}}'])
                elif r == (1 if kind == 'water' else 2):
                    cell['f'] = total([f'{col(c)}6:{col(c)}11'])
                else:
                    cell['f'] = total([f'{col(c)}{{first}}:{col(c)}{{last}}'])
            elif r == 0 and c in leaves or kind != 'water' and r == 1 and c in leaves:
                cell['v'] = v
                cell['editable'] = True
            elif isinstance(v, (float, int)):
                if c == 1 and r in (3, 4):
                    cell['v'] = '{year}'
                else:
                    continue
            elif isinstance(v, str):
                cell['v'] = ' '.join(v.split()).replace('全年合计', '采暖季合计')
                if kind == 'heat':
                    cell['v'] = cell['v'].replace('电表', '热量表').replace('耗电', '耗热')
                if c == 0 and '年' in v and v[:4].isdigit():
                    cell['v'] = '{year}采暖季'
            else:
                continue
            cells.append(cell)
    positions = {(c['r'], c['c']) for c in cells}
    for c in leaves:
        for r in ([0] if kind == 'water' else [0, 1]):
            if (r, c) not in positions:
                cells.append({'r': r, 'c': c, 'editable': True})
    if kind != 'heat':
        cells += [{'r': 4, 'c': 0, 'v': '统计期'}, {'r': 4, 'c': 3, 'v': '{year}-11-05 至 {nextyear}-04-05'}]
    daily = []
    for c in inputs:
        daily.append({'r': 2, 'c': c, 'editable': kind != 'heat'})
        a, b, maximum = f'{col(c)}3', f'{col(c)}2', f'{col(c+1)}$1'
        # SUM coerces blank operands for the browser engine's eager IF evaluation.
        # COUNT still guards validity, so absent readings never become valid zero.
        va, vb, vm = f'SUM({a})', f'SUM({b})', f'SUM({maximum})'
        diff = f'IF({va}<{vb},IF(OR(COUNT({maximum})<>1,{vm}<{vb}),"",{vm}-{vb}+{va}),{va}-{vb})'
        if kind != 'water':
            ratio = f'{col(c+1)}$2'
            vr = f'SUM({ratio})'
            diff = f'IF(OR(COUNT({ratio})<>1,AND({va}<{vb},OR(COUNT({maximum})<>1,{vm}<{vb}))),"",IF({va}<{vb},({vm}-{vb}+{va})*{vr},({va}-{vb})*{vr}))'
        daily.append({'r': 2, 'c': c+1, 'f': f'=IF(COUNT({a},{b})<>2,"",{diff})'})
    grand = 4 if kind == 'water' else 3
    for c, formula in daily_formula.items():
        if c in leaves:
            continue
        if kind == 'water' and c == 3:
            daily.append({'r': 2, 'c': c, 'f': formula})
        elif c == grand:
            daily.append({'r': 2, 'c': c, 'f': total([f'{col(n)}3' for n in leaves])})
        else:
            refs = re.findall(r'([A-Z]+)\d+', formula)
            daily.append({'r': 2, 'c': c, 'f': total([f'{n}3' for n in dict.fromkeys(refs)])})
    calc_columns = {c['c'] for c in daily if c.get('f')}
    for r in [1 if kind == 'water' else 2, 5, 6, 7, 8, 9, 10]:
        for c in calc_columns:
            if kind == 'water' and c == 3:
                continue
            cells = [x for x in cells if (x['r'], x['c']) != (r, c)]
            if r in range(5, 11):
                m = [11, 12, 1, 2, 3, 4][r-5]
                f = total([f'{col(c)}{{m{m}first}}:{col(c)}{{m{m}last}}'])
            else:
                f = total([f'{col(c)}6:{col(c)}11'])
            cells.append({'r': r, 'c': c, 'f': f})
    merges = []
    # Consolidate legacy month-end helper labels into one clear subtotal label.
    for r in [1 if kind == 'water' else 2, 5, 6, 7, 8, 9, 10]:
        cells = [c for c in cells if c['r'] != r or c['c'] not in (1, 2)]
        merges.append({'r': r, 'c': 0, 'rs': 1, 'cs': 3})
    for r in [0] + ([1] if kind != 'water' else []):
        merges.append({'r': r, 'c': 0, 'rs': 1, 'cs': inputs[0]+1})
    for r in ([3, 4] if kind == 'heat' else [3, 11]):
        labels = sorted(c['c'] for c in cells if c['r'] == r and c['c'] >= 3 and isinstance(c.get('v'), str))
        for i, c in enumerate(labels):
            end = labels[i+1] if i+1 < len(labels) else columns
            if end-c > 1:
                merges.append({'r': r, 'c': c, 'rs': 1, 'cs': end-c})
    if kind != 'heat':
        merges += [{'r': 4, 'c': 0, 'rs': 1, 'cs': 3}, {'r': 4, 'c': 3, 'rs': 1, 'cs': columns-3}]
    result = {'kind': kind, 'name': {'heat': '热报表', 'electricity': '电报表', 'water': '水报表'}[kind], 'columns': columns, 'header_rows': headers, 'cells': cells, 'daily': daily, 'input_columns': inputs, 'widths': {'0': 54, '1': 54, '2': 76, '3': 120}, 'merges': merges}
    style_path = path.parent / f'{kind}.styles.json'
    if style_path.exists():
        result['styles'] = json.loads(style_path.read_text(encoding='utf-8-sig'))
    layout_path = path.parent / f'{kind}.layout.json'
    if layout_path.exists():
        layout = json.loads(layout_path.read_text(encoding='utf-8-sig'))
        result['merges'] = [m for m in layout['merges'] if kind == 'heat' or not (m['r'] <= 4 < m['r']+m['rs'])]
        if kind != 'heat':
            result['merges'] += [{'r': 4, 'c': 0, 'rs': 1, 'cs': 3}, {'r': 4, 'c': 3, 'rs': 1, 'cs': columns-3}]
        result['widths'] = layout['widths']
        # Excel visually overflows these labels into blank neighbours; use a
        # merge in the embedded renderer without swallowing the coloured E cell.
        for r in ([0] if kind == 'water' else [0, 1]):
            if not any(m['r'] <= r < m['r']+m['rs'] and m['c'] < 3 for m in result['merges']):
                result['merges'].append({'r': r, 'c': 0, 'rs': 1, 'cs': 3})
    if kind == 'heat':
        # Confirmed 2026-11-11 ER_TotalHeat member zones, once per shared meter.
        stations = ['01-001-01', '01-005-01', '01-003-01', '02-002-01', '02-003-01', '03-001-01', '04-001-01', '04-003-01']
        assert len(inputs) == len(stations)
        result['bindings'] = [{'column': c, 'station': s, 'point': 'ER_TotalHeat', 'unit': 'GJ'} for c, s in zip(inputs, stations)]
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--original-dir', type=Path, help='Native Excel-saved heat/electricity/water.xlsx originals for lossless export')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for kind, filename in [('heat', 'A热量统计热源版26.cells.json'), ('electricity', '耗电统计26(2).cells.json'), ('water', '耗水统计26.cells.json')]:
        result = build(args.input / filename, kind)
        if args.original_dir:
            original = (args.original_dir / f'{kind}.xlsx').read_bytes()
            with zipfile.ZipFile(args.original_dir / f'{kind}.xlsx') as book:
                xml = ElementTree.fromstring(book.read('xl/workbook.xml'))
                sheets = [node.attrib['name'] for node in xml.iter() if node.tag.endswith('}sheet')]
            sheet = next(name for name in sheets if name.startswith('各站'))
            result['workbook'] = {'sheet': sheet, 'data': base64.b64encode(original).decode('ascii'),
                                  'repeat_row': 20 if kind == 'heat' else 33}
        (args.output / f'{kind}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        print(f'{kind}: {len(result["input_columns"])} meters; {result["columns"]} columns')
