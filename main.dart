import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const PosApp());

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const HomePage(),
    );
  }
}

// ───────────── receipt filter (same idea as the Termux script) ─────────────
final List<RegExp> _markers = [
  RegExp(r'TERMINAL', caseSensitive: false),
  RegExp(r'GRAND|TOTALS?', caseSensitive: false),
  RegExp(r'NATIONAL\s*BANK|\bNBE\b', caseSensitive: false),
  RegExp(r'BATCH', caseSensitive: false),
  RegExp(r'MERCHANT', caseSensitive: false),
  RegExp(r'SUCCESSF|CLOSED', caseSensitive: false),
  RegExp(r'\bVISA\b|MASTER|MEZZA|MEEZA|MEEZ', caseSensitive: false),
  RegExp(r'THANK\s*YOU', caseSensitive: false),
];

int receiptScore(String text) => _markers.where((r) => r.hasMatch(text)).length;

// ───────────── files ─────────────
const String root = '/storage/emulated/0';
final String outDirPath = '$root/all/raw_images';
final String seenPath = '$root/all/.app_seen.json';

String baseName(String path) => path.split('/').last;

List<Directory> _subDirs(String path) {
  try {
    return Directory(path).listSync().whereType<Directory>().toList();
  } catch (_) {
    return [];
  }
}

List<Directory> findWhatsAppImageDirs() {
  final out = <Directory>[];
  void addImages(String mediaPath) {
    for (final d in _subDirs(mediaPath)) {
      if (baseName(d.path).endsWith('Images')) out.add(d);
    }
  }

  for (final a in _subDirs('$root/Android/media')) {
    if (!baseName(a.path).startsWith('com.whatsapp')) continue;
    for (final w in _subDirs(a.path)) {
      if (!baseName(w.path).startsWith('WhatsApp')) continue;
      addImages('${w.path}/Media');
      for (final acc in _subDirs('${w.path}/accounts')) {
        addImages('${acc.path}/Media');
      }
    }
  }
  for (final r in _subDirs(root)) {
    if (baseName(r.path).startsWith('WhatsApp')) addImages('${r.path}/Media');
  }
  return out;
}

DateTime fileDate(File f) {
  final m = RegExp(r'-(\d{8})-').firstMatch(baseName(f.path));
  if (m != null) {
    final s = m.group(1)!;
    final d = DateTime.tryParse(
        '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}');
    if (d != null) return d;
  }
  return f.lastModifiedSync();
}

Map<String, dynamic> loadSeen() {
  try {
    return jsonDecode(File(seenPath).readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
}

void saveSeen(Map<String, dynamic> seen) {
  try {
    File(seenPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(seen));
  } catch (_) {}
}

// ───────────── screen ─────────────
class Found {
  final String path;
  final int score;
  Found(this.path, this.score);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int days = 0; // 0 = today
  bool busy = false;
  double progress = 0;
  String status = 'اضغط "فحص الواتساب" لسحب إيصالات الفترة المختارة.';
  final List<Found> found = [];

  Future<void> scan() async {
    setState(() {
      busy = true;
      progress = 0;
      found.clear();
      status = 'طلب إذن الوصول للملفات...';
    });

    final perm = await Permission.manageExternalStorage.request();
    if (!perm.isGranted) {
      setState(() {
        busy = false;
        status = 'لازم تسمح بالوصول لكل الملفات من الإعدادات، وبعدين جرّب تاني.';
      });
      return;
    }

    final dirs = findWhatsAppImageDirs();
    if (dirs.isEmpty) {
      setState(() {
        busy = false;
        status = 'مش لاقي فولدر صور الواتساب.';
      });
      return;
    }

    final now = DateTime.now();
    final cutoff =
        DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
    final seen = loadSeen();
    final todo = <File>[];
    for (final d in dirs) {
      try {
        for (final e in d.listSync().whereType<File>()) {
          final lower = e.path.toLowerCase();
          if (!(lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.png') ||
              lower.endsWith('.webp'))) {
            continue;
          }
          final key = '${baseName(e.path)}:${e.lengthSync()}';
          if (seen.containsKey(key)) continue;
          if (fileDate(e).isBefore(cutoff)) continue;
          todo.add(e);
        }
      } catch (_) {}
    }

    setState(() => status = '${dirs.length} فولدر، ${todo.length} صورة جديدة. جاري الفحص...');
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    Directory(outDirPath).createSync(recursive: true);
    var copied = 0;

    for (var i = 0; i < todo.length; i++) {
      final f = todo[i];
      try {
        final res = await recognizer.processImage(InputImage.fromFilePath(f.path));
        final sc = receiptScore(res.text);
        seen['${baseName(f.path)}:${f.lengthSync()}'] = true;
        if (sc >= 2) {
          final dst = '$outDirPath/wa_${baseName(f.path)}';
          if (!File(dst).existsSync()) {
            f.copySync(dst);
            copied++;
          }
          found.add(Found(f.path, sc));
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        progress = (i + 1) / todo.length;
        status = 'فحص ${i + 1} من ${todo.length}  •  إيصالات: ${found.length}';
      });
    }

    await recognizer.close();
    saveSeen(seen);
    if (!mounted) return;
    setState(() {
      busy = false;
      status = 'خلص: ${todo.length} صورة اتفحصت، ${found.length} إيصال، '
          '$copied اتنسخ لـ all/raw_images (مفيش حاجة اتمسحت من الواتساب).';
    });
  }

  void resetSeen() {
    try {
      File(seenPath).deleteSync();
    } catch (_) {}
    setState(() => status = 'اتمسحت ذاكرة الفحص، المرة الجاية هيفحص من الأول.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إيصالات POS')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final o in const [
                  [0, 'اليوم'],
                  [3, '3 أيام'],
                  [7, 'أسبوع'],
                ])
                  ChoiceChip(
                    label: Text(o[1] as String),
                    selected: days == o[0],
                    onSelected: busy ? null : (_) => setState(() => days = o[0] as int),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : scan,
              icon: const Icon(Icons.search),
              label: const Text('فحص الواتساب'),
            ),
            TextButton(
              onPressed: busy ? null : resetSeen,
              child: const Text('إعادة الفحص من الأول'),
            ),
            if (busy) LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(status),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: found.length,
                itemBuilder: (context, i) {
                  final f = found[i];
                  return ListTile(
                    leading: Image.file(File(f.path),
                        width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 120),
                    title: Text(baseName(f.path)),
                    subtitle: Text('علامات الإيصال: ${f.score}'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
