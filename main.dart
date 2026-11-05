import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const PosApp());

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'A2R POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const RootPage(),
    );
  }
}

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: tab, children: const [HomePage(), MachinesPage()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.receipt_long), label: 'الإيصالات'),
          NavigationDestination(icon: Icon(Icons.folder_copy), label: 'ملفات الماكينات'),
        ],
      ),
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
  "50325716": const TerminalInfo(4, 3, "برج العرب"), // برج العرب 1
  "50335998": const TerminalInfo(5, 3, "برج العرب"), // برج العرب 2
  "50335994": const TerminalInfo(6, 3, "برج العرب"), // برج العرب 3
  "50335711": const TerminalInfo(7, 3, "برج العرب"), // برج العرب 4
  "50382298": const TerminalInfo(8, 4, "المنتزه"), // المنتزه 1
  "50382315": const TerminalInfo(9, 4, "المنتزه"), // المنتزه 2
  "50383712": const TerminalInfo(10, 4, "المنتزه"), // المنتزه 3
  "50382306": const TerminalInfo(11, 5, "محرم بك"), // محرم بك 1
  "50382316": const TerminalInfo(12, 5, "محرم بك"), // محرم بك 2
  "50382308": const TerminalInfo(13, 6, "العجمي"), // العجمي 1
  "50383706": const TerminalInfo(14, 6, "العجمي"), // العجمي 2
  "50382300": const TerminalInfo(15, 7, "القباري"),
  "50383702": const TerminalInfo(16, 8, "مصطفى كامل"),
  "50382312": const TerminalInfo(17, 9, "مديرية الأمن"),
  "50383699": const TerminalInfo(18, 10, "ميناء الإسكندرية"),
  "50383700": const TerminalInfo(19, 11, "خدمات مصر"),
};

