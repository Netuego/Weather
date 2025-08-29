
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart' as geo;

import 'secrets.dart';
import 'characters.dart';

// ---------- Models

class DayForecast {
  final DateTime date;
  final double temp;
  final String condition;
  DayForecast(this.date, this.temp, this.condition);
  Map<String, dynamic> toJson() => {"date": date.toIso8601String(), "temp": temp, "condition": condition};
  static DayForecast fromJson(Map<String, dynamic> j) => DayForecast(DateTime.parse(j["date"]), (j["temp"] as num).toDouble(), j["condition"]);
}

class HourForecast {
  final DateTime time;
  final double temp;
  final String condition;
  HourForecast(this.time, this.temp, this.condition);
  Map<String, dynamic> toJson() => {"time": time.toIso8601String(), "temp": temp, "condition": condition};
  static HourForecast fromJson(Map<String, dynamic> j) => HourForecast(DateTime.parse(j["time"]), (j["temp"] as num).toDouble(), j["condition"]);
}

class WeatherBundle {
  final String city;
  final double temperature;
  final String condition;
  final List<DayForecast> nextDays;
  final List<HourForecast> hours;
  final double lat;
  final double lon;
  WeatherBundle({required this.city, required this.temperature, required this.condition, required this.nextDays, required this.hours, required this.lat, required this.lon});
  Map<String, dynamic> toJson() => {"city": city, "temperature": temperature, "condition": condition, "nextDays": nextDays.map((e) => e.toJson()).toList(), "hours": hours.map((e) => e.toJson()).toList(), "lat": lat, "lon": lon};
  static WeatherBundle fromJson(Map<String, dynamic> j) => WeatherBundle(city: j["city"], temperature: (j["temperature"] as num).toDouble(), condition: j["condition"], nextDays: (j["nextDays"] as List? ?? []).map((e) => DayForecast.fromJson(e)).toList(), hours: (j["hours"] as List? ?? []).map((e) => HourForecast.fromJson(e)).toList(), lat: (j["lat"] as num).toDouble(), lon: (j["lon"] as num).toDouble());
}

class GeoSuggestion {
  final String name;
  final String? state;
  final String country;
  final double lat;
  final double lon;
  GeoSuggestion({required this.name, required this.country, this.state, required this.lat, required this.lon});
  String displayName() => state == null || state!.isEmpty ? "$name, $country" : "$name, $state, $country";
}

// ---------- Repository

class WeatherRepository {
  final String apiKey;
  WeatherRepository(this.apiKey);

  Future<WeatherBundle> fetchForCity(String city) async {
    final curUrl = "https://api.openweathermap.org/data/2.5/weather?q=$city&units=metric&lang=ru&appid=$apiKey";
    final curRes = await http.get(Uri.parse(curUrl)).timeout(const Duration(seconds: 8));
    if (curRes.statusCode != 200) throw Exception("Current weather error ${curRes.statusCode}");
    final cur = json.decode(curRes.body);
    final tempNow = (cur["main"]["temp"] as num).toDouble();
    final condNow = cur["weather"][0]["main"] as String;
    final lat = (cur["coord"]["lat"] as num).toDouble();
    final lon = (cur["coord"]["lon"] as num).toDouble();
    final resolvedCity = (cur["name"] as String?) ?? city;

    // Try One Call 3.0 first, then 2.5, then fallback to 5-day
    List<HourForecast> hours = [];
    List<DayForecast> days7 = [];

    // 3.0
    try {
      final oc3 = "https://api.openweathermap.org/data/3.0/onecall?lat=$lat&lon=$lon&exclude=minutely,alerts&units=metric&lang=ru&appid=$apiKey";
      final r = await http.get(Uri.parse(oc3)).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final oc = json.decode(r.body);
        final now = DateTime.now();
        for (final h in (oc["hourly"] as List? ?? [])) {
          final dt = DateTime.fromMillisecondsSinceEpoch((h["dt"] as num).toInt() * 1000, isUtc: true).toLocal();
          if (dt.isAfter(now.subtract(const Duration(minutes: 1)))) {
            final t = (h["temp"] as num).toDouble();
            final c = (h["weather"]?[0]?["main"] as String?) ?? "Clouds";
            hours.add(HourForecast(dt, t, c));
          }
        }
        for (final d in (oc["daily"] as List? ?? [])) {
          final dt = DateTime.fromMillisecondsSinceEpoch((d["dt"] as num).toInt() * 1000, isUtc: true).toLocal();
          final t = ((d["temp"]?["day"]) as num?)?.toDouble() ?? ((d["temp"] is num) ? (d["temp"] as num).toDouble() : 0.0);
          final c = (d["weather"]?[0]?["main"] as String?) ?? "Clouds";
          days7.add(DayForecast(DateTime(dt.year, dt.month, dt.day), t, c));
        }
      }
    } catch (_) {}

