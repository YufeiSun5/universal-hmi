//
//  Generated code. Do not modify.
//  source: runtime.proto
//
// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'runtime.pb.dart' as $0;
import 'runtime.pbjson.dart';

export 'runtime.pb.dart';

abstract class RuntimeServiceBase extends $pb.GeneratedService {
  $async.Future<$0.RuntimeFrame> subscribe(
      $pb.ServerContext ctx, $0.SubscribeRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'Subscribe':
        return $0.SubscribeRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'Subscribe':
        return this.subscribe(ctx, request as $0.SubscribeRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => RuntimeServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => RuntimeServiceBase$messageJson;
}
