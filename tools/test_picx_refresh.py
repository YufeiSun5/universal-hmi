import unittest
import picx_refresh as p
from pathlib import Path


def cstring(text):
    raw=text.encode('utf-16le')
    n=len(raw)//2
    size=bytes([n]) if n<255 else b'\xff'+n.to_bytes(2,'little')
    return b'\xff\xfe\xff'+size+raw


class PICXRefreshTest(unittest.TestCase):
    def test_native_string_lengths_and_truncation(self):
        for value in ['中文', '字'*300]:
            self.assertEqual(p.strings_from(cstring(value))[0]['text'],value)
        self.assertEqual(p.strings_from(cstring('中文')[:-1]),[])

    def test_title_and_script_are_not_bindings(self):
        ss=p.strings_from(cstring('Text1')+cstring('中心站东南区')+cstring('\\\\local\\A=1;')+cstring('####.##')+cstring('\\\\local\\A'))
        obj=p.objects_from(ss)[0]
        self.assertEqual([b['path'] for b in obj['bindings']],['\\\\local\\A'])
        self.assertTrue(obj['numeric'])

    def test_pump_number_is_a_label_not_numeric_format(self):
        ss = p.strings_from(cstring('Text570') + cstring('1#循环泵') + cstring(p.LOCAL+'泵频率'))
        self.assertFalse(p.objects_from(ss)[0]['numeric'])

    def test_center_has_distinct_branches_and_keeps_red_labels(self):
        from picx_center_layout import build_center
        obj = dict(object='Text570', numeric=False, bindings=[])
        rows = [(obj,'1#循环泵',[1011,473,89,25])]
        templates = Path(__file__).resolve().parents[1]/'app/assets/process/templates'
        _, se, _, _ = build_center('中心站东南区','中心站流程1',rows,templates)
        _, nw, _, _ = build_center('中心站西北区','中心站流程2',rows,templates)
        ns = {n['id']:n for n in se['nodes']}
        self.assertEqual(ns['secondary-east']['points'][0],ns['secondary-south']['points'][0])
        self.assertEqual(ns['secondary-east']['points'][-1]['y'],100)
        self.assertEqual(ns['secondary-south']['points'][-1]['y'],260)
        self.assertEqual(ns['native-label-Text570']['text'],'1#循环泵')
        self.assertEqual(ns['native-label-Text570']['color'],'#CF2424')
        self.assertNotIn('south-meter',{n['id'] for n in nw['nodes']})

    def test_reference_is_not_resolved_by_menu_station(self):
        self.assertIsNotNone(p.REFERENCE.search('\\\\local\\引用1.液位'))
        self.assertIsNotNone(p.REFERENCE.search('\\\\local\\引用模型1.循环2运行'))
        self.assertIsNone(p.REFERENCE.search('\\\\local\\中心站一区水箱水位'))

    def test_commented_old_menu_is_not_active(self):
        code='// string[1] nodeNames={"old"};\nstring[1] nodeNames={"A"};string[1] pictureNames={"B"};'
        self.assertEqual(p.menu_pairs([dict(text=code)]),[('A','B')])

    def test_shared_picture_mapping_rejected(self):
        code='string[2] nodeNames={"A","B"};string[2] pictureNames={"P","P"};'
        with self.assertRaises(ValueError):
            p.menu_pairs([dict(text=code)])

    def test_visible_spelling_does_not_rewrite_source(self):
        path = p.LOCAL+'中洁能_测试_压力'
        obj = dict(object='Text529',numeric=True,bindings=[dict(path=path)],
                   strings=[dict(text='中洁能阀门')])
        _, doc, readings, _ = p.build_screen('测试站','测试画面',[obj],
            Path(__file__).resolve().parents[1]/'app/assets/process/templates')
        self.assertEqual(readings[0][0]['bindings'][0]['path'],path)
        self.assertTrue(all('中洁能' not in n.get('text','')+n.get('label','') for n in doc['nodes']))
        self.assertTrue(all(not n['point_id'] for n in doc['nodes']))
        self.assertEqual(doc['background']['color'],'#F0F3F5')
        self.assertEqual(doc['background']['end_color'],'#D5DEE5')


if __name__=='__main__':
    unittest.main()