    // 2.5
    if (days7.isEmpty || hours.isEmpty) {
      try {
        final oc2 = "https://api.openweathermap.org/data/2.5/onecall?lat=$lat&lon=$lon&exclude=minutely,alerts&units=metric&lang=ru&appid=$apiKey";
        final r = await http.get(Uri.parse(oc2)).timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) {
          final oc = json.decode(r.body);
          final now = DateTime.now();
          hours.clear();
          for (final h in (oc["hourly"] as List? ?? [])) {
            final dt = DateTime.fromMillisecondsSinceEpoch((h["dt"] as num).toInt() * 1000, isUtc: true).toLocal();
            if (dt.isAfter(now.subtract(const Duration(minutes: 1)))) {
              final t = (h["temp"] as num).toDouble();
              final c = (h["weather"]?[0]?["main"] as String?) ?? "Clouds";
              hours.add(HourForecast(dt, t, c));
            }
          }
          days7.clear();
          for (final d in (oc["daily"] as List? ?? [])) {
            final dt = DateTime.fromMillisecondsSinceEpoch((d["dt"] as num).toInt() * 1000, isUtc: true).toLocal();
            final t = ((d["temp"]?["day"]) as num?)?.toDouble() ?? ((d["temp"] is num) ? (d["temp"] as num).toDouble() : 0.0);
            final c = (d["weather"]?[0]?["main"] as String?) ?? "Clouds";
            days7.add(DayForecast(DateTime(dt.year, dt.month, dt.day), t, c));
          }
        }
      } catch (_) {}
    }

    // Fallback to 5-day if daily < 7 or hourly empty
    if (days7.length < 7 || hours.isEmpty) {
      final fcUrl = "https://api.openweathermap.org/data/2.5/forecast?q=$city&units=metric&lang=ru&appid=$apiKey";
      final fcRes = await http.get(Uri.parse(fcUrl)).timeout(const Duration(seconds: 10));
      if (fcRes.statusCode == 200) {
        final data = json.decode(fcRes.body);
        final List<dynamic> list = data["list"];
        final now = DateTime.now();
        if (hours.isEmpty) {
          for (final item in list) {
            final dt = DateTime.fromMillisecondsSinceEpoch(item["dt"] * 1000, isUtc: true).toLocal();
            if (dt.isAfter(now.subtract(const Duration(minutes: 1)))) {
              final t = (item["main"]["temp"] as num).toDouble();
              final c = item["weather"][0]["main"] as String;
              hours.add(HourForecast(dt, t, c));
            }
          }
          hours.sort((a, b) => a.time.compareTo(b.time));
        }
        if (days7.length < 7) {
          final Map<String, Map<String, dynamic>> daily = {};
          for (final item in list) {
            final dt = DateTime.fromMillisecondsSinceEpoch(item["dt"] * 1000, isUtc: true).toLocal();
            final key = DateFormat('yyyy-MM-dd').format(dt);
            final diff = (15 - dt.hour).abs();
            final t = (item["main"]["temp"] as num).toDouble();
            final c = item["weather"][0]["main"] as String;
            if (!daily.containsKey(key) || diff < (daily[key]!["diff"] as int)) {
              daily[key] = {"date": DateTime(dt.year, dt.month, dt.day), "temp": t, "cond": c, "diff": diff};
            }
          }
          final vals = daily.values.toList()..sort((a, b) => (a["date"] as DateTime).compareTo(b["date"] as DateTime));
          days7 = vals.take(7).map((m) => DayForecast(m["date"], (m["temp"] as num).toDouble(), m["cond"])).toList();
        }
      }
    }

    if (days7.length > 7) days7 = days7.take(7).toList();

    return WeatherBundle(city: resolvedCity, temperature: tempNow, condition: condNow, nextDays: days7, hours: hours, lat: lat, lon: lon);
  }

  Future<String?> reverseCity(double lat, double lon) async {
    final url = "https://api.openweathermap.org/geo/1.0/reverse?lat=$lat&lon=$lon&limit=1&appid=$apiKey";
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    final j = json.decode(res.body);
    if (j is List && j.isNotEmpty) {
      final name = j[0]["local_names"]?["ru"] ?? j[0]["name"];
      return name is String ? name : null;
    }
    return null;
  }

  Future<List<GeoSuggestion>> suggestCities(String query) async {
    if (query.trim().isEmpty) return [];
    final url = "https://api.openweathermap.org/geo/1.0/direct?q=$query&limit=5&appid=$apiKey";
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return [];
    final list = json.decode(res.body);
    if (list is! List) return [];
    return list.map<GeoSuggestion>((m) => GeoSuggestion(
      name: m["local_names"]?["ru"] ?? m["name"],
      state: m["state"],
      country: m["country"] ?? "",
      lat: (m["lat"] as num).toDouble(),
      lon: (m["lon"] as num).toDouble(),
    )).toList();
  }
}

