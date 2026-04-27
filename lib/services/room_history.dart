import 'package:shared_preferences/shared_preferences.dart';

/// 直近に入室したルーム情報を端末に保存・読み込み・削除するヘルパー。
/// アプリkill後の復帰ダイアログ用。
class RoomHistory {
  static const _kRoomCode = 'room_history_code';
  static const _kNickname = 'room_history_nickname';
  static const _kVehicle = 'room_history_vehicle_type';
  static const _kExpiresAt = 'room_history_expires_at';

  /// ルーム入室成功時に呼び出して保存（既存があれば上書き）
  static Future<void> save({
    required String roomCode,
    required String nickname,
    required String vehicleType,
    required int expiresAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRoomCode, roomCode);
    await prefs.setString(_kNickname, nickname);
    await prefs.setString(_kVehicle, vehicleType);
    await prefs.setInt(_kExpiresAt, expiresAt);
  }

  /// 保存済みルーム情報を読み込み。情報なしまたは期限切れなら null（同時に自動削除）。
  static Future<RoomHistoryEntry?> loadIfValid() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_kRoomCode);
    final nickname = prefs.getString(_kNickname);
    final vehicle = prefs.getString(_kVehicle);
    final expiresAt = prefs.getInt(_kExpiresAt);
    if (code == null || nickname == null || vehicle == null || expiresAt == null) {
      return null;
    }
    if (expiresAt <= DateTime.now().millisecondsSinceEpoch) {
      await clear();
      return null;
    }
    return RoomHistoryEntry(
      roomCode: code,
      nickname: nickname,
      vehicleType: vehicle,
      expiresAt: expiresAt,
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRoomCode);
    await prefs.remove(_kNickname);
    await prefs.remove(_kVehicle);
    await prefs.remove(_kExpiresAt);
  }
}

class RoomHistoryEntry {
  final String roomCode;
  final String nickname;
  final String vehicleType;
  final int expiresAt;
  const RoomHistoryEntry({
    required this.roomCode,
    required this.nickname,
    required this.vehicleType,
    required this.expiresAt,
  });
}
