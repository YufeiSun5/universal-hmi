import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/equipment/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'equipment_test.dart' show LedgerApi;

const photoBytes =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGP0qJjNgA0wYRUdtBIAEyYBa74a5twAAAAASUVORK5CYII=';

class RetryPhotoApi extends LedgerApi {
  RetryPhotoApi({this.badImage = false, this.delayed});
  final bool badImage;
  final Completer<Json>? delayed;
  int requests = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.contains('/photos/')) {
      requests++;
      if (requests == 1) {
        if (badImage) {
          return {'data': base64Encode(utf8.encode('invalid image'))};
        }
        throw Exception('temporary photo download failure');
      }
      if (delayed != null) return delayed!.future;
      return {'data': photoBytes};
    }
    return super.request(method, path, body: body, query: query);
  }
}

Widget photo(RetryPhotoApi api) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 320,
        child: EquipmentPhoto(
          api: api,
          deviceID: 'pump',
          photo: const {'id': 'p'},
        ),
      ),
    ),
  ),
);
Future<void> decode(WidgetTester t) async {
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await t.pumpAndSettle();
}

void main() {
  for (final badImage in [false, true]) {
    testWidgets(
      'photo retry recovers ${badImage ? 'decode' : 'network'} failure and opens preview',
      (t) async {
        final api = RetryPhotoApi(badImage: badImage);
        await t.pumpWidget(photo(api));
        await t.pumpAndSettle();
        await decode(t);
        expect(find.text('图片加载失败 · 重试'), findsOneWidget);
        await t.tap(find.text('图片加载失败 · 重试'));
        expect(t.takeException(), isNull);
        await t.pumpAndSettle();
        await decode(t);
        expect(api.requests, 2);
        expect(find.text('图片加载失败 · 重试'), findsNothing);
        await t.tap(find.byType(Image));
        await t.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsOneWidget);
        await t.tap(find.byIcon(Icons.close));
        await t.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('photo retry may finish after its host has been removed', (
    t,
  ) async {
    final pending = Completer<Json>();
    final api = RetryPhotoApi(delayed: pending);
    await t.pumpWidget(photo(api));
    await t.pumpAndSettle();
    await t.tap(find.text('图片加载失败 · 重试'));
    expect(t.takeException(), isNull);
    await t.pump();
    expect(api.requests, 2);
    await t.pumpWidget(const SizedBox());
    pending.complete({'data': photoBytes});
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