// ---------- App

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  runApp(const WeatherFoxApp());
}

class WeatherFoxApp extends StatelessWidget {
  const WeatherFoxApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Weather Fox',
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3A6E86))),
      home: const WeatherScreen(defaultCity: "Москва"),
    );
  }
}

class WeatherScreen extends StatefulWidget {
  final String defaultCity;
  const WeatherScreen({super.key, required this.defaultCity});
  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  late final WeatherRepository repo;
  String city = "";
  WeatherBundle? bundle;
  bool loading = true;
  String? error;
  Set<String> _assetKeys = {};
  DateTime? _lastUpdated;

  String characterId = CharacterIds.fox;

  static const _prefCity = "last_city";
  static const _prefWeather = "last_weather_json";
  static const _prefUpdated = "last_updated_ms";
  static const _prefCharacterKey = 'selected_character_id';

  late final ScrollController _hourCtrl;
  int _selectedDayIndex = 0; // 0 = сегодня
  double _dragStartX = 0;
  bool _menuOpenedOnDrag = false;

  static const double _hourBoxHeight = 72.0;

  @override
  void initState() {
    super.initState();
    repo = WeatherRepository(openWeatherApiKey);
    city = widget.defaultCity;
    _hourCtrl = ScrollController(initialScrollOffset: 0);
    _loadAssetManifest();
    _loadSavedCharacter().then((id) { if (mounted) setState(() => characterId = id); });
    _loadFromPrefs().then((_) => _load());
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    super.dispose();
  }

