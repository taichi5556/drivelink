import 'dart:async';
import 'dart:math';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'login_screen.dart';
import 'package:google_fonts/google_fonts.dart';

const String agoraAppId = '9b3f59b1a52245b88a7cfbd33236f333';

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

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  LatLng _myPosition = const LatLng(35.6812, 139.7671);
  bool _isRecording = false;
  bool _isOtherRecording = false;
  Timer? _expiryTimer;
  String _remainingTime = '';
  Timer? _countdownTimer;
  Timer? _locationTimer;
  String _fromNickname = '';
  bool _showReceiving = false;
  late AnimationController _pulseController;
  Map<String, dynamic> _members = {};
  StreamSubscription? _membersSubscription;

  // Agora
  RtcEngine? _agoraEngine;
  bool _agoraJoined = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  DatabaseReference get _db => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://drivelink-a7ffb-default-rtdb.asia-southeast1.firebasedatabase.app',
      ).ref();

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _initAll();
  }

  Future<void> _initAll() async {
    await Permission.microphone.request();
    await Permission.locationWhenInUse.request();
    await _initAgora();
    await _updateLocation();
    _locationTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _updateLocation(),
    );
    _listenToMembers();
    _listenToRecordingUser();
    _startExpiryCheck();
  }

  Future<void> _initAgora() async {
    try {
      _agoraEngine = createAgoraRtcEngine();
      await _agoraEngine!.initialize(RtcEngineContext(appId: agoraAppId));
      await _agoraEngine!.setClientRole(role: ClientRoleType.clientRoleAudience);
      await _agoraEngine!.enableAudio();
      await _agoraEngine!.setAudioProfile(
        profile: AudioProfileType.audioProfileMusicHighQuality,
        scenario: AudioScenarioType.audioScenarioChatroom,
      );
      await _agoraEngine!.setDefaultAudioRouteToSpeakerphone(true);
      _agoraEngine!.registerEventHandler(RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) {
          debugPrint('Agora参加成功: ${connection.channelId}');
          if (mounted) setState(() => _agoraJoined = true);
        },
        onUserOffline: (connection, remoteUid, reason) {
          debugPrint('ユーザー退出: $remoteUid');
        },
        onError: (err, msg) {
          debugPrint('Agoraエラー: $err $msg');
        },
      ));
      await _agoraEngine!.joinChannel(
        token: '',
        channelId: widget.roomCode,
        uid: 0,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileCommunication,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          publishMicrophoneTrack: false,
          autoSubscribeAudio: true,
        ),
      );
      debugPrint('Agoraチャンネル参加中: ${widget.roomCode}');
    } catch (e) {
      debugPrint('Agora初期化エラー: $e');
    }
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
    // 5分前に警告
    if (remaining > 5 * 60 * 1000) {
      Timer(Duration(milliseconds: remaining - 5 * 60 * 1000), () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('⏰ ルームの使用時間まで残り5分です'),
          backgroundColor: Color(0xFFFF6B35),
          duration: Duration(seconds: 5),
        ));
      });
    }
    // カウントダウン表示開始
    _startCountdown(expiresAt);
    // 時間切れで自動退出
    _expiryTimer = Timer(Duration(milliseconds: remaining), () {
      if (mounted) _exitDueToExpiry();
    });
  }

  void _startCountdown(int expiresAt) {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final remaining = expiresAt - DateTime.now().millisecondsSinceEpoch;
      if (remaining <= 0) {
        _countdownTimer?.cancel();
        setState(() => _remainingTime = '');
        return;
      }
      final hours = remaining ~/ 3600000;
      final minutes = (remaining % 3600000) ~/ 60000;
      final seconds = (remaining % 60000) ~/ 1000;
      final h = hours.toString();
      final m = minutes.toString().padLeft(2, '0');
      final s = seconds.toString().padLeft(2, '0');
      setState(() {
        _remainingTime = hours > 0
            ? '⏰ 残り ' + h + '時間' + m + '分'
            : '⏰ 残り ' + m + '分' + s + '秒';
      });
    });
  }

  void _exitDueToExpiry() {
    _db.child('rooms/${widget.roomCode}/members/${widget.userId}').remove();
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        title: const Text('⏰ ルーム時間終了', style: TextStyle(color: Colors.white)),
        content: const Text('設定した使用時間が終了しました。お疲れ様でした！', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
            child: const Text('OK', style: TextStyle(color: Color(0xFF00D4FF))),
          ),
        ],
      ),
    );
  }

  void _listenToRecordingUser() {
    _db.child('rooms/${widget.roomCode}/recording_user').onValue.listen((event) {
      final val = event.snapshot.value as String?;
      final otherNick = val != null && val != widget.userId
          ? ((_members[val] as Map?)?['nickname'] as String? ?? '他のユーザー')
          : '';
      if (mounted) {
        setState(() {
          _isOtherRecording = val != null && val != widget.userId;
          if (_isOtherRecording) _fromNickname = otherNick;
          _showReceiving = _isOtherRecording;
        });
      }
    });
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
      if (mounted) {
        setState(() => _myPosition = LatLng(pos.latitude, pos.longitude));
        _mapController?.animateCamera(CameraUpdate.newLatLng(_myPosition));
      }
      await _db.child('rooms/${widget.roomCode}/members/${widget.userId}').update({
        'nickname': widget.nickname,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('位置情報エラー: $e');
    }
  }

  Future<void> _startRecording() async {
    debugPrint('録音開始試行: _isOtherRecording=$_isOtherRecording, _isRecording=$_isRecording');
    if (_isOtherRecording || _isRecording) return;
    if (!_agoraJoined) {
      debugPrint('Agora未接続のため録音不可');
      return;
    }
    // Agoraのマイク送信を開始
    try {
      await _agoraEngine?.updateChannelMediaOptions(const ChannelMediaOptions(
        publishMicrophoneTrack: true,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
      ));
    } catch (e) {
      debugPrint('startRecording Agora error: $e');
      return;
    }
    await _db.child('rooms/${widget.roomCode}/recording_user').set(widget.userId);
    try {
      await _agoraEngine?.muteLocalAudioStream(false);
      await _agoraEngine?.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
      if (mounted) setState(() { _isRecording = true; _recordSeconds = 0; });
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _recordSeconds++);
        if (_recordSeconds >= 30) _stopRecording();
      });
      debugPrint('Agora録音開始');
    } catch (e) {
      debugPrint('録音開始エラー: $e');
      await _db.child('rooms/${widget.roomCode}/recording_user').remove();
    }
  }

  Future<void> _stopRecording() async {
    // Agoraのマイク送信を停止
    if (_agoraJoined) {
      try {
        await _agoraEngine?.updateChannelMediaOptions(const ChannelMediaOptions(
          publishMicrophoneTrack: false,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
        ));
      } catch (e) {
        debugPrint('stopRecording Agora error: $e');
      }
    }
    _recordTimer?.cancel();
    try {
      await _agoraEngine?.muteLocalAudioStream(true);
    } catch (e) {
      debugPrint('録音停止エラー: $e');
    }
    await _db.child('rooms/${widget.roomCode}/recording_user').remove();
    if (mounted) setState(() => _isRecording = false);
    debugPrint('Agora録音停止');
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
    _pulseController.dispose();
    _locationTimer?.cancel();
    _recordTimer?.cancel();
    _membersSubscription?.cancel();
    _db.child('rooms/${widget.roomCode}/members/${widget.userId}').remove();
    _db.child('rooms/${widget.roomCode}/recording_user').remove();
    _agoraEngine?.leaveChannel();
    _agoraEngine?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A1628),
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
          if (_agoraJoined)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Icon(Icons.wifi, color: Colors.green, size: 20),
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
            if (_showReceiving) _buildReceivingBanner(),
            if (_remainingTime.isNotEmpty) _buildTimerBanner(),
            Expanded(flex: 3, child: _buildMap()),
            Expanded(flex: 2, child: _buildRecButton()),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            GoogleMap(
          initialCameraPosition: CameraPosition(target: _myPosition, zoom: 15),
          markers: _markers,
          onMapCreated: (c) => _mapController = c,
          myLocationEnabled: true,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
        ),
            Positioned(
              right: 8,
              bottom: 8,
              child: FloatingActionButton.small(
                backgroundColor: Colors.white,
                onPressed: () => _mapController?.animateCamera(CameraUpdate.newLatLng(_myPosition)),
                child: const Icon(Icons.my_location, color: Colors.grey),
              ),
            ),
          ],
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

  Widget _buildReceivingBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: const Color(0xFF1A3A5C),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.volume_up, color: Colors.green, size: 20),
          const SizedBox(width: 8),
          Text(
            _isOtherRecording ? '${_fromNickname}さんが話しています...' : '${_fromNickname}さんの声を受信中...',
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildRecButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildMemberList(),
          const SizedBox(height: 2),
          if (_isRecording)
            Text(
              '送信中... 残り ${30 - _recordSeconds}秒',
              style: const TextStyle(color: Colors.redAccent, fontSize: 14),
            ),
          const SizedBox(height: 2),
          GestureDetector(
            onLongPressStart: _isOtherRecording ? null : (_) => _startRecording(),
            onLongPressEnd: _isOtherRecording ? null : (_) => _stopRecording(),
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (_, __) => Container(
                width: 300,
                height: 160,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(40),
                  color: _isOtherRecording
                      ? Colors.grey
                      : _isRecording
                          ? Color.lerp(Colors.red, Colors.redAccent, _pulseController.value)!
                          : const Color(0xFFFF6B35),
                  boxShadow: [
                    BoxShadow(
                      color: (_isOtherRecording
                              ? Colors.grey
                              : _isRecording ? Colors.red : const Color(0xFFFF6B35))
                          .withAlpha((_pulseController.value * 180).toInt()),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _isRecording ? Icons.mic : Icons.mic_none,
                      color: Colors.white,
                      size: 36,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _isOtherRecording ? '録音中(他ユーザー)' : _isRecording ? '送信中...' : '長押しで送信',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
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
