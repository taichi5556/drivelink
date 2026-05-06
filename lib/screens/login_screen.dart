import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'main_screen.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import '../services/room_history.dart';

class LoginScreen extends StatefulWidget {
  static String lastProcessedCode = '';
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  // 同一セッション内で getInitialLink を1回だけ消費するフラグ
  static bool _initialLinkConsumed = false;

  final _nicknameController = TextEditingController();
  final _roomController = TextEditingController();
  bool _isLoading = false;
  bool _isJapanese = true;
  String? _createdRoomCode;
  int? _createdExpiresAt;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnim;
  StreamSubscription? _linkSub;
  static bool _appWasInBackground = false;
  static Timer? _backgroundFlagTimer;
  bool _consentAll = false;
  // 'car' / 'bike'。Phase L-1 で UI を削除したが、マーカー絵文字（main_screen.dart）等の
  // 内部ロジックは維持。将来のバイク向け機能差分に備えて読み書きパスは残す。
  String _vehicleType = 'car';
  int _selectedHours = 4;  // デフォルト4時間
  bool get _allConsented => _consentAll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initDeepLink();
    _loadNickname();
    _fadeController = AnimationController(duration: const Duration(milliseconds: 1000), vsync: this);
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);
    _fadeController.forward();
    _roomController.addListener(() => setState(() {}));
    // フレーム描画後に復帰ダイアログを試行（deep link 非同期処理の完了を少し待つ）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      // deep link でルームコードが既にセットされていれば復帰ダイアログをスキップ
      if (_roomController.text.isNotEmpty) return;
      await _maybeShowResumeDialog();
    });
  }

  Future<void> _maybeShowResumeDialog() async {
    final entry = await RoomHistory.loadIfValid();
    if (entry == null || !mounted) return;
    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        title: const Text('前回のルームに戻る？', style: TextStyle(color: Colors.white)),
        content: Text(
          'ルームコード: ${entry.roomCode}\n${entry.nickname}として再入室します。',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('いいえ', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('戻る', style: TextStyle(color: Color(0xFFFF6B35))),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (resume == true) {
      await _resumeRoom(entry);
    } else {
      await RoomHistory.clear();
    }
  }

  /// 保存情報を使って即ルーム入室（Firebase上の最新期限を再確認してから遷移）
  Future<void> _resumeRoom(RoomHistoryEntry entry) async {
    setState(() => _isLoading = true);
    try {
      final userId = await _getStableUserId();
      final db = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: 'https://drivelink-a7ffb-default-rtdb.asia-southeast1.firebasedatabase.app',
      );
      final expirySnapshot = await db.ref('rooms/${entry.roomCode}/info/expires_at').get();
      final expiresAt = (expirySnapshot.value as num?)?.toInt();
      if (!mounted) return;
      if (expiresAt == null || expiresAt <= DateTime.now().millisecondsSinceEpoch) {
        await RoomHistory.clear();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ルームの有効期限が切れています')),
        );
        setState(() => _isLoading = false);
        return;
      }
      await db.ref('rooms/${entry.roomCode}/members/$userId').update({
        'nickname': entry.nickname,
        'vehicle_type': entry.vehicleType,
      });
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => MainScreen(
          nickname: entry.nickname,
          roomCode: entry.roomCode,
          userId: userId,
          vehicleType: entry.vehicleType,
        )),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundFlagTimer?.cancel();
    _nicknameController.dispose();
    _linkSub?.cancel();
    _roomController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundFlagTimer?.cancel();
      _appWasInBackground = true;
    } else if (state == AppLifecycleState.resumed) {
      _backgroundFlagTimer?.cancel();
      _backgroundFlagTimer = Timer(const Duration(seconds: 3), () {
        _appWasInBackground = false;
      });
    }
  }

  String get _nickLabel => _isJapanese ? 'ニックネーム' : 'Nickname';
  String get _emptyNick => _isJapanese ? 'ニックネームを入力してください' : 'Please enter a nickname';
  String get _emptyRoom => _isJapanese ? 'ルームコードを入力してください' : 'Please enter a room code';

  Future<void> _initDeepLink() async {
    if (!_initialLinkConsumed) {
      _initialLinkConsumed = true;
      try {
        final appLinks = AppLinks();
        final uri = await appLinks.getInitialLink();
        if (uri != null && uri.scheme == 'drivevoice' && uri.host == 'join') {
          final code = uri.queryParameters['room'] ?? '';
          if (code.isNotEmpty && mounted) {
            if (!(code == LoginScreen.lastProcessedCode && !_appWasInBackground)) {
              LoginScreen.lastProcessedCode = code;
              setState(() {
                _roomController.text = code;
              });
            }
          }
        }
      } catch (e) {
        debugPrint('deeplink init error: $e');
      }
    }
    final appLinks2 = AppLinks();
    _linkSub = appLinks2.uriLinkStream.listen((uri) {
      if (uri.scheme == 'drivevoice' && uri.host == 'join') {
        final code = uri.queryParameters['room'] ?? '';
        if (code == LoginScreen.lastProcessedCode && !_appWasInBackground) return;
        if (code.isNotEmpty && mounted) {
          LoginScreen.lastProcessedCode = code;
          _appWasInBackground = false;
          _backgroundFlagTimer?.cancel();
          setState(() {
            _roomController.text = code;
          });
        }
      }
    }, onError: (e) => debugPrint('deeplink stream error: $e'));
  }

  Future<void> _loadNickname() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('nickname') ?? '';
    final savedVehicle = prefs.getString('vehicle_type') ?? 'car';
    if (mounted) {
      setState(() {
        if (saved.isNotEmpty) _nicknameController.text = saved;
        _vehicleType = savedVehicle;
      });
    }
  }

  Future<void> _saveNickname(String nickname) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nickname', nickname);
    await prefs.setString('vehicle_type', _vehicleType);
  }

  String _generateRoomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random.secure();
    return List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  // Firebase Anonymous Auth で端末固有の安定したUIDを取得
  Future<String> _getStableUserId() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      final credential = await FirebaseAuth.instance.signInAnonymously();
      user = credential.user!;
    }
    return user.uid;
  }

  Future<void> _createRoom() async {
    final nickname = _nicknameController.text.trim();
    await _saveNickname(nickname);
    if (!mounted) return;
    if (nickname.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_emptyNick)));
      return;
    }
    setState(() => _isLoading = true);
    try {
      // Android 14以降: DB操作前に匿名認証を完了させる
      await _getStableUserId();
      final roomCode = _generateRoomCode();
      final expiresAt = DateTime.now().millisecondsSinceEpoch + (_selectedHours * 3600 * 1000);
      final db = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: 'https://drivelink-a7ffb-default-rtdb.asia-southeast1.firebasedatabase.app',
      );
      await db.ref('rooms/$roomCode/info').set({
        'expires_at': expiresAt,
        'duration_hours': _selectedHours,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      setState(() { _createdRoomCode = roomCode; _createdExpiresAt = expiresAt; _isLoading = false; });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _enterRoom() async {
    final nickname = _nicknameController.text.trim();
    await _saveNickname(nickname);
    if (!mounted) return;
    final roomCode = _roomController.text.trim().toUpperCase();
    if (nickname.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_emptyNick))); return; }
    if (roomCode.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_emptyRoom))); return; }
    setState(() => _isLoading = true);
    try {
      // Android 14以降: DB操作前に匿名認証を完了させる
      final userId = await _getStableUserId();
      final db = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: 'https://drivelink-a7ffb-default-rtdb.asia-southeast1.firebasedatabase.app',
      );
      // ルームの有効期限を確認してから入室
      final expirySnapshot = await db.ref('rooms/$roomCode/info/expires_at').get();
      final expiresAt = (expirySnapshot.value as num?)?.toInt();
      if (!mounted) return;
      if (expiresAt == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_isJapanese ? 'ルームが見つかりません' : 'Room not found')),
        );
        setState(() => _isLoading = false);
        return;
      }
      if (expiresAt <= DateTime.now().millisecondsSinceEpoch) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_isJapanese ? 'このルームは有効期限が切れています' : 'This room has expired')),
        );
        setState(() => _isLoading = false);
        return;
      }
      await db.ref('rooms/$roomCode/members/$userId').update({
        'nickname': nickname, 'vehicle_type': _vehicleType,
      });
      // ルーム履歴を端末に保存（kill後の復帰ダイアログ用）
      await RoomHistory.save(
        roomCode: roomCode,
        nickname: nickname,
        vehicleType: _vehicleType,
        expiresAt: expiresAt,
      );
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MainScreen(nickname: nickname, roomCode: roomCode, userId: userId, vehicleType: _vehicleType)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _startFromCreated() async {
    final nickname = _nicknameController.text.trim();
    final roomCode = _createdRoomCode!;
    final userId = await _getStableUserId();
    if (!mounted) return;
    final db = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: 'https://drivelink-a7ffb-default-rtdb.asia-southeast1.firebasedatabase.app',
    );
    await db.ref('rooms/$roomCode/members/$userId').update({
      'nickname': nickname,
      'vehicle_type': _vehicleType,
    });
    // ルーム履歴を端末に保存（kill後の復帰ダイアログ用）
    if (_createdExpiresAt != null) {
      await RoomHistory.save(
        roomCode: roomCode,
        nickname: nickname,
        vehicleType: _vehicleType,
        expiresAt: _createdExpiresAt!,
      );
    }
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MainScreen(nickname: nickname, roomCode: roomCode, userId: userId, vehicleType: _vehicleType)));
  }

  void _shareRoomCode(String code) {
    final link = 'https://drivelink-a7ffb.web.app/join?room=$code';
    SharePlus.instance.share(ShareParams(text: _isJapanese
        ? 'TouriLinkで一緒にツーリングしよう！\nリンクをタップしてルームに参加👇\n$link\n\nリンクが使えない場合はルームコード: $code'
        : 'Join me on TouriLink!\nTap the link to join👇\n$link\n\nRoom Code: $code'));
  }

  void _copyRoomCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_isJapanese ? 'コードをコピーしました！' : 'Code copied!'),
      backgroundColor: const Color(0xFF00C896),
      duration: const Duration(seconds: 2),
    ));
  }


  // ─── ナビ案内 ─────────────────────────────────────────────
  Widget _buildInfoRow(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline_rounded, color: Color(0xFF4CAF50), size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Color(0xFF81C784), fontSize: 12, height: 1.5),
          ),
        ),
      ],
    );
  }

  Widget _buildNaviInfoCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1A0D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1A4A1A), width: 1.5),
      ),
      child: _buildInfoRow(
        _isJapanese
            ? 'バックグラウンドでも位置情報の共有を継続します。端末の状態により停止する場合があります（その場合は復帰時に自動再開）。'
            : 'Location sharing continues in the background. It may stop depending on device conditions, in which case it resumes automatically when you return.',
      ),
    );
  }

  // ─── 同意チェックセクション ───────────────────────────────
  Widget _buildConsentSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              const Icon(Icons.verified_user_rounded,
                  color: Color(0xFF00D4FF), size: 15),
              const SizedBox(width: 6),
              Text(
                _isJapanese ? '利用規約への同意' : 'Terms of Use',
                style: const TextStyle(
                  color: Color(0xFF6680AA),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        _buildConsentTile(
          icon: Icons.verified_user_rounded,
          iconColor: const Color(0xFFFF6B35),
          text: _isJapanese
              ? '位置情報の共有および運転中はアプリを操作しないことに同意します'
              : 'I agree to share my location and not to operate this app while driving.',
          value: _consentAll,
          onChanged: (v) => setState(() => _consentAll = v ?? false),
          isWarning: true,
        ),
        if (!_allConsented) ...[
          const SizedBox(height: 8),
          Center(
            child: Text(
              _isJapanese
                  ? 'チェックを入れると開始できます'
                  : 'Check the box to continue',
              style: const TextStyle(
                color: Color(0xFF3A5070),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildConsentTile({
    required IconData icon,
    required Color iconColor,
    required String text,
    required bool value,
    required ValueChanged<bool?> onChanged,
    bool isWarning = false,
  }) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: value
              ? (isWarning
                  ? const Color(0xFF1A1005)
                  : const Color(0xFF071420))
              : const Color(0xFF111827),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: value
                ? (isWarning
                    ? const Color(0xFFFF6B35).withValues(alpha: 0.7)
                    : const Color(0xFF00D4FF).withValues(alpha: 0.7))
                : const Color(0xFF1E3A5F),
            width: value ? 1.5 : 1.0,
          ),
          boxShadow: value
              ? [
                  BoxShadow(
                    color: (isWarning
                            ? const Color(0xFFFF6B35)
                            : const Color(0xFF00D4FF))
                        .withValues(alpha: 0.08),
                    blurRadius: 10,
                    spreadRadius: 1,
                  )
                ]
              : [],
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: iconColor.withValues(alpha: 0.12),
              ),
              child: Icon(icon, color: iconColor, size: 17),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: value ? Colors.white : const Color(0xFF8899AA),
                  fontSize: 13,
                  fontWeight:
                      value ? FontWeight.w600 : FontWeight.normal,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: onChanged,
                activeColor: isWarning
                    ? const Color(0xFFFF6B35)
                    : const Color(0xFF00D4FF),
                checkColor: Colors.white,
                side: BorderSide(
                  color: value
                      ? (isWarning
                          ? const Color(0xFFFF6B35)
                          : const Color(0xFF00D4FF))
                      : const Color(0xFF3A5070),
                  width: 1.5,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label, IconData icon, {bool isCode = false}) {
    return TextField(
      controller: ctrl,
      style: TextStyle(color: Colors.white, fontSize: isCode ? 14 : 13, letterSpacing: isCode ? 6 : 0, fontWeight: isCode ? FontWeight.bold : FontWeight.normal),
      textCapitalization: isCode ? TextCapitalization.characters : TextCapitalization.none,
      textAlign: isCode ? TextAlign.center : TextAlign.start,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF6680AA)),
        prefixIcon: Icon(icon, color: const Color(0xFF00D4FF), size: 22),
        filled: true,
        fillColor: const Color(0xFF111827),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF1E3A5F), width: 1.5)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF00D4FF), width: 2)),
      ),
    );
  }

  Widget _buildGradientButton(String text, IconData icon, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity, height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: onTap == null
              ? const LinearGradient(colors: [Color(0xFF334455), Color(0xFF334455)])
              : const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF0057FF)], begin: Alignment.centerLeft, end: Alignment.centerRight),
          boxShadow: onTap == null ? [] : [BoxShadow(color: const Color(0xFF00D4FF).withValues(alpha: 0.35), blurRadius: 20, offset: const Offset(0, 6))],
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070D1A),
      body: Stack(children: [
        Positioned(top: -80, left: -60, child: Container(width: 280, height: 280,
          decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF00D4FF).withValues(alpha: 0.07)))),
        SafeArea(child: FadeTransition(opacity: _fadeAnim, child: Column(children: [
          Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(children: [
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('TouriLink', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 1.5)),
              GestureDetector(
                onTap: () => setState(() => _isJapanese = !_isJapanese),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF1E3A5F))),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_isJapanese ? 'JP' : 'EN', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 6),
                    const Icon(Icons.language, color: Color(0xFF00D4FF), size: 16),
                  ]),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            _buildTextField(_nicknameController, _nickLabel, Icons.person_outline_rounded),
            const SizedBox(height: 8),
            _buildNaviInfoCard(),
            const SizedBox(height: 8),
            _buildConsentSection(),
            const SizedBox(height: 8),
            if (_createdRoomCode == null) ...[
              const SizedBox(height: 8),
              if (_roomController.text.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF1E3A5F), width: 1.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.timer_outlined, color: Color(0xFF00D4FF), size: 16),
                      const SizedBox(width: 6),
                      Text(
                        _isJapanese ? 'ルーム使用時間' : 'Room Duration',
                        style: const TextStyle(color: Color(0xFF6680AA), fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [2, 4, 6, 8].map((h) {
                        final selected = _selectedHours == h;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedHours = h),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              gradient: selected
                                  ? const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF0057FF)])
                                  : null,
                              color: selected ? null : const Color(0xFF0D1B2A),
                              border: Border.all(
                                color: selected ? const Color(0xFF00D4FF) : const Color(0xFF1E3A5F),
                                width: selected ? 2 : 1,
                              ),
                              boxShadow: selected ? [BoxShadow(color: const Color(0xFF00D4FF).withValues(alpha: 0.3), blurRadius: 10)] : [],
                            ),
                            child: Text(
                              '${h}h',
                              style: TextStyle(
                                color: selected ? Colors.white : const Color(0xFF6680AA),
                                fontWeight: selected ? FontWeight.w800 : FontWeight.normal,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              // コードが空なら「ルームを作成」、入力中なら「参加する」
              if (_roomController.text.isEmpty)
                _buildGradientButton(_isJapanese ? 'ルームを作成' : 'Create Room', Icons.add_circle_outline_rounded, (_isLoading || !_allConsented) ? null : _createRoom)
              else
                GestureDetector(
                  onTap: (_isLoading || !_allConsented) ? null : _enterRoom,
                  child: Container(
                    width: double.infinity, height: 54,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: (_isLoading || !_allConsented)
                          ? null
                          : const LinearGradient(
                              colors: [Color(0xFF00D4FF), Color(0xFF0057FF)],
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ),
                      color: (_isLoading || !_allConsented) ? const Color(0xFF1E3A5F) : null,
                    ),
                    child: Center(
                      child: _isLoading
                          ? const SizedBox(width: 24, height: 24,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              const Icon(Icons.login_rounded, color: Colors.white, size: 20),
                              const SizedBox(width: 8),
                              Text(_isJapanese ? '参加する' : 'Join',
                                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                            ]),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              // ルームコード入力欄（常時表示）
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF1E3A5F), width: 1.5),
                ),
                child: TextField(
                  controller: _roomController,
                  style: const TextStyle(color: Colors.white, letterSpacing: 3, fontSize: 18, fontWeight: FontWeight.w700),
                  textCapitalization: TextCapitalization.characters,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: _isJapanese ? 'ルームコード（参加する場合）' : 'Room Code (to join)',
                    hintStyle: const TextStyle(color: Color(0xFF3A5078), letterSpacing: 1, fontSize: 13),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  ),
                ),
              ),
            ],
            if (_createdRoomCode != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1B2A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.4), width: 1.5),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF00D4FF), size: 22),
                    const SizedBox(width: 8),
                    Text(_isJapanese ? 'ルーム作成完了！' : 'Room Created!',
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 6),
                  Text(_isJapanese ? 'ルームコード' : 'Room Code',
                    style: const TextStyle(color: Color(0xFF6680AA), fontSize: 10)),
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111827),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF1E3A5F)),
                    ),
                    child: Text(_createdRoomCode!, style: const TextStyle(
                      color: Color(0xFF00D4FF), fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 6)),
                  ),
                  const SizedBox(height: 6),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    GestureDetector(
                      onTap: () => _copyRoomCode(_createdRoomCode!),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111827),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF1E3A5F)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.copy_rounded, color: Color(0xFF00D4FF), size: 14),
                          const SizedBox(width: 5),
                          Text(_isJapanese ? 'コピー' : 'Copy',
                            style: const TextStyle(color: Color(0xFF00D4FF), fontSize: 12)),
                        ]),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => _shareRoomCode(_createdRoomCode!),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111827),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF1E3A5F)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.share_rounded, color: Color(0xFF00D4FF), size: 14),
                          const SizedBox(width: 5),
                          Text(_isJapanese ? '共有' : 'Share',
                            style: const TextStyle(color: Color(0xFF00D4FF), fontSize: 12)),
                        ]),
                      ),
                    ),
                  ]),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => setState(() => _createdRoomCode = null),
                    child: Text(_isJapanese ? '← 戻る' : '← Back',
                      style: const TextStyle(color: Color(0xFF3A5078), fontSize: 12)),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            // プライバシーポリシーへのリンク（A-5: Android クローズドテスト審査要件）
            Center(
              child: GestureDetector(
                onTap: () async {
                  final uri = Uri.parse('https://taichi5556.github.io/drivelink/privacy_policy.html');
                  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('ブラウザを起動できませんでした')),
                    );
                  }
                },
                child: Text(
                  _isJapanese ? 'プライバシーポリシー' : 'Privacy Policy',
                  style: const TextStyle(
                    color: Color(0xFF6680AA),
                    fontSize: 12,
                    decoration: TextDecoration.underline,
                    decorationColor: Color(0xFF6680AA),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ]),
        )),
          if (_createdRoomCode != null) Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: _buildGradientButton(
              _isJapanese ? 'マップを開く' : 'Open Map',
              Icons.map_rounded,
              _startFromCreated),
          ),
        ])))
      ]),
    );
  }
}
