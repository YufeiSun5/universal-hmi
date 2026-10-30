import 'package:http/http.dart' as http;

http.Client newTransport() => http.Client();
void configureRemoteTrust(String? pem, {String? origin}) {}
