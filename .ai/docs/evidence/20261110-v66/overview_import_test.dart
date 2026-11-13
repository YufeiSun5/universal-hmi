import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/transfer.dart';
import 'package:universal_hmi/shared/api.dart';
void main(){test('final 1110 dual valve file actual decode/merge/repeat/rollback preserves custom content',(){
 const root='D:/DEV_D/KPimport';
 final metadata=jsonDecode(File('$root/.local/process-update-v66/import-result.json').readAsStringSync()) as Json;
 final points=objects(jsonDecode(File('${metadata['fixture']}/points.json').readAsStringSync()));
 final definitions={for(final p in points) p['id'] as String:p};
 final incoming=OverviewImport.decode(File('$root/outputs/庄河1110更新包/03-数据总览配置.json').readAsBytesSync(),definitions);
 final previous=OverviewImport.decode(File('$root/outputs/庄河1110更新包/回退/02-恢复1110前总览.json').readAsBytesSync(),definitions);
 expect(incoming.missing,isEmpty);expect(incoming.columns.length,32);expect(incoming.rows.length,31);
 final oldColumns=[...previous.columns, <String,dynamic>{'id':'custom','group':'自定义','name':'保留','unit':'','decimals':1}];
 final oldRows=objects(jsonDecode(jsonEncode(previous.rows)));
 (oldRows.first['bindings'] as Map)['custom']=points.first['id'];
 oldRows.add({'id':'unrelated','station':'不相关站区','name':'自定义','site':'自定义','area':'自定义','bindings':{'custom':points.first['id']}});
 final merged=incoming.merge(oldColumns,oldRows,incoming.rows);
 expect(merged.columns.map((c)=>c['id']).toList().sublist(9,11),['zh-m10','zh-local-valve']);
 expect(merged.columns.last,oldColumns.last);expect(merged.rows.last,oldRows.last);expect((merged.rows.first['bindings'] as Map)['custom'],points.first['id']);
 expect(merged.rows.take(31).where((r)=>(r['bindings'] as Map).containsKey('zh-m10')).length,20);
 expect(merged.rows.take(31).map((r)=>(r['bindings'] as Map)['zh-local-valve']).toSet().length,31);
 final repeat=incoming.merge(merged.columns,merged.rows,incoming.rows);
 expect(jsonEncode(repeat.columns),jsonEncode(merged.columns));expect(jsonEncode(repeat.rows),jsonEncode(merged.rows));
 // The documented rollback first removes this batch's one new column, then
 // imports the old standard content, retaining unrelated user content.
 final rollback=previous.merge(merged.columns.where((c)=>c['id']!='zh-local-valve').toList(),objects(jsonDecode(jsonEncode(merged.rows))),previous.rows);
 for(final r in rollback.rows){(r['bindings'] as Map).remove('zh-local-valve');r.remove('control');}
 expect(rollback.columns,oldColumns);expect(rollback.rows,oldRows);
 });}
