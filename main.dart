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
  "50382315": const TerminalInfo(9, 4, "المنتزه"), // منتزه 2 الجديدة الأساسية
  "50383712": const TerminalInfo(9, 4, "المنتزه"), // منتزه 2 القديمة
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
  1: "50335710", 2: "50335993", 3: "50335987",
  4: "50325716", 5: "50335998", 6: "50335994", 7: "50335711",
  8: "50382298", 9: "50382315", 
  10: "50382306", 11: "50382316",
  12: "50382308", 13: "50383706", 14: "50382300", 15: "50383702",
  16: "50382312", 17: "50383699", 18: "50383700",
};

final Map<String, String> tidFix = {
  "50336994": "50335994", "50336711": "50335711", "50336998": "50335998",
  "50302316": "50382316", "50382318": "50382315", "50330987": "50335987",
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
  return _markers.where((r) => r.hasMatch(text)).length + (findTerminal(text) != null ? 1 : 0);
}

String? findTerminal(String rawText) {
  final text = normalizeOcrText(rawText);
  final m = RegExp(r"TERMINAL\s*(?:ID)?\D{0,15}?(\d[\d\s/]{6,10}\d)", caseSensitive: false).firstMatch(text);
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
  final pool = terminals.entries.where((e) => targetRow == null || e.value.excelRow == targetRow).map((e) => e.key).toList();
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
        if (d < (dist[tid] ?? 99)) dist[tid] = d;
      }
    }
  }
  if (dist.isEmpty) return null;
  final best = dist.values.reduce(min);
  final winners = dist.entries.where((e) => e.value == best).map((e) => e.key).toList();
  if (best <= 1 && winners.length == 1) return winners.first;
  return null;
}

int? findUnitByExtra(String rawText) {
  final text = normalizeOcrText(rawText);
  final m = RegExp(r"MERCHANT\s*(?:ID|10)\D{0,15}?(\d[\d\s/]{8,14}\d)", caseSensitive: false).firstMatch(text);
  final cands = <String>[];
  if (m != null) cands.add(m.group(1)!.replaceAll('/', '7').replaceAll(RegExp(r'\D'), ''));
  cands.add(text.replaceAll('/', '7').replaceAll(RegExp(r'\D'), ''));

  for (final d in cands) {
    final mm = RegExp(r"11470?(2[2-9]|3[01])084").firstMatch(d);
    if (mm != null && merchantCodeMap.containsKey(mm.group(1))) return merchantCodeMap[mm.group(1)];
  }

  final up = text.toUpperCase();
  for (final hint in nameHints) {
    if (hint.key.any((w) => up.contains(w))) return hint.value;
  }
  return null;
}

String? findDate(String text) {
  final m = RegExp(r"DATE\s*:?\s*(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})", caseSensitive: false).firstMatch(text);
  if (m != null) {
    final mo = int.tryParse(m.group(2)!) ?? 0;
    final d = int.tryParse(m.group(3)!) ?? 0;
    if (mo > 0 && d > 0) return "$d.$mo";
  }
  return null;
}

// ───────────────────── استخراج المبالغ بطريقة التجميع الذكية ─────────────────────
final RegExp _amountRe = RegExp(r"(?<![\d.,])(\d{1,3}(?:[\s.,]+\d{3})*|\d+)\s*[.,]\s*(\d{2})(?!\d)");

List<double> amountsIn(String rawText) {
  final text = normalizeOcrText(rawText);
  final out = <double>[];
  for (final m in _amountRe.allMatches(text)) {
    try {
      final whole = m.group(1)!.replaceAll(RegExp(r'[^\d]'), '');
      final dec = m.group(2)!;
      final v = double.tryParse("$whole.$dec");
      // تجاهل الأرقام الصغيرة لضمان التقاط الإجماليات فقط
      if (v != null && v >= 10.0 && v <= 5000000) {
        out.add(double.parse(v.toStringAsFixed(2)));
      }
    } catch (_) {}
  }
  return out;
}

class AmountDecision {
  final double amount;
  final bool confirmed;
  const AmountDecision(this.amount, this.confirmed);
}

