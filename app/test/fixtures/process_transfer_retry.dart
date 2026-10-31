import 'package:universal_hmi/shared/api.dart';

/// Synthetic decoded input for transfer-dialog state tests, not a recreation of
/// the unavailable KingIO delivery artifact. Keep 385 entries to exercise the original batch
/// cardinality. Nonempty screens/bindings ensure retry create-targets, rather
/// than the variable-only default, enable variable definitions on import.
/// Returns a fresh nested structure because tests deliberately edit requests.
Json syntheticProcessTransferRetry() {
  final variables = List<Json>.generate(
    385,
    (i) => {
      'key': 'synthetic-variable-$i',
      'definition': {
        'name': '模拟变量$i',
        'station': 'Synthetic-A',
        'data_type': i.isEven ? 'FLOAT' : 'INT',
        'source_type': 'manual',
        'writable': false,
        'scale_factor': 1,
        'offset': 0,
      },
    },
  );
  return {
    'retry_request': {
      'import_identity': 'synthetic-transfer-retry-v1',
      'bundle': {
        'format': 'universal-hmi-process-bundle',
        'version': 1,
        'screens': [
          {
            'key': 'screenA',
            'document': {
              'schema_version': 1,
              'id': 'synthetic-screen',
              'name': '模拟画面',
              'station': 'Synthetic-A',
              'width': 800,
              'height': 600,
              'nodes': [
                {
                  'id': 'n1',
                  'kind': 'value',
                  'x': 10,
                  'y': 10,
                  'width': 100,
                  'height': 40,
                },
              ],
              'assets': <String, dynamic>{},
            },
          },
        ],
        'variables': variables,
        'bindings': [
          {
            'screen_key': 'screenA',
            'node_id': 'n1',
            'property': 'point_id',
            'variable_key': 'synthetic-variable-0',
            'operation': 'set',
          },
        ],
      },
      'screen_targets': {
        'screenA': {'mode': 'create'},
      },
      'variable_targets': {
        for (final v in variables) v['key'] as String: {'mode': 'create'},
      },
      'station_map': {'Synthetic-A': 'Synthetic-A'},
      'create_stations': ['Synthetic-A'],
      'source_map': <String, String>{},
    },
  };
}
