
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, SystemChrome, SystemUiMode, SystemUiOverlayStyle;
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secrets.dart';
import 'characters.dart';

// ---- Disable overscroll stretch globally ----
class NoStretchScrollBehavior extends MaterialScrollBehavior {
  const NoStretchScrollBehavior();
  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}

// ===================== DATA =====================
class DayForecast {
  final DateTime date;
  final double temp;
  final String condition;
  final double? minT;
  final double? maxT;
  final double? pop; // 0..1
  DayForecast(this.date, this.temp, this.condition, {this.minT, this.maxT, this.pop});

  Map<String, dynamic> toJson() => {
    "date": date.toIso8601String(),
    "temp": temp,
    "condition": condition,
    if (minT != null) "minT": minT,
    if (maxT != null) "maxT": maxT,
    if (pop != null) "pop": pop,
  };

  static DayForecast fromJson(Map<String, dynamic> j) => DayForecast(
    DateTime.parse(j["date"]),
    (j["temp"] as num).toDouble(),
    j["condition"],
    minT: (j["minT"] as num?)?.toDouble(),
    maxT: (j["maxT"] as num?)?.toDouble(),
    pop: (j["pop"] as num?)?.toDouble(),
  );
}

class HourForecast {
  final DateTime time;
  final double temp;
  final String condition;
  HourForecast(this.time, this.temp, this.condition);

  Map<String, dynamic> toJson() => {
    "time": time.toIso8601String(),
    "temp": temp,
    "condition": condition,
  };

  static HourForecast fromJson(Map<String, dynamic> j) =>
      HourForecast(DateTime.parse(j["time"]), (j["temp"] as num).toDouble(), j["condition"]);
}

class WeatherBundle {
  final String city;
  final double temperature;
  final String condition;
  final List<DayForecast> nextDays;
  final List<HourForecast> hours; // 24 значения, начиная с текущего часа
  final double lat;
  final double lon;
  WeatherBundle({
    required this.city,
    required this.temperature,
    required this.condition,
    required this.nextDays,
    required this.hours,
    required this.lat,
    required this.lon,
  });

  Map<String, dynamic> toJson() => {
    "city": city,
    "temperature": temperature,
    "condition": condition,
    "nextDays": nextDays.map((e) => e.toJson()).toList(),
    "hours": hours.map((e) => e.toJson()).toList(),
    "lat": lat,
    "lon": lon,
  };

  static WeatherBundle fromJson(Map<String, dynamic> j) => WeatherBundle(
    city: j["city"],
    temperature: (j["temperature"] as num).toDouble(),
    condition: j["condition"],
    nextDays: (j["nextDays"] as List? ?? []).map((e) => DayForecast.fromJson(e)).toList(),
    hours: (j["hours"] as List? ?? []).map((e) => HourForecast.fromJson(e)).toList(),
    lat: (j["lat"] as num).toDouble(),
    lon: (j["lon"] as num).toDouble(),
  );
}

class GeoSuggestion {
  final String name;
  final String? state;
  final String country;
  final double lat;
  final double lon;
  GeoSuggestion({required this.name, this.state, required this.country, required this.lat, required this.lon});
  String displayName() => state == null || state!.isEmpty ? "$name, $country" : "$name, $state, $country";
}

// ===================== REPOSITORY =====================
class WeatherRepository {
  final String apiKey;
  WeatherRepository(this.apiKey);

  Future<WeatherBundle> fetchForCity(String city) async {
    final curUrl = "https://api.openweathermap.org/data/2.5/weather?q=$city&units=metric&lang=ru&appid=$apiKey";
    final curRes = await http.get(Uri.parse(curUrl)).timeout(const Duration(seconds: 10));
    if (curRes.statusCode != 200) throw Exception("Ошибка текущей погоды (${curRes.statusCode})");
    final cur = json.decode(curRes.body);
    final tempNow = (cur["main"]["temp"] as num).toDouble();
    final condNow = cur["weather"][0]["main"] as String;
    final lat = (cur["coord"]["lat"] as num).toDouble();
    final lon = (cur["coord"]["lon"] as num).toDouble();
    final resolvedCity = (cur["name"] as String?) ?? city;

    final wb = await _fetchByCoordsInternal(lat, lon);
    return WeatherBundle(
      city: resolvedCity,
      temperature: tempNow,
      condition: condNow,
      nextDays: wb.nextDays,
      hours: wb.hours,
      lat: lat,
      lon: lon,
    );
  }

