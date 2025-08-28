
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'characters.dart';
import 'secrets.dart';

// ---- Models
class DayForecast {
  final DateTime date;
  final double temp;
  final String condition;
  DayForecast(this.date, this.temp, this.condition);
}
class WeatherBundle {
  final String city;
  final double temperature;
  final String condition;
  final List<DayForecast> nextDays;
  WeatherBundle({required this.city, required this.temperature, required this.condition, required this.nextDays});
}

// ---- API
class WeatherRepository {
  final String apiKey;
  WeatherRepository(this.apiKey);

  Future<WeatherBundle> fetchForCity(String city) async {
    final curUrl = "https://api.openweathermap.org/data/2.5/weather?q=$city&units=metric&lang=ru&appid=$apiKey";
    final curRes = await http.get(Uri.parse(curUrl));
    if (curRes.statusCode != 200) throw Exception("Current weather error ${curRes.statusCode}");
    final cur = json.decode(curRes.body);
    final temp = (cur["main"]["temp"] as num).toDouble();
    final cond = cur["weather"][0]["main"] as String;

    final fcUrl = "https://api.openweathermap.org/data/2.5/forecast?q=$city&units=metric&lang=ru&appid=$apiKey";
    final fcRes = await http.get(Uri.parse(fcUrl));
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

    return WeatherBundle(city: data["city"]["name"], temperature: temp, condition: cond, nextDays: forecasts);
  }
}

// ---- Helpers
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
    case "Drizzle": return "rain";
    case "Snow": return "snow";
    case "Thunderstorm":
    case "Drizzle": return "rain";
    default: return "fog";
  }
}

// ---- App
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const WeatherFoxApp());
}

class WeatherFoxApp extends StatelessWidget {
  const WeatherFoxApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Weather Fox',
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3A6E86))),
      home: const WeatherScreen(defaultCity: "Москва", defaultCharacter: CharacterIds.fox),
    );
  }
}

class WeatherScreen extends StatefulWidget {
  final String defaultCity;
  final String defaultCharacter;
  const WeatherScreen({super.key, required this.defaultCity, required this.defaultCharacter});
  @override State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  late final WeatherRepository repo;
  String city = "";
  WeatherBundle? bundle;
  String characterId = CharacterIds.fox;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    repo = WeatherRepository(openWeatherApiKey);
    city = widget.defaultCity;
    characterId = widget.defaultCharacter;
    _load();
  }

  Future<void> _load() async {
    setState(()=> {loading = true, error = null});
    try {
      final b = await repo.fetchForCity(city);
      setState(()=> bundle = b);
    } catch (e) {
      setState(()=> error = e.toString());
    } finally {
      setState(()=> loading = false);
    }
  }

  String sceneFor(String cond, DateTime now) {
    final c = conditionKey(cond);
    final t = appTimeOfDay(now);
    final path = "assets/images/${characterId}_${c}_${t}.png";
    return path;
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

  String weekdayRu(DateTime d) => DateFormat('EE','ru').format(d).toUpperCase();

  @override
  Widget build(BuildContext context) {
    final b = bundle;
    final now = DateTime.now();
    return Scaffold(
      body: Stack(
        children: [
          // Background
          Positioned.fill(
            child: b == null
                ? const ColoredBox(color: Color(0xFF355F5B))
                : Image.asset(
                    sceneFor(b.condition, now),
                    fit: BoxFit.cover,
                  ),
          ),
          // Soft scrim for readability
          Positioned.fill(child: Container(color: Colors.black.withOpacity(0.10))),

          // Content (portrait layout)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : error != null
                      ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text("Не удалось загрузить погоду", style: TextStyle(color: Colors.white)),
                          const SizedBox(height: 8),
                          Text(error!, style: const TextStyle(color: Colors.white70)),
                          const SizedBox(height: 12),
                          FilledButton(onPressed: _load, child: const Text("Повторить")),
                        ]))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Row: City + Temp
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(b!.city, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Colors.white)),
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
                                                  Icon(_iconFor(d.condition), size: 18),
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
                                    Icon(_iconFor(b.condition), color: Colors.white, size: 40),
                                  ],
                                ),
                              ],
                            ),
                            const Spacer(),
                            // Bottom bar: actions
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
