import 'dart:convert';
import 'dart:io';

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
  "50382315": const TerminalInfo(9, 4, "المنتزه"), // ماكينة المنتزه 2 الجديدة
  "50383712": const TerminalInfo(9, 4, "المنتزه"), // بديل احتياطي لمنتزه 2
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
  9: "50382315", // المنتزه 2
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
};

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
  10: "ميناء الإسكندرية", 11: "مجمع خدمات",
};

// ───────────────────── خوارزميات الاستخراج ─────────────────────
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

String? findTerminal(String text) {
  final m = RegExp(r"TERMINAL\s*(?:ID)?\D{0,15}?(\d[\d\s]{6,9}\d)", caseSensitive: false)
      .firstMatch(text);
  if (m != null) {
    var raw = m.group(1)!.replaceAll(RegExp(r'\D'), '');
    if (raw.length >= 8) {
      var d = raw.substring(raw.length - 8);
      d = tidFix[d] ?? d;
      if (terminals.containsKey(d)) return d;
    }
  }
  for (final tid in terminals.keys) {
    if (text.contains(tid)) return tid;
  }
  for (final match in RegExp(r"\b(503\d{5})\b").allMatches(text)) {
    var c = match.group(1)!;
    c = tidFix[c] ?? c;
    if (terminals.containsKey(c)) return c;
  }
  return null;
}

String? findTerminalFuzzy(String text, int? targetRow) {
  final pool = terminals.entries
      .where((e) => targetRow == null || e.value.excelRow == targetRow)
      .map((e) => e.key)
      .toList();

  final runs = RegExp(r"\d[\d ]{6,14}\d").allMatches(text);
  String? bestTid;
  int minDiff = 99;

  for (final run in runs) {
    final digits = run.group(0)!.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8) continue;
    for (var i = 0; i <= digits.length - 8; i++) {
      final cand = digits.substring(i, i + 8);
      if (!cand.startsWith("50")) continue;
      for (final tid in pool) {
        int d = 0;
        for (var k = 0; k < 8; k++) {
          if (cand[k] != tid[k]) d++;
        }
        if (d < minDiff) {
          minDiff = d;
          bestTid = tid;
        }
      }
    }
  }
  if (minDiff <= 1) return bestTid;
  return null;
}

int? findUnitByExtra(String text) {
  final m = RegExp(r"MERCHANT\s*ID\D{0,15}?(\d[\d\s]{8,13}\d)", caseSensitive: false).firstMatch(text);
  final digits = m != null ? m.group(1)!.replaceAll(RegExp(r'\D'), '') : text.replaceAll(RegExp(r'\D'), '');
  final mm = RegExp(r"11470?(2[2-9]|3[01])084").firstMatch(digits);
  if (mm != null && merchantCodeMap.containsKey(mm.group(1))) {
    return merchantCodeMap[mm.group(1)];
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
    return "$d.$mo";
  }
  return null;
}

List<double> amountsIn(String text) {
  final out = <double>[];
  final reg = RegExp(r"(?<![\d,.])(\d{1,3}(?:,\d{3})*|\d+)[.,\s](\d{2})(?!\d)");
  for (final m in reg.allMatches(text)) {
    try {
      final whole = m.group(1)!.replaceAll(',', '');
      final dec = m.group(2)!;
      final v = double.tryParse("$whole.$dec");
      if (v != null && v >= 0.5 && v <= 5000000) {
        out.add(double.parse(v.toStringAsFixed(2)));
      }
    } catch (_) {}
  }
  return out;
}