  Future<WeatherBundle> fetchByCoords(double lat, double lon) async {
    final curUrl =
        "https://api.openweathermap.org/data/2.5/weather?lat=$lat&lon=$lon&units=metric&lang=ru&appid=$apiKey";
    final curRes = await http.get(Uri.parse(curUrl)).timeout(const Duration(seconds: 10));
    if (curRes.statusCode != 200) throw Exception("Ошибка текущей погоды (${curRes.statusCode})");
    final cur = json.decode(curRes.body);
    final tempNow = (cur["main"]["temp"] as num).toDouble();
    final condNow = cur["weather"][0]["main"] as String;
    final name = (cur["name"] as String?) ?? "";

    final wb = await _fetchByCoordsInternal(lat, lon);
    return WeatherBundle(
      city: name,
      temperature: tempNow,
      condition: condNow,
      nextDays: wb.nextDays,
      hours: wb.hours,
      lat: lat,
      lon: lon,
    );
  }

  Future<WeatherBundle> _fetchByCoordsInternal(double lat, double lon) async {
    List<HourForecast> hours = [];
    List<DayForecast> days10 = [];

    // OneCall 3.0
    try {
      final oc3 =
          "https://api.openweathermap.org/data/3.0/onecall?lat=$lat&lon=$lon&exclude=minutely,alerts&units=metric&lang=ru&appid=$apiKey";
      final r = await http.get(Uri.parse(oc3)).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final oc = json.decode(r.body);
        final now = DateTime.now();
        for (final h in (oc["hourly"] as List? ?? [])) {
          final dt = DateTime.fromMillisecondsSinceEpoch((h["dt"] as num).toInt() * 1000, isUtc: true).toLocal();
          if (dt.isAfter(now.subtract(const Duration(minutes: 1)))) {
            hours.add(HourForecast(
              dt,
              (h["temp"] as num).toDouble(),
              (h["weather"]?[0]?["main"] as String?) ?? "Clouds",
            ));
          }
        }
        for (final d in (oc["daily"] as List? ?? [])) {
          final dt = DateTime.fromMillisecondsSinceEpoch((d["dt"] as num).toInt() * 1000, isUtc: true).toLocal();
          days10.add(DayForecast(
            DateTime(dt.year, dt.month, dt.day),
            ((d["temp"]?["day"]) as num?)?.toDouble() ?? 0.0,
            (d["weather"]?[0]?["main"] as String?) ?? "Clouds",
            minT: (d["temp"]?["min"] as num?)?.toDouble(),
            maxT: (d["temp"]?["max"] as num?)?.toDouble(),
            pop: (d["pop"] as num?)?.toDouble(),
          ));
        }
      }
    } catch (_) {}

