import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

const [report, html, evidence, dest] = process.argv.slice(2);
if (!dest) throw Error('Usage: node build.mjs <KS report folder> <庄河HTML> <KS_HELP/output> <destination>');
const read = p => fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '');
const json = p => JSON.parse(read(p));
const input = json(path.join(report, '实际推送映射.json'));
const source = fs.readFileSync(path.join(report, 'KS实时推送_31站区37项_张屯正向电能.txt'));
assert.equal(createHash('sha256').update(source).digest('hex'), input.sha256);
const model = {};
for (const f of ['config/station-directory.js', 'pages/energy-report/model.js']) {
  vm.runInNewContext(read(path.join(html, f)), model);
}
const displayed = model.HuanhaiEnergyReportModel.displayColumns.filter(c => c.kind !== 'text');
const directory = new Map(model.HuanhaiStationDirectory.map(r => [r[0],r]));
const defaults = json('app/test/fixtures/overview_reference_columns.json');
assert.equal(displayed.length, 31);
assert.deepEqual(input.columns.map(c=>c.key), Array.from(model.HuanhaiEnergyReportModel.stationColumns,c=>c.key));
const columns = Array.from(displayed, (c,i) => {
  assert.equal(c.label, defaults[i].name);
  assert.equal(c.unit, defaults[i].unit);
  return {...defaults[i], id:'zh-m'+(i+1)};
});
const latest = json(path.resolve(evidence,'../outputs/01a19edc_1103_KS_KIO/最新导出/工作数据.json'));
const tags = new Map();
for (const [ks, kio, status] of latest.catalog) {
  if (status !== '已核实' || !ks || !kio) continue;
  assert.ok(!tags.has(ks), 'duplicate KS path: '+ks);
  tags.set(ks,kio);
}
const reference = json('tools/picx_restore_1103/seed.json').source_map['kingio-confirmed'];
const audit = [];
function resolve(station, key, ks, pos) {
  const tag = tags.get(ks);
  assert.ok(!ks || tag, 'Missing verified KS→KIO target: '+ks);
  audit.push({station,key,position:pos,ks,kio:tag??null,basis:ks?'最新 KS XML IOAccess + KIO CSV':'KS 空槽'});
  return tag ? {source_id:reference,source_path:tag} : undefined;
}
const rows = input.rows.map(row=>{
  const [,site,name,area] = directory.get(row.station);
  assert.equal(row.values.length,37);
  const bindings = {};
  displayed.forEach((c,j)=>{
    const pos=input.columns.findIndex(x=>x.key===c.key);
    assert.ok(pos>=0);
    const ref=resolve(row.station,c.key,row.values[pos],pos+1);
    if (ref) bindings[columns[j].id]=ref;
  });
  return {id:'zh-'+createHash('sha256').update(row.station).digest('hex').slice(0,16),site,name,area,station:row.station,bindings};
});
assert.equal(rows.length,31);
const outdoor = {point_id:resolve('表头','室外温度',input.outdoor,null)};
assert.ok(rows.find(r=>r.station==='张屯换热站').bindings['zh-m31'].source_path.includes('正向'));
const file = {format:'universal-hmi-live-overview',version:1,columns,rows,outdoor};
fs.mkdirSync(dest,{recursive:true});
for(const [name,data] of [['庄河总览配置',file],['总览逐格核对',audit]]) {
  fs.writeFileSync(path.join(dest,name+'.json'),JSON.stringify(data,null,2)+'\n');
}
console.log({rows:rows.length,columns:columns.length,refs:audit.filter(x=>x.kio).length,
  nulls:audit.filter(x=>!x.ks).length,unresolved:audit.filter(x=>x.ks&&!x.kio).length,outdoor});
