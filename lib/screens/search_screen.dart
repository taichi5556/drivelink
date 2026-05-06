import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 検索画面の戻り値。`Navigator.pop(SearchResultAction(...))` で main_screen 側へ
/// 確定内容を返す。type は 'destination' / 'reset' / （将来 'waypoint'）。
class SearchResultAction {
  final String type;
  final String? name;
  final double? lat;
  final double? lng;
  const SearchResultAction({
    required this.type,
    this.name,
    this.lat,
    this.lng,
  });
}

/// Phase M-1a: 全画面の目的地検索 UI。
/// - 検索結果ゼロ時: 履歴 + 「現在地を目的地」ボタン
/// - 検索結果あり: 上部マップ（候補ピン）+ 下部リストの分割表示
/// 旧 AlertDialog 版（main_screen の _setPersonalDestination 内）の挙動を保全:
/// 300ms デバウンス / 2文字未満は API 呼ばない / ロケーションバイアス / 20件取得。
class SearchScreen extends StatefulWidget {
  final LatLng currentPosition;
  final bool hasGpsFix;
  final List<Map<String, dynamic>> history;
  final bool hasActiveDestination;
  // M-1c: 経由地ボタンの活性条件（既存ルートあり）
  final bool hasActiveRoute;
  final String placesApiKey;

  const SearchScreen({
    super.key,
    required this.currentPosition,
    required this.hasGpsFix,
    required this.history,
    required this.hasActiveDestination,
    required this.hasActiveRoute,
    required this.placesApiKey,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounceTimer;
  List<Map<String, dynamic>> _results = [];
  bool _isSearching = false;
  GoogleMapController? _mapController;
  // 検索リクエストの世代カウンタ。HTTP 完了時に最新世代でなければ破棄する
  // ことで、デバウンス＋ネットワーク遅延に伴う stale 結果の上書きを防ぐ。
  int _searchSeq = 0;
  // M-1b: ピン ↔ リスト連動。null = 未選択
  int? _selectedIdx;
  final ScrollController _listScrollCtrl = ScrollController();
  // animateTo(idx * extent) の精度確保のため固定高さに揃える
  static const double _listItemExtent = 64.0;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchCtrl.dispose();
    _listScrollCtrl.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  void _onQueryChanged(String val) {
    _debounceTimer?.cancel();
    if (val.length < 2) {
      setState(() => _results = []);
      return;
    }
    _debounceTimer = Timer(const Duration(milliseconds: 300), _runSearch);
  }

  Future<void> _runSearch() async {
    if (!mounted) return;
    final mySeq = ++_searchSeq;
    setState(() => _isSearching = true);
    try {
      final encoded = Uri.encodeComponent(_searchCtrl.text);
      // radius=10km は「優先範囲」（絶対制限ではない）。カテゴリ検索（ガソリン等）は
      // 近場で絞り、固有名詞検索（スカイツリー等）は Google が範囲外の正解も返す。
      final biasParam = widget.hasGpsFix
          ? '&location=${widget.currentPosition.latitude},${widget.currentPosition.longitude}&radius=10000'
          : '';
      final url = 'https://maps.googleapis.com/maps/api/place/textsearch/json'
          '?query=$encoded&language=ja&region=jp$biasParam&key=${widget.placesApiKey}';
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        final body = await response.transform(const Utf8Decoder()).join();
        final data = jsonDecode(body);
        if (!mounted || mySeq != _searchSeq) return; // stale 検索は破棄
        if (data['status'] == 'OK') {
          final results = (data['results'] as List).take(20).map((r) {
            final loc = r['geometry']['location'];
            return <String, dynamic>{
              'name': r['name'] as String,
              'address': r['formatted_address'] as String? ?? '',
              'lat': (loc['lat'] as num).toDouble(),
              'lng': (loc['lng'] as num).toDouble(),
            };
          }).toList();
          setState(() {
            _results = List<Map<String, dynamic>>.from(results);
            _isSearching = false;
            _selectedIdx = null;  // 新検索ごとに選択リセット
          });
          _fitMapToResults();
        } else {
          setState(() {
            _results = [];
            _isSearching = false;
          });
        }
      } finally {
        client.close();
      }
    } catch (_) {
      if (!mounted || mySeq != _searchSeq) return;
      setState(() {
        _results = [];
        _isSearching = false;
      });
    }
  }

  /// 結果到着後の地図表示。
  /// - GPS fix あり + 全結果が自分位置 20km 以内 → zoom 14 で自分位置中心
  /// - それ以外（GPS fix 無し / 遠方の結果あり）→ 自分位置 + 全候補の bounds fit
  void _fitMapToResults() {
    if (_mapController == null || _results.isEmpty) return;

    if (widget.hasGpsFix) {
      const double nearThresholdMeters = 20000;
      final allNear = _results.every((r) {
        final d = _metersTo(
          widget.currentPosition,
          LatLng(r['lat'] as double, r['lng'] as double),
        );
        return d <= nearThresholdMeters;
      });
      if (allNear) {
        _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(widget.currentPosition, 12),
        );
        return;
      }
    }
    _animateBoundsFit();
  }