    // fallback OneCall 2.5
    if (days10.isEmpty || hours.isEmpty) {
      try {
        final oc2 =
            "https://api.openweathermap.org/data/2.5/onecall?lat=$lat&lon=$lon&exclude=minutely,alerts&units=metric&lang=ru&appid=$apiKey";
        final r = await http.get(Uri.parse(oc2)).timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) {
          final oc = json.decode(r.body);
          final now = DateTime.now();
          hours.clear();
          for (final h in (oc["hourly"] as List? ?? [])) {
            final dt = DateTime.fromMillisecondsSinceEpoch((h["dt"] as num).toInt() * 1000, isUtc: true).toLocal();
            if (dt.isAfter(now.subtract(const Duration(minutes: 1)))) {
              hours.add(HourForecast(
                dt,
                (h["temp"] as num).toDouble(),
                (h["weather"]?[0]?["main"] as String?) ?? "Clouds",
              ));
            }
          }
          days10.clear();
          for (final d in (oc["daily"] as List? ?? [])) {
            final dt = DateTime.fromMillisecondsSinceEpoch((d["dt"] as num).toInt() * 1000, isUtc: true).toLocal();
            days10.add(DayForecast(
              DateTime(dt.year, dt.month, dt.day),
              ((d["temp"]?["day"]) as num?)?.toDouble() ?? 0.0,
              (d["weather"]?[0]?["main"] as String?) ?? "Clouds",
              minT: (d["temp"]?["min"] as num?)?.toDouble(),
              maxT: (d["temp"]?["max"] as num?)?.toDouble(),
              pop: (d["pop"] as num?)?.toDouble(),
            ));
          }
        }
      } catch (_) {}
    }

    // /forecast fallback (5 суток)
    if (days10.length < 10 || hours.isEmpty) {
      final fcUrl =
          "https://api.openweathermap.org/data/2.5/forecast?lat=$lat&lon=$lon&units=metric&lang=ru&appid=$apiKey";
      final fcRes = await http.get(Uri.parse(fcUrl)).timeout(const Duration(seconds: 10));
      if (fcRes.statusCode == 200) {
        final data = json.decode(fcRes.body);
        final List<dynamic> list = data["list"];
        final now = DateTime.now();
        if (hours.isEmpty) {
          for (final item in list) {
            final dt = DateTime.fromMillisecondsSinceEpoch(item["dt"] * 1000, isUtc: true).toLocal();
            if (dt.isAfter(now.subtract(const Duration(minutes: 1)))) {
              hours.add(HourForecast(
                dt,
                (item["main"]["temp"] as num).toDouble(),
                item["weather"][0]["main"] as String,
              ));
            }
          }
          hours.sort((a, b) => a.time.compareTo(b.time));
        }
        if (days10.length < 10) {
          final Map<String, Map<String, dynamic>> daily = {};
          for (final item in list) {
            final dt = DateTime.fromMillisecondsSinceEpoch(item["dt"] * 1000, isUtc: true).toLocal();
            final key = DateFormat('yyyy-MM-dd').format(dt);
            final diff = (15 - dt.hour).abs(); // ближе к 15:00
            final t = (item["main"]["temp"] as num).toDouble();
            final c = item["weather"][0]["main"] as String;
            final pop = (item["pop"] as num?)?.toDouble() ?? 0.0;
            if (!daily.containsKey(key)) {
              daily[key] = {
                "date": DateTime(dt.year, dt.month, dt.day),
                "temp": t,
                "cond": c,
                "diff": diff,
                "min": t,
                "max": t,
                "pop": pop,
              };
            } else {
              if (diff < (daily[key]!["diff"] as int)) {
                daily[key]!["temp"] = t;
                daily[key]!["cond"] = c;
                daily[key]!["diff"] = diff;
              }
              if (t < (daily[key]!["min"] as num)) daily[key]!["min"] = t;
              if (t > (daily[key]!["max"] as num)) daily[key]!["max"] = t;
              if (pop > (daily[key]!["pop"] as num)) daily[key]!["pop"] = pop;
            }
          }
          final vals = daily.values.toList()
            ..sort((a, b) => (a["date"] as DateTime).compareTo(b["date"] as DateTime));
          days10 = vals.take(10).map((m) => DayForecast(
            m["date"],
            (m["temp"] as num).toDouble(),
            m["cond"],
            minT: (m["min"] as num).toDouble(),
            maxT: (m["max"] as num).toDouble(),
            pop: (m["pop"] as num?)?.toDouble(),
          )).toList();
        }
      }
    }

    final hours24 = _toHourly(hours, 24);
    if (days10.length > 10) days10 = days10.take(10).toList();
    return WeatherBundle(city: "", temperature: 0, condition: "", nextDays: days10, hours: hours24, lat: lat, lon: lon);
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
    return list
        .map<GeoSuggestion>((m) => GeoSuggestion(
      name: m["local_names"]?["ru"] ?? m["name"],
      state: m["state"],
      country: m["country"] ?? "",
      lat: (m["lat"] as num).toDouble(),
      lon: (m["lon"] as num).toDouble(),
    ))
        .toList();
  }
}

