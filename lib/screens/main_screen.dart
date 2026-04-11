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
import 'login_screen.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:share_plus/share_plus.dart';

class MainScreen extends StatefulWidget {
  final String userId;
  final String nickname;
  final String roomCode;
  final String vehicleType; // 'car' or 'bike'
  final bool initialShareLocation;
  const MainScreen({
    Key? key,
    required this.userId,
    required this.nickname,
    required this.roomCode,
    this.vehicleType = 'car',
    this.initialShareLocation = false,
  }) : super(key: key);

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  GoogleMapController? _mapController;
  bool _isFollowingMember = false;
  late bool _shareLocation;
  bool _programmaticCameraMove = false;
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

  // ルート逸脱自動再検索
  DateTime? _lastRerouteTime;
  static const _rerouteThresholdMeters = 50.0;  // 逸脱判定距離
  static const _rerouteCooldownSecs    = 20;     // 再検索間隔（秒）

  // 警告ポイント関連
  Map<String, dynamic> _warnings = {};
  StreamSubscription? _warningsSubscription;
  Timer? _warningCleanupTimer;

  // 車両マーカーキャッシュ（vehicleType-isMe → BitmapDescriptor）
  final Map<String, BitmapDescriptor> _markerCache = {};


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
    _shareLocation = widget.initialShareLocation;
    WakelockPlus.enable();
    _initAll();
    _loadBannerAd();
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
    _initAppLinks();
    await _startExpiryCheck();
    // 期限切れ警告ポイントを1分ごとに削除
    _warningCleanupTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _cleanupExpiredWarnings(),
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
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
            child: const Text('OK', style: TextStyle(color: Color(0xFFFF6B35))),
          ),
        ],
      ),
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
        });
        _updateDestinationMarker();
        return;
      }
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final name = data['name'] as String? ?? '目的地';
      final senderUid = data['senderUid'] as String? ?? '';
      if (lat == null || lng == null) return;
      final newDest = LatLng(lat, lng);
      if (senderUid != widget.userId) {
        setState(() {
          _groupDestination = newDest;
          _groupDestName = name;
        });
        _updateDestinationMarker();
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
    // imagePixelRatio: 2.5 → 画面上の表示サイズ ≈ 幅21dp・高さ28dp
    _warningMarkerCache = BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
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
    // imagePixelRatio: 2.5 → 画面上の表示サイズ = 52 / 2.5 ≈ 20dp
    final descriptor = BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
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
      final lat = (m['lat'] as num).toDouble();
      final lng = (m['lng'] as num).toDouble();
      final nick = m['nickname'] as String? ?? '';
      final vehicleType = m['vehicle_type'] as String? ?? 'car';
      final isMe = uid == widget.userId;
      final icon = await _getVehicleMarker(vehicleType, isMe);
      newMarkers.add(Marker(
        markerId: MarkerId(uid),
        position: LatLng(lat, lng),
        icon: icon,
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

    setState(() => _markers = newMarkers);
  }

  // ── ここまで警告ポイント ───────────────────────────────────────

  void _updateDestinationMarker() {
    final dest = _activeDestination;
    if (dest != null) {
      _fetchRoute(dest);
    } else {
      setState(() => _polylines = {});
    }
    _rebuildMarkers();
  }

  Future<void> _fetchRoute(LatLng dest) async {
    const apiKey = 'AIzaSyChuUZypiVhojgCO6ZgZML-ZW3eYLtti5c';
    try {
      final origin = '${_myPosition.latitude},${_myPosition.longitude}';
      final destination = '${dest.latitude},${dest.longitude}';
      final url = 'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=$origin&destination=$destination'
          '&mode=driving&language=ja&key=$apiKey';
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      final data = jsonDecode(body);
      if (data['status'] == 'OK') {
        final steps = data['routes'][0]['legs'][0]['steps'] as List;
        final allCoords = <LatLng>[];
        for (final step in steps) {
          final encoded = step['polyline']['points'] as String;
          final points = PolylinePoints.decodePolyline(encoded);
          allCoords.addAll(points.map((p) => LatLng(p.latitude, p.longitude)));
        }
        if (allCoords.isNotEmpty && mounted) {
          setState(() {
            _polylines = {
              Polyline(
                polylineId: const PolylineId('route'),
                points: allCoords,
                color: const Color(0xFF1565C0),
                width: 5,
              ),
            };
          });
          _animateCamera(
            CameraUpdate.newLatLngZoom(_myPosition, 14),
            programmatic: true,
          );
        }
      }
    } catch (e) {
      debugPrint('ルート取得エラー: $e');
    }
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
      });
      _updateDestinationMarker();
      _saveDestHistory(name, lat, lng);
      Navigator.pop(ctx);
    }

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
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
                if (searchResults.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 250),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: searchResults.length,
                      itemBuilder: (_, i) {
                        final r = searchResults[i];
                        return ListTile(
                          leading: const Icon(Icons.place, color: Color(0xFF00D4FF)),
                          title: Text(r['name'], style: const TextStyle(color: Colors.white, fontSize: 14)),
                          subtitle: Text(r['address'], style: const TextStyle(color: Colors.grey, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => selectDest(ctx, r['name'] as String, r['lat'] as double, r['lng'] as double),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 4),
                TextButton.icon(
                  icon: const Icon(Icons.my_location, color: Color(0xFF00D4FF), size: 18),
                  label: const Text('現在地を目的地に設定', style: TextStyle(color: Color(0xFF00D4FF))),
                  onPressed: () {
                    setState(() {
                      _groupDestination = _myPosition;
                      _groupDestName = '現在地';
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
                  setState(() { _groupDestination = null; _groupDestName = ''; });
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
    final dest = _activeDestination!;
    final name = _activeDestName;
    await _db.child('rooms/${widget.roomCode}/destination').set({
      'lat': dest.latitude,
      'lng': dest.longitude,
      'name': name,
      'senderUid': widget.userId,
      'senderNick': widget.nickname,
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('📍 「$name」をグループに共有しました'), backgroundColor: const Color(0xFF1A3A5C)),
      );
    }
  }

  void _listenToMembers() {
    _membersSubscription = _db
        .child('rooms/${widget.roomCode}/members')
        .onValue
        .listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return;
      final updated = <String, dynamic>{};
      data.forEach((k, v) => updated[k.toString()] = v);
      if (mounted) {
        setState(() => _members = updated);
        _rebuildMarkers();
      }
    });
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
      if (!_isFollowingMember && !_programmaticCameraMove) {
        _animateCamera(CameraUpdate.newLatLng(_myPosition), programmatic: true);
      }
      _checkRouteDeviation();
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
      if (!_isFollowingMember && !_programmaticCameraMove) {
        _animateCamera(
          CameraUpdate.newLatLng(_myPosition),
          programmatic: true,
        );
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
    if (_polylines.isEmpty || _groupDestination == null) return;

    // クールダウン中はスキップ
    final now = DateTime.now();
    if (_lastRerouteTime != null &&
        now.difference(_lastRerouteTime!).inSeconds < _rerouteCooldownSecs) return;

    // ポリラインの全点を抽出
    final points = _polylines.first.points;
    if (points.isEmpty) return;

    final dist = _distanceToPolyline(_myPosition, points);
    if (dist > _rerouteThresholdMeters) {
      _lastRerouteTime = now;
      debugPrint('ルート逸脱検知: ${dist.toStringAsFixed(0)}m → 再検索');
      _fetchRoute(_groupDestination!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📍 ルートを外れたため再検索しています...'),
            backgroundColor: Color(0xFF1A3A5C),
            duration: Duration(seconds: 2),
          ),
        );
      }
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
      _programmaticCameraMove = true;
    }
    _mapController!.animateCamera(update);
  }

  double _calcDistance(double lat, double lng) {
    const R = 6371.0;
    final dLat = (lat - _myPosition.latitude) * (3.141592653589793 / 180);
    final dLng = (lng - _myPosition.longitude) * (3.141592653589793 / 180);
    final a = (dLat / 2) * (dLat / 2) +
        (_myPosition.latitude * 3.141592653589793 / 180).abs() *
            (dLng / 2) * (dLng / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _locationSubscription?.cancel();
    _countdownTimer?.cancel();
    _expiryTimer?.cancel();
    _warningCleanupTimer?.cancel();
    _membersSubscription?.cancel();
    _destSubscription?.cancel();
    _warningsSubscription?.cancel();
    _appLinkSubscription?.cancel();
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

  void _shareRoomCode() {
    final link = 'https://drivelink-a7ffb.web.app/join?room=${widget.roomCode}';
    Share.share('TouriLinkで一緒にツーリングしよう！\nリンクをタップしてルームに参加👇\n$link\n\nリンクが使えない場合はルームコード: ${widget.roomCode}');
  }

  // 縦向きレイアウト
  Widget _buildPortraitLayout() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A1628),
        titleSpacing: 12,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('TouriLink',
                style: GoogleFonts.audiowide(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            Text('ルーム: ${widget.roomCode} | ${_members.length}人が走行中',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
        actions: [
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
                activeColor: Colors.green,
                inactiveThumbColor: Colors.grey,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (_) => _toggleLocationSharing(),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.share_rounded, color: Colors.white, size: 22),
            tooltip: 'ルームを共有',
            onPressed: _shareRoomCode,
          ),
          TextButton.icon(
            icon: const Icon(Icons.exit_to_app, color: Colors.white, size: 18),
            label: const Text('退出', style: TextStyle(color: Colors.white, fontSize: 13)),
            onPressed: () => Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        bottom: true,
        child: Column(
          children: [
            if (_remainingTime.isNotEmpty) _buildTimerBanner(),
            Expanded(child: _buildMap()),
            _buildBottomSection(),
            if (_isBannerAdLoaded) _buildAdBanner(),
          ],
        ),
      ),
    );
  }

  // 横向きレイアウト
  Widget _buildLandscapeLayout() {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      body: SafeArea(
        child: Row(
          children: [
            // 左: マップ（メイン）
            Expanded(
              flex: 3,
              child: Column(
                children: [
                  if (_remainingTime.isNotEmpty) _buildTimerBanner(),
                  Expanded(child: _buildMap()),
                ],
              ),
            ),
            // 右: サイドパネル
            Container(
              width: 180,
              color: const Color(0xFF0D1B2A),
              child: Column(
                children: [
                  // ルーム情報 + 退出ボタン
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    color: const Color(0xFF0A1628),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('TouriLink',
                                  style: GoogleFonts.audiowide(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                              Text('${_members.length}人が走行中',
                                  style: const TextStyle(color: Colors.grey, fontSize: 10)),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(builder: (_) => const LoginScreen()),
                          ),
                          child: const Icon(Icons.exit_to_app, color: Colors.white54, size: 20),
                        ),
                      ],
                    ),
                  ),
                  // メンバーリスト（縦向き）
                  Expanded(
                    child: _buildMemberListVertical(),
                  ),
                  // アクションボタン
                  _buildActionButtons(),
                  // 広告
                  if (_isBannerAdLoaded) _buildAdBanner(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: GoogleMap(
        initialCameraPosition: CameraPosition(target: _myPosition, zoom: 15),
        markers: _markers,
        polylines: _polylines,
        onMapCreated: (c) => _mapController = c,
        onCameraMoveStarted: () {
          if (_programmaticCameraMove) {
            _programmaticCameraMove = false;
            return;
          }
          setState(() => _isFollowingMember = true);
        },
        onCameraIdle: () {
          _programmaticCameraMove = false;
        },
        myLocationEnabled: false,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
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
      color: const Color(0xFF0D1B2A),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildMemberList(),
          const SizedBox(height: 6),
          _buildActionButtons(),
        ],
      ),
    );
  }

  // アクションボタン行（縦・横レイアウト共用）
  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          _buildActionBtn(
            icon: _polylines.isNotEmpty ? Icons.stop : Icons.place,
            label: _polylines.isNotEmpty ? 'ルート終了' : '目的地',
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
                    });
                    _updateDestinationMarker();
                  }
                : _setPersonalDestination,
          ),
          _buildActionBtn(
            icon: Icons.my_location,
            label: '現在地',
            color: const Color(0xFF1A3A5C),
            onTap: () {
              setState(() => _isFollowingMember = false);
              _animateCamera(CameraUpdate.newLatLng(_myPosition), programmatic: true);
            },
          ),
          _buildActionBtn(
            icon: Icons.share,
            label: 'ルート共有',
            color: _groupDestination != null
                ? const Color(0xFF00D4FF)
                : Colors.grey.shade800,
            onTap: _groupDestination != null ? _shareGroupDestination : null,
          ),
          _buildActionBtn(
            icon: Icons.warning_amber_rounded,
            label: '注意喚起',
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
          ),
        ],
      ),
    );
  }

  Widget _buildActionBtn({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 2),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 10)),
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

  // 横向き用: 縦スクロールのメンバーリスト
  Widget _buildMemberListVertical() {
    final uids = _members.keys.toList();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: uids.length,
      itemBuilder: (context, index) {
        final uid = uids[index];
        final m = _members[uid] as Map;
        final nick = m['nickname'] as String? ?? '?';
        final lat = (m['lat'] as num).toDouble();
        final lng = (m['lng'] as num).toDouble();
        final dist = _calcDistance(lat, lng);
        final isMe = uid == widget.userId;
        return ListTile(
          dense: true,
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: isMe ? const Color(0xFF1E90FF) : const Color(0xFFFF6B35),
            child: Text(
              nick.isNotEmpty ? nick[0].toUpperCase() : '?',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          title: Text(nick, style: const TextStyle(color: Colors.white, fontSize: 12)),
          subtitle: Text(
            isMe ? '自分' : '${dist.toStringAsFixed(1)}km',
            style: TextStyle(color: Colors.grey[400], fontSize: 10),
          ),
          onTap: () {
            setState(() => _isFollowingMember = true);
            _mapController?.animateCamera(CameraUpdate.newLatLng(LatLng(lat, lng)));
          },
        );
      },
    );
  }

  Widget _buildMemberList() {
    final uids = _members.keys.toList();
    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: uids.length,
        itemBuilder: (context, index) {
          final uid = uids[index];
          final m = _members[uid] as Map;
          final nick = m['nickname'] as String? ?? '?';
          final lat = (m['lat'] as num).toDouble();
          final lng = (m['lng'] as num).toDouble();
          final dist = _calcDistance(lat, lng);
          final isMe = uid == widget.userId;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: GestureDetector(
              onTap: () {
                setState(() => _isFollowingMember = true);
                _mapController?.animateCamera(
                  CameraUpdate.newLatLng(LatLng(lat, lng)),
                );
              },
              onLongPress: () {
                final bearing = atan2(
                  lng - _myPosition.longitude,
                  lat - _myPosition.latitude,
                ) * 180 / 3.141592653589793;
                final dir = _bearingToDirection(bearing);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('$nickさんは${dist.toStringAsFixed(1)}km先の$dir方向'),
                    duration: const Duration(seconds: 3),
                  ),
                );
              },
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: isMe ? const Color(0xFF1E90FF) : const Color(0xFFFF6B35),
                    child: Text(
                      nick.isNotEmpty ? nick[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(nick, style: const TextStyle(color: Colors.white, fontSize: 11)),
                  Text(
                    isMe ? '自分' : '${dist.toStringAsFixed(1)}km',
                    style: TextStyle(color: Colors.grey[400], fontSize: 10),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _bearingToDirection(double bearing) {
    if (bearing < -157.5 || bearing >= 157.5) return '南';
    if (bearing < -112.5) return '南西';
    if (bearing < -67.5) return '西';
    if (bearing < -22.5) return '北西';
    if (bearing < 22.5) return '北';
    if (bearing < 67.5) return '北東';
    if (bearing < 112.5) return '東';
    return '南東';
  }
}
