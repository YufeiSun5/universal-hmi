"""Editable heating reference, matching the user's 1574x674 process layout.
No bindings, simulated readings, or running-state claims; arrows are static.
"""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
nodes = []
CYAN, BG = '#40baff', '#162f45'


def node(kind, identity, x, y, width, height, **fields):
    item = dict(id=identity, kind=kind, x=x, y=y, width=width, height=height,
                color=CYAN, fill='none', stroke_width=1, font_size=18,
                point_id='', text='', label='', show_unit=True, decimals=1,
                rotation=0, points=[], arrow=False)
    item.update(fields)
    nodes.append(item)
    return item


def label(identity, x, y, text, width=150, size=20, color=CYAN):
    return node('text', identity, x, y, width, 27, text=text, font_size=size, color=color)


def pipe(identity, points, color, **fields):
    xs, ys = zip(*points)
    return node('pipe', identity, min(xs), min(ys), max(xs)-min(xs), max(ys)-min(ys),
                color=color, stroke_width=11, pipe_style='cylinder', pipe_rounded=True,
                pipe_bend_radius=10, orthogonal=True, arrow=True, arrow_mode='count',
                arrow_count=fields.pop('arrow_count', 2), arrow_animate=False,
                points=[dict(x=x, y=y) for x, y in points], **fields)


def value(identity, x, y, text, unit, width=96, decimals=1):
    # Instrument names are in tooltips and the readable variable table.
    node('rect', identity+'-box', x, y, width, 23, color='#26d6df', fill=BG)
    node('value', identity, x+6, y, width-12, 23, label=text, unit_override=unit,
         color='#ede94b', font_size=16, decimals=decimals)


def symbol(identity, key, x, y, w, h, title):
    node('symbol', identity, x, y, w, h, symbol=key, label=title)


def sensor(identity, center, line):
    h = 39
    symbol(identity, 'monitor_pressure_v2', center-400/1536*h,
           line-1450/1536*h, h*1024/1536, h, '压力变送器')


def thermometer(identity, center, line):
    h = 49
    symbol(identity, 'monitor_temperature', center-463/1536*h,
           line-1498/1536*h, h*1024/1536, h, '电子温度表')


node('rect', 'monitor-backdrop', 0, 0, 1574, 674, color=BG, fill=BG)
# Reviewed PNG contacts; shared with symbol_geometry.dart.
scale = 230/1000
hx_x, hx_y = 664, 100-224*scale
left, right, top, bottom = hx_x+55*scale, hx_x+969*scale, 100, 330
red, blue, steel = '#ec555e', '#6267ef', '#aeb9c2'
pipe('primary-in', [(126, top), (left, top)], red, end_node='heat-exchanger', end_port='left_top')
pipe('secondary-out', [(right, top), (1450, top)], red, start_node='heat-exchanger', start_port='right_top')
pipe('primary-out', [(left, bottom), (84, bottom)], blue, start_node='heat-exchanger', start_port='left_bottom')
pipe('secondary-in', [(1450, bottom), (right, bottom)], '#9aa7d9', end_node='heat-exchanger', end_port='right_bottom')
pipe('makeup-feed', [(84, 578), (303, 578)], steel, end_node='tank', end_port='left')
pipe('makeup-discharge', [(476.5, 636.5), (1160, 636.5), (1160, bottom)], steel,
     start_node='tank', start_port='right', end_node='secondary-in', end_port=f'path:{290/(1450-right):.12f}', arrow_count=3)
pipe('relief-branch', [(1222, bottom), (1222, 568), (1282.1875, 568), (1282.1875, 543.2)], steel,
     start_node='secondary-in', start_port=f'path:{228/(1450-right):.12f}',
     end_node='relief-valve', end_port='bottom', arrow_count=1)
pipe('relief-discharge', [(1315.59, 510.24), (1360, 510.24), (1360, 586)], steel,
     start_node='relief-valve', start_port='right', arrow_count=1)
symbol('heat-exchanger', 'monitor_hx_v2', hx_x, hx_y, 1024*scale, 1536*scale, '板式换热器')
symbol('tank', 'monitor_tank_v2', 300, 529, 180, 135, '不锈钢拼装补水箱')
for identity, x, line, title in [('primary-valve', 223, top, '一次调节阀'),
                                  ('primary-return-valve', 133, bottom, '一次回水阀'),
                                  ('feed-valve', 140, 578, '补水进水阀')]:
    symbol(identity, 'monitor_valve', x, line-947/1254*65, 65, 65, title)
for identity, x, line, title in [('circulation-pump', 1000, bottom, '循环泵'),
                                  ('makeup-pump', 1000, 636.5, '补水泵')]:
    symbol(identity, 'monitor_pump', x, line-1015/1254*75, 75, 75, title)
