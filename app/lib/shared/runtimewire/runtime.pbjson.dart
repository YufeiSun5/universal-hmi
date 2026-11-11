//
//  Generated code. Do not modify.
//  source: runtime.proto
//
// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use subscribeRequestDescriptor instead')
const SubscribeRequest$json = {
  '1': 'SubscribeRequest',
  '2': [
    {'1': 'point_ids', '3': 1, '4': 3, '5': 9, '10': 'pointIds'},
    {'1': 'all_authorized', '3': 2, '4': 1, '5': 8, '10': 'allAuthorized'},
    {'1': 'overview', '3': 3, '4': 1, '5': 8, '10': 'overview'},
  ],
};

/// Descriptor for `SubscribeRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscribeRequestDescriptor = $convert.base64Decode(
    'ChBTdWJzY3JpYmVSZXF1ZXN0EhsKCXBvaW50X2lkcxgBIAMoCVIIcG9pbnRJZHMSJQoOYWxsX2'
    'F1dGhvcml6ZWQYAiABKAhSDWFsbEF1dGhvcml6ZWQSGgoIb3ZlcnZpZXcYAyABKAhSCG92ZXJ2'
    'aWV3');

@$core.Deprecated('Use scalarDescriptor instead')
const Scalar$json = {
  '1': 'Scalar',
  '2': [
    {'1': 'number', '3': 1, '4': 1, '5': 1, '9': 0, '10': 'number'},
    {'1': 'text', '3': 2, '4': 1, '5': 9, '9': 0, '10': 'text'},
    {'1': 'boolean', '3': 3, '4': 1, '5': 8, '9': 0, '10': 'boolean'},
    {'1': 'null_value', '3': 4, '4': 1, '5': 8, '9': 0, '10': 'nullValue'},
  ],
  '8': [
    {'1': 'kind'},
  ],
};

/// Descriptor for `Scalar`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List scalarDescriptor = $convert.base64Decode(
    'CgZTY2FsYXISGAoGbnVtYmVyGAEgASgBSABSBm51bWJlchIUCgR0ZXh0GAIgASgJSABSBHRleH'
    'QSGgoHYm9vbGVhbhgDIAEoCEgAUgdib29sZWFuEh8KCm51bGxfdmFsdWUYBCABKAhIAFIJbnVs'
    'bFZhbHVlQgYKBGtpbmQ=');

@$core.Deprecated('Use runtimeValueDescriptor instead')
const RuntimeValue$json = {
  '1': 'RuntimeValue',
  '2': [
    {'1': 'point_id', '3': 1, '4': 1, '5': 9, '10': 'pointId'},
    {
      '1': 'value',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.hmi.runtime.v1.Scalar',
      '10': 'value'
    },
    {
      '1': 'raw',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.hmi.runtime.v1.Scalar',
      '10': 'raw'
    },
    {'1': 'quality', '3': 4, '4': 1, '5': 9, '10': 'quality'},
    {'1': 'source_time', '3': 5, '4': 1, '5': 9, '10': 'sourceTime'},
    {'1': 'received_time', '3': 6, '4': 1, '5': 9, '10': 'receivedTime'},
    {'1': 'station', '3': 7, '4': 1, '5': 9, '10': 'station'},
    {'1': 'name', '3': 8, '4': 1, '5': 9, '10': 'name'},
    {'1': 'unit', '3': 9, '4': 1, '5': 9, '10': 'unit'},
    {'1': 'version', '3': 10, '4': 1, '5': 9, '10': 'version'},
    {'1': 'seq', '3': 11, '4': 1, '5': 3, '10': 'seq'},
  ],
};