// الدالة العبقرية لتخطي مشكلة قراءة الفلاتر الأفقية للصور التي تحتوي على أكثر من إيصال
AmountDecision extractReceiptAmountPythonStyle(String rawText) {
  final txt = normalizeOcrText(rawText);
  final allAmts = amountsIn(txt);
  if (allAmts.isEmpty) return const AmountDecision(0.0, false);

  // 1. كم إيصال (باتش) في هذه الصورة؟
  int batchCount = RegExp(r"BATCH", caseSensitive: false).allMatches(txt).length;
  int termCount = RegExp(r"TERMINAL", caseSensitive: false).allMatches(txt).length;
  int receiptCount = max(1, max(batchCount, termCount)); // أقل شيء إيصال واحد

  // 2. تجميع الأرقام المتشابهة (التي تكررت في نفس الإيصال كـ Sale و Total و Net)
  List<List<double>> groups = [];
  for (double a in allAmts) {
    bool added = false;
    for (var g in groups) {
      if ((g.first - a).abs() < 2.0) { // السماحية لتجاهل أخطاء الـ OCR البسيطة في القروش
        g.add(a);
        added = true;
        break;
      }
    }
    if (!added) groups.add([a]);
  }

  // 3. ترتيب المجموعات تنازلياً للحصول على المبالغ الأكبر (التي هي الـ GRAND TOTALS)
  groups.sort((a, b) => b.first.compareTo(a.first));

  double finalSum = 0.0;
  int receiptsFound = 0;
  bool confirmed = true;

  // 4. أخذ أكبر مبالغ تكررت بناءً على عدد الإيصالات الموجودة في الصورة
  for (var g in groups) {
    if (receiptsFound >= receiptCount) break;

    // كل إيصال يكرر مبلغه 3 مرات، إذا تكرر المبلغ 4-6 مرات فهذا يعني أن هناك إيصالين لهما نفس المبلغ بالضبط!
    int occurrences = g.length;
    int receiptsRepresented = (occurrences / 3).ceil();
    if (receiptsRepresented == 0) receiptsRepresented = 1;

    for (int i = 0; i < receiptsRepresented; i++) {
      if (receiptsFound >= receiptCount) break;
      finalSum += g.first;
      receiptsFound++;
      if (occurrences < 2) confirmed = false; // إذا لم يتكرر الرقم مرتين على الأقل، يحتاج مراجعة
    }
  }

  return AmountDecision(round2(finalSum), confirmed);
}

double round2(double val) => double.parse(val.toStringAsFixed(2));

// ───────────────────── مسارات المجلدات ─────────────────────
const String root = '/storage/emulated/0';
final String baseDir = '$root/all';
final String rawImagesDir = '$baseDir/raw_images';
final String outputDir = '$baseDir/output';
final String cfgPath = '$baseDir/.app_cfg.json';
final String fixPath = '$baseDir/.pos_fix.json';

String baseName(String path) => path.split('/').last;

String fileKey(String path) {
  final bytes = File(path).readAsBytesSync();
  return 'v4${crypto.md5.convert(bytes)}';
}

Map<String, dynamic> loadFixes() {
  try {
    final f = File(fixPath);
    if (f.existsSync()) return Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
  } catch (_) {}
  return {};
}

void saveFixes(Map<String, dynamic> fixes) {
  try {
    File(fixPath)..createSync(recursive: true)..writeAsStringSync(jsonEncode(fixes));
  } catch (_) {}
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
    if (d.existsSync() && !out.any((x) => x.path == d.path)) out.add(d);
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
      }
    }
  }
  return out;
}

