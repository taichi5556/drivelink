import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/room_history.dart';
import 'login_screen.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:share_plus/share_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';

class MainScreen extends StatefulWidget {
  final String userId;
  final String nickname;
  final String roomCode;
  final String vehicleType; // 'car' or 'bike'
  const MainScreen({
    Key? key,
    required this.userId,
    required this.nickname,
    required this.roomCode,
    this.vehicleType = 'car',
  }) : super(key: key);

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  GoogleMapController? _mapController;
  bool _isFollowingMember = false;
  late bool _shareLocation;
  // アプリ自身が直近にカメラを動かした時刻。onCameraMoveStartedの発火が
  // ユーザー操作由来かプログラム由来かをタイムスタンプ差で判定するために使う。
  DateTime? _lastProgrammaticMoveAt;
  // この時間以内のonCameraMoveStartedはプログラム由来とみなす（ms）
  static const _programmaticMoveGuardMs = 100;
  Set<Marker> _markers = {};
  LatLng _myPosition = const LatLng(35.6812, 139.7671);
  Timer? _expiryTimer;
  String _remainingTime = '';
  Timer? _countdownTimer;
  StreamSubscription<Position>? _locationSubscription;
  bool _updateLocationInProgress = false;
  bool _expiryHandled = false;
  Map<String, dynamic> _members = {};
  StreamSubscription? _membersSubscription;

  // 目的地関連
  LatLng? _groupDestination;
  String _groupDestName = '';
  StreamSubscription? _destSubscription;
  Set<Polyline> _polylines = {};
  StreamSubscription? _appLinkSubscription;
  final _appLinks = AppLinks();
  LatLng? get _activeDestination => _groupDestination;
  String get _activeDestName => _groupDestName;

  // ルート優先度（'highway' = 高速優先 / 'local' = 下道優先）
  // Firebase destination ノードと双方向同期。トグル UI のソースオブトゥルース。
  String _routePreference = 'highway';

  // トグル切替時のデバウンス用タイマー（500ms 後に Firebase 書き込み + 再検索）
  Timer? _routePreferenceDebounceTimer;

  // 目的地候補をタップしてルート描画した直後の「プレビュー中」フラグ。
  // true の間は「このルートで出発」「やめる」フローティングを表示し、
  // ナビ開始系の処理（ヘディングアップ自動 ON、5秒後の現在地ズーム復帰）をスキップする。
  bool _isRoutePreview = false;

  // 目的地が Firebase に共有済みかどうか。
  // 自分が「ルート共有」ボタンを押した時、または他メンバーから受信した時に true。
  // トグル切替時の Firebase 書き込み判定に使う（true のときだけ書き込む）。
  bool _isShared = false;

  // ルート逸脱自動再検索
  DateTime? _lastRerouteTime;     // API 成功時刻（クールダウン基準）
  bool _rerouteInFlight = false;  // 再検索 API 応答待ちガード（多重発火防止）
  static const _rerouteThresholdHighSpeedMeters = 80.0;   // 50km/h 以上時の逸脱判定距離
  static const _rerouteThresholdLowSpeedMeters  = 30.0;   // 50km/h 未満時の逸脱判定距離
  static const _rerouteSpeedThresholdMps        = 13.89;  // 高低閾値の境界（50km/h）
  static const _rerouteCooldownSecs             = 20;     // 再検索間隔（秒）

  // 接続状態判定（last_seen の経過時間がこの値を超えたら「接続切れ」表示）
  static const _connectionStaleSecs = 60;
  // メンバーリストUIの経過時間表示を更新する間隔
  static const _connectionRefreshIntervalSecs = 10;

  // 警告ポイント関連
  Map<String, dynamic> _warnings = {};
  StreamSubscription? _warningsSubscription;
  Timer? _warningCleanupTimer;

  // 接続状態UI更新タイマー（last_seen からの経過時間表示を定期リフレッシュ）
  Timer? _connectionRefreshTimer;

  // 通知関連
  int _joinedAt = 0;
  StreamSubscription? _notificationsSubscription;
  final Map<String, Map<String, dynamic>> _pendingNotifications = {};
  final Set<String> _confirmedNotificationIds = {};
  final Map<String, Timer> _notificationHideTimers = {};
  final Map<String, Timer> _notificationRetryTimers = {};
  Timer? _blinkTimer;
  bool _blinkVisible = false;
  Color _blinkColor = Colors.transparent;
  Timer? _senderBlinkTimer;
  Timer? _senderAutoStopTimer;
  bool _senderBlinkVisible = false;
  Color _senderBlinkColor = Colors.transparent;

  // ヘディングアップ
  bool _headingUp = false;
  double _currentBearing = 0.0;
  double _currentSpeed = 0.0;  // 現在速度（m/s）。逸脱閾値の動的決定に使用
  double _currentZoom = 17.0;
  Timer? _routeOverviewTimer;
  bool _inRouteOverview = false;

  // 取得した全ルート（最大3本、Directions API alternatives=true で取得）
  List<_Route> _routes = [];
  // 選択中のルートインデックス（描画では太線オレンジで表示）
  int _selectedRouteIndex = 0;
  // 互換 getter（既存の _routePoints 参照を維持。選択中ルートの座標列を返す）
  List<LatLng> get _routePoints =>
      _routes.isEmpty ? const [] : _routes[_selectedRouteIndex].points;

  // 車両マーカーキャッシュ（vehicleType-isMe → BitmapDescriptor）
  final Map<String, BitmapDescriptor> _markerCache = {};

  // プレビュー中のルート色（最大3本対応）。0=赤, 1=青, 2=緑。
  // インデックスがこの長さを超えた場合はモジュロで巡回。
  static const _previewRouteColors = [
    Color(0xFFE53935), // 赤
    Color(0xFF1E88E5), // 青
    Color(0xFF43A047), // 緑
  ];

  // 逸脱判定調査用ログバッファ。最新200行保持。アプリ内ログ画面で表示。
  // 公開版にも入れて常時収集（メモリ消費は微小）。表示のオン/オフは _debugLogEnabled で制御。
  final List<String> _debugLogBuffer = [];
  static const int _debugLogMaxLines = 200;

  // 隠しデバッグメニュー（TouriLink ロゴ10回タップで解禁/無効）。
  // バグアイコン・位置オーバーライドボタン等の表示制御。
  bool _debugLogEnabled = false;
  int _debugTapCount = 0;
  DateTime? _lastDebugTapTime;

