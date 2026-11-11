//
//  Generated code. Do not modify.
//  source: runtime.proto
//
// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class SubscribeRequest extends $pb.GeneratedMessage {
  factory SubscribeRequest({
    $core.Iterable<$core.String>? pointIds,
    $core.bool? allAuthorized,
    $core.bool? overview,
  }) {
    final $result = create();
    if (pointIds != null) {
      $result.pointIds.addAll(pointIds);
    }
    if (allAuthorized != null) {
      $result.allAuthorized = allAuthorized;
    }
    if (overview != null) {
      $result.overview = overview;
    }
    return $result;
  }
  SubscribeRequest._() : super();
  factory SubscribeRequest.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory SubscribeRequest.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SubscribeRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'hmi.runtime.v1'),
      createEmptyInstance: create)
    ..pPS(1, _omitFieldNames ? '' : 'pointIds')
    ..aOB(2, _omitFieldNames ? '' : 'allAuthorized')
    ..aOB(3, _omitFieldNames ? '' : 'overview')
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  SubscribeRequest clone() => SubscribeRequest()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  SubscribeRequest copyWith(void Function(SubscribeRequest) updates) =>
      super.copyWith((message) => updates(message as SubscribeRequest))
          as SubscribeRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SubscribeRequest create() => SubscribeRequest._();
  SubscribeRequest createEmptyInstance() => create();
  static $pb.PbList<SubscribeRequest> createRepeated() =>
      $pb.PbList<SubscribeRequest>();
  @$core.pragma('dart2js:noInline')
  static SubscribeRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SubscribeRequest>(create);
  static SubscribeRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get pointIds => $_getList(0);

  @$pb.TagNumber(2)
  $core.bool get allAuthorized => $_getBF(1);
  @$pb.TagNumber(2)
  set allAuthorized($core.bool v) {
    $_setBool(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasAllAuthorized() => $_has(1);
  @$pb.TagNumber(2)
  void clearAllAuthorized() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get overview => $_getBF(2);
  @$pb.TagNumber(3)
  set overview($core.bool v) {
    $_setBool(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasOverview() => $_has(2);
  @$pb.TagNumber(3)
  void clearOverview() => $_clearField(3);
}

enum Scalar_Kind { number, text, boolean, nullValue, notSet }

class Scalar extends $pb.GeneratedMessage {
  factory Scalar({
    $core.double? number,
    $core.String? text,
    $core.bool? boolean,
    $core.bool? nullValue,
  }) {
    final $result = create();
    if (number != null) {
      $result.number = number;
    }
    if (text != null) {
      $result.text = text;
    }
    if (boolean != null) {
      $result.boolean = boolean;
    }
    if (nullValue != null) {
      $result.nullValue = nullValue;
    }
    return $result;
  }
  Scalar._() : super();
  factory Scalar.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory Scalar.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static const $core.Map<$core.int, Scalar_Kind> _Scalar_KindByTag = {
    1: Scalar_Kind.number,
    2: Scalar_Kind.text,
    3: Scalar_Kind.boolean,
    4: Scalar_Kind.nullValue,
    0: Scalar_Kind.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Scalar',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'hmi.runtime.v1'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3, 4])
    ..a<$core.double>(1, _omitFieldNames ? '' : 'number', $pb.PbFieldType.OD)
    ..aOS(2, _omitFieldNames ? '' : 'text')
    ..aOB(3, _omitFieldNames ? '' : 'boolean')
    ..aOB(4, _omitFieldNames ? '' : 'nullValue')
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  Scalar clone() => Scalar()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  Scalar copyWith(void Function(Scalar) updates) =>
      super.copyWith((message) => updates(message as Scalar)) as Scalar;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Scalar create() => Scalar._();
  Scalar createEmptyInstance() => create();
  static $pb.PbList<Scalar> createRepeated() => $pb.PbList<Scalar>();
  @$core.pragma('dart2js:noInline')
  static Scalar getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Scalar>(create);
  static Scalar? _defaultInstance;

  Scalar_Kind whichKind() => _Scalar_KindByTag[$_whichOneof(0)]!;
  void clearKind() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.double get number => $_getN(0);
  @$pb.TagNumber(1)
  set number($core.double v) {
    $_setDouble(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasNumber() => $_has(0);
  @$pb.TagNumber(1)
  void clearNumber() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get text => $_getSZ(1);
  @$pb.TagNumber(2)
  set text($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasText() => $_has(1);
  @$pb.TagNumber(2)
  void clearText() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get boolean => $_getBF(2);
  @$pb.TagNumber(3)
  set boolean($core.bool v) {
    $_setBool(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasBoolean() => $_has(2);
  @$pb.TagNumber(3)
  void clearBoolean() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get nullValue => $_getBF(3);
  @$pb.TagNumber(4)
  set nullValue($core.bool v) {
    $_setBool(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasNullValue() => $_has(3);
  @$pb.TagNumber(4)
  void clearNullValue() => $_clearField(4);
}

class RuntimeValue extends $pb.GeneratedMessage {
  factory RuntimeValue({
    $core.String? pointId,
    Scalar? value,
    Scalar? raw,
    $core.String? quality,
    $core.String? sourceTime,
    $core.String? receivedTime,
    $core.String? station,
    $core.String? name,
    $core.String? unit,
    $core.String? version,
    $fixnum.Int64? seq,
  }) {
    final $result = create();
    if (pointId != null) {
      $result.pointId = pointId;
    }
    if (value != null) {
      $result.value = value;
    }
    if (raw != null) {
      $result.raw = raw;
    }
    if (quality != null) {
      $result.quality = quality;
    }
    if (sourceTime != null) {
      $result.sourceTime = sourceTime;
    }
    if (receivedTime != null) {
      $result.receivedTime = receivedTime;
    }
    if (station != null) {
      $result.station = station;
    }
    if (name != null) {
      $result.name = name;
    }
    if (unit != null) {
      $result.unit = unit;
    }
    if (version != null) {
      $result.version = version;
    }
    if (seq != null) {
      $result.seq = seq;
    }
    return $result;
  }
  RuntimeValue._() : super();
  factory RuntimeValue.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory RuntimeValue.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RuntimeValue',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'hmi.runtime.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'pointId')
    ..aOM<Scalar>(2, _omitFieldNames ? '' : 'value', subBuilder: Scalar.create)
    ..aOM<Scalar>(3, _omitFieldNames ? '' : 'raw', subBuilder: Scalar.create)
    ..aOS(4, _omitFieldNames ? '' : 'quality')
    ..aOS(5, _omitFieldNames ? '' : 'sourceTime')
    ..aOS(6, _omitFieldNames ? '' : 'receivedTime')
    ..aOS(7, _omitFieldNames ? '' : 'station')
    ..aOS(8, _omitFieldNames ? '' : 'name')
    ..aOS(9, _omitFieldNames ? '' : 'unit')
    ..aOS(10, _omitFieldNames ? '' : 'version')
    ..aInt64(11, _omitFieldNames ? '' : 'seq')
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  RuntimeValue clone() => RuntimeValue()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  RuntimeValue copyWith(void Function(RuntimeValue) updates) =>
      super.copyWith((message) => updates(message as RuntimeValue))
          as RuntimeValue;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RuntimeValue create() => RuntimeValue._();
  RuntimeValue createEmptyInstance() => create();
  static $pb.PbList<RuntimeValue> createRepeated() =>
      $pb.PbList<RuntimeValue>();
  @$core.pragma('dart2js:noInline')
  static RuntimeValue getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RuntimeValue>(create);
  static RuntimeValue? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get pointId => $_getSZ(0);
  @$pb.TagNumber(1)
  set pointId($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasPointId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPointId() => $_clearField(1);

  @$pb.TagNumber(2)
  Scalar get value => $_getN(1);
  @$pb.TagNumber(2)
  set value(Scalar v) {
    $_setField(2, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearValue() => $_clearField(2);
  @$pb.TagNumber(2)
  Scalar ensureValue() => $_ensure(1);

  @$pb.TagNumber(3)
  Scalar get raw => $_getN(2);
  @$pb.TagNumber(3)
  set raw(Scalar v) {
    $_setField(3, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasRaw() => $_has(2);
  @$pb.TagNumber(3)
  void clearRaw() => $_clearField(3);
  @$pb.TagNumber(3)
  Scalar ensureRaw() => $_ensure(2);

  @$pb.TagNumber(4)
  $core.String get quality => $_getSZ(3);
  @$pb.TagNumber(4)
  set quality($core.String v) {
    $_setString(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasQuality() => $_has(3);
  @$pb.TagNumber(4)
  void clearQuality() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get sourceTime => $_getSZ(4);
  @$pb.TagNumber(5)
  set sourceTime($core.String v) {
    $_setString(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasSourceTime() => $_has(4);
  @$pb.TagNumber(5)
  void clearSourceTime() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.String get receivedTime => $_getSZ(5);
  @$pb.TagNumber(6)
  set receivedTime($core.String v) {
    $_setString(5, v);
  }

  @$pb.TagNumber(6)
  $core.bool hasReceivedTime() => $_has(5);
  @$pb.TagNumber(6)
  void clearReceivedTime() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get station => $_getSZ(6);
  @$pb.TagNumber(7)
  set station($core.String v) {
    $_setString(6, v);
  }

  @$pb.TagNumber(7)
  $core.bool hasStation() => $_has(6);
  @$pb.TagNumber(7)
  void clearStation() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.String get name => $_getSZ(7);
  @$pb.TagNumber(8)
  set name($core.String v) {
    $_setString(7, v);
  }

  @$pb.TagNumber(8)
  $core.bool hasName() => $_has(7);
  @$pb.TagNumber(8)
  void clearName() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.String get unit => $_getSZ(8);
  @$pb.TagNumber(9)
  set unit($core.String v) {
    $_setString(8, v);
  }

  @$pb.TagNumber(9)
  $core.bool hasUnit() => $_has(8);
  @$pb.TagNumber(9)
  void clearUnit() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.String get version => $_getSZ(9);
  @$pb.TagNumber(10)
  set version($core.String v) {
    $_setString(9, v);
  }

  @$pb.TagNumber(10)
  $core.bool hasVersion() => $_has(9);
  @$pb.TagNumber(10)
  void clearVersion() => $_clearField(10);

  @$pb.TagNumber(11)
  $fixnum.Int64 get seq => $_getI64(10);
  @$pb.TagNumber(11)
  set seq($fixnum.Int64 v) {
    $_setInt64(10, v);
  }

  @$pb.TagNumber(11)
  $core.bool hasSeq() => $_has(10);
  @$pb.TagNumber(11)
  void clearSeq() => $_clearField(11);
}

class RuntimeFrame extends $pb.GeneratedMessage {
  factory RuntimeFrame({
    $core.String? epoch,
    $fixnum.Int64? sequence,
    $core.String? version,
    $core.bool? reset,
    $core.Iterable<RuntimeValue>? values,
    $core.Iterable<$core.String>? removed,
    $core.List<$core.int>? metaJson,
  }) {
    final $result = create();
    if (epoch != null) {
      $result.epoch = epoch;
    }
    if (sequence != null) {
      $result.sequence = sequence;
    }
    if (version != null) {
      $result.version = version;
    }
    if (reset != null) {
      $result.reset = reset;
    }
    if (values != null) {
      $result.values.addAll(values);
    }
    if (removed != null) {
      $result.removed.addAll(removed);
    }
    if (metaJson != null) {
      $result.metaJson = metaJson;
    }
    return $result;
  }
  RuntimeFrame._() : super();
  factory RuntimeFrame.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory RuntimeFrame.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RuntimeFrame',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'hmi.runtime.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'epoch')
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'sequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(3, _omitFieldNames ? '' : 'version')
    ..aOB(4, _omitFieldNames ? '' : 'reset')
    ..pc<RuntimeValue>(5, _omitFieldNames ? '' : 'values', $pb.PbFieldType.PM,
        subBuilder: RuntimeValue.create)
    ..pPS(6, _omitFieldNames ? '' : 'removed')
    ..a<$core.List<$core.int>>(
        7, _omitFieldNames ? '' : 'metaJson', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  RuntimeFrame clone() => RuntimeFrame()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  RuntimeFrame copyWith(void Function(RuntimeFrame) updates) =>
      super.copyWith((message) => updates(message as RuntimeFrame))
          as RuntimeFrame;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RuntimeFrame create() => RuntimeFrame._();
  RuntimeFrame createEmptyInstance() => create();
  static $pb.PbList<RuntimeFrame> createRepeated() =>
      $pb.PbList<RuntimeFrame>();
  @$core.pragma('dart2js:noInline')
  static RuntimeFrame getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RuntimeFrame>(create);
  static RuntimeFrame? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get epoch => $_getSZ(0);
  @$pb.TagNumber(1)
  set epoch($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasEpoch() => $_has(0);
  @$pb.TagNumber(1)
  void clearEpoch() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get sequence => $_getI64(1);
  @$pb.TagNumber(2)
  set sequence($fixnum.Int64 v) {
    $_setInt64(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasSequence() => $_has(1);
  @$pb.TagNumber(2)
  void clearSequence() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get version => $_getSZ(2);
  @$pb.TagNumber(3)
  set version($core.String v) {
    $_setString(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasVersion() => $_has(2);
  @$pb.TagNumber(3)
  void clearVersion() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get reset => $_getBF(3);
  @$pb.TagNumber(4)
  set reset($core.bool v) {
    $_setBool(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasReset() => $_has(3);
  @$pb.TagNumber(4)
  void clearReset() => $_clearField(4);

  @$pb.TagNumber(5)
  $pb.PbList<RuntimeValue> get values => $_getList(4);

  @$pb.TagNumber(6)
  $pb.PbList<$core.String> get removed => $_getList(5);

  /// Existing extensible runtime health/configuration metadata, without values.
  @$pb.TagNumber(7)
  $core.List<$core.int> get metaJson => $_getN(6);
  @$pb.TagNumber(7)
  set metaJson($core.List<$core.int> v) {
    $_setBytes(6, v);
  }

  @$pb.TagNumber(7)
  $core.bool hasMetaJson() => $_has(6);
  @$pb.TagNumber(7)
  void clearMetaJson() => $_clearField(7);
}

/// Latest state only. Every connection begins with reset; no event replay.
class RuntimeServiceApi {
  $pb.RpcClient _client;
  RuntimeServiceApi(this._client);

  $async.Future<RuntimeFrame> subscribe(
          $pb.ClientContext? ctx, SubscribeRequest request) =>
      _client.invoke<RuntimeFrame>(
          ctx, 'RuntimeService', 'Subscribe', request, RuntimeFrame());
}

const _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