double parseSingleReceiptText(String txt) {
  // 1. البحث الصريح في منطقة ما بعد GRAND TOTALS أو TOTALS GRAND
  final grandMatch = RegExp(r"(?:GRAND\s*TOTALS?|TOTALS?\s*GRAND)[\s\S]*?(?:THANK\s*YOU|Hotline|App\s*Version|$)", caseSensitive: false).firstMatch(txt);
  if (grandMatch != null) {
    final gAmts = amountsIn(grandMatch.group(0)!);
    if (gAmts.isNotEmpty) {
      return gAmts.reduce((a, b) => a > b ? a : b);
    }
  }

  // 2. البحث عن آخر Total Net Amount قبل نهاية الإيصال
  final netMatches = RegExp(r"Total\s*Net\s*Amount[\s\S]*?(\d{1,3}(?:,\d{3})*|\d+)[.,\s](\d{2})", caseSensitive: false).allMatches(txt);
  if (netMatches.isNotEmpty) {
    final lastNet = netMatches.last;
    final v = double.tryParse("${lastNet.group(1)!.replaceAll(',', '')}.${lastNet.group(2)!}");
    if (v != null && v >= 0.5) return double.parse(v.toStringAsFixed(2));
  }

  // 3. القاعدة الأساسية: أكبر مبلغ مسجل في الإيصال
  final allAmts = amountsIn(txt);
  if (allAmts.isNotEmpty) {
    return allAmts.reduce((a, b) => a > b ? a : b);
  }
  return 0.0;
}

double extractReceiptAmounts(String text) {
  final batchMatches = RegExp(r"BATCH\s*CLOSED|SUCCESSFULLY", caseSensitive: false).allMatches(text).toList();
  if (batchMatches.length > 1) {
    double totalCombined = 0.0;
    int prev = 0;
    for (var i = 1; i < batchMatches.length; i++) {
      final chunk = text.substring(prev, batchMatches[i].start);
      final amt = parseSingleReceiptText(chunk);
      if (amt > 0) totalCombined += amt;
      prev = batchMatches[i].start;
    }
    final lastChunk = text.substring(prev);
    final lastAmt = parseSingleReceiptText(lastChunk);
    if (lastAmt > 0) totalCombined += lastAmt;
    if (totalCombined > 0) return double.parse(totalCombined.toStringAsFixed(2));
  }

  return parseSingleReceiptText(text);
}

double round2(double val) => double.parse(val.toStringAsFixed(2));

// ───────────────────── مسارات المجلدات ─────────────────────
const String root = '/storage/emulated/0';
final String baseDir = '$root/all';
final String rawImagesDir = '$baseDir/raw_images';
final String outputDir = '$baseDir/output';
final String seenPath = '$baseDir/.app_seen.json';
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

// ───────────────────── نموذج الإيصال ─────────────────────
class ReceiptItem {
  String path;
  String? tid;
  int? orderNum;
  int? row;
  String? unitName;
  double amount;
  String? date;

  ReceiptItem({
    required this.path,
    this.tid,
    this.orderNum,
    this.row,
    this.unitName,
    this.amount = 0.0,
    this.date,
  });
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
  String? standardXlsxPath;
  String? advancedXlsxPath;
  String? generatedPdfPath;
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

  void resetSeen() {
    try {
      File(seenPath).deleteSync();
    } catch (_) {}
    setState(() => status = 'اتمسحت ذاكرة الفحص، الفحص القادم سيبدأ من الأول.');
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
    if (advancedXlsxPath != null && File(advancedXlsxPath!).existsSync()) {
      await Share.shareXFiles([XFile(advancedXlsxPath!)], text: 'تقرير إيصالات POS الشامل بالتفاصيل');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('التقرير الشامل غير متاح حالياً.')),
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
                final newAmt = double.tryParse(amtController.text) ?? item.amount;
                setState(() {
                  item.amount = round2(newAmt);
                  if (selectedOrder != null) {
                    item.orderNum = selectedOrder;
                    item.tid = numToTid[selectedOrder];
                    item.row = terminals[item.tid]!.excelRow;
                    item.unitName = terminals[item.tid]!.unitName;
                  }
                });
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
    processedItems.sort((a, b) => (a.orderNum ?? 99).compareTo(b.orderNum ?? 99));
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

    // حساب إجماليات الوحدات
    final unitTotals = <int, double>{};
    for (var r = 2; r <= 11; r++) {
      unitTotals[r] = 0.0;
    }
    for (final item in processedItems) {
      if (item.row != null && item.amount > 0) {
        unitTotals[item.row!] = (unitTotals[item.row!] ?? 0.0) + item.amount;
      }
    }

    final tplFile = File('$baseDir/الاسكندريه 00.xlsx');
    if (tplFile.existsSync()) {
      // 2. الملف الأول: طبق الأصل 100% من التمبلت الأصلي بدون أي تغيير في شكله أو أوراقه
      try {
        final bytes = tplFile.readAsBytesSync();
        final excel = xl.Excel.decodeBytes(bytes);
        final defaultSheet = excel.tables.keys.first;
        final sheet = excel[defaultSheet];

        for (var r = 2; r <= 11; r++) {
          final tot = round2(unitTotals[r] ?? 0.0);
          final cellD = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: r - 1));
          cellD.value = xl.DoubleCellValue(tot);

          final cellE = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: r - 1));
          double cashVal = 0.0;
          if (cellE.value != null && cellE.value is xl.DoubleCellValue) {
            cashVal = (cellE.value as xl.DoubleCellValue).value;
          }
          cashVal = round2(cashVal);

