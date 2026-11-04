import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const PosApp());

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إيصالات POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const HomePage(),
    );
  }
}

// ───────────────────── جداول الماكينات والوحدات ─────────────────────
class TerminalInfo {
  final int orderNum;
  final int excelRow;
  final String unitName;
  const TerminalInfo(this.orderNum, this.excelRow, this.unitName);
}

final Map<String, TerminalInfo> terminals = {
  "50335710": const TerminalInfo(1, 2, "أبيس"),
  "50335993": const TerminalInfo(2, 2, "أبيس"),
  "50335987": const TerminalInfo(3, 2, "أبيس"),
  "50325716": const TerminalInfo(4, 3, "برج العرب"),
  "50335998": const TerminalInfo(5, 3, "برج العرب"),
  "50335994": const TerminalInfo(6, 3, "برج العرب"),
  "50335711": const TerminalInfo(7, 3, "برج العرب"),
  "50382298": const TerminalInfo(8, 4, "المنتزه"),
  "50382315": const TerminalInfo(9, 4, "المنتزه"), // منتزه 2 الجديدة
  "50383712": const TerminalInfo(9, 4, "المنتزه"), // منتزه 2 الاحتياطية/القديمة
  "50382306": const TerminalInfo(10, 5, "محرم بك"),
  "50382316": const TerminalInfo(11, 5, "محرم بك"),
  "50382308": const TerminalInfo(12, 6, "العجمي"),
  "50383706": const TerminalInfo(13, 6, "العجمي"),
  "50382300": const TerminalInfo(14, 7, "القباري"),
  "50383702": const TerminalInfo(15, 8, "مصطفى كامل"),
  "50382312": const TerminalInfo(16, 9, "مديرية الأمن"),
  "50383699": const TerminalInfo(17, 10, "ميناء الإسكندرية"),
  "50383700": const TerminalInfo(18, 11, "مجمع خدمات"),
};

final Map<int, String> numToTid = {
  1: "50335710",
  2: "50335993",
  3: "50335987",
  4: "50325716",
  5: "50335998",
  6: "50335994",
  7: "50335711",
  8: "50382298",
  9: "50382315", // منتزه 2
  10: "50382306",
  11: "50382316",
  12: "50382308",
  13: "50383706",
  14: "50382300",
  15: "50383702",
  16: "50382312",
  17: "50383699",
  18: "50383700",
};

final Map<String, String> tidFix = {
  "50336994": "50335994",
  "50336711": "50335711",
  "50336998": "50335998",
  "50302316": "50382316",
  "50382318": "50382315",
  "50330987": "50335987",
  "60382308": "50382308",
};

final Map<String, int> merchantCodeMap = {
  "22": 2, "23": 3, "24": 4, "25": 5, "26": 6,
  "27": 7, "28": 8, "29": 9, "30": 10, "31": 11,
};

final List<MapEntry<List<String>, int>> nameHints = [
  MapEntry(["ABYSS", "ABIS"], 2),
  MapEntry(["BURJ", "BORG"], 3),
  MapEntry(["MONTZAH", "TOSUN", "WAHDI", "WAHUT"], 4),
  MapEntry(["MUHRAM", "MOHARAM"], 5),
  MapEntry(["AJAMI", "AGAMI"], 6),
  MapEntry(["KABBARY", "KABARY"], 7),
  MapEntry(["MUSTAFA", "KAMEL"], 8),
  MapEntry(["MODRYT", "MODERYT"], 9),
  MapEntry(["ALEXANDRIA PORT", "ESMAT"], 10),
  MapEntry(["EC ESC", "ELZREA", "ESC ALEX", "KHADAMAT"], 11),
];

final Map<int, String> rowNames = {
  2: "أبيس", 3: "برج العرب", 4: "المنتزه", 5: "محرم بك",
  6: "العجمي", 7: "القباري", 8: "مصطفى كامل", 9: "مديرية الأمن",
  10: "ميناء الإسكندرية", 11: "مجمع خدمات",
};

// ───────────────────── تنظيف نصوص OCR ─────────────────────
String normalizeOcrText(String text) {
  var s = text;
  s = s.replaceAllMapped(RegExp(r'(\d)\s*/\s*(\d)'), (m) => '${m.group(1)}7${m.group(2)}');
  s = s.replaceAllMapped(RegExp(r'\bB(\d{2,3}[.,]\d{2})\b'), (m) => '8${m.group(1)}');
  return s;
}

// ───────────────────── خوارزميات الاستخراج المطابقة للبايثون ─────────────────────
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

int receiptScore(String rawText) {
  final text = normalizeOcrText(rawText);
  return _markers.where((r) => r.hasMatch(text)).length +
      (findTerminal(text) != null ? 1 : 0);
}

String? findTerminal(String rawText) {
  final text = normalizeOcrText(rawText);
  final m = RegExp(r"TERMINAL\s*(?:ID)?\D{0,15}?(\d[\d\s/]{6,10}\d)", caseSensitive: false)
      .firstMatch(text);
  if (m != null) {
    var clean = m.group(1)!.replaceAll('/', '7').replaceAll(RegExp(r'\D'), '');
    if (clean.length >= 8) {
      var d = clean.substring(clean.length - 8);
      d = tidFix[d] ?? d;
      if (terminals.containsKey(d)) return d;
    }
  }
  for (final tid in terminals.keys) {
    if (text.contains(tid)) return tid;
  }
  for (final match in RegExp(r"\b([56]03\d{5})\b").allMatches(text)) {
    var c = match.group(1)!;
    c = tidFix[c] ?? c;
    if (terminals.containsKey(c)) return c;
  }
  return null;
}

