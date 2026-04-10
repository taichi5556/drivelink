import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'login_screen.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';

class MainScreen extends StatefulWidget {
  final String userId;
  final String nickname;
  final String roomCode;
  const MainScreen({
    Key? key,
    required this.userId,
    required this.nickname,
    required this.roomCode,
  }) : super(key: key);

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  GoogleMapController? _mapController;
  bool _isFollowingMember = false;
  bool _programmaticCameraMove = false;
  Set<Marker> _markers = {};
  LatLng _myPosition = const LatLng(35.6812, 139.7671);
  Timer? _expiryTimer;
  String _remainingTime = '';
  Timer? _countdownTimer;
  Timer? _locationTimer;
  bool _updateLocationInProgress = false;
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
    WakelockPlus.enable();
    _initAll();
    _loadBannerAd();
  }

  Future<void> _initAll() async {
    await Permission.locationWhenInUse.request();
    await _updateLocation();
    _locationTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _updateLocation(),
    );
    _listenToMembers();
    _listenToDestination();
    _initAppLinks();
    _startExpiryCheck();
  }

  void _loadBannerAd() {
    _bannerAd = BannerAd(
      adUnitId: 'ca-app-pub-3940256099942544/6300978111',
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
    final snapshot = await _db.child('rooms/${widget.roomCode}/info/expires_at').get();
    if (!mounted) return;
    final expiresAt = snapshot.value as int?;
    if (expiresAt == null) return;
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
    if (!mounted) return;
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

  void _updateDestinationMarker() {
    final dest = _activeDestination;
    final name = _activeDestName;
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == 'destination');
      if (dest != null) {
        _markers.add(Marker(
          markerId: const MarkerId('destination'),
          position: dest,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          infoWindow: InfoWindow(title: name),
        ));
        _fetchRoute(dest);
      } else {
        setState(() => _polylines = {});
      }
    });
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

  Future<void> _setPersonalDestination() async {
    final TextEditingController searchCtrl = TextEditingController();
    List<Map<String, dynamic>> searchResults = [];
    bool isSearching = false;
    const placesApiKey = 'AIzaSyChuUZypiVhojgCO6ZgZML-ZW3eYLtti5c';

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
                const SizedBox(height: 8),
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
                          onTap: () async {
                            setState(() {
                              _groupDestination = LatLng(r['lat'], r['lng']);
                              _groupDestName = r['name'];
                            });
                            _updateDestinationMarker();
                            Navigator.pop(ctx);
                          },
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
      final newMarkers = <Marker>{};
      updated.forEach((uid, val) {
        final m = val as Map;
        final lat = (m['lat'] as num).toDouble();
        final lng = (m['lng'] as num).toDouble();
        final nick = m['nickname'] as String? ?? '';
        final isMe = uid == widget.userId;
        newMarkers.add(Marker(
          markerId: MarkerId(uid),
          position: LatLng(lat, lng),
          icon: isMe
              ? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue)
              : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(title: nick),
        ));
      });
      if (mounted) {
        setState(() {
          _members = updated;
          _markers = newMarkers;
        });
      }
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
          _locationTimer?.cancel();
          return;
        }
      }
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() => _myPosition = LatLng(pos.latitude, pos.longitude));
      await _db.child('rooms/${widget.roomCode}/members/${widget.userId}').update({
        'nickname': widget.nickname,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
      });
      if (!mounted) return;
      if (!_isFollowingMember && !_programmaticCameraMove) {
        _animateCamera(
          CameraUpdate.newLatLng(_myPosition),
          programmatic: true,
        );
      }
    } catch (e) {
      debugPrint('位置情報エラー: $e');
    } finally {
      _updateLocationInProgress = false;
    }
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
    _locationTimer?.cancel();
    _countdownTimer?.cancel();
    _expiryTimer?.cancel();
    _membersSubscription?.cancel();
    _destSubscription?.cancel();
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
            Text('DriveVoice',
                style: GoogleFonts.audiowide(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            Text('ルーム: ${widget.roomCode} | ${_members.length}人が走行中',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
        actions: [
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
                              Text('DriveVoice',
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 10)),
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