DateTime fileDate(File f) {
  final m = RegExp(r'-(\d{8})-').firstMatch(baseName(f.path));
  if (m != null) {
    final s = m.group(1)!;
    final d = DateTime.tryParse('${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}');
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
    File(cfgPath)..createSync(recursive: true)..writeAsStringSync(jsonEncode({'folder': f}));
  } catch (_) {}
}

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
    required this.fn, required this.path, this.key, this.tid, this.origTid, this.orderNum,
    this.suffix, this.row, this.unitName, this.amount = 0.0, this.confirmed = false,
    this.how = "none", this.date, this.batchNo, this.skip = false, this.conflict = false, this.newName,
  });

  String get displayOrder => orderNum != null ? (suffix != null ? '${orderNum}_$suffix' : '$orderNum') : '؟';
}

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
    final res = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => FolderPicker(start: customDir ?? root)));
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
    if (standardXlsxPath != null && File(standardXlsxPath!).existsSync()) files.add(XFile(standardXlsxPath!));
    if (generatedPdfPath != null && File(generatedPdfPath!).existsSync()) files.add(XFile(generatedPdfPath!));
    if (files.isNotEmpty) await Share.shareXFiles(files, text: 'تقرير إيصالات الإسكندرية (الرسمي)');
    else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لم يتم إنشاء ملفات بعد.')));
  }

  Future<void> shareAdvancedFile() async {
    final files = <XFile>[];
    if (advancedXlsxPath != null && File(advancedXlsxPath!).existsSync()) files.add(XFile(advancedXlsxPath!));
    if (reportTxtPath != null && File(reportTxtPath!).existsSync()) files.add(XFile(reportTxtPath!));
    if (files.isNotEmpty) await Share.shareXFiles(files, text: 'التقرير الشامل للمراجعة');
    else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('التقرير الشامل غير متاح.')));
  }

  void assignTerminalsStage2(List<ReceiptItem> recs) {
    warnings.clear();
    for (final r in recs) {
      r.skip = false;
      r.conflict = false;
      r.suffix = null;
      if (r.origTid != null && r.tid == null) r.tid = r.origTid;
    }

    const prio = {"manual": 0, "terminal": 0, "fuzzy": 1, "file-number": 2};
    final taken = <String, ReceiptItem>{};

    final withTid = recs.where((x) => x.tid != null).toList()..sort((a, b) => (prio[a.how] ?? 3).compareTo(prio[b.how] ?? 3));

    for (final r in withTid) {
      final t = r.tid!;
      if (!taken.containsKey(t)) taken[t] = r;
      else if (r.amount > 0 && (taken[t]!.amount - r.amount).abs() < 0.005) r.skip = true;
      else {
        r.origTid = r.tid;
        r.tid = null;
        r.conflict = true;
      }
    }

    final usedSuffix = <String>{};
    void giveSuffix(ReceiptItem r, String targetTid) {
      var k = 2;
      while (usedSuffix.contains('${targetTid}_$k')) k++;
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

      if (r.how == "name/merchant") {
        final primaryEntries = terminals.entries.where((kv) => kv.value.excelRow == r.row).toList()..sort((a, b) => a.value.orderNum.compareTo(b.value.orderNum));
        if (primaryEntries.isNotEmpty) {
          final primaryTid = primaryEntries.first.key;
          if (!taken.containsKey(primaryTid)) {
            r.tid = primaryTid;
            r.orderNum = primaryEntries.first.value.orderNum;
            taken[primaryTid] = r;
            r.how = "auto-number";
          } else {
            giveSuffix(r, primaryTid);
          }
        }
        continue;
      }

      final freeEntries = terminals.entries.where((kv) => kv.value.excelRow == r.row && !taken.containsKey(kv.key)).toList()..sort((a, b) => a.value.orderNum.compareTo(b.value.orderNum));
      if (freeEntries.isNotEmpty) {
        final chosenTid = freeEntries.first.key;
        r.tid = chosenTid;
        r.orderNum = freeEntries.first.value.orderNum;
        taken[chosenTid] = r;
        r.how = r.conflict ? "conflict" : "auto-number";
      } else if (r.origTid != null) {
        giveSuffix(r, r.origTid!);
      } else {
        final unitEntries = terminals.entries.where((kv) => kv.value.excelRow == r.row).toList()..sort((a, b) => a.value.orderNum.compareTo(b.value.orderNum));
        if (unitEntries.isNotEmpty) giveSuffix(r, unitEntries.last.key);
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
          title: const Text('تعديل بيانات الإيصال'),
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
                      DropdownMenuItem(value: i, child: Text('ماكينة $i - ${rowNames[terminals[numToTid[i]]!.excelRow]}')),
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
                    fixes[item.key!] = {"val": item.amount, "tid": item.tid, "row": item.row, "date": item.date};
                    saveFixes(fixes);
                  }
                });
                Navigator.pop(ctx);
                assignTerminalsStage2(processedItems);
                rebuildFiles();
              },
              child: const Text('حفظ وتحديث'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> rebuildFiles() async {
    setState(() => status = 'جاري توليد الملفات...');

    final dateCounts = <String, int>{};
    for (final r in processedItems) {
      if (!r.skip && r.date != null) dateCounts[r.date!] = (dateCounts[r.date!] ?? 0) + 1;
    }
    String reportDate = dateCounts.isNotEmpty ? dateCounts.entries.reduce((a, b) => a.value > b.value ? a : b).key : "today";

    for (var k = 0; k < processedItems.length; k++) {
      final r = processedItems[k];
      final ext = r.path.split('.').last.toLowerCase();
      String targetName;
      if (r.skip) targetName = 'dup_${baseName(r.path)}';
      else if (r.orderNum != null) targetName = '${r.orderNum}${r.suffix != null ? '_${r.suffix}' : ''}.$ext';
      else continue;
      
      r.newName = targetName;
      final newPath = '$outputDir/$targetName'; // الحفظ المباشر في output
      if (r.path != newPath && File(r.path).existsSync()) {
        try {
          final fTmp = File(r.path).copySync(newPath);
          r.path = fTmp.path;
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
          pdf.addPage(pw.Page(pageFormat: PdfPageFormat.a4, build: (pw.Context ctx) => pw.Center(child: pw.Image(pw.MemoryImage(imgBytes), fit: pw.BoxFit.contain))));
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
      if (exact.existsSync()) { tplFile = exact; break; }
    }

    if (tplFile != null) {
      // تعديل ملف الإكسيل بحرص شديد للحفاظ على التنسيق
      try {
        final bytes = tplFile.readAsBytesSync();
        final excel = xl.Excel.decodeBytes(bytes);
        final sheet = excel[excel.tables.keys.first];

        for (var r = 2; r <= 11; r++) {
          final tot = unitTotals[r] ?? 0.0;
          final cnt = unitCounts[r] ?? 0;
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: r - 1)).value = xl.IntCellValue(cnt);
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: r - 1)).value = xl.DoubleCellValue(tot);
        }

        final excelOutBytes = excel.encode();
        if (excelOutBytes != null) {
          final stdFile = File('$outputDir/الاسكندريه $reportDate.xlsx');
          stdFile.createSync(recursive: true);
          stdFile.writeAsBytesSync(excelOutBytes);
          standardXlsxPath = stdFile.path;
        }
      } catch (_) {}
    }

    final foundOrders = processedItems.where((e) => !e.skip && e.orderNum != null && e.amount > 0).map((e) => e.orderNum!).toSet();
    final montazahCount = processedItems.where((e) => !e.skip && e.row == 4 && e.amount > 0).length;
    
    missingTerminals.clear();
    for (var i = 1; i <= 18; i++) {
        if (i == 8 || i == 9) continue; // المنتزه لها معالجة خاصة أدناه
        if (!foundOrders.contains(i)) missingTerminals.add(i);
    }
    
    if (montazahCount < 3) {
       missingTerminals.add(19); 
       numToTid[19] = "50383712";
       terminals["50383712"] = const TerminalInfo(19, 4, "المنتزه (ماكينة 3)");
    }

    final grandSum = unitTotals.values.fold(0.0, (a, b) => a + b);
    setState(() => status = 'اكتمل بنجاح! الإجمالي العام: ${grandSum.toStringAsFixed(2)} ج.م\n'
        '• تم وضع الصور المعدلة في مجلد الإخراج (output).');
  }

  Future<void> runFullPipeline() async {
    final perm = await Permission.manageExternalStorage.request();
    if (!perm.isGranted) {
      setState(() => status = 'يجب منح إذن الوصول لجميع الملفات.');
      return;
    }

    setState(() {
      busy = true;
      progress = 0;
      processedItems.clear();
      missingTerminals.clear();
      warnings.clear();
      status = 'جاري فحص الصور...';
    });

    final dirs = customDir != null ? [Directory(customDir!)] : findWhatsAppImageDirs();
    if (dirs.isEmpty) {
      setState(() { busy = false; status = 'تعذر العثور على مجلد الصور.'; });
      return;
    }

    final now = DateTime.now();
    final cutoff = days < 0 ? DateTime(2000) : DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
    final todo = <File>[];

    for (final d in dirs) {
      try {
        for (final e in d.listSync().whereType<File>()) {
          final fn = baseName(e.path);
          if (fn.startsWith('.') || fn.startsWith('dup_')) continue;
          final lower = fn.toLowerCase();
          if (!(lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp'))) continue;
          if (customDir == null && fileDate(e).isBefore(cutoff)) continue;
          todo.add(e);
        }
      } catch (_) {}
    }

    if (todo.isEmpty) {
      setState(() { busy = false; status = 'لا توجد صور في الفترة المحددة.'; });
      return;
    }

    final fixes = loadFixes();
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    Directory(rawImagesDir).createSync(recursive: true);
    Directory(outputDir).createSync(recursive: true);
    final rawReceipts = <ReceiptItem>[];

    for (var i = 0; i < todo.length; i++) {
      final f = todo[i];
      try {
        final key = fileKey(f.path);
        if (fixes.containsKey(key)) {
          final fx = Map<String, dynamic>.from(fixes[key] as Map);
          final dst = f.parent.path == rawImagesDir ? f.path : '$rawImagesDir/wa_${baseName(f.path)}';
          final localFile = File(dst).existsSync() ? File(dst) : f.copySync(dst);
          final tid = fx['tid'] as String?;
          rawReceipts.add(ReceiptItem(
            fn: baseName(localFile.path), path: localFile.path, key: key, tid: tid, origTid: tid,
            orderNum: tid != null ? terminals[tid]?.orderNum : null, row: fx['row'] as int?,
            unitName: fx['row'] != null ? rowNames[fx['row']] : null, amount: (fx['val'] as num).toDouble(),
            confirmed: true, how: "manual", date: fx['date'] as String?,
          ));
          continue;
        }

        final res = await recognizer.processImage(InputImage.fromFilePath(f.path));
        final sc = receiptScore(res.text);

        if (sc >= 2 || customDir == rawImagesDir) {
          final dst = f.parent.path == rawImagesDir ? f.path : '$rawImagesDir/wa_${baseName(f.path)}';
          final localFile = File(dst).existsSync() ? File(dst) : f.copySync(dst);
          final nameOnly = baseName(localFile.path).split('.').first;

          final decision = extractReceiptAmountPythonStyle(res.text);
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
            order = terminals[tid]!.orderNum;
            row = terminals[tid]!.excelRow;
            uName = terminals[tid]!.unitName;
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

          rawReceipts.add(ReceiptItem(
            fn: baseName(localFile.path), path: localFile.path, key: key, tid: tid, origTid: tid,
            orderNum: order, row: row, unitName: uName, amount: decision.amount,
            confirmed: decision.confirmed, how: how, date: findDate(res.text),
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
      setState(() { busy = false; status = 'لم يتم العثور على إيصالات مطابقة.'; });
      return;
    }

    assignTerminalsStage2(rawReceipts);
    processedItems.addAll(rawReceipts);
    await rebuildFiles();

    if (!mounted) return;
    setState(() { busy = false; progress = 1.0; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إيصالات POS (نسخة مطابقة للبايثون)'),
        actions: [IconButton(icon: const Icon(Icons.share), onPressed: busy ? null : shareStandardFiles)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              children: [for (final o in const [[0, 'اليوم'], [1, 'أمس واليوم'], [3, '3 أيام'], [7, 'أسبوع'], [-1, 'الكل']])
                ChoiceChip(label: Text(o[1] as String), selected: days == o[0], onSelected: busy ? null : (_) => setState(() => days = o[0] as int))],
            ),
            const SizedBox(height: 8),
            Text('المصدر: ${customDir ?? 'واتساب (تلقائي)'}', textDirection: TextDirection.ltr),
            Row(
              children: [
                TextButton.icon(onPressed: busy ? null : pickFolder, icon: const Icon(Icons.folder_open), label: const Text('اختيار فولدر')),
                if (customDir != null) TextButton(onPressed: busy ? null : useWhatsApp, child: const Text('رجوع للواتساب')),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(child: FilledButton.icon(onPressed: busy ? null : runFullPipeline, icon: const Icon(Icons.play_arrow), label: const Text('بدء المعالجة الشاملة'))),
                const SizedBox(width: 8),
                IconButton.filledTonal(onPressed: busy ? null : shareStandardFiles, icon: const Icon(Icons.share)),
              ],
            ),
            if (busy) ...[const SizedBox(height: 8), LinearProgressIndicator(value: progress > 0 ? progress : null)],
            const SizedBox(height: 8),
            Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(8)), child: Text(status)),
            if (missingTerminals.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.amber.shade100, border: Border.all(color: Colors.amber.shade800), borderRadius: BorderRadius.circular(8)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('⚠️ ماكينات ناقصة (${missingTerminals.length}):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber.shade900)),
                    const SizedBox(height: 4),
                    Text(missingTerminals.map((n) => '$n (${rowNames[terminals[numToTid[n]]!.excelRow]})').join(' ، '), style: const TextStyle(fontSize: 13)),
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
                    color: item.skip ? Colors.red.shade50 : (needsReview ? Colors.orange.shade50 : null),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: Image.file(File(item.path), width: 48, height: 48, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.receipt_long)),
                      title: Text(item.skip ? 'مكرر (مستبعد) - ماكينة ${item.displayOrder}' : 'ماكينة ${item.displayOrder} - ${item.unitName ?? 'وحدة غير معروفة'}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('TID: ${item.tid ?? 'غير محدد'} (${item.how})\nالمبلغ: ${item.amount.toStringAsFixed(2)} ج.م'),
                      trailing: IconButton(icon: const Icon(Icons.edit, color: Colors.teal), onPressed: () => editReceiptDialog(item)),
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

class FolderPicker extends StatefulWidget {
  final String start;
  const FolderPicker({super.key, required this.start});
  @override State<FolderPicker> createState() => _FolderPickerState();
}
class _FolderPickerState extends State<FolderPicker> {
  late String path = widget.start;
  List<Directory> dirs = [];
  String? error;
  @override void initState() { super.initState(); load(); }
  void load() {
    try {
      final l = Directory(path).listSync().whereType<Directory>().where((d) => !baseName(d.path).startsWith('.')).toList();
      l.sort((a, b) => baseName(a.path).toLowerCase().compareTo(baseName(b.path).toLowerCase()));
      dirs = l; error = null;
    } catch (_) { dirs = []; error = 'مش قادر أفتح الفولدر ده.'; }
  }
  void go(String p) => setState(() { path = p; load(); });
  @override Widget build(BuildContext context) {
    final canUp = path.length > root.length;
    return Scaffold(
      appBar: AppBar(title: const Text('اختيار فولدر')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(padding: const EdgeInsets.all(12), child: Text(path, textDirection: TextDirection.ltr)),
            if (error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(error!)),
            Expanded(child: ListView(children: [if (canUp) ListTile(leading: const Icon(Icons.arrow_upward), title: const Text('..'), onTap: () => go(Directory(path).parent.path)), for (final d in dirs) ListTile(leading: const Icon(Icons.folder), title: Text(baseName(d.path), textDirection: TextDirection.ltr), onTap: () => go(d.path))])),
            Padding(padding: const EdgeInsets.all(12), child: FilledButton(onPressed: () => Navigator.pop(context, path), child: const Text('اختيار هذا الفولدر'))),
          ],
        ),
      ),
    );
  }
}
