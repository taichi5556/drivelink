// Phase H-1: デモモード用の Position シミュレータ。
// Geolocator.getPositionStream の代わりにこの Stream<Position> を main_screen から購読することで、
// 既存の位置情報ハンドラ（_handlePositionUpdate）を完全無改修のまま室内テスト可能にする。
//
// H-1: speedMps = 0 で停車状態。位置は据え置き、Position だけ 500ms ごとに発射。
// H-2 以降: speedMps を可変、_bearing / _bearingOffset で進行方向を変えてルート上を走行 or 離脱。
//
// リリース前に Phase H 関連コミットを revert / 削除してマージする運用。
import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class DemoLocationSource {
  final StreamController<Position> _controller =
      StreamController<Position>.broadcast();
  Timer? _ticker;

  LatLng _position;
  double _bearingDeg = 0;       // 基本進行方向（度、0=北、東回り正）
  double _bearingOffsetDeg = 0; // 一時オフセット（H-3 逆走 +180、H-4 離脱 +90 用）
  double _speedMps = 0;         // 速度（m/s）。H-1 は 0 固定（停車）

  // Phase H-2: ルート polyline 自動追従
  List<LatLng> _routePoints = [];
  int _routeIdx = 0;
  bool _autoFollow = false;

  DemoLocationSource(LatLng initial) : _position = initial;

  Stream<Position> get stream => _controller.stream;
  LatLng get currentPosition => _position;
  double get currentSpeedMps => _speedMps;
  double get currentHeadingDeg => (_bearingDeg + _bearingOffsetDeg) % 360;
  bool get isAutoFollowing => _autoFollow;
  bool get hasRoute => _routePoints.isNotEmpty;
  // Phase H-5: ステータス表示用
  int get routeIdx => _routeIdx;
  int get routeLength => _routePoints.length;
  bool get isAtEnd =>
      _routePoints.isNotEmpty && _routeIdx >= _routePoints.length - 1;

  void start() {
    _ticker?.cancel();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _emit(),
    );
    // 起動直後に 1 発投げて即座にハンドラを駆動
    _emit();
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  // H-2 以降の API（H-1 では未使用、雛形のみ）
  void setSpeedKmh(double kmh) {
    _speedMps = kmh / 3.6;
  }

  void setBearing(double deg) {
    _bearingDeg = deg % 360;
  }

  void setBearingOffset(double deg) {
    _bearingOffsetDeg = deg;
  }

  void setPosition(LatLng pos) {
    _position = pos;
  }

  // Phase H-2: ルート polyline をセット。現在位置から最近接の vertex に snap して開始。
  void setRoute(List<LatLng> points) {
    _routePoints = List<LatLng>.from(points);
    _routeIdx = 0;
    if (_routePoints.isEmpty) return;
    double bestDist = double.infinity;
    int bestIdx = 0;
    for (int i = 0; i < _routePoints.length; i++) {
      final d = _haversineMeters(_position, _routePoints[i]);
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    _routeIdx = bestIdx;
    _position = _routePoints[bestIdx]; // snap：以降は polyline に乗った状態で走行
  }

  void clearRoute() {
    _routePoints = [];
    _routeIdx = 0;
  }

  // Phase H-2: ルート自動追従の ON/OFF。ON 中は _emit ごとに次の vertex を目指して bearing を更新。
  void setAutoFollow(bool enable) {
    _autoFollow = enable;
  }

  void _emit() {
    // Phase H-2: 自動追従 ON ならルート上を進行。次の vertex に 3m 以内まで近づいたら index を進める。
    if (_autoFollow && _routePoints.isNotEmpty && _speedMps > 0) {
      while (_routeIdx < _routePoints.length - 1) {
        final target = _routePoints[_routeIdx + 1];
        final distToTarget = _haversineMeters(_position, target);
        if (distToTarget < 3.0) {
          _routeIdx++;
          _position = _routePoints[_routeIdx]; // vertex に正確に乗せて drift を防ぐ
          continue;
        }
        _bearingDeg = _bearingTo(_position, target);
        break;
      }
      if (_routeIdx >= _routePoints.length - 1) {
        // 末尾到達 → 停車
        _speedMps = 0;
        _autoFollow = false;
      }
    }

    // 速度がある場合のみ位置を進める
    if (_speedMps > 0) {
      final eff = (_bearingDeg + _bearingOffsetDeg) % 360;
      _position = _moveAlongBearing(_position, eff, _speedMps * 0.5);
    }
    _controller.add(
      Position(
        latitude: _position.latitude,
        longitude: _position.longitude,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: (_bearingDeg + _bearingOffsetDeg) % 360,
        headingAccuracy: 0,
        speed: _speedMps,
        speedAccuracy: 0,
      ),
    );
  }

  static double _haversineMeters(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final sinLat = sin(dLat / 2);
    final sinLng = sin(dLng / 2);
    final h = sinLat * sinLat +
        cos(a.latitude * pi / 180) *
            cos(b.latitude * pi / 180) *
            sinLng *
            sinLng;
    return r * 2 * atan2(sqrt(h), sqrt(1 - h));
  }

  static double _bearingTo(LatLng a, LatLng b) {
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final y = sin(dLng) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
    final bearing = atan2(y, x) * 180 / pi;
    return (bearing + 360) % 360;
  }

  // 球面三角法で出発点から bearing 方向に meters m 進んだ点を返す。
  static LatLng _moveAlongBearing(LatLng from, double bearingDeg, double meters) {
    const earthRadius = 6371000.0;
    final br = bearingDeg * pi / 180;
    final lat1 = from.latitude * pi / 180;
    final lng1 = from.longitude * pi / 180;
    final dr = meters / earthRadius;
    final lat2 = asin(
      sin(lat1) * cos(dr) + cos(lat1) * sin(dr) * cos(br),
    );
    final lng2 = lng1 +
        atan2(
          sin(br) * sin(dr) * cos(lat1),
          cos(dr) - sin(lat1) * sin(lat2),
        );
    return LatLng(lat2 * 180 / pi, lng2 * 180 / pi);
  }
}