String? findTerminalFuzzy(String rawText, int? targetRow) {
  final text = normalizeOcrText(rawText);
  final pool = terminals.entries
      .where((e) => targetRow == null || e.value.excelRow == targetRow)
      .map((e) => e.key)
      .toList();

  final dist = <String, int>{};
  final runs = RegExp(r"\d[\d /]{6,14}\d").allMatches(text);

  for (final run in runs) {
    final digits = run.group(0)!.replaceAll('/', '7').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8) continue;
    for (var i = 0; i <= digits.length - 8; i++) {
      final cand = digits.substring(i, i + 8);
      if (!cand.startsWith("50") && !cand.startsWith("60")) continue;
      for (final tid in pool) {
        int d = 0;
        for (var k = 0; k < 8; k++) {
          if (cand[k] != tid[k]) d++;
        }
        if (d < (dist[tid] ?? 99)) {
          dist[tid] = d;
        }
      }
    }
  }
  if (dist.isEmpty) return null;
  final best = dist.values.reduce(min);
  final winners = dist.entries.where((e) => e.value == best).map((e) => e.key).toList();
  if (best <= 1 && winners.length == 1) {
    return winners.first;
  }
  return null;
}

int? findUnitByExtra(String rawText) {
  final text = normalizeOcrText(rawText);
  final m = RegExp(r"MERCHANT\s*(?:ID|10)\D{0,15}?(\d[\d\s/]{8,14}\d)", caseSensitive: false)
      .firstMatch(text);
  final cands = <String>[];
  if (m != null) {
    cands.add(m.group(1)!.replaceAll('/', '7').replaceAll(RegExp(r'\D'), ''));
  }
  cands.add(text.replaceAll('/', '7').replaceAll(RegExp(r'\D'), ''));

  for (final d in cands) {
    final mm = RegExp(r"11470?(2[2-9]|3[01])084").firstMatch(d);
    if (mm != null && merchantCodeMap.containsKey(mm.group(1))) {
      return merchantCodeMap[mm.group(1)];
    }
  }

  final up = text.toUpperCase();
  for (final hint in nameHints) {
    if (hint.key.any((w) => up.contains(w))) {
      return hint.value;
    }
  }
  return null;
}

String? findDate(String text) {
  final m = RegExp(r"DATE\s*:?\s*(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})", caseSensitive: false)
      .firstMatch(text);
  if (m != null) {
    final mo = int.tryParse(m.group(2)!) ?? 0;
    final d = int.tryParse(m.group(3)!) ?? 0;
    if (mo > 0 && d > 0) return "$d.$mo";
  }
  return null;
}

String? findBatchNo(String text) {
  final m = RegExp(r"BATCH\s*NO\D{0,6}(\d{4,7})", caseSensitive: false).firstMatch(text);
  return m?.group(1);
}

final RegExp _amountRe = RegExp(r"(?<![\d,.])(\d{1,3}(?:[.,\s]\d{3})*|\d+)[.,\s](\d{2})(?!\d)");
final RegExp _brandRe = RegExp(r"\b(VISA|MASTER(?:CARD)?|MEZZA|MEEZA|MEZA|MEZZ4|MEZZ)\b", caseSensitive: false);

List<double> amountsIn(String rawText) {
  final text = normalizeOcrText(rawText);
  final out = <double>[];
  for (final m in _amountRe.allMatches(text)) {
    try {
      final whole = m.group(1)!.replaceAll(RegExp(r'[.,\s]'), '');
      final dec = m.group(2)!;
      final v = double.tryParse("$whole.$dec");
      if (v != null && v >= 0.5 && v <= 5000000) {
        out.add(round2(v));
      }
    } catch (_) {}
  }
  return out;
}

double? modeValue(List<double> vals) {
  if (vals.isEmpty) return null;
  final counts = <double, int>{};
  for (final v in vals) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  var bestVal = vals.first;
  var bestCnt = 0;
  for (final e in counts.entries) {
    if (e.value > bestCnt) {
      bestCnt = e.value;
      bestVal = e.key;
    }
  }
  return bestVal;
}

class AmountDecision {
  final double amount;
  final bool confirmed;
  const AmountDecision(this.amount, this.confirmed);
}

