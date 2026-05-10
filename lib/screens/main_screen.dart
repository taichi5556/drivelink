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
import '../services/tts_service.dart';
import 'login_screen.dart';
import 'search_screen.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:share_plus/share_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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

class _MainScreenState extends State<MainScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  GoogleMapController? _mapController;
  bool _isFollowingMember = false;
  late bool _shareLocation;
  // アプリ自身が直近にカメラを動かした時刻。onCameraMoveStartedの発火が
  // ユーザー操作由来かプログラム由来かをタイムスタンプ差で判定するために使う。
  DateTime? _lastProgrammaticMoveAt;
  // この時間以内のonCameraMoveStartedはプログラム由来とみなす（ms）
  static const _programmaticMoveGuardMs = 100;
  // バックグラウンドからの復帰直後は GoogleMap widget の再構成や GPS 再取得で
  // onCameraMoveStarted が誤発火し、追従が解除されてしまうケースがある。
  // 復帰時刻を記録しておき、一定時間内の発火はプログラム由来とみなす。
  DateTime? _lastResumedAt;
  static const _resumeGuardMs = 1500;
  Set<Marker> _markers = {};
  // 生 GPS 値。ステップ判定 / 逸脱判定 / 距離計算など全ロジックで使用。
  LatLng _myPosition = const LatLng(35.6812, 139.7671);
  // 一度でも実 GPS を取得したか。検索のロケーションバイアスは fix 済みの時のみ適用
  // （初期値の東京駅で bias して遠隔地ユーザーの結果を歪めないため）。
  bool _hasGpsFix = false;
  // 目的地検索のデバウンス用（300ms）。連打時の API 浪費 + race condition 抑制。
  Timer? _searchDebounceTimer;
  // Phase B-5: 自車マーカーの表示位置（_myPosition への補間後）。
  // 約 500ms tween でジャンプを滑らかに見せる。生ロジックには使わない。
  LatLng _displayMyPosition = const LatLng(35.6812, 139.7671);
  LatLng _animFrom = const LatLng(35.6812, 139.7671);
  LatLng _animTo = const LatLng(35.6812, 139.7671);
  AnimationController? _markerAnimController;
  // 初回 GPS 取得済みフラグ。初回はデフォルト東京座標から現在地へ tween しないようスナップ。
  bool _hasFirstFix = false;
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
  // M-1d: ユーザー追加経由地（順序保持）。via: でルートに通過点として渡す
  final List<LatLng> _waypoints = [];
  final List<String> _waypointNames = [];
  // M-1d 到着判定: 経由地ごとの「まもなく経由地」発話済みフラグ。_waypoints と同期維持
  final List<bool> _waypointSaidNear = [];
  StreamSubscription? _appLinkSubscription;
  final _appLinks = AppLinks();
  LatLng? get _activeDestination => _groupDestination;
  String get _activeDestName => _groupDestName;

  // ルート優先度（'highway' = 高速優先 / 'local' = 一般道優先）
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

  // Uターン回避用 waypoint（B-6 逆走検知 / B-7 残距離増加検知の再検索時のみ適用）
  // 進行方向に少し先の点を waypoint として渡し、物理的に Uターン不可能なルートを生成させる。
  static const _waypointMinSpeedMps   = 1.389; // 5 km/h（これ未満では waypoint 追加しない）
  static const _waypointLookaheadSec  = 3.0;   // 速度 × この秒数 = waypoint までの距離

  // Phase F-1: 停車時 bearing 固定。速度がこの値未満の時は GPS bearing 更新を止め
  // 直近の値を維持する（停車・徐行・室内 GPS ジッタで画面がぐるぐる回るのを防ぐ）。
  static const _bearingUpdateMinSpeedMps = 0.55; // 約 2 km/h

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

  // Phase B-2: ステップ判定（投影方式 + 3秒デバウンス）
  // ナビ中の現在 step。B-3 案内バナーが「次の曲がる場所まで N m」を出すために使用。
  int _currentStepIndex = 0;
  // 切替候補。位置更新ごとに最近接 step を計算し、現 step と異なれば候補にする。
  int? _pendingStepIndex;
  // 候補が初めて検出された時刻。経過 >= 3秒で切替確定（GPS ジッタ・分岐点の誤判定を吸収）。
  DateTime? _pendingSince;
  static const Duration _stepDebounceDuration = Duration(seconds: 3);

  // Phase C-2: 音声案内の tier 管理
  // step が切り替わるたびに _announcedTiers をリセットし、開始時点で既に通過済みの
  // tier（500/100/30）は announced 扱いにして読み上げをスキップ（plan A：過去 tier 無音化）。
  int _lastVoiceStepIdx = -1;
  Set<int> _announcedTiers = <int>{};

  // 2D/3D 表示モード。デフォルト 2D（_is3D=false）。永続化キー: 'map_tilt_mode'（'2D'/'3D'）
  // 3D: ナビ中 tilt=60 + 自車下寄せ / 2D: ナビ中も tilt=0 + 自車中心
  bool _is3D = false;
  static const _kMapTiltModeKey = 'map_tilt_mode';

  // Phase B-7: 残り距離増加検知（90° ズレで B-6 がヒットしないケースを補完）
  // GPS tick ごとに _remainingDistanceMeters を記録、10秒前比で +100m 以上増 + 速度 5km/h 以上で再検索。
  // Cooldown は B-6 と共用（_lastRerouteTime / _rerouteCooldownSecs / _rerouteInFlight）。
  final List<_DistSample> _distSamples = [];
  static const Duration _distHistoryDuration = Duration(seconds: 10);
  static const double _distIncreaseThresholdMeters = 100.0;
  static const double _distIncreaseSpeedMps = 5.0 / 3.6; // 5 km/h


  // Phase B-6: 逆走検知 → 自動再検索
  // 速度 >= 18km/h かつ 走行方向と進路方向の角度差 >= 135° が連続3秒で確定 → _fetchRoute(reroute) 発火。
  // 多重発火防止は逸脱判定と同じ _rerouteInFlight / _lastRerouteTime（_rerouteCooldownSecs=20s）を共用。
  static const double _reverseSpeedThresholdMps = 5.0; // 18km/h
  static const double _reverseAngleThresholdDeg = 135.0;
  static const Duration _reverseDebounceDuration = Duration(seconds: 3);
  DateTime? _reverseSince;

  // 車両マーカーキャッシュ（vehicleType-isMe → BitmapDescriptor）
  final Map<String, BitmapDescriptor> _markerCache = {};

  // プレビュー中のルート色（最大3本対応）。0=赤, 1=青, 2=緑。
  // インデックスがこの長さを超えた場合はモジュロで巡回。
  static const _previewRouteColors = [
    Color(0xFFE53935), // 赤
    Color(0xFF1E88E5), // 青
    Color(0xFF43A047), // 緑
  ];

  // Phase D-1: ナビシート (DraggableScrollableSheet) 制御用。
  // ナビ確定直後に展開→5秒で折りたたみ。ユーザー操作（指タップ）でタイマー即キャンセル。
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  Timer? _sheetAutoCollapseTimer;
  // _buildNavigationSheet で計算した実 min/max を animateTo で再利用するためキャッシュ
  double _sheetMinSize = 0.06;
  double _sheetMaxSize = 0.40;
  // GestureDetector でシート全体を縦ドラッグする際に jumpTo 量を画面比に換算するため parentH を保持
  double _sheetParentH = 0.0;

  // 逸脱判定調査用ログバッファ。最新200行保持。アプリ内ログ画面で表示。
  // 公開版にも入れて常時収集（メモリ消費は微小）。表示のオン/オフは _debugLogEnabled で制御。
  final List<String> _debugLogBuffer = [];
  static const int _debugLogMaxLines = 200;

  // 隠しデバッグメニュー（TouriLink ロゴ10回タップで解禁/無効）。
  // バグアイコン・位置オーバーライドボタン等の表示制御。
  bool _debugLogEnabled = false;
  int _debugTapCount = 0;
  DateTime? _lastDebugTapTime;
  // GPS偽装トグル（隠しメニュー）。ON で位置を東京駅に固定し
  // _locationSubscription をキャンセル → ナビロジック連鎖停止
  bool _gpsSpoofEnabled = false;
  static const LatLng _kSpoofPosition = LatLng(35.6812, 139.7671);  // 東京駅

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
    // Phase C-1: 音声案内サービス初期化（fire-and-forget。完了前の speak は no-op）
    // 完了後に setState することで、シート上のトグル Switch が永続化済の状態を反映する
    TtsService.instance.init().then((_) {
      if (mounted) setState(() {});
    });
    // 2D/3D モード復元（fire-and-forget。未設定/読込前は 2D デフォルト）
    SharedPreferences.getInstance().then((p) {
      final v = p.getString(_kMapTiltModeKey);
      if (mounted) setState(() => _is3D = (v == '3D'));
    });
    // Phase B-5: 自車マーカー位置の補間用 AnimationController。
    // GPS 受信ごとに duration 500ms で _animFrom → _animTo へ tween。
    // listener 内で _displayMyPosition を更新し、_markers の自車だけ高速差替え。
    _markerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..addListener(_onMarkerAnimTick);
    _initAll();
    _loadBannerAd();
  }

  // Phase B-5: アニメーション tick ごとに自車マーカー位置を更新。
  // フル _rebuildMarkers は呼ばず、Set 内の自車エントリだけ position を差し替える同期処理。
  void _onMarkerAnimTick() {
    if (!mounted) return;
    final t = _markerAnimController?.value ?? 1.0;
    final lat = _animFrom.latitude + (_animTo.latitude - _animFrom.latitude) * t;
    final lng = _animFrom.longitude + (_animTo.longitude - _animFrom.longitude) * t;
    _displayMyPosition = LatLng(lat, lng);
    final myUid = widget.userId;
    final updated = <Marker>{};
    for (final m in _markers) {
      if (m.markerId.value == myUid) {
        updated.add(m.copyWith(positionParam: _displayMyPosition));
      } else {
        updated.add(m);
      }
    }
    setState(() => _markers = updated);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 復帰前の追従状態を記憶（_isFollowingMember=false が追従中）
      final wasFollowing = !_isFollowingMember;
      // 復帰直後の onCameraMoveStarted 誤発火による追従解除を防ぐためのガード起点
      _lastResumedAt = DateTime.now();
      // iOS では onCameraMoveStarted が resume guard 期限後に遅延発火し、
      // 追従が解除されてしまうケースがある。その保険として、復帰前が追従中
      // なら一定時間後に強制復元する。
      if (wasFollowing) {
        Future.delayed(const Duration(milliseconds: 2500), () {
          if (mounted && _isFollowingMember) {
            setState(() => _isFollowingMember = false);
          }
        });
      }
      // GPS 偽装中は復帰時の GPS 再起動をスキップ（意図しない解除を回避）
      if (_gpsSpoofEnabled) return;
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

  /// 退出ボタン押下時の確認ダイアログ。OK 時のみ _exitToLogin を呼ぶ。
  /// barrierDismissible: true で背景タップ・キャンセルともに退出しない。
  Future<void> _confirmExitToLogin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        title: const Text(
          'ルームから退出しますか？',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'キャンセル',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '退出',
              style: TextStyle(
                color: Color(0xFFFF453A), // iOS systemRed（destructive）
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _exitToLogin();
    }
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
          _waypoints.clear();
          _waypointNames.clear();
          _waypointSaidNear.clear();
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
        // M-1 経由地共有: waypoints を List/Map 両形式でパース
        // （Firebase Realtime DB は List を numeric-keyed Map として保存することがある）
        final newWaypoints = <LatLng>[];
        final newWaypointNames = <String>[];
        void parseWp(dynamic wp) {
          if (wp is! Map) return;
          final wlat = (wp['lat'] as num?)?.toDouble();
          final wlng = (wp['lng'] as num?)?.toDouble();
          final wname = wp['name'] as String? ?? '経由地';
          if (wlat != null && wlng != null) {
            newWaypoints.add(LatLng(wlat, wlng));
            newWaypointNames.add(wname);
          }
        }
        final wpsRaw = data['waypoints'];
        if (wpsRaw is List) {
          for (final wp in wpsRaw) {
            parseWp(wp);
          }
        } else if (wpsRaw is Map) {
          final entries = wpsRaw.entries.toList()
            ..sort((a, b) {
              final ai = int.tryParse(a.key.toString()) ?? 0;
              final bi = int.tryParse(b.key.toString()) ?? 0;
              return ai.compareTo(bi);
            });
          for (final e in entries) {
            parseWp(e.value);
          }
        }
        // 他メンバーが共有した目的地を受信したらプレビューを強制解除し、
        // Firebase 同期済み状態に遷移（_isShared=true）
        setState(() {
          _groupDestination = newDest;
          _groupDestName = name;
          _isRoutePreview = false;
          _isShared = true;
          _waypoints
            ..clear()
            ..addAll(newWaypoints);
          _waypointNames
            ..clear()
            ..addAll(newWaypointNames);
          _waypointSaidNear
            ..clear()
            ..addAll(List.filled(newWaypoints.length, false));
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

  // Phase A-6: 車両アイコンに名前ラベルを焼き込み。
  // Canvas 144x104（円64x64 + ラベル領域 144x40）。円は Canvas 横幅の中央上に配置、
  // ラベルは Canvas 横幅をフル活用して 5文字+省略（「タロウ太…」等）が確実に収まるサイズ。
  // ニックネームは最大4文字、5文字以上は末尾「…」省略。空文字時はラベル無し（透過）。
  // Marker 側で anchor=(0.5, 0.308) を指定して円中心(72,32)が地点位置に来るようにする。
  Future<BitmapDescriptor> _getVehicleMarker(String vehicleType, bool isMe, String nickname) async {
    final key = '$vehicleType-$isMe-$nickname';
            if (_markerCache.containsKey(key)) return _markerCache[key]!;

    final emoji = vehicleType == 'bike' ? '🏍' : '🚗';
    final bgColor = isMe ? const Color(0xFF1E90FF) : const Color(0xFFFF6B35);
    const double iconSize = 64.0;             // 円直径
    const double canvasWidth = 144.0;         // Canvas 横幅（ラベル収納用）
    const double labelHeight = 40.0;
    const double canvasHeight = iconSize + labelHeight; // 104
    const double circleCx = canvasWidth / 2;  // 72
    const double circleCy = iconSize / 2;     // 32
    const double circleR = iconSize / 2 - 1;  // 31

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // ── 上半分：円アイコン（Canvas 中央上に配置）──
    canvas.drawCircle(
      const Offset(circleCx, circleCy),
      circleR,
      Paint()..color = bgColor,
    );
    // 白枠
    canvas.drawCircle(
      const Offset(circleCx, circleCy),
      circleR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // 絵文字
    final tp = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(text: emoji, style: const TextStyle(fontSize: 28))
      ..layout();
    tp.paint(canvas, Offset(circleCx - tp.width / 2, circleCy - tp.height / 2));

    // ── 下半分：名前ラベル（空文字時はスキップ）──
    if (nickname.isNotEmpty) {
      final shortName = nickname.length <= 4
          ? nickname
          : '${nickname.substring(0, 4)}…';

      const double labelLeft = 4.0;
      const double labelRight = canvasWidth - 4;        // 140
      const double labelTop = iconSize + 2;              // 66
      const double labelBottom = canvasHeight - 2;       // 102
      final labelRect = RRect.fromLTRBR(
        labelLeft, labelTop, labelRight, labelBottom,
        const Radius.circular(4),
      );
      // 白背景
      canvas.drawRRect(labelRect, Paint()..color = Colors.white);
      // 細い黒枠（マップ背景に対する視認性確保）
      canvas.drawRRect(
        labelRect,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5,
      );
      // 黒テキスト中央寄せ
      final labelTp = TextPainter(
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )
        ..text = TextSpan(
          text: shortName,
          style: const TextStyle(
            fontSize: 26,
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        )
        ..layout(maxWidth: labelRight - labelLeft);
      labelTp.paint(
        canvas,
        Offset(
          (canvasWidth - labelTp.width) / 2,
          labelTop + (labelBottom - labelTop - labelTp.height) / 2,
        ),
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasWidth.toInt(), canvasHeight.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) {
            return BitmapDescriptor.defaultMarker;
    }
    // imagePixelRatio: 2.5 → 画面上の表示サイズ = 64 / 2.5 ≈ 25.6dp（円部分）
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
            final icon = await _getVehicleMarker(vehicleType, isMe, nick);
      final stale = !isMe && _isStale(m);
      // Phase B-5: 自車だけ補間後の表示位置を使う（ジャンプを tween で滑らかに見せる）
      final pos = isMe ? _displayMyPosition : LatLng(lat, lng);
      if (isMe) {
              }
      newMarkers.add(Marker(
        markerId: MarkerId(uid),
        position: pos,
        icon: icon,
        // Phase A-6: 画像 144x104 のうち円中心(72,32)を地点位置にアンカー
        // 32/104 ≈ 0.308。これでラベル分のズレを補正
        anchor: const Offset(0.5, 0.308),
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

    // M-1d: 経由地マーカー（hueOrange、目的地の hueBlue と区別）
    for (int i = 0; i < _waypoints.length; i++) {
      newMarkers.add(Marker(
        markerId: MarkerId('waypoint_$i'),
        position: _waypoints[i],
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(
          title: _waypointNames[i],
          snippet: '経由地 ${i + 1}',
        ),
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

  /// M-1e fix: 経由地モードで SearchScreen を起動し、結果に応じて
  /// 経由地追加 / 経由地全クリアを実行する。
  Future<void> _addWaypointFromSearch() async {
    if (!mounted) return;
    final result = await Navigator.push<SearchResultAction>(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(
        currentPosition: _myPosition,
        hasGpsFix: _hasGpsFix,
        history: const [],
        hasActiveDestination: false,
        hasActiveRoute: true,
        waypointCount: _waypoints.length,
        isWaypointMode: true,
        placesApiKey: 'AIzaSyChuUZypiVhojgCO6ZgZML-ZW3eYLtti5c',
      )),
    );
    if (!mounted || result == null) return;
    if (result.type == 'waypoint') {
      await _addWaypoint(LatLng(result.lat!, result.lng!), result.name!);
    } else if (result.type == 'clear_waypoints') {
      await _clearWaypoints();
    }
  }

  /// M-1e fix: 経由地を全クリアしてルート再計算。
  Future<void> _clearWaypoints() async {
    if (_waypoints.isEmpty) return;
    setState(() {
      _waypoints.clear();
      _waypointNames.clear();
      _waypointSaidNear.clear();
    });
    _rebuildMarkers();
    if (_groupDestination != null) {
      await _fetchRoute(_groupDestination!, isRerouting: true, force: true);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('経由地をクリアしました'),
          backgroundColor: Color(0xFF1A3A5C),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// M-1d: 経由地を末尾に追加してルート再計算 + マーカー更新。
  /// 呼出側で _groupDestination != null を保証する（ボタンの活性条件で担保済）。
  Future<void> _addWaypoint(LatLng latLng, String name) async {
    final destBefore = _groupDestination;
    _appendDebugLog(
      '[経由地追加] before: dest=${destBefore?.latitude.toStringAsFixed(4)},'
      '${destBefore?.longitude.toStringAsFixed(4)} waypoints=${_waypoints.length}',
    );
    if (_groupDestination == null) {
      _appendDebugLog('[経由地追加] スキップ: _groupDestination が null');
      return;
    }
    setState(() {
      _waypoints.add(latLng);
      _waypointNames.add(name);
      _waypointSaidNear.add(false);
    });
    _rebuildMarkers();              // 経由地マーカーを即時表示
    // 経由地追加はリルート扱い：カメラ広域動作・選択index リセット・5秒タイマー等の
    // 「新規目的地検索」副作用を回避し、ナビ/プレビューの state を保全する。
    // step/voice state は新ルート向けに自動リセットされ整合。force=true で
    // _rerouteInFlight 中でも確実に反映。
    await _fetchRoute(_groupDestination!, isRerouting: true, force: true);
    if (mounted) {
      _rebuildMarkers();            // 防御的: fetch 完了後の最終状態でも再描画
      _appendDebugLog(
        '[経由地追加] after: dest=${_groupDestination?.latitude.toStringAsFixed(4)},'
        '${_groupDestination?.longitude.toStringAsFixed(4)} waypoints=${_waypoints.length}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('経由地「$name」を追加しました'),
          backgroundColor: const Color(0xFF1A3A5C),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 目的地到着時の状態クリーンアップ。「案内終了」と同等のリセット + SnackBar。
  /// 音声「目的地に到着しました」は呼出側で既に流す前提。
  void _onDestinationArrived() {
    _routeOverviewTimer?.cancel();
    setState(() {
      _groupDestination = null;
      _groupDestName = '';
      _polylines = {};
      _routes = [];
      _selectedRouteIndex = 0;
      _headingUp = false;
      _isRoutePreview = false;
      _isShared = false;
      _inRouteOverview = false;
      _waypoints.clear();
      _waypointNames.clear();
      _waypointSaidNear.clear();
    });
    _animateCameraWithBearing(_myPosition, 0);
    _rebuildMarkers();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🎯 目的地に到着しました'),
          backgroundColor: Color(0xFF1A3A5C),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  /// 経由地通過判定。GPS 更新ごとに呼ぶ。
  /// _waypoints[0]（次の経由地）への直線距離で判定:
  /// - 100m 以内かつ未発話: 「まもなく経由地」（経由地ごとに 1 回）
  /// - 30m 以内: 「経由地です」+ 該当経由地除外 + マーカー再描画
  /// ルート再計算は行わない（既存ポリラインの後続部分で継続）。
  void _checkWaypointArrival() {
    if (_waypoints.isEmpty || _isRoutePreview) return;
    final dist = _metersTo(_myPosition, _waypoints[0]);
    if (dist < 30) {
      final name = _waypointNames[0];
      setState(() {
        _waypoints.removeAt(0);
        _waypointNames.removeAt(0);
        if (_waypointSaidNear.isNotEmpty) _waypointSaidNear.removeAt(0);
      });
      _rebuildMarkers();
      TtsService.instance.speak('経由地です');
      _appendDebugLog('[経由地通過] $name / 残${_waypoints.length}');
      return;
    }
    if (dist < 100 && _waypointSaidNear.isNotEmpty && !_waypointSaidNear[0]) {
      setState(() => _waypointSaidNear[0] = true);
      TtsService.instance.speak('まもなく経由地');
    }
  }

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

  Future<bool> _fetchRoute(
    LatLng dest, {
    bool isRerouting = false,
    bool force = false,
    bool addAntiUTurnWaypoint = false,
  }) async {
    if (isRerouting && !force && _rerouteInFlight) return false;
    if (isRerouting) _rerouteInFlight = true;

    const apiKey = 'AIzaSyChuUZypiVhojgCO6ZgZML-ZW3eYLtti5c';
    String? failureReason; // null=成功 / 'ZERO_RESULTS' / 'OVER_QUERY_LIMIT' / 'EXCEPTION' / 'EMPTY' / その他status
    bool succeeded = false;
    try {
      final origin = '${_myPosition.latitude},${_myPosition.longitude}';
      final destination = '${dest.latitude},${dest.longitude}';
      final avoidParam = _routePreference == 'local' ? '&avoid=highways' : '';

      // Uターン回避: B-6/B-7 自動再検索時のみ、進行方向に少し先の点を via waypoint として追加。
      // via: プレフィックスで停車地扱いを回避（leg 分割を起こさず単一 leg のまま）。
      // M-1d: ユーザー追加経由地（_waypoints）も同様に via: で連結。順序: anti-U-turn → user[0..n]。
      final wpList = <String>[];
      if (addAntiUTurnWaypoint && _currentSpeed >= _waypointMinSpeedMps) {
        final offsetMeters = _currentSpeed * _waypointLookaheadSec;
        final wp = _destinationLatLng(_myPosition, _currentBearing, offsetMeters);
        wpList.add('via:${wp.latitude},${wp.longitude}');
        _appendDebugLog(
          '[再検索waypoint] +${offsetMeters.toStringAsFixed(0)}m 方位${_currentBearing.toStringAsFixed(0)}° → ${wp.latitude.toStringAsFixed(5)},${wp.longitude.toStringAsFixed(5)}',
        );
      }
      for (final userWp in _waypoints) {
        wpList.add('via:${userWp.latitude},${userWp.longitude}');
      }
      final waypointParam = wpList.isEmpty ? '' : '&waypoints=${wpList.join('|')}';

      final url = 'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=$origin&destination=$destination'
          '&mode=driving&language=ja&alternatives=true$avoidParam$waypointParam&key=$apiKey';
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
            final durationSec = (leg['duration']['value'] as num?)?.toInt() ?? 0;
            final distanceMet = (leg['distance']['value'] as num?)?.toInt() ?? 0;
            debugPrint('[Phase1]   [$i] summary="$summary" / $duration / $distance');
            final stepsJson = leg['steps'] as List;
            final stepsList = <_RouteStep>[];
            for (final step in stepsJson) {
              final encoded = step['polyline']['points'] as String;
              final pts = PolylinePoints.decodePolyline(encoded);
              final stepPoints = pts.map((p) => LatLng(p.latitude, p.longitude)).toList();
              if (stepPoints.isEmpty) continue;
              final htmlInst = (step['html_instructions'] as String?) ?? '';
              final maneuver = step['maneuver'] as String?;
              final stepDistText = (step['distance']?['text'] as String?) ?? '';
              final stepDistVal = (step['distance']?['value'] as num?)?.toInt() ?? 0;
              final stepDurVal = (step['duration']?['value'] as num?)?.toInt() ?? 0;
              final startLoc = step['start_location'];
              final endLoc = step['end_location'];
              final start = startLoc != null
                  ? LatLng((startLoc['lat'] as num).toDouble(), (startLoc['lng'] as num).toDouble())
                  : stepPoints.first;
              final end = endLoc != null
                  ? LatLng((endLoc['lat'] as num).toDouble(), (endLoc['lng'] as num).toDouble())
                  : stepPoints.last;
              stepsList.add(_RouteStep(
                points: stepPoints,
                htmlInstructions: htmlInst,
                plainInstructions: _stripHtmlTags(htmlInst),
                maneuver: maneuver,
                distanceMeters: stepDistVal,
                durationSeconds: stepDurVal,
                distanceText: stepDistText,
                startLocation: start,
                endLocation: end,
              ));
            }
            if (stepsList.isNotEmpty) {
              newRoutes.add(_Route(
                steps: stepsList,
                summary: summary,
                durationText: duration,
                distanceText: distance,
                durationSeconds: durationSec,
                distanceMeters: distanceMet,
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
                // 再検索でルート構造が変わるため step / 音声 state をリセット。
                // 残したままだと _lastVoiceStepIdx が新ルートの step と偶然一致して
                // 「step 突入」と判定されず音声案内が完全に鳴らないケースがある。
                _currentStepIndex = 0;
                _pendingStepIndex = null;
                _pendingSince = null;
                _lastVoiceStepIdx = -1;
                _announcedTiers = <int>{};
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
              // 縮退チェック（現在地と目的地が同じ + 経由地無し の場合のみ概観スキップ）
              final isSamePoint = _waypoints.isEmpty &&
                  (_myPosition.latitude - dest.latitude).abs() < 0.00001 &&
                  (_myPosition.longitude - dest.longitude).abs() < 0.00001;
              if (isSamePoint) {
                _animateCamera(CameraUpdate.newLatLngZoom(_myPosition, 17.0), programmatic: true);
              } else {
                // M-1d fix: bounds に waypoints も含めて全マーカーが画面に収まるように
                final allPts = [_myPosition, dest, ..._waypoints];
                final bounds = LatLngBounds(
                  southwest: LatLng(
                    allPts.map((p) => p.latitude).reduce(min),
                    allPts.map((p) => p.longitude).reduce(min),
                  ),
                  northeast: LatLng(
                    allPts.map((p) => p.latitude).reduce(max),
                    allPts.map((p) => p.longitude).reduce(max),
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
    final history = await _loadDestHistory();
    if (!mounted) return;
    final result = await Navigator.push<SearchResultAction>(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(
        currentPosition: _myPosition,
        hasGpsFix: _hasGpsFix,
        history: history,
        hasActiveDestination: _groupDestination != null,
        hasActiveRoute: _routes.isNotEmpty,
        placesApiKey: 'AIzaSyChuUZypiVhojgCO6ZgZML-ZW3eYLtti5c',
      )),
    );
    if (!mounted || result == null) return;
    if (result.type == 'destination') {
      setState(() {
        _groupDestination = LatLng(result.lat!, result.lng!);
        _groupDestName = result.name!;
        _isRoutePreview = true;
        // 新規目的地検索時は「高速優先」にリセット。
        // 前回「一般道優先」のまま検索すると意図せず狭い道が選ばれることがあるため。
        _routePreference = 'highway';
        // M-1d: 新目的地で経由地もリセット（前ルートの経由地は意味を失う）
        _waypoints.clear();
        _waypointNames.clear();
        _waypointSaidNear.clear();
      });
      _updateDestinationMarker();
      // 「現在地」は履歴に保存しない（既存挙動踏襲）
      if (result.name != '現在地') {
        _saveDestHistory(result.name!, result.lat!, result.lng!);
      }
    } else if (result.type == 'waypoint') {
      // M-1d: 経由地として追加
      await _addWaypoint(
        LatLng(result.lat!, result.lng!),
        result.name!,
      );
    } else if (result.type == 'reset') {
      setState(() {
        _groupDestination = null;
        _groupDestName = '';
        _isRoutePreview = false;
        _isShared = false;
        _waypoints.clear();
        _waypointNames.clear();
        _waypointSaidNear.clear();
      });
      _updateDestinationMarker();
    }
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
      // M-1 経由地共有: 各 waypoint を {lat, lng, name} で書込。経由地ゼロ時は空配列
      'waypoints': List.generate(_waypoints.length, (i) => {
        'lat': _waypoints[i].latitude,
        'lng': _waypoints[i].longitude,
        'name': _waypointNames[i],
      }),
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
                if (data == null) {
                    return;
        }
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
    // Phase B-5: ナビ最適化（高頻度・高精度。バッテリー消費は許容）
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        intervalDuration: const Duration(milliseconds: 500),
        // ジッタ抑制のため最小移動量は控えめに（0 にすると静止時もイベントが連発する）
        distanceFilter: 0,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: 'バックグラウンドで位置情報を更新中',
          notificationTitle: 'TouriLink',
          enableWakeLock: true,
        ),
      );
    } else if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
        distanceFilter: 0,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  void _startLocationStream() {
    _locationSubscription = Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(),
    ).listen(
      _handlePositionUpdate,
      onError: (e) => debugPrint('位置情報ストリームエラー: $e'),
    );
  }

  Future<void> _handlePositionUpdate(Position pos) async {
    if (!mounted) return;
    final newPos = LatLng(pos.latitude, pos.longitude);
        // Phase B-5: 自車マーカーの tween を駆動（生 _myPosition は別途 setState で更新）
    // 初回はデフォルト東京座標から長距離 tween しないようスナップ。
    if (!_hasFirstFix) {
      _hasFirstFix = true;
      _displayMyPosition = newPos;
      _animFrom = newPos;
      _animTo = newPos;
    } else {
      _animFrom = _displayMyPosition;
      _animTo = newPos;
      _markerAnimController?.forward(from: 0);
    }
    setState(() => _myPosition = newPos);
    _hasGpsFix = true;
    final spd = pos.speed;
    // 負値（取得不可）は 0 扱い。bearing ガードの外で常に更新
    _currentSpeed = spd > 0 ? spd : 0.0;
    // Phase F-1: 速度 >= 2km/h の時のみ bearing 更新（停車・徐行で画面回転を抑止）。
    // 走り出したら自動で反映再開、ヘディングアップで自然に追従する。
    if (spd > _bearingUpdateMinSpeedMps && pos.heading >= 0) {
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
          } else {
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
    _updateCurrentStep(); // B-2: ステップ判定（投影方式 + 3秒デバウンス）
    _updateReverseDetection(); // B-6: 逆走検知（_currentStepIndex を使うため後）
    _checkWaypointArrival(); // M-1d: 経由地通過判定（音声 + マーカー除去）
    _updateVoiceGuidance(); // C-2: 音声案内（500/100/30m tier で読み上げ）
    _updateRemainingDistanceCheck(); // B-7: 残り距離増加検知（90° ズレ補完）
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
      final newPos = LatLng(pos.latitude, pos.longitude);
      // Phase B-5: 単発取得でも first-fix なら表示位置をスナップしておく
      if (!_hasFirstFix) {
        _hasFirstFix = true;
        _displayMyPosition = newPos;
        _animFrom = newPos;
        _animTo = newPos;
      } else {
        _animFrom = _displayMyPosition;
        _animTo = newPos;
        _markerAnimController?.forward(from: 0);
      }
      setState(() => _myPosition = newPos);
      _hasGpsFix = true;
      if (_shareLocation) {
        await _db.child('rooms/${widget.roomCode}/members/${widget.userId}').update({
          'nickname': widget.nickname,
          'lat': pos.latitude,
          'lng': pos.longitude,
          'vehicle_type': widget.vehicleType,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
        });
                // BUGFIX: Firebase realtime DB は自分書込時に listener 再発火しないため、
        // _members を直接更新して _rebuildMarkers を呼ぶ。これがないと自分の
        // マーカーが地図に出ない（_members[uid] に lat/lng が無いまま skip される）
        if (mounted) {
          setState(() {
            _members[widget.userId] = {
              'nickname': widget.nickname,
              'lat': pos.latitude,
              'lng': pos.longitude,
              'vehicle_type': widget.vehicleType,
              'last_seen': DateTime.now().millisecondsSinceEpoch,
            };
          });
          _rebuildMarkers();
                  }
      } else {
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
      _fetchRoute(_groupDestination!, isRerouting: true, addAntiUTurnWaypoint: true);
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

  /// Phase B-2: ナビ中の現在 step を判定。投影方式（最近接セグメント）。
  /// 全 step の polyline 線分への垂線距離が最小のものを採用。
  /// step 数は通常 10〜30 程度なので O(N×M) 線形探索で問題無し。
  int _findClosestStepIndex(LatLng pos, List<_RouteStep> steps) {
    if (steps.isEmpty) return 0;
    int bestStep = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < steps.length; i++) {
      final pts = steps[i].points;
      if (pts.length < 2) continue;
      for (int j = 0; j < pts.length - 1; j++) {
        final d = _distanceToSegment(pos, pts[j], pts[j + 1]);
        if (d < bestDist) {
          bestDist = d;
          bestStep = i;
        }
      }
    }
    return bestStep;
  }

  /// Phase B-2: 位置更新時に呼ぶ。最近接 step を求め、3秒間連続で同じ候補が
  /// 出続けた場合のみ切替確定（GPS ジッタ・分岐点での誤判定を吸収）。
  /// プレビュー中 / ルート無し時は state をリセット。setState はしない（B-3 で UI と連携時に対応）。
  void _updateCurrentStep() {
    if (_isRoutePreview || _routes.isEmpty) {
      if (_currentStepIndex != 0 || _pendingStepIndex != null) {
        _currentStepIndex = 0;
        _pendingStepIndex = null;
        _pendingSince = null;
      }
      return;
    }
    if (_selectedRouteIndex < 0 || _selectedRouteIndex >= _routes.length) return;
    final steps = _routes[_selectedRouteIndex].steps;
    if (steps.isEmpty) return;

    final candidate = _findClosestStepIndex(_myPosition, steps);

    if (candidate == _currentStepIndex) {
      // 候補が現 step と同じ → debounce 状態をクリア
      _pendingStepIndex = null;
      _pendingSince = null;
      return;
    }

    if (_pendingStepIndex != candidate) {
      // 新しい候補出現
      _pendingStepIndex = candidate;
      _pendingSince = DateTime.now();
      return;
    }

    // 同じ候補が継続 → 経過時間チェック
    if (_pendingSince != null &&
        DateTime.now().difference(_pendingSince!) >= _stepDebounceDuration) {
            _currentStepIndex = candidate;
      _pendingStepIndex = null;
      _pendingSince = null;
    }
  }

  /// Phase C-2: 音声案内のトリガー。GPS 更新ごとに呼ぶ。
  /// 現 step の終了点（次の曲がり地点）までの距離を 500m / 100m / 30m の tier 判定で読み上げ。
  /// step 切替時：突入時の残距離バンドに応じて 1 メッセージを即時発話（短い step / 再検索後でも
  /// 必ず 1 発話を担保）。残りの tier は通常通り順次発火。
  /// keep-* / null（直進）maneuver は発話せずスキップ。1 tick で発火する tier は直近 1 つのみ。
  void _updateVoiceGuidance() {
    if (_isRoutePreview || _routes.isEmpty) {
      _lastVoiceStepIdx = -1;
      _announcedTiers = <int>{};
      return;
    }
    if (_selectedRouteIndex < 0 || _selectedRouteIndex >= _routes.length) return;
    final steps = _routes[_selectedRouteIndex].steps;
    if (steps.isEmpty) return;

    final i = _currentStepIndex.clamp(0, steps.length - 1);
    final isLast = i >= steps.length - 1;

    // 末尾 step は「目的地」固定、それ以外は次 step の maneuver から日本語生成
    final String? maneuverJa = isLast
        ? '目的地'
        : _maneuverToJa(steps[i + 1].maneuver);

    // step 切替時：突入バンドに応じて即時発話 + 通過済み tier を事前マーク
    if (i != _lastVoiceStepIdx) {
      _lastVoiceStepIdx = i;
      _announcedTiers = <int>{};
      final initDist = _distanceAlongStepToEnd(_myPosition, steps[i]);

      String? immediateText;
      Set<int> preMarked = <int>{};
      if (maneuverJa != null) {
        if (initDist < 30) {
          // < 30m: 直前案内を即時発話、以降の tier は全部抑止
          immediateText = isLast ? '目的地に到着しました' : '$maneuverJaです';
          preMarked = {500, 100, 30};
        } else if (initDist < 500) {
          // 30〜500m: 「まもなく〜」を即時発話、30m tier のみ後で監視
          immediateText = isLast ? 'まもなく目的地' : 'まもなく$maneuverJa';
          preMarked = {500, 100};
        }
        // initDist >= 500m: 即時発話なし、500/100/30 を順次発火（既存挙動）
      }
      _announcedTiers.addAll(preMarked);

      // [調査支援] 即時発話の有無 / 事前スキップ tier を記録
      final nextManeuver = isLast ? '(末尾step)' : (steps[i + 1].maneuver ?? '(null=直進)');
      final resolved = maneuverJa ?? '(無音)';
      _appendDebugLog(
        '[音声] step=$i / maneuver=$nextManeuver → $resolved'
        ' / initDist=${initDist.toStringAsFixed(0)}m'
        ' / 即時発話=${immediateText ?? "なし"}'
        ' / 事前スキップtier=$preMarked',
      );

      if (immediateText != null) {
        TtsService.instance.speak(immediateText);
        // 末尾 step + 30m 即時発話 = 既に到着 → state リセット
        if (isLast && initDist < 30) _onDestinationArrived();
        return; // 即時発話したらこの tick の tier 判定はスキップ
      }
    }

    if (maneuverJa == null) return; // keep-* / null（直進）はスキップ

    final distance = _distanceAlongStepToEnd(_myPosition, steps[i]);

    // 直近 1 tier のみ発火（30 を最優先、GPS ジャンプで複数 tier 跨いでも 1 発話に収束）
    if (distance < 30 && !_announcedTiers.contains(30)) {
      _announcedTiers.addAll({30, 100, 500});
      final text = isLast ? '目的地に到着しました' : '$maneuverJaです';
      TtsService.instance.speak(text);
      // 末尾 step + 30m 到達 → 目的地到着、state リセット
      if (isLast) _onDestinationArrived();
    } else if (distance < 100 && !_announcedTiers.contains(100)) {
      _announcedTiers.addAll({100, 500});
      final text = isLast ? 'まもなく目的地' : 'まもなく$maneuverJa';
      TtsService.instance.speak(text);
    } else if (distance < 500 && !_announcedTiers.contains(500)) {
      _announcedTiers.add(500);
      // 連続交差点の先読み: 直前案内の曲がり後、200m 以内に次の曲がりがあれば追記。
      // 直進系（_maneuverToJa が null）step は中継として無視し累積距離で判定。
      // 末尾 step（arrive）は j+1 < length で除外 → 「次は目的地」化を回避。
      String? lookaheadJa;
      double lookaheadDist = 0;
      if (!isLast) {
        for (int j = i + 1; j + 1 < steps.length; j++) {
          lookaheadDist += steps[j].distanceMeters.toDouble();
          if (lookaheadDist > 200) break;
          final cand = _maneuverToJa(steps[j + 1].maneuver);
          if (cand != null) {
            lookaheadJa = cand;
            break;
          }
        }
      }
      final String text;
      if (isLast) {
        text = '500m先、目的地です';
      } else if (lookaheadJa != null) {
        text = '500m先、$maneuverJaです。そのあとすぐ$lookaheadJaです';
        _appendDebugLog(
          '[音声] 500m先読み: 現=$maneuverJa / 次=$lookaheadJa'
          ' / 次step長=${lookaheadDist.toStringAsFixed(0)}m',
        );
      } else {
        text = '500m先、$maneuverJaです';
      }
      TtsService.instance.speak(text);
    }
  }

  /// Phase B-7: 残り距離が増加していないか監視 → 自動再検索。GPS 更新ごとに呼ぶ。
  /// 90° ズレ（B-6 の 135° しきい値で検知できない）でルートから離れて残り距離が増えていく
  /// ケースを 10秒スパンの増減で捕捉。最古サンプル 9秒以上経過時、現在 - 最古 > 100m
  /// かつ速度 > 5km/h で発火。Cooldown は B-6 と共用。
  void _updateRemainingDistanceCheck() {
    if (_isRoutePreview || _routes.isEmpty || _groupDestination == null) {
      _distSamples.clear();
      return;
    }
    if (_rerouteInFlight) {
      _distSamples.clear();
      return;
    }
    final now = DateTime.now();
    if (_lastRerouteTime != null &&
        now.difference(_lastRerouteTime!).inSeconds < _rerouteCooldownSecs) {
      _distSamples.clear();
      return;
    }
    final dist = _remainingDistanceMeters();
    if (dist <= 0) return;

    // 10秒以上古いサンプルを削除
    _distSamples.removeWhere(
      (s) => now.difference(s.t) > _distHistoryDuration,
    );

    // 最古サンプルが 9秒以上経過していれば判定（バッファ未充足は判定スキップ）
    if (_distSamples.isNotEmpty) {
      final oldest = _distSamples.first;
      if (now.difference(oldest.t).inSeconds >= 9) {
        final increase = dist - oldest.dist;
        final speedOk = _currentSpeed > _distIncreaseSpeedMps;
        if (increase > _distIncreaseThresholdMeters && speedOk) {
          _appendDebugLog(
            '[B-7] 残り距離増加 → 再検索 +${increase.toStringAsFixed(0)}m 速度=${(_currentSpeed * 3.6).toStringAsFixed(1)}km/h',
          );
          _distSamples.clear();
          _fetchRoute(_groupDestination!, isRerouting: true, addAntiUTurnWaypoint: true);
          return;
        }
      }
    }

    _distSamples.add(_DistSample(now, dist));
  }

  /// Phase C-2: maneuver 文字列を音声案内用の日本語へ変換。null は読み上げ対象外。
  /// fork-* / ramp-* / keep-* は同じ「◯方向」で統一（ランプ・緩い分岐は伝わりにくいため）。
  /// straight / depart / arrive 系 / 未知 は無音（arrive 系は末尾 step で「目的地」発話される）。
  String? _maneuverToJa(String? maneuver) {
    switch (maneuver) {
      case 'turn-left':
      case 'turn-sharp-left':
      case 'turn-slight-left':
        return '左折';
      case 'turn-right':
      case 'turn-sharp-right':
      case 'turn-slight-right':
        return '右折';
      case 'uturn-left':
      case 'uturn-right':
        return 'Uターン';
      case 'fork-left':
      case 'ramp-left':
      case 'keep-left':
        return '左方向';
      case 'fork-right':
      case 'ramp-right':
      case 'keep-right':
        return '右方向';
      case 'merge':
        return '合流';
      case 'ferry':
      case 'ferry-train':
        return 'フェリー';
      case 'roundabout-left':
      case 'roundabout-right':
      case 'rotary':
        return 'ロータリー';
      default:
        return null;
    }
  }

  /// Phase B-6: 逆走検知 → 自動再検索。GPS 更新ごとに呼ぶ。
  /// 速度 >= _reverseSpeedThresholdMps かつ 走行方向と進路方向の角度差 >= _reverseAngleThresholdDeg
  /// が _reverseDebounceDuration（3秒）連続で _fetchRoute(isRerouting: true) を発火。
  /// 多重発火防止は逸脱判定と同じ _rerouteInFlight / _lastRerouteTime（cooldown 20秒）を共用。
  void _updateReverseDetection() {
    if (_isRoutePreview || _routes.isEmpty || _groupDestination == null) {
      _reverseSince = null;
      return;
    }
    if (_selectedRouteIndex < 0 || _selectedRouteIndex >= _routes.length) {
      _reverseSince = null;
      return;
    }
    // 再検索 in-flight / cooldown 中はループ防止のためスキップ（逸脱判定と共用）
    if (_rerouteInFlight) {
      _reverseSince = null;
      return;
    }
    final now = DateTime.now();
    if (_lastRerouteTime != null &&
        now.difference(_lastRerouteTime!).inSeconds < _rerouteCooldownSecs) {
      _reverseSince = null;
      return;
    }
    final steps = _routes[_selectedRouteIndex].steps;
    if (steps.isEmpty) {
      _reverseSince = null;
      return;
    }
    final i = _currentStepIndex.clamp(0, steps.length - 1);
    final routeBearing = _routeBearingAtPosition(_myPosition, steps[i]);
    if (routeBearing == null) {
      _reverseSince = null;
      return;
    }

    final diff = _angleDiff(_currentBearing, routeBearing);
    final speedOk = _currentSpeed >= _reverseSpeedThresholdMps;
    final angleOk = diff >= _reverseAngleThresholdDeg;

    if (!(speedOk && angleOk)) {
      _reverseSince = null;
      return;
    }

    _reverseSince ??= now;
    if (now.difference(_reverseSince!) >= _reverseDebounceDuration) {
      _appendDebugLog(
        '[B-6] 逆走確定 → 再検索 diff=${diff.toStringAsFixed(0)}° 速度=${(_currentSpeed * 3.6).toStringAsFixed(1)}km/h',
      );
      _reverseSince = null;
      _fetchRoute(_groupDestination!, isRerouting: true, addAntiUTurnWaypoint: true);
    }
  }

  /// Phase B-6: 指定 step 上で現在位置に最も近いセグメントの方位（度、0=北、東回り正）を返す。
  /// step.points が 2点未満なら null。
  double? _routeBearingAtPosition(LatLng pos, _RouteStep step) {
    final pts = step.points;
    if (pts.length < 2) return null;
    int bestIdx = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < pts.length - 1; i++) {
      final d = _distanceToSegment(pos, pts[i], pts[i + 1]);
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return _bearingBetween(pts[bestIdx], pts[bestIdx + 1]);
  }

  /// 2点間の方位（度、0=北、東回り正、[0, 360)）
  double _bearingBetween(LatLng a, LatLng b) {
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final y = sin(dLng) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
    final bearing = atan2(y, x) * 180 / pi;
    return (bearing + 360) % 360;
  }

  /// 出発点から指定方位・距離の地点を返す（球面三角法・direct 解）。高緯度でも誤差少。
  /// bearingDeg: 0=北, 90=東, 度。distanceMeters: メートル。
  LatLng _destinationLatLng(LatLng from, double bearingDeg, double distanceMeters) {
    const earthRadius = 6371000.0;
    final delta = distanceMeters / earthRadius;
    final theta = bearingDeg * pi / 180;
    final phi1 = from.latitude * pi / 180;
    final lambda1 = from.longitude * pi / 180;
    final phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta));
    final lambda2 = lambda1 +
        atan2(
          sin(theta) * sin(delta) * cos(phi1),
          cos(delta) - sin(phi1) * sin(phi2),
        );
    return LatLng(phi2 * 180 / pi, lambda2 * 180 / pi);
  }

  /// 2方位の差を [0, 180] に正規化
  double _angleDiff(double a, double b) {
    double d = (a - b).abs() % 360;
    if (d > 180) d = 360 - d;
    return d;
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

  /// Phase B-3: 現在位置から指定 step の終了地点までのルート沿い距離（メートル）。
  /// 1) 現在位置を step polyline の最近接セグメントに投影
  /// 2) 投影点から該当セグメント終端までの距離 + 以降のセグメント長を合算
  double _distanceAlongStepToEnd(LatLng pos, _RouteStep step) {
    final pts = step.points;
    if (pts.length < 2) return 0;
    int bestIdx = 0;
    double bestPerp = double.infinity;
    double bestT = 0;
    final cosLat = cos(pos.latitude * pi / 180);
    for (int i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final px = (pos.longitude - a.longitude) * cosLat * 111320;
      final py = (pos.latitude  - a.latitude)           * 111320;
      final dx = (b.longitude - a.longitude) * cosLat * 111320;
      final dy = (b.latitude  - a.latitude)           * 111320;
      final lenSq = dx * dx + dy * dy;
      if (lenSq == 0) continue;
      final t = ((px * dx + py * dy) / lenSq).clamp(0.0, 1.0);
      final perp = sqrt(pow(px - t * dx, 2) + pow(py - t * dy, 2));
      if (perp < bestPerp) {
        bestPerp = perp;
        bestIdx = i;
        bestT = t;
      }
    }
    // 最近接セグメント上で投影点から終端までの距離
    double remaining = _metersTo(pts[bestIdx], pts[bestIdx + 1]) * (1.0 - bestT);
    // 以降のセグメント長を加算
    for (int i = bestIdx + 1; i < pts.length - 1; i++) {
      remaining += _metersTo(pts[i], pts[i + 1]);
    }
    return remaining;
  }

  /// Phase B-4: ルート全体の残り距離（メートル）。
  /// 現在 step の残量（_distanceAlongStepToEnd）+ 以降の step.distanceMeters 合計。
  double _remainingDistanceMeters() {
    if (_routes.isEmpty) return 0;
    if (_selectedRouteIndex < 0 || _selectedRouteIndex >= _routes.length) return 0;
    final steps = _routes[_selectedRouteIndex].steps;
    if (steps.isEmpty) return 0;
    final i = _currentStepIndex.clamp(0, steps.length - 1);
    double rem = _distanceAlongStepToEnd(_myPosition, steps[i]);
    for (int k = i + 1; k < steps.length; k++) {
      rem += steps[k].distanceMeters.toDouble();
    }
    return rem;
  }

  /// Phase B-4: ルート全体の残り時間（秒）。
  /// 現在 step は残量比例で按分、以降は durationSeconds 合計。
  int _remainingDurationSeconds() {
    if (_routes.isEmpty) return 0;
    if (_selectedRouteIndex < 0 || _selectedRouteIndex >= _routes.length) return 0;
    final steps = _routes[_selectedRouteIndex].steps;
    if (steps.isEmpty) return 0;
    final i = _currentStepIndex.clamp(0, steps.length - 1);
    final cur = steps[i];
    final curRem = _distanceAlongStepToEnd(_myPosition, cur);
    final curTotal = cur.distanceMeters;
    double sec = curTotal > 0
        ? cur.durationSeconds * (curRem / curTotal)
        : cur.durationSeconds.toDouble();
    for (int k = i + 1; k < steps.length; k++) {
      sec += steps[k].durationSeconds.toDouble();
    }
    return sec.round();
  }

  /// Phase B-4: 「HH:mm 着」形式の到着予想時刻
  String _formatEta(int remainingSec) {
    final eta = DateTime.now().add(Duration(seconds: remainingSec));
    final h = eta.hour.toString().padLeft(2, '0');
    final m = eta.minute.toString().padLeft(2, '0');
    return '$h:$m 着';
  }

  /// Phase B-4: 残り時間表示（"25分" / "1時間20分"）
  String _formatRemainingDuration(int sec) {
    if (sec < 60) return '1分未満';
    final totalMin = (sec / 60).round();
    if (totalMin < 60) return '$totalMin分';
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    if (m == 0) return '$h時間';
    return '$h時間$m分';
  }

  /// Phase B-4: 残り距離表示（"850m" / "12.3km"）
  String _formatRemainingDistance(double meters) {
    if (meters < 1000) {
      final rounded = (meters / 10).round() * 10;
      return '${rounded}m';
    }
    final km = (meters / 100).round() / 10.0;
    return '${km.toStringAsFixed(1)}km';
  }

  /// Phase B-3: maneuver 文字列から表示アイコンへ変換。null は直進アイコン。
  IconData _maneuverToIcon(String? maneuver) {
    switch (maneuver) {
      case 'turn-left':
      case 'turn-slight-left':
      case 'turn-sharp-left':
        return Icons.turn_left;
      case 'turn-right':
      case 'turn-slight-right':
      case 'turn-sharp-right':
        return Icons.turn_right;
      case 'uturn-left':
        return Icons.u_turn_left;
      case 'uturn-right':
        return Icons.u_turn_right;
      case 'keep-left':
      case 'fork-left':
      case 'ramp-left':
        return Icons.turn_slight_left;
      case 'keep-right':
      case 'fork-right':
      case 'ramp-right':
        return Icons.turn_slight_right;
      case 'merge':
        return Icons.merge;
      case 'roundabout-left':
        return Icons.roundabout_left;
      case 'roundabout-right':
        return Icons.roundabout_right;
      default:
        return Icons.straight;
    }
  }

  /// Phase B-3: ナビ距離の表示形式（"500m先" / "1.2km先" / "まもなく"）
  String _formatNavDistance(double meters) {
    if (meters < 50) return 'まもなく';
    if (meters < 1000) {
      final rounded = (meters / 10).round() * 10;
      return '${rounded}m先';
    }
    final km = (meters / 100).round() / 10.0;
    return '${km.toStringAsFixed(1)}km先';
  }

  void _animateCamera(CameraUpdate update, {required bool programmatic}) {
    if (_mapController == null) return;
    if (programmatic) {
      _lastProgrammaticMoveAt = DateTime.now();
    }
    _mapController!.animateCamera(update);
  }

  // Phase A-4: 「現在地へ戻る」ボタンのダブルタップで全メンバーが画面に収まる範囲にズーム。
  /// Phase D-1: 現在地ボタンの onTap 共通処理。ナビ中・非ナビ両モードで同じ動き。
  /// ナビ中はオフセット + 既存 bearing を維持、非ナビはズーム17の真俯瞰。
  void _handleRecenterTap() {
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
  }

  /// 右下コラムの +/- ズームボタン処理。
  /// programmatic: true で _lastProgrammaticMoveAt を更新 → onCameraMoveStarted の guard で
  /// _isFollowingMember は変化せず、GPS 自動追従を切らない。
  /// CameraUpdate.zoomBy は target/bearing/tilt を保持するので自車中心ズームが維持される。
  void _handleZoomIn() {
    _animateCamera(CameraUpdate.zoomBy(1), programmatic: true);
  }

  void _handleZoomOut() {
    _animateCamera(CameraUpdate.zoomBy(-1), programmatic: true);
  }

  /// 右下コラムのシンプルな 44x44 円形マップ操作ボタン共通ビルダ（+/-）。
  Widget _buildSquareMapButton({
    required IconData icon,
    required VoidCallback onTap,
    required Color bgColor,
    required Color iconColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: bgColor,
          shape: BoxShape.circle,
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        child: Icon(icon, color: iconColor, size: 24),
      ),
    );
  }

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
  // - ナビ中 + 3D: 自車を画面下1/3 に置くため bearing 方向にオフセット、tilt 60度
  //   縦画面 200m / 横画面 100m（横画面は縦サイズが狭く 200m だと画面外に出るため）
  // - ナビ中 + 2D: 自車中心、tilt 0（全周囲を均等に見せる）
  // - それ以外（プレビュー中・目的地なし・案内終了直後）: target そのまま、tilt 0
  // 約数 111320 は 1度あたりの緯度メートル換算。経度は cos(lat) で補正。
  ({LatLng target, double tilt}) _navCameraConfig(LatLng position, double bearing) {
    final isNavigating = !_isRoutePreview && _routes.isNotEmpty;
    if (!isNavigating || !_is3D) {
      return (target: position, tilt: 0.0);
    }
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final offsetMeters = isLandscape ? 100.0 : 200.0;
    final dx = sin(bearing * pi / 180) * offsetMeters;
    final dy = cos(bearing * pi / 180) * offsetMeters;
    final cosLat = cos(position.latitude * pi / 180);
    final offsetLat = position.latitude + dy / 111320;
    final offsetLng = position.longitude + dx / (111320 * cosLat);
    return (target: LatLng(offsetLat, offsetLng), tilt: 60.0);
  }

  // 2D/3D トグル + 永続化 + 即時カメラ反映
  Future<void> _toggleMapTiltMode() async {
    setState(() => _is3D = !_is3D);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMapTiltModeKey, _is3D ? '3D' : '2D');
    _animateCameraWithBearing(_myPosition, _currentBearing);
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
    _searchDebounceTimer?.cancel();
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
    _markerAnimController?.removeListener(_onMarkerAnimTick);
    _markerAnimController?.dispose();
    // Phase D-1: シート関連リソース
    _sheetAutoCollapseTimer?.cancel();
    _sheetController.dispose();
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
      // BUGFIX: ON 修正と対称的な対応。listener が自分書込で発火しないため、
      // _members からも自分を直接削除 + _rebuildMarkers を呼ぶ
      if (mounted) {
        setState(() {
          _members.remove(widget.userId);
        });
        _rebuildMarkers();
              }
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
              // SizedBox で明示サイズを与える。AlertDialog 内部の IntrinsicWidth が
              // QrImageView 内部の LayoutBuilder に intrinsic を要求してクラッシュするのを防ぐ。
              child: SizedBox(
                width: 220,
                height: 220,
                child: QrImageView(
                  data: 'https://drivelink-a7ffb.web.app/join?room=${widget.roomCode}',
                  version: QrVersions.auto,
                  size: 220,
                ),
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
        if (_debugLogEnabled) ...[
          IconButton(
            tooltip: _gpsSpoofEnabled ? 'GPS偽装 ON（東京駅）' : 'GPS偽装',
            icon: Icon(
              _gpsSpoofEnabled ? Icons.location_off : Icons.location_searching,
              color: Colors.purple,
            ),
            onPressed: _toggleGpsSpoof,
          ),
          IconButton(
            tooltip: '逸脱判定ログ',
            icon: const Icon(Icons.bug_report, color: Colors.purple),
            onPressed: _showDebugLogDialog,
          ),
        ],
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
              onChanged: (newValue) {
                                _toggleLocationSharing();
              },
            ),
          ],
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          color: const Color(0xFF0D1B2A),
          onSelected: (value) async {
            if (value == 'qr') _showQrDialog();
            if (value == 'share') _shareRoomCode();
            if (value == 'privacy') {
              final uri = Uri.parse('https://taichi5556.github.io/drivelink/privacy_policy.html');
              final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
              if (!ok && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('ブラウザを起動できませんでした')),
                );
              }
            }
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
            const PopupMenuItem(
              value: 'privacy',
              child: Row(children: [
                Icon(Icons.privacy_tip_outlined, color: Colors.white, size: 20),
                SizedBox(width: 10),
                Text('プライバシーポリシー', style: TextStyle(color: Colors.white)),
              ]),
            ),
          ],
        ),
        TextButton.icon(
          icon: const Icon(Icons.exit_to_app, color: Colors.white, size: 18),
          label: const Text('退出', style: TextStyle(color: Colors.white, fontSize: 13)),
          onPressed: _confirmExitToLogin,
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
    // Phase D-1: ナビ中（!preview && routes 有り）はシートが下端を覆うため
    // 現在地・ヘディングアップボタンを上方（bottom: 86）に逃がす。
    final isNav = !_isRoutePreview && _routes.isNotEmpty;
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
          // 復帰直後の誤発火（GoogleMap 再構成や GPS 再取得起因）もプログラム由来扱い
          if (_lastResumedAt != null &&
              DateTime.now().difference(_lastResumedAt!).inMilliseconds <
                  _resumeGuardMs) {
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
        // 左下 4 横列ボタン（左から: + / − / 現在地 / ヘディングアップ）
        // ナビ中: ETA カード折りたたみ（70px）の真上 bottom: 78（8px breathing）
        // シート展開時は Stack 後勝ちでシートが上から覆って自然に隠れる（仕様通り）
        // ズームボタン操作で GPS 追従は切れない（programmatic: true により onCameraMoveStarted guard）
        Positioned(
          left: 12,
          bottom: isNav ? 78 : 12,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ＋ ズームイン
              _buildSquareMapButton(
                icon: Icons.add,
                onTap: _handleZoomIn,
                bgColor: const Color(0xFF1A3A5C).withValues(alpha: 0.9),
                iconColor: Colors.white,
              ),
              const SizedBox(width: 8),
              // − ズームアウト
              _buildSquareMapButton(
                icon: Icons.remove,
                onTap: _handleZoomOut,
                bgColor: const Color(0xFF1A3A5C).withValues(alpha: 0.9),
                iconColor: Colors.white,
              ),
              const SizedBox(width: 8),
              // 現在地（タップ: センタリング + zoom17 / ダブルタップ: 全メンバー収まるズーム）
              // 追従中（_isFollowingMember=false）は青色 active、追従外れ（true）は灰色 inactive で
              // タップで追従復帰できることを視覚的に示す（ヘディングアップと同パターン）。
              GestureDetector(
                onTap: _handleRecenterTap,
                onDoubleTap: _zoomToAllMembers,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _isFollowingMember
                        ? const Color(0xFF1A3A5C).withValues(alpha: 0.9)
                        : const Color(0xFF00D4FF),
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4),
                    ],
                  ),
                  child: Icon(
                    Icons.my_location,
                    color: _isFollowingMember
                        ? Colors.white70
                        : Colors.white,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // ヘディングアップ ON/OFF
              GestureDetector(
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
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 4),
                    ],
                  ),
                  child: Icon(
                    Icons.navigation,
                    color: _headingUp ? Colors.white : Colors.white70,
                    size: 24,
                  ),
                ),
              ),
            ],
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
        // Phase B-3: 上部案内バナー（ナビ中のみ表示）。メンバーリストを避けるため右マージン70px。
        if (!_isRoutePreview && _routes.isNotEmpty)
          Positioned(
            top: 8,
            left: 8,
            right: 70,
            child: _buildNavigationBanner(),
          ),
        // Phase D-1: ナビ中はマップ下部に DraggableScrollableSheet を出す。
        // 折りたたみ：ハンドル + ETA 1行（時刻 / 残り時間 / 残り距離）
        // 展開：ETA + 目的地名 + アクション 4ボタン
        if (!_isRoutePreview && _routes.isNotEmpty)
          _buildNavigationSheet(),
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

  // GPS偽装トグル（隠しデバッグメニュー）。
  // ON: _locationSubscription をキャンセルして _myPosition を東京駅に固定。
  //     _handlePositionUpdate が呼ばれなくなるため、逸脱判定・通過判定・音声案内・
  //     カメラ追従・残距離検知・逆走検知・step 判定が全連鎖停止。
  //     既存の polyline / マーカーは描画維持（テスト用）。
  // OFF: 通常 GPS ストリームに復帰。
  void _toggleGpsSpoof() {
    if (_gpsSpoofEnabled) {
      setState(() => _gpsSpoofEnabled = false);
      _locationSubscription?.cancel();
      _startLocationStream();
    } else {
      _locationSubscription?.cancel();
      setState(() {
        _gpsSpoofEnabled = true;
        _myPosition = _kSpoofPosition;
        _displayMyPosition = _kSpoofPosition;
        _animFrom = _kSpoofPosition;
        _animTo = _kSpoofPosition;
        _hasGpsFix = true;
        _hasFirstFix = true;
      });
      _rebuildMarkers();
      _animateCamera(
        CameraUpdate.newLatLngZoom(_kSpoofPosition, 15.0),
        programmatic: true,
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_gpsSpoofEnabled
              ? '📍 GPS偽装 ON（東京駅 / ナビロジック停止）'
              : '📍 GPS偽装 OFF'),
          duration: const Duration(seconds: 2),
          backgroundColor: const Color(0xFF1A3A5C),
        ),
      );
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
    // B-2: ナビ開始時に step 判定 state をリセット（前回のナビの残骸を持ち越さない）
    _currentStepIndex = 0;
    _pendingStepIndex = null;
    _pendingSince = null;
    // プレビュー（3色） → ナビ（選択ルートのみオレンジ）に切替
    _rebuildPolylines();
    _routeOverviewTimer?.cancel();
    if (_headingUp) {
      _moveCameraWithBearing(_myPosition, _currentBearing);
    } else {
      _animateCamera(CameraUpdate.newLatLngZoom(_myPosition, 17.0), programmatic: true);
    }
    // Phase D-1: ナビ確定直後 5秒間シート展開（ルート共有ボタンに即アクセス可能にする）
    _expandSheetTemporarily();
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
      _waypoints.clear();
      _waypointNames.clear();
      _waypointSaidNear.clear();
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
            label: '🚗 一般道優先',
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
    // Phase D-1: ナビ中は4ボタンをシート内に表示するため下部側は非表示にする。
    // 通知（_pendingNotifications）はナビ中でも安全のため残す（急減速 warning 等）。
    final isNavigating = !_isRoutePreview && _routes.isNotEmpty;
    // ナビ中で通知も無ければ section ごと省略してマップ領域を最大化
    if (isNavigating && _pendingNotifications.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      color: _blinkVisible ? _blinkColor.withValues(alpha: 0.25) : const Color(0xFF0D1B2A),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pendingNotifications.isNotEmpty) ...[
            _buildNotificationBanners(),
            if (!isNavigating) const SizedBox(height: 4),
          ],
          if (!isNavigating) _buildActionButtons(),
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
                  _waypoints.clear();
                  _waypointNames.clear();
                  _waypointSaidNear.clear();
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

  // 2段目アクションボタン4つ（2D/3D + 経由地 + 準備中×2）
  // 1段目と同レイアウト（4ボタン横並び等幅）。準備中枠は onTap=null + グレーで非活性表現。
  List<Widget> _buildActionButtonItems2(double btnWidth) {
    return [
      _buildActionBtn(
        icon: _is3D ? Icons.threed_rotation : Icons.map,
        label: _is3D ? '3D' : '2D',
        color: const Color(0xFF1A3A5C),
        onTap: _toggleMapTiltMode,
        width: btnWidth,
      ),
      // M-1e: 経由地追加ボタン。経由地モード専用フローで SearchScreen 起動
      _buildActionBtn(
        icon: Icons.add_location_alt_outlined,
        label: '経由地',
        color: const Color(0xFFFF8A50),  // 経由地マーカー（hueOrange）と色統一
        onTap: _addWaypointFromSearch,
        width: btnWidth,
      ),
      for (int k = 0; k < 2; k++)
        _buildActionBtn(
          icon: Icons.more_horiz,
          label: '準備中',
          color: Colors.grey.shade700,
          onTap: null,
          width: btnWidth,
        ),
    ];
  }

  // 縦画面 bottom 用：横並び 4ボタン（ルート有り時のみ 2段目 [2D/3D + 経由地 + 準備中×2]
  // を追加表示。プレビュー中も含む = 経由地追加をプレビュー段階でも可能に）
  Widget _buildActionButtons() {
    final hasRoute = _routes.isNotEmpty;
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
          Widget rowOf(List<Widget> ws) => Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  for (int i = 0; i < ws.length; i++) ...[
                    if (i > 0) const SizedBox(width: spacing),
                    ws[i],
                  ],
                ],
              );
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              rowOf(items),
              if (hasRoute) ...[
                const SizedBox(height: spacing),
                rowOf(_buildActionButtonItems2(btnWidth)),
              ],
            ],
          );
        },
      ),
    );
  }

  // 横画面 左帯用：縦並び 4ボタン（ルート有り時のみ 2段目を縦に追加で計8ボタン）
  Widget _buildActionButtonsVertical() {
    final hasRoute = _routes.isNotEmpty;
    const double spacing = 8.0;
    final items = [
      ..._buildActionButtonItems(60.0),
      if (hasRoute) ..._buildActionButtonItems2(60.0),
    ];
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
  /// Phase B-3: 上部案内バナー（Apple マップ風）。ナビ中（!preview && _routes.isNotEmpty）のみ表示。
  /// 表示する maneuver は「次の step」のもの（= 現 step の終了地点で行う動作）。
  /// 末尾 step に到達した場合は「目的地に到着」表示。
  Widget _buildNavigationBanner() {
    if (_isRoutePreview || _routes.isEmpty) return const SizedBox.shrink();
    if (_selectedRouteIndex < 0 || _selectedRouteIndex >= _routes.length) {
      return const SizedBox.shrink();
    }
    final steps = _routes[_selectedRouteIndex].steps;
    if (steps.isEmpty) return const SizedBox.shrink();

    final i = _currentStepIndex.clamp(0, steps.length - 1);
    final isLastStep = i >= steps.length - 1;

    // 表示用の指示 step / アイコン / テキスト
    final IconData icon;
    final String distanceText;
    final String instructionText;
    if (isLastStep) {
      // 末尾 step → 目的地到着案内
      final endDist = _distanceAlongStepToEnd(_myPosition, steps[i]);
      icon = Icons.flag;
      distanceText = _formatNavDistance(endDist);
      instructionText = '目的地に到着';
    } else {
      final next = steps[i + 1];
      icon = _maneuverToIcon(next.maneuver);
      final distToTurn = _distanceAlongStepToEnd(_myPosition, steps[i]);
      distanceText = _formatNavDistance(distToTurn);
      instructionText = next.plainInstructions.isNotEmpty
          ? next.plainInstructions
          : '次の指示';
    }

    // Phase D-1: ダークガラス化。ClipRRect で blur を適用、シャドウは ClipRRect 外側
    // の親 Container に設定して可視性を確保（内側に置くとクリップされて見えない）。
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1B2A).withValues(alpha: 0.30),
              ),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00D4FF),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: Colors.black, size: 36),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          distanceText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          instructionText,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // Phase D-1: 目的地名（B-4 シートから移設）。空名なら出さない。
                        if (_groupDestName.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                Icons.place,
                                color: Colors.white.withValues(alpha: 0.5),
                                size: 11,
                              ),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  // 経由地ありなら「次の経由地 → 目的地」を表示。
                                  // 通過判定で _waypointNames は順次先頭から
                                  // 削除されるため、_waypointNames[0] が常に次の経由地。
                                  _waypointNames.isEmpty
                                      ? _groupDestName
                                      : '${_waypointNames[0]} → $_groupDestName',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w400,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Phase D-1: ナビ中の DraggableScrollableSheet（Apple マップ風 frosted glass）。
  /// 折りたたみ：ハンドル + ETA 1行（時刻 / 残り時間 / 残り距離）
  /// 展開：ETA行 + アクション 4ボタン（目的地名は B-3 ナビバナーで表示）
  /// 高さ比率は LayoutBuilder で実 Stack 高さから px 換算。
  /// _sheetController で animateTo を可能にし、ユーザーのタップで自動折りたたみタイマーをキャンセル。
  Widget _buildNavigationSheet() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final parentH = constraints.maxHeight;
        // 折りたたみ ~70px（ハンドル + ETA行 + 余白）/ 展開 ~260px（ハンドル + ETA + 音声トグル
        // + 4ボタン×2段 + 段間 spacing + 余白）。2段目（2D/3D + 準備中×3）追加で +60px。
        final minSize = (70.0 / parentH).clamp(0.06, 0.4);
        final maxSize = (260.0 / parentH).clamp(0.12, 0.6);
        // _expandSheetTemporarily / GestureDetector 用にキャッシュ
        _sheetMinSize = minSize;
        _sheetMaxSize = maxSize;
        _sheetParentH = parentH;
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            // ユーザーが触れた瞬間にタイマーキャンセル（連続操作で延長）
            if (_sheetAutoCollapseTimer?.isActive ?? false) {
              _sheetAutoCollapseTimer?.cancel();
              _sheetAutoCollapseTimer = null;
            }
          },
          onPointerUp: (_) {
            // 操作完了後 10秒静止で自動折りたたみ（連続操作中は cancel→reschedule で延長）
            _scheduleAutoCollapseAfterInteraction();
          },
          onPointerCancel: (_) {
            // gesture が中断された場合も同様にタイマー再スケジュール
            _scheduleAutoCollapseAfterInteraction();
          },
          child: DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: minSize,
            minChildSize: minSize,
            maxChildSize: maxSize,
            snap: true,
            snapSizes: [minSize, maxSize],
            builder: (context, scrollController) =>
                _buildSheetBody(scrollController),
          ),
        );
      },
    );
  }

  /// ハンドル領域タップでシート展開／折りたたみをトグル。
  /// midpoint 未満なら maxSize へ展開、以上なら minSize へ折りたたみ。
  /// 既存のスワイプ操作は無改修。タップ後は 10秒後の自動折りたたみを再スケジュール。
  void _toggleSheetByHandleTap() {
    if (!_sheetController.isAttached) return;
    final current = _sheetController.size;
    final midpoint = (_sheetMinSize + _sheetMaxSize) / 2;
    final target = current <= midpoint ? _sheetMaxSize : _sheetMinSize;
    _sheetController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
    _scheduleAutoCollapseAfterInteraction();
  }

  /// Phase D-1: ナビ確定直後にシートを展開状態にし、5秒後に折りたたみへ自動復帰。
  /// 5秒の間にユーザーが指で触れたら Listener 経由でタイマーキャンセル（自動復帰なし）。
  /// controller の attach は次フレーム以降のため post-frame で実行。
  void _expandSheetTemporarily() {
    if (_isRoutePreview || _routes.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_sheetController.isAttached) return;
      _sheetController.animateTo(
        _sheetMaxSize,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
      _sheetAutoCollapseTimer?.cancel();
      _sheetAutoCollapseTimer = Timer(const Duration(seconds: 5), () {
        if (!_sheetController.isAttached) return;
        _sheetController.animateTo(
          _sheetMinSize,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      });
    });
  }

  /// Phase D-1: ユーザーがシート操作した後 10秒間さわらなければ折りたたみへ自動遷移。
  /// onPointerDown でタイマーキャンセル → onPointerUp で再スケジュール
  /// → 連続操作中は発火しない、操作のたびに 10秒延長される。
  /// 折りたたみ済み（size <= midpoint）の場合は no-op で済むよう、タイマー発火時に再判定。
  void _scheduleAutoCollapseAfterInteraction() {
    if (!_sheetController.isAttached) return;
    _sheetAutoCollapseTimer?.cancel();
    _sheetAutoCollapseTimer = Timer(const Duration(seconds: 10), () {
      if (!_sheetController.isAttached) return;
      final currentSize = _sheetController.size;
      final midpoint = (_sheetMinSize + _sheetMaxSize) / 2;
      if (currentSize <= midpoint) return; // 既に折りたたみ済み
      _sheetController.animateTo(
        _sheetMinSize,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// Phase D-1: シート内コンテンツ。ListView で `scrollController` を受けることで
  /// DraggableScrollableSheet のドラッグ判定が正しく動く（中身は実質スクロールしない）。
  /// すりガラス感を強めるため白α0.7 + blur sigma 30。
  Widget _buildSheetBody(ScrollController scrollController) {
    final remDist = _remainingDistanceMeters();
    final remDur = _remainingDurationSeconds();
    final eta = _formatEta(remDur);
    final dur = _formatRemainingDuration(remDur);
    final dist = _formatRemainingDistance(remDist);

    // 透明度を上げた背景でも読めるよう文字は黒寄り＋太字
    const primaryColor = Color(0xFF000000);
    const flatTextStyle = TextStyle(
      color: primaryColor,
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    );

    // シート全体を縦ドラッグでサイズ変更するための GestureDetector でラップ。
    // - HitTestBehavior.translucent で子のタップ・horizontal drag は妨げない
    // - onVerticalDragUpdate: jumpTo で finger に追従、auto collapse タイマーをキャンセル
    // - onVerticalDragEnd: velocity > 300 px/s なら fling、それ未満は中点ベース snap
    //   （iOS Apple Music / マップ ETA 風の操作感）
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (details) {
        if (!_sheetController.isAttached || _sheetParentH <= 0) return;
        final newSize =
            (_sheetController.size - details.delta.dy / _sheetParentH)
                .clamp(_sheetMinSize, _sheetMaxSize);
        _sheetController.jumpTo(newSize);
        _sheetAutoCollapseTimer?.cancel();
        _sheetAutoCollapseTimer = null;
      },
      onVerticalDragEnd: (details) {
        if (!_sheetController.isAttached) return;
        final velocity = details.primaryVelocity ?? 0;
        const flingThreshold = 300.0; // px/s（Apple 標準的閾値）
        final double target;
        if (velocity.abs() > flingThreshold) {
          // 下向き fling → 折りたたみ、上向き fling → 展開
          target = velocity > 0 ? _sheetMinSize : _sheetMaxSize;
        } else {
          // 低速時は中点ベースの位置 snap
          final midpoint = (_sheetMinSize + _sheetMaxSize) / 2;
          target = _sheetController.size < midpoint
              ? _sheetMinSize
              : _sheetMaxSize;
        }
        _sheetController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        _scheduleAutoCollapseAfterInteraction();
      },
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Container(
          // BackdropFilter 削除（GPU 負荷削減・発熱対策）。alpha 0.25 → 0.85 で文字可読性確保。
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.85),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          child: ListView(
            controller: scrollController,
            // 内部スクロールを無効化することで、全ての縦ドラッグが DraggableScrollableSheet 本体の
            // ドラッグへ素通りする。ScrollController は attach 維持（bridge 機構の要件）。
            // これでハンドル外の任意位置からも上下スワイプで展開/折りたたみが効く。
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              // ハンドル（タップで展開／折りたたみトグル。誤作動防止のためシート本体は反応させない）
              Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleSheetByHandleTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                    child: Container(
                      width: 36,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xFFC7C7CC),
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),
                ),
              ),
              // ETA 行（時刻 / 残り時間 / 残り距離 横一列）
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(eta, style: flatTextStyle),
                  Text(dur, style: flatTextStyle),
                  Text(dist, style: flatTextStyle),
                ],
              ),
              const SizedBox(height: 8),
              // Phase C-3: 音声案内 ON/OFF トグル（永続化は TtsService 側で実施）
              Row(
                children: [
                  const Icon(
                    Icons.volume_up,
                    size: 20,
                    color: primaryColor,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '音声案内',
                    style: TextStyle(
                      color: primaryColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Switch.adaptive(
                    value: TtsService.instance.isEnabled,
                    onChanged: (v) async {
                      await TtsService.instance.setEnabled(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // アクション 4ボタン（既存ヘルパー流用、展開時のみ視認）
              _buildActionButtons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMemberListOverlay() {
    final uids = _members.keys.toList();
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.35,
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

// Phase B-7: 残り距離サンプル（時刻 + その時点での残り距離 m）。10秒履歴で増加検知に使用。
class _DistSample {
  final DateTime t;
  final double dist;
  const _DistSample(this.t, this.dist);
}

// Directions API から取得した 1 本のルート情報。複数ルート (alternatives=true) の保持に使用。
class _Route {
  final List<_RouteStep> steps;
  final String summary;
  final String durationText;
  final String distanceText;
  // leg['duration']['value'] / leg['distance']['value'] の数値版（B-4 到着予想カードで使用）
  final int durationSeconds;
  final int distanceMeters;
  const _Route({
    required this.steps,
    required this.summary,
    required this.durationText,
    required this.distanceText,
    required this.durationSeconds,
    required this.distanceMeters,
  });

  // 既存の _routePoints / passedRoute 計算用。steps の polyline を連結して返す。
  List<LatLng> get points => [
        for (final s in steps) ...s.points,
      ];
}

// Directions API の step 単位の情報。B-2 の最近接点判定 / B-3 の案内バナーで使用。
class _RouteStep {
  final List<LatLng> points;          // この step の polyline 点列
  final String htmlInstructions;       // 例: "<b>国道20号</b>を<b>甲府</b>方面へ進む"
  final String plainInstructions;      // HTML タグ除去済み（バナー表示用）
  final String? maneuver;              // 例: "turn-left" / "turn-right" / null=直進
  final int distanceMeters;            // step['distance']['value']
  final int durationSeconds;           // step['duration']['value']
  final String distanceText;           // 例: "500 m"
  final LatLng startLocation;          // step 開始座標
  final LatLng endLocation;            // step 終了座標
  const _RouteStep({
    required this.points,
    required this.htmlInstructions,
    required this.plainInstructions,
    required this.maneuver,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.distanceText,
    required this.startLocation,
    required this.endLocation,
  });
}

// html_instructions から HTML タグを取り除く（<b>国道20号</b> → 国道20号）
// Directions API の出力は単純なタグのみ含まれるので正規表現で十分。
String _stripHtmlTags(String html) {
  // <div> による改行ヒントは半角スペースに置換してから他タグ除去
  return html
      .replaceAll(RegExp(r'<div[^>]*>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
