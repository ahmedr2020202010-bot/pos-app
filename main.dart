import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';

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

// ───────────────────── جداول الماكينات ─────────────────────
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
  "50383712": const TerminalInfo(9, 4, "المنتزه"),
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

final Map<String, String> tidFix = {
  "50336994": "50335994",
  "50336711": "50335711",
  "50336998": "50335998",
  "50302316": "50382316",
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

double extractAmountAccurate(String text) {
  final grandMatch = RegExp(r"GRAND\s*TOTALS?[\s\S]*?(?:THANK\s*YOU|Hotline|App\s*Version|$)", caseSensitive: false).firstMatch(text);
  if (grandMatch != null) {
    final grandText = grandMatch.group(0)!;
    final grandAmounts = amountsIn(grandText);
    if (grandAmounts.isNotEmpty) {
      return grandAmounts.reduce((a, b) => a > b ? a : b);
    }
  }

  final netMatches = RegExp(r"Total\s*Net\s*Amount[\s\S]*?(\d{1,3}(?:,\d{3})*|\d+)[.,\s](\d{2})", caseSensitive: false).allMatches(text);
  if (netMatches.isNotEmpty) {
    final lastNet = netMatches.last;
    final v = double.tryParse("${lastNet.group(1)!.replaceAll(',', '')}.${lastNet.group(2)!}");
    if (v != null && v >= 0.5) return double.parse(v.toStringAsFixed(2));
  }

  final allAmts = amountsIn(text);
  if (allAmts.isNotEmpty) {
    return allAmts.reduce((a, b) => a > b ? a : b);
  }
  return 0.0;
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
  final String path;
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
      status = 'جاري البحث عن مجلدات الصور...';
    });

    final dirs = customDir != null ? [Directory(customDir!)] : findWhatsAppImageDirs();
    if (dirs.isEmpty) {
      setState(() {
        busy = false;
        status = 'تعذر العثور على مجلد صور الواتساب تلقائياً، يمكنك اختياره من زر "اختيار فولدر".';
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
        status = 'لا توجد صور إيصالات جديدة في مجلد الواتساب بالفترة المحددة.';
      });
      return;
    }

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    Directory(rawImagesDir).createSync(recursive: true);
    Directory(outputDir).createSync(recursive: true);

    final rawReceipts = <ReceiptItem>[];

    // المرحلة 1: فحص الـ OCR
    for (var i = 0; i < todo.length; i++) {
      final f = todo[i];
      try {
        final res = await recognizer.processImage(InputImage.fromFilePath(f.path));
        final sc = receiptScore(res.text);
        seen['${baseName(f.path)}:${f.lengthSync()}'] = true;

        if (sc >= 2) {
          final dst = '$rawImagesDir/wa_${baseName(f.path)}';
          final localFile = File(dst).existsSync() ? File(dst) : f.copySync(dst);

          final tid = findTerminal(res.text);
          final amt = extractAmountAccurate(res.text);
          final d = findDate(res.text);

          int? order;
          int? row;
          String? uName;
          if (tid != null && terminals.containsKey(tid)) {
            final info = terminals[tid]!;
            order = info.orderNum;
            row = info.excelRow;
            uName = info.unitName;
          }

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

    // المرحلة 2: إعادة التسمية حسب رقم الماكينة (1..18)
    setState(() => status = 'إعادة تسمية الصور وترتيبها...');
    final orderedReceipts = <ReceiptItem>[];
    for (final item in rawReceipts) {
      if (item.orderNum != null) {
        final ext = item.path.split('.').last;
        final newPath = '$rawImagesDir/${item.orderNum}.$ext';
        try {
          final renFile = File(item.path).renameSync(newPath);
          orderedReceipts.add(ReceiptItem(
            path: renFile.path,
            tid: item.tid,
            orderNum: item.orderNum,
            row: item.row,
            unitName: item.unitName,
            amount: item.amount,
            date: item.date,
          ));
        } catch (_) {
          orderedReceipts.add(item);
        }
      } else {
        orderedReceipts.add(item);
      }
    }

    orderedReceipts.sort((a, b) => (a.orderNum ?? 99).compareTo(b.orderNum ?? 99));

    // تحديد تاريخ التقرير
    final dateCounts = <String, int>{};
    for (final r in orderedReceipts) {
      if (r.date != null) {
        dateCounts[r.date!] = (dateCounts[r.date!] ?? 0) + 1;
      }
    }
    String reportDate = "اليوم";
    if (dateCounts.isNotEmpty) {
      reportDate = dateCounts.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    }

    // المرحلة 3: توليد ملف الـ PDF
    setState(() => status = 'توليد ملف الـ PDF المجمع...');
    final pdf = pw.Document();
    for (final r in orderedReceipts) {
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

    // المرحلة 4: كتابة المبالغ والإجمالي المقرب بخانتين عشريتين في الإكسيل
    setState(() => status = 'تحديث شيت الإكسيل...');
    final unitTotals = <int, double>{};
    for (var r = 2; r <= 11; r++) {
      unitTotals[r] = 0.0;
    }
    for (final item in orderedReceipts) {
      if (item.row != null && item.amount > 0) {
        unitTotals[item.row!] = (unitTotals[item.row!] ?? 0.0) + item.amount;
      }
    }

    final tplFile = File('$baseDir/الاسكندريه 00.xlsx');
    if (tplFile.existsSync()) {
      try {
        final bytes = tplFile.readAsBytesSync();
        final excel = xl.Excel.decodeBytes(bytes);
        final defaultSheet = excel.tables.keys.first;
        final sheet = excel[defaultSheet];

        double grandPosTotal = 0.0;
        double grandCashTotal = 0.0;

        for (var r = 2; r <= 11; r++) {
          final tot = round2(unitTotals[r] ?? 0.0);
          grandPosTotal += tot;

          // العمود D (مبلغ POS)
          final cellD = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: r - 1));
          cellD.value = xl.DoubleCellValue(tot);

          // قراءة عمود الكاش إن وُجد (العمود E)
          final cellE = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: r - 1));
          double cashVal = 0.0;
          if (cellE.value != null && cellE.value is xl.DoubleCellValue) {
            cashVal = (cellE.value as xl.DoubleCellValue).value;
          }
          cashVal = round2(cashVal);
          grandCashTotal += cashVal;

          // العمود F (الإجمالي = POS + Cash) مقرب تماماً لخانتين
          final cellF = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: r - 1));
          cellF.value = xl.DoubleCellValue(round2(tot + cashVal));
        }

        // صف الإجمالي العام النهائي أسفل الجدول (الصف 12)
        final rowTotalIndex = 11; // يمثل Row 12
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowTotalIndex)).value =
            xl.TextCellValue('الإجمالي العام');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowTotalIndex)).value =
            xl.IntCellValue(18);
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowTotalIndex)).value =
            xl.DoubleCellValue(round2(grandPosTotal));
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowTotalIndex)).value =
            xl.DoubleCellValue(round2(grandCashTotal));
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: rowTotalIndex)).value =
            xl.DoubleCellValue(round2(grandPosTotal + grandCashTotal));

        final excelOutBytes = excel.encode();
        if (excelOutBytes != null) {
          File('$outputDir/الاسكندريه $reportDate.xlsx')
            ..createSync(recursive: true)
            ..writeAsBytesSync(excelOutBytes);
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      busy = false;
      progress = 1.0;
      processedItems.addAll(orderedReceipts);
      status = 'اكتمل بنجاح!\n'
          '• تم سحب وترقيم ${orderedReceipts.length} إيصال.\n'
          '• حُفظ الـ PDF: الاسكندريه $reportDate.pdf\n'
          '• حُفظ الإكسيل بمبالغ مقربة: الاسكندريه $reportDate.xlsx\n'
          'المسار: all/output';
    });
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
            FilledButton.icon(
              onPressed: busy ? null : runFullPipeline,
              icon: const Icon(Icons.play_arrow),
              label: const Text('بدء المعالجة الشاملة (PDF + إكسيل)'),
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
                        'TID: ${item.tid ?? '—'} | المبلغ: ${item.amount.toStringAsFixed(2)} ج.م',
                      ),
                      trailing: Text(item.path.split('/').last),
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