AmountDecision extractReceiptAmountPythonStyle(String rawText) {
  final txt = normalizeOcrText(rawText);

  final stopMatch = RegExp(r"THANK\s*YOU|Hotline|App\s*Versi", caseSensitive: false).firstMatch(txt);
  final t = stopMatch != null ? txt.substring(0, stopMatch.start) : txt;

  final gm = RegExp(r"GRAND|TOTALS", caseSensitive: false).firstMatch(t);
  String pre = gm != null ? t.substring(0, gm.start) : t;
  String post = gm != null ? t.substring(gm.start) : "";

  final bm = _brandRe.firstMatch(pre);
  if (bm != null) {
    pre = pre.substring(bm.start);
  } else {
    final sm = RegExp(r"SUCCESSFULL?Y|CLOSED", caseSensitive: false).firstMatch(pre);
    if (sm != null) {
      pre = pre.substring(sm.end);
    }
  }

  final brandMatches = _brandRe.allMatches(pre).toList();
  final sections = <String>[];
  if (brandMatches.isNotEmpty) {
    for (var i = 0; i < brandMatches.length; i++) {
      final start = brandMatches[i].end;
      final end = (i + 1 < brandMatches.length) ? brandMatches[i + 1].start : pre.length;
      sections.add(pre.substring(start, end));
    }
  } else {
    sections.add(pre);
  }

  final brandVals = <double>[];
  for (final sec in sections) {
    final mv = modeValue(amountsIn(sec));
    if (mv != null) brandVals.add(mv);
  }

  final grand = amountsIn(post);
  final brandSum = brandVals.isNotEmpty ? round2(brandVals.fold(0.0, (a, b) => a + b)) : null;

  if (brandSum != null && grand.any((g) => (g - brandSum).abs() < 0.005)) {
    return AmountDecision(brandSum, true);
  }

  if (brandSum != null && brandVals.length >= 2) {
    final sb = brandSum.toStringAsFixed(2);
    for (final g in grand) {
      final sa = g.toStringAsFixed(2);
      if (sa.length == sb.length) {
        int diff = 0;
        for (var k = 0; k < sa.length; k++) {
          if (sa[k] != sb[k]) diff++;
        }
        if (diff == 1) {
          return AmountDecision(brandSum, true);
        }
      }
    }
  }

  if (grand.isNotEmpty) {
    final counts = <double, int>{};
    for (final g in grand) {
      counts[g] = (counts[g] ?? 0) + 1;
    }
    final topGrand = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (topGrand.value >= 2) {
      return AmountDecision(topGrand.key, brandSum == null);
    }
  }

  if (brandSum != null && brandVals.length >= 2) {
    return AmountDecision(brandSum, true);
  }

  final pool = <double>[...grand];
  if (brandSum != null) pool.add(brandSum);
  final voted = modeValue(pool);
  if (voted != null) {
    return AmountDecision(voted, false);
  }

  return const AmountDecision(0.0, false);
}

double round2(double val) => double.parse(val.toStringAsFixed(2));

// ───────────────────── مسارات المجلدات والملفات المساعدة ─────────────────────
const String root = '/storage/emulated/0';
final String baseDir = '$root/all';
final String rawImagesDir = '$baseDir/raw_images';
final String outputDir = '$baseDir/output';
final String cfgPath = '$baseDir/.app_cfg.json';
final String fixPath = '$baseDir/.pos_fix.json';
final String ignorePath = '$baseDir/ignore.txt';

String baseName(String path) => path.split('/').last;

String fileKey(String path) {
  final bytes = File(path).readAsBytesSync();
  return 'v4${crypto.md5.convert(bytes)}';
}

Map<String, dynamic> loadFixes() {
  try {
    final f = File(fixPath);
    if (f.existsSync()) {
      return Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
    }
  } catch (_) {}
  return {};
}

void saveFixes(Map<String, dynamic> fixes) {
  try {
    File(fixPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(fixes));
  } catch (_) {}
}

Set<int> loadIgnoreList() {
  try {
    final f = File(ignorePath);
    if (f.existsSync()) {
      return RegExp(r'\d+')
          .allMatches(f.readAsStringSync())
          .map((m) => int.parse(m.group(0)!))
          .toSet();
    }
  } catch (_) {}
  return {};
}

List<Directory> _subDirs(String path) {
  try {
    final dir = Directory(path);
    if (!dir.existsSync()) return [];
    return dir.listSync().whereType<Directory>().toList();
  } catch (_) {
    return [];
  }
}

List<Directory> findWhatsAppImageDirs() {
  final out = <Directory>[];
  void checkAndAdd(String p) {
    final d = Directory(p);
    if (d.existsSync() && !out.any((x) => x.path == d.path)) {
      out.add(d);
    }
  }

  checkAndAdd('$root/Android/media/com.whatsapp/WhatsApp/accounts/1003/Media/WhatsApp Images');
  checkAndAdd('$root/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images');
  checkAndAdd('$root/WhatsApp/Media/WhatsApp Images');

  final mediaDir = Directory('$root/Android/media');
  if (mediaDir.existsSync()) {
    for (final pkg in _subDirs(mediaDir.path)) {
      if (baseName(pkg.path).toLowerCase().contains('whatsapp')) {
        checkAndAdd('${pkg.path}/Media/WhatsApp Images');
        checkAndAdd('${pkg.path}/WhatsApp/Media/WhatsApp Images');
        for (final acc in _subDirs('${pkg.path}/WhatsApp/accounts')) {
          checkAndAdd('${acc.path}/Media/WhatsApp Images');
        }
        for (final acc in _subDirs('${pkg.path}/accounts')) {
          checkAndAdd('${acc.path}/Media/WhatsApp Images');
        }
      }
    }
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

String? loadFolder() {
  try {
    return (jsonDecode(File(cfgPath).readAsStringSync()) as Map)['folder'] as String?;
  } catch (_) {
    return null;
  }
}

void saveFolder(String? f) {
  try {
    File(cfgPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'folder': f}));
  } catch (_) {}
}

// ───────────────────── نموذج الإيصال الشامل ─────────────────────
class ReceiptItem {
  String fn;
  String path;
  String? key;
  String? tid;
  String? origTid;
  int? orderNum;
  int? suffix;
  int? row;
  String? unitName;
  double amount;
  bool confirmed;
  String how;
  String? date;
  String? batchNo;
  bool skip;
  bool conflict;
  String? newName;

