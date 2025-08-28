import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CharacterIds {
  static const fox = 'fox';
  static const spider = 'spider'; // новый вместо енота
  static const robot = 'robot';
}

class Character {
  final String id;
  final String name;
  final String preview; // путь к превью (WebP)
  const Character(this.id, this.name, this.preview);
}

const availableCharacters = <Character>[
  Character(CharacterIds.fox, 'Лисёнок', 'assets/images/fox_clear_day.webp'),
  Character(CharacterIds.spider, 'Паук', 'assets/images/spider_clear_day.webp'),
  Character(CharacterIds.robot, 'Робот', 'assets/images/robot_clear_day.webp'),
];

Future<String> loadSavedCharacter() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('character_id') ?? CharacterIds.fox;
}

Future<void> saveCharacter(String id) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('character_id', id);
}

class CharacterSelectScreen extends StatelessWidget {
  final String selectedId;
  const CharacterSelectScreen({super.key, required this.selectedId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Выбор персонажа')),
      body: GridView.count(
        crossAxisCount: 2,
        padding: const EdgeInsets.all(16),
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        children: [
          for (final c in availableCharacters)
            InkWell(
              onTap: () async {
                await saveCharacter(c.id);
                if (context.mounted) Navigator.pop(context, c.id);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.88),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: selectedId == c.id
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 3,
                  ),
                  boxShadow: const [BoxShadow(blurRadius: 10, color: Colors.black26)],
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.asset(c.preview, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