// Нормализуем к N часам, начиная с текущего часа (HH:00)
List<HourForecast> _toHourly(List<HourForecast> src, int count) {
  if (src.isEmpty) return src;
  src.sort((a, b) => a.time.compareTo(b.time));
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day, now.hour);
  if (src.length == 1) {
    return List.generate(count, (i) => HourForecast(start.add(Duration(hours: i)), src.first.temp, src.first.condition));
  }
  final step = src[1].time.difference(src[0].time).inMinutes.abs();
  if (step <= 70) {
    final List<HourForecast> out = [];
    for (int i = 0; i < count; i++) {
      final t = start.add(Duration(hours: i));
      HourForecast nearest = src.first;
      int best = 1 << 30;
      for (final h in src) {
        final d = (h.time.difference(t)).inMinutes.abs();
        if (d < best) { best = d; nearest = h; }
      }
      out.add(HourForecast(t, nearest.temp, nearest.condition));
    }
    return out;
  }
  List<HourForecast> out = [];
  for (int i = 0; i < count; i++) {
    final t = start.add(Duration(hours: i));
    HourForecast? a;
    HourForecast? b;
    for (int j = 0; j < src.length - 1; j++) {
      final tA = src[j].time;
      final tB = src[j + 1].time;
      if ((t.isAfter(tA) || t.isAtSameMomentAs(tA)) && t.isBefore(tB)) {
        a = src[j];
        b = src[j + 1];
        break;
      }
    }
    a ??= src.first;
    b ??= src.last;
    final ta = a.time.millisecondsSinceEpoch.toDouble();
    final tb = b.time.millisecondsSinceEpoch.toDouble();
    final tt = t.millisecondsSinceEpoch.toDouble();
    final w = tb == ta ? 0.0 : (tt - ta) / (tb - ta);
    final temp = a.temp + (b.temp - a.temp) * w;
    final cond = (w < 0.5) ? a.condition : b.condition;
    out.add(HourForecast(t, temp, cond));
  }
  return out;
}

// ===================== APP =====================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  debugPrint("WeatherFox build: v18");
  runApp(const WeatherFoxApp());
}

class WeatherFoxApp extends StatelessWidget {
  const WeatherFoxApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Weather Fox',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const NoStretchScrollBehavior(),
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

class _WeatherScreenState extends State<WeatherScreen> with TickerProviderStateMixin {
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
  late final ScrollController _dayCtrl;
  int _selectedDayIndex = 0;