final Map<int, String> numToTid = {
  1: "50335710", 2: "50335993", 3: "50335987",
  4: "50325716", 5: "50335998", 6: "50335994", 7: "50335711",
  8: "50382298", 9: "50382315", 10: "50383712",
  11: "50382306", 12: "50382316",
  13: "50382308", 14: "50383706",
  15: "50382300", 16: "50383702", 17: "50382312",
  18: "50383699", 19: "50383700",
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

// (فاضي) المنتزه 3 = 50383712 ماكينة مستقلة
final Map<String, String> tidAlias = {};

final Map<String, int> merchantCodeMap = {
  "22": 2, "23": 3, "24": 4, "25": 5, "26": 6,
  "27": 7, "28": 8, "29": 9, "30": 10, "31": 11,
};

final List<MapEntry<List<String>, int>> nameHints = [
  MapEntry(["ABYSS", "ABIS"], 2),
  MapEntry(["BURJ", "BORG"], 3),
  MapEntry(["MONTZAH", "TOSUN"], 4),
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
  10: "ميناء الإسكندرية", 11: "خدمات مصر",
};

// ───────────────────── خوارزميات الاستخراج (منقولة من نسخة البايثون) ─────────────────────
final List<RegExp> _markers = [
  RegExp(r'TERMINAL', caseSensitive: false),
  RegExp(r'GRAND|TOTALS?', caseSensitive: false),
  RegExp(r'NATIONAL\s*BANK|\bNBE\b', caseSensitive: false),
  RegExp(r'BATCH', caseSensitive: false),
  RegExp(r'MERCHANT', caseSensitive: false),
  RegExp(r'SUCCESSF|CLOSED', caseSensitive: false),
  RegExp(r'\bVISA\b|MASTER|MEZZA|MEEZA|MEEZ', caseSensitive: false),
  RegExp(r'THANK\s*YOU', caseSensitive: false),
  RegExp(r'NET\s*AMOUNT', caseSensitive: false),
  RegExp(r'\bSALE\b', caseSensitive: false),
];

int receiptScore(String text) => _markers.where((r) => r.hasMatch(text)).length;

// سطر نص مع مكانه في الصورة
class OcrLine {
  final String text;
  final double left, right, top, bottom;
  OcrLine(this.text, this.left, this.right, this.top, this.bottom);
  double get cy => (top + bottom) / 2;
  double get h => bottom - top;
}

List<OcrLine> toLines(RecognizedText res) {
  final out = <OcrLine>[];
  for (final b in res.blocks) {
    for (final l in b.lines) {
      final t = l.text.trim();
      if (t.isEmpty) continue;
      final r = l.boundingBox;
      out.add(OcrLine(t, r.left, r.right, r.top, r.bottom));
    }
  }
  return out;
}

// يرتب النص صفوف (الاسم يمين والرقم جنبه في نفس السطر) زي Tesseract بالظبط
String rowsText(List<OcrLine> lines) {
  final ls = [...lines]..sort((a, b) => a.cy.compareTo(b.cy));
  final rows = <List<OcrLine>>[];
  for (final l in ls) {
    if (rows.isNotEmpty) {
      final last = rows.last;
      final cy = last.map((e) => e.cy).reduce((a, b) => a + b) / last.length;
      final h = last.map((e) => e.h).reduce((a, b) => a + b) / last.length;
      if ((l.cy - cy).abs() < h * 0.6) {
        last.add(l);
        continue;
      }
    }
    rows.add([l]);
  }
  final sb = StringBuffer();
  for (final r in rows) {
    r.sort((a, b) => a.left.compareTo(b.left));
    sb.writeln(r.map((e) => e.text).join('  '));
  }
  return sb.toString();
}

String readingText(List<OcrLine> lines) => lines.map((e) => e.text).join('\n');

// صورة فيها أكتر من إيصال جنب بعض -> نقسمها لأعمدة
List<List<OcrLine>> splitColumns(List<OcrLine> lines) {
  if (lines.length < 8) return [lines];
  final minL = lines.map((e) => e.left).reduce(math.min);
  final maxR = lines.map((e) => e.right).reduce(math.max);
  final w = maxR - minL;
  if (w <= 0) return [lines];
  final sorted = [...lines]..sort((a, b) => a.left.compareTo(b.left));
  for (final tolFrac in const [0.03, 0.02, 0.01]) {
    final groups = <List<OcrLine>>[];
    var curRight = -1e9;
    for (final l in sorted) {
      if (groups.isEmpty || l.left - curRight > w * tolFrac) {
        groups.add([l]);
        curRight = l.right;
      } else {
        groups.last.add(l);
        curRight = math.max(curRight, l.right);
      }
    }
    final big = groups.where((g) {
      final gl = g.map((e) => e.left).reduce(math.min);
      final gr = g.map((e) => e.right).reduce(math.max);
      return gr - gl >= w * 0.12 && g.length >= 6;
    }).toList();
    if (big.length >= 2 &&
        big.length <= 4 &&
        big.every((g) => receiptScore(readingText(g)) >= 3)) {
      return big;
    }
  }
  return [lines];
}

// ───────────── المبالغ ─────────────
final RegExp _amountRe =
    RegExp(r"(?<![\d,.])(\d{1,3}(?:,\d{3})*|\d+)[., ](\d{2})(?!\d)");
final RegExp _brandRe = RegExp(
    r"\b(VISA|MASTER(?:CARD)?|MEZZA|MEEZA|MEZA|MEZZ4|MEZZ)\b",
    caseSensitive: false);

List<double> amountsIn(String rawText) {
  final text = rawText.replaceAllMapped(
      RegExp(r'\bB(\d{2,3}[.,]\d{2})\b'), (m) => '8${m.group(1)}');
  final out = <double>[];
  for (final m in _amountRe.allMatches(text)) {
    final v = double.tryParse("${m.group(1)!.replaceAll(',', '')}.${m.group(2)!}");
    if (v != null && v >= 0.5 && v <= 5000000) out.add(round2(v));
  }
  return out;
}

MapEntry<T, int>? mostCommon<T>(List<T> vals) {
  if (vals.isEmpty) return null;
  final counts = <T, int>{};
  for (final v in vals) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  MapEntry<T, int>? best;
  for (final e in counts.entries) {
    if (best == null || e.value > best.value) best = e;
  }
  return best;
}

class Parsed {
  final List<double> grand;
  final double? bsum;
  final List<double> bvals;
  Parsed(this.grand, this.bsum, this.bvals);
}

Parsed parseReceipt(String txt) {
  final t = txt
      .split(RegExp(r"THANK\s*YOU|Hotline|App\s*Version", caseSensitive: false))
      .first;
  final gm = RegExp(r"GRAND|TOTALS", caseSensitive: false).firstMatch(t);
  var pre = gm != null ? t.substring(0, gm.start) : t;
  final post = gm != null ? t.substring(gm.start) : "";

  final bms = _brandRe.allMatches(pre).toList();
  final sections = <String>[];
  if (bms.isNotEmpty) {
    for (var i = 0; i < bms.length; i++) {
      final end = i + 1 < bms.length ? bms[i + 1].start : pre.length;
      sections.add(pre.substring(bms[i].end, end));
    }
  } else {
    final sm =
        RegExp(r"SUCCESSFULL?Y|CLOSED", caseSensitive: false).firstMatch(pre);
    if (sm != null) pre = pre.substring(sm.end);
    sections.add(pre);
  }

  final bvals = <double>[];
  for (final sec in sections) {
    final mc = mostCommon(amountsIn(sec));
    if (mc != null) bvals.add(mc.key);
  }
  final grand = amountsIn(post);
  final bsum = bvals.isNotEmpty ? round2(bvals.reduce((a, b) => a + b)) : null;
  return Parsed(grand, bsum, bvals);
}

class Decision {
  final double val;
  final bool ok;
  Decision(this.val, this.ok);
}

Decision decide(List<Parsed> results) {
  // 1) تطابق تام بين مجموع الكروت و GRAND TOTALS
  for (final r in results) {
    final b = r.bsum;
    if (b != null && b > 0 && r.grand.any((g) => (g - b).abs() < 0.005)) {
      return Decision(b, true);
    }
  }
  // 2) فرق رقم واحد
  for (final r in results) {
    final b = r.bsum;
    if (b != null && b > 0 && r.bvals.length >= 2) {
      for (final g in r.grand) {
        final sa = g.toStringAsFixed(2), sb = b.toStringAsFixed(2);
        if (sa.length == sb.length) {
          var diff = 0;
          for (var i = 0; i < sa.length; i++) {
            if (sa[i] != sb[i]) diff++;
          }
          if (diff == 1) return Decision(b, true);
        }
      }
    }
  }
  // 3) إجمالي مكرر
  for (final r in results) {
    final c = mostCommon(r.grand);
    if (c != null && c.value >= 2 && r.bsum == null) return Decision(c.key, false);
  }
  // 4) تصويت
  final pool = <double>[];
  for (final r in results) {
    pool.addAll(r.grand);
    final b = r.bsum;
    if (b != null && b > 0) pool.add(b);
  }
  final c = mostCommon(pool);
  if (c != null) return Decision(c.key, false);
  return Decision(0.0, false);
}

class PieceResult {
  final List<String> texts;
  final double val;
  final bool ok;
  PieceResult(this.texts, this.val, this.ok);
}

PieceResult ocrPiece(List<OcrLine> lines) {
  final texts = <String>[rowsText(lines), readingText(lines)];
  final d = decide(texts.map(parseReceipt).toList());
  return PieceResult(texts, d.val, d.ok);
}

String? batchNo(List<String> texts) {
  final reg = RegExp(r"BATCH\s*NO\D{0,6}(\d{4,7})", caseSensitive: false);
  final all = <String>[];
  for (final t in texts) {
    for (final m in reg.allMatches(t)) {
      all.add(m.group(1)!);
    }
  }
  return mostCommon(all)?.key;
}

// ───────────── الماكينة / الوحدة / التاريخ ─────────────
String? _tidLabeled(String t) {
  final m = RegExp(r"TERMINAL\s*(?:ID)?\D{0,15}?(\d[\d\s/]{6,9}\d)",
          caseSensitive: false)
      .firstMatch(t);
  if (m == null) return null;
  final raw = m.group(1)!.replaceAll('/', '7').replaceAll(RegExp(r'\D'), '');
  if (raw.length < 8) return null;
  var d = raw.substring(raw.length - 8);
  d = tidFix[d] ?? d;
  return terminals.containsKey(d) ? d : null;
}

String? _tidLoose(String t) {
  for (final tid in terminals.keys) {
    if (t.contains(tid)) return tid;
  }
  for (final m in RegExp(r"\b(503\d{5})\b").allMatches(t)) {
    var c = m.group(1)!;
    c = tidFix[c] ?? c;
    if (terminals.containsKey(c)) return c;
  }
  return null;
}

String? findTerminalIn(List<String> texts) {
  for (final t in texts) {
    final r = _tidLabeled(t);
    if (r != null) return r;
  }
  for (final t in texts) {
    final r = _tidLoose(t);
    if (r != null) return r;
  }
  return null;
}

String? findTerminalFuzzyIn(List<String> texts, int? targetRow) {
  final pool = terminals.entries
      .where((e) => targetRow == null || e.value.excelRow == targetRow)
      .map((e) => e.key)
      .toList();
  final dist = <String, int>{};
  for (final t in texts) {
    for (final run in RegExp(r"\d[\d /]{6,14}\d").allMatches(t)) {
      final digits = run.group(0)!.replaceAll('/', '7').replaceAll(RegExp(r'\D'), '');
      for (var i = 0; i + 8 <= digits.length; i++) {
        final cand = digits.substring(i, i + 8);
        if (!cand.startsWith('50') && !cand.startsWith('60')) continue;
        for (final tid in pool) {
          var d = 0;
          for (var k = 0; k < 8; k++) {
            if (cand[k] != tid[k]) d++;
          }
          if (d < (dist[tid] ?? 99)) dist[tid] = d;
        }
      }
    }
  }
  if (dist.isEmpty) return null;
  final best = dist.values.reduce(math.min);
  final winners = dist.entries.where((e) => e.value == best).map((e) => e.key).toList();
  if (best <= 1 && winners.length == 1) return winners.first;
  return null;
}

int? findUnitExtraIn(List<String> texts) {
  for (final t in texts) {
    final m = RegExp(r"MERCHANT\s*(?:ID|10)\D{0,15}?(\d[\d\s/]{8,13}\d)", caseSensitive: false)
        .firstMatch(t);
    final cands = <String>[
      if (m != null) m.group(1)!.replaceAll('/', '7').replaceAll(RegExp(r'\D'), ''),
      t.replaceAll(RegExp(r'\D'), ''),
    ];
    for (final d in cands) {
      final mm = RegExp(r"11470?(2[2-9]|3[01])084").firstMatch(d);
      if (mm != null && merchantCodeMap.containsKey(mm.group(1))) {
        return merchantCodeMap[mm.group(1)];
      }
    }
  }
  for (final t in texts) {
    final up = t.toUpperCase();
    for (final hint in nameHints) {
      if (hint.key.any((w) => up.contains(w))) return hint.value;
    }
  }
  return null;
}

String? findDateIn(List<String> texts) {
  final reg = RegExp(r"DATE\s*:?\s*(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})",
      caseSensitive: false);
  for (final t in texts) {
    final m = reg.firstMatch(t);
    if (m != null) {
      final mo = int.tryParse(m.group(2)!) ?? 0;
      final d = int.tryParse(m.group(3)!) ?? 0;
      return "$d.$mo";
    }
  }
  return null;
}

class Analysis {
  String? tid;
  String how;
  int? row;
  String? unitName;
  double val;
  bool ok;
  List<double> batches;
  String? date;
  String debug = '';
  Analysis(this.tid, this.how, this.row, this.unitName, this.val, this.ok,
      this.batches, this.date);
}

// تحليل صورة كاملة (ممكن فيها أكتر من إيصال)
Analysis analyzeLines(List<OcrLine> all) {
  final pieces = splitColumns(all);
  final multi = pieces.length > 1;
  final allTexts = <String>[];
  final batches = <double>[];
  var allOk = true;
  final seen = <String>{};

  final dbg = StringBuffer('pieces=${pieces.length}\n');
  for (final pc in pieces) {
    final r = ocrPiece(pc);
    final pr = parseReceipt(r.texts[0]);
    dbg.writeln('--- receipt ---\n${r.texts[0]}>> cards=${pr.bvals} sum=${pr.bsum} '
        'grand=${pr.grand} => ${r.val} ok=${r.ok}');
    allTexts.addAll(r.texts);
    if (r.val <= 0) {
      allOk = false;
      continue;
    }
    final b = batchNo(r.texts);
    final key = '$b|${r.val}';
    if (b != null && seen.contains(key)) continue; // نفس الباتش اتصور مرتين
    seen.add(key);
    batches.add(r.val);
    allOk = allOk && r.ok;
  }
  var total = round2(batches.fold(0.0, (a, b) => a + b));
  var ok = allOk && batches.isNotEmpty;

  // شبكة أمان: لو التقسيم مش مؤكد جرّب الصورة كلها
  if (multi && !ok) {
    final r = ocrPiece(all);
    allTexts.addAll(r.texts);
    if (r.val > 0 && (r.ok || batches.isEmpty)) {
      total = r.val;
      ok = r.ok;
      batches
        ..clear()
        ..add(r.val);
    }
  }

  final date = findDateIn(allTexts);
  var tid = findTerminalIn(allTexts);
  var how = 'terminal';
  int? row;
  String? name;
  if (tid == null) {
    final u0 = findUnitExtraIn(allTexts);
    tid = findTerminalFuzzyIn(allTexts, u0);
    how = 'fuzzy';
  }
  if (tid != null) {
    tid = tidAlias[tid] ?? tid;
    final info = terminals[tid]!;
    row = info.excelRow;
    name = info.unitName;
  } else {
    how = 'none';
    final u = findUnitExtraIn(allTexts);
    if (u != null) {
      row = u;
      name = rowNames[u];
      how = 'name/merchant';
    }
  }
  final result = Analysis(tid, how, row, name, total, ok, batches, date);
  result.debug = dbg.toString();
  return result;
}

double round2(double val) => double.parse(val.toStringAsFixed(2));

// دمج القراءة التانية (الصورة المحسّنة) في القراءة الأولى.
// بترجع قيمة المبلغ التانية لو متعارضة مع الأولى (علشان تتراجع)، وإلا null.
double? mergeSecondRead(Analysis a, Analysis b) {
  if (a.tid == null && b.tid != null) {
    a.tid = b.tid;
    a.row = b.row;
    a.unitName = b.unitName;
    a.how = b.how;
  } else if (a.row == null && b.row != null) {
    a.row = b.row;
    a.unitName = b.unitName;
    a.how = b.how;
  }
  a.date ??= b.date;
  if (b.val <= 0) return null;
  if (a.val <= 0) {
    a.val = b.val;
    a.ok = b.ok;
    a.batches = [...b.batches];
    return null;
  }
  if ((a.val - b.val).abs() < 0.005) return null; // القراءتين متطابقتين
  if (!a.ok && b.ok) {
    // الأولى مش مؤكدة والتانية مؤكدة بمجموع الكروت -> نعتمد التانية
    a.val = b.val;
    a.ok = true;
    a.batches = [...b.batches];
    return null;
  }
  if (a.ok && !b.ok) return null; // الأولى مؤكدة، نتجاهل التانية
  a.ok = false; // قراءتين مختلفتين: لازم مراجعة
  return b.val;
}

// بيحوّل صفحات ملف PDF لصور PNG (بيستخدم في حالة مفيش صور)
Future<List<File>> extractPdfPages(File pdf) async {
  final out = <File>[];
  try {
    final bytes = await pdf.readAsBytes();
    final dir = Directory('$tmpDir/pdf')..createSync(recursive: true);
    var i = 0;
    await for (final page in Printing.raster(bytes, dpi: 220)) {
      i++;
      final png = await page.toPng();
      final f = File('${dir.path}/pdf${bytes.length}_p$i.png');
      await f.writeAsBytes(png);
      out.add(f);
    }
  } catch (_) {}
  return out;
}

// ───────────────────── مسارات المجلدات ─────────────────────
const String root = '/storage/emulated/0';
final String baseDir = '$root/all';
final String rawImagesDir = '$baseDir/raw_images';
String outputDir = '$baseDir/output'; // ممكن المستخدم يغيّره من الشاشة
final String defaultOutputDir = '$baseDir/output';
final String tmpDir = '$baseDir/.tmp';
final String cfgPath = '$baseDir/.app_cfg.json';

String baseName(String path) => path.split('/').last;

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

  for (final d in _subDirs(root)) {
    if (baseName(d.path).toLowerCase().startsWith('whatsapp')) {
      checkAndAdd('${d.path}/Media/WhatsApp Images');
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

Map<String, dynamic> _readCfg() {
  try {
    return Map<String, dynamic>.from(jsonDecode(File(cfgPath).readAsStringSync()) as Map);
  } catch (_) {
    return <String, dynamic>{};
  }
}

void _writeCfg(Map<String, dynamic> m) {
  try {
    File(cfgPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(m));
  } catch (_) {}
}

String? loadFolder() => _readCfg()['folder'] as String?;

void saveFolder(String? f) {
  final m = _readCfg();
  m['folder'] = f;
  _writeCfg(m);
}

String? loadOutDir() => _readCfg()['out'] as String?;

void saveOutDir(String? f) {
  final m = _readCfg();
  m['out'] = f;
  _writeCfg(m);
}

// ───────────────── معالجة الصور (تدوير / تحسين) - بتشتغل في Isolate ─────────────────
// بتصلّح اتجاه الـ EXIF وبتدوّر الصورة لو deg != 0. بترجع true لو كتبت ملف جديد.
bool _fixImage(String src, String dst, int deg) {
  final bytes = File(src).readAsBytesSync();
  var im = img.decodeImage(bytes);
  if (im == null) {
    if (src != dst) File(src).copySync(dst);
    return false;
  }
  var ori = 1;
  try {
    ori = im.exif.imageIfd.orientation ?? 1;
  } catch (_) {}
  if (deg == 0 && ori == 1) {
    if (src != dst) File(src).copySync(dst);
    return false;
  }
  im = img.bakeOrientation(im);
  if (deg != 0) im = img.copyRotate(im, angle: deg);
  File(dst).writeAsBytesSync(img.encodeJpg(im, quality: 92));
  return true;
}

// نسخة محسّنة للقراءة التانية: رمادي + كونتراست + تكبير/تصغير لمقاس مناسب للـ OCR
void _enhanceImage(String src, String dst) {
  var im = img.decodeImage(File(src).readAsBytesSync());
  if (im == null) throw Exception('decode failed');
  im = img.bakeOrientation(im);
  im = img.grayscale(im);
  im = img.adjustColor(im, contrast: 1.6);
  if (im.width < 1800) {
    im = img.copyResize(im,
        width: (im.width * 1.6).round(), interpolation: img.Interpolation.cubic);
  } else if (im.width > 2600) {
    im = img.copyResize(im, width: 2200, interpolation: img.Interpolation.linear);
  }
  File(dst).writeAsBytesSync(img.encodeJpg(im, quality: 95));
}

Future<bool> fixImageAsync(String src, String dst, int deg) =>
    Isolate.run(() => _fixImage(src, dst, deg));

Future<void> enhanceImageAsync(String src, String dst) =>
    Isolate.run(() => _enhanceImage(src, dst));


// ───────────────── ملء القالب مباشرة جوه ملف الـ xlsx (من غير ما نبوّظ التنسيق) ─────────────────
Future<List<int>?> loadTemplateBytes() async {
  try {
    final exact = File('$baseDir/الاسكندريه 00.xlsx');
    if (exact.existsSync()) return exact.readAsBytesSync();
    final d = Directory(baseDir);
    if (d.existsSync()) {
      for (final e in d.listSync().whereType<File>()) {
        final n = baseName(e.path);
        if (n.toLowerCase().endsWith('.xlsx') &&
            n.contains('00') &&
            !n.startsWith('~') &&
            !n.startsWith('.')) {
          return e.readAsBytesSync();
        }
      }
    }
  } catch (_) {}
  try {
    final data = await rootBundle.load('assets/template.xlsx');
    return data.buffer.asUint8List();
  } catch (_) {}
  return null;
}

String _firstSheetPath(Archive arc) {
  String? text(String n) {
    for (final f in arc.files) {
      if (f.name == n) return utf8.decode(f.content as List<int>, allowMalformed: true);
    }
    return null;
  }

  final wb = text('xl/workbook.xml');
  final rels = text('xl/_rels/workbook.xml.rels');
  if (wb != null && rels != null) {
    final sm = RegExp(r'<sheet\b[^>]*?r:id="([^"]+)"').firstMatch(wb);
    if (sm != null) {
      for (final m in RegExp(r'<Relationship\b[^>]*>').allMatches(rels)) {
        final tag = m.group(0)!;
        if (tag.contains('Id="${sm.group(1)}"')) {
          final t = RegExp(r'Target="([^"]+)"').firstMatch(tag)?.group(1);
          if (t != null) return t.startsWith('/') ? t.substring(1) : 'xl/$t';
        }
      }
    }
  }
  return 'xl/worksheets/sheet1.xml';
}

final RegExp _cellRe = RegExp(r'<c\b[^>]*?/>|<c\b[^>]*?>.*?</c>', dotAll: true);

int _colNum(String c) {
  var n = 0;
  for (final ch in c.codeUnits) {
    n = n * 26 + (ch - 64);
  }
  return n;
}

RegExpMatch? _findRow(String xml, int row) => RegExp(
        '<row\\b[^>]*\\br="$row"[^>]*?(?:/>|>.*?</row>)',
        dotAll: true)
    .firstMatch(xml);

double _readNum(String xml, String col, int row) {
  final rm = _findRow(xml, row);
  if (rm == null) return 0.0;
  for (final m in _cellRe.allMatches(rm.group(0)!)) {
    final cell = m.group(0)!;
    final open = RegExp(r'<c\b[^>]*?>').firstMatch(cell)!.group(0)!;
    final r = RegExp(r'\br="([A-Z]+)\d+"').firstMatch(open);
    if (r == null || r.group(1) != col) continue;
    final t = RegExp(r'\bt="([^"]+)"').firstMatch(open)?.group(1);
    if (t != null && t != 'n') return 0.0;
    final v = RegExp(r'<v>([^<]*)</v>').firstMatch(cell)?.group(1);
    return double.tryParse(v ?? '') ?? 0.0;
  }
  return 0.0;
}

// بيكتب خلية واحدة محافظ على الـ style بتاعها. build(style, oldFormulaElement) -> xml الخلية
String _setCell(String xml, String col, int row,
    String Function(String ref, String? style, String? formula) build) {
  final rm = _findRow(xml, row);
  if (rm == null) throw Exception('row $row missing');
  var rowXml = rm.group(0)!;
  final ref = '$col$row';
  final target = _colNum(col);
  RegExpMatch? existing, before;
  for (final m in _cellRe.allMatches(rowXml)) {
    final cell = m.group(0)!;
    final open = RegExp(r'<c\b[^>]*?>').firstMatch(cell)!.group(0)!;
    final r = RegExp(r'\br="([A-Z]+)\d+"').firstMatch(open);
    if (r == null) continue;
    final cn = _colNum(r.group(1)!);
    if (cn == target) {
      existing = m;
      break;
    }
    if (cn > target && before == null) before = m;
  }
  String? style, formula;
  if (existing != null) {
    final cell = existing.group(0)!;
    final open = RegExp(r'<c\b[^>]*?>').firstMatch(cell)!.group(0)!;
    style = RegExp(r'\bs="(\d+)"').firstMatch(open)?.group(1);
    formula = RegExp(r'<f\b[^>]*?(?:/>|>.*?</f>)', dotAll: true).firstMatch(cell)?.group(0);
  }
  final newCell = build(ref, style, formula);
  if (existing != null) {
    rowXml = rowXml.replaceRange(existing.start, existing.end, newCell);
  } else if (before != null) {
    rowXml = rowXml.replaceRange(before.start, before.start, newCell);
  } else if (rowXml.endsWith('/>')) {
    rowXml = '${rowXml.substring(0, rowXml.length - 2)}>$newCell</row>';
  } else {
    final i = rowXml.lastIndexOf('</row>');
    rowXml = rowXml.replaceRange(i, i, newCell);
  }
  return xml.replaceRange(rm.start, rm.end, rowXml);
}

List<int> fillTemplate(List<int> bytes, Map<int, double> totals) {
  final arc = ZipDecoder().decodeBytes(bytes);
  final sheetPath = _firstSheetPath(arc);
  final out = Archive();
  var found = false;
  for (final f in arc.files) {
    if (!f.isFile) continue;
    final c = f.content as List<int>;
    if (f.name == sheetPath) {
      found = true;
      var xml = utf8.decode(c, allowMalformed: true);
      for (var r = 2; r <= 11; r++) {
        final tot = round2(totals[r] ?? 0.0);
        xml = _setCell(xml, 'D', r, (ref, st, f0) =>
            '<c r="$ref"${st != null ? ' s="$st"' : ''}><v>$tot</v></c>');
        final cash = _readNum(xml, 'E', r);
        final total = round2(tot + cash);
        xml = _setCell(xml, 'F', r, (ref, st, f0) =>
            '<c r="$ref"${st != null ? ' s="$st"' : ''}>'
            '${f0 ?? '<f>D$r+IF(ISBLANK(E$r),0,E$r)</f>'}<v>$total</v></c>');
      }
      final b = utf8.encode(xml);
      out.addFile(ArchiveFile(f.name, b.length, b));
    } else {
      out.addFile(ArchiveFile(f.name, c.length, c));
    }
  }
  if (!found) throw Exception('sheet not found: $sheetPath');
  final enc = ZipEncoder().encode(out);
  if (enc == null) throw Exception('zip encode failed');
  return enc;
}

// ───────────────── قنوات النظام (واتساب مباشر / فتح فولدر) ─────────────────
const MethodChannel _chan = MethodChannel('pos/native');

String todayToken() {
  final n = DateTime.now();
  return '${n.day}.${n.month}';
}

String _normAr(String s) => s
    .replaceAll(RegExp('[أإآ]'), 'ا')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .toLowerCase();

// ملف PDF اسمه "الاسكندريه + تاريخ النهارده" (بيقبل 5.11 / 05.11 / 5-11 / 5_11)
bool isTodayAlexPdf(String path) {
  final name = _normAr(baseName(path));
  if (!name.endsWith('.pdf')) return false;
  if (!name.contains('اسكندري')) return false;
  final n = DateTime.now();
  final re = RegExp('(?<!\\d)0?${n.day}[._\\- ]0?${n.month}(?!\\d)');
  return re.hasMatch(name);
}

List<File> findTodayAlexPdfs(List<String> dirs) {
  final out = <File>[];
  final seen = <String>{};
  for (final d in dirs) {
    if (d == outputDir) continue; // ما نقراش الملفات اللي التطبيق نفسه طلّعها
    try {
      final dir = Directory(d);
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync().whereType<File>()) {
        if (isTodayAlexPdf(e.path) && seen.add(e.path)) out.add(e);
      }
    } catch (_) {}
  }
  out.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return out;
}

// ───────────────────── نموذج الإيصال ─────────────────────
class ReceiptItem {
  String path;
  String? tid;
  int? orderNum;
  int? row;
  String? unitName;
  double amount;
  String? date;
  String key; // اسم الملف الأصلي + حجمه (لحفظ التصحيحات اليدوية)
  bool ok; // المبلغ مؤكد؟
  String how; // terminal | fuzzy | name/merchant | auto-number | conflict | extra-batch | manual
  List<double> batches;
  int? suffix;
  String? origTid;
  bool conflict;
  bool skip;
  double? alt; // قراءة تانية مختلفة للمبلغ (للمراجعة)

  ReceiptItem({
    required this.path,
    this.tid,
    this.orderNum,
    this.row,
    this.unitName,
    this.amount = 0.0,
    this.date,
    this.key = '',
    this.ok = false,
    this.how = 'none',
    List<double>? batches,
    this.suffix,
    this.origTid,
    this.conflict = false,
    this.skip = false,
    this.alt,
  }) : batches = batches ?? <double>[];

  bool get needsReview =>
      amount <= 0 ||
      row == null ||
      !ok ||
      alt != null ||
      how == 'auto-number' ||
      how == 'conflict';
}

// ───────────────────── التصحيحات اليدوية (بتفضل محفوظة) ─────────────────────
final String fixPath = '$baseDir/.app_fix.json';

Map<String, dynamic> loadFixes() {
  try {
    return Map<String, dynamic>.from(jsonDecode(File(fixPath).readAsStringSync()) as Map);
  } catch (_) {
    return <String, dynamic>{};
  }
}

void saveFix(ReceiptItem item) {
  if (item.key.isEmpty) return;
  try {
    final m = loadFixes();
    m[item.key] = {'val': item.amount, 'tid': item.tid};
    File(fixPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(m));
  } catch (_) {}
}

bool sameDay(ReceiptItem a, ReceiptItem b) =>
    a.date == null || b.date == null || a.date == b.date;

// ───────────────────── الشاشة الرئيسية ─────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  AppLifecycleState _life = AppLifecycleState.resumed;
  int days = 0;
  String? customDir;
  String? customOut;
  bool busy = false;
  double progress = 0;
  String status = 'اضغط "بدء المعالجة الشاملة" لسحب الصور وتوليد الإكسيل والـ PDF.';
  final List<ReceiptItem> processedItems = [];
  String? standardXlsxPath;
  String? generatedPdfPath;
  List<int> missingTerminals = [];
  final List<String> warnings = [];
  bool autoRotate = false; // أبطأ: بيجرّب تدوير كل صورة مش إيصال
  String sourceNote = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    customDir = loadFolder();
    customOut = loadOutDir();
    if (customOut != null && customOut!.isNotEmpty) outputDir = customOut!;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _life = state;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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

  Future<void> pickOutFolder() async {
    final perm = await Permission.manageExternalStorage.request();
    if (!perm.isGranted) {
      setState(() => status = 'لازم تسمح بالوصول لكل الملفات الأول.');
      return;
    }
    if (!mounted) return;
    final res = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FolderPicker(start: customOut ?? root)),
    );
    if (res != null) {
      try {
        final t = File('$res/.write_test')..writeAsStringSync('x');
        t.deleteSync();
      } catch (_) {
        setState(() => status = 'مش قادر أكتب في الفولدر ده: $res');
        return;
      }
      saveOutDir(res);
      setState(() {
        customOut = res;
        outputDir = res;
      });
    }
  }

  void useDefaultOut() {
    saveOutDir(null);
    setState(() {
      customOut = null;
      outputDir = defaultOutputDir;
    });
  }

  Future<void> openFolder(String path) async {
    try {
      Directory(path).createSync(recursive: true);
    } catch (_) {}
    try {
      final ok = await _chan.invokeMethod<bool>('openFolder', {'path': path});
      if (ok == true) return;
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('مقدرتش أفتح الفولدر. المسار اتنسخ: $path')),
    );
  }

  // إرسال الإكسيل والـ PDF (المستخدم بيختار واتساب من قايمة المشاركة)
  Future<void> sendToWhatsApp() async {
    final x = latestOutput('.xlsx');
    final p = latestOutput('.pdf');
    final files = <XFile>[if (x != null) XFile(x), if (p != null) XFile(p)];
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لم يتم إنشاء ملفات بعد لمشاركتها.')),
      );
      return;
    }
    await Share.shareXFiles(files, text: 'تقرير إيصالات الإسكندرية');
  }

  // أحدث ملف إخراج (إكسيل/PDF): من آخر معالجة، أو آخر ملف "الاسكندريه ..." في فولدر الإخراج
  String? latestOutput(String ext) {
    final cur = ext == '.xlsx' ? standardXlsxPath : generatedPdfPath;
    if (cur != null && File(cur).existsSync()) return cur;
    try {
      final d = Directory(outputDir);
      if (!d.existsSync()) return null;
      final fs = d
          .listSync()
          .whereType<File>()
          .where((f) {
            final n = _normAr(baseName(f.path));
            return n.endsWith(ext) && n.contains('اسكندري');
          })
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      return fs.isEmpty ? null : fs.first.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> openFile(String? path, String mime) async {
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الملف مش موجود. شغّل المعالجة الأول.')),
      );
      return;
    }
    try {
      final ok = await _chan.invokeMethod<bool>('openFile', {'path': path, 'mime': mime});
      if (ok == true) return;
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('مفيش برنامج يفتح الملف ده.')),
    );
  }

  bool _isAppOutput(String path) {
    final n = baseName(path);
    final l = n.toLowerCase();
    return n == 'review_report.txt' ||
        n == 'ocr_debug.txt' ||
        ((l.endsWith('.xlsx') || l.endsWith('.pdf')) && _normAr(n).contains('اسكندري'));
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('مسح')),
        ],
      ),
    );
    return r == true;
  }

  // مسح الكل: ملفات فولدر الإخراج + الصور المرتبة
  Future<void> clearAll() async {
    final protectedDirs = <String>{
      root,
      baseDir,
      '$root/Download',
      '$root/Documents',
      '$root/DCIM',
      '$root/Pictures',
    };
    final isProtected = protectedDirs.contains(outputDir);
    final outFiles = <File>[];
    try {
      final d = Directory(outputDir);
      if (d.existsSync()) {
        for (final e in d.listSync().whereType<File>()) {
          if (!isProtected || _isAppOutput(e.path)) outFiles.add(e);
        }
      }
    } catch (_) {}
    final rawFiles = <File>[];
    try {
      final d = Directory(rawImagesDir);
      if (d.existsSync()) rawFiles.addAll(d.listSync().whereType<File>());
    } catch (_) {}
    if (outFiles.isEmpty && rawFiles.isEmpty) {
      setState(() => status = 'مفيش حاجة للمسح.');
      return;
    }
    final ok = await _confirm(
      'مسح الكل',
      'هتتمسح ${outFiles.length} ملف من الإخراج:\n$outputDir\n\n'
          'و ${rawFiles.length} صورة من الصور المرتبة.'
          '${isProtected ? '\n\n(فولدر الإخراج ده عام، فهيتمسح بس ملفات التطبيق منه)' : ''}',
    );
    if (!ok) return;
    var n = 0;
    for (final f in [...outFiles, ...rawFiles]) {
      try {
        f.deleteSync();
        n++;
      } catch (_) {}
    }
    setState(() {
      processedItems.clear();
      missingTerminals = [];
      warnings.clear();
      standardXlsxPath = null;
      generatedPdfPath = null;
      status = 'تم مسح $n ملف.';
    });
  }

  Future<void> openReview() async {
    final list = processedItems.where((e) => e.needsReview).toList();
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('مفيش إيصالات محتاجة مراجعة.')),
      );
      return;
    }
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ReviewPage(items: list)),
    );
    if (changed == true) {
      await rebuildFiles();
    } else if (mounted) {
      setState(() {});
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
    for (final p in ['$outputDir/review_report.txt', '$outputDir/ocr_debug.txt']) {
      if (File(p).existsSync()) files.add(XFile(p));
    }
    if (files.isNotEmpty) {
      await Share.shareXFiles(files, text: 'تقرير المراجعة + ملف الـ OCR');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ملفات المراجعة غير متاحة حالياً.')),
      );
    }
  }

  Future<void> editReceiptDialog(ReceiptItem item) async {
    final amtController = TextEditingController(text: item.amount.toStringAsFixed(2));
    int? selectedOrder = item.orderNum;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('تعديل بيانات الإيصال'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.file(File(item.path), height: 160, fit: BoxFit.contain),
                const SizedBox(height: 8),
                TextField(
                  controller: amtController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'المبلغ الإجمالي'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  value: selectedOrder,
                  hint: const Text('اختر الماكينة (1..19)'),
                  items: [
                    for (var i = 1; i <= 19; i++)
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
                final newAmt = double.tryParse(amtController.text) ?? item.amount;
                setState(() {
                  item.amount = round2(newAmt);
                  item.batches = [item.amount];
                  item.ok = true;
                  item.alt = null;
                  item.how = 'manual';
                  if (selectedOrder != null) {
                    item.orderNum = selectedOrder;
                    item.tid = numToTid[selectedOrder];
                    item.row = terminals[item.tid]!.excelRow;
                    item.unitName = terminals[item.tid]!.unitName;
                  }
                });
                saveFix(item);
                Navigator.pop(ctx);
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
    setState(() => status = 'جاري توليد الملفات وتحديث الشيتات...');
    final dateCounts = <String, int>{};
    for (final r in processedItems) {
      if (r.date != null) {
        dateCounts[r.date!] = (dateCounts[r.date!] ?? 0) + 1;
      }
    }
    String reportDate = "اليوم";
    if (dateCounts.isNotEmpty) {
      reportDate = dateCounts.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    }

    // 1. بناء ملف الـ PDF المجمع
    final pdf = pw.Document();
    processedItems.sort((a, b) {
      final c = (a.orderNum ?? 99).compareTo(b.orderNum ?? 99);
      return c != 0 ? c : (a.suffix ?? 1).compareTo(b.suffix ?? 1);
    });
    for (final r in processedItems) {
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

    // حساب إجماليات كل وحدة
    final unitTotals = <int, double>{};
    for (var r = 2; r <= 11; r++) {
      unitTotals[r] = 0.0;
    }
    for (final item in processedItems) {
      if (item.row != null && item.amount > 0) {
        unitTotals[item.row!] = (unitTotals[item.row!] ?? 0.0) + item.amount;
      }
    }

    // الإكسيل: نفس القالب بالظبط، بنكتب بس عمود D (مبلغ كل وحدة) و F (الإجمالي)
    var xlsxLine = '• تم توليد الإكسيل: الاسكندريه $reportDate.xlsx';
    standardXlsxPath = null;
    final tpl = await loadTemplateBytes();
    if (tpl == null) {
      xlsxLine = '⚠️ قالب "الاسكندريه 00.xlsx" مش موجود في فولدر all (ولا مضاف للتطبيق)، فمتعملش إكسيل.';
    } else {
      try {
        final outBytes = fillTemplate(tpl, unitTotals);
        final stdFile = File('$outputDir/الاسكندريه $reportDate.xlsx');
        stdFile.createSync(recursive: true);
        stdFile.writeAsBytesSync(outBytes);
        standardXlsxPath = stdFile.path;
      } catch (e) {
        xlsxLine = '⚠️ فشل ملء القالب: $e';
      }
    }

    final ignore = <int>{};
    try {
      for (final m in RegExp(r'\d+').allMatches(File('$baseDir/ignore.txt').readAsStringSync())) {
        ignore.add(int.parse(m.group(0)!));
      }
    } catch (_) {}
    final foundOrders =
        processedItems.where((e) => e.amount > 0).map((e) => e.orderNum).whereType<int>().toSet();
    missingTerminals = [
      for (var i = 1; i <= 19; i++)
        if (!foundOrders.contains(i) && !ignore.contains(i)) i
    ];
    writeReport(reportDate);

    setState(() => status = 'اكتمل!\n'
        '$xlsxLine\n'
        '• تم توليد ملف الـ PDF المجمع.' +
        (sourceNote.isEmpty ? '' : '\n$sourceNote'));
  }

  String subtitleOf(ReceiptItem item) {
    final sfx = item.suffix != null ? ' (باتش ${item.suffix})' : '';
    final bt = item.batches.length > 1
        ? '\n= ${item.batches.map((b) => b.toStringAsFixed(2)).join(' + ')}'
        : '';
    final alt = item.alt != null ? '\n⚠️ قراءة تانية: ${item.alt!.toStringAsFixed(2)}' : '';
    return 'TID: ${item.tid ?? 'غير محدد'}$sfx | المبلغ: ${item.amount.toStringAsFixed(2)} ج.م$bt$alt';
  }

  String warningsText() {
    final sb = StringBuffer('ملاحظات للمراجعة (${warnings.length}):');
    for (final w in warnings) {
      sb.write('\n• $w');
    }
    return sb.toString();
  }

  void writeReport(String date) {
    try {
      final line = '=' * 50;
      final sb = StringBuffer('تقرير المراجعة - $date\n$line\n');
      var total = 0.0;
      for (final r in processedItems) {
        final flags = <String>[];
        if (r.amount <= 0) flags.add('المبلغ غير مقروء');
        if (r.row == null) flags.add('الوحدة غير معروفة');
        if (!r.ok && r.amount > 0) flags.add('المبلغ يحتاج مراجعة');
        if (r.how == 'auto-number' || r.how == 'conflict' || r.how == 'extra-batch') {
          flags.add('رقم الماكينة: ${r.how}');
        }
        if (r.batches.length > 1) flags.add('${r.batches.length} باتشات');
        if (r.alt != null) flags.add('قراءة تانية: ${r.alt!.toStringAsFixed(2)}');
        if (r.amount > 0 && r.row != null) total += r.amount;
        final mark = flags.isEmpty ? '✓' : '⚠️';
        final extra = flags.isEmpty ? '' : '   [${flags.join(' | ')}]';
        sb.writeln('$mark ${baseName(r.path)}  ${r.unitName ?? '??'}  '
            '${r.amount.toStringAsFixed(2)}$extra');
      }
      sb.writeln(line);
      sb.writeln('الإجمالي العام: ${total.toStringAsFixed(2)} ج.م');
      if (missingTerminals.isNotEmpty) {
        sb.writeln('ماكينات ناقصة: ${missingTerminals.join(' ، ')}');
      }
      for (final w in warnings) {
        sb.writeln('- $w');
      }
      File('$outputDir/review_report.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync(sb.toString());
    } catch (_) {}
  }

  Future<void> runFullPipeline() async {
    try {
      await Permission.notification.request();
    } catch (_) {}
    try {
      await _chan.invokeMethod('startKeepAlive',
          {'title': 'A2R POS', 'text': 'جاري فحص الإيصالات...'});
    } catch (_) {}
    try {
      await _runPipelineInner();
    } finally {
      try {
        await _chan.invokeMethod('stopKeepAlive');
      } catch (_) {}
      if (_life != AppLifecycleState.resumed) {
        final rv = processedItems.where((e) => e.needsReview).length;
        final txt = 'تم فحص ${processedItems.length} إيصال'
            '${missingTerminals.isNotEmpty ? ' - ناقص ${missingTerminals.length} ماكينة' : ''}'
            '${rv > 0 ? ' - $rv للمراجعة' : ''}';
        try {
          await _chan.invokeMethod('notify', {'title': 'A2R POS - انتهى الفحص', 'text': txt});
        } catch (_) {}
      }
    }
  }

  Future<void> _runPipelineInner() async {
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
      status = 'جاري البحث عن مجلدات الصور...';
    });

    final dirs = customDir != null ? [Directory(customDir!)] : findWhatsAppImageDirs();

    final now = DateTime.now();
    final cutoff = days < 0
        ? DateTime(2000)
        : DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
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
          if (baseName(e.path).startsWith('.') || baseName(e.path).startsWith('dup_')) continue;
          if (fileDate(e).isBefore(cutoff)) continue;
          todo.add(e);
        }
      } catch (_) {}
    }
    todo.sort((a, b) => baseName(a.path).compareTo(baseName(b.path)));
    sourceNote = '';

    // مفيش صور؟ دوّر على PDF اسمه "الاسكندريه + تاريخ النهارده"
    if (todo.isEmpty) {
      setState(() => status = 'مفيش صور. بدوّر على ملف PDF اسمه "الاسكندريه ${todayToken()}"...');
      final searchDirs = <String>[];
      if (customDir != null) searchDirs.add(customDir!);
      for (final d in findWhatsAppImageDirs()) {
        final p = d.path;
        if (p.endsWith('WhatsApp Images')) {
          searchDirs.add(p.substring(0, p.length - 'WhatsApp Images'.length) + 'WhatsApp Documents');
        }
      }
      searchDirs.addAll([baseDir, '$root/Download', '$root/Documents']);
      final pdfs = findTodayAlexPdfs(searchDirs);
      if (pdfs.isNotEmpty) {
        final pages = await extractPdfPages(pdfs.first);
        if (pages.isNotEmpty) {
          todo.addAll(pages);
          sourceNote = '• المصدر: ملف PDF ${baseName(pdfs.first.path)} (${pages.length} صفحة)';
        }
      }
    }

    if (todo.isEmpty) {
      setState(() {
        busy = false;
        status = (dirs.isEmpty
                ? 'تعذر العثور على مجلد صور الواتساب تلقائياً.'
                : 'لا توجد صور في مجلد الواتساب بالفترة المحددة.') +
            '\nولا يوجد ملف PDF باسم "الاسكندريه ${todayToken()}".';
      });
      return;
    }

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    Directory(rawImagesDir).createSync(recursive: true);
    Directory(outputDir).createSync(recursive: true);
    try {
      File('$outputDir/ocr_debug.txt').writeAsStringSync('');
    } catch (_) {}
    final fixes = loadFixes();
    final rawReceipts = <ReceiptItem>[];

    // ═════════ المرحلة 1: قراءة الصور ═════════
    for (var i = 0; i < todo.length; i++) {
      final f = todo[i];
      try {
        Directory(tmpDir).createSync(recursive: true);
        var workPath = f.path;
        var res = await recognizer.processImage(InputImage.fromFilePath(workPath));
        var isReceipt = receiptScore(res.text) >= 2 || findTerminalIn([res.text]) != null;

        // صورة مقلوبة؟ جرّب EXIF ثم 90 / 270 / 180
        if (!isReceipt && autoRotate) {
          for (final deg in const [0, 90, 270, 180]) {
            final tp = '$tmpDir/rot_$deg.jpg';
            try {
              final wrote = await fixImageAsync(f.path, tp, deg);
              if (!wrote) continue;
              final r2 = await recognizer.processImage(InputImage.fromFilePath(tp));
              if (receiptScore(r2.text) >= 2 || findTerminalIn([r2.text]) != null) {
                res = r2;
                workPath = tp;
                isReceipt = true;
                break;
              }
            } catch (_) {}
          }
        }

        if (isReceipt) {
          final key = '${baseName(f.path)}:${f.lengthSync()}';
          final a = analyzeLines(toLines(res));

          // قراءة تانية بتنسيق مختلف (صورة محسّنة) علشان نكشف الأخطاء
          double? alt;
          // القراءة التانية بس للإيصالات اللي القراءة الأولى فيها مش مؤكدة (علشان السرعة)
          final needSecond = !a.ok || a.tid == null || a.row == null || a.val <= 0;
          if (needSecond) {
            try {
            final ep = '$tmpDir/enh.jpg';
            await enhanceImageAsync(workPath, ep);
            final res2 = await recognizer.processImage(InputImage.fromFilePath(ep));
            final a2 = analyzeLines(toLines(res2));
            try {
              File('$outputDir/ocr_debug.txt').writeAsStringSync(
                  '##### ${baseName(f.path)} (2nd read) total=${a2.val} ok=${a2.ok}\n',
                  mode: FileMode.append);
            } catch (_) {}
            alt = mergeSecondRead(a, a2);
            } catch (_) {}
          }

          if (a.tid == null) {
            final fnNum = int.tryParse(baseName(f.path).split('.').first);
            final ft = fnNum != null ? numToTid[fnNum] : null;
            if (ft != null && (a.row == null || terminals[ft]!.excelRow == a.row)) {
              a.tid = ft;
              a.row = terminals[ft]!.excelRow;
              a.unitName = terminals[ft]!.unitName;
              a.how = 'file-number';
            }
          }
          try {
            File('$outputDir/ocr_debug.txt').writeAsStringSync(
                '##### ${baseName(f.path)} => tid=${a.tid} how=${a.how} total=${a.val} ok=${a.ok} alt=$alt rotated=${workPath != f.path}\n'
                '${a.debug}\n--- raw ML Kit ---\n${res.text}\n\n',
                mode: FileMode.append);
          } catch (_) {}

          // نسخة الصورة اللي هتدخل الـ PDF (متظبطة الاتجاه)
          final inRaw = f.path.startsWith('$rawImagesDir/');
          final dst = inRaw ? f.path : '$rawImagesDir/wa_${baseName(f.path)}';
          File localFile;
          if (workPath != f.path) {
            final noExt = dst.contains('.') ? dst.substring(0, dst.lastIndexOf('.')) : dst;
            final jd = '$noExt.jpg';
            File(workPath).copySync(jd);
            if (jd != dst && inRaw) {
              try {
                File(dst).deleteSync();
              } catch (_) {}
            }
            localFile = File(jd);
          } else if (inRaw || File(dst).existsSync()) {
            localFile = File(dst);
          } else {
            await fixImageAsync(f.path, dst, 0); // نسخ + تصحيح EXIF لو لازم
            localFile = File(dst);
          }

          final item = ReceiptItem(
            path: localFile.path,
            tid: a.tid,
            orderNum: a.tid != null ? terminals[a.tid]!.orderNum : null,
            row: a.row,
            unitName: a.unitName,
            amount: a.val,
            date: a.date,
            key: key,
            ok: a.ok,
            how: a.how,
            batches: a.batches,
            alt: alt,
          );

          // تصحيح يدوي محفوظ من مرة سابقة
          final fx = fixes[key];
          if (fx is Map) {
            final v = fx['val'];
            if (v is num && v > 0) {
              item.amount = round2(v.toDouble());
              item.batches = [item.amount];
            }
            final ft = fx['tid'];
            if (ft is String && terminals.containsKey(ft)) {
              final t = tidAlias[ft] ?? ft;
              final info = terminals[t]!;
              item.tid = t;
              item.orderNum = info.orderNum;
              item.row = info.excelRow;
              item.unitName = info.unitName;
            }
            item.ok = true;
            item.alt = null;
            item.how = 'manual';
          }
          rawReceipts.add(item);
        }
      } catch (e) {
        warnings.add('${baseName(f.path)}: فشلت القراءة');
      }

      if (!mounted) return;
      setState(() {
        progress = ((i + 1) / todo.length) * 0.5;
        status = 'فحص OCR: ${i + 1} من ${todo.length}';
      });
    }

    await recognizer.close();

    if (rawReceipts.isEmpty) {
      setState(() {
        busy = false;
        status = 'تم فحص ${todo.length} صورة، ولم يتم العثور على إيصالات مطابقة.';
      });
      return;
    }

    // ═════════ المرحلة 2: التكرار وترقيم الماكينات ═════════
    setState(() => status = 'مراجعة التكرار وترقيم الماكينات...');
    final prio = <String, int>{'manual': 0, 'terminal': 0, 'fuzzy': 1, 'file-number': 2};
    final withTid = rawReceipts.where((r) => r.tid != null).toList();
    withTid.sort((a, b) {
      final c = (prio[a.how] ?? 3).compareTo(prio[b.how] ?? 3);
      return c != 0 ? c : rawReceipts.indexOf(a).compareTo(rawReceipts.indexOf(b));
    });

    final taken = <int, ReceiptItem>{};
    for (final r in withTid) {
      final n = r.orderNum!;
      final prev = taken[n];
      if (prev == null) {
        taken[n] = r;
      } else if (r.amount > 0 &&
          (prev.amount - r.amount).abs() < 0.005 &&
          sameDay(prev, r)) {
        r.skip = true; // نفس الماكينة ونفس المبلغ = إيصال مكرر
        warnings.add('${baseName(r.path)}: نفس الماكينة $n ونفس المبلغ '
            '${r.amount.toStringAsFixed(2)} (إيصال مكرر) - تم استبعاده');
      } else {
        r.origTid = r.tid;
        r.tid = null;
        r.conflict = true;
      }
    }

    final usedSuffix = <String>{};
    void giveSuffix(ReceiptItem r) {
      var k = 2;
      while (usedSuffix.contains('${r.origTid}:$k')) {
        k++;
      }
      usedSuffix.add('${r.origTid}:$k');
      r.tid = r.origTid;
      r.suffix = k;
      r.how = 'extra-batch';
    }

    for (final r in rawReceipts) {
      if (r.skip || r.tid != null || r.row == null) continue;
      if (r.conflict && (r.how == 'terminal' || r.how == 'fuzzy')) {
        giveSuffix(r); // نفس الماكينة بمبلغ مختلف = باتش إضافي
        continue;
      }
      final free = <int>[];
      for (var n = 1; n <= 19; n++) {
        if (terminals[numToTid[n]!]!.excelRow == r.row && !taken.containsKey(n)) {
          free.add(n);
        }
      }
      if (free.isNotEmpty) {
        final n = free.first;
        final t = numToTid[n]!;
        r.tid = t;
        r.orderNum = n;
        r.unitName = terminals[t]!.unitName;
        taken[n] = r;
        r.how = r.conflict ? 'conflict' : 'auto-number';
      } else if (r.origTid != null) {
        giveSuffix(r);
      }
    }

    final kept = rawReceipts.where((r) => !r.skip).toList();

    // التاريخ الأكثر تكراراً + تحذيرات
    final dateVotes = <String, int>{};
    for (final r in kept) {
      if (r.date != null) dateVotes[r.date!] = (dateVotes[r.date!] ?? 0) + 1;
    }
    final mainDate = mostCommon(dateVotes.keys.expand((k) => List.filled(dateVotes[k]!, k)).toList())?.key;

    for (final r in kept) {
      final nm = baseName(r.path);
      if (mainDate != null && r.date != null && r.date != mainDate) {
        warnings.add('$nm: تاريخ الإيصال ${r.date} بينما أغلب الإيصالات $mainDate');
      }
      if (r.row != null && r.amount > 0) {
        if (!r.ok) warnings.add('$nm: ${r.unitName} = ${r.amount.toStringAsFixed(2)} (راجع المبلغ يدوياً)');
        if (r.alt != null) {
          warnings.add('$nm: القراءة التانية للمبلغ ${r.alt!.toStringAsFixed(2)} مختلفة عن ${r.amount.toStringAsFixed(2)} - راجع الصورة');
        }
        if (r.how == 'extra-batch') {
          warnings.add('$nm: الماكينة ${r.orderNum} ظهرت في صورة تانية بمبلغ مختلف - اتحسبت كباتش إضافي ${r.suffix}');
        } else if (r.how == 'auto-number' || r.how == 'conflict') {
          warnings.add('$nm: رقم الماكينة اتحدد تلقائياً (${r.orderNum}) - اتأكد منه');
        } else if (!(r.how == 'terminal' || r.how == 'fuzzy' || r.how == 'manual')) {
          warnings.add('$nm: الوحدة اتحددت بالاسم/الميرشانت فقط');
        }
      } else {
        warnings.add('$nm: مش قادر أقرا المبلغ أو الوحدة - اضغط تعديل');
      }
    }

    // ═════════ المرحلة 3: إعادة التسمية (على مرحلتين عشان التعارض) ═════════
    setState(() => status = 'إعادة تسمية الصور وترتيبها...');
    final moves = <ReceiptItem>[];
    final newNames = <ReceiptItem, String>{};
    for (final r in kept) {
      if (r.tid == null || r.orderNum == null) continue;
      final ext = r.path.split('.').last;
      final sfx = r.suffix != null ? '_${r.suffix}' : '';
      final target = '$rawImagesDir/${r.orderNum}$sfx.$ext';
      if (r.path != target) {
        moves.add(r);
        newNames[r] = target;
      }
    }
    for (var k = 0; k < moves.length; k++) {
      final r = moves[k];
      final tmp = '$rawImagesDir/__tmp$k.${r.path.split('.').last}';
      try {
        r.path = File(r.path).renameSync(tmp).path;
      } catch (_) {}
    }
    for (final r in moves) {
      try {
        final dst = newNames[r]!;
        if (File(dst).existsSync()) File(dst).deleteSync();
        r.path = File(r.path).renameSync(dst).path;
      } catch (_) {}
    }

    processedItems.addAll(kept);
    await rebuildFiles();
    try {
      Directory(tmpDir).deleteSync(recursive: true);
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      busy = false;
      progress = 1.0;
    });
  }

  Widget _card(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final xlsx = latestOutput('.xlsx');
    final pdf = latestOutput('.pdf');
    final reviewCount = processedItems.where((e) => e.needsReview).length;
    return Scaffold(
      appBar: AppBar(title: const Text('A2R POS')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _card('الفترة', [
            Wrap(
              spacing: 8,
              children: [
                for (final o in const [
                  [0, 'اليوم'],
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
          ]),
          _card('المصدر والإخراج', [
            Text('المصدر: ${customDir ?? 'واتساب (تلقائي)'}',
                textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: busy ? null : pickFolder,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('فولدر الفحص'),
                  ),
                ),
                if (customDir != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: busy ? null : useWhatsApp,
                    child: const Text('واتساب'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text('الإخراج: ${customOut ?? '$defaultOutputDir (افتراضي)'}',
                textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: busy ? null : pickOutFolder,
                    icon: const Icon(Icons.drive_file_move_outline),
                    label: const Text('مكان الإخراج'),
                  ),
                ),
                if (customOut != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: busy ? null : useDefaultOut,
                    child: const Text('الافتراضي'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Expanded(child: Text('فحص الصور المقلوبة (أبطأ)')),
                Switch(
                  value: autoRotate,
                  onChanged: busy ? null : (v) => setState(() => autoRotate = v),
                ),
              ],
            ),
          ]),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: busy ? null : runFullPipeline,
              icon: const Icon(Icons.play_arrow),
              label: const Text('بدء المعالجة الشاملة'),
            ),
          ),
          if (busy) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress > 0 ? progress : null),
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(status),
          ),
          const SizedBox(height: 10),
          _card('الملفات الناتجة', [
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: xlsx == null
                        ? null
                        : () => openFile(xlsx,
                            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
                    icon: const Icon(Icons.table_chart),
                    label: const Text('فتح الإكسيل'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: pdf == null ? null : () => openFile(pdf, 'application/pdf'),
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('فتح PDF'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : sendToWhatsApp,
                    icon: const Icon(Icons.chat),
                    label: const Text('إرسال واتساب'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openFolder(outputDir),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('مكان الإخراج'),
                  ),
                ),
              ],
            ),
          ]),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : openReview,
                  icon: const Icon(Icons.fact_check),
                  label: Text('مراجعة ($reviewCount)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : clearAll,
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text('مسح الكل'),
                ),
              ),
            ],
          ),
          if (missingTerminals.isNotEmpty) ...[
            const SizedBox(height: 10),
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
                    '⚠️ ماكينات ناقصة (${missingTerminals.length} من 19):',
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
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 130),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                border: Border.all(color: Colors.orange.shade700),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: Text(warningsText(), style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
          const SizedBox(height: 10),
          for (final item in processedItems)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: Image.file(
                  File(item.path),
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                ),
                title: Text(
                  'ماكينة ${item.orderNum ?? '؟'} - ${item.unitName ?? 'وحدة غير معروفة'}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(subtitleOf(item)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.needsReview)
                      Icon(Icons.warning_amber, color: Colors.orange.shade800),
                    IconButton(
                      icon: const Icon(Icons.edit, color: Colors.teal),
                      onPressed: () => editReceiptDialog(item),
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


// ───────────────────── شاشة المراجعة ─────────────────────
class ReviewPage extends StatefulWidget {
  final List<ReceiptItem> items;
  const ReviewPage({super.key, required this.items});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  int idx = 0;
  bool changed = false;
  int rev = 0; // بيتغير لما الصورة تتدوّر علشان تتحدّث
  final done = <ReceiptItem>{};
  late TextEditingController amt;
  int? order;

  ReceiptItem get item => widget.items[idx];

  @override
  void initState() {
    super.initState();
    amt = TextEditingController();
    load();
  }

  @override
  void dispose() {
    amt.dispose();
    super.dispose();
  }

  void load() {
    amt.text = item.amount > 0 ? item.amount.toStringAsFixed(2) : '';
    order = item.orderNum;
  }

  void go(int i) {
    if (i < 0 || i >= widget.items.length) return;
    setState(() {
      idx = i;
      load();
    });
  }

  void save({bool next = true}) {
    final v = double.tryParse(amt.text.replaceAll(',', '.'));
    if (v == null || v <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اكتب مبلغ صحيح.')),
      );
      return;
    }
    final it = item;
    it.amount = round2(v);
    it.batches = [it.amount];
    it.ok = true;
    it.alt = null;
    it.how = 'manual';
    if (order != null) {
      it.orderNum = order;
      it.tid = numToTid[order];
      it.row = terminals[it.tid]!.excelRow;
      it.unitName = terminals[it.tid]!.unitName;
    }
    saveFix(it);
    changed = true;
    done.add(it);
    if (next && idx < widget.items.length - 1) {
      go(idx + 1);
    } else {
      setState(() {});
    }
  }

  Future<void> rotate() async {
    try {
      await fixImageAsync(item.path, item.path, 90);
      await FileImage(File(item.path)).evict();
      imageCache.clear();
      changed = true;
      setState(() => rev++);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('مقدرتش أدوّر الصورة.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = item;
    final image = Container(
      color: Colors.black12,
      child: InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: Image.file(File(it.path), key: ValueKey('${it.path}#$rev'), fit: BoxFit.contain),
        ),
      ),
    );

    final form = SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'المقروء: ${it.amount > 0 ? it.amount.toStringAsFixed(2) : 'غير مقروء'} ج.م'
            '${it.batches.length > 1 ? '  (= ${it.batches.map((b) => b.toStringAsFixed(2)).join(' + ')})' : ''}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (it.alt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('⚠️ القراءة التانية: ${it.alt!.toStringAsFixed(2)}',
                        style: TextStyle(color: Colors.orange.shade900)),
                  ),
                  TextButton(
                    onPressed: () => setState(() => amt.text = it.alt!.toStringAsFixed(2)),
                    child: const Text('استخدمها'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: amt,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'المبلغ الإجمالي',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            value: order,
            isExpanded: true,
            hint: const Text('اختر الماكينة (1..19)'),
            items: [
              for (var i = 1; i <= 19; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text('ماكينة $i - ${rowNames[terminals[numToTid[i]]!.excelRow]}'),
                ),
            ],
            onChanged: (v) => setState(() => order = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: rotate,
                icon: const Icon(Icons.rotate_right),
                label: const Text('تدوير'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => save(),
                  child: Text(idx < widget.items.length - 1 ? 'حفظ والتالي' : 'حفظ'),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('مراجعة ${idx + 1} / ${widget.items.length}'
              '${done.contains(it) ? '  ✓' : ''}'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, changed),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.navigate_before),
              tooltip: 'السابق',
              onPressed: idx > 0 ? () => go(idx - 1) : null,
            ),
            IconButton(
              icon: const Icon(Icons.navigate_next),
              tooltip: 'التالي',
              onPressed: idx < widget.items.length - 1 ? () => go(idx + 1) : null,
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth > 600) {
                return Row(
                  children: [
                    Expanded(flex: 3, child: image),
                    Expanded(flex: 2, child: form),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(flex: 3, child: image),
                  Expanded(flex: 2, child: form),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}


// ───────────────────── ملفات الماكينات (PDF لكل ماكينة) ─────────────────────
String? loadPdfDir() => _readCfg()['pdfDir'] as String?;

// فولدرات مستندات واتساب (جنب فولدرات الصور)
List<Directory> findWhatsAppDocDirs() {
  final out = <Directory>[];
  for (final d in findWhatsAppImageDirs()) {
    final p = d.path;
    if (p.endsWith('WhatsApp Images')) {
      final dd = Directory('${p.substring(0, p.length - 'WhatsApp Images'.length)}WhatsApp Documents');
      if (dd.existsSync() && !out.any((x) => x.path == dd.path)) out.add(dd);
    }
  }
  return out;
}

Set<String> loadDoneM() {
  final l = _readCfg()['doneM'];
  return l is List ? l.map((e) => e.toString()).toSet() : <String>{};
}

void saveDoneM(Set<String> s) {
  final m = _readCfg();
  final l = s.toList();
  m['doneM'] = l.length > 500 ? l.sublist(l.length - 500) : l;
  _writeCfg(m);
}

void savePdfDir(String? f) {
  final m = _readCfg();
  m['pdfDir'] = f;
  _writeCfg(m);
}

// الاسم الجديد: "1.أبيس.1.يوم.4.11" (وحدة فيها أكتر من ماكينة) أو "17.مديرية.الأمن.يوم.4.11"
String machineNewName(TerminalInfo info, String day, String month) {
  final same = terminals.values.where((t) => t.excelRow == info.excelRow).toList()
    ..sort((a, b) => a.orderNum.compareTo(b.orderNum));
  final unit = info.unitName.trim().replaceAll(RegExp(r'\s+'), '.');
  final k = same.indexWhere((t) => t.orderNum == info.orderNum) + 1;
  return [
    info.orderNum.toString(),
    unit,
    if (same.length > 1) '$k',
    'يوم',
    day,
    month,
  ].join('.');
}

class PageOcr {
  final String text;
  final List<OcrLine> lines;
  PageOcr(this.text, this.lines);
}

// الإيصال الدفع بس: بنعدّه برقم RRN (12 رقم) المميز لكل عملية دفع.
// إيصالات الإقفال والملخص وإعادة الطباعة مفيهاش RRN فمبتتعدّش.
class MScan {
  final Map<String, String?> rrnDay = {}; // rrn -> "يوم.شهر" أو null
  int sale = 0, auth = 0;
  bool nonPayment = false;
  String? tid, day, month;
  final List<String> otherDay = [];
  int get rrn => rrnDay.length;
  int get count {
    final a = rrn, b = sale, c = auth;
    if (a == b || a == c) return a;
    if (b == c) return b;
    return a > 0 ? a : (b > 0 ? b : c);
  }

  bool get agree => rrn == sale && sale == auth;
}

final RegExp _rrnRe = RegExp(r'(?<![\d*])(?!00)(\d{12})(?!\d)');
final RegExp _dateRe = RegExp(r'(20\d{2})[^\d\n]{1,3}(\d{2})[^\d\n]{1,3}(\d{2})');

String? _dayKey(String text) {
  for (final m in _dateRe.allMatches(text)) {
    final mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
    if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) return '$d.$mo';
  }
  return null;
}

MScan scanPages(List<PageOcr> pages) {
  final r = MScan();
  final all = pages.map((p) => p.text).join('\n');

  // عدد عمليات الدفع: RRN + ربط كل RRN بتاريخ أقرب سطر تاريخ ليه
  for (final p in pages) {
    final width = p.lines.isEmpty ? 1000.0 : p.lines.map((l) => l.right).reduce(math.max);
    final dates = <OcrLine>[];
    for (final l in p.lines) {
      if (_dayKey(l.text) != null) dates.add(l);
    }
    for (final l in p.lines) {
      for (final m in _rrnRe.allMatches(l.text)) {
        final rrn = m.group(1)!;
        String? day = _dayKey(l.text);
        if (day == null) {
          OcrLine? best;
          var bd = double.infinity;
          for (final d in dates) {
            final dy = (d.cy - l.cy).abs();
            final dx = ((d.left + d.right) / 2 - (l.left + l.right) / 2).abs();
            if (dy > l.h * 4 || dx > width * 0.22) continue;
            final dist = dy + dx * 0.5;
            if (dist < bd) {
              bd = dist;
              best = d;
            }
          }
          if (best != null) day = _dayKey(best.text);
        }
        if (!r.rrnDay.containsKey(rrn) || r.rrnDay[rrn] == null) r.rrnDay[rrn] = day;
      }
    }
  }
  // لو سطور الصفحة مش كفاية، نحسب من النص الكامل
  for (final m in _rrnRe.allMatches(all)) {
    r.rrnDay.putIfAbsent(m.group(1)!, () => null);
  }

  r.sale = RegExp(r'(VISA|MASTER|MEZZA|MEEZA|MEEZ)\w*\W{0,6}S[a-z]l[a-z]', caseSensitive: false)
      .allMatches(all)
      .length;
  r.auth = RegExp(r'AUTH\W{0,3}(\d{6})', caseSensitive: false)
      .allMatches(all)
      .map((m) => m.group(1)!)
      .toSet()
      .length;
  r.nonPayment = RegExp(
          r'GRAND\s*TOTAL|TOTAL\s*NET\s*AMOUNT|BATCH\s*CLOS|SUMMARY|REPRINT|DUPLICATE|SUCCESSF',
          caseSensitive: false)
      .hasMatch(all);

  // الماكينة: أكتر Terminal ID متكرر
  final tc = <String, int>{};
  for (final m in RegExp(r'(?<!\d)(\d{8})(?!\d)').allMatches(all)) {
    var c = m.group(1)!;
    c = tidFix[c] ?? c;
    if (terminals.containsKey(c)) tc[c] = (tc[c] ?? 0) + 1;
  }
  if (tc.isNotEmpty) {
    r.tid = tc.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  } else {
    r.tid = findTerminalIn([all]);
  }

  // اليوم الأغلب + الإيصالات اللي مش تبع نفس اليوم
  final dc = <String, int>{};
  for (final d in r.rrnDay.values) {
    if (d != null) dc[d] = (dc[d] ?? 0) + 1;
  }
  if (dc.isEmpty) {
    for (final m in _dateRe.allMatches(all)) {
      final k = _dayKey(m.group(0)!);
      if (k != null) dc[k] = (dc[k] ?? 0) + 1;
    }
  }
  if (dc.isNotEmpty) {
    final best = dc.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final parts = best.split('.');
    r.day = parts[0];
    r.month = parts[1];
    r.rrnDay.forEach((rrn, d) {
      if (d != null && d != best) {
        r.otherDay.add('إيصال ${rrn.substring(6)} بتاريخ $d');
      }
    });
  }
  return r;
}

class MResult {
  final String pdfName;
  String? openPath;
  int? orderNum;
  String? newName;
  int count = 0;
  String detail = '';
  bool ok = true;
  final List<String> notes = [];
  final TextEditingController ctl = TextEditingController();
  MResult(this.pdfName);
}

class MachinesPage extends StatefulWidget {
  const MachinesPage({super.key});

  @override
  State<MachinesPage> createState() => _MachinesPageState();
}

class _MachinesPageState extends State<MachinesPage> with WidgetsBindingObserver {
  String? pdfDir; // null = مستندات واتساب (تلقائي)
  int days = 3;
  bool skipDone = true;
  bool busy = false;
  String status = 'اضغط "فحص وإعادة تسمية" لفحص ملفات الماكينات من مستندات واتساب.';
  final List<MResult> results = [];
  final Map<String, String> expectedByName = {};
  AppLifecycleState _life = AppLifecycleState.resumed;
  String get destDir => '$baseDir/وحدات';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pdfDir = loadPdfDir();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final r in results) {
      r.ctl.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _life = state;
  }

  Future<void> openPdf(String? path) async {
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الملف مش موجود.')),
      );
      return;
    }
    try {
      final ok = await _chan.invokeMethod<bool>('openFile', {'path': path, 'mime': 'application/pdf'});
      if (ok == true) return;
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('مفيش برنامج يفتح الـ PDF.')),
    );
  }

  Future<void> pickDir() async {
    final perm = await Permission.manageExternalStorage.request();
    if (!perm.isGranted) {
      setState(() => status = 'لازم تسمح بالوصول لكل الملفات الأول.');
      return;
    }
    if (!mounted) return;
    final res = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FolderPicker(start: pdfDir ?? root)),
    );
    if (res != null) {
      savePdfDir(res);
      setState(() => pdfDir = res);
    }
  }

  Future<void> openDest() async {
    try {
      Directory(destDir).createSync(recursive: true);
    } catch (_) {}
    try {
      final ok = await _chan.invokeMethod<bool>('openFolder', {'path': destDir});
      if (ok == true) return;
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: destDir));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('مقدرتش أفتح الفولدر. المسار اتنسخ: $destDir')),
    );
  }

  Future<void> start() async {
    final perm = await Permission.manageExternalStorage.request();
    if (!perm.isGranted) {
      setState(() => status = 'لازم تسمح بالوصول لكل الملفات الأول.');
      return;
    }
    try {
      await Permission.notification.request();
    } catch (_) {}
    try {
      await _chan.invokeMethod(
          'startKeepAlive', {'title': 'A2R POS', 'text': 'جاري فحص ملفات الماكينات...'});
    } catch (_) {}
    try {
      await _scan();
    } finally {
      try {
        await _chan.invokeMethod('stopKeepAlive');
      } catch (_) {}
      if (_life != AppLifecycleState.resumed) {
        final total = results.fold<int>(0, (a, r) => a + r.count);
        try {
          await _chan.invokeMethod('notify', {
            'title': 'A2R POS - انتهى فحص الماكينات',
            'text': '${results.length} ملف، $total إيصال'
          });
        } catch (_) {}
      }
    }
  }

  Future<void> _scan() async {
    for (final r0 in results) {
      r0.ctl.dispose();
    }
    setState(() {
      busy = true;
      results.clear();
      status = 'جاري البحث عن ملفات PDF...';
    });
    final dirs = pdfDir != null ? [Directory(pdfDir!)] : findWhatsAppDocDirs();
    final now = DateTime.now();
    final cutoff = days < 0
        ? DateTime(2000)
        : DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
    final done = loadDoneM();
    final pdfs = <File>[];
    var skippedDone = 0;
    for (final d in dirs) {
      if (d.path == destDir) continue; // ما نفحصش ملفات فولدر وحدات (ناتج التطبيق)
      try {
        for (final e in d.listSync().whereType<File>()) {
          final n = baseName(e.path);
          if (!n.toLowerCase().endsWith('.pdf')) continue;
          if (_normAr(n).contains('اسكندري')) continue; // إخراج التطبيق نفسه
          if (fileDate(e).isBefore(cutoff)) continue;
          if (skipDone && done.contains('$n:${e.lengthSync()}')) {
            skippedDone++;
            continue;
          }
          pdfs.add(e);
        }
      } catch (_) {}
    }
    pdfs.sort((a, b) => baseName(a.path).compareTo(baseName(b.path)));
    if (pdfs.isEmpty) {
      setState(() {
        busy = false;
        status = dirs.isEmpty
            ? 'مش لاقي فولدر مستندات واتساب. اختار فولدر بإيدك.'
            : (skippedDone > 0
                ? 'كل الملفات في الفترة دي اتفحصت قبل كده ($skippedDone ملف).'
                : 'مفيش ملفات PDF في الفترة دي.');
      });
      return;
    }
    Directory(destDir).createSync(recursive: true);
    Directory(tmpDir).createSync(recursive: true);
    final rec = TextRecognizer(script: TextRecognitionScript.latin);
    final used = <String>{};
    for (var i = 0; i < pdfs.length; i++) {
      final f = pdfs[i];
      final r = MResult(baseName(f.path));
      setState(() => status = 'فحص ${i + 1} / ${pdfs.length}: ${r.pdfName}');
      try {
        final bytes = await f.readAsBytes();
        final pages = <PageOcr>[];
        var pg = 0;
        await for (final page in Printing.raster(bytes, dpi: 300)) {
          pg++;
          final png = await page.toPng();
          final tp = File('$tmpDir/m_$pg.png');
          await tp.writeAsBytes(png);
          final res = await rec.processImage(InputImage.fromFilePath(tp.path));
          pages.add(PageOcr(res.text, toLines(res)));
          try {
            tp.deleteSync();
          } catch (_) {}
        }
        final sc = scanPages(pages);
        r.count = sc.count;
        r.detail = 'RRN ${sc.rrn} • Sale ${sc.sale} • AUTH ${sc.auth}';
        if (!sc.agree) {
          r.ok = false;
          r.notes.add('القراءات مختلفة، راجع العدد يدوياً');
        }
        if (sc.otherDay.isNotEmpty) {
          r.ok = false;
          r.notes.add('مش تبع نفس اليوم: ${sc.otherDay.join(' ، ')}');
        }
        if (sc.nonPayment) {
          r.notes.add('فيه إيصال إقفال/ملخص/إعادة طباعة (اتجاهل ومش معدود)');
        }
        if (sc.tid == null) {
          r.ok = false;
          r.notes.add('مش قادر أعرف الماكينة من الـ PDF');
        } else {
          final info = terminals[sc.tid]!;
          r.orderNum = info.orderNum;
          var day = sc.day, month = sc.month;
          if (day == null) {
            final m = RegExp(r'(\d{2})-(\d{2})-(\d{4})').firstMatch(r.pdfName);
            if (m != null) {
              day = int.parse(m.group(1)!).toString();
              month = int.parse(m.group(2)!).toString();
            }
          }
          if (day == null || month == null) {
            r.ok = false;
            r.notes.add('مش قادر أعرف التاريخ');
          } else {
            var name = machineNewName(info, day, month);
            var final0 = name;
            var k = 2;
            while (used.contains(final0) || File('$destDir/$final0.pdf').existsSync()) {
              final0 = '${name}_$k';
              k++;
            }
            used.add(final0);
            await f.copy('$destDir/$final0.pdf');
            r.newName = final0;
            r.openPath = '$destDir/$final0.pdf';
            done.add('${baseName(f.path)}:${f.lengthSync()}');
          }
        }
      } catch (e) {
        r.ok = false;
        r.notes.add('فشل الفحص');
      }
      r.openPath ??= f.path;
      r.ctl.text = expectedByName[r.pdfName] ?? '';
      results.add(r);
      if (!mounted) return;
      setState(() => progressValue = (i + 1) / pdfs.length);
    }
    await rec.close();
    saveDoneM(done);
    try {
      Directory(tmpDir).deleteSync(recursive: true);
    } catch (_) {}
    results.sort((a, b) => (a.orderNum ?? 99).compareTo(b.orderNum ?? 99));
    final total = results.fold<int>(0, (a, r) => a + r.count);
    final named = results.where((r) => r.newName != null).length;
    setState(() {
      busy = false;
      progressValue = 0;
      status = 'اكتمل: ${results.length} ملف، $named اتسمّى واتنسخ في وحدات، إجمالي $total إيصال.';
    });
  }

  double progressValue = 0;

  List<String> missingMachines() {
    final got = results.map((r) => r.orderNum).whereType<int>().toSet();
    final out = <String>[];
    for (var n = 1; n <= 19; n++) {
      if (!got.contains(n)) out.add('$n ${terminals[numToTid[n]]!.unitName}');
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final missing = results.isEmpty ? <String>[] : missingMachines();
    return Scaffold(
      appBar: AppBar(title: const Text('ملفات الماكينات')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('الفترة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final o in const [
                        [0, 'اليوم'],
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
                  const Divider(height: 20),
                  const Text('المصدر',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 6),
                  Text('المصدر: ${pdfDir ?? 'واتساب - مستندات (تلقائي)'}',
                      textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: busy ? null : pickDir,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('اختيار فولدر'),
                        ),
                      ),
                      if (pdfDir != null) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: busy
                              ? null
                              : () {
                                  savePdfDir(null);
                                  setState(() => pdfDir = null);
                                },
                          child: const Text('واتساب'),
                        ),
                      ],
                    ],
                  ),
                  Row(
                    children: [
                      const Expanded(child: Text('تجاهل الملفات اللي اتفحصت قبل كده')),
                      Switch(
                        value: skipDone,
                        onChanged: busy ? null : (v) => setState(() => skipDone = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: busy ? null : start,
              icon: const Icon(Icons.play_arrow),
              label: const Text('فحص وإعادة تسمية'),
            ),
          ),
          if (busy) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progressValue > 0 ? progressValue : null),
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(status),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: openDest,
            icon: const Icon(Icons.folder_special),
            label: const Text('فتح فولدر وحدات'),
          ),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                border: Border.all(color: Colors.amber.shade800),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('⚠️ ماكينات ما وصلش ملفها (${missing.length}): ${missing.join(' ، ')}',
                  style: const TextStyle(fontSize: 13)),
            ),
          ],
          const SizedBox(height: 10),
          for (final r in results)
            Builder(builder: (context) {
              final e = int.tryParse(r.ctl.text.trim());
              final match = e == null ? null : e == r.count;
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                color: match == null
                    ? null
                    : (match ? Colors.green.shade100 : Colors.red.shade100),
                child: ListTile(
                  onTap: () => openPdf(r.openPath),
                  title: Text(r.newName ?? '؟ ${r.pdfName}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('الأصل: ${r.pdfName}\n'
                      'عدد إيصالات الدفع: ${r.count}  (${r.detail})'
                      '${r.notes.isEmpty ? '' : '\n⚠️ ${r.notes.join('\n⚠️ ')}'}'),
                  isThreeLine: true,
                  trailing: SizedBox(
                    width: 76,
                    child: TextField(
                      controller: r.ctl,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'الصح',
                        border: const OutlineInputBorder(),
                        filled: match != null,
                        fillColor: match == null
                            ? null
                            : (match ? Colors.green.shade300 : Colors.red.shade300),
                      ),
                      onChanged: (v) {
                        expectedByName[r.pdfName] = v;
                        setState(() {});
                      },
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
