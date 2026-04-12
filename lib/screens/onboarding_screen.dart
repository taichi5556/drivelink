import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  static const _pages = [
    _OnboardingPage(
      icon: Icons.person_outline_rounded,
      iconColor: Color(0xFF00D4FF),
      title: 'ニックネームを設定',
      description: 'ニックネームと車両タイプを選んで\nルームを作成しよう',
      tag: 'ルームを作る場合 ①',
    ),
    _OnboardingPage(
      icon: Icons.qr_code_rounded,
      iconColor: Color(0xFF00D4FF),
      title: 'コードを仲間に共有',
      description: 'ルームコードをQRやコピーで\n仲間に共有しよう',
      tag: 'ルームを作る場合 ②',
    ),
    _OnboardingPage(
      icon: Icons.map_rounded,
      iconColor: Color(0xFF00D4FF),
      title: 'マップで全員を確認',
      description: 'マップで全員の位置を\nリアルタイムに確認できる',
      tag: 'ルームを作る場合 ③',
    ),
    _OnboardingPage(
      icon: Icons.login_rounded,
      iconColor: Color(0xFFFF6B35),
      title: 'コードを入力して参加',
      description: 'コードを入力またはQRを読み取って\nルームに参加しよう',
      tag: 'ルームに参加する場合 ④',
    ),
    _OnboardingPage(
      icon: Icons.directions_car_rounded,
      iconColor: Color(0xFFFF6B35),
      title: '仲間と一緒に走ろう',
      description: 'マップで仲間の位置を確認しながら\n最高のドライブを楽しもう！',
      tag: 'ルームに参加する場合 ⑤',
    ),
    _OnboardingPage(
      icon: Icons.rocket_launch_rounded,
      iconColor: Color(0xFF00D4FF),
      title: 'さあ始めよう！',
      description: 'TouriLinkで最高のドライブを',
      tag: '',
      isLast: true,
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  void _next() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    } else {
      _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _currentPage == _pages.length - 1;

    return Scaffold(
      backgroundColor: const Color(0xFF070D1A),
      body: Stack(children: [
        // 背景装飾
        Positioned(
          top: -80, left: -60,
          child: Container(
            width: 280, height: 280,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF00D4FF).withValues(alpha: 0.07),
            ),
          ),
        ),
        Positioned(
          bottom: -60, right: -40,
          child: Container(
            width: 220, height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0057FF).withValues(alpha: 0.08),
            ),
          ),
        ),

        SafeArea(
          child: Column(children: [
            // スキップボタン
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: isLast
                    ? const SizedBox(height: 36)
                    : TextButton(
                        onPressed: _finish,
                        child: const Text(
                          'スキップ',
                          style: TextStyle(color: Color(0xFF3A5078), fontSize: 13),
                        ),
                      ),
              ),
            ),

            // ページ本体
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemBuilder: (_, i) => _PageContent(page: _pages[i]),
              ),
            ),

            // ドットインジケーター
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pages.length, (i) {
                  final active = i == _currentPage;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 20 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: active
                          ? const Color(0xFF00D4FF)
                          : const Color(0xFF1E3A5F),
                    ),
                  );
                }),
              ),
            ),

            // 次へ / 始めようボタン
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: GestureDetector(
                onTap: _next,
                child: Container(
                  width: double.infinity,
                  height: 52,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF00D4FF), Color(0xFF0057FF)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00D4FF).withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      isLast ? 'さあ始めよう！' : '次へ',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ─── 1ページ分のデータ ───────────────────────────────────────
class _OnboardingPage {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final String tag;
  final bool isLast;

  const _OnboardingPage({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.tag,
    this.isLast = false,
  });
}

// ─── ページのUI ─────────────────────────────────────────────
class _PageContent extends StatelessWidget {
  final _OnboardingPage page;
  const _PageContent({required this.page});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // タグ（ステップ表示）
          if (page.tag.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                color: page.iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: page.iconColor.withValues(alpha: 0.3)),
              ),
              child: Text(
                page.tag,
                style: TextStyle(
                  color: page.iconColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(height: 28),
          ] else
            const SizedBox(height: 48),

          // アイコン
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  page.iconColor.withValues(alpha: 0.2),
                  page.iconColor.withValues(alpha: 0.05),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(
                color: page.iconColor.withValues(alpha: 0.3),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: page.iconColor.withValues(alpha: 0.2),
                  blurRadius: 30,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Icon(page.icon, color: page.iconColor, size: 46),
          ),

          const SizedBox(height: 36),

          // タイトル
          Text(
            page.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              height: 1.3,
            ),
          ),

          const SizedBox(height: 16),

          // 説明
          Text(
            page.description,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF6680AA),
              fontSize: 14,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }
}