for identity, x, line in [('primary-meter', 564, top), ('secondary-meter', 1156, top), ('water-meter', 600, 636.5)]:
    h = 58
    symbol(identity, 'monitor_flow_meter', x, line-950/1292*h, h*1218/1292, h, '电磁流量计')
for identity, x, line in [('primary-pressure-sensor', 389, top), ('primary-downstream-sensor', 518, top),
                         ('primary-return-sensor', 289, bottom), ('secondary-pressure-sensor', 1380, top),
                         ('secondary-return-sensor', 1380, bottom), ('pump-inlet-sensor', 912, bottom)]:
    sensor(identity, x, line)
for identity, x, line in [('primary-temperature-sensor', 352, top), ('primary-return-temperature-sensor', 246, bottom),
                         ('secondary-temperature-sensor', 1340, top), ('secondary-return-temperature-sensor', 1340, bottom)]:
    thermometer(identity, x, line)
symbol('relief-valve', 'monitor_relief', 1240, 414, 90, 135, '弹簧式泄压阀')
for args in [('primary-in-label', 0, 82, '一次网供水', 120), ('primary-out-label', 6, 292, '一次网回水', 122),
             ('secondary-out-label', 1454, 82, '二次网供水', 120), ('secondary-in-label', 1454, 316, '二次网回水', 120),
             ('valve-name', 236, 24, '调节阀', 100, 17), ('circulation-name', 992, 242, '循环泵', 120, 21),
             ('makeup-name', 980, 537, '补水泵', 120, 21), ('relief-label', 1238, 387, '泄压阀', 130),
             ('water-label', 0, 560, '自来水', 80), ('energy-label', 18, 15, '累计电量', 90, 14, '#bcd0de')]:
    label(*args)
for args in [
    ('energy-total', 110, 16, '累计电量', 'kWh', 130),
    ('valve-opening', 210, 117, '阀门开度', '%'),
    ('primary-temperature', 325, 117, '一次供水温度', '°C'),
    ('primary-pressure', 325, 140, '一次供水压力', 'MPa', 96, 3),
    ('primary-downstream-pressure', 438, 140, '阀后压力', 'MPa', 96, 3),
    ('primary-flow', 542, 117, '一次瞬时流量', 't/h'),
    ('primary-heat', 542, 140, '一次瞬时热量', 'GJ/h'),
    ('primary-flow-total', 542, 163, '一次累计流量', 't', 148),
    ('primary-heat-total', 542, 186, '一次累计热量', 'GJ', 148),
    ('secondary-flow', 1142, 117, '二次瞬时流量', 't/h'),
    ('secondary-heat', 1142, 140, '二次瞬时热量', 'GJ/h'),
    ('secondary-flow-total', 1142, 163, '二次累计流量', 't', 148),
    ('secondary-heat-total', 1142, 186, '二次累计热量', 'GJ', 148),
    ('secondary-temperature', 1324, 117, '二次供水温度', '°C'),
    ('secondary-pressure', 1324, 140, '二次供水压力', 'MPa', 96, 3),
    ('return-temperature', 216, 346, '一次回水温度', '°C'),
    ('return-pressure', 216, 369, '一次回水压力', 'MPa', 96, 3),
    ('pump-inlet-pressure', 873, 345, '循环泵入口压力', 'MPa', 96, 3),
    ('circulation-frequency', 986, 350, '循环泵频率', 'Hz'),
    ('circulation-current', 986, 373, '循环泵电流', 'A'),
    ('secondary-return-temperature', 1324, 346, '二次回水温度', '°C'),
    ('secondary-return-pressure', 1324, 369, '二次回水压力', 'MPa', 96, 3),
    ('tank-level', 330, 503, '水箱液位', 'mm', 96, 0),
    ('makeup-flow', 584, 534, '补水流量', 't/h'),
    ('makeup-total', 584, 557, '累计补水', 't'),
    ('makeup-frequency', 1080, 568, '补水泵频率', 'Hz'),
    ('makeup-current', 1080, 591, '补水泵电流', 'A')]:
    value(*args)
# Pipes reach the visible bore centers in front of the flange faces. This is
# ordinary editor stacking order, retained by save/reopen and move/resize.
back = ['monitor-backdrop', 'heat-exchanger', 'tank']
nodes = [next(n for n in nodes if n['id'] == key) for key in back] + [n for n in nodes if n['id'] not in back]
document = dict(schema_version=1, id='reference-heating-monitor', revision=0,
                name='换热站工艺流程', station='', width=1574, height=674, nodes=nodes, assets={})
for n in nodes:
    assert n['x'] >= 0 and n['y'] >= 0 and n['x']+n['width'] <= 1574 and n['y']+n['height'] <= 674, n['id']
path = ROOT / 'app/assets/process/templates/heating-monitor.json'
path.write_text(json.dumps(document, ensure_ascii=False, indent=2)+'\n', encoding='utf-8', newline='\n')
print(f'Wrote {len(nodes)} elements; {sum(n["kind"] == "value" for n in nodes)} unbound values')
