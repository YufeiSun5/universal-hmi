"""Center-station layout reviewed against the two supplied native screenshots.

Text/measurement locations come from PICX. Pipes follow the reviewed source
topology; equipment uses the existing application's licensed symbol catalog.
"""
import re
from picx_refresh import read, digest, text_node, display_text, ROLES, LOCAL


def build_center(station, picture, rows, templates):
    southeast = picture == '中心站流程1'
    base = read(templates/'heating-single-three.json')
    key = 'pic1103-'+digest(picture.encode())[:20]
    doc = dict(schema_version=1, id=key, revision=0, name=station+' · 工艺',
               station=station, width=1750, height=800,
               background=dict(type='linear', color='#F0F3F5', end_color='#D5DEE5', angle=45, opacity=1))
    nodes, audit = [], []
    symbols = {n['id']: n for n in base['nodes'] if n['kind'] == 'symbol'}

    def symbol(id, template, x, y, width=None, height=None):
        node = dict(symbols[template], id=id, x=x, y=y, point_id='')
        if width is not None:
            node.update(width=width, height=height)
        nodes.append(node)
        return node

    def pipe(id, coords, color):
        xs, ys = zip(*coords)
        node = text_node(id, '', min(xs), min(ys), max(xs)-min(xs), max(ys)-min(ys))
        node.update(kind='pipe', color=color, stroke_width=10,
                    points=[dict(x=x,y=y) for x,y in coords], pipe_style='cylinder',
                    pipe_rounded=True, pipe_bend_radius=8, orthogonal=True)
        nodes.append(node)

    # Source supply/return axes are 180/430. The native single circulation
    # symbol represents the group; three separate electrical reading pairs.
    red, blue, water = '#E2555D', '#537EC9', '#7E9199'
    hx_x, hx_y, hx_w, hx_h = 760, 124, 256, 384
    left, right = hx_x+55*.25, hx_x+969*.25
    pipe('primary-in', [(150,180),(left,180)], red)
    pipe('primary-return', [(110,430),(left,430)], blue)
    if southeast:
        pipe('secondary-common', [(right,180),(1380,180)], red)
        pipe('secondary-east', [(1380,180),(1380,100),(1550,100)], red)
        pipe('secondary-south', [(1380,180),(1380,260),(1550,260)], red)
    else:
        pipe('secondary-out', [(right,180),(1580,180)], red)
    pipe('secondary-return', [(right,430),(1580,430)], blue)
    # Existing tank drawing contacts are used so neither pipe terminates in
    # transparent asset margins. Separate relief branch remains on the return.
    tank_x, tank_y, tank_w, tank_h = 330, 665, 180, 135
    pipe('feed', [(110,714.25),(333,714.25)], water)
    pipe('makeup', [(507.5,773.125),(1270,773.125),(1270,430)], water)
    pipe('relief-branch', [(1340,430),(1340,690)], water)
    symbol('heat-exchanger','heat-exchanger',hx_x,hx_y,hx_w,hx_h)
    symbol('tank','tank',tank_x,tank_y,tank_w,tank_h)

    def inline(id, template, center, axis, kind):
        n = symbols[template]
        contact = {'valve':947/1254,'pump':1015/1254,'meter':950/1292}[kind]
        return symbol(id, template, center-n['width']/2, axis-contact*n['height'])

    inline('brand-valve','primary-valve',195 if southeast else 210,180,'valve')
    inline('primary-valve','primary-valve',690 if southeast else 715,180,'valve')
    inline('primary-return-valve','primary-return-valve',195,430,'valve')
    inline('feed-valve','feed-valve',195,714.25,'valve')
    inline('circulation-pump','circulation-pump',1135,430,'pump')
    inline('makeup-pump','makeup-pump',1135,773.125,'pump')
    inline('primary-meter','primary-meter',305 if southeast else 340,180,'meter')
    if southeast:
        inline('east-meter','secondary-meter',1435,100,'meter')
        inline('south-meter','secondary-meter',1435,260,'meter')
    else:
        inline('secondary-meter','secondary-meter',1295,180,'meter')
    inline('water-meter','water-meter',700,773.125,'meter')
    for id,x,axis in [('primary-strainer',550,180),('secondary-return-strainer',1420,430)]:
        n = text_node(id,'',x-25.5,axis-10.29,51,35.376289)
        n.update(kind='symbol',symbol='fuxa_6916cde53cad00f9',color='#376E96')
        nodes.append(n)
    # Retain the reviewed device contacts from the application's source assets.
    for id, x, axis in [('primary-pressure-sensor',420 if southeast else 430,180),
                        ('primary-downstream-sensor',600,180),
                        ('primary-return-sensor',285,430),
                        ('secondary-pressure-sensor',1190 if southeast else 1465,180),
                        ('secondary-return-sensor',1465,430),
                        ('pump-inlet-sensor',1000,430)]:
        symbol(id,id,x-400/1024*26,axis-1450/1536*39)
    for id,x,axis in [('primary-temperature-sensor',465,180),
                      ('primary-return-temperature-sensor',335,430),
                      ('secondary-temperature-sensor',1270 if southeast else 1515,180),
                      ('secondary-return-temperature-sensor',1515,430)]:
        symbol(id,id,x-463/1024*(49*2/3),axis-1498/1536*49)
    symbol('relief-valve','relief-valve',1298,537,84,126)

    for obj, text, box in rows:
        x,y,w,h = box
        if y >= 800 or text in ('参数设定','设备操作','Text'):
            continue
        if obj['numeric']:
            id = ROLES.get(obj['object'], 'native-'+obj['object'])
            # Native text widths vary with unit length; keep the original
            # instrument groups in aligned cells instead of staggered boxes.
            num = int(obj['object'][4:])
            cells = {108:245,528:245,529:400 if southeast else 410,530:400 if southeast else 410,
                     532:650 if southeast else 159,577:145,
                     533:255 if southeast else 283,534:255 if southeast else 283,
                     535:255 if southeast else 283,536:255 if southeast else 283,
                     538:645,539:645,540:1000 if southeast else 1007,541:1000 if southeast else 1007,
                     542:1110,543:1110,548:1460 if southeast else 1250,549:1460 if southeast else 1250,
                     550:1460 if southeast else 1250,551:1460 if southeast else 1250,
                     552:1220 if southeast else 1450,553:1220 if southeast else 1450,
                     554:1450,555:1450,558:1110,559:1110,560:1110,561:1110,
                     562:1300,563:1300,566:1450,567:1450,568:1450,569:1450}
            x = cells.get(num,x)
            w = 154 if num in (550,551,568,569) else max(96,w)
            node = text_node(id, '', x+6, y, w-8, h, 17)
            unit = re.sub(r'[#.]','',text)
            node.update(kind='value', label=display_text(' / '.join(b['path'].removeprefix(LOCAL) for b in obj['bindings'])),
                        show_unit=True, unit_override=unit, decimals=1)
            border = text_node(id+'-box','', x,y,w,h)
            border.update(kind='rect', color='#7BA6B9', fill='#F1F5F7')
            nodes.extend([border,node])
            if obj['bindings']:
                audit.append((obj,node))
        else:
            node = text_node('native-label-'+obj['object'], display_text(text),x,y,w+6,h,20 if h>=28 else 17)
            if text == '循环泵':
                node['y'] = 338
            if text == '泄压阀':
                node.update(x=1380,width=100)
            if text == '电量显示':
                node['x'] = 4
            if re.fullmatch(r'\d+#(?:循环|补水)泵',text):
                node['color']='#CF2424'
            nodes.append(node)
    doc['nodes'] = nodes
    return key, doc, audit, 'native-center-reviewed'