  ReceiptItem({
    required this.fn,
    required this.path,
    this.key,
    this.tid,
    this.origTid,
    this.orderNum,
    this.suffix,
    this.row,
    this.unitName,
    this.amount = 0.0,
    this.confirmed = false,
    this.how = "none",
    this.date,
    this.batchNo,
    this.skip = false,
    this.conflict = false,
    this.newName,
  });

  String get displayOrder =>
      orderNum != null ? (suffix != null ? '${orderNum}_$suffix' : '$orderNum') : '؟';
}

// ───────────────────── الشاشة الرئيسية ─────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int days = 0;
  String? customDir;
  bool busy = false;
  double progress = 0;
  String status = 'اضغط "بدء المعالجة الشاملة" لسحب الصور وتوليد الإكسيل والـ PDF.';
  final List<ReceiptItem> processedItems = [];
  final List<String> warnings = [];
  String? standardXlsxPath;
  String? advancedXlsxPath;
  String? generatedPdfPath;
  String? reportTxtPath;
  List<int> missingTerminals = [];

  @override
  void initState() {
    super.initState();
    customDir = loadFolder();
  }

  Future<void> pickFolder() async {
    final perm = await Permission.manageExternalStorage.request();
    if (!perm.isGranted) {
      setState(() => status = 'لازم تسمح بالوصول لكل الملفات الأول.');
      return;
    }
    if (!mounted) return;
    final res = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FolderPicker(start: customDir ?? root)),
    );
    if (res != null) {
      saveFolder(res);
      setState(() => customDir = res);
    }
  }

  void useWhatsApp() {
    saveFolder(null);
    setState(() => customDir = null);
  }

  Future<void> shareStandardFiles() async {
    final files = <XFile>[];
    if (standardXlsxPath != null && File(standardXlsxPath!).existsSync()) {
      files.add(XFile(standardXlsxPath!));
    }
    if (generatedPdfPath != null && File(generatedPdfPath!).existsSync()) {
      files.add(XFile(generatedPdfPath!));
    }
    if (files.isNotEmpty) {
      await Share.shareXFiles(files, text: 'تقرير إيصالات الإسكندرية (الرسمي)');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لم يتم إنشاء ملفات بعد لمشاركتها.')),
      );
    }
  }

  Future<void> shareAdvancedFile() async {
    final files = <XFile>[];
    if (advancedXlsxPath != null && File(advancedXlsxPath!).existsSync()) {
      files.add(XFile(advancedXlsxPath!));
    }
    if (reportTxtPath != null && File(reportTxtPath!).existsSync()) {
      files.add(XFile(reportTxtPath!));
    }
    if (files.isNotEmpty) {
      await Share.shareXFiles(files, text: 'تقرير إيصالات POS الشامل وتقرير المراجعة');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('التقرير الشامل غير متاح حالياً.')),
      );
    }
  }

  void assignTerminalsStage2(List<ReceiptItem> recs) {
    warnings.clear();
    for (final r in recs) {
      r.skip = false;
      r.conflict = false;
      r.suffix = null;
      if (r.origTid != null && r.tid == null) {
        r.tid = r.origTid;
      }
    }

    const prio = {"manual": 0, "terminal": 0, "fuzzy": 1, "file-number": 2};
    final taken = <String, ReceiptItem>{};

    final withTid = recs.where((x) => x.tid != null).toList()
      ..sort((a, b) => (prio[a.how] ?? 3).compareTo(prio[b.how] ?? 3));

    for (final r in withTid) {
      final t = r.tid!;
      if (!taken.containsKey(t)) {
        taken[t] = r;
      } else if (r.amount > 0 && (taken[t]!.amount - r.amount).abs() < 0.005) {
        r.skip = true;
        warnings.add("${r.fn}: مكرر نفس الماكينة $t ونفس المبلغ ${r.amount.toStringAsFixed(2)} - تم استبعاده");
      } else {
        r.origTid = r.tid;
        r.tid = null;
        r.conflict = true;
      }
    }

    final usedSuffix = <String>{};
    void giveSuffix(ReceiptItem r, String targetTid) {
      var k = 2;
      while (usedSuffix.contains('${targetTid}_$k')) {
        k++;
      }
      usedSuffix.add('${targetTid}_$k');
      r.tid = targetTid;
      r.orderNum = terminals[targetTid]!.orderNum;
      r.suffix = k;
      r.how = "extra-batch";
    }

    for (final r in recs) {
      if (r.skip || r.tid != null || r.row == null) continue;

      if (r.conflict && (r.how == "terminal" || r.how == "fuzzy") && r.origTid != null) {
        giveSuffix(r, r.origTid!);
        continue;
      }

      final freeEntries = terminals.entries
          .where((kv) => kv.value.excelRow == r.row && !taken.containsKey(kv.key))
          .toList()
        ..sort((a, b) => a.value.orderNum.compareTo(b.value.orderNum));

      if (freeEntries.isNotEmpty) {
        final chosenTid = freeEntries.first.key;
        r.tid = chosenTid;
        r.orderNum = freeEntries.first.value.orderNum;
        taken[chosenTid] = r;
        r.how = r.conflict ? "conflict" : "auto-number";
      } else if (r.origTid != null) {
        giveSuffix(r, r.origTid!);
      } else {
        final unitEntries = terminals.entries
            .where((kv) => kv.value.excelRow == r.row)
            .toList()
          ..sort((a, b) => a.value.orderNum.compareTo(b.value.orderNum));
        if (unitEntries.isNotEmpty) {
          giveSuffix(r, unitEntries.last.key);
        }
      }
    }

    for (final r in recs) {
      if (r.tid != null && terminals.containsKey(r.tid)) {
        r.orderNum = terminals[r.tid]!.orderNum;
        r.row = terminals[r.tid]!.excelRow;
        r.unitName = terminals[r.tid]!.unitName;
      }
    }
  }

  Future<void> editReceiptDialog(ReceiptItem item) async {
    final amtController = TextEditingController(text: item.amount.toStringAsFixed(2));
    int? selectedOrder = item.orderNum;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('تعديل بيانات الإيصال (يُحفظ تلقائياً)'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.file(File(item.path), height: 180, fit: BoxFit.contain),
                const SizedBox(height: 8),
                TextField(
                  controller: amtController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'المبلغ الإجمالي الصحيح'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  value: selectedOrder,
                  hint: const Text('اختر الماكينة (1..18)'),
                  items: [
                    for (var i = 1; i <= 18; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text('ماكينة $i - ${rowNames[terminals[numToTid[i]]!.excelRow]}'),
                      ),
                  ],
                  onChanged: (v) => setDlgState(() => selectedOrder = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                final newAmt = double.tryParse(amtController.text.replaceAll(',', '')) ?? item.amount;
                setState(() {
                  item.amount = round2(newAmt);
                  item.confirmed = true;
                  item.how = "manual";
                  item.skip = false;
                  if (selectedOrder != null) {
                    item.orderNum = selectedOrder;
                    item.tid = numToTid[selectedOrder];
                    item.origTid = item.tid;
                    item.row = terminals[item.tid]!.excelRow;
                    item.unitName = terminals[item.tid]!.unitName;
                  }
                  if (item.key != null && item.row != null) {
                    final fixes = loadFixes();
                    fixes[item.key!] = {
                      "val": item.amount,
                      "tid": item.tid,
                      "row": item.row,
                      "date": item.date,
                    };
                    saveFixes(fixes);
                  }
                });
                Navigator.pop(ctx);
                assignTerminalsStage2(processedItems);
                rebuildFiles();
              },
              child: const Text('حفظ وتحديث الملفات'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> rebuildFiles() async {
    setState(() => status = 'جاري إعادة التسمية وتوليد الملفات...');

    final dateCounts = <String, int>{};
    for (final r in processedItems) {
      if (!r.skip && r.date != null) {
        dateCounts[r.date!] = (dateCounts[r.date!] ?? 0) + 1;
      }
    }
    String reportDate = "today";
    if (dateCounts.isNotEmpty) {
      reportDate = dateCounts.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    }

    for (var k = 0; k < processedItems.length; k++) {
      final r = processedItems[k];
      final ext = r.path.split('.').last.toLowerCase();
      String targetName;
      if (r.skip) {
        targetName = 'dup_${baseName(r.path)}';
      } else if (r.orderNum != null) {
        final sfx = r.suffix != null ? '_${r.suffix}' : '';
        targetName = '${r.orderNum}$sfx.$ext';
      } else {
        continue;
      }
      r.newName = targetName;
      final newPath = '$rawImagesDir/$targetName';
      if (r.path != newPath && File(r.path).existsSync()) {
        try {
          final tmpPath = '$rawImagesDir/__tmp_${k}_${DateTime.now().millisecondsSinceEpoch}.$ext';
          final fTmp = File(r.path).renameSync(tmpPath);
          if (File(newPath).existsSync()) {
            File(newPath).deleteSync();
          }
          final fFinal = fTmp.renameSync(newPath);
          r.path = fFinal.path;
        } catch (_) {}
      }
    }

    processedItems.sort((a, b) {
      if (a.skip != b.skip) return a.skip ? 1 : -1;
      final c1 = (a.orderNum ?? 99).compareTo(b.orderNum ?? 99);
      if (c1 != 0) return c1;
      return (a.suffix ?? 0).compareTo(b.suffix ?? 0);
    });

    final pdf = pw.Document();
    for (final r in processedItems.where((x) => !x.skip && x.orderNum != null)) {
      if (File(r.path).existsSync()) {
        try {
          final imgBytes = File(r.path).readAsBytesSync();
          final imgWidget = pw.MemoryImage(imgBytes);
          pdf.addPage(
            pw.Page(
              pageFormat: PdfPageFormat.a4,
              build: (pw.Context ctx) => pw.Center(child: pw.Image(imgWidget, fit: pw.BoxFit.contain)),
            ),
          );
        } catch (_) {}
      }
    }
    final pdfOutFile = File('$outputDir/الاسكندريه $reportDate.pdf');
    await pdfOutFile.writeAsBytes(await pdf.save());
    generatedPdfPath = pdfOutFile.path;

    final unitTotals = <int, double>{for (var r = 2; r <= 11; r++) r: 0.0};
    final unitCounts = <int, int>{for (var r = 2; r <= 11; r++) r: 0};

    for (final item in processedItems) {
      if (!item.skip && item.row != null && item.amount > 0) {
        unitTotals[item.row!] = round2((unitTotals[item.row!] ?? 0.0) + item.amount);
        unitCounts[item.row!] = (unitCounts[item.row!] ?? 0) + 1;
      }
    }

    File? tplFile;
    for (final d in [baseDir, rawImagesDir, outputDir]) {
      final exact = File('$d/الاسكندريه 00.xlsx');
      if (exact.existsSync()) {
        tplFile = exact;
        break;
      }
    }

    if (tplFile != null) {
      try {
        final bytes = tplFile.readAsBytesSync();
        final excel = xl.Excel.decodeBytes(bytes);
        final defaultSheet = excel.tables.keys.first;
        final sheet = excel[defaultSheet];

        for (var r = 2; r <= 11; r++) {
          final tot = round2(unitTotals[r] ?? 0.0);
          final cellD = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: r - 1));
          cellD.value = xl.DoubleCellValue(tot);

          final cellF = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: r - 1));
          cellF.value = xl.FormulaCellValue('=D$r+IF(ISBLANK(E$r),0,E$r)');
        }

        final excelOutBytes = excel.encode();
        if (excelOutBytes != null) {
          final stdFile = File('$outputDir/الاسكندريه $reportDate.xlsx');
          stdFile.createSync(recursive: true);
          stdFile.writeAsBytesSync(excelOutBytes);
          standardXlsxPath = stdFile.path;
        }
      } catch (_) {}

      try {
        final bytesAdv = tplFile.readAsBytesSync();
        final excelAdv = xl.Excel.decodeBytes(bytesAdv);
        final defaultSheet = excelAdv.tables.keys.first;
        final sheetAdv = excelAdv[defaultSheet];

        double grandPos = 0.0;
        for (var r = 2; r <= 11; r++) {
          final tot = round2(unitTotals[r] ?? 0.0);
          grandPos += tot;
          sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: r - 1)).value =
              xl.DoubleCellValue(tot);
          sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: r - 1)).value =
              xl.DoubleCellValue(tot);
        }

        const rowTotalIndex = 11;
        sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowTotalIndex)).value =
            xl.TextCellValue('الإجمالي العام');
        sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowTotalIndex)).value =
            xl.IntCellValue(18);
        sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowTotalIndex)).value =
            xl.DoubleCellValue(round2(grandPos));

        final detailSheet = excelAdv['تفاصيل الماكينات'];
        final headers = ['رقم الترتيب', 'اسم الوحدة', 'TID الماكينة', 'المبلغ (ج.م)', 'طريقة التعرف / الحالة'];
        for (var c = 0; c < headers.length; c++) {
          detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0)).value =
              xl.TextCellValue(headers[c]);
        }

        var rowIdx = 1;
        for (var i = 1; i <= 18; i++) {
          final currentTid = numToTid[i]!;
          final info = terminals[currentTid]!;
          final matched = processedItems.where((e) => !e.skip && e.orderNum == i).toList();

          if (matched.isEmpty) {
            detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIdx)).value =
                xl.TextCellValue('$i');
            detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIdx)).value =
                xl.TextCellValue(info.unitName);
            detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowIdx)).value =
                xl.TextCellValue(currentTid);
            detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowIdx)).value =
                xl.DoubleCellValue(0.0);
            detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowIdx)).value =
                xl.TextCellValue('⚠️ غير وارد (مفقود)');
            rowIdx++;
          } else {
            for (final m in matched) {
              detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIdx)).value =
                  xl.TextCellValue(m.displayOrder);
              detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIdx)).value =
                  xl.TextCellValue(info.unitName);
              detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowIdx)).value =
                  xl.TextCellValue(m.tid ?? currentTid);
              detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowIdx)).value =
                  xl.DoubleCellValue(round2(m.amount));
              detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowIdx)).value =
                  xl.TextCellValue('${m.confirmed ? "✓ مؤكد" : "⚠️ يحتاج مراجعة"} (${m.how})');
              rowIdx++;
            }
          }
        }

        final advBytes = excelAdv.encode();
        if (advBytes != null) {
          final advFile = File('$outputDir/تقرير_شامل_POS_$reportDate.xlsx');
          advFile.createSync(recursive: true);
          advFile.writeAsBytesSync(advBytes);
          advancedXlsxPath = advFile.path;
        }
      } catch (_) {}
    }

    final ignoreSet = loadIgnoreList();
    final foundOrders = processedItems
        .where((e) => !e.skip && e.orderNum != null && e.amount > 0)
        .map((e) => e.orderNum!)
        .toSet();
    missingTerminals = [
      for (var i = 1; i <= 18; i++)
        if (!foundOrders.contains(i) && !ignoreSet.contains(i)) i
    ];

    final lines = <String>[
      "Review report - $reportDate",
      "=" * 60,
      "",
    ];
    for (final r in processedItems) {
      final name = r.newName ?? r.fn;
      final flags = <String>[];
      if (r.skip) flags.add("duplicate - removed");
      if (r.amount <= 0) flags.add("amount unreadable");
      if (r.row == null) flags.add("unit unknown");
      if (!r.confirmed && r.amount > 0) flags.add("amount needs checking");
      if (["auto-number", "conflict", "extra-batch", "name/merchant", "fuzzy"].contains(r.how)) {
        flags.add("terminal set by ${r.how}");
      }
      if (r.date != null && r.date != reportDate) {
        flags.add("date ${r.date} (expected $reportDate)");
      }
      final mark = flags.isNotEmpty ? "⚠️" : "✓ ";
      lines.add(
          "$mark ${name.padRight(14)} ${(r.unitName ?? '??').padRight(18)} ${r.amount.toStringAsFixed(2).padLeft(12)}"
          "${flags.isNotEmpty ? '   [${flags.join(' | ')}]' : ''}");
    }
    final grandSum = unitTotals.values.fold(0.0, (a, b) => a + b);
    lines.addAll(["", "=" * 60, "Grand total: ${grandSum.toStringAsFixed(2)} EGP"]);
    if (missingTerminals.isNotEmpty) {
      lines.add("");
      lines.add("Missing terminals: " +
          missingTerminals.map((n) => "$n (${rowNames[terminals[numToTid[n]]!.excelRow]})").join(", "));
    }
    final repFile = File('$outputDir/review_report.txt');
    repFile.writeAsStringSync(lines.join("\n"));
    reportTxtPath = repFile.path;

    setState(() => status = 'اكتمل بنجاح! الإجمالي العام: ${grandSum.toStringAsFixed(2)} ج.م\n'
        '• التقرير الرسمي: الاسكندريه $reportDate.xlsx\n'
        '• ملف الـ PDF وتقرير المراجعة جاهزون للمشاركة.');
  }

  Future<void> runFullPipeline() async {
    final perm = await Permission.manageExternalStorage.request();
    if (!perm.isGranted) {
      setState(() => status = 'يجب منح إذن الوصول إلى جميع الملفات للمتابعة.');
      return;
    }

    setState(() {
      busy = true;
      progress = 0;
      processedItems.clear();
      missingTerminals.clear();
      warnings.clear();
      status = 'جاري البحث عن الصور...';
    });

    final dirs = customDir != null ? [Directory(customDir!)] : findWhatsAppImageDirs();
    if (dirs.isEmpty) {
      setState(() {
        busy = false;
        status = 'تعذر العثور على مجلد الصور.';
      });
      return;
    }

    final now = DateTime.now();
    final cutoff = days < 0
        ? DateTime(2000)
        : DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
    final todo = <File>[];

    for (final d in dirs) {
      try {
        for (final e in d.listSync().whereType<File>()) {
          final fn = baseName(e.path);
          if (fn.startsWith('.') || fn.startsWith('dup_')) continue;
          final lower = fn.toLowerCase();
          if (!(lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.png') ||
              lower.endsWith('.webp'))) {
            continue;
          }
          if (customDir == null && fileDate(e).isBefore(cutoff)) continue;
          todo.add(e);
        }
      } catch (_) {}
    }

    if (todo.isEmpty) {
      setState(() {
        busy = false;
        status = 'لا توجد صور في الفترة المحددة.';
      });
      return;
    }

    final fixes = loadFixes();
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    Directory(rawImagesDir).createSync(recursive: true);
    Directory(outputDir).createSync(recursive: true);

    final rawReceipts = <ReceiptItem>[];
    final seenBatchKey = <String>{};

    for (var i = 0; i < todo.length; i++) {
      final f = todo[i];
      try {
        final key = fileKey(f.path);

        if (fixes.containsKey(key)) {
          final fx = Map<String, dynamic>.from(fixes[key] as Map);
          final dst = f.parent.path == rawImagesDir ? f.path : '$rawImagesDir/wa_${baseName(f.path)}';
          final localFile = File(dst).existsSync() ? File(dst) : f.copySync(dst);
          final tid = fx['tid'] as String?;
          final row = fx['row'] as int?;
          rawReceipts.add(ReceiptItem(
            fn: baseName(localFile.path),
            path: localFile.path,
            key: key,
            tid: tid,
            origTid: tid,
            orderNum: tid != null ? terminals[tid]?.orderNum : null,
            row: row,
            unitName: row != null ? rowNames[row] : null,
            amount: (fx['val'] as num).toDouble(),
            confirmed: true,
            how: "manual",
            date: fx['date'] as String?,
          ));
          continue;
        }

        final res = await recognizer.processImage(InputImage.fromFilePath(f.path));
        final sc = receiptScore(res.text);

        if (sc >= 2 || customDir == rawImagesDir) {
          final dst = f.parent.path == rawImagesDir ? f.path : '$rawImagesDir/wa_${baseName(f.path)}';
          final localFile = File(dst).existsSync() ? File(dst) : f.copySync(dst);
          final fn = baseName(localFile.path);
          final nameOnly = fn.contains('.') ? fn.substring(0, fn.lastIndexOf('.')) : fn;

          final decision = extractReceiptAmountPythonStyle(res.text);
          final bNo = findBatchNo(res.text);

          var tid = findTerminal(res.text);
          var how = tid != null ? "terminal" : "none";
          int? row;
          String? uName;
          int? order;

          final extraRow = findUnitByExtra(res.text);
          if (tid == null) {
            tid = findTerminalFuzzy(res.text, extraRow);
            if (tid != null) how = "fuzzy";
          }

          if (tid != null && terminals.containsKey(tid)) {
            final info = terminals[tid]!;
            order = info.orderNum;
            row = info.excelRow;
            uName = info.unitName;
          } else if (extraRow != null) {
            row = extraRow;
            uName = rowNames[extraRow];
            how = "name/merchant";
          }

          final fnNum = int.tryParse(nameOnly);
          if (tid == null && fnNum != null && numToTid.containsKey(fnNum)) {
            final ft = numToTid[fnNum]!;
            if (row == null || terminals[ft]!.excelRow == row) {
              tid = ft;
              order = terminals[ft]!.orderNum;
              row = terminals[ft]!.excelRow;
              uName = terminals[ft]!.unitName;
              how = "file-number";
            }
          }

          if (bNo != null && decision.amount > 0) {
            final bKey = '${tid ?? row}_${bNo}_${decision.amount.toStringAsFixed(2)}';
            if (seenBatchKey.contains(bKey)) continue;
            seenBatchKey.add(bKey);
          }

          rawReceipts.add(ReceiptItem(
            fn: fn,
            path: localFile.path,
            key: key,
            tid: tid,
            origTid: tid,
            orderNum: order,
            row: row,
            unitName: uName,
            amount: decision.amount,
            confirmed: decision.confirmed,
            how: how,
            date: findDate(res.text),
            batchNo: bNo,
          ));
        }
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        progress = ((i + 1) / todo.length) * 0.7;
        status = 'فحص الإيصالات: ${i + 1} من ${todo.length}';
      });
    }

    await recognizer.close();

    if (rawReceipts.isEmpty) {
      setState(() {
        busy = false;
        status = 'لم يتم العثور على إيصالات مطابقة.';
      });
      return;
    }

    assignTerminalsStage2(rawReceipts);

    processedItems.addAll(rawReceipts);
    await rebuildFiles();

    if (!mounted) return;
    setState(() {
      busy = false;
      progress = 1.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إيصالات POS (نسخة البايثون المطورة)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'مشاركة الملفات الرسمية',
            onPressed: busy ? null : shareStandardFiles,
          ),
        ],
      ),
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
                  [1, 'أمس واليوم'],
                  [3, '3 أيام'],
                  [7, 'أسبوع'],
                  [-1, 'الكل'],
                ])
                  ChoiceChip(
                    label: Text(o[1] as String),
                    selected: days == o[0],
                    onSelected: busy ? null : (_) => setState(() => days = o[0] as int),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text('المصدر: ${customDir ?? 'واتساب (تلقائي)'}',
                textDirection: TextDirection.ltr),
            Row(
              children: [
                TextButton.icon(
                  onPressed: busy ? null : pickFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('اختيار فولدر'),
                ),
                if (customDir != null)
                  TextButton(
                    onPressed: busy ? null : useWhatsApp,
                    child: const Text('رجوع للواتساب'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : runFullPipeline,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('بدء المعالجة الشاملة'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: busy ? null : shareStandardFiles,
                  icon: const Icon(Icons.share),
                  tooltip: 'مشاركة التقرير الرسمي والـ PDF',
                ),
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  onPressed: busy ? null : shareAdvancedFile,
                  icon: const Icon(Icons.table_chart),
                  tooltip: 'مشاركة التقرير الشامل وتقرير المراجعة',
                ),
              ],
            ),
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress > 0 ? progress : null),
            ],
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(status),
            ),
            if (missingTerminals.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade100,
                  border: Border.all(color: Colors.amber.shade800),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '⚠️ ماكينات ناقصة (${missingTerminals.length} من 18):',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.amber.shade900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      missingTerminals
                          .map((n) => '$n (${rowNames[terminals[numToTid[n]]!.excelRow]})')
                          .join(' ، '),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: processedItems.length,
                itemBuilder: (context, i) {
                  final item = processedItems[i];
                  final needsReview = !item.confirmed || item.row == null || item.amount <= 0;
                  return Card(
                    color: item.skip
                        ? Colors.red.shade50
                        : (needsReview ? Colors.orange.shade50 : null),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: Image.file(
                        File(item.path),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.receipt_long),
                      ),
                      title: Text(
                        item.skip
                            ? 'مكرر (مستبعد) - ماكينة ${item.displayOrder}'
                            : 'ماكينة ${item.displayOrder} - ${item.unitName ?? 'وحدة غير معروفة'}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        'TID: ${item.tid ?? 'غير محدد'} (${item.how})\n'
                        'المبلغ: ${item.amount.toStringAsFixed(2)} ج.م ${item.confirmed ? "✓" : "⚠️ راجع المبلغ"}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.edit, color: Colors.teal),
                        onPressed: () => editReceiptDialog(item),
                      ),
                    ),
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

// ───────────────────── متصفح الفولدرات ─────────────────────
class FolderPicker extends StatefulWidget {
  final String start;
  const FolderPicker({super.key, required this.start});

  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  late String path = widget.start;
  List<Directory> dirs = [];
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  void load() {
    try {
      final l = Directory(path)
          .listSync()
          .whereType<Directory>()
          .where((d) => !baseName(d.path).startsWith('.'))
          .toList();
      l.sort((a, b) =>
          baseName(a.path).toLowerCase().compareTo(baseName(b.path).toLowerCase()));
      dirs = l;
      error = null;
    } catch (_) {
      dirs = [];
      error = 'مش قادر أفتح الفولدر ده.';
    }
  }

  void go(String p) => setState(() {
        path = p;
        load();
      });

  @override
  Widget build(BuildContext context) {
    final canUp = path.length > root.length;
    return Scaffold(
      appBar: AppBar(title: const Text('اختيار فولدر')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(path, textDirection: TextDirection.ltr),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(error!),
              ),
            Expanded(
              child: ListView(
                children: [
                  if (canUp)
                    ListTile(
                      leading: const Icon(Icons.arrow_upward),
                      title: const Text('..'),
                      onTap: () => go(Directory(path).parent.path),
                    ),
                  for (final d in dirs)
                    ListTile(
                      leading: const Icon(Icons.folder),
                      title: Text(baseName(d.path), textDirection: TextDirection.ltr),
                      onTap: () => go(d.path),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                onPressed: () => Navigator.pop(context, path),
                child: const Text('اختيار هذا الفولدر'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
