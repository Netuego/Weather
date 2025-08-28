
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import 'secrets.dart';

class DayForecast {
  final DateTime date;
  final double temp;
  final String condition;
  DayForecast(this.date, this.temp, this.condition);

  Map<String, dynamic> toJson() => {
    "date": date.toIso8601String(),
    "temp": temp,
    "condition": condition,
  };
  static DayForecast fromJson(Map<String, dynamic> j) =>
      DayForecast(DateTime.parse(j["date"]), (j["temp"] as num).toDouble(), j["condition"]);
}

class WeatherBundle {
  final String city;
  final double temperature;
  final String condition;
  final List<DayForecast> nextDays;
  final double lat;
  final double lon;
  WeatherBundle({required this.city, required this.temperature, required this.condition, required this.nextDays, required this.lat, required this.lon});

  Map<String, dynamic> toJson() => {
    "city": city,
    "temperature": temperature,
    "condition": condition,
    "nextDays": nextDays.map((e)=> e.toJson()).toList(),
    "lat": lat,
    "lon": lon,
  };
  static WeatherBundle fromJson(Map<String, dynamic> j) => WeatherBundle(
    city: j["city"],
    temperature: (j["temperature"] as num).toDouble(),
    condition: j["condition"],
    nextDays: (j["nextDays"] as List).map((e)=> DayForecast.fromJson(e)).toList(),
    lat: (j["lat"] as num).toDouble(),
    lon: (j["lon"] as num).toDouble(),
  );
}

class WeatherRepository {
  final String apiKey;
  WeatherRepository(this.apiKey);

  Future<WeatherBundle> fetchForCity(String city) async {
    final curUrl = "https://api.openweathermap.org/data/2.5/weather?q=$city&units=metric&lang=ru&appid=$apiKey";
    final curRes = await http.get(Uri.parse(curUrl)).timeout(const Duration(seconds: 8));
    if (curRes.statusCode != 200) throw Exception("Current weather error ${curRes.statusCode}");
    final cur = json.decode(curRes.body);
    final temp = (cur["main"]["temp"] as num).toDouble();
    final cond = cur["weather"][0]["main"] as String;

    final fcUrl = "https://api.openweathermap.org/data/2.5/forecast?q=$city&units=metric&lang=ru&appid=$apiKey";
    final fcRes = await http.get(Uri.parse(fcUrl)).timeout(const Duration(seconds: 10));
    if (fcRes.statusCode != 200) throw Exception("Forecast error ${fcRes.statusCode}");
    final data = json.decode(fcRes.body);
    final List list = data["list"];

    Map<String, Map<String, dynamic>> daily = {};
    for (final item in list) {
      final dt = DateTime.fromMillisecondsSinceEpoch(item["dt"] * 1000, isUtc: true).toLocal();
      final key = DateFormat('yyyy-MM-dd').format(dt);
      final hour = dt.hour;
      final diff = (15 - hour).abs();
      final t = (item["main"]["temp"] as num).toDouble();
      final c = item["weather"][0]["main"] as String;
      if (!daily.containsKey(key) || diff < daily[key]!["diff"]) {
        daily[key] = {"date": DateTime(dt.year, dt.month, dt.day), "temp": t, "cond": c, "diff": diff};
      }
    }
    final days = daily.values.toList()
      ..sort((a,b)=> (a["date"] as DateTime).compareTo(b["date"] as DateTime));
    final forecasts = days.take(7).map((m)=> DayForecast(m["date"], (m["temp"] as num).toDouble(), m["cond"] as String)).toList();

    final lat = (data["city"]["coord"]["lat"] as num).toDouble();
    final lon = (data["city"]["coord"]["lon"] as num).toDouble();

    return WeatherBundle(city: data["city"]["name"], temperature: temp, condition: cond, nextDays: forecasts, lat: lat, lon: lon);
  }
}

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
  @override State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  late final WeatherRepository repo;
  String city = "";
  WeatherBundle? bundle;
  bool loading = true;
  String? error;
  Set<String> _assetKeys = {};
  DateTime? _lastUpdated;

  static const _prefCity = "last_city";
  static const _prefWeather = "last_weather_json";
  static const _prefUpdated = "last_updated_ms";

  @override
  void initState() {
    super.initState();
    repo = WeatherRepository(openWeatherApiKey);
    city = widget.defaultCity;
    _loadAssetManifest();
    _loadFromPrefs().then((_) => _load());
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
    setState(()=> {loading = true, error = null});
    try {
      final b = await repo.fetchForCity(city);
      setState(()=> bundle = b);
      await _saveToPrefs(b);
    } catch (e) {
      if (bundle == null) {
        await _loadFromPrefs();
      }
      setState(()=> error = e.toString());
    } finally {
      setState(()=> loading = false);
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
      "assets/images/fox_${c}_${s}_${t}.webp",
      "assets/images/fox_${c}_${t}.webp",
      "assets/images/fox_${c}_day.webp",
    ];
    for (final p in candidates) {
      if (_assetKeys.contains(p)) return p;
    }
    return "assets/images/fox_clouds_day.webp";
  }

  String weekdayRu(DateTime d) => DateFormat('EE','ru').format(d).toUpperCase();

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
      body: Stack(
        children: [
          Positioned.fill(
            child: b == null
                ? const ColoredBox(color: Color(0xFF355F5B))
                : Image.asset(sceneForSeasonal(b.condition, now, b), fit: BoxFit.cover),
          ),
          Positioned.fill(child: Container(color: Colors.black.withOpacity(0.10))),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: loading && b == null
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (b != null) ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(b.city, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Colors.white)),
                                    const SizedBox(height: 4),
                                    if (_updatedLabel().isNotEmpty)
                                      Text(_updatedLabel(), style: const TextStyle(color: Colors.white70)),
                                    const SizedBox(height: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.78), borderRadius: BorderRadius.circular(16)),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          for (final d in b.nextDays.take(7))
                                            Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 8),
                                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                                Text(weekdayRu(d.date), style: const TextStyle(fontWeight: FontWeight.w600)),
                                                const SizedBox(height: 6),
                                                Icon(Icons.circle, size: 10, color: Colors.black26),
                                                const SizedBox(height: 6),
                                                Text("${d.temp.round()}°", style: const TextStyle(fontSize: 12)),
                                              ]),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text("${b.temperature.round()}°", style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800, color: Colors.white, height: 1.0)),
                                  const SizedBox(height: 6),
                                  Text(conditionKey(b.condition), style: const TextStyle(color: Colors.white70)),
                                ],
                              ),
                            ],
                          ),
                        ],
                        const Spacer(),
                        Align(
                          alignment: Alignment.bottomRight,
                          child: FilledButton.tonal(
                            onPressed: () async {
                              final ctrl = TextEditingController(text: city);
                              final newCity = await showDialog<String>(context: context, builder: (ctx){
                                return AlertDialog(
                                  title: const Text("Город"),
                                  content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: "Например, Москва")),
                                  actions: [
                                    TextButton(onPressed: ()=> Navigator.pop(ctx), child: const Text("Отмена")),
                                    FilledButton(onPressed: ()=> Navigator.pop(ctx, ctrl.text.trim()), child: const Text("OK")),
                                  ],
                                );
                              });
                              if (newCity != null && newCity.isNotEmpty) {
                                city = newCity;
                                setState((){});
                                await _load();
                              }
                            },
                            child: const Text("Изменить город"),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