  // ----- character persistence
  Future<void> _saveSelectedCharacter(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefCharacterKey, id);
  }
  Future<String> _loadSavedCharacter() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefCharacterKey) ?? CharacterIds.fox;
  }

  Future<void> _loadAssetManifest() async {
    final manifest = await rootBundle.loadString('AssetManifest.json');
    final map = json.decode(manifest) as Map<String, dynamic>;
    _assetKeys = map.keys.toSet();
    if (mounted) setState(() {});
  }

  Future<void> _saveToPrefs(WeatherBundle b) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefCity, city);
    await prefs.setString(_prefWeather, json.encode(b.toJson()));
    final ts = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt(_prefUpdated, ts);
    _lastUpdated = DateTime.fromMillisecondsSinceEpoch(ts);
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefWeather);
    final savedCity = prefs.getString(_prefCity);
    final ts = prefs.getInt(_prefUpdated);
    if (saved != null) {
      try {
        final b = WeatherBundle.fromJson(json.decode(saved));
        setState(() {
          bundle = b;
          city = savedCity ?? city;
          _lastUpdated = ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
          loading = false;
        });
      } catch (_) {}
    }
  }

  Future<void> _load() async {
    setState(() => {loading = true, error = null});
    try {
      final b = await repo.fetchForCity(city);
      setState(() {
        bundle = b;
        _selectedDayIndex = 0; // сброс на «сегодня»
      });
      await _saveToPrefs(b);
      if (_hourCtrl.hasClients) _hourCtrl.jumpTo(0);
    } catch (e) {
      if (bundle == null) await _loadFromPrefs();
      setState(() => error = e.toString());
    } finally {
      setState(() => loading = false);
    }
  }

  String appTimeOfDay(DateTime now) {
    final h = now.hour;
    if (h >= 5 && h < 11) return "morning";
    if (h >= 11 && h < 17) return "day";
    if (h >= 17 && h < 22) return "evening";
    return "night";
  }

  String conditionKey(String cond) {
    switch (cond) {
      case "Clear": return "clear";
      case "Clouds": return "clouds";
      case "Rain":
      case "Drizzle":
      case "Thunderstorm": return "rain";
      case "Snow": return "snow";
      default: return "fog";
    }
  }

  IconData _iconFor(String cond) {
    switch (cond) {
      case "Rain":
      case "Drizzle":
      case "Thunderstorm": return Icons.umbrella;
      case "Snow": return Icons.ac_unit;
      case "Clear": return Icons.wb_sunny;
      default: return Icons.cloud;
    }
  }

  String _seasonFour(DateTime now, {required bool north}) {
    int m = now.month;
    if (!north) m = ((m + 5) % 12) + 1;
    if (m == 12 || m <= 2) return "winter";
    if (m >= 3 && m <= 5) return "spring";
    if (m >= 6 && m <= 8) return "summer";
    return "autumn";
  }

  String _seasonTropics(List<DayForecast> days) {
    final rainy = days.where((d) {
      final c = d.condition;
      return c == "Rain" || c == "Drizzle" || c == "Thunderstorm";
    }).length;
    return rainy >= (days.length / 2).ceil() ? "wet" : "dry";
  }

  String seasonTag(double lat, DateTime now, List<DayForecast> days) {
    if (lat.abs() <= 23.5) {
      return _seasonTropics(days);
    } else {
      return _seasonFour(now, north: lat > 0);
    }
  }

  String sceneForSeasonal(String cond, DateTime now, WeatherBundle b) {
    final c = conditionKey(cond);
    final t = appTimeOfDay(now);
    final s = seasonTag(b.lat, now, b.nextDays);
    final candidates = [
      "assets/images/${characterId}_${c}_${s}_${t}.webp",
      "assets/images/${characterId}_${c}_${t}.webp",
      "assets/images/${characterId}_${c}_day.webp",
    ];
    for (final p in candidates) {
      if (_assetKeys.contains(p)) return p;
    }
    return "assets/images/${characterId}_clouds_day.webp";
  }

  String dayRu(DateTime t) => DateFormat('EEE', 'ru').format(t).replaceAll('.', '');
  String _updatedLabel() {
    if (_lastUpdated == null) return "";
    final diff = DateTime.now().difference(_lastUpdated!);
    final mins = diff.inMinutes;
    if (mins < 1) return "Обновлено только что";
    if (mins < 60) return "Обновлено ${mins} мин назад";
    final hours = diff.inHours;
    return "Обновлено ${hours} ч назад";
  }

  @override
  Widget build(BuildContext context) {
    final b = bundle;
    final now = DateTime.now();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: b == null ? const ColoredBox(color: Color(0xFF355F5B)) : Image.asset(sceneForSeasonal(b.condition, now, b), fit: BoxFit.cover)),
          Positioned.fill(child: Container(color: Colors.black.withOpacity(0.10))),

          SafeArea(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  if (loading && b == null) const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
                  if (b != null) ...[
                    // gesture zone for opening menu by swipe from left edge
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (details) {
                        _dragStartX = details.globalPosition.dx;
                        _menuOpenedOnDrag = false;
                      },
                      onHorizontalDragUpdate: (details) {
                        if (!_menuOpenedOnDrag && _dragStartX < 40 && details.delta.dx > 10) {
                          _menuOpenedOnDrag = true;
                          _openSettings();
                        }
                      },
                      onHorizontalDragEnd: (_) => _menuOpenedOnDrag = false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Move tiny button to the right side
                          Align(alignment: Alignment.centerRight, child: const _TinyThreeDots()),
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      b.city,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Colors.white),
                                    ),
                                    const SizedBox(height: 4),
                                    if (_updatedLabel().isNotEmpty) Text(_updatedLabel(), style: const TextStyle(color: Colors.white70)),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text("${b.temperature.round()}°", style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800, color: Colors.white, height: 1.0)),
                                  const SizedBox(height: 6),
                                  Text(_capitalize(_condRu(b.condition)), style: const TextStyle(color: Colors.white70)),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),

                    // hourly or day summary
                    SizedBox(
                      height: _hourBoxHeight,
                      child: LayoutBuilder(builder: (c, cc) {
                        final isToday = _selectedDayIndex == 0;
                        if (isToday) {
                          final count = b!.hours.length > 12 ? 12 : b!.hours.length;
                          const double _hPad = 12.0;
                          final double _innerW = cc.maxWidth - (_hPad * 2);
                          final double _slotW = _innerW / 5;
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              decoration: BoxDecoration(color: Colors.white.withOpacity(0.78)),
                              child: ListView.builder(
                                controller: _hourCtrl,
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                padding: const EdgeInsets.symmetric(horizontal: _hPad),
                                itemCount: count,
                                itemBuilder: (context, index) {
                                  final h = b!.hours[index];
                                  return SizedBox(
                                    width: _slotW,
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(DateFormat('HH:mm', 'ru').format(h.time), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, height: 1.0), overflow: TextOverflow.fade, softWrap: false),
                                        const SizedBox(height: 2),
                                        Icon(_iconFor(h.condition), size: 18),
                                        const SizedBox(height: 2),
                                        Text("${h.temp.round()}°", style: const TextStyle(fontSize: 11, height: 1.0), overflow: TextOverflow.fade, softWrap: false),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          );
                        } else {
                          final d = b!.nextDays[_selectedDayIndex];
                          return Container(
                            decoration: BoxDecoration(color: Colors.white.withOpacity(0.78), borderRadius: BorderRadius.circular(16)),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Icon(_iconFor(d.condition), size: 24),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    "${_capitalize(dayRu(d.date))}, ${DateFormat('d MMM', 'ru').format(d.date)} • ${d.temp.round()}° • ${_condRu(d.condition)}",
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                      }),
                    ),

                    const SizedBox(height: 8),

                    // 7-day forecast
                    LayoutBuilder(builder: (c, cc) {
                      final days = b!.nextDays;
                      final int count = days.length >= 7 ? 7 : days.length;
                      final cellW = cc.maxWidth / 7;
                      return Container(
                        height: 68,
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.78), borderRadius: BorderRadius.circular(16)),
                        child: Row(
                          children: List.generate(7, (index) {
                            final bool hasData = index < count;
                            final d = hasData ? days[index] : null;
                            final isSel = index == _selectedDayIndex;
                            final String title;
                            if (index == 0) title = "Сегодня";
                            else if (hasData) title = _capitalize(dayRu(d!.date));
                            else title = "—";
                            return SizedBox(
                              width: cellW,
                              child: InkWell(enableFeedback: false,
                                onTap: hasData ? () => setState(() => _selectedDayIndex = index) : null,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: (isSel && index != 0) ? Colors.black.withOpacity(0.06) : Colors.transparent, // подсветка, кроме "Сегодня"
                                    border: Border(
                                      right: index < 6 ? BorderSide(color: Colors.black.withOpacity(0.12)) : BorderSide.none,
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        title,
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: isSel ? Colors.black : Colors.black87),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      if (hasData) ...[
                                        Icon(_iconFor(d!.condition), size: 16),
                                        const SizedBox(height: 4),
                                        Text("${d.temp.round()}°", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                                      ] else ...[
                                        const SizedBox(height: 16),
                                        const SizedBox(height: 4),
                                        const Text(" ", style: TextStyle(fontSize: 11)),
                                      ]
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      );
                    }),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // helpers
  String _capitalize(String s) => s.isEmpty ? s : (s[0].toUpperCase() + s.substring(1));
  String _condRu(String c) {
    switch (c) {
      case "Clear": return "ясно";
      case "Clouds": return "облачно";
      case "Rain": return "дождь";
      case "Drizzle": return "морось";
      case "Thunderstorm": return "гроза";
      case "Snow": return "снег";
      default: return c.toLowerCase();
    }
  }

  // ---- SETTINGS SHEET (with characters + city buttons + autocomplete, loader before close)
  Future<void> _openSettings() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black.withOpacity(0.20),
      barrierColor: Colors.black54,
      builder: (bottomCtx) {
        bool busy = false;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final ids = _availableCharacterIds();
            return SafeArea(
              child: Stack(
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: busy ? null : () async {
                                    setSheetState(() { busy = true; });
                                    final ok = await _detectCityByGPS();
                                    setSheetState(() { busy = false; });
                                    if (ok && Navigator.of(bottomCtx).canPop()) Navigator.of(bottomCtx).pop();
                                  },
                                  style: OutlinedButton.styleFrom(enableFeedback: false, foregroundColor: Colors.white, side: const BorderSide(color: Colors.white70)),
                                  child: const Text("Определить город"),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: busy ? null : () => _openCitySearch(bottomCtx),
                                  style: OutlinedButton.styleFrom(enableFeedback: false, foregroundColor: Colors.white, side: const BorderSide(color: Colors.white70)),
                                  child: const Text("Выбрать вручную"),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Container(height: 1, color: Colors.white.withOpacity(0.4)),
                          const SizedBox(height: 12),
                          const Text("Персонажи", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 12),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: 1,
                            ),
                            itemCount: ids.length,
                            itemBuilder: (context, index) {
                              final id = ids[index];
                              final path = _avatarFor(id);
                              final isSelected = id == characterId;
                              return GestureDetector(
                                onTap: busy ? null : () async {
                                  setSheetState(() { busy = true; });
                                  setState(() { characterId = id; });
                                  await _saveSelectedCharacter(id);
                                  setSheetState(() { busy = false; });
                                  if (Navigator.of(bottomCtx).canPop()) Navigator.of(bottomCtx).pop();
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Image.asset(path, fit: BoxFit.cover),
                                      if (isSelected) Container(color: Colors.black.withOpacity(0.25), child: const Center(child: Icon(Icons.check_circle, color: Colors.white, size: 28))),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (busy)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black26,
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openCitySearch(BuildContext parentBottomCtx) async {
    final selected = await showModalBottomSheet<GeoSuggestion>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black.withOpacity(0.40), // менее прозрачное
      barrierColor: Colors.black54,
      builder: (ctx) {
        return _CitySearchSheet(repo: repo);
      },
    );
    if (selected != null) {
      // покажем лоадер, пока идёт загрузка города, и закроем меню после
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      setState(() { city = selected.displayName(); });
      await _load();
      if (Navigator.canPop(context)) Navigator.pop(context); // закрыть лоадер
      if (Navigator.of(parentBottomCtx).canPop()) Navigator.of(parentBottomCtx).pop();
    }
  }

  // --- characters helpers
  String _avatarFor(String id) {
    final prefixes = ["${id}_clear_day", "${id}_clouds_day", "${id}_rain_day", "${id}_clouds_morning"];
    for (final key in _assetKeys) {
      for (final p in prefixes) {
        if (key.startsWith("assets/images/") && key.contains(p)) return key;
      }
    }
    for (final key in _assetKeys) {
      if (key.startsWith("assets/images/$id")) return key;
    }
    return "assets/images/${id}_clouds_day.webp";
  }

  List<String> _availableCharacterIds() {
    final candidates = <String>{CharacterIds.fox, "raccoon", "spider", "robot"};
    bool hasAssets(String id) => _assetKeys.any((k) => k.startsWith("assets/images/$id"));
    final result = candidates.where(hasAssets).toList();
    if (result.isEmpty) return [CharacterIds.fox];
    return result;
  }

  Future<bool> _detectCityByGPS() async {
    try {
      bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Включите геолокацию")));
        return false;
      }
      geo.LocationPermission permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
      }
      if (permission == geo.LocationPermission.deniedForever || permission == geo.LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Нет разрешения на геолокацию")));
        return false;
      }
      final pos = await geo.Geolocator.getCurrentPosition(desiredAccuracy: geo.LocationAccuracy.low);
      final name = await repo.reverseCity(pos.latitude, pos.longitude);
      if (name != null && name.isNotEmpty) {
        setState(() { city = name; });
        await _load();
        return true;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Город не найден по координатам")));
        return false;
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ошибка определения местоположения")));
      return false;
    }
  }
}

// ------- Tiny three-dots widget (now right-aligned in UI)
class _TinyThreeDots extends StatelessWidget {
  const _TinyThreeDots({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(enableFeedback: false,
        onTap: () {
          final state = context.findAncestorStateOfType<_WeatherScreenState>();
          state?._openSettings();
        },
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 20,
          height: 16,
          child: CustomPaint(painter: _DotsPainter()),
        ),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.95)
      ..style = PaintingStyle.fill;
    final r = size.height * 0.10; // очень маленькие точки
    final cy = size.height * 0.5;
    final gap = size.width * 0.18;
    final cx = size.width * 0.5;
    canvas.drawCircle(Offset(cx - gap, cy), r, paint);
    canvas.drawCircle(Offset(cx, cy), r, paint);
    canvas.drawCircle(Offset(cx + gap, cy), r, paint);
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// --------- City search sheet with typeahead ----------
class _CitySearchSheet extends StatefulWidget {
  final WeatherRepository repo;
  const _CitySearchSheet({required this.repo});

  @override
  State<_CitySearchSheet> createState() => _CitySearchSheetState();
}

class _CitySearchSheetState extends State<_CitySearchSheet> {
  final TextEditingController _ctrl = TextEditingController();
  Timer? _debounce;
  List<GeoSuggestion> _items = [];
  bool _loading = false;
  String _error = "";

  void _onChanged(String q) {
    _error = "";
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      setState(() { _loading = true; });
      try {
        final list = await widget.repo.suggestCities(q);
        setState(() { _items = list; });
      } catch (_) {
        setState(() { _items = []; });
      } finally {
        if (mounted) setState(() { _loading = false; });
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.only(bottom: bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _ctrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: "Введите город...",
                  hintStyle: TextStyle(color: Colors.white70),
                  prefixIcon: Icon(Icons.search, color: Colors.white70),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white54)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white)),
                ),
                onChanged: _onChanged,
                onSubmitted: (value) {
                  if (_items.isNotEmpty) {
                    Navigator.pop(context, _items.first);
                  } else {
                    setState(() { _error = "Город не найден"; });
                  }
                },
              ),
              const SizedBox(height: 12),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              if (_error.isNotEmpty) Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error, style: const TextStyle(color: Colors.redAccent)),
              ),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: _items.isEmpty && !_loading
                      ? const Center(child: Text("Начните вводить название города", style: TextStyle(color: Colors.white70)))
                      : ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white24, height: 1),
                    itemBuilder: (context, index) {
                      final s = _items[index];
                      return ListTile(enableFeedback: false,
                        onTap: () => Navigator.pop(context, s),
                        title: Text(s.name, style: const TextStyle(color: Colors.white)),
                        subtitle: Text(s.state == null || s.state!.isEmpty ? s.country : "${s.state}, ${s.country}", style: const TextStyle(color: Colors.white70)),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