  void _appendDebugLog(String msg) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    _debugLogBuffer.add('$timestamp $msg');
    if (_debugLogBuffer.length > _debugLogMaxLines) {
      _debugLogBuffer.removeAt(0);
    }
  }


  // AdMob
  BannerAd? _bannerAd;
  bool _isBannerAdLoaded = false;

  DatabaseReference get _db => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://drivelink-a7ffb-default-rtdb.asia-southeast1.firebasedatabase.app',
      ).ref();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shareLocation = false;
    WakelockPlus.enable();
    _initAll();
    _loadBannerAd();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _locationSubscription?.cancel();
      _startLocationStream();
      _updateLocation();
    }
  }

  Future<void> _initAll() async {
    await Permission.locationWhenInUse.request();
    // Android 13以降: 通知権限が必須（フォアグラウンドサービス通知に必要）
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }
    await _updateLocation();
    _startLocationStream();
    _listenToMembers();
    _listenToDestination();
    _listenToWarnings();
    _joinedAt = DateTime.now().millisecondsSinceEpoch;
    await _cleanupExpiredNotifications();
    _listenToNotifications();
    _initAppLinks();
    await _startExpiryCheck();
    // 期限切れ警告ポイントを1分ごとに削除
    _warningCleanupTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _cleanupExpiredWarnings(),
    );
    // 接続状態の経過時間表示を定期更新（_membersは触らずsetStateだけ）
    _connectionRefreshTimer = Timer.periodic(
      const Duration(seconds: _connectionRefreshIntervalSecs),
      (_) {
        if (mounted) {
          setState(() {});
          _rebuildMarkers(); // マーカーのalphaも更新
        }
      },
    );
    // マップ読み込み完了後に位置共有確認ダイアログを表示
    WidgetsBinding.instance.addPostFrameCallback((_) => _showLocationSharingDialog());
  }

  Future<void> _showLocationSharingDialog() async {
    if (!mounted) return;
    final share = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        title: const Text(
          '⚠️ 再度確認！GPS情報を共有しますか？',
          style: TextStyle(color: Colors.red, fontSize: 17, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          '自宅・職場など普段いる場所での使用は避けてください。\nルーム入室後でも変更できます。',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('共有しない', style: TextStyle(color: Colors.grey, fontSize: 15)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D4FF),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('共有する', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final newValue = share ?? false;
    setState(() => _shareLocation = newValue);
    if (!newValue) {
      await _db.child('rooms/${widget.roomCode}/members/${widget.userId}').remove();
    } else {
      await _updateLocation();
    }
  }

  void _loadBannerAd() {
    _bannerAd = BannerAd(
      adUnitId: Platform.isIOS
          ? 'ca-app-pub-4544332023567609/6687240610'
          : 'ca-app-pub-4544332023567609/4801658317',
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _isBannerAdLoaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          debugPrint('バナー広告読み込み失敗: $error');
        },
      ),
    )..load();
  }

  Future<void> _startExpiryCheck() async {
    try {
      final snapshot = await _db.child('rooms/${widget.roomCode}/info/expires_at').get();
      if (!mounted) return;
      // Firebase は iOS で double を返す場合があるため num? でキャスト
      final expiresAt = (snapshot.value as num?)?.toInt();
      if (expiresAt == null || expiresAt <= 0) return;
      final remaining = expiresAt - DateTime.now().millisecondsSinceEpoch;
      if (remaining <= 0) {
        _exitDueToExpiry();
        return;
      }
      if (remaining > 5 * 60 * 1000) {
        Timer(Duration(milliseconds: remaining - 5 * 60 * 1000), () {
          if (!mounted) return;
          _startCountdown(expiresAt);
        });
      } else {
        _startCountdown(expiresAt);
      }
      _expiryTimer = Timer(Duration(milliseconds: remaining), () {
        if (mounted) _exitDueToExpiry();
      });
    } catch (e) {
      debugPrint('expiryCheck error: $e');
    }
  }

  void _startCountdown(int expiresAt) {
    _countdownTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      final remaining = expiresAt - DateTime.now().millisecondsSinceEpoch;
      if (remaining <= 0) {
        _exitDueToExpiry();
        return;
      }
      final minutes = (remaining / 60000).ceil();
      final hours = minutes ~/ 60;
      final mins = minutes % 60;
      setState(() {
        _remainingTime = hours > 0 ? '残り約${hours}時間${mins}分' : '残り約${mins}分';
      });
    });
    final remaining = expiresAt - DateTime.now().millisecondsSinceEpoch;
    final minutes = (remaining / 60000).ceil();
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    setState(() {
      _remainingTime = hours > 0 ? '残り約${hours}時間${mins}分' : '残り約${mins}分';
    });
  }

  void _exitDueToExpiry() {
    if (!mounted || _expiryHandled) return;
    _expiryHandled = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        title: const Text('ルームの有効期限が切れました', style: TextStyle(color: Colors.white)),
        content: const Text('ルームを退出します。', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _exitToLogin();
            },
            child: const Text('OK', style: TextStyle(color: Color(0xFFFF6B35))),
          ),
        ],
      ),
    );
  }

  /// ルーム退出時の共通処理：履歴クリア＋ログイン画面へ遷移
  Future<void> _exitToLogin() async {
    await RoomHistory.clear();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  Future<void> _initAppLinks() async {
    try {
      final initialLink = await _appLinks.getInitialLink();
      if (initialLink != null) _handleAppLink(initialLink);
    } catch (e) {
      debugPrint('AppLinks初期化エラー: $e');
    }
    _appLinkSubscription = _appLinks.uriLinkStream.listen(
      _handleAppLink,
      onError: (e) => debugPrint('AppLinksエラー: $e'),
    );
  }

  void _handleAppLink(Uri uri) {
    debugPrint('受信したURL: $uri');
    double? lat;
    double? lng;
    String name = '共有目的地';

    if (uri.scheme == 'drivevoice') {
      lat = double.tryParse(uri.queryParameters['lat'] ?? '');
      lng = double.tryParse(uri.queryParameters['lng'] ?? '');
      name = uri.queryParameters['name'] ?? '共有目的地';
    } else {
      // Google Maps URLから緯度経度を抽出
      final path = uri.toString();
      final atIndex = path.indexOf('@');
      if (atIndex != -1) {
        final afterAt = path.substring(atIndex + 1);
        final parts = afterAt.split(',');
        if (parts.length >= 2) {
          lat = double.tryParse(parts[0]);
          lng = double.tryParse(parts[1]);
        }
      }
      if (lat == null) {
        final qParam = uri.queryParameters['q'];
        if (qParam != null) {
          final parts = qParam.split(',');
          if (parts.length >= 2) {
            lat = double.tryParse(parts[0]);
            lng = double.tryParse(parts[1]);
          }
        }
      }
    }

    if (lat != null && lng != null) {
      if (mounted) {
        setState(() {
          _groupDestination = LatLng(lat!, lng!);
          _groupDestName = name;
        });
        _updateDestinationMarker();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('📍「$name」を目的地に設定しました'),
            backgroundColor: const Color(0xFF1A3A5C),
          ),
        );
      }
    }
  }

  void _listenToDestination() {
    _destSubscription = _db
        .child('rooms/${widget.roomCode}/destination')
        .onValue
        .listen((event) {
      final data = event.snapshot.value as Map?;
      if (!mounted) return;
      if (data == null) {
        setState(() {
          _groupDestination = null;
          _groupDestName = '';
          _routePreference = 'highway';
          _isRoutePreview = false;
          _isShared = false;
        });
        _updateDestinationMarker();
        return;
      }
      // routePreference は senderUid に関係なく全メンバーで同期する（自分が共有した値も Firebase 経由の変更を拾う）
      final rawPref = data['routePreference'] as String?;
      final validPref = (rawPref == 'highway' || rawPref == 'local') ? rawPref! : 'highway';
      if (_routePreference != validPref) {
        setState(() => _routePreference = validPref);
        debugPrint('[Phase2] routePreference 更新: $validPref');
      }
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final name = data['name'] as String? ?? '目的地';
      final senderUid = data['senderUid'] as String? ?? '';
      if (lat == null || lng == null) return;
      final newDest = LatLng(lat, lng);
      if (senderUid != widget.userId) {
        // 他メンバーが共有した目的地を受信したらプレビューを強制解除し、
        // Firebase 同期済み状態に遷移（_isShared=true）
        setState(() {
          _groupDestination = newDest;
          _groupDestName = name;
          _isRoutePreview = false;
          _isShared = true;
        });
        _updateDestinationMarker();
        _saveDestHistory(name, lat, lng);
      }
    });
  }

  // ── 警告ポイント ──────────────────────────────────────────────

  void _listenToWarnings() {
    _warningsSubscription = _db
        .child('rooms/${widget.roomCode}/warnings')
        .onValue
        .listen((event) {
      final data = event.snapshot.value as Map?;
      if (!mounted) return;
      if (data == null) {
        setState(() => _warnings = {});
        _rebuildMarkers();
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final updated = <String, dynamic>{};
      data.forEach((k, v) {
        final w = v as Map;
        final expiresAt = (w['expires_at'] as num?)?.toInt() ?? 0;
        if (expiresAt > now) updated[k.toString()] = v;
      });
      setState(() => _warnings = updated);
      _rebuildMarkers();
    });
  }

  Future<void> _addWarning(LatLng position) async {
    final id = _db.child('rooms/${widget.roomCode}/warnings').push().key!;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.child('rooms/${widget.roomCode}/warnings/$id').set({
      'lat': position.latitude,
      'lng': position.longitude,
      'senderUid': widget.userId,
      'senderNick': widget.nickname,
      'created_at': now,
      'expires_at': now + 30 * 60 * 1000,
    });
  }

  Future<void> _cleanupExpiredWarnings() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final snapshot = await _db.child('rooms/${widget.roomCode}/warnings').get();
    final data = snapshot.value as Map?;
    if (data == null) return;
    final updates = <String, dynamic>{};
    data.forEach((k, v) {
      final w = v as Map;
      final expiresAt = (w['expires_at'] as num?)?.toInt() ?? 0;
      if (expiresAt <= now) updates['$k'] = null;
    });
    if (updates.isNotEmpty) {
      await _db.child('rooms/${widget.roomCode}/warnings').update(updates);
    }
  }

  // ── 通知機能 ─────────────────────────────────────────────────────

  Future<void> _cleanupExpiredNotifications() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final snapshot = await _db.child('rooms/${widget.roomCode}/notifications').get();
    final data = snapshot.value as Map?;
    if (data == null) return;
    final updates = <String, dynamic>{};
    data.forEach((k, v) {
      final n = v as Map;
      final expiresAt = (n['expires_at'] as num?)?.toInt() ?? 0;
      if (expiresAt <= now) updates['$k'] = null;
    });
    if (updates.isNotEmpty) {
      await _db.child('rooms/${widget.roomCode}/notifications').update(updates);
    }
  }

  void _listenToNotifications() {
    _notificationsSubscription = _db
        .child('rooms/${widget.roomCode}/notifications')
        .onValue
        .listen(
      (event) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final data = event.snapshot.value as Map?;
        if (data == null) return;
        data.forEach((k, v) {
          final id = k.toString();
          final notification = Map<String, dynamic>.from(v as Map);
          final expiresAt = (notification['expires_at'] as num?)?.toInt() ?? 0;
          final createdAt = (notification['created_at'] as num?)?.toInt() ?? 0;
          final senderUid = notification['senderUid'] as String? ?? '';
          if (expiresAt <= now) return;
          if (createdAt <= _joinedAt) return;
          if (senderUid == widget.userId) return;
          if (_confirmedNotificationIds.contains(id)) return;
          if (_pendingNotifications.containsKey(id)) return;
          if (_notificationHideTimers.containsKey(id)) return;
          if (_notificationRetryTimers.containsKey(id)) return;
          _showNotification(id, notification);
        });
      },
      onError: (e) => debugPrint('notifications リスナーエラー: $e'),
    );
  }

  void _showNotification(String id, Map<String, dynamic> notification) {
    if (_confirmedNotificationIds.contains(id)) return;
    if (_pendingNotifications.containsKey(id)) return;
    setState(() => _pendingNotifications[id] = notification);
    _updateBlinking();

    _notificationHideTimers[id] = Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      _notificationHideTimers.remove(id);
      setState(() => _pendingNotifications.remove(id));
      _updateBlinking();

      _notificationRetryTimers[id] = Timer(const Duration(minutes: 3), () {
        if (!mounted) return;
        _notificationRetryTimers.remove(id);
        if (_confirmedNotificationIds.contains(id)) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        final expiresAt = (notification['expires_at'] as num?)?.toInt() ?? 0;
        if (expiresAt > now) _showNotification(id, notification);
      });
    });
  }

  void _confirmNotification(String id) {
    _confirmedNotificationIds.add(id);
    _notificationHideTimers[id]?.cancel();
    _notificationHideTimers.remove(id);
    _notificationRetryTimers[id]?.cancel();
    _notificationRetryTimers.remove(id);
    setState(() => _pendingNotifications.remove(id));
    _updateBlinking();
  }

  void _updateBlinking() {
    if (_pendingNotifications.isEmpty) {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      setState(() {
        _blinkVisible = false;
        _blinkColor = Colors.transparent;
      });
      return;
    }
    final types = _pendingNotifications.values.map((v) => v['type'] as String).toList();
    final color = types.contains('トラブル')
        ? Colors.red
        : types.contains('給油依頼')
            ? const Color(0xFF1E90FF)
            : Colors.green;
    setState(() => _blinkColor = color);
    if (_blinkTimer != null) return; // 既に点滅中
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _blinkVisible = !_blinkVisible);
    });
  }

  Future<void> _sendNotification(String type) async {
    await _cleanupExpiredNotifications();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.child('rooms/${widget.roomCode}/notifications').push().set({
      'type': type,
      'senderUid': widget.userId,
      'senderNick': widget.nickname,
      'created_at': now,
      'expires_at': now + 30 * 60 * 1000,
    });
    _startSenderBlink(type);
    if (mounted) {
      final icon = type == 'トラブル' ? '🆘' : type == '給油依頼' ? '⛽' : '🚻';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$icon $typeをメンバーに通知しました'),
        backgroundColor: const Color(0xFF1A3A5C),
      ));
    }
  }

  void _startSenderBlink(String type) {
    final color = type == 'トラブル'
        ? Colors.red
        : type == '給油依頼'
            ? const Color(0xFF1E90FF)
            : Colors.green;
    _senderBlinkTimer?.cancel();
    _senderAutoStopTimer?.cancel();
    setState(() {
      _senderBlinkColor = color;
      _senderBlinkVisible = true;
    });
    _senderBlinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _senderBlinkVisible = !_senderBlinkVisible);
    });
    _senderAutoStopTimer = Timer(const Duration(seconds: 30), () {
      _senderBlinkTimer?.cancel();
      _senderBlinkTimer = null;
      _senderAutoStopTimer = null;
      if (mounted) setState(() {
        _senderBlinkVisible = false;
        _senderBlinkColor = Colors.transparent;
      });
    });
  }

  Widget _buildNotificationBanners() {
    // created_at が最新の1件のみ表示（他は内部タイマーを継続）
    final latest = _pendingNotifications.entries.reduce((a, b) {
      final aTime = (a.value['created_at'] as num?)?.toInt() ?? 0;
      final bTime = (b.value['created_at'] as num?)?.toInt() ?? 0;
      return aTime >= bTime ? a : b;
    });
    return Column(
      children: [latest].map((entry) {
        final id = entry.key;
        final n = entry.value;
        final type = n['type'] as String? ?? '';
        final nick = n['senderNick'] as String? ?? '';
        final icon = type == 'トラブル' ? '🆘' : type == '給油依頼' ? '⛽' : '🚻';
        final color = type == 'トラブル'
            ? Colors.red
            : type == '給油依頼'
                ? const Color(0xFF1E90FF)
                : Colors.green;
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color, width: 1),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$icon $nickさんが$type',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _confirmNotification(id),
                style: ElevatedButton.styleFrom(
                  backgroundColor: color,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('確認', style: TextStyle(fontSize: 12, color: Colors.white)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildNotifyBtn({double? width}) {
    return PopupMenuButton<String>(
      onSelected: _sendNotification,
      color: const Color(0xFF1A3A5C),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (context) => const [
        PopupMenuItem(value: '給油依頼', child: Text('⛽ 給油依頼', style: TextStyle(color: Colors.white))),
        PopupMenuItem(value: 'トイレ依頼', child: Text('🚻 トイレ依頼', style: TextStyle(color: Colors.white))),
        PopupMenuItem(value: 'トラブル', child: Text('🆘 トラブル', style: TextStyle(color: Colors.white))),
      ],
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: _senderBlinkVisible
              ? _senderBlinkColor.withValues(alpha: 0.8)
              : const Color(0xFF2E4A6B),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_active, color: Colors.white, size: 22),
            SizedBox(height: 2),
            Text('通知', textAlign: TextAlign.center, maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  // ── ここまで通知機能 ──────────────────────────────────────────────

  BitmapDescriptor? _warningMarkerCache;

  Future<BitmapDescriptor> _getWarningMarker() async {
    if (_warningMarkerCache != null) return _warningMarkerCache!;
    // キャンバスサイズ: 幅52, 高さ70（ピンの先端を収めるため縦長）
    const w = 52.0;
    const h = 70.0;
    const r = 24.0; // 円の半径
    const cx = w / 2; // 円の中心X
    const cy = r + 2; // 円の中心Y（上から少し余白）

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // ピン形状（円 + 下向き三角）のパス
    final path = Path()
      ..addOval(Rect.fromCircle(center: const Offset(cx, cy), radius: r))
      ..moveTo(cx - r * 0.45, cy + r * 0.75)
      ..lineTo(cx + r * 0.45, cy + r * 0.75)
      ..lineTo(cx, h - 2)
      ..close();

    // 赤塗り
    canvas.drawPath(path, Paint()..color = const Color(0xFFD32F2F));
    // 白枠（円部分のみ）
    canvas.drawCircle(
      const Offset(cx, cy),
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // 白い「!」を円の中央に描画
    final tp = TextPainter(textDirection: TextDirection.ltr)
      ..text = const TextSpan(
          text: '!',
          style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Colors.white))
      ..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));

    final picture = recorder.endRecording();
    final image = await picture.toImage(w.toInt(), h.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
    // imagePixelRatio: 2.5 → 画面上の表示サイズ ≈ 幅21dp・高さ28dp
    _warningMarkerCache = BitmapDescriptor.bytes(
      bytes.buffer.asUint8List(),
      imagePixelRatio: 2.5,
    );
    return _warningMarkerCache!;
  }

  Future<BitmapDescriptor> _getVehicleMarker(String vehicleType, bool isMe) async {
    final key = '$vehicleType-$isMe';
    if (_markerCache.containsKey(key)) return _markerCache[key]!;

    final emoji = vehicleType == 'bike' ? '🏍' : '🚗';
    final bgColor = isMe ? const Color(0xFF1E90FF) : const Color(0xFFFF6B35);
    // 高解像度で描画して imagePixelRatio で縮小表示（約20dp）
    const size = 52.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // 背景円
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2 - 1,
      Paint()..color = bgColor,
    );
    // 白枠
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      size / 2 - 1,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // 絵文字
    final tp = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(text: emoji, style: const TextStyle(fontSize: 22))
      ..layout();
    tp.paint(canvas, Offset((size - tp.width) / 2, (size - tp.height) / 2));

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return BitmapDescriptor.defaultMarker;
    // imagePixelRatio: 2.5 → 画面上の表示サイズ = 52 / 2.5 ≈ 20dp
    final descriptor = BitmapDescriptor.bytes(
      bytes.buffer.asUint8List(),
      imagePixelRatio: 2.5,
    );
    _markerCache[key] = descriptor;
    return descriptor;
  }

  Future<void> _rebuildMarkers() async {
    // メンバーマーカーを再構築（警告マーカーを含む全マーカーを同期）
    final newMarkers = <Marker>{};

    // メンバーマーカー
    for (final entry in _members.entries) {
      final uid = entry.key;
      final m = entry.value as Map;
      if (m['lat'] == null || m['lng'] == null) continue;
      final lat = (m['lat'] as num).toDouble();
      final lng = (m['lng'] as num).toDouble();
      final nick = m['nickname'] as String? ?? '';
      final vehicleType = m['vehicle_type'] as String? ?? 'car';
      final isMe = uid == widget.userId;
      final icon = await _getVehicleMarker(vehicleType, isMe);
      final stale = !isMe && _isStale(m);
      newMarkers.add(Marker(
        markerId: MarkerId(uid),
        position: LatLng(lat, lng),
        icon: icon,
        alpha: stale ? 0.35 : 1.0,
        infoWindow: InfoWindow(title: nick),
      ));
    }

    // 目的地マーカー
    if (_groupDestination != null) {
      newMarkers.add(Marker(
        markerId: const MarkerId('destination'),
        position: _groupDestination!,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: InfoWindow(title: _groupDestName),
      ));
    }

    // 警告マーカー
    final warningIcon = await _getWarningMarker();
    _warnings.forEach((id, val) {
      final w = val as Map;
      final lat = (w['lat'] as num).toDouble();
      final lng = (w['lng'] as num).toDouble();
      final nick = w['senderNick'] as String? ?? '';
      newMarkers.add(Marker(
        markerId: MarkerId('warning_$id'),
        position: LatLng(lat, lng),
        icon: warningIcon,
        infoWindow: InfoWindow(
          title: '！ 注意喚起',
          snippet: '$nickが報告',
        ),
      ));
    });

    if (mounted) {
      setState(() => _markers = newMarkers);
    }
  }

  // ── ここまで警告ポイント ───────────────────────────────────────

  void _updateDestinationMarker() {
    final dest = _activeDestination;
    if (dest != null) {
      _fetchRoute(dest);
    } else {
      _inRouteOverview = false;
      _routeOverviewTimer?.cancel();
      setState(() {
        _polylines = {};
        _routes = [];
        _selectedRouteIndex = 0;
        _headingUp = false;
      });
      _animateCameraWithBearing(_myPosition, 0);
    }
    _rebuildMarkers();
  }

  Future<bool> _fetchRoute(LatLng dest, {bool isRerouting = false, bool force = false}) async {
    if (isRerouting && !force && _rerouteInFlight) return false;
    if (isRerouting) _rerouteInFlight = true;

    const apiKey = 'AIzaSyChuUZypiVhojgCO6ZgZML-ZW3eYLtti5c';
    String? failureReason; // null=成功 / 'ZERO_RESULTS' / 'OVER_QUERY_LIMIT' / 'EXCEPTION' / 'EMPTY' / その他status
    bool succeeded = false;
    try {
      final origin = '${_myPosition.latitude},${_myPosition.longitude}';
      final destination = '${dest.latitude},${dest.longitude}';
      final avoidParam = _routePreference == 'local' ? '&avoid=highways' : '';
      final url = 'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=$origin&destination=$destination'
          '&mode=driving&language=ja&alternatives=true$avoidParam&key=$apiKey';
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        final body = await response.transform(const Utf8Decoder()).join();
        final data = jsonDecode(body);
        final status = data['status'] as String?;
        if (status == 'OK') {
          final routesJson = data['routes'] as List;
          debugPrint('[Phase1] ルート取得: ${routesJson.length}本 (preference=$_routePreference)');
          final newRoutes = <_Route>[];
          for (int i = 0; i < routesJson.length; i++) {
            final leg = routesJson[i]['legs'][0];
            final summary = (routesJson[i]['summary'] as String?) ?? '';
            final duration = (leg['duration']['text'] as String?) ?? '';
            final distance = (leg['distance']['text'] as String?) ?? '';
            debugPrint('[Phase1]   [$i] summary="$summary" / $duration / $distance');
            final steps = leg['steps'] as List;
            final coords = <LatLng>[];
            for (final step in steps) {
              final encoded = step['polyline']['points'] as String;
              final pts = PolylinePoints.decodePolyline(encoded);
              coords.addAll(pts.map((p) => LatLng(p.latitude, p.longitude)));
            }
            if (coords.isNotEmpty) {
              newRoutes.add(_Route(
                points: coords,
                summary: summary,
                durationText: duration,
                distanceText: distance,
              ));
            }
          }
          if (newRoutes.isNotEmpty && mounted) {
            setState(() {
              _routes = newRoutes;
              // コース逸脱再検索後の選択ルート維持。範囲外なら 0 にフォールバック
              if (isRerouting) {
                if (_selectedRouteIndex >= newRoutes.length) {
                  _selectedRouteIndex = 0;
                }
              } else {
                _selectedRouteIndex = 0;
              }
              // 再検索時 / プレビュー中はヘディングアップ・追跡状態を変更しない
              // （プレビュー中はナビ開始扱いにせず、ユーザーが「このルートで出発」を押すまで保留）
              if (!isRerouting && !_isRoutePreview) {
                _headingUp = true;
                _isFollowingMember = false;
              }
            });
            debugPrint('[Phase5] ルート構築: ${newRoutes.length}本 (選択中=$_selectedRouteIndex, 通過済み着色=有効)');
            // [DEBUG-TEMP] 再検索完了ログ
            if (isRerouting) {
              final selPts = _selectedRouteIndex < newRoutes.length
                  ? newRoutes[_selectedRouteIndex].points.length
                  : 0;
              _appendDebugLog('[再検索完了] routes=${newRoutes.length}本 / 選択中=$_selectedRouteIndex / pts=$selPts');
            }
            _updatePassedRoute();
            if (!isRerouting) {
              // 前回のタイマーをキャンセル（5秒以内の再設定時の競合防止）
              _routeOverviewTimer?.cancel();
              // 縮退チェック（現在地と目的地が同じ場合は概観スキップ）
              final isSamePoint = (_myPosition.latitude - dest.latitude).abs() < 0.00001 &&
                  (_myPosition.longitude - dest.longitude).abs() < 0.00001;
              if (isSamePoint) {
                _animateCamera(CameraUpdate.newLatLngZoom(_myPosition, 17.0), programmatic: true);
              } else {
                // 現在地と目的地が両方見えるようズームアウト
                final bounds = LatLngBounds(
                  southwest: LatLng(
                    min(_myPosition.latitude, dest.latitude),
                    min(_myPosition.longitude, dest.longitude),
                  ),
                  northeast: LatLng(
                    max(_myPosition.latitude, dest.latitude),
                    max(_myPosition.longitude, dest.longitude),
                  ),
                );
                _inRouteOverview = true;
                _animateCamera(CameraUpdate.newLatLngBounds(bounds, 80), programmatic: true);
                // 5秒後に通常ズームへ自動復帰（プレビュー中はセットしない＝ユーザーが
                // 「このルートで出発」を押した時に _startNavigation がセットする）
                if (!_isRoutePreview) {
                  _routeOverviewTimer = Timer(const Duration(seconds: 5), () {
                    if (!mounted || _routePoints.isEmpty) return;
                    _inRouteOverview = false;
                    _currentZoom = 17.0;
                    // ユーザーが地図操作中（追従停止中）なら強制復帰しない
                    if (_isFollowingMember) return;
                    if (_headingUp) {
                      _moveCameraWithBearing(_myPosition, _currentBearing);
                    } else {
                      _animateCamera(CameraUpdate.newLatLngZoom(_myPosition, 17.0), programmatic: true);
                    }
                  });
                }
              }
            }
            succeeded = true;
          } else {
            failureReason = 'EMPTY';
          }
        } else {
          failureReason = status ?? 'UNKNOWN';
        }
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('ルート取得エラー: $e');
      failureReason = 'EXCEPTION';
    } finally {
      if (isRerouting) _rerouteInFlight = false;
    }

    if (succeeded) {
      if (isRerouting) _lastRerouteTime = DateTime.now();
      return true;
    }
    if (failureReason != null) _showRouteFailureSnackBar(failureReason);
    return false;
  }

  void _showRouteFailureSnackBar(String reason) {
    if (!mounted) return;
    String message;
    switch (reason) {
      case 'ZERO_RESULTS':
        message = 'ルートが見つかりませんでした';
        break;
      case 'OVER_QUERY_LIMIT':
        message = 'APIの利用制限に達しました（しばらくお待ちください）';
        break;
      default:
        message = 'ルート取得に失敗しました';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ── 目的地履歴 ───────────────────────────────────────────────
  static const _historyKey = 'dest_history';
  static const _historyMax = 3;

  Future<List<Map<String, dynamic>>> _loadDestHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null) return [];
    try {
      return List<Map<String, dynamic>>.from(
        (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)),
      );
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveDestHistory(String name, double lat, double lng) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await _loadDestHistory();
    // 同名の重複を除去してから先頭に追加
    history.removeWhere((e) => e['name'] == name);
    history.insert(0, {'name': name, 'lat': lat, 'lng': lng});
    if (history.length > _historyMax) history.removeRange(_historyMax, history.length);
    await prefs.setString(_historyKey, jsonEncode(history));
  }

  // ── ここまで目的地履歴 ────────────────────────────────────────

  Future<void> _setPersonalDestination() async {
    final TextEditingController searchCtrl = TextEditingController();
    List<Map<String, dynamic>> searchResults = [];
    List<Map<String, dynamic>> history = await _loadDestHistory();
    bool isSearching = false;
    const placesApiKey = 'AIzaSyChuUZypiVhojgCO6ZgZML-ZW3eYLtti5c';

    void selectDest(BuildContext ctx, String name, double lat, double lng) {
      setState(() {
        _groupDestination = LatLng(lat, lng);
        _groupDestName = name;
        _isRoutePreview = true;
        // 新規目的地検索時は「高速優先」にリセット。
        // 前回「下道優先」のまま検索すると意図せず狭い道が選ばれることがあるため。
        _routePreference = 'highway';
      });
      _updateDestinationMarker();
      _saveDestHistory(name, lat, lng);
      Navigator.pop(ctx);
    }

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          // 横画面（縦の利用可能領域が狭い）でも検索結果と「現在地を目的地に設定」が
          // 全部見えるよう、ダイアログ全体を縦スクロール可能にする
          scrollable: true,
          backgroundColor: const Color(0xFF0D1B2A),
          title: const Text('🔍 目的地を検索', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: searchCtrl,
                  style: const TextStyle(color: Colors.white),
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '場所・お店・住所を検索...',
                    hintStyle: const TextStyle(color: Colors.grey),
                    prefixIcon: const Icon(Icons.search, color: Color(0xFF00D4FF)),
                    suffixIcon: isSearching
                        ? const SizedBox(width: 20, height: 20, child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00D4FF))))
                        : null,
                    enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00D4FF))),
                  ),
                  onChanged: (val) async {
                    if (val.length < 2) {
                      setStateDialog(() => searchResults = []);
                      return;
                    }
                    setStateDialog(() => isSearching = true);
                    try {
                      final encoded = Uri.encodeComponent(val);
                      final url = 'https://maps.googleapis.com/maps/api/place/textsearch/json?query=$encoded&language=ja&region=jp&key=$placesApiKey';
                      final client = HttpClient();
                      try {
                        final request = await client.getUrl(Uri.parse(url));
                        final response = await request.close();
                        final body = await response.transform(const Utf8Decoder()).join();
                        final data = jsonDecode(body);
                        if (data['status'] == 'OK') {
                          final results = (data['results'] as List).take(5).map((r) {
                            final loc = r['geometry']['location'];
                            return {
                              'name': r['name'] as String,
                              'address': r['formatted_address'] as String? ?? '',
                              'lat': (loc['lat'] as num).toDouble(),
                              'lng': (loc['lng'] as num).toDouble(),
                            };
                          }).toList();
                          setStateDialog(() {
                            searchResults = List<Map<String, dynamic>>.from(results);
                            isSearching = false;
                          });
                        } else {
                          setStateDialog(() { searchResults = []; isSearching = false; });
                        }
                      } finally {
                        client.close();
                      }
                    } catch (e) {
                      setStateDialog(() { searchResults = []; isSearching = false; });
                    }
                  },
                ),
                // 履歴（検索結果がないときだけ表示）
                if (searchResults.isEmpty && history.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    const Icon(Icons.history, color: Colors.grey, size: 14),
                    const SizedBox(width: 4),
                    const Text('最近の目的地', style: TextStyle(color: Colors.grey, fontSize: 11)),
                  ]),
                  const SizedBox(height: 4),
                  ...history.map((h) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history, color: Color(0xFF6680AA), size: 18),
                    title: Text(h['name'] as String, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    onTap: () => selectDest(ctx, h['name'] as String, h['lat'] as double, h['lng'] as double),
                  )),
                ],
                const SizedBox(height: 4),
                // 検索結果は最大5件のため Column に展開（AlertDialog.scrollable=true との競合回避）
                if (searchResults.isNotEmpty)
                  ...searchResults.map((r) => ListTile(
                        leading: const Icon(Icons.place, color: Color(0xFF00D4FF)),
                        title: Text(r['name'], style: const TextStyle(color: Colors.white, fontSize: 14)),
                        subtitle: Text(r['address'], style: const TextStyle(color: Colors.grey, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => selectDest(ctx, r['name'] as String, r['lat'] as double, r['lng'] as double),
                      )),
                const SizedBox(height: 4),
                TextButton.icon(
                  icon: const Icon(Icons.my_location, color: Color(0xFF00D4FF), size: 18),
                  label: const Text('現在地を目的地に設定', style: TextStyle(color: Color(0xFF00D4FF))),
                  onPressed: () {
                    setState(() {
                      _groupDestination = _myPosition;
                      _groupDestName = '現在地';
                      _isRoutePreview = true;
                      _routePreference = 'highway';
                    });
                    _updateDestinationMarker();
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ),
          ),
          actions: [
            if (_groupDestination != null)
              TextButton(
                onPressed: () {
                  setState(() {
                    _groupDestination = null;
                    _groupDestName = '';
                    _isRoutePreview = false;
                    _isShared = false;
                  });
                  _updateDestinationMarker();
                  Navigator.pop(ctx);
                },
                child: const Text('目的地をリセット', style: TextStyle(color: Colors.redAccent)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareGroupDestination() async {
    if (_groupDestination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先に目的地を設定してください'), backgroundColor: Colors.redAccent),
      );
      return;
    }
    // Phase A-3: プレビュー中の暗黙ナビ開始を撤廃。
    // _buildActionButtonItems 側で _isRoutePreview=true 中はボタン非活性化済みのため、
    // ここに到達するのは「このルートで出発」確定後（_isRoutePreview=false）のみ。
    final dest = _activeDestination!;
    final name = _activeDestName;
    await _db.child('rooms/${widget.roomCode}/destination').set({
      'lat': dest.latitude,
      'lng': dest.longitude,
      'name': name,
      'senderUid': widget.userId,
      'senderNick': widget.nickname,
      'shared_at': DateTime.now().millisecondsSinceEpoch,
      'routePreference': _routePreference,
    });
    if (mounted) {
      setState(() => _isShared = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('📍 「$name」をグループに共有しました'), backgroundColor: const Color(0xFF1A3A5C)),
      );
    }
  }

  /// last_seen からの経過秒数を返す。null/不正値は null を返す。
  int? _secondsSinceLastSeen(Map memberData) {
    final raw = memberData['last_seen'];
    if (raw is! num) return null;
    final lastSeenMs = raw.toInt();
    final diffMs = DateTime.now().millisecondsSinceEpoch - lastSeenMs;
    if (diffMs < 0) return 0; // 未来時刻（時計ズレ）→ 0扱い
    return diffMs ~/ 1000;
  }

  /// 接続切れ判定（last_seen が無い場合は false=接続中扱い）
  bool _isStale(Map memberData) {
    final secs = _secondsSinceLastSeen(memberData);
    return secs != null && secs >= _connectionStaleSecs;
  }

  /// 経過時間の表示文字列を返す。60秒未満 or null は空文字。
  String _formatElapsed(Map memberData) {
    final secs = _secondsSinceLastSeen(memberData);
    if (secs == null || secs < _connectionStaleSecs) return '';
    if (secs < 3600) return '${secs ~/ 60}分前';
    return '${secs ~/ 3600}時間前';
  }

  void _listenToMembers() {
    _membersSubscription = _db
        .child('rooms/${widget.roomCode}/members')
        .onValue
        .listen(
      (event) {
        final data = event.snapshot.value as Map?;
        if (data == null) return;
        final updated = <String, dynamic>{};
        data.forEach((k, v) => updated[k.toString()] = v);
        if (mounted) {
          setState(() => _members = updated);
          _rebuildMarkers();
        }
      },
      onError: (e) => debugPrint('members リスナーエラー: $e'),
    );
  }

  LocationSettings _buildLocationSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: 'バックグラウンドで位置情報を更新中',
          notificationTitle: 'TouriLink',
          enableWakeLock: true,
        ),
      );
    } else if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );
  }

  void _startLocationStream() {
    _locationSubscription = Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(),
    ).listen((pos) async {
      if (!mounted) return;
      setState(() => _myPosition = LatLng(pos.latitude, pos.longitude));
      final spd = pos.speed;
      // 負値（取得不可）は 0 扱い。bearing ガードの外で常に更新
      _currentSpeed = spd > 0 ? spd : 0.0;
      // 速度が十分な場合のみbearingを更新（停車中の誤検知を防ぐ）
      if (spd > 0.5 && pos.heading >= 0) {
        _currentBearing = pos.heading;
      }
      if (_shareLocation) {
        await _db.child('rooms/${widget.roomCode}/members/${widget.userId}').update({
          'nickname': widget.nickname,
          'lat': pos.latitude,
          'lng': pos.longitude,
          'vehicle_type': widget.vehicleType,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
        });
      }
      if (!mounted) return;
      // 追従停止中（_isFollowingMember==true）はヘディングアップでもカメラを動かさない
      if (!_inRouteOverview && !_isFollowingMember) {
        if (_headingUp) {
          _moveCameraWithBearing(_myPosition, _currentBearing);
        } else {
          _animateCamera(CameraUpdate.newLatLng(_myPosition), programmatic: true);
        }
      }
      _checkRouteDeviation();
      _updatePassedRoute();
    }, onError: (e) {
      debugPrint('位置情報ストリームエラー: $e');
    });
  }

  Future<void> _updateLocation() async {
    if (_updateLocationInProgress) return;
    _updateLocationInProgress = true;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        final requested = await Geolocator.requestPermission();
        if (requested == LocationPermission.denied ||
            requested == LocationPermission.deniedForever) {
          _locationSubscription?.cancel();
          return;
        }
      }
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() => _myPosition = LatLng(pos.latitude, pos.longitude));
      if (_shareLocation) {
        await _db.child('rooms/${widget.roomCode}/members/${widget.userId}').update({
          'nickname': widget.nickname,
          'lat': pos.latitude,
          'lng': pos.longitude,
          'vehicle_type': widget.vehicleType,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
        });
      }
      if (!mounted) return;
      // 追従停止中（_isFollowingMember==true）はヘディングアップでもカメラを動かさない
      if (!_inRouteOverview && !_isFollowingMember) {
        if (_headingUp) {
          _moveCameraWithBearing(_myPosition, _currentBearing);
        } else {
          _animateCamera(CameraUpdate.newLatLngZoom(_myPosition, 17.0), programmatic: true);
        }
      }
      // ルート逸脱チェック
      _checkRouteDeviation();
    } catch (e) {
      debugPrint('位置情報エラー: $e');
    } finally {
      _updateLocationInProgress = false;
    }
  }

  void _checkRouteDeviation() {
    if (_routePoints.isEmpty || _groupDestination == null) {
      final msg = '[逸脱] skip: empty=${_routePoints.isEmpty}, destNull=${_groupDestination == null}';
      debugPrint(msg);
      _appendDebugLog(msg);
      return;
    }

    // 再検索 API 応答待ち中はスキップ（多重発火防止）
    if (_rerouteInFlight) {
      debugPrint('[逸脱] skip: inFlight');
      _appendDebugLog('[逸脱] skip: inFlight');
      return;
    }

    // クールダウン中はスキップ（成功時のみ消費される）
    final now = DateTime.now();
    if (_lastRerouteTime != null &&
        now.difference(_lastRerouteTime!).inSeconds < _rerouteCooldownSecs) {
      debugPrint('[逸脱] skip: cooldown');
      _appendDebugLog('[逸脱] skip: cooldown');
      return;
    }

    final points = _routePoints;
    if (points.isEmpty) {
      debugPrint('[逸脱] skip: points空（getter経由 - 異常）');
      _appendDebugLog('[逸脱] skip: points空（getter経由 - 異常）');
      return;
    }

    final dist = _distanceToPolyline(_myPosition, points);
    // 速度連動の動的閾値：50km/h以上は80m（高速並行誤検知抑制）、未満は30m（市街地で機敏に）
    final threshold = _currentSpeed >= _rerouteSpeedThresholdMps
        ? _rerouteThresholdHighSpeedMeters
        : _rerouteThresholdLowSpeedMeters;
    final detLog = '[逸脱判定] dist=${dist.toStringAsFixed(0)}m / thr=${threshold.toStringAsFixed(0)}m / 速度=${(_currentSpeed * 3.6).toStringAsFixed(1)}km/h / pts=${points.length}';
    debugPrint(detLog);
    _appendDebugLog(detLog);
    if (dist > threshold) {
      debugPrint('[逸脱] 検知 → 再検索');
      _appendDebugLog('[逸脱] 検知 → 再検索');
      _fetchRoute(_groupDestination!, isRerouting: true);
    }
  }

  /// 現在地からポリライン（各線分）までの最短距離（メートル）を返す
  double _distanceToPolyline(LatLng point, List<LatLng> polylinePoints) {
    if (polylinePoints.length == 1) return _metersTo(point, polylinePoints[0]);
    double minDist = double.infinity;
    for (int i = 0; i < polylinePoints.length - 1; i++) {
      final d = _distanceToSegment(point, polylinePoints[i], polylinePoints[i + 1]);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  /// 点 p から線分 a-b までの最短距離（メートル）
  double _distanceToSegment(LatLng p, LatLng a, LatLng b) {
    final cosLat = cos(p.latitude * pi / 180);
    // 局所平面座標に変換（メートル）
    final px = (p.longitude - a.longitude) * cosLat * 111320;
    final py = (p.latitude  - a.latitude)           * 111320;
    final dx = (b.longitude - a.longitude) * cosLat * 111320;
    final dy = (b.latitude  - a.latitude)           * 111320;
    final lenSq = dx * dx + dy * dy;
    if (lenSq == 0) return sqrt(px * px + py * py);
    final t = ((px * dx + py * dy) / lenSq).clamp(0.0, 1.0);
    return sqrt(pow(px - t * dx, 2) + pow(py - t * dy, 2));
  }

  /// 2点間の距離（メートル）
  double _metersTo(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude  - a.latitude)  * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final sinLat = sin(dLat / 2);
    final sinLng = sin(dLng / 2);
    final h = sinLat * sinLat +
        cos(a.latitude * pi / 180) * cos(b.latitude * pi / 180) * sinLng * sinLng;
    return r * 2 * atan2(sqrt(h), sqrt(1 - h));
  }

  void _animateCamera(CameraUpdate update, {required bool programmatic}) {
    if (_mapController == null) return;
    if (programmatic) {
      _lastProgrammaticMoveAt = DateTime.now();
    }
    _mapController!.animateCamera(update);
  }

  // Phase A-4: 「現在地へ戻る」ボタンのダブルタップで全メンバーが画面に収まる範囲にズーム。
  // - 自分から 10km 超のメンバーは除外し、SnackBar で通知
  // - tilt 0、bearing 0、padding 80 の真俯瞰
  // - _isFollowingMember=true を維持: GPS update のカメラ上書きをガード（行 1437/1479/1069）
  // - 自分のみ or 全員遠すぎる場合は自分中心ズーム17にフォールバック
  void _zoomToAllMembers() {
    if (_mapController == null) return;
    final List<LatLng> points = [_myPosition];
    final List<String> excluded = [];
    for (final entry in _members.entries) {
      final uid = entry.key;
      if (uid == widget.userId) continue;
      final m = entry.value as Map;
      if (m['lat'] == null || m['lng'] == null) continue;
      final lat = (m['lat'] as num).toDouble();
      final lng = (m['lng'] as num).toDouble();
      final pos = LatLng(lat, lng);
      if (_metersTo(pos, _myPosition) > 10000) {
        excluded.add(m['nickname'] as String? ?? '?');
        continue;
      }
      points.add(pos);
    }
    if (excluded.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${excluded.join('、')}さんは10km以上離れているため範囲外'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    if (points.length < 2) {
      // 自分のみ → 自分中心ズーム17にフォールバック（ナビ中の3D解除も兼ねて真俯瞰）
      setState(() {
        _isFollowingMember = false;
        _currentZoom = 17.0;
      });
      _animateCamera(
        CameraUpdate.newLatLngZoom(_myPosition, 17.0),
        programmatic: true,
      );
      return;
    }
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
    _lastProgrammaticMoveAt = DateTime.now();
    // 先に tilt/bearing を即時リセット（newLatLngBounds は target/zoom のみ更新のため）
    _mapController!.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: _myPosition,
          bearing: 0,
          tilt: 0,
          zoom: _currentZoom,
        ),
      ),
    );
    // 次に bounds に合わせてズーム調整
    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 80),
    );
  }

  // Phase A-4: ナビ確定後（_isRoutePreview=false かつ _routes.isNotEmpty）の
  // カメラ表示用設定を返すヘルパー。
  // - ナビ中: 自車を画面下1/3 に置くため bearing 方向に 200m オフセット、tilt 60度の3Dビュー
  //   （初回 100m では中央寄りすぎたため 200m に拡大）
  // - それ以外（プレビュー中・目的地なし・案内終了直後）: target そのまま、tilt 0
  // 約数 111320 は 1度あたりの緯度メートル換算。経度は cos(lat) で補正。
  ({LatLng target, double tilt}) _navCameraConfig(LatLng position, double bearing) {
    final isNavigating = !_isRoutePreview && _routes.isNotEmpty;
    if (!isNavigating) {
      return (target: position, tilt: 0.0);
    }
    const offsetMeters = 200.0;
    final dx = sin(bearing * pi / 180) * offsetMeters;
    final dy = cos(bearing * pi / 180) * offsetMeters;
    final cosLat = cos(position.latitude * pi / 180);
    final offsetLat = position.latitude + dy / 111320;
    final offsetLng = position.longitude + dx / (111320 * cosLat);
    return (target: LatLng(offsetLat, offsetLng), tilt: 60.0);
  }

  void _animateCameraWithBearing(LatLng target, double bearing) {
    if (_mapController == null) return;
    _lastProgrammaticMoveAt = DateTime.now();
    final config = _navCameraConfig(target, bearing);
    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: config.target,
          bearing: bearing,
          zoom: _currentZoom,
          tilt: config.tilt,
        ),
      ),
    );
  }

  // GPS追従用：bearingを設定してカメラ移動（animateCamera経由）
  void _moveCameraWithBearing(LatLng target, double bearing) {
    if (_mapController == null) return;
    _lastProgrammaticMoveAt = DateTime.now();
    final config = _navCameraConfig(target, bearing);
    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: config.target,
          bearing: bearing,
          zoom: _currentZoom,
          tilt: config.tilt,
        ),
      ),
    );
  }

  // 走行中の通過済み着色更新。実体は _rebuildPolylines() に移譲。
  void _updatePassedRoute() {
    _rebuildPolylines();
  }

  // ルートポリラインを再構築。プレビュー中とナビ中で表示が大きく変わる。
  // - プレビュー中: 全ルートを 3 色（赤/青/緑）で描画。選択中は太線。
  // - ナビ中: 選択中ルートのみオレンジで描画（通過済みは灰色）。代替ルートは非表示。
  void _rebuildPolylines() {
    if (!mounted || _routes.isEmpty) return;
    if (_selectedRouteIndex < 0 || _selectedRouteIndex >= _routes.length) return;
    final selectedPoints = _routes[_selectedRouteIndex].points;
    if (selectedPoints.isEmpty) return;

    final newPolylines = <Polyline>{};

    if (_isRoutePreview) {
      // プレビュー中: 全ルートを 3 色で描画。選択中を太線＋前面、代替を細線＋背面。
      for (int i = 0; i < _routes.length; i++) {
        final pts = _routes[i].points;
        if (pts.length < 2) continue;
        final isSelected = i == _selectedRouteIndex;
        final color = _previewRouteColors[i % _previewRouteColors.length];
        newPolylines.add(Polyline(
          polylineId: PolylineId('route_$i'),
          points: pts,
          color: color,
          width: isSelected ? 8 : 5,
          zIndex: isSelected ? 3 : 1,
        ));
      }
    } else {
      // ナビ中: 選択中ルートの通過済み判定（現在地から最も近い点のインデックス）
      int closestIdx = 0;
      double minDist = double.infinity;
      for (int i = 0; i < selectedPoints.length; i++) {
        final d = _metersTo(_myPosition, selectedPoints[i]);
        if (d < minDist) {
          minDist = d;
          closestIdx = i;
        }
      }
      final passed = selectedPoints.sublist(0, closestIdx + 1);
      final remaining = selectedPoints.sublist(closestIdx);

      // 通過済み（灰色、中間）
      if (passed.length >= 2) {
        newPolylines.add(Polyline(
          polylineId: PolylineId('route_${_selectedRouteIndex}_passed'),
          points: passed,
          color: Colors.grey.withValues(alpha: 0.35),
          width: 5,
          zIndex: 2,
        ));
      }
      // 残り（オレンジ、最前面）
      if (remaining.length >= 2) {
        newPolylines.add(Polyline(
          polylineId: PolylineId('route_${_selectedRouteIndex}_remaining'),
          points: remaining,
          color: const Color(0xFFFF6B35),
          width: 6,
          zIndex: 3,
        ));
      }
    }

    setState(() => _polylines = newPolylines);
  }


  @override
  void dispose() {
    WakelockPlus.disable();
    _locationSubscription?.cancel();
    _countdownTimer?.cancel();
    _expiryTimer?.cancel();
    _warningCleanupTimer?.cancel();
    _connectionRefreshTimer?.cancel();
    _routeOverviewTimer?.cancel();
    _routePreferenceDebounceTimer?.cancel();
    _membersSubscription?.cancel();
    _destSubscription?.cancel();
    _warningsSubscription?.cancel();
    _notificationsSubscription?.cancel();
    _blinkTimer?.cancel();
    _senderBlinkTimer?.cancel();
    _senderAutoStopTimer?.cancel();
    for (final t in _notificationHideTimers.values) { t.cancel(); }
    for (final t in _notificationRetryTimers.values) { t.cancel(); }
    _appLinkSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _db.child('rooms/${widget.roomCode}/members/${widget.userId}').remove();
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(
      builder: (context, orientation) {
        if (orientation == Orientation.landscape) {
          return _buildLandscapeLayout();
        }
        return _buildPortraitLayout();
      },
    );
  }

  Future<void> _toggleLocationSharing() async {
    final newValue = !_shareLocation;
    setState(() => _shareLocation = newValue);
    if (!newValue) {
      // OFF: Firebaseから自分の位置情報を削除（他ユーザーに見えなくなる）
      await _db.child('rooms/${widget.roomCode}/members/${widget.userId}').remove();
    } else {
      // ON: 即座に現在位置をFirebaseに送信
      await _updateLocation();
    }
  }

  void _showQrDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        title: const Text('QRコード', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: 'https://drivelink-a7ffb.web.app/join?room=${widget.roomCode}',
                version: QrVersions.auto,
                size: 220,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.roomCode,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 4),
            const Text('このQRコードを仲間に読み取ってもらおう',
                style: TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる', style: TextStyle(color: Color(0xFF00D4FF))),
          ),
        ],
      ),
    );
  }

  void _shareRoomCode() {
    final link = 'https://drivelink-a7ffb.web.app/join?room=${widget.roomCode}';
    SharePlus.instance.share(ShareParams(text: 'TouriLinkで一緒にツーリングしよう！\nリンクをタップしてルームに参加👇\n$link\n\nリンクが使えない場合はルームコード: ${widget.roomCode}'));
  }

  // 縦向きレイアウト
  // 縦・横レイアウト共用の AppBar（Phase A-2 で抽出）
  PreferredSizeWidget _buildPrimaryAppBar() {
    return AppBar(
      backgroundColor: _blinkVisible ? _blinkColor.withValues(alpha: 0.4) : const Color(0xFF0A1628),
      titleSpacing: 12,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // TouriLink ロゴ：10回連打で隠しデバッグメニュー解禁/無効を切替
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onLogoTapped,
            child: Text('TouriLink',
                style: GoogleFonts.audiowide(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          Text('ルーム: ${widget.roomCode} | ${_members.length}人が走行中',
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
      actions: [
        // 隠しデバッグメニュー（TouriLink ロゴ10回タップで解禁時のみ表示）
        if (_debugLogEnabled)
          IconButton(
            tooltip: '逸脱判定ログ',
            icon: const Icon(Icons.bug_report, color: Colors.purple),
            onPressed: _showDebugLogDialog,
          ),
        // 位置共有スイッチ（GPSラベル付き）
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'GPS',
              style: TextStyle(
                color: _shareLocation ? Colors.green : Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            Switch(
              value: _shareLocation,
              activeThumbColor: Colors.green,
              inactiveThumbColor: Colors.grey,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (_) => _toggleLocationSharing(),
            ),
          ],
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          color: const Color(0xFF0D1B2A),
          onSelected: (value) {
            if (value == 'qr') _showQrDialog();
            if (value == 'share') _shareRoomCode();
          },
          itemBuilder: (ctx) => [
            const PopupMenuItem(
              value: 'qr',
              child: Row(children: [
                Icon(Icons.qr_code_rounded, color: Colors.white, size: 20),
                SizedBox(width: 10),
                Text('QRコードを表示', style: TextStyle(color: Colors.white)),
              ]),
            ),
            const PopupMenuItem(
              value: 'share',
              child: Row(children: [
                Icon(Icons.share_rounded, color: Colors.white, size: 20),
                SizedBox(width: 10),
                Text('ルームを共有', style: TextStyle(color: Colors.white)),
              ]),
            ),
          ],
        ),
        TextButton.icon(
          icon: const Icon(Icons.exit_to_app, color: Colors.white, size: 18),
          label: const Text('退出', style: TextStyle(color: Colors.white, fontSize: 13)),
          onPressed: _exitToLogin,
        ),
      ],
    );
  }

  Widget _buildPortraitLayout() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      appBar: _buildPrimaryAppBar(),
      body: SafeArea(
        bottom: true,
        child: Column(
          children: [
            if (_remainingTime.isNotEmpty) _buildTimerBanner(),
            _buildRoutePreferenceToggle(),
            Expanded(child: _buildMap()),
            _buildBottomSection(),
            if (_isBannerAdLoaded) _buildAdBanner(),
          ],
        ),
      ),
    );
  }

  // 横向きレイアウト（Phase A-2 で全面書き換え）
  // 上部: 縦画面と共用ヘッダー / 左帯: アクションボタン縦並び / 中央〜右: マップ（A-1 と同じ吹き出し+メンバーリスト） / 下端: 広告
  Widget _buildLandscapeLayout() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      appBar: _buildPrimaryAppBar(),
      body: SafeArea(
        bottom: true,
        child: Column(
          children: [
            if (_remainingTime.isNotEmpty) _buildTimerBanner(),
            _buildRoutePreferenceToggle(),
            Expanded(
              child: Row(
                children: [
                  // 左帯: アクションボタン縦並び（width 60 + padding 4*2 + 余白 = 約76px）
                  Container(
                    width: 76,
                    color: const Color(0xFF0D1B2A),
                    child: SingleChildScrollView(
                      child: _buildActionButtonsVertical(),
                    ),
                  ),
                  // 中央〜右: マップ（縦画面と同じ吹き出し+メンバーリスト）
                  Expanded(child: _buildMap()),
                ],
              ),
            ),
            // 通知バナーは横画面でもマップ下に表示
            if (_pendingNotifications.isNotEmpty) _buildNotificationBanners(),
            if (_isBannerAdLoaded) _buildAdBanner(),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    return Stack(
      children: [
        GoogleMap(
        initialCameraPosition: CameraPosition(target: _myPosition, zoom: 17),
        markers: _markers,
        polylines: _polylines,
        onMapCreated: (c) => _mapController = c,
        onCameraMove: (position) {
          _currentZoom = position.zoom;
        },
        onCameraMoveStarted: () {
          // 直近のプログラム移動から短時間内ならプログラム由来とみなして無視。
          // それ以外（アニメ中の遅延発火含む）はユーザー操作とみなす。
          if (_lastProgrammaticMoveAt != null &&
              DateTime.now().difference(_lastProgrammaticMoveAt!).inMilliseconds <
                  _programmaticMoveGuardMs) {
            return;
          }
          setState(() => _isFollowingMember = true);
        },
        myLocationEnabled: false,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        padding: EdgeInsets.zero,
        onLongPress: (latLng) async {
          final result = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF0D1B2A),
              title: const Text('この地点をどうしますか？', style: TextStyle(color: Colors.white, fontSize: 16)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.place, color: Color(0xFF00D4FF)),
                    title: const Text('目的地に設定', style: TextStyle(color: Colors.white)),
                    onTap: () => Navigator.pop(ctx, 'destination'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
                    title: const Text('注意喚起を報告', style: TextStyle(color: Colors.white)),
                    onTap: () => Navigator.pop(ctx, 'warning'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
                ),
              ],
            ),
          );
          if (!mounted) return;
          if (result == 'destination') {
            const name = 'マップで選択した地点';
            setState(() {
              _groupDestination = latLng;
              _groupDestName = name;
              _isRoutePreview = true;
              _routePreference = 'highway';
            });
            _updateDestinationMarker();
            _saveDestHistory(name, latLng.latitude, latLng.longitude);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('📍 目的地を設定しました'),
                backgroundColor: Color(0xFF1A3A5C),
              ),
            );
          } else if (result == 'warning') {
            await _addWarning(latLng);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('！ 注意喚起を報告しました（30分間表示）'),
                  backgroundColor: Color(0xFF1A3A5C),
                ),
              );
            }
          }
        },
        ),
        // 現在地に戻るFAB（追従停止中のみ表示・ピル型・中央下）
        if (_isFollowingMember)
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  // Phase A-4: ナビ中はオフセット + tilt 60 維持で復帰、それ以外はズーム17の真俯瞰
                  final isNavigating = !_isRoutePreview && _routes.isNotEmpty;
                  setState(() {
                    _isFollowingMember = false;
                    _currentZoom = 17.0;
                  });
                  if (isNavigating) {
                    _animateCameraWithBearing(_myPosition, _currentBearing);
                  } else {
                    _animateCamera(
                      CameraUpdate.newLatLngZoom(_myPosition, 17.0),
                      programmatic: true,
                    );
                  }
                },
                // Phase A-4: ダブルタップで全メンバーが画面に収まる範囲にズーム
                onDoubleTap: _zoomToAllMembers,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00D4FF),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.my_location, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text(
                        '現在地へ戻る',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // ヘディングアップ ON/OFF ボタン
        Positioned(
          right: 12,
          bottom: 12,
          child: GestureDetector(
            onTap: () {
              final newVal = !_headingUp;
              setState(() {
                _headingUp = newVal;
                if (newVal) _isFollowingMember = false;
              });
              if (newVal) {
                _animateCameraWithBearing(_myPosition, _currentBearing);
              } else {
                _animateCameraWithBearing(_myPosition, 0);
              }
            },
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _headingUp
                    ? const Color(0xFF00D4FF)
                    : const Color(0xFF1A3A5C).withValues(alpha: 0.9),
                shape: BoxShape.circle,
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
              ),
              child: Icon(
                Icons.navigation,
                color: _headingUp ? Colors.white : Colors.white70,
                size: 24,
              ),
            ),
          ),
        ),
        // プレビュー中のみ表示するフローティングアクション。
        // 「このルートで出発」= Firebase 共有でグループに確定 / 「やめる」= ローカル破棄して再検索ダイアログ
        if (_isRoutePreview && _groupDestination != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 90,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: _confirmRouteAndStartNav,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF6B35),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.navigation, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'このルートで出発',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: _cancelRoutePreview,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A3A5C).withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                      ),
                      child: const Text(
                        'やめる',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        // プレビュー中: 画面左端に縦並びでルート選択吹き出しを表示（Phase A-1 で右→左に移動）。
        // 各吹き出しの色は対応するルート色（赤/青/緑）と一致させる。
        // 選択中は白い太枠線で強調。タップで _selectRoute(i)。
        if (_isRoutePreview && _routes.isNotEmpty)
          Positioned(
            left: 12,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < _routes.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: GestureDetector(
                        onTap: () => _selectRoute(i),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: _previewRouteColors[i % _previewRouteColors.length],
                            borderRadius: BorderRadius.circular(14),
                            border: i == _selectedRouteIndex
                                ? Border.all(color: Colors.white, width: 3)
                                : null,
                            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6)],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _routes[i].durationText,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                _routes[i].distanceText,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        // マップ右上にメンバーリスト縦並び（Phase A-1 で下部横スクロールから移動）
        Positioned(
          right: 6,
          top: 6,
          child: _buildMemberListOverlay(),
        ),
      ],
    );
  }

  // TouriLink ロゴ10回連打で隠しデバッグメニューの有効/無効を切替。
  // 直近2秒以内の連続タップのみカウントし、それ以外でリセット。
  void _onLogoTapped() {
    final now = DateTime.now();
    if (_lastDebugTapTime != null &&
        now.difference(_lastDebugTapTime!).inSeconds > 2) {
      _debugTapCount = 0;
    }
    _debugTapCount++;
    _lastDebugTapTime = now;

    if (_debugTapCount >= 10) {
      setState(() {
        _debugLogEnabled = !_debugLogEnabled;
        _debugTapCount = 0;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_debugLogEnabled ? '🐛 デバッグメニュー有効' : 'デバッグメニュー無効'),
            duration: const Duration(seconds: 1),
            backgroundColor: const Color(0xFF1A3A5C),
          ),
        );
      }
    }
  }

  // 逸脱判定ログ画面（隠しデバッグメニュー）
  void _showDebugLogDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('逸脱判定ログ（新しい順）'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: _debugLogBuffer.isEmpty
              ? const Center(child: Text('（ログ未取得）'))
              : ListView.builder(
                  itemCount: _debugLogBuffer.length,
                  itemBuilder: (c, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      _debugLogBuffer[_debugLogBuffer.length - 1 - i],
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _debugLogBuffer.clear());
              Navigator.pop(ctx);
            },
            child: const Text('クリア'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  // 吹き出しタップで選択中ルートを切替。polyline のみ再構築（吹き出しは Widget なので setState で自動更新）。
  void _selectRoute(int index) {
    if (index < 0 || index >= _routes.length) return;
    if (index == _selectedRouteIndex) return;
    setState(() => _selectedRouteIndex = index);
    _rebuildPolylines();
  }

  // ナビ開始処理（共通ヘルパー）。
  // プレビュー中フラグの解除、ヘディングアップ ON、追跡解除、即座に現在地ズームへ移動。
  // 「このルートで出発」と「ルート共有（プレビュー中の直接共有）」の両方から呼ぶ。
  void _startNavigation() {
    setState(() {
      _isRoutePreview = false;
      _headingUp = true;
      _isFollowingMember = false;
      _inRouteOverview = false;
      _currentZoom = 17.0;
    });
    // プレビュー（3色） → ナビ（選択ルートのみオレンジ）に切替
    _rebuildPolylines();
    _routeOverviewTimer?.cancel();
    if (_headingUp) {
      _moveCameraWithBearing(_myPosition, _currentBearing);
    } else {
      _animateCamera(CameraUpdate.newLatLngZoom(_myPosition, 17.0), programmatic: true);
    }
  }

  // 「このルートで出発」: 自分のルートを確定してナビ開始。Firebase は触らない。
  // 共有したい時は別途「ルート共有」ボタンを押す。
  void _confirmRouteAndStartNav() {
    _startNavigation();
  }

  // プレビューを破棄して目的地検索ダイアログを再表示する。
  // _groupDestination をローカルでクリアするだけで Firebase には触れない
  // （プレビュー中は元々書き込んでいないため、他メンバーへの影響はない）。
  void _cancelRoutePreview() {
    _routeOverviewTimer?.cancel();
    setState(() {
      _groupDestination = null;
      _groupDestName = '';
      _isRoutePreview = false;
      _isShared = false;
      _polylines = {};
      _routes = [];
      _selectedRouteIndex = 0;
      _headingUp = false;
      _inRouteOverview = false;
    });
    _updateDestinationMarker();
    _setPersonalDestination();
  }

  // トグルタップハンドラ：500ms デバウンス後に Firebase 書き込み + 即再検索
  // クールダウン無視で即発火するため _fetchRoute に force: true を渡す
  // プレビュー中は Firebase 書き込みをスキップし、ローカル再検索のみ走らせる
  void _onRoutePreferenceToggle(String newPref) {
    if (_routePreference == newPref) return;
    setState(() => _routePreference = newPref);
    _routePreferenceDebounceTimer?.cancel();
    _routePreferenceDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      debugPrint('[Phase6] トグル → preference=$newPref (debounced, preview=$_isRoutePreview, shared=$_isShared)');
      // Firebase に共有済みの時のみ書き込む。プレビュー中・ローカル確定中はローカル再検索のみ。
      if (_isShared) {
        _persistRoutePreference();
      }
      if (_groupDestination != null) {
        _fetchRoute(_groupDestination!, isRerouting: true, force: true);
      }
    });
  }

  // routePreference を Firebase の destination ノードに部分パス書き込み（他フィールドは保護）
  Future<void> _persistRoutePreference() async {
    if (_groupDestination == null) return;
    await _db
        .child('rooms/${widget.roomCode}/destination/routePreference')
        .set(_routePreference);
  }

  // ルート優先度トグル（iOS Settings 風）
  // 目的地未設定時は非表示。タップで _routePreference を切替し 500ms デバウンスで再検索。
  Widget _buildRoutePreferenceToggle() {
    if (_groupDestination == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EFE8),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          _buildToggleSegment(
            label: '🛣 高速優先',
            isSelected: _routePreference == 'highway',
            onTap: () => _onRoutePreferenceToggle('highway'),
          ),
          _buildToggleSegment(
            label: '🚗 下道優先',
            isSelected: _routePreference == 'local',
            onTap: () => _onRoutePreferenceToggle('local'),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleSegment({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFFF6B35) : Colors.transparent,
            borderRadius: BorderRadius.circular(17),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: isSelected
                  ? Colors.white
                  : const Color(0xFF5F5E5A),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimerBanner() {
    final isWarning = _remainingTime.contains('分') && !_remainingTime.contains('時間');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: isWarning ? const Color(0xFFFF6B35).withValues(alpha: 0.9) : const Color(0xFF1A3A5C),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _remainingTime,
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: isWarning ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomSection() {
    return Container(
      color: _blinkVisible ? _blinkColor.withValues(alpha: 0.25) : const Color(0xFF0D1B2A),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pendingNotifications.isNotEmpty) ...[
            _buildNotificationBanners(),
            const SizedBox(height: 4),
          ],
          _buildActionButtons(),
        ],
      ),
    );
  }

  // アクションボタン4つ（目的地/ルート共有/速度注意/通知）の Widget リストを返却。
  // 縦並び（横画面・左帯）と横並び（縦画面・bottom）の両方で使う共通化ヘルパー（Phase A-2 で新設）。
  List<Widget> _buildActionButtonItems(double btnWidth) {
    return [
      _buildActionBtn(
        icon: _polylines.isNotEmpty ? Icons.stop : Icons.place,
        label: _polylines.isNotEmpty ? '案内終了' : '目的地',
        color: _polylines.isNotEmpty
            ? Colors.redAccent
            : _groupDestination != null
                ? const Color(0xFF1E90FF)
                : const Color(0xFF1A3A5C),
        onTap: _polylines.isNotEmpty
            ? () {
                setState(() {
                  _groupDestination = null;
                  _groupDestName = '';
                  _polylines = {};
                  _routes = [];
                  _selectedRouteIndex = 0;
                  _headingUp = false;
                  _isRoutePreview = false;
                  _isShared = false;
                });
                _animateCameraWithBearing(_myPosition, 0);
                _updateDestinationMarker();
              }
            : _setPersonalDestination,
        width: btnWidth,
      ),
      // プレビュー中（3ルート表示中）は共有不可。「このルートで出発」でナビ確定後のみ有効
      _buildActionBtn(
        icon: Icons.share,
        label: 'ルート共有',
        color: (_groupDestination != null && !_isRoutePreview)
            ? const Color(0xFF00D4FF)
            : Colors.grey.shade800,
        onTap: (_groupDestination != null && !_isRoutePreview)
            ? _shareGroupDestination
            : null,
        width: btnWidth,
      ),
      _buildActionBtn(
        icon: Icons.warning_amber_rounded,
        label: '速度注意',
        color: const Color(0xFFB71C1C),
        onTap: () async {
          await _addWarning(_myPosition);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('！ 注意喚起を報告しました（30分間表示）'),
                backgroundColor: Color(0xFF1A3A5C),
              ),
            );
          }
        },
        width: btnWidth,
      ),
      _buildNotifyBtn(width: btnWidth),
    ];
  }

  // 縦画面 bottom 用：横並び 4ボタン（既存のレイアウト維持）
  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const int buttonCount = 4;
          const double spacing = 8.0;
          final double btnWidth =
              ((constraints.maxWidth - spacing * (buttonCount - 1)) / buttonCount)
                  .clamp(60.0, 100.0);
          final items = _buildActionButtonItems(btnWidth);
          return Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              for (int i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(width: spacing),
                items[i],
              ],
            ],
          );
        },
      ),
    );
  }

  // 横画面 左帯用：縦並び 4ボタン（Phase A-2 で新設、width 60 固定）
  Widget _buildActionButtonsVertical() {
    const double spacing = 8.0;
    final items = _buildActionButtonItems(60.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: spacing),
            items[i],
          ],
        ],
      ),
    );
  }

  Widget _buildActionBtn({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
    double? width,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdBanner() {
    return Container(
      alignment: Alignment.center,
      width: _bannerAd!.size.width.toDouble(),
      height: _bannerAd!.size.height.toDouble(),
      child: AdWidget(ad: _bannerAd!),
    );
  }

  // マップ右上に重ねて表示する縦並びメンバーリスト（Phase A-1 で新設）。
  // 縦・横レイアウト共用。max-height は画面高の 50% で SingleChildScrollView でラップ。
  Widget _buildMemberListOverlay() {
    final uids = _members.keys.toList();
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < uids.length; i++) ...[
              if (i > 0) const SizedBox(height: 3),
              Builder(
                builder: (context) {
                  final uid = uids[i];
                  final m = _members[uid] as Map;
                  if (m['lat'] == null || m['lng'] == null) {
                    return const SizedBox.shrink();
                  }
                  final nick = m['nickname'] as String? ?? '?';
                  final lat = (m['lat'] as num).toDouble();
                  final lng = (m['lng'] as num).toDouble();
                  final dist = _metersTo(LatLng(lat, lng), _myPosition) / 1000;
                  final isMe = uid == widget.userId;
                  final stale = !isMe && _isStale(m);
                  // 名前は最大3文字、4文字以上は末尾省略
                  final shortName = nick.length <= 3 ? nick : '${nick.substring(0, 3)}…';
                  return GestureDetector(
                    onTap: () {
                      setState(() => _isFollowingMember = true);
                      _mapController?.animateCamera(
                        CameraUpdate.newLatLng(LatLng(lat, lng)),
                      );
                    },
                    child: Opacity(
                      opacity: stale ? 0.4 : 1.0,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 38),
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0D1B2A).withValues(alpha: 0.85),
                          border: Border.all(color: Colors.white, width: 1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 8,
                              backgroundColor: isMe
                                  ? const Color(0xFF1E90FF)
                                  : const Color(0xFFFF6B35),
                              child: Text(
                                nick.isNotEmpty ? nick[0].toUpperCase() : '?',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              shortName,
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: const TextStyle(color: Colors.white, fontSize: 8),
                            ),
                            Text(
                              isMe
                                  ? '自分'
                                  : (stale ? _formatElapsed(m) : '${dist.toStringAsFixed(1)}km'),
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                color: stale ? const Color(0xFFFFB74D) : Colors.grey[400],
                                fontSize: 7,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Directions API から取得した 1 本のルート情報。複数ルート (alternatives=true) の保持に使用。
class _Route {
  final List<LatLng> points;
  final String summary;
  final String durationText;
  final String distanceText;
  const _Route({
    required this.points,
    required this.summary,
    required this.durationText,
    required this.distanceText,
  });
}
