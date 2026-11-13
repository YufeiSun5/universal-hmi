"""Read-only comparison of November 4 sources against the 1103n delivery."""
from pathlib import Path
import collections, csv, json, sys, zipfile, xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import picx_refresh as p

SRC = Path('D:/Users/SunYufei/Downloads/Downloads')
OLD = SRC.parent

def csvread(path):
    with path.open(encoding='gb18030', newline='') as f:
        rows = list(csv.DictReader(f))
    result = {r['TagName']: r for r in rows}
    assert len(result) == len(rows)
    assert all(None not in r for r in rows)
    return result

def xmlread(path):
    rows = [r.attrib for r in ET.parse(path).iter('Tag')]
    result = {r['TagName']: r for r in rows}
    assert len(result) == len(rows)
    return result

def main():
    for kind, old, new in [
        ('KIO', csvread(OLD/'kio变量1103n.csv'), csvread(SRC/'kio变量1104.csv')),
        ('KS', xmlread(OLD/'ks变量1103n.xml'), xmlread(SRC/'1104ks变量.xml')),
    ]:
        added, removed = new.keys()-old.keys(), old.keys()-new.keys()
        changed = {n:[k for k in new[n].keys()|old[n].keys() if new[n].get(k)!=old[n].get(k)] for n in new.keys()&old.keys() if new[n]!=old[n]}
        print(kind, 'old',len(old),'new',len(new),'added',len(added),'removed',len(removed),'changed',len(changed))
        print('added', sorted(added)); print('removed', sorted(removed))
        print('changed fields', dict(collections.Counter(k for fields in changed.values() for k in fields)))
        for n, fields in changed.items():
            if len(changed)<80: print(n,{k:[old[n].get(k),new[n].get(k)] for k in fields})
    with zipfile.ZipFile(OLD/'1103n.zip',metadata_encoding='gbk') as z:
        sys.path.insert(0, str(ROOT/'tools/picx_restore_1103'))
        from layout import make
        from arrows import apply
        from spacing import place
        menu=p.menu_pairs(p.strings_from((SRC/'1104画面/工艺图菜单.picx').read_bytes()))
        omenu=p.menu_pairs(p.strings_from(z.read('1103n/工艺图菜单.picx')))
        print('MENU',len(menu),'same',menu==omenu)
        changes=[]
        for st,pic in menu:
            before=z.read('1103n/'+pic+'.picx'); after=(SRC/'1104画面'/f'{pic}.picx').read_bytes()
            if before==after: continue
            def values(d):
                return {o['object']:[b['path'] for b in o['bindings']] for o in p.objects_from(p.strings_from(d)) if o['numeric']}
            a,b=values(before),values(after)
            changes.append(st)
            print('PIC',st,pic,len(before),len(after),'value changes',[(n,a.get(n),b.get(n)) for n in a.keys()|b.keys() if a.get(n)!=b.get(n)])
            if '--layout' in sys.argv:
                def doc(d):
                    _, value, _, _ = make(st,pic,d)
                    apply(value); place(value)
                    return value
                aa,bb=doc(before),doc(after)
                an,bn=({n['id']:n for n in dd['nodes']} for dd in (aa,bb))
                print('LAYOUT',st,'equal',aa==bb,'nodes',len(an),len(bn))
                for n in sorted(an.keys()|bn.keys()):
                    if an.get(n)!=bn.get(n):
                        print(n, {k:[str(an.get(n,{}).get(k))[:140],str(bn.get(n,{}).get(k))[:140]] for k in an.get(n,{}).keys()|bn.get(n,{}).keys() if an.get(n,{}).get(k)!=bn.get(n,{}).get(k)})
        print('Changed process source files',len(changes),changes)
        newfiles={n.name for n in (SRC/'1104画面').glob('*.picx')}
        oldfiles={Path(n).name for n in z.namelist() if n.endswith('.picx')}
        print('Added PICX',sorted(newfiles-oldfiles),'Removed PICX',sorted(oldfiles-newfiles))
        print('Other modified PICX',[n for n in sorted(newfiles&oldfiles) if n not in {pic+'.picx' for _,pic in menu} and (SRC/'1104画面'/n).read_bytes()!=z.read('1103n/'+n)])

if __name__=='__main__': main()
