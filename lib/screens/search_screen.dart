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
  final String placesApiKey;

  const SearchScreen({
    super.key,
    required this.currentPosition,
    required this.hasGpsFix,
    required this.history,
    required this.hasActiveDestination,
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

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchCtrl.dispose();
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
    setState(() => _isSearching = true);
    try {
      final encoded = Uri.encodeComponent(_searchCtrl.text);
      final biasParam = widget.hasGpsFix
          ? '&location=${widget.currentPosition.latitude},${widget.currentPosition.longitude}&radius=50000'
          : '';
      final url = 'https://maps.googleapis.com/maps/api/place/textsearch/json'
          '?query=$encoded&language=ja&region=jp$biasParam&key=${widget.placesApiKey}';
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        final body = await response.transform(const Utf8Decoder()).join();
        final data = jsonDecode(body);
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
          if (!mounted) return;
          setState(() {
            _results = List<Map<String, dynamic>>.from(results);
            _isSearching = false;
          });
          _fitMapToResults();
        } else {
          if (!mounted) return;
          setState(() {
            _results = [];
            _isSearching = false;
          });
        }
      } finally {
        client.close();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _isSearching = false;
      });
    }
  }

  /// 結果到着後、自分位置 + 全候補を含む LatLngBounds に合わせてカメラ移動。
  void _fitMapToResults() {
    if (_mapController == null || _results.isEmpty) return;
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
      body: Column(
        children: [
          _buildSearchField(),
          if (hasResults)
            Expanded(
              child: Column(
                children: [
                  Expanded(flex: 3, child: _buildMap()),
                  Expanded(flex: 2, child: _buildResultsList()),
                ],
              ),
            )
          else
            Expanded(child: _buildEmptyStateBody()),
        ],
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
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _results.length,
        separatorBuilder: (_, _) => const Divider(
          color: Color(0xFF1E3A5F),
          height: 1,
          thickness: 0.5,
        ),
        itemBuilder: (ctx, i) {
          final r = _results[i];
          final lat = r['lat'] as double;
          final lng = r['lng'] as double;
          final dist = _metersTo(widget.currentPosition, LatLng(lat, lng));
          return ListTile(
            dense: true,
            leading: const Icon(Icons.place, color: Color(0xFF00D4FF)),
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
            onTap: () => _selectDestination(r['name'] as String, lat, lng),
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
