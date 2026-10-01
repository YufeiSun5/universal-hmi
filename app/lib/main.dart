import 'dart:async';
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features/editors.dart';
import 'features/trend.dart';
import 'platform/save.dart';
import 'shared/api.dart';
import 'shared/table.dart';
import 'shared/theme.dart';

void main()=>runApp(const UniversalHmiApp());
Uri defaultApi(){
 const configured=String.fromEnvironment('API_BASE_URL');
 return configured.isNotEmpty?Uri.parse(configured):kIsWeb?Uri.base:Uri.parse('http://127.0.0.1:18080');
}
class UniversalHmiApp extends StatefulWidget{
 const UniversalHmiApp({super.key,this.api});
 final PlatformApi? api;
 @override State<UniversalHmiApp> createState()=>_UniversalHmiAppState();
}
class _UniversalHmiAppState extends State<UniversalHmiApp>{
 bool dark=true;
 late final PlatformApi api=widget.api??PlatformClient(defaultApi());
 @override void dispose(){api.close();super.dispose();}
 @override Widget build(BuildContext context)=>MaterialApp(title:'Universal HMI',debugShowCheckedModeBanner:false,
  theme:workspaceTheme(false),darkTheme:workspaceTheme(true),themeMode:dark?ThemeMode.dark:ThemeMode.light,
  home:Workspace(api:api,dark:dark,onTheme:()=>setState(()=>dark=!dark)));
}
const pages=['点位管理','实时趋势','条件事件','独立存储','分析与报表','采集来源'];
const pageIcons=[Icons.tune,Icons.show_chart,Icons.bolt_outlined,Icons.storage_outlined,Icons.table_chart_outlined,Icons.router_outlined];
class Workspace extends StatefulWidget{
 const Workspace({super.key,required this.api,required this.dark,required this.onTheme});
 final PlatformApi api;
 final bool dark;
 final VoidCallback onTheme;
 @override State<Workspace> createState()=>_WorkspaceState();
}
class _WorkspaceState extends State<Workspace>{
 final search=TextEditingController(),searchFocus=FocusNode();
 final min=TextEditingController(),max=TextEditingController(),from=TextEditingController(),to=TextEditingController();
 Timer? timer;
 List<Json> points=[],history=[],jobs=[],logs=[],buffer=[];
 Json runtime={},stats={};
 String station='',query='',selectedID='',quality='',historyPoint='';
 int page=0,offset=0,boundary=0;
 bool online=false,busy=false,polling=false,draft=false;
 double treeWidth=218,inspectorWidth=278;
 String? error;
 final selected=<String>{};
 int lastJobs=0;
 @override void initState(){super.initState();_load();_restore();timer=Timer.periodic(const Duration(milliseconds:700),(_)=>_poll());}
 Future<void> _restore()async{
  try{final prefs=await SharedPreferences.getInstance();if(!mounted)return;setState((){treeWidth=(prefs.getDouble('treeWidth')??218).clamp(150,340);inspectorWidth=(prefs.getDouble('inspectorWidth')??278).clamp(230,400);});}catch(_){}
 }
 Future<void> _persist()async{try{final p=await SharedPreferences.getInstance();await p.setDouble('treeWidth',treeWidth);await p.setDouble('inspectorWidth',inspectorWidth);}catch(_){}}
 @override void dispose(){timer?.cancel();for(final c in [search,min,max,from,to]){c.dispose();}searchFocus.dispose();super.dispose();}
 List<Json> get sources=>objects(runtime['sources']);
 List<Json> get rules=>objects(runtime['rules']);
 Json get policy=>Map<String,dynamic>.from(runtime['policy'] as Map? ??{});
 List<Json> get values=>objects(runtime['values']);
 Map<String,Json> get live=>{for(final r in values)r['point_id'].toString():r};
 List<Json> get visible=>points.where((p)=>(station.isEmpty||p['station']==station)&&
  (p['station'].toString()+' '+p['name'].toString()+' '+p['unit'].toString()).toLowerCase().contains(query.toLowerCase())).toList();
 Json? get current{
  for(final p in points){if(p['id']==selectedID)return p;}return null;
 }
 void acceptRuntime(Json data){
  runtime=data;online=true;
  final ids=selected.isNotEmpty?selected:points.where((p)=>p['source_type']!='virtual'&&! (p['writable']==true)).take(2).map((p)=>p['id'].toString()).toSet();
  final last=<String,String>{};for(final r in buffer){last[r['point_id'].toString()]=r['source_time'].toString();}
  for(final r in objects(data['values'])){final id=r['point_id'].toString();if(ids.contains(id)&&r['value'] is num&&last[id]!=r['source_time'])buffer.add(r);}
  final cutoff=DateTime.now().subtract(const Duration(minutes:3));
  buffer=buffer.where((r)=>ids.contains(r['point_id'])&&(DateTime.tryParse(r['source_time'].toString())?.isAfter(cutoff)??false)).toList();
  if(buffer.length>1800)buffer=buffer.sublist(buffer.length-1800);
 }
 Future<void> _load()async{
  try{
   final result=await Future.wait([widget.api.request('GET','/api/v1/points'),widget.api.request('GET','/api/v1/runtime'),widget.api.request('GET','/api/v1/jobs')]);
   if(!mounted)return;setState((){points=objects(result[0]['items']);acceptRuntime(result[1]);jobs=objects(result[2]['items']);error=null;});
  }catch(e){if(mounted)setState((){online=false;error=e.toString();});}
 }
 Future<void> _poll()async{
  if(polling)return;polling=true;
  try{final data=await widget.api.request('GET','/api/v1/runtime');if(!mounted)return;setState(()=>acceptRuntime(data));
   if(page==4&&DateTime.now().millisecondsSinceEpoch-lastJobs>2500){lastJobs=DateTime.now().millisecondsSinceEpoch;final j=await widget.api.request('GET','/api/v1/jobs');if(mounted)setState(()=>jobs=objects(j['items']));}
  }catch(_){if(mounted)setState(()=>online=false);}finally{polling=false;}
 }
 Future<void> act(Future<void> Function() work,{String? success})async{
  if(busy)return;setState((){busy=true;error=null;});
  try{await work();if(mounted&&success!=null)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(success),duration:const Duration(seconds:3)));}
  catch(e){if(mounted)setState(()=>error=e.toString());}
  finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> add({Json? existing})async{
  if(busy)return;
  final result=await pointEditor(context,widget.api,points,existing:existing,station:station.isEmpty?null:station);
  if(result!=null){setState(()=>draft=true);await _load();}
 }
 Future<void> apply()async=>act(()async{await widget.api.request('POST','/api/v1/apply');setState(()=>draft=false);await _load();},success:'运行配置已应用');
 Future<void> demo()async=>act(()async{
  await widget.api.request('POST','/api/v1/demo',body:{'enabled':runtime['demo']!=true});
  await _load();
 },success:runtime['demo']==true?'模拟采集已停止':'30 个模拟站点已启动');
 Future<void> changeStorage(bool enabled)async=>act(()async{
  final p=policy;p['enabled']=enabled;await widget.api.request('PUT','/api/v1/storage',body:p);await _poll();
 },success:enabled?'独立存储已启动':'独立存储已停止');
 Future<void> writePoint(Json p)async{
  final value=await inputValue(context,p['writable']==true?'下设工程值 · '+p['name'].toString():'输入原始值 · '+p['name'].toString(),initial:number(live[p['id']]?['value']));
  if(value==null||!mounted)return;
  await act(()async{
   Json result;
   if(p['writable']==true){
    final n=double.tryParse(value);if(n==null||!n.isFinite)throw Exception('请输入有限数字');
    result=await widget.api.request('POST','/api/v1/write',body:{'command_id':'ui-'+DateTime.now().microsecondsSinceEpoch.toString(),'point_id':p['id'],'value':n,'version':runtime['version']});
   }else{
    Object data=value;if(p['data_type']=='BOOL'){if(value!='true'&&value!='false')throw Exception('请输入 true 或 false');data=value=='true';}
    else if(p['data_type']!='STRING'){final n=double.tryParse(value);if(n==null||!n.isFinite)throw Exception('请输入有限数字');data=n;}
    result=await widget.api.request('POST','/api/v1/points/'+p['id'].toString()+'/sample',body:{'value':data});
   }
   if(mounted){await showDialog<void>(context:context,builder:(c)=>AlertDialog(title:Text(stateLabel(result['state']?.toString()??'accepted')),content:SelectableText((result['message']??'手工值已提交').toString()),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('关闭'))]));}
   await _poll();
  });
 }
 Future<void> pointMenu(int index,Offset location,List<Json> rows)async{
  final p=rows[index];setState(()=>selectedID=p['id'].toString());
  final action=await showMenu<String>(context:context,position:RelativeRect.fromLTRB(location.dx,location.dy,location.dx,location.dy),
   items:[const PopupMenuItem(value:'edit',child:Text('编辑点位')),if(p['writable']==true||p['source_type']=='manual')const PopupMenuItem(value:'write',child:Text('输入／下设数据')),
    const PopupMenuItem(value:'history',child:Text('查询点位历史')),const PopupMenuItem(value:'delete',child:Text('删除配置'))]);
  if(!mounted)return;
  if(action=='edit')await add(existing:p);
  if(action=='write')await writePoint(p);
  if(action=='history'){setState((){historyPoint=p['id'].toString();page=3;});await queryHistory(reset:true);}
  if(action=='delete')await act(()async{await widget.api.request('DELETE','/api/v1/points/'+p['id'].toString());setState(()=>draft=true);await _load();});
 }
 Json filterQuery({bool includePage=true}){
  final q=<String,dynamic>{if(station.isNotEmpty)'station':station,if(historyPoint.isNotEmpty)'point_id':historyPoint,if(quality.isNotEmpty)'quality':quality,
   if(min.text.trim().isNotEmpty)'min':min.text.trim(),if(max.text.trim().isNotEmpty)'max':max.text.trim()};
  for(final entry in {'from':from,'to':to}.entries){if(entry.value.text.trim().isNotEmpty){
   final date=DateTime.tryParse(entry.value.text.trim());if(date==null)throw Exception('请输入 ISO 时间');q[entry.key]=date.toUtc().millisecondsSinceEpoch;
  }}
  if(boundary>0)q['before']=boundary;
  if(includePage){q['offset']=offset;q['limit']=1000;}
  return q;
 }
 Future<void> queryHistory({bool reset=false})async=>act(()async{
  if(reset){offset=0;boundary=0;}
  final result=await widget.api.request('GET','/api/v1/history',query:filterQuery());
  setState((){history=objects(result['items']);stats=Map<String,dynamic>.from(result['stats'] as Map);boundary=(result['boundary'] as num).toInt();});
 });
 Future<void> export(String format)async=>act(()async{
  final q=filterQuery(includePage:false);q['format']=format;await widget.api.request('POST','/api/v1/export',query:q);await _load();
 },success:'报表任务已排队');
 Future<void> upload()async=>act(()async{
  final file=await openFile(acceptedTypeGroups:[const XTypeGroup(label:'数据文件',extensions:['xlsx','csv'])]);
  if(file==null)return;
  if(await file.length()>8*1024*1024)throw Exception('文件上限 8 MiB，请缩小数据范围');
  final result=await widget.api.upload(file.name,await file.readAsBytes());if(!mounted)return;
  final imported=await importEditor(context,widget.api,result);
  if(imported is Map&&mounted){setState((){historyPoint=imported['point_id'].toString();station=imported['station'].toString();page=4;boundary=0;offset=0;});}
 });
 Future<void> commandPalette()async{
  final choice=await showDialog<int>(context:context,builder:(context)=>SimpleDialog(title:const Text('切换工作区'),
   children:List.generate(pages.length,(i)=>SimpleDialogOption(onPressed:()=>Navigator.pop(context,i),child:Row(children:[Icon(pageIcons[i],size:18),const SizedBox(width:12),Text(pages[i])])))));
  if(choice!=null&&mounted)setState(()=>page=choice);
 }
 Widget split(ValueChanged<double> onDelta,VoidCallback onEnd)=>MouseRegion(cursor:SystemMouseCursors.resizeColumn,child:GestureDetector(
  behavior:HitTestBehavior.opaque,onHorizontalDragUpdate:(d)=>onDelta(d.delta.dx),onHorizontalDragEnd:(_)=>onEnd(),
  child:const SizedBox(width:5,child:VerticalDivider(width:1))));
 @override Widget build(BuildContext context){
  final c=Theme.of(context).colorScheme;
  final actions=<ShortcutActivator,VoidCallback>{
   const SingleActivator(LogicalKeyboardKey.keyP,control:true):commandPalette,
   const SingleActivator(LogicalKeyboardKey.keyN,control:true):add,
   const SingleActivator(LogicalKeyboardKey.enter,control:true):apply,
   const SingleActivator(LogicalKeyboardKey.keyF,control:true):searchFocus.requestFocus,
   const SingleActivator(LogicalKeyboardKey.keyP,meta:true):commandPalette,
  };
  return CallbackShortcuts(bindings:actions,child:Focus(autofocus:true,child:Scaffold(body:Column(children:[
   Container(height:44,padding:const EdgeInsets.symmetric(horizontal:14),color:c.surfaceContainerLow,child:Row(children:[
    Icon(Icons.hexagon_outlined,size:21,color:c.primary),const SizedBox(width:9),const Text('Universal HMI',style:TextStyle(fontWeight:FontWeight.w600)),
    const SizedBox(width:18),Expanded(child:Text('通用临时上位机平台',overflow:TextOverflow.ellipsis,style:TextStyle(color:c.onSurfaceVariant,fontSize:12))),
    TextButton.icon(onPressed:commandPalette,icon:const Icon(Icons.search,size:16),label:const Text('工作区  Ctrl+P')),
    IconButton(tooltip:widget.dark?'浅色主题':'深色主题',onPressed:widget.onTheme,icon:Icon(widget.dark?Icons.light_mode_outlined:Icons.dark_mode_outlined,size:18))
   ])),const Divider(),
   Expanded(child:LayoutBuilder(builder:(context,box)=>Row(children:[
    Container(width:58,color:c.surfaceContainerLow,child:Column(children:[
     const SizedBox(height:8),...List.generate(pages.length,(i)=>Padding(padding:const EdgeInsets.symmetric(vertical:4),child:IconButton(
      key:Key('nav-$i'),tooltip:pages[i],isSelected:page==i,style:IconButton.styleFrom(backgroundColor:page==i?c.primary.withValues(alpha:.13):null),
      onPressed:()=>setState(()=>page=i),icon:Icon(pageIcons[i],size:21)))),
     const Spacer(),IconButton(tooltip:runtime['demo']==true?'停止模拟采集':'启动 30 站模拟工程',onPressed:busy||!online?null:demo,icon:Icon(runtime['demo']==true?Icons.stop_circle_outlined:Icons.science_outlined))
    ])),
    if(box.maxWidth>850)...[SizedBox(width:treeWidth,child:tree()),split((d)=>setState(()=>treeWidth=(treeWidth+d).clamp(150,340)),_persist)],
    Expanded(child:Column(children:[
     Container(height:38,padding:const EdgeInsets.symmetric(horizontal:14),decoration:BoxDecoration(border:Border(bottom:BorderSide(color:c.outlineVariant))),
      child:Row(children:[Icon(pageIcons[page],size:15,color:c.primary),const SizedBox(width:8),Text(pages[page],style:const TextStyle(fontWeight:FontWeight.w600)),
       const Spacer(),if(draft)const Text('有未应用配置',style:TextStyle(fontSize:11,color:Color(0xffd5aa61))),
       const SizedBox(width:8),IconButton(tooltip:'刷新',onPressed:busy?null:_load,icon:const Icon(Icons.refresh,size:17))])),
     if(error!=null)Container(width:double.infinity,color:c.errorContainer.withValues(alpha:.35),padding:const EdgeInsets.fromLTRB(12,5,6,5),
      child:Row(children:[Icon(Icons.error_outline,size:16,color:c.error),const SizedBox(width:8),Expanded(child:SelectableText(error!,style:TextStyle(fontSize:12,color:c.error))),IconButton(onPressed:()=>setState(()=>error=null),icon:const Icon(Icons.close,size:15))])),
     if(busy)const LinearProgressIndicator(minHeight:2),
     Expanded(child:Padding(padding:const EdgeInsets.all(12),child:switch(page){0=>pointWorkspace(),1=>trendWorkspace(),2=>eventWorkspace(),3=>historyWorkspace(),4=>reportWorkspace(),_=>sourceWorkspace()}))
    ])),
    if(box.maxWidth>1150&&page<2)...[split((d)=>setState(()=>inspectorWidth=(inspectorWidth-d).clamp(230,400)),_persist),SizedBox(width:inspectorWidth,child:inspector())]
   ]))),
   Container(height:26,padding:const EdgeInsets.symmetric(horizontal:12),color:c.primary.withValues(alpha:.14),child:Row(children:[
    Icon(online?Icons.check_circle_outline:Icons.link_off,size:13,color:online?const Color(0xff47be97):c.error),const SizedBox(width:5),
    Text(online?'后端已连接':'后端离线',style:const TextStyle(fontSize:11)),const SizedBox(width:18),
    Text(points.length.toString()+' 点位 · '+points.map((p)=>p['station']).toSet().length.toString()+' 站',style:const TextStyle(fontSize:11)),
    const Spacer(),if(runtime['demo']==true)const Text('模拟采集  ',style:TextStyle(fontSize:11)),
    Text(policy['enabled']==true?'存储运行中':'存储未启动',style:const TextStyle(fontSize:11)),const SizedBox(width:12),
    if((runtime['storage_error']??'').toString().isNotEmpty)Text('存储错误',style:TextStyle(color:c.error,fontSize:11)),
    if((runtime['dropped'] as num? ??0)>0)Text('丢弃 '+runtime['dropped'].toString(),style:TextStyle(color:c.error,fontSize:11))
   ]))
  ]))));
 }
 Widget tree(){
  final c=Theme.of(context).colorScheme,stations=points.map((p)=>p['station'].toString()).toSet().toList()..sort();
  return ColoredBox(color:c.surfaceContainerLow,child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
   Padding(padding:const EdgeInsets.fromLTRB(14,14,8,10),child:Row(children:[Text('工程资源',style:TextStyle(fontSize:11,color:c.onSurfaceVariant,fontWeight:FontWeight.w600)),const Spacer(),
    IconButton(tooltip:'添加点位',onPressed:online?add:null,icon:const Icon(Icons.add,size:16))])),
   ListTile(dense:true,selected:station.isEmpty,leading:const Icon(Icons.account_tree_outlined,size:17),title:const Text('全部站点'),subtitle:Text(stations.length.toString()+' 个站点'),onTap:()=>setState(()=>station='')),
   const Divider(),Expanded(child:ListView.builder(itemCount:stations.length,itemBuilder:(context,i){
    final s=stations[i],count=points.where((p)=>p['station']==s).length;
    return ListTile(dense:true,selected:station==s,leading:Icon(Icons.memory,size:16,color:station==s?c.primary:c.onSurfaceVariant),
     title:Text(s,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:12)),trailing:Text('$count',style:TextStyle(fontSize:11,color:c.onSurfaceVariant)),onTap:()=>setState(()=>station=s));
   })),
   const Divider(),Padding(padding:const EdgeInsets.all(12),child:Text('本地工程\n后台采集不依赖工作区保持打开',style:TextStyle(fontSize:11,height:1.7,color:c.onSurfaceVariant)))
  ]));
 }
 Widget toolbar(List<Widget> children)=>SizedBox(height:42,child:SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:children.map((w)=>Padding(padding:const EdgeInsets.only(right:8),child:w)).toList())));
 Widget pointWorkspace(){
  final rows=visible,valuesByID=live;
  return Column(children:[
   toolbar([SizedBox(width:240,child:TextField(key:const Key('point-search'),controller:search,focusNode:searchFocus,decoration:const InputDecoration(hintText:'搜索点位／站点／单位',prefixIcon:Icon(Icons.search,size:17)),onChanged:(v)=>setState(()=>query=v))),
    FilledButton.icon(onPressed:online&&!busy?add:null,icon:const Icon(Icons.add,size:16),label:const Text('添加点位')),
    OutlinedButton.icon(onPressed:online&&!busy?apply:null,icon:const Icon(Icons.play_arrow,size:16),label:const Text('应用配置')),
    if(selected.isNotEmpty)TextButton(onPressed:()=>setState(()=>selected.clear()),child:Text('清除选择 ('+selected.length.toString()+')'))]),
   const SizedBox(height:8),Expanded(child:points.isEmpty?Center(child:Column(mainAxisSize:MainAxisSize.min,children:[
    const Icon(Icons.memory_outlined,size:38),const SizedBox(height:12),const Text('建立你的第一个工程'),const SizedBox(height:8),
    const Text('添加真实点位，或启动 30 站模拟工程验证数据流程。'),const SizedBox(height:16),
    OutlinedButton.icon(onPressed:online?demo:null,icon:const Icon(Icons.science_outlined,size:17),label:const Text('启动模拟工程'))
   ])):DenseTable(headers:const ['站点','点位','工程值','单位','质量','来源','源时间'],rows:rows.map((p){
    final r=valuesByID[p['id']]??<String,dynamic>{};return [p['station'].toString(),p['name'].toString(),number(r['value']),p['unit'].toString(),
     qualityLabel(online?(r['quality']??'missing').toString():'stale'),p['source_type'].toString(),clock(r['source_time'])];
   }).toList(),selected:rows.indexWhere((p)=>p['id']==selectedID),onSelect:(i)=>setState(()=>selectedID=rows[i]['id'].toString()),onContext:(i,loc)=>pointMenu(i,loc,rows),
    checks:{for(int i=0;i<rows.length;i++)if(selected.contains(rows[i]['id']))i},onCheck:(i,v)=>setState((){
     final id=rows[i]['id'].toString();if(v){if(selected.length<6)selected.add(id);}else{selected.remove(id);}
    }))),
   Align(alignment:Alignment.centerLeft,child:Text(rows.length.toString()+' 行 · 右键编辑／下设／历史 · 选择最多 6 条曲线',style:const TextStyle(fontSize:11)))
  ]);
 }
 Widget inspector(){
  final c=Theme.of(context).colorScheme,p=current;
  final r=p==null?<String,dynamic>{}:live[p['id']]??<String,dynamic>{};
  Widget property(String label,String value)=>Padding(padding:const EdgeInsets.only(bottom:16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
   Text(label,style:TextStyle(fontSize:11,color:c.onSurfaceVariant)),const SizedBox(height:5),SelectableText(value,style:const TextStyle(fontSize:12))]));
  return SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
   Text('点位属性',style:TextStyle(fontSize:11,fontWeight:FontWeight.w600,color:c.onSurfaceVariant)),const SizedBox(height:20),
   if(p==null)const Text('选择表格中的点位查看属性与操作。')else...[
    Text(p['name'].toString(),style:const TextStyle(fontSize:18,fontWeight:FontWeight.w600)),const SizedBox(height:4),
    Text(p['station'].toString(),style:TextStyle(color:c.onSurfaceVariant)),const SizedBox(height:20),
    Text(number(r['value'])+' '+p['unit'].toString(),style:const TextStyle(fontSize:30,fontWeight:FontWeight.w500)),const SizedBox(height:4),
    Text(qualityLabel(online?(r['quality']??'missing').toString():'stale'),style:TextStyle(color:qualityColor((r['quality']??'missing').toString(),c))),const SizedBox(height:20),const Divider(),const SizedBox(height:16),
    property('内部 ID',p['id'].toString()),property('原始值',number(r['raw'])),property('换算',number(p['scale_factor'])+' × 原值 + '+number(p['offset'])),
    property('源时间',clock(r['source_time'])),property('接收时间',clock(r['received_time'])),
    if(p['source_type']=='mqtt')property('来源与路径',p['source_id'].toString()+'\n'+p['source_path'].toString()),
    if(p['source_type']=='virtual')property('计算公式',(p['expression']??'').toString()),
    OutlinedButton.icon(onPressed:()=>add(existing:p),icon:const Icon(Icons.edit_outlined,size:16),label:const Text('编辑点位')),
    if(p['writable']==true||p['source_type']=='manual')Padding(padding:const EdgeInsets.only(top:8),child:FilledButton(onPressed:busy||!online?null:()=>writePoint(p),child:Text(p['writable']==true?'下设工程值':'输入原始值')))
   ]
  ]));
 }
 Widget trendWorkspace(){
  final names={for(final p in points)p['id'].toString():p['station'].toString()+' / '+p['name'].toString()};
  return Column(children:[
   toolbar([const Text('最近 3 分钟 · 实时工程值'),OutlinedButton(onPressed:()=>setState(()=>page=0),child:const Text('选择曲线')),TextButton(onPressed:()=>setState(()=>buffer.clear()),child:const Text('清空显示'))]),
   const SizedBox(height:6),Expanded(child:DecoratedBox(decoration:BoxDecoration(border:Border.all(color:Theme.of(context).colorScheme.outlineVariant),borderRadius:BorderRadius.circular(5)),child:Trend(rows:buffer,names:names)))
  ]);
 }
 Widget eventWorkspace()=>Column(children:[
  toolbar([FilledButton.icon(onPressed:online&&!busy?()async{final r=await ruleEditor(context,widget.api,points,rules);if(r!=null)await _load();}:null,
   icon:const Icon(Icons.add,size:16),label:const Text('添加事件')),
   OutlinedButton(onPressed:()=>act(()async{final r=await widget.api.request('GET','/api/v1/executions');setState(()=>logs=objects(r['items']));}),child:const Text('执行记录'))]),
  const SizedBox(height:8),Expanded(child:rules.isEmpty?const Center(child:Text('将多个点位条件组合成事件，执行下设或存储动作。')):ListView.separated(itemCount:rules.length,separatorBuilder:(_,_)=>const Divider(),itemBuilder:(context,i){
   final r=rules[i];return ListTile(dense:true,leading:Switch(value:r['enabled']==true,onChanged:(v)=>act(()async{final next=rules.map((x)=>Map<String,dynamic>.from(x)).toList();next[i]['enabled']=v;await widget.api.request('PUT','/api/v1/rules',body:{'items':next});await _poll();})),
    title:Text(r['name'].toString()),subtitle:Text((r['logic']=='and'?'同时满足':'任一满足')+' · '+objects(r['conditions']).length.toString()+' 个条件 · '+objects(r['actions']).length.toString()+' 个动作'),
    trailing:Wrap(children:[IconButton(tooltip:'编辑规则',onPressed:()async{final result=await ruleEditor(context,widget.api,points,rules,existing:r);if(result!=null)await _load();},icon:const Icon(Icons.edit_outlined,size:17)),
     IconButton(tooltip:'删除规则',onPressed:()=>act(()async{await widget.api.request('PUT','/api/v1/rules',body:{'items':rules.where((x)=>x['id']!=r['id']).toList()});await _load();}),icon:const Icon(Icons.delete_outline,size:17))]));
  })),
  if(logs.isNotEmpty)...[const Divider(),SizedBox(height:180,child:ListView.builder(itemCount:logs.length,itemBuilder:(context,i)=>ListTile(dense:true,title:Text(clock(logs[i]['at'])+' · '+(logs[i]['name']??logs[i]['type']).toString()),
   subtitle:Text(logs[i]['results']!=null?objects(logs[i]['results']).map((r)=>stateLabel(r['state'].toString())).join(' → '):stateLabel((logs[i]['result'] as Json?)?['state']?.toString()??'')),
   onTap:()=>showDialog<void>(context:context,builder:(c)=>AlertDialog(title:const Text('执行明细'),content:SizedBox(width:580,child:SingleChildScrollView(child:SelectableText(pretty(logs[i])))),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('关闭'))])))))]
 ]);
 Widget filters()=>Column(children:[
  toolbar([SizedBox(width:180,child:DropdownButtonFormField<String>(initialValue:historyPoint.isNotEmpty&&points.any((p)=>p['id']==historyPoint)?historyPoint:'',
   decoration:const InputDecoration(labelText:'点位'),items:[const DropdownMenuItem(value:'',child:Text('全部／当前导入')),
    ...points.map((p)=>DropdownMenuItem(value:p['id'].toString(),child:Text(p['station'].toString()+'/'+p['name'].toString(),overflow:TextOverflow.ellipsis)))],
   onChanged:(v)=>setState(()=>historyPoint=v??''))),
   SizedBox(width:150,child:DropdownButtonFormField<String>(initialValue:quality,decoration:const InputDecoration(labelText:'质量'),
    items:['','good','bad','stale','imported'].map((v)=>DropdownMenuItem(value:v,child:Text(v.isEmpty?'全部质量':qualityLabel(v)))).toList(),onChanged:(v)=>setState(()=>quality=v??''))),
   SizedBox(width:115,child:TextField(controller:min,decoration:const InputDecoration(labelText:'最小值'))),SizedBox(width:115,child:TextField(controller:max,decoration:const InputDecoration(labelText:'最大值'))),
   FilledButton.icon(onPressed:busy?null:()=>queryHistory(reset:true),icon:const Icon(Icons.filter_alt_outlined,size:16),label:const Text('筛选')),
   TextButton(onPressed:()=>setState((){station='';historyPoint='';quality='';min.clear();max.clear();from.clear();to.clear();boundary=0;}),child:const Text('清除'))]),
  const SizedBox(height:8),toolbar([
   SizedBox(width:245,child:TextField(controller:from,decoration:const InputDecoration(labelText:'开始时间 ISO（可选）',hintText:'2026-10-01T00:00:00Z'))),
   SizedBox(width:245,child:TextField(controller:to,decoration:const InputDecoration(labelText:'结束时间 ISO（可选）'))),
   if(station.isNotEmpty)InputChip(label:Text(station),onDeleted:()=>setState(()=>station=''))
  ])
 ]);
 Widget summary()=>Container(height:38,padding:const EdgeInsets.symmetric(horizontal:10),color:Theme.of(context).colorScheme.surfaceContainerLow,
  child:SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:[
   for(final entry in {'样本':stats['count']??0,'最小':number(stats['min']),'最大':number(stats['max']),'均值':number(stats['mean'])}.entries)
    Padding(padding:const EdgeInsets.only(right:28),child:Text(entry.key+'  '+entry.value.toString(),style:const TextStyle(fontSize:12)))
  ])));
 Widget historyTable()=>DenseTable(headers:const ['源时间','站点','点位','数值','单位','质量','配置版本'],
  rows:history.map((r)=>[clock(r['source_time']),r['station'].toString(),r['name'].toString(),number(r['value']),r['unit'].toString(),qualityLabel(r['quality'].toString()),r['version'].toString()]).toList());
 Widget pager()=>Row(children:[Text('第 '+(offset~/1000+1).toString()+' 页 · '+history.length.toString()+' 行',style:const TextStyle(fontSize:11)),const Spacer(),
  TextButton(onPressed:offset==0||busy?null:(){setState(()=>offset=math.max(0,offset-1000));queryHistory();},child:const Text('上一页')),
  TextButton(onPressed:history.length<1000||busy?null:(){setState(()=>offset+=1000);queryHistory();},child:const Text('下一页'))]);
 Widget historyWorkspace()=>Column(children:[
  toolbar([Switch(value:policy['enabled']==true,onChanged:busy?null:changeStorage),const Text('独立存储'),
   TextButton(onPressed:busy?null:()=>act(()async{await widget.api.request('POST','/api/v1/snapshot');},success:'当前快照已存储'),child:const Text('存储快照')),
   OutlinedButton(onPressed:storageOptions,child:const Text('存储策略')),const Text('无需开始检测',style:TextStyle(fontSize:11))]),
  const SizedBox(height:8),filters(),const SizedBox(height:8),summary(),const SizedBox(height:8),Expanded(child:historyTable()),pager()
 ]);
 Future<void> storageOptions()async{
  final interval=TextEditingController(text:(policy['interval_ms']??1000).toString()),retention=TextEditingController(text:(policy['retention_days']??30).toString());
  bool changed=policy['changed_only']==true;
  await showDialog<Object>(context:context,barrierDismissible:false,builder:(context)=>StatefulBuilder(builder:(context,update)=>EditorFrame(title:'独立存储策略',content:Column(children:[
   field(interval,'周期（毫秒，最小 200）'),field(retention,'保留天数'),
   SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('仅在值／质量／配置变化时存储'),value:changed,onChanged:(v)=>update(()=>changed=v)),
   Text(selected.isEmpty?'范围：全部点位':'范围：当前选择 '+selected.length.toString()+' 个点位')
  ]),save:()async{final p=policy;p['interval_ms']=int.parse(interval.text);p['retention_days']=int.parse(retention.text);p['changed_only']=changed;p['point_ids']=selected.toList();await widget.api.request('PUT','/api/v1/storage',body:p);return true;})));
  interval.dispose();retention.dispose();await _poll();
 }
 Widget reportWorkspace()=>Column(children:[
  toolbar([FilledButton.icon(onPressed:busy?null:upload,icon:const Icon(Icons.upload_file,size:16),label:const Text('导入 Excel / CSV')),
   OutlinedButton(onPressed:busy?null:()=>export('xlsx'),child:const Text('导出 XLSX')),OutlinedButton(onPressed:busy?null:()=>export('csv'),child:const Text('导出 CSV'))]),
  const SizedBox(height:8),filters(),const SizedBox(height:8),summary(),const SizedBox(height:8),
  Expanded(child:Column(children:[Expanded(flex:3,child:Trend(rows:history,names:{for(final r in history)r['point_id'].toString():r['station'].toString()+'/'+r['name'].toString()})),
   const Divider(),Expanded(flex:2,child:historyTable())])),pager(),
  if(jobs.isNotEmpty)SizedBox(height:100,child:ListView.builder(itemCount:jobs.length,itemBuilder:(context,i){
   final j=jobs[i],id=j['id'].toString(),state=j['state'].toString();
   return ListTile(dense:true,leading:Icon(state=='completed'?Icons.task_alt:state=='failed'?Icons.error_outline:Icons.pending_outlined,size:18),
    title:Text(j['format'].toString().toUpperCase()+' · '+stateLabel(state)+' · '+j['rows'].toString()+' 行'),subtitle:Text((j['message']??'').toString(),overflow:TextOverflow.ellipsis),
    trailing:Wrap(children:[
     if(state=='completed')IconButton(tooltip:'保存报表',onPressed:()=>act(()async{final bytes=await widget.api.download(id);final saved=await saveFile(bytes,'universal-hmi.'+j['format'].toString());if(saved&&context.mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('报表已交给文件保存器')));}),icon:const Icon(Icons.download,size:17)),
     if(state=='queued'||state=='running')IconButton(tooltip:'取消任务',onPressed:()=>act(()async{await widget.api.request('POST','/api/v1/jobs/$id/cancel');await _load();}),icon:const Icon(Icons.close,size:17))
      else IconButton(tooltip:'删除任务和文件',onPressed:()=>act(()async{await widget.api.request('DELETE','/api/v1/jobs/$id');await _load();}),icon:const Icon(Icons.delete_outline,size:17))
    ]));
  }))
 ]);
 Widget sourceWorkspace()=>Column(children:[
  toolbar([FilledButton.icon(onPressed:busy?null:()async{final r=await sourceEditor(context,widget.api,sources);if(r!=null)await _load();},icon:const Icon(Icons.add,size:16),label:const Text('添加 MQTT 来源')),
   OutlinedButton(onPressed:busy?null:demo,child:Text(runtime['demo']==true?'停止模拟采集':'启动 30 站模拟'))]),
  const SizedBox(height:8),Expanded(child:sources.isEmpty?const Center(child:Text('一个来源可包含多个站点，点位按源路径映射到不同站点。')):ListView.separated(
   itemCount:sources.length,separatorBuilder:(_,_)=>const Divider(),itemBuilder:(context,i){
    final s=sources[i],id=s['id'].toString(),state=((runtime['source_states'] as Map?)?[id]??'未连接').toString();
    return ListTile(title:Text(s['name'].toString()),subtitle:Text(s['broker'].toString()+' · '+s['topic'].toString()+'\n'+state),
     trailing:Wrap(children:[
      IconButton(tooltip:'编辑来源',onPressed:busy?null:()async{final r=await sourceEditor(context,widget.api,sources,existing:s);if(r!=null)await _load();},icon:const Icon(Icons.edit_outlined,size:17)),
      TextButton(onPressed:busy?null:()=>act(()async{await widget.api.request('POST','/api/v1/sources/$id/connect');await _poll();}),child:const Text('连接')),
      TextButton(onPressed:busy?null:()=>act(()async{await widget.api.request('POST','/api/v1/sources/$id/disconnect');await _poll();}),child:const Text('断开')),
      IconButton(tooltip:'删除来源',onPressed:busy?null:()=>act(()async{await widget.api.request('PUT','/api/v1/sources',body:{'items':sources.where((x)=>x['id']!=id).toList()});await _load();}),icon:const Icon(Icons.delete_outline,size:17))
     ]));
   }))
 ]);
}
String stateLabel(String state)=>switch(state){
 'readback_confirmed'=>'读回确认','sent'=>'已发送（设备结果待确认）','unknown'=>'结果未知','accepted'=>'已接受',
 'queued'=>'排队中','running'=>'运行中','completed'=>'已完成','failed'=>'失败','cancelled'=>'已取消',_=>state
};