          final cellF = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: r - 1));
          cellF.value = xl.DoubleCellValue(round2(tot + cashVal));
        }

        final excelOutBytes = excel.encode();
        if (excelOutBytes != null) {
          final stdFile = File('$outputDir/الاسكندريه $reportDate.xlsx');
          stdFile.createSync(recursive: true);
          stdFile.writeAsBytesSync(excelOutBytes);
          standardXlsxPath = stdFile.path;
        }
      } catch (_) {}

      // 3. الملف الثاني: تقرير شامل منفصل تماماً باسم مختلف
      try {
        final bytesAdv = tplFile.readAsBytesSync();
        final excelAdv = xl.Excel.decodeBytes(bytesAdv);
        final defaultSheet = excelAdv.tables.keys.first;
        final sheetAdv = excelAdv[defaultSheet];

        double grandPos = 0.0;
        double grandCash = 0.0;

        for (var r = 2; r <= 11; r++) {
          final tot = round2(unitTotals[r] ?? 0.0);
          grandPos += tot;

          final cellD = sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: r - 1));
          cellD.value = xl.DoubleCellValue(tot);

          final cellE = sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: r - 1));
          double cashVal = 0.0;
          if (cellE.value != null && cellE.value is xl.DoubleCellValue) {
            cashVal = (cellE.value as xl.DoubleCellValue).value;
          }
          cashVal = round2(cashVal);
          grandCash += cashVal;

          final cellF = sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: r - 1));
          cellF.value = xl.DoubleCellValue(round2(tot + cashVal));
        }

        const rowTotalIndex = 11;
        sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowTotalIndex)).value =
            xl.TextCellValue('الإجمالي العام');
        sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowTotalIndex)).value =
            xl.IntCellValue(18);
        sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowTotalIndex)).value =
            xl.DoubleCellValue(round2(grandPos));
        sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowTotalIndex)).value =
            xl.DoubleCellValue(round2(grandCash));
        sheetAdv.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: rowTotalIndex)).value =
            xl.DoubleCellValue(round2(grandPos + grandCash));

        final detailSheet = excelAdv['تفاصيل الماكينات'];
        final headers = ['رقم الترتيب', 'اسم الوحدة', 'TID الماكينة', 'المبلغ (ج.م)', 'حالة الإيصال'];
        for (var c = 0; c < headers.length; c++) {
          detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0)).value =
              xl.TextCellValue(headers[c]);
        }

        for (var i = 1; i <= 18; i++) {
          final currentTid = numToTid[i]!;
          final info = terminals[currentTid]!;
          final matched = processedItems.where((e) => e.orderNum == i).toList();

          double amt = 0.0;
          for (final m in matched) {
            amt += m.amount;
          }

          detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: i)).value =
              xl.IntCellValue(i);
          detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: i)).value =
              xl.TextCellValue(info.unitName);
          detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: i)).value =
              xl.TextCellValue(currentTid);
          detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: i)).value =
              xl.DoubleCellValue(round2(amt));
          detailSheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: i)).value =
              xl.TextCellValue(matched.isNotEmpty ? 'تم الفحص بنجاح' : '⚠️ غير وارد (مفقود)');
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

    // حساب النواقص
    final foundOrders = processedItems.map((e) => e.orderNum).whereType<int>().toSet();
    missingTerminals = [for (var i = 1; i <= 18; i++) if (!foundOrders.contains(i)) i];

    setState(() => status = 'اكتمل بنجاح!\n'
        '• تم توليد التقرير الأصلي: الاسكندريه $reportDate.xlsx\n'
        '• تم توليد التقرير الشامل: تقرير_شامل_POS_$reportDate.xlsx\n'
        '• تم توليد ملف الـ PDF المجمع.');
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
      status = 'جاري البحث عن مجلدات الصور...';
    });

    final dirs = customDir != null ? [Directory(customDir!)] : findWhatsAppImageDirs();
    if (dirs.isEmpty) {
      setState(() {
        busy = false;
        status = 'تعذر العثور على مجلد صور الواتساب تلقائياً.';
      });
      return;
    }

    final now = DateTime.now();
    final cutoff = days < 0
        ? DateTime(2000)
        : DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
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

    if (todo.isEmpty) {
      setState(() {
        busy = false;
        status = 'لا توجد صور إيصالات جديدة في الفترة المحددة.';
      });
      return;
    }

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    Directory(rawImagesDir).createSync(recursive: true);
    Directory(outputDir).createSync(recursive: true);

    final rawReceipts = <ReceiptItem>[];

    // المرحلة 1: فحص الـ OCR واستخراج مبالغ الـ Grand Total الحقيقية
    for (var i = 0; i < todo.length; i++) {
      final f = todo[i];
      try {
        final res = await recognizer.processImage(InputImage.fromFilePath(f.path));
        final sc = receiptScore(res.text);
        seen['${baseName(f.path)}:${f.lengthSync()}'] = true;

        if (sc >= 2) {
          final dst = '$rawImagesDir/wa_${baseName(f.path)}';
          final localFile = File(dst).existsSync() ? File(dst) : f.copySync(dst);

          var tid = findTerminal(res.text);
          int? row;
          String? uName;
          int? order;

          final extraRow = findUnitByExtra(res.text);

          if (tid == null) {
            tid = findTerminalFuzzy(res.text, extraRow);
          }

          if (tid != null && terminals.containsKey(tid)) {
            final info = terminals[tid]!;
            order = info.orderNum;
            row = info.excelRow;
            uName = info.unitName;
          } else if (extraRow != null) {
            row = extraRow;
            uName = rowNames[extraRow];
          }

          final amt = extractReceiptAmounts(res.text);
          final d = findDate(res.text);

          rawReceipts.add(ReceiptItem(
            path: localFile.path,
            tid: tid,
            orderNum: order,
            row: row,
            unitName: uName,
            amount: amt,
            date: d,
          ));
        }
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        progress = ((i + 1) / todo.length) * 0.5;
        status = 'فحص OCR: ${i + 1} من ${todo.length}';
      });
    }

    await recognizer.close();
    saveSeen(seen);

    if (rawReceipts.isEmpty) {
      setState(() {
        busy = false;
        status = 'تم فحص ${todo.length} صورة، ولم يتم العثور على إيصالات مطابقة.';
      });
      return;
    }

    // المرحلة 2: إعادة التسمية
    setState(() => status = 'إعادة تسمية الصور وترتيبها...');
    final orderedReceipts = <ReceiptItem>[];
    for (final item in rawReceipts) {
      if (item.orderNum != null) {
        final ext = item.path.split('.').last;
        final newPath = '$rawImagesDir/${item.orderNum}.$ext';
        try {
          final renFile = File(item.path).renameSync(newPath);
          item.path = renFile.path;
        } catch (_) {}
      }
      orderedReceipts.add(item);
    }

    processedItems.addAll(orderedReceipts);
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
        title: const Text('إيصالات POS'),
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
                  tooltip: 'مشاركة التقرير الشامل المفصل',
                ),
              ],
            ),
            TextButton(
              onPressed: busy ? null : resetSeen,
              child: const Text('إعادة الفحص من الأول'),
            ),
            if (busy) LinearProgressIndicator(value: progress > 0 ? progress : null),
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
                  return Card(
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
                      subtitle: Text(
                        'TID: ${item.tid ?? 'غير محدد'} | المبلغ: ${item.amount.toStringAsFixed(2)} ج.م',
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
