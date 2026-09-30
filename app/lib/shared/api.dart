import 'dart:convert';
import 'package:http/http.dart' as http;

class PointDefinition {
  const PointDefinition({
    required this.id,
    required this.station,
    required this.name,
    required this.dataType,
    required this.sourceType,
    required this.unit,
    required this.scaleFactor,
    required this.offset,
  });

  factory PointDefinition.fromJson(Map<String, dynamic> json) =>
      PointDefinition(
        id: json['id'] as String,
        station: json['station'] as String,
        name: json['name'] as String,
        dataType: json['data_type'] as String,
        sourceType: json['source_type'] as String,
        unit: json['unit'] as String,
        scaleFactor: (json['scale_factor'] as num).toDouble(),
        offset: (json['offset'] as num).toDouble(),
      );

  final String id;
  final String station;
  final String name;
  final String dataType;
  final String sourceType;
  final String unit;
  final double scaleFactor;
  final double offset;
}

abstract interface class PlatformApi {
  Future<void> checkHealth();
  Future<List<PointDefinition>> listPoints();
  Future<PointDefinition> addPoint(Map<String, dynamic> input);
  void close();
}

class PlatformClient implements PlatformApi {
  PlatformClient(this.base, {http.Client? client})
      : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;

  Future<http.Response> _check(Future<http.Response> request) async {
    final response = await request.timeout(const Duration(seconds: 8));
    if (response.statusCode >= 400) {
      throw Exception('操作未完成（HTTP ${response.statusCode}），请检查配置后重试。');
    }
    return response;
  }

  @override
  Future<void> checkHealth() async {
    await _check(_client.get(base.resolve('/health')));
  }

  @override
  Future<List<PointDefinition>> listPoints() async {
    final response = await _check(
      _client.get(base.resolve('/api/v1/points')),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['items'] as List<dynamic>)
        .map((item) => PointDefinition.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<PointDefinition> addPoint(Map<String, dynamic> input) async {
    final response = await _check(
      _client.post(
        base.resolve('/api/v1/points'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(input),
      ),
    );
    return PointDefinition.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  @override
  void close() => _client.close();
}
