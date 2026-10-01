import 'dart:io';
import 'package:flutter/foundation.dart';
Process? ownedBackend;
Future<bool> ready() async {
 final client=HttpClient()..connectionTimeout=const Duration(milliseconds:300);
 try{
  final req=await client.getUrl(Uri.parse('http://127.0.0.1:18080/health'));
  final response=await req.close().timeout(const Duration(milliseconds:600));
  await response.drain<void>();return response.statusCode==200;
 }catch(_){return false;}finally{client.close(force:true);}
}
Future<void> startLocalBackend() async {
 const configured=String.fromEnvironment('API_BASE_URL');
 if(configured.isNotEmpty||await ready())return;
 final folder=File(Platform.resolvedExecutable).parent.path;
 final executable=File('$folder/universal-hmi-server'+(Platform.isWindows?'.exe':''));
 if(!await executable.exists())return;
 final home=Platform.environment['HOME']??Directory.systemTemp.path;
 final base=Platform.isWindows?(Platform.environment['LOCALAPPDATA']??Directory.systemTemp.path):(Platform.environment['XDG_DATA_HOME']??'$home/.local/share');
 try{
  ownedBackend=await Process.start(executable.path,['--data-dir','$base/universal-hmi']);
  ownedBackend!.stdout.listen((_){});
  ownedBackend!.stderr.listen((_){}); // Backend state is reported by the API, not raw log dialogs.
  for(int i=0;i<30;i++){if(await ready())return;await Future<void>.delayed(const Duration(milliseconds:100));}
 }catch(e){debugPrint('Local backend could not start: $e');}
}
void stopLocalBackend(){ownedBackend?.kill();ownedBackend=null;}