  /// 自分位置 + 全候補を含む LatLngBounds にフィット（広域表示）。
  void _animateBoundsFit() {
    final pts = <LatLng>[
      widget.currentPosition,
      ..._results.map((r) => LatLng(r['lat'] as double, r['lng'] as double)),
    ];
    double minLat = pts.first.latitude;
    double maxLat = pts.first.latitude;
    double minLng = pts.first.longitude;
    double maxLng = pts.first.longitude;
    for (final p in pts) {
      minLat = min(minLat, p.latitude);
      maxLat = max(maxLat, p.latitude);
      minLng = min(minLng, p.longitude);
      maxLng = max(maxLng, p.longitude);
    }
    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
  }

  /// 自分位置からの直線距離（メートル）。Haversine 簡略版（短距離向け平面近似）。
  double _metersTo(LatLng a, LatLng b) {
    const r = 6371000.0;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return 2 * r * atan2(sqrt(h), sqrt(1 - h));
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)}m';
    return '${(meters / 1000).toStringAsFixed(1)}km';
  }

  /// M-1b: リスト項目タップ → 該当ピン強調 + 地図カメラ移動 + InfoWindow 表示
  void _selectFromList(int idx) {
    setState(() => _selectedIdx = idx);
    final r = _results[idx];
    final pos = LatLng(r['lat'] as double, r['lng'] as double);
    _mapController?.animateCamera(CameraUpdate.newLatLng(pos));
    _mapController?.showMarkerInfoWindow(MarkerId('r$idx'));
  }

  /// M-1b: ピンタップ → 該当リスト項目強調 + リストスクロール
  void _selectFromMap(int idx) {
    setState(() => _selectedIdx = idx);
    if (_listScrollCtrl.hasClients) {
      _listScrollCtrl.animateTo(
        idx * _listItemExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// M-1c: 詳細ダイアログ。「目的地として設定」「経由地として追加」の2択。
  /// 経由地ボタンは hasActiveRoute=true 時のみ活性（M-1c は SnackBar 仮、M-1d で実装）。
  Future<void> _showDetailDialog(int idx) async {
    final r = _results[idx];
    final name = r['name'] as String;
    final address = r['address'] as String;
    final lat = r['lat'] as double;
    final lng = r['lng'] as double;
    final dist = _metersTo(widget.currentPosition, LatLng(lat, lng));

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        titlePadding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.grey, size: 22),
              onPressed: () => Navigator.pop(dialogCtx),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.place, color: Color(0xFF00D4FF), size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  address,
                  style: const TextStyle(color: Color(0xFFAAB8C8), fontSize: 12),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.straighten, color: Color(0xFF6680AA), size: 14),
              const SizedBox(width: 6),
              Text(
                '距離 ${_formatDistance(dist)}',
                style: const TextStyle(color: Color(0xFF6680AA), fontSize: 12),
              ),
            ]),
            const SizedBox(height: 16),
            // 目的地として設定（常時活性）
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.flag, size: 18),
                label: const Text('目的地として設定'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00D4FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  Navigator.pop(dialogCtx);
                  Navigator.pop(
                    context,
                    SearchResultAction(
                      type: 'destination',
                      name: name,
                      lat: lat,
                      lng: lng,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            // 経由地として追加（M-1c: hasActiveRoute=true 時のみ活性、押下で SnackBar 仮）
            SizedBox(
              width: double.infinity,
              child: Tooltip(
                message: widget.hasActiveRoute ? '' : 'ルート設定後に使用可能',
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                  label: const Text('経由地として追加'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: widget.hasActiveRoute
                        ? const Color(0xFFFF8A50)
                        : Colors.grey.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: widget.hasActiveRoute
                      ? () {
                          Navigator.pop(dialogCtx);
                          Navigator.pop(
                            context,
                            SearchResultAction(
                              type: 'waypoint',
                              name: name,
                              lat: lat,
                              lng: lng,
                            ),
                          );
                        }
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectDestination(String name, double lat, double lng) {
    Navigator.pop(
      context,
      SearchResultAction(type: 'destination', name: name, lat: lat, lng: lng),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasResults = _results.isNotEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B2A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('🔍 目的地を検索', style: TextStyle(fontSize: 16)),
        actions: [
          if (widget.hasActiveDestination)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              tooltip: '目的地をリセット',
              onPressed: () => Navigator.pop(
                context,
                const SearchResultAction(type: 'reset'),
              ),
            ),
        ],
      ),
      // body 内の空き領域 / リスト下地タップでキーボードを閉じる。
      // TextField や ListTile.onTap など子の gesture が消費するタップは素通りするので
      // 検索ボックスを再タップすればキーボードは復活する。
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            _buildSearchField(),
            // IndexedStack で結果ビュー / 空ビューの両方を常時マウント。GoogleMap を
            // unmount→remount する経路を排除し、_mapController が常に有効になる
            // （連続別ワード検索でピンが反映されないバグの根本対処）。
            Expanded(
              child: IndexedStack(
                index: hasResults ? 0 : 1,
                children: [
                  Column(
                    children: [
                      Expanded(flex: 3, child: _buildMap()),
                      Expanded(flex: 2, child: _buildResultsList()),
                    ],
                  ),
                  _buildEmptyStateBody(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(color: Colors.white),
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: '場所・お店・住所を検索...',
          hintStyle: const TextStyle(color: Colors.grey),
          prefixIcon: const Icon(Icons.search, color: Color(0xFF00D4FF)),
          suffixIcon: _isSearching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF00D4FF)),
                  ),
                )
              : null,
          enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.grey)),
          focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF00D4FF))),
        ),
        onChanged: _onQueryChanged,
        // キーボードの「検索」ボタン押下時に閉じる（ユーザーの「入力完了」意思）
        onSubmitted: (_) => FocusScope.of(context).unfocus(),
      ),
    );
  }

  Widget _buildMap() {
    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('me'),
        position: widget.currentPosition,
        icon:
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: '現在地'),
      ),
      for (int i = 0; i < _results.length; i++)
        Marker(
          markerId: MarkerId('r$i'),
          position: LatLng(
              _results[i]['lat'] as double, _results[i]['lng'] as double),
          // 選択中のみ hueRose で強調。通常は Google マーカー既定の hueRed
          icon: BitmapDescriptor.defaultMarkerWithHue(
            i == _selectedIdx
                ? BitmapDescriptor.hueRose
                : BitmapDescriptor.hueRed,
          ),
          onTap: () => _selectFromMap(i),
          infoWindow: InfoWindow(
            title: _results[i]['name'] as String,
            snippet: _results[i]['address'] as String?,
          ),
        ),
    };
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: widget.currentPosition,
        zoom: 14,
      ),
      onMapCreated: (c) {
        _mapController = c;
        // 結果が既にある場合（理論上ここでは無いが念のため）即フィット
        if (_results.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _fitMapToResults());
        }
      },
      // 地図タップでキーボードを閉じる（GoogleMap は独自にタッチを消費するため
      // 親 GestureDetector では拾えない）
      onTap: (_) => FocusScope.of(context).unfocus(),
      markers: markers,
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      compassEnabled: false,
    );
  }

  Widget _buildResultsList() {
    return Container(
      color: const Color(0xFF0A1628),
      // animateTo(idx * extent) で正確にスクロールするため itemExtent 固定。
      // セパレータは各 tile の bottom border に統合。
      child: ListView.builder(
        controller: _listScrollCtrl,
        padding: EdgeInsets.zero,
        itemCount: _results.length,
        itemExtent: _listItemExtent,
        itemBuilder: (ctx, i) {
          final r = _results[i];
          final lat = r['lat'] as double;
          final lng = r['lng'] as double;
          final dist = _metersTo(widget.currentPosition, LatLng(lat, lng));
          final isSelected = i == _selectedIdx;
          return Container(
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF1A2A40) : null,
              border: const Border(
                bottom: BorderSide(color: Color(0xFF1E3A5F), width: 0.5),
              ),
            ),
            child: ListTile(
              dense: true,
              leading: Icon(
                Icons.place,
                color: isSelected
                    ? const Color(0xFFFF6B9D)   // hueRose 系
                    : const Color(0xFF00D4FF),
              ),
              title: Text(r['name'] as String,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: Text(r['address'] as String,
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              trailing: Text(
                _formatDistance(dist),
                style:
                    const TextStyle(color: Color(0xFF6680AA), fontSize: 11),
              ),
              // M-1c: 強調しつつ詳細ダイアログを表示。ダイアログ閉じても選択状態は維持
              onTap: () {
                _selectFromList(i);
                _showDetailDialog(i);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyStateBody() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        if (widget.history.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(children: [
              Icon(Icons.history, color: Colors.grey, size: 14),
              SizedBox(width: 4),
              Text('最近の目的地',
                  style: TextStyle(color: Colors.grey, fontSize: 11)),
            ]),
          ),
          ...widget.history.map((h) => ListTile(
                dense: true,
                leading:
                    const Icon(Icons.history, color: Color(0xFF6680AA), size: 18),
                title: Text(h['name'] as String,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13)),
                onTap: () => _selectDestination(
                    h['name'] as String,
                    h['lat'] as double,
                    h['lng'] as double),
              )),
          const Divider(color: Color(0xFF1E3A5F), height: 16),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextButton.icon(
            icon: const Icon(Icons.my_location, color: Color(0xFF00D4FF), size: 18),
            label: const Text('現在地を目的地に設定',
                style: TextStyle(color: Color(0xFF00D4FF))),
            onPressed: () => _selectDestination(
              '現在地',
              widget.currentPosition.latitude,
              widget.currentPosition.longitude,
            ),
          ),
        ),
      ],
    );
  }
}
