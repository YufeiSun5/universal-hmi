import '../../shared/api.dart';
import 'model.dart';

Set<String> processSubscriptionIDs(ScreenDocument? document) => {
  for (final node in document?.nodes ?? <ScreenElement>[]) ...{
    if (node.pointID.isNotEmpty) node.pointID,
    for (final rule in [node.arrowVisibleRule, node.arrowMotionRule])
      for (final condition in objects(rule?['conditions']))
        if ((condition['point_id'] as String? ?? '').isNotEmpty)
          condition['point_id'] as String,
  },
};

Set<String> gisSubscriptionIDs(Json? config) => {
  for (final station in objects(config?['stations']))
    for (final group in [station, ...objects(station['zones'])])
      for (final id in (group['bindings'] as Map? ?? {}).values)
        if (id is String && id.isNotEmpty) id,
};
