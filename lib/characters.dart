/// Идентификаторы и хелперы для персонажей.
/// Структура ассетов предполагается такая:
/// assets/images/<id>/<id>_<condition>[_<season>]_<(morning|day|evening|night)>.webp
///
/// Примеры:
/// assets/images/fox/fox_clear_day.webp
/// assets/images/fox/fox_rain_summer_evening.webp
/// assets/images/robot/robot_clouds_morning.webp
/// assets/images/spider/spider_rain_day.webp
///
/// ВНИМАНИЕ: Имена файлов по-прежнему содержат префикс id (например, fox_...),
/// чтобы существующая логика в main.dart продолжала без правок находить картинки.

class CharacterIds {
  static const String fox = 'fox';
  static const String robot = 'robot';
  static const String spider = 'spider';

  /// Оставляем на всякий случай, если где-то ещё используется.
  /// Если енот больше не нужен — можно удалить из списка `all`.
  static const String raccoon = 'raccoon';

  static const List<String> all = <String>[
    fox,
    robot,
    spider,
    raccoon, // можно убрать, если енота точно нет
  ];

  /// Человекочитаемые названия (на всякий случай).
  static const Map<String, String> displayName = {
    fox: 'Лисёнок',
    robot: 'Робот',
    spider: 'Паук',
    raccoon: 'Енот',
  };

  /// Папка персонажа.
  static String folder(String id) => 'assets/images/$id';

  /// Префикс имени файла (оставляем с id во избежание ломки совместимости).
  static String filePrefix(String id) => id;

  /// Кандидаты путей для сцены по убыванию специфичности.
  /// Example for fox:
  /// assets/images/fox/fox_rain_summer_evening.webp
  static List<String> sceneCandidates({
    required String id,
    required String condition, // clear|clouds|rain|snow|fog...
    required String timeOfDay, // morning|day|evening|night
    String? season,            // winter|spring|summer|autumn|wet|dry (для тропиков)
  }) {
    final base = folder(id);
    final pref = filePrefix(id);

    final List<String> list = [];
    if (season != null && season.isNotEmpty) {
      list.add('$base/${pref}_${condition}_${season}_${timeOfDay}.webp');
    }
    list.add('$base/${pref}_${condition}_${timeOfDay}.webp');
    list.add('$base/${pref}_${condition}_day.webp');
    return list;
  }

  /// Кандидаты для иконки/аватарки (превью персонажа).
  /// Возвращаем список, из которого можно выбрать первый существующий.
  static List<String> avatarCandidates(String id) {
    final base = folder(id);
    final pref = filePrefix(id);
    return <String>[
      '$base/${pref}_clear_day.webp',
      '$base/${pref}_clouds_day.webp',
      '$base/${pref}_rain_day.webp',
      '$base/${pref}_clouds_morning.webp',
    ];
  }

  /// Значение по умолчанию, если ничего не найдено.
  static String fallbackAvatar(String id) =>
      '${folder(id)}/${filePrefix(id)}_clouds_day.webp';

  /// Проверка, что для персонажа вообще есть какие-то ассеты в манифесте.
  static bool hasAnyAssets(String id, Set<String> assetKeys) {
    final base = folder(id) + '/';
    return assetKeys.any((k) => k.startsWith(base));
  }

  /// Попытка угадать лучший аватар по имеющимся ключам ассетов.
  static String bestAvatarFromAssets(String id, Set<String> assetKeys) {
    final cand = avatarCandidates(id);
    for (final p in cand) {
      if (assetKeys.contains(p)) return p;
    }
    // Если ничего из кандидатов — возьмём первый любой из папки персонажа
    final base = folder(id) + '/';
    final any = assetKeys.firstWhere(
          (k) => k.startsWith(base),
      orElse: () => fallbackAvatar(id),
    );
    return any;
  }
}