/// Descriptor for `RuntimeValue`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List runtimeValueDescriptor = $convert.base64Decode(
    'CgxSdW50aW1lVmFsdWUSGQoIcG9pbnRfaWQYASABKAlSB3BvaW50SWQSLAoFdmFsdWUYAiABKA'
    'syFi5obWkucnVudGltZS52MS5TY2FsYXJSBXZhbHVlEigKA3JhdxgDIAEoCzIWLmhtaS5ydW50'
    'aW1lLnYxLlNjYWxhclIDcmF3EhgKB3F1YWxpdHkYBCABKAlSB3F1YWxpdHkSHwoLc291cmNlX3'
    'RpbWUYBSABKAlSCnNvdXJjZVRpbWUSIwoNcmVjZWl2ZWRfdGltZRgGIAEoCVIMcmVjZWl2ZWRU'
    'aW1lEhgKB3N0YXRpb24YByABKAlSB3N0YXRpb24SEgoEbmFtZRgIIAEoCVIEbmFtZRISCgR1bm'
    'l0GAkgASgJUgR1bml0EhgKB3ZlcnNpb24YCiABKAlSB3ZlcnNpb24SEAoDc2VxGAsgASgDUgNz'
    'ZXE=');

@$core.Deprecated('Use runtimeFrameDescriptor instead')
const RuntimeFrame$json = {
  '1': 'RuntimeFrame',
  '2': [
    {'1': 'epoch', '3': 1, '4': 1, '5': 9, '10': 'epoch'},
    {'1': 'sequence', '3': 2, '4': 1, '5': 4, '10': 'sequence'},
    {'1': 'version', '3': 3, '4': 1, '5': 9, '10': 'version'},
    {'1': 'reset', '3': 4, '4': 1, '5': 8, '10': 'reset'},
    {
      '1': 'values',
      '3': 5,
      '4': 3,
      '5': 11,
      '6': '.hmi.runtime.v1.RuntimeValue',
      '10': 'values'
    },
    {'1': 'removed', '3': 6, '4': 3, '5': 9, '10': 'removed'},
    {'1': 'meta_json', '3': 7, '4': 1, '5': 12, '10': 'metaJson'},
  ],
};

/// Descriptor for `RuntimeFrame`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List runtimeFrameDescriptor = $convert.base64Decode(
    'CgxSdW50aW1lRnJhbWUSFAoFZXBvY2gYASABKAlSBWVwb2NoEhoKCHNlcXVlbmNlGAIgASgEUg'
    'hzZXF1ZW5jZRIYCgd2ZXJzaW9uGAMgASgJUgd2ZXJzaW9uEhQKBXJlc2V0GAQgASgIUgVyZXNl'
    'dBI0CgZ2YWx1ZXMYBSADKAsyHC5obWkucnVudGltZS52MS5SdW50aW1lVmFsdWVSBnZhbHVlcx'
    'IYCgdyZW1vdmVkGAYgAygJUgdyZW1vdmVkEhsKCW1ldGFfanNvbhgHIAEoDFIIbWV0YUpzb24=');

const $core.Map<$core.String, $core.dynamic> RuntimeServiceBase$json = {
  '1': 'RuntimeService',
  '2': [
    {
      '1': 'Subscribe',
      '2': '.hmi.runtime.v1.SubscribeRequest',
      '3': '.hmi.runtime.v1.RuntimeFrame',
      '6': true
    },
  ],
};

@$core.Deprecated('Use runtimeServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    RuntimeServiceBase$messageJson = {
  '.hmi.runtime.v1.SubscribeRequest': SubscribeRequest$json,
  '.hmi.runtime.v1.RuntimeFrame': RuntimeFrame$json,
  '.hmi.runtime.v1.RuntimeValue': RuntimeValue$json,
  '.hmi.runtime.v1.Scalar': Scalar$json,
};

/// Descriptor for `RuntimeService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List runtimeServiceDescriptor = $convert.base64Decode(
    'Cg5SdW50aW1lU2VydmljZRJNCglTdWJzY3JpYmUSIC5obWkucnVudGltZS52MS5TdWJzY3JpYm'
    'VSZXF1ZXN0GhwuaG1pLnJ1bnRpbWUudjEuUnVudGltZUZyYW1lMAE=');