  static const double _rowBoxHeight = 72.0;
  Color _accentColor = const Color(0xFF5DA3C4);
  String? _currentScene;
  bool _paletteBusy = false;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    repo = WeatherRepository(openWeatherApiKey);
    city = widget.defaultCity;
    _hourCtrl = ScrollController(initialScrollOffset: 0);
    _dayCtrl = ScrollController(initialScrollOffset: 0);
    _loadAssetManifest();
    _loadSavedCharacter().then((id) { if (mounted) setState(() => characterId = id); });
    _loadFromPrefs().then((_) => _load());
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(minutes: 15), (_) => _load(soft: true));
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _hourCtrl.dispose();
    _dayCtrl.dispose();
    super.dispose();
  }

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

  Future<void> _load({bool soft = false}) async {
    if (!soft) setState(() { loading = true; error = null; });
    try {
      final b = await repo.fetchForCity(city);
      setState(() { bundle = b; _selectedDayIndex = 0; });
      await _saveToPrefs(b);
      if (_hourCtrl.hasClients) _hourCtrl.jumpTo(0);
      if (_dayCtrl.hasClients) _dayCtrl.jumpTo(0);
    } catch (e) {
      if (bundle == null) await _loadFromPrefs();
      setState(() => error = e.toString());
    } finally {
      if (!soft) setState(() { loading = false; });
    }
  }

  Future<void> _loadByCoords(double lat, double lon, {String? named}) async {
    setState(() { loading = true; error = null; });
    try {
      final b = await repo.fetchByCoords(lat, lon);
      setState(() { bundle = b; city = named ?? b.city; _selectedDayIndex = 0; });
      await _saveToPrefs(b);
      if (_hourCtrl.hasClients) _hourCtrl.jumpTo(0);
      if (_dayCtrl.hasClients) _dayCtrl.jumpTo(0);
    } catch (e) {
      if (bundle == null) await _loadFromPrefs();
      setState(() => error = e.toString());
    } finally {
      setState(() { loading = false; });
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
    if (lat.abs() <= 23.5) return _seasonTropics(days);
    return _seasonFour(now, north: lat > 0);
  }

  String sceneForSeasonal(String cond, DateTime now, WeatherBundle b) {
    final c = conditionKey(cond);
    final t = appTimeOfDay(now);
    final s = seasonTag(b.lat, now, b.nextDays);
    final wanted = [
      "assets/images/${characterId}/${characterId}_${c}_${s}_${t}.webp",
      "assets/images/${characterId}/${characterId}_${c}_${t}.webp",
      "assets/images/${characterId}/${characterId}_${c}_day.webp",
      "assets/images/${characterId}_${c}_${s}_${t}.webp",
      "assets/images/${characterId}_${c}_${t}.webp",
      "assets/images/${characterId}_${c}_day.webp",
    ];
    for (final p in wanted) {
      if (_assetKeys.contains(p)) return p;
    }
    final byChar = _assetKeys.where((k) =>
    k.startsWith("assets/images/${characterId}/") || k.startsWith("assets/images/${characterId}_")).toList();
    if (byChar.isNotEmpty) {
      final preferred = byChar.where((k) => k.contains("_${c}_")).toList();
      if (preferred.isNotEmpty) {
        final preferredTime = preferred.where((k) => k.endsWith("_${t}.webp")).toList();
        if (preferredTime.isNotEmpty) return preferredTime.first;
        return preferred.first;
      }
      return byChar.first;
    }
    final fallback = _assetKeys.firstWhere(
          (k) => k.startsWith("assets/images/${CharacterIds.fox}/") || k.startsWith("assets/images/${CharacterIds.fox}_"),
      orElse: () => "assets/images/${CharacterIds.fox}/${CharacterIds.fox}_clouds_day.webp",
    );
    return fallback;
  }

  String dayRu(DateTime t) => DateFormat('EEE', 'ru').format(t).replaceAll('.', '');
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

  String _updatedLabel() {
    if (_lastUpdated == null) return "";
    final now = DateTime.now();
    final diff = now.difference(_lastUpdated!);
    final timeStr = DateFormat('HH:mm', 'ru').format(_lastUpdated!);
    final mins = diff.inMinutes;
    if (mins < 1) return "Обновлено только что ($timeStr)";
    if (mins < 60) return "Обновлено ${mins} мин назад ($timeStr)";
    final hours = diff.inHours;
    return "Обновлено ${hours} ч назад ($timeStr)";
  }

  String _dayRangeLine(DayForecast d) {
    final minT = d.minT?.round();
    final maxT = d.maxT?.round();
    final cond = _condRu(d.condition);
    if (minT != null && maxT != null) return "$minT–$maxT° • $cond";
    return "${d.temp.round()}° • $cond";
  }

  // ------- UI -------
  @override
  Widget build(BuildContext context) {
    final b = bundle;
    final now = DateTime.now();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background
          Positioned.fill(
            child: b == null
                ? const ColoredBox(color: Color(0xFF355F5B))
                : Builder(builder: (ctx) {
              final scene = sceneForSeasonal(b.condition, now, b);
              _ensureAccentForScene(scene);
              return Image.asset(scene, fit: BoxFit.cover, key: ValueKey(scene));
            }),
          ),
          // constant dim overlay
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54.withOpacity(0.32), Colors.black54.withOpacity(0.18), Colors.black54.withOpacity(0.32)],
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),

          SafeArea(
            child: RefreshIndicator(
              backgroundColor: Colors.transparent,
              color: Colors.white,
              onRefresh: () => _load(soft: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
                padding: const EdgeInsets.all(16),
                children: [
                  if (loading && b == null)
                    const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
                  if (!loading && b == null) ...[
                    const SizedBox(height: 24),
                    _glass(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: const [
                          SizedBox(height: 8),
                          Icon(Icons.cloud_off, size: 44, color: Colors.white70),
                          SizedBox(height: 12),
                          Text('Нет данных', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                          SizedBox(height: 6),
                          Text('Проверьте сеть, выберите город или потяните вниз, чтобы обновить',
                              textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
                          SizedBox(height: 8),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  if (b != null) ...[
                    // Header
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Align(alignment: Alignment.topRight, child: _TinyThreeDots(onTap: _openSettings)),
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
                                    style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Colors.white),
                                  ),
                                  const SizedBox(height: 2),
                                  if (_updatedLabel().isNotEmpty)
                                    Text(_updatedLabel(), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Row(
                                  children: [
                                    Text("${b.temperature.round()}°",
                                        style: const TextStyle(fontSize: 58, fontWeight: FontWeight.w800, color: Colors.white, height: 1.0)),
                                    const SizedBox(width: 8),
                                    _WeatherIcon(b.condition, size: 28),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(_capitalize(_condRu(b.condition)), style: const TextStyle(color: Colors.white70)),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Hourly or summary
                    SizedBox(
                      height: _rowBoxHeight,
                      child: LayoutBuilder(
                        builder: (c, cc) {
                          final isToday = _selectedDayIndex == 0;
                          if (isToday) {
                            const double visibleSlots = 7;
                            final double slotW = cc.maxWidth / visibleSlots;
                            final list = b!.hours;
                            const int count = 24;
                            return _glass(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: ListView.builder(
                                controller: _hourCtrl,
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                padding: EdgeInsets.zero,
                                itemCount: count,
                                itemBuilder: (context, index) {
                                  final h = list[index < list.length ? index : (list.length - 1)];
                                  final hh = DateTime(h.time.year, h.time.month, h.time.day, h.time.hour);
                                  return SizedBox(
                                    width: slotW,
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(DateFormat('HH:00', 'ru').format(hh),
                                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, height: 1.0),
                                            overflow: TextOverflow.fade, softWrap: false),
                                        const SizedBox(height: 2),
                                        _WeatherIcon(h.condition, size: 16),
                                        const SizedBox(height: 2),
                                        Text("${h.temp.round()}°", style: const TextStyle(fontSize: 11, height: 1.0),
                                            overflow: TextOverflow.fade, softWrap: false),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            );
                          } else {
                            final d = b!.nextDays[_selectedDayIndex];
                            return _glass(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    DateFormat('d MMMM', 'ru').format(d.date),
                                    maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, textAlign: TextAlign.right,
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "${_capitalize(dayRu(d.date))} • ${_dayRangeLine(d)} • " +
                                        (d.pop != null ? "Вероятность осадков: ${(d.pop! * 100).round()}%" : "Вероятность осадков: —"),
                                    maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, textAlign: TextAlign.right,
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                                  ),
                                ],
                              ),
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 8),

                    // 10-day row (horizontal)
                    SizedBox(
                      height: _rowBoxHeight,
                      child: LayoutBuilder(builder: (c, cc) {
                        const double visibleSlots = 7;
                        final double slotW = cc.maxWidth / visibleSlots;
                        return _glass(
                          padding: EdgeInsets.zero,
                          child: ListView.builder(
                            controller: _dayCtrl,
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            padding: EdgeInsets.zero,
                            itemCount: 10,
                            itemBuilder: (context, index) {
                              final days = b!.nextDays;
                              final bool hasData = index < days.length;
                              final bool isSel = index == _selectedDayIndex;
                              final d = hasData ? days[index] : null;
                              final String title = index == 0 ? "Сегодня" : (hasData ? _capitalize(dayRu(d!.date)) : "—");

                              return SizedBox(
                                width: slotW,
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: hasData ? () => setState(() => _selectedDayIndex = index) : null,
                                    overlayColor: MaterialStateProperty.resolveWith((states) {
                                      if (states.contains(MaterialState.pressed)) return Colors.white.withOpacity(0.06);
                                      if (states.contains(MaterialState.hovered) || states.contains(MaterialState.focused)) {
                                        return Colors.white.withOpacity(0.04);
                                      }
                                      return Colors.transparent;
                                    }),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: isSel && index != 0 ? Colors.black.withOpacity(0.06) : Colors.transparent,
                                        border: Border(
                                          right: BorderSide(color: Colors.black.withOpacity(0.12)),
                                        ),
                                      ),
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            title,
                                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: isSel ? Colors.white : Colors.white70),
                                            maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          if (hasData) ...[
                                            _WeatherIcon(d!.condition, size: 16),
                                            const SizedBox(height: 4),
                                            Text("${d.temp.round()}°", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                                          ] else ...[
                                            const SizedBox(height: 16),
                                            const SizedBox(height: 4),
                                            const Text(" ", style: TextStyle(fontSize: 11)),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        );
                      }),
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
      // settings button also accessible from app bar area if needed
    );
  }

  // ------- helpers -------
  Widget _glass({required Widget child, EdgeInsetsGeometry? padding, BorderRadius? radius}) {
    return ClipRRect(
      borderRadius: radius ?? BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.20),
            border: Border.all(color: Colors.white.withOpacity(0.34)),
            borderRadius: radius ?? BorderRadius.circular(16),
          ),
          child: child,
        ),
      ),
    );
  }

  Future<void> _ensureAccentForScene(String scenePath) async {
    if (_currentScene == scenePath || _paletteBusy) return;
    _currentScene = scenePath;
    _paletteBusy = true;
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        AssetImage(scenePath),
        maximumColorCount: 10,
        size: const Size(200, 120),
      );
      final swatch = palette.vibrantColor ?? palette.dominantColor;
      final col = swatch?.color ?? _accentColor;
      if (!mounted) return;
      setState(() { _accentColor = col; });
    } catch (_) {} finally { _paletteBusy = false; }
  }

  Future<void> _openSettings() async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Settings',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, anim1, anim2) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __) {
        final width = MediaQuery.of(ctx).size.width * 0.4; // 40%
        final offset = Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
        return SlideTransition(
          position: offset,
          child: Align(
            alignment: Alignment.centerRight,
            child: SafeArea(
              child: _SettingsPanel(
                width: width,
                onManualPick: () => _openCitySearch(ctx),
                onDetectCity: _detectCityByGPS,
                avatarFor: _avatarFor,
                availableIds: _availableCharacterIds,
                isSelected: (id) => id == characterId,
                onPickCharacter: (id) async {
                  setState(() { characterId = id; });
                  await _saveSelectedCharacter(id);
                  Navigator.of(ctx).maybePop();
                },
              ),
            ),
          ),
        );
      },
    );
  }

  String _avatarFor(String id) {
    final candidates = <String>[
      "assets/images/$id/${id}_clear_day.webp",
      "assets/images/$id/${id}_clouds_day.webp",
      "assets/images/$id/${id}_rain_day.webp",
      "assets/images/$id/${id}_clouds_morning.webp",
      "assets/images/${id}_clear_day.webp",
      "assets/images/${id}_clouds_day.webp",
      "assets/images/${id}_rain_day.webp",
      "assets/images/${id}_clouds_morning.webp",
    ];
    for (final p in candidates) { if (_assetKeys.contains(p)) return p; }
    for (final k in _assetKeys) {
      if (k.startsWith("assets/images/$id/") || k.startsWith("assets/images/${id}_")) return k;
    }
    return "assets/images/$id/${id}_clouds_day.webp";
  }

  List<String> _availableCharacterIds() {
    final candidates = <String>{CharacterIds.fox, "robot", "spider", "raccoon"};
    bool hasAssets(String id) =>
        _assetKeys.any((k) => k.startsWith("assets/images/$id/") || k.startsWith("assets/images/${id}_"));
    final result = candidates.where(hasAssets).toList();
    if (result.isEmpty) return [CharacterIds.fox];
    return result;
  }

  Future<void> _openCitySearch(BuildContext fromCtx) async {
    final selected = await showModalBottomSheet<GeoSuggestion>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black.withOpacity(0.40),
      barrierColor: Colors.black54,
      builder: (ctx) => _CitySearchSheet(repo: repo, detectCity: _detectCityByGPS),
    );
    if (selected != null) {
      showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
      await _loadByCoords(selected.lat, selected.lon, named: selected.displayName());
      if (Navigator.canPop(context)) Navigator.pop(context);
      if (Navigator.of(fromCtx).canPop()) Navigator.of(fromCtx).pop();
    }
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
      if (name != null && name.isNotEmpty) { await _loadByCoords(pos.latitude, pos.longitude, named: name); return true; }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Город не найден по координатам")));
      return false;
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Ошибка определения местоположения")));
      return false;
    }
  }
}

// Weather icon with raindrops
class _WeatherIcon extends StatelessWidget {
  final String condition;
  final double size;
  const _WeatherIcon(this.condition, {this.size = 20, super.key});

  @override
  Widget build(BuildContext context) {
    final c = condition;
    if (c == "Rain" || c == "Drizzle") {
      return SizedBox(
        width: size, height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(Icons.cloud, size: size, color: Colors.white),
            Positioned(
              bottom: size * 0.02,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.water_drop, size: size * 0.28, color: Colors.white),
                  SizedBox(width: size * 0.06),
                  Icon(Icons.water_drop, size: size * 0.28, color: Colors.white),
                  SizedBox(width: size * 0.06),
                  Icon(Icons.water_drop, size: size * 0.28, color: Colors.white),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (c == "Thunderstorm") return Icon(Icons.thunderstorm, size: size, color: Colors.white);
    if (c == "Snow") return Icon(Icons.ac_unit, size: size, color: Colors.white);
    if (c == "Clear") return Icon(Icons.wb_sunny, size: size, color: Colors.white);
    return Icon(Icons.cloud, size: size, color: Colors.white);
  }
}

// ------- Side Settings Panel -------
class _SettingsPanel extends StatefulWidget {
  final double width;
  final Future<bool> Function() onDetectCity;
  final Future<void> Function() onManualPick;
  final List<String> Function() availableIds;
  final String Function(String) avatarFor;
  final bool Function(String) isSelected;
  final Future<void> Function(String) onPickCharacter;

  const _SettingsPanel({
    required this.width,
    required this.onDetectCity,
    required this.onManualPick,
    required this.availableIds,
    required this.avatarFor,
    required this.isSelected,
    required this.onPickCharacter,
  });

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final ids = widget.availableIds();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
      child: Container(
        width: widget.width,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: Color(0xFFF7F7FA),
          borderRadius: BorderRadius.only(topLeft: Radius.circular(16), bottomLeft: Radius.circular(16)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0,4))],
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // One City button
            Theme(
              data: Theme.of(context).copyWith(
                splashColor: Colors.black12,
                highlightColor: Colors.black12,
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: busy ? null : () async {
                    setState(() => busy = true);
                    await widget.onManualPick();
                    setState(() => busy = false);
                  },
                  child: const Text("Город"),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(height: 1, color: Colors.black12),
            const SizedBox(height: 12),
            const Text("Персонаж", style: TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1,
                ),
                physics: const BouncingScrollPhysics(),
                itemCount: ids.length,
                itemBuilder: (context, index) {
                  final id = ids[index];
                  final path = widget.avatarFor(id);
                  final isSelected = widget.isSelected(id);
                  return GestureDetector(
                    onTap: busy ? null : () async {
                      await widget.onPickCharacter(id);
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.asset(path, fit: BoxFit.cover),
                          if (isSelected) Container(
                            color: Colors.black.withOpacity(0.25),
                            child: const Center(child: Icon(Icons.check_circle, color: Colors.white, size: 28)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (busy) const LinearProgressIndicator(minHeight: 2, color: Colors.black54, backgroundColor: Color(0xFFE0E0E0)),
          ],
        ),
      ),
    );
  }
}

// ------- Three tiny dots -------
class _TinyThreeDots extends StatelessWidget {
  final VoidCallback onTap;
  const _TinyThreeDots({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: const SizedBox(width: 20, height: 16, child: CustomPaint(painter: _DotsPainter())),
      ),
    );
  }
}
class _DotsPainter extends CustomPainter {
  const _DotsPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withOpacity(0.95)..style = PaintingStyle.fill;
    final r = size.height * 0.10;
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

// ------- City Search Sheet -------
class _CitySearchSheet extends StatefulWidget {
  final WeatherRepository repo;
  final Future<bool> Function()? detectCity;
  const _CitySearchSheet({required this.repo, this.detectCity});
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
    setState((){}); // to show/hide "Автоматически"
    _error = "";
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      setState(() { _loading = true; });
      try {
        final list = await widget.repo.suggestCities(q);
        setState(() { _items = list; if (list.isEmpty) _error = "Город не найден"; });
      } catch (_) {
        setState(() { _items = []; _error = "Ошибка поиска"; });
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
                onSubmitted: (v) {
                  if (_items.isNotEmpty) {
                    Navigator.pop(context, _items.first);
                  } else {
                    setState(() { _error = "Город не найден"; });
                  }
                },
              ),
              const SizedBox(height: 12),
              if ((_ctrl.text.trim().isEmpty) && widget.detectCity != null)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.my_location),
                    label: const Text("Автоматически"),
                    onPressed: () async {
                      setState(() { _loading = true; _error = ""; });
                      final ok = await widget.detectCity!();
                      setState(() { _loading = false; });
                      if (ok && mounted) Navigator.of(context).maybePop();
                    },
                  ),
                ),
              if (_loading) const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
              if (_error.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error, style: const TextStyle(color: Colors.redAccent))),
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
                      return ListTile(
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
