import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:share_plus/share_plus.dart';
import 'main_screen.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  final _nicknameController = TextEditingController();
  final _roomController = TextEditingController();
  bool _isLoading = false;
  bool _isJapanese = true;
  bool _isJoining = false;
  String? _createdRoomCode;
  late AnimationController _fadeController;
  late AnimationController _pulseController;
  late Animation<double> _fadeAnim;
  late Animation<double> _pulseAnim;
  StreamSubscription? _linkSub;
  bool _consentLocation = false;
  String _vehicleType = 'car'; // 'car' or 'bike'
  int _selectedHours = 4;  // デフォルト4時間
  bool get _allConsented => _consentLocation;

  @override
  void initState() {
    super.initState();
    _initDeepLink();
    _loadNickname();
    _fadeController = AnimationController(duration: const Duration(milliseconds: 1000), vsync: this);
    _pulseController = AnimationController(duration: const Duration(seconds: 2), vsync: this)..repeat(reverse: true);
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.08).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _fadeController.forward();
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _linkSub?.cancel();
    _roomController.dispose();
    _fadeController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  String get _subtitle => _isJapanese ? 'ドライブ仲間と繋がろう' : 'Connect with your drive buddies';
  String get _nickLabel => _isJapanese ? 'ニックネーム' : 'Nickname';
  String get _roomLabel => _isJapanese ? 'ルームコード' : 'Room Code';
  String get _startLabel => _isJapanese ? 'ドライブ開始！' : 'Start Drive!';
  String get _emptyNick => _isJapanese ? 'ニックネームを入力してください' : 'Please enter a nickname';
  String get _emptyRoom => _isJapanese ? 'ルームコードを入力してください' : 'Please enter a room code';

  Future<void> _initDeepLink() async {
    // 起動時のリンクを処理
    try {
      final appLinks = AppLinks();
      final uri = await appLinks.getInitialLink();
      if (uri != null && uri.scheme == 'drivevoice' && uri.host == 'join') {
        final code = uri.queryParameters['room'] ?? '';
        if (code.isNotEmpty && mounted) {
          setState(() {
            _roomController.text = code;
            _isJoining = true;
          });
        }
      }
    } catch (e) {
      debugPrint('deeplink init error: $e');
    }
    // 起動中のリンクを監視
    final appLinks2 = AppLinks();
    _linkSub = appLinks2.uriLinkStream.listen((uri) {
      if (uri != null && uri.scheme == 'drivevoice' && uri.host == 'join') {
        final code = uri.queryParameters['room'] ?? '';
        if (code.isNotEmpty && mounted) {
          setState(() {
            _roomController.text = code;
            _isJoining = true;
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

  Future<void> _createRoom() async {
    final nickname = _nicknameController.text.trim();
    await _saveNickname(nickname);
    if (nickname.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_emptyNick)));
      return;
    }
    setState(() => _isLoading = true);
    try {
      final roomCode = _generateRoomCode();
      final prefs2 = await SharedPreferences.getInstance();
      String userId = prefs2.getString('user_id') ?? '';
      if (userId.isEmpty) {
        userId = 'u_${DateTime.now().millisecondsSinceEpoch}';
        await prefs2.setString('user_id', userId);
      }
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
      setState(() { _createdRoomCode = roomCode; _isLoading = false; });
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
    final roomCode = _roomController.text.trim().toUpperCase();
    if (nickname.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_emptyNick))); return; }
    if (roomCode.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_emptyRoom))); return; }
    setState(() => _isLoading = true);
    try {
      final prefs2 = await SharedPreferences.getInstance();
      String userId = prefs2.getString('user_id') ?? '';
      if (userId.isEmpty) {
        userId = 'u_${DateTime.now().millisecondsSinceEpoch}';
        await prefs2.setString('user_id', userId);
      }
      await FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: 'https://drivelink-a7ffb-default-rtdb.asia-southeast1.firebasedatabase.app',
      ).ref('rooms/$roomCode/members/$userId').set({
        'nickname': nickname, 'lat': 35.6812, 'lng': 139.7671,
      });
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
    final prefs2 = await SharedPreferences.getInstance();
      String userId = prefs2.getString('user_id') ?? '';
      if (userId.isEmpty) {
        userId = 'u_${DateTime.now().millisecondsSinceEpoch}';
        await prefs2.setString('user_id', userId);
      }
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MainScreen(nickname: nickname, roomCode: roomCode, userId: userId, vehicleType: _vehicleType)));
  }

  void _shareRoomCode(String code) {
    final link = 'https://drivelink-a7ffb.web.app/join?room=$code';
    Share.share(_isJapanese
        ? 'DriveVoiceで一緒にドライブしよう！\nリンクをタップしてルームに参加👇\n$link\n\nリンクが使えない場合はルームコード: $code'
        : 'Join me on DriveVoice!\nTap the link to join👇\n$link\n\nRoom Code: $code');
  }

  void _copyRoomCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_isJapanese ? 'コードをコピーしました！' : 'Code copied!'),
      backgroundColor: const Color(0xFF00C896),
      duration: const Duration(seconds: 2),
    ));
  }


  // ─── 車両選択 ─────────────────────────────────────────────
  Widget _buildVehicleSelector() {
    return Container(
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
            const Icon(Icons.directions_car_rounded, color: Color(0xFF00D4FF), size: 16),
            const SizedBox(width: 6),
            Text(
              _isJapanese ? '車両タイプ' : 'Vehicle Type',
              style: const TextStyle(color: Color(0xFF6680AA), fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _buildVehicleBtn('car',  '🚗', _isJapanese ? '車' : 'Car')),
            const SizedBox(width: 10),
            Expanded(child: _buildVehicleBtn('bike', '🏍', _isJapanese ? 'バイク' : 'Bike')),
          ]),
        ],
      ),
    );
  }

  Widget _buildVehicleBtn(String type, String emoji, String label) {
    final selected = _vehicleType == type;
    return GestureDetector(
      onTap: () => setState(() => _vehicleType = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
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
          boxShadow: selected
              ? [BoxShadow(color: const Color(0xFF00D4FF).withValues(alpha: 0.3), blurRadius: 10)]
              : [],
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : const Color(0xFF6680AA),
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
          ],
        ),
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
          icon: Icons.location_on_rounded,
          iconColor: const Color(0xFF00D4FF),
          text: _isJapanese
              ? '位置情報を共有します。同意しますか？'
              : 'I agree to share my location.',
          value: _consentLocation,
          onChanged: (v) => setState(() => _consentLocation = v ?? false),
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
                    ? const Color(0xFFFF6B35).withOpacity(0.7)
                    : const Color(0xFF00D4FF).withOpacity(0.7))
                : const Color(0xFF1E3A5F),
            width: value ? 1.5 : 1.0,
          ),
          boxShadow: value
              ? [
                  BoxShadow(
                    color: (isWarning
                            ? const Color(0xFFFF6B35)
                            : const Color(0xFF00D4FF))
                        .withOpacity(0.08),
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
                color: iconColor.withOpacity(0.12),
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
          boxShadow: onTap == null ? [] : [BoxShadow(color: const Color(0xFF00D4FF).withOpacity(0.35), blurRadius: 20, offset: const Offset(0, 6))],
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
          decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF00D4FF).withOpacity(0.07)))),
        Positioned(bottom: -60, right: -40, child: Container(width: 220, height: 220,
          decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF0057FF).withOpacity(0.08)))),
        SafeArea(child: FadeTransition(opacity: _fadeAnim, child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(children: [
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
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
            const SizedBox(height: 4),
            ScaleTransition(scale: _pulseAnim, child: Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF0057FF)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                boxShadow: [BoxShadow(color: const Color(0xFF00D4FF).withOpacity(0.5), blurRadius: 32, spreadRadius: 4)],
              ),
              child: const Icon(Icons.directions_car_rounded, color: Colors.white, size: 24),
            )),
            const SizedBox(height: 4),
            const Text('DriveVoice', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 2)),
            const SizedBox(height: 2),
            Text(_subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF6680AA), letterSpacing: 0.5)),
            const SizedBox(height: 8),
            _buildTextField(_nicknameController, _nickLabel, Icons.person_outline_rounded),
            const SizedBox(height: 8),
            _buildVehicleSelector(),
            const SizedBox(height: 8),
            _buildConsentSection(),
            const SizedBox(height: 8),
            if (_createdRoomCode == null) ...[
              const SizedBox(height: 8),
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
                              boxShadow: selected ? [BoxShadow(color: const Color(0xFF00D4FF).withOpacity(0.3), blurRadius: 10)] : [],
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
              _buildGradientButton(_isJapanese ? 'ルームを作成' : 'Create Room', Icons.add_circle_outline_rounded, (_isLoading || !_allConsented) ? null : _createRoom),
              const SizedBox(height: 10),
              Row(children: [
                const Expanded(child: Divider(color: Color(0xFF1E3A5F))),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text(_isJapanese ? 'または' : 'or', style: const TextStyle(color: Color(0xFF3A5078), fontSize: 13))),
                const Expanded(child: Divider(color: Color(0xFF1E3A5F))),
              ]),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(() => _isJoining = !_isJoining),
                child: Container(
                  width: double.infinity, height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: _isJoining ? const Color(0xFF111827) : Colors.transparent,
                    border: Border.all(color: const Color(0xFF1E3A5F), width: 1.5),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.login_rounded, color: _isJoining ? const Color(0xFF00D4FF) : const Color(0xFF6680AA), size: 20),
                    const SizedBox(width: 8),
                    Text(_isJapanese ? 'コードで参加' : 'Join with Code',
                      style: TextStyle(color: _isJoining ? Colors.white : const Color(0xFF6680AA), fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
              if (_isJoining) ...[
                const SizedBox(height: 16),
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
                      hintText: _isJapanese ? 'ルームコード' : 'Room Code',
                      hintStyle: const TextStyle(color: Color(0xFF3A5078), letterSpacing: 1),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: (_isLoading || !_allConsented) ? null : _enterRoom,
                  child: Container(
                    width: double.infinity, height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: _isLoading
                          ? null
                          : const LinearGradient(
                              colors: [Color(0xFF00D4FF), Color(0xFF0057FF)],
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ),
                      color: _isLoading ? const Color(0xFF1E3A5F) : null,
                    ),
                    child: Center(
                      child: _isLoading
                          ? const SizedBox(width: 24, height: 24,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Text(_isJapanese ? '参加する' : 'Join',
                              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ],
            ],
            if (_createdRoomCode != null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1B2A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.4), width: 1.5),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF00D4FF), size: 36),
                  const SizedBox(height: 12),
                  Text(_isJapanese ? 'ルーム作成完了！' : 'Room Created!',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  Text(_isJapanese ? 'ルームコード' : 'Room Code',
                    style: const TextStyle(color: Color(0xFF6680AA), fontSize: 10)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111827),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF1E3A5F)),
                    ),
                    child: Text(_createdRoomCode!, style: const TextStyle(
                      color: Color(0xFF00D4FF), fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 6)),
                  ),
                  const SizedBox(height: 16),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    GestureDetector(
                      onTap: () => _copyRoomCode(_createdRoomCode!),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111827),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF1E3A5F)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.copy_rounded, color: Color(0xFF00D4FF), size: 16),
                          const SizedBox(width: 6),
                          Text(_isJapanese ? 'コピー' : 'Copy',
                            style: const TextStyle(color: Color(0xFF00D4FF), fontSize: 13)),
                        ]),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () => _shareRoomCode(_createdRoomCode!),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111827),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF1E3A5F)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.share_rounded, color: Color(0xFF00D4FF), size: 16),
                          const SizedBox(width: 6),
                          Text(_isJapanese ? '共有' : 'Share',
                            style: const TextStyle(color: Color(0xFF00D4FF), fontSize: 13)),
                        ]),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => setState(() => _createdRoomCode = null),
                    child: Text(_isJapanese ? '← 戻る' : '← Back',
                      style: const TextStyle(color: Color(0xFF3A5078))),
                  ),
                ]),
              ),
              const SizedBox(height: 20),
              _buildGradientButton(
                _isJapanese ? 'マップを開く' : 'Open Map',
                Icons.map_rounded,
                _startFromCreated),
            ],
            const SizedBox(height: 40),
          ]),
        ))),
      ]),
    );
  }
}
