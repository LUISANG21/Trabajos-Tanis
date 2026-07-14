
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';


class AppColors {
  static const yellow = Color(0xFFFFCF00);
  static const blue = Color(0xFF001A66);
  static const black = Color(0xFF000000);
  static const white = Color(0xFFFFFFFF);
  static const gray = Color(0xFFF7F7F7);
  static const border = Color(0xFFE7E7E7);
  static const muted = Color(0xFF5F6572);
}


void main() => runApp(const RockPhysApp());

class RockPhysApp extends StatelessWidget {
  const RockPhysApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RockPhys',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.gray,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.blue),
      ),
      home: const SplashScreen(),
    );
  }
}

enum UnitSystem { api, si, mixed }

enum EntryMode { complete, estimateFromDtp }

class UnitInfo {
  final String name, subtitle, vUnit, rhoUnit, dtpUnit, elasticUnit, cUnit, strengthUnit;
  const UnitInfo(this.name, this.subtitle, this.vUnit, this.rhoUnit, this.dtpUnit, this.elasticUnit, this.cUnit, this.strengthUnit);
}

const units = {
  // API / sistema inglés: velocidad en ft/s, densidad en lb/ft³, slowness en μs/ft.
  UnitSystem.api: UnitInfo('API', '', 'ft/s', 'lb/ft³', 'μs/ft', 'Mpsi', '1/Mpsi', 'ksi'),

  // SI / sistema internacional: velocidad en m/s, densidad en kg/m³, slowness en μs/m.
  UnitSystem.si: UnitInfo('SI', '', 'm/s', 'kg/m³', 'μs/m', 'GPa', '1/GPa', 'MPa'),

  // Mixed: basado en configuración tipo Mixed API de las capturas:
  // velocidad en ft/s, densidad tipo mud weight en g/cc, slowness en μs/ft,
  // y resultados de esfuerzo en unidades inglesas prácticas.
  UnitSystem.mixed: UnitInfo('Mixed', '', 'ft/s', 'g/cm³', 'μs/ft', 'Mpsi', '1/Mpsi', 'ksi'),
};

class InputData {
  final double vp, vs, rho, dtp;
  final UnitSystem system;
  final bool estimated;
  const InputData(this.vp, this.vs, this.rho, this.dtp, this.system, {this.estimated = false});
  UnitInfo get u => units[system]!;

  double get vpSI => u.vUnit == 'km/s' ? vp * 1000 : u.vUnit == 'ft/s' ? vp * 0.3048 : vp;
  double get vsSI => u.vUnit == 'km/s' ? vs * 1000 : u.vUnit == 'ft/s' ? vs * 0.3048 : vs;
  double get rhoSI => u.rhoUnit == 'g/cm³' ? rho * 1000 : u.rhoUnit == 'lb/ft³' ? rho * 16.01846337 : rho;
  double get dtpUsFt => estimated ? dtp : (u.dtpUnit == 'μs/m' ? dtp / 3.280839895 : dtp);

  String get vpLabel => '${fmtInput(vp)} ${u.vUnit}';
  String get vsLabel => '${fmtInput(vs)} ${u.vUnit}';
  String get rhoLabel => '${fmtInput(rho)} ${u.rhoUnit}';
  String get dtpLabel => estimated ? '${fmtInput(dtp)} μs/ft' : '${fmtInput(dtp)} ${u.dtpUnit}';
}

class Results {
  final double nu, g, e, k, c, ucs, fa, so;
  const Results(this.nu, this.g, this.e, this.k, this.c, this.ucs, this.fa, this.so);

  double elastic(UnitSystem s, double gpa) => units[s]!.elasticUnit == 'Mpsi' ? gpa * 0.1450377377 : gpa;
  double strength(UnitSystem s, double mpa) => units[s]!.strengthUnit == 'ksi' ? mpa * 0.1450377377 : mpa;
  double comp(UnitSystem s) => units[s]!.cUnit == '1/Mpsi' ? c / 0.1450377377 : c;
}

class Record {
  final String id;
  final DateTime date;
  final InputData input;
  final Results results;
  const Record(this.id, this.date, this.input, this.results);
}


class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const GeoElasticScreen(),
          transitionDuration: const Duration(milliseconds: 350),
          transitionsBuilder: (_, animation, __, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.blue,
      body: SizedBox.expand(
        child: Image.asset(
          'assets/app/splash_rockphys.png',
          fit: BoxFit.cover,
          alignment: Alignment.center,
        ),
      ),
    );
  }
}

class GeoElasticScreen extends StatefulWidget {
  const GeoElasticScreen({super.key});

  @override
  State<GeoElasticScreen> createState() => _GeoElasticScreenState();
}

class _GeoElasticScreenState extends State<GeoElasticScreen> {
  final formKey = GlobalKey<FormState>();
  final vp = TextEditingController();
  final vs = TextEditingController();
  final rho = TextEditingController();
  final dtp = TextEditingController();

  UnitSystem system = UnitSystem.api;
  EntryMode entryMode = EntryMode.complete;
  InputData? lastInput;
  Results? results;
  final List<Record> history = [];
  final Set<String> selected = {};

  @override
  void dispose() {
    vp.dispose();
    vs.dispose();
    rho.dispose();
    dtp.dispose();
    super.dispose();
  }

  UnitInfo get u => units[system]!;

  void newCalc() {
    setState(() {
      vp.clear();
      vs.clear();
      rho.clear();
      dtp.clear();
      lastInput = null;
      results = null;
      selected.clear();
    });
  }


  double velocityFromSI(double valueMetersPerSecond, UnitSystem targetSystem) {
    final unit = units[targetSystem]!.vUnit;
    if (unit == 'ft/s') return valueMetersPerSecond / 0.3048;
    if (unit == 'km/s') return valueMetersPerSecond / 1000.0;
    return valueMetersPerSecond;
  }

  double densityFromSI(double valueKgM3, UnitSystem targetSystem) {
    final unit = units[targetSystem]!.rhoUnit;
    if (unit == 'lb/ft³') return valueKgM3 / 16.01846337;
    if (unit == 'g/cm³') return valueKgM3 / 1000.0;
    return valueKgM3;
  }

  InputData buildEstimatedInput() {
    final dtpInput = double.parse(dtp.text.trim());

    // En modo estimado, ΔTp siempre se interpreta como μs/ft.
    final dtpUsFt = dtpInput;

    if (dtpUsFt <= 0) {
      throw Exception('ΔTp debe ser mayor que cero.');
    }

    // Modelo desde registro sónico compresional:
    // ΔTp en μs/ft → Vp en m/s.
    final vpMetersPerSecond = 304800.0 / dtpUsFt;

    // Modelo de Castagna:
    // Vp en km/s → Vs en km/s.
    final vpKmS = vpMetersPerSecond / 1000.0;
    final vsKmS = 0.862 * vpKmS - 1.172;
    if (vsKmS <= 0) {
      throw Exception('El modelo de Castagna generó una Vs no válida. Revisa ΔTp.');
    }
    final vsMetersPerSecond = vsKmS * 1000.0;

    // Modelo de Gardner:
    // Vp en m/s → ρ en g/cc, después se convierte internamente a kg/m³.
    final rhoGcc = 0.31 * math.pow(vpMetersPerSecond, 0.25).toDouble();
    final rhoKgM3 = rhoGcc * 1000.0;

    return InputData(
      velocityFromSI(vpMetersPerSecond, system),
      velocityFromSI(vsMetersPerSecond, system),
      densityFromSI(rhoKgM3, system),
      dtpInput,
      system,
      estimated: true,
    );
  }

  void calculate() {
    if (!formKey.currentState!.validate()) return;

    InputData input;

    try {
      if (entryMode == EntryMode.estimateFromDtp) {
        input = buildEstimatedInput();
      } else {
        input = InputData(
          double.parse(vp.text.trim()),
          double.parse(vs.text.trim()),
          double.parse(rho.text.trim()),
          double.parse(dtp.text.trim()),
          system,
        );
      }
    } catch (error) {
      showMsg(error.toString().replaceFirst('Exception: ', ''));
      return;
    }

    if (input.vpSI <= input.vsSI) {
      showMsg('Vp debe ser mayor que Vs.');
      return;
    }

    final r = compute(input);
    final rec = Record('#RMP-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}', DateTime.now(), input, r);

    setState(() {
      lastInput = input;
      results = r;
      history.insert(0, rec);
      if (history.length > 20) history.removeLast();
    });
  }

  Results compute(InputData i) {
    final vp = i.vpSI;
    final vs = i.vsSI;
    final rho = i.rhoSI;
    final dtp = i.dtpUsFt;

    final vp2 = vp * vp;
    final vs2 = vs * vs;

    final nu = (vp2 - 2 * vs2) / (2 * (vp2 - vs2));
    final g = rho * vs2 / 1e9;
    final e = rho * vs2 * ((3 * vp2 - 4 * vs2) / (vp2 - vs2)) / 1e9;
    final k = (rho * vp2 - (4 / 3) * rho * vs2) / 1e9;
    final c = 1 / k;

    final vpKmS = vp / 1000;
    final ucs = 1200 * math.exp(-0.036 * dtp);
    final ratio = ((vpKmS - 1) / (vpKmS + 1)).clamp(-1.0, 1.0);
    final fa = math.asin(ratio) * 180 / math.pi;
    final so = 5 * (vpKmS - 1) / math.sqrt(vpKmS);

    return Results(nu, g, e, k, c, ucs, fa, so);
  }

  void load(Record r) {
    setState(() {
      system = r.input.system;
      entryMode = r.input.estimated ? EntryMode.estimateFromDtp : EntryMode.complete;
      vp.text = fmtInput(r.input.vp);
      vs.text = fmtInput(r.input.vs);
      rho.text = fmtInput(r.input.rho);
      dtp.text = fmtInput(r.input.dtp);
      lastInput = r.input;
      results = r.results;
    });
    showMsg('Cálculo cargado.');
  }


  Future<void> downloadPdf() async {
    if (results == null || lastInput == null) {
      showMsg('Primero realiza un cálculo.');
      return;
    }

    final bytes = await buildPdf();
    await Printing.sharePdf(
      bytes: bytes,
      filename: 'rockphys_reporte.pdf',
    );
  }

  Future<Uint8List> buildPdf() async {
    final r = results!;
    final i = lastInput!;
    final doc = pw.Document();

    final blue = PdfColor.fromInt(0xFF001A66);
    final yellow = PdfColor.fromInt(0xFFFFCF00);
    final lightGray = PdfColor.fromInt(0xFFF7F7F7);
    final borderGray = PdfColor.fromInt(0xFFE7E7E7);
    final textGray = PdfColor.fromInt(0xFF5F6572);

    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final dateText = '${two(now.day)}/${two(now.month)}/${now.year}, ${two(now.hour)}:${two(now.minute)}';

    pw.MemoryImage? appLogo;
    try {
      final logoData = await rootBundle.load('assets/app/rockmech_logo.png');
      appLogo = pw.MemoryImage(logoData.buffer.asUint8List());
    } catch (_) {
      appLogo = null;
    }

    pw.Widget sectionTitle(String title) {
      return pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 7),
        decoration: pw.BoxDecoration(
          color: blue,
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Text(
          title,
          style: pw.TextStyle(
            color: PdfColors.white,
            fontWeight: pw.FontWeight.bold,
            fontSize: 10,
          ),
        ),
      );
    }

    pw.Widget compactTable(List<List<String>> rows) {
      return pw.Table(
        border: pw.TableBorder.all(color: borderGray, width: .55),
        columnWidths: const {
          0: pw.FlexColumnWidth(1.15),
          1: pw.FlexColumnWidth(1.45),
        },
        children: rows.map((row) {
          return pw.TableRow(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 5),
                child: pw.Text(
                  row[0],
                  style: pw.TextStyle(
                    color: blue,
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 8.2,
                  ),
                ),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 5),
                child: pw.Text(
                  row[1],
                  style: const pw.TextStyle(fontSize: 8.2),
                ),
              ),
            ],
          );
        }).toList(),
      );
    }

    final inputRows = <List<String>>[
      ['Método', i.estimated ? 'Estimación desde ΔTp + Castagna + Gardner' : 'Datos completos'],
      ['Sistema', i.u.name],
      ['ΔTp', i.dtpLabel],
      ['Vp', i.vpLabel],
      ['Vs', i.vsLabel],
      ['Densidad ρ', i.rhoLabel],
    ];

    final resultRows = <List<String>>[
      ['Poisson ν', fmt(r.nu, 2)],
      ['G', '${fmt(r.elastic(system, r.g), 2)} ${u.elasticUnit}'],
      ['E', '${fmt(r.elastic(system, r.e), 2)} ${u.elasticUnit}'],
      ['K', '${fmt(r.elastic(system, r.k), 2)} ${u.elasticUnit}'],
      ['C', '${fmt(r.comp(system), 4)} ${u.cUnit}'],
      ['UCS', '${fmt(r.strength(system, r.ucs), 1)} ${u.strengthUnit}'],
      ['FA', '${fmt(r.fa, 1)}°'],
      ['So', '${fmt(r.strength(system, r.so), 1)} ${u.strengthUnit}'],
    ];

    final noteText = i.estimated
        ? 'El cálculo estima Vp mediante Vp = 304800 / ΔTp, con ΔTp en μs/ft; estima Vs con Castagna: Vs = 0.862·Vp - 1.172, usando Vp en km/s; y estima la densidad mediante Gardner: ρ = 0.31 · Vp^0.25. Los módulos elásticos se calculan con relaciones isotrópicas y las propiedades de resistencia mediante correlaciones empíricas. Este reporte no sustituye validación petrofísica, calibración con núcleos ni interpretación geomecánica especializada.'
        : 'El cálculo utiliza los datos capturados por el usuario para estimar propiedades elásticas y de resistencia mediante relaciones isotrópicas y correlaciones empíricas. UCS usa ΔTp en μs/ft; FA y So usan Vp en km/s. Este reporte no sustituye validación petrofísica, calibración con núcleos ni interpretación geomecánica especializada.';

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(14),
                decoration: pw.BoxDecoration(
                  color: blue,
                  borderRadius: pw.BorderRadius.circular(10),
                ),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    if (appLogo != null)
                      pw.Container(
                        width: 54,
                        height: 54,
                        decoration: pw.BoxDecoration(
                          color: PdfColors.white,
                          borderRadius: pw.BorderRadius.circular(9),
                        ),
                        padding: const pw.EdgeInsets.all(3),
                        child: pw.Image(appLogo, fit: pw.BoxFit.cover),
                      )
                    else
                      pw.Container(width: 12, height: 54, color: yellow),
                    pw.SizedBox(width: 12),
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            'Reporte RockPhys',
                            style: pw.TextStyle(
                              color: PdfColors.white,
                              fontSize: 23,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                          pw.SizedBox(height: 3),
                          pw.Text(
                            'Propiedades mecánicas de roca a partir de ΔTp, Vp, Vs y densidad.',
                            style: const pw.TextStyle(color: PdfColors.white, fontSize: 9.3),
                          ),
                          pw.SizedBox(height: 5),
                          pw.Container(
                            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: pw.BoxDecoration(
                              color: yellow,
                              borderRadius: pw.BorderRadius.circular(12),
                            ),
                            child: pw.Text(
                              'by Grupo Tanis · Ingeniería y Consultoría',
                              style: pw.TextStyle(
                                color: blue,
                                fontSize: 8.5,
                                fontWeight: pw.FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Container(
                      padding: const pw.EdgeInsets.all(8),
                      decoration: pw.BoxDecoration(
                        color: lightGray,
                        borderRadius: pw.BorderRadius.circular(6),
                        border: pw.Border.all(color: borderGray, width: .7),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('Datos del reporte', style: pw.TextStyle(color: blue, fontWeight: pw.FontWeight.bold, fontSize: 10)),
                          pw.SizedBox(height: 5),
                          pw.Text('Muestra: 1', style: const pw.TextStyle(fontSize: 8.5)),
                          pw.Text('Fecha: $dateText', style: const pw.TextStyle(fontSize: 8.5)),
                          pw.Text('Responsable / área: No especificado', style: const pw.TextStyle(fontSize: 8.5)),
                        ],
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 10),
                  pw.Expanded(
                    child: pw.Container(
                      padding: const pw.EdgeInsets.all(8),
                      decoration: pw.BoxDecoration(
                        color: lightGray,
                        borderRadius: pw.BorderRadius.circular(6),
                        border: pw.Border.all(color: borderGray, width: .7),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('Grupo TANIS', style: pw.TextStyle(color: blue, fontWeight: pw.FontWeight.bold, fontSize: 10)),
                          pw.SizedBox(height: 5),
                          pw.Text('Correo: tanis.dvc@ttanis.com', style: const pw.TextStyle(fontSize: 8.5)),
                          pw.Text('Web: www.ttanis.com', style: const pw.TextStyle(fontSize: 8.5)),
                          pw.Text('LinkedIn: linkedin.com/company/grupo-tanis', style: const pw.TextStyle(fontSize: 8.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 10),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        sectionTitle('Datos de entrada'),
                        pw.SizedBox(height: 5),
                        compactTable(inputRows),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 10),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        sectionTitle('Resultados'),
                        pw.SizedBox(height: 5),
                        compactTable(resultRows),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 10),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  color: lightGray,
                  borderRadius: pw.BorderRadius.circular(6),
                  border: pw.Border.all(color: borderGray, width: .7),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Nota metodológica', style: pw.TextStyle(color: blue, fontWeight: pw.FontWeight.bold, fontSize: 10)),
                    pw.SizedBox(height: 4),
                    pw.Text(noteText, style: pw.TextStyle(color: textGray, fontSize: 7.6, lineSpacing: 1.1)),
                  ],
                ),
              ),
              pw.Spacer(),
              pw.Align(
                alignment: pw.Alignment.center,
                child: pw.Text(
                  'Documento generado automáticamente por RockPhys by Grupo Tanis.',
                  style: pw.TextStyle(color: textGray, fontSize: 8),
                ),
              ),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  void showMsg(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: AppColors.blue,
        child: SafeArea(
          child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: header()),
            SliverPadding(
              padding: const EdgeInsets.all(18),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  intro(),
                  const SizedBox(height: 16),
                  mainDesktopLayout(),
                  const SizedBox(height: 18),
                  formulaImagesSection(),
                  const SizedBox(height: 18),
                  historySection(),
                  const SizedBox(height: 16),
                  comparisonSection(),
                  const SizedBox(height: 16),
                  reportSection(),
                  const SizedBox(height: 16),
                  helpSection(),
                  const SizedBox(height: 16),
                  companyContactBanner(),
                  const SizedBox(height: 26),
                  const Text(
                    'Los resultados son estimaciones basadas en relaciones elásticas isotrópicas y correlaciones empíricas.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xff6b7280), fontSize: 12),
                  ),
                ]),
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }




  Widget companyContactBanner() {
    return shell(
      child: LayoutBuilder(
        builder: (context, c) {
          final logo = Container(
            width: c.maxWidth < 720 ? double.infinity : 360,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Image.asset('assets/tanis/tanis_logo_new.png', fit: BoxFit.contain),
          );

          const links = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ContactPill(icon: Icons.language, label: 'www.ttanis.com', url: 'https://www.ttanis.com'),
              ContactPill(icon: Icons.email_outlined, label: 'tanis.dvc@ttanis.com', url: 'mailto:tanis.dvc@ttanis.com'),
              ContactPill(icon: Icons.business_center_outlined, label: 'LinkedIn Grupo TTANIS', url: 'https://www.linkedin.com/company/grupo-ttanis'),
              ContactPill(icon: Icons.facebook_outlined, label: 'Facebook TTANIS', url: 'https://www.facebook.com/grupottanis'),
            ],
          );

          if (c.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                logo,
                const SizedBox(height: 14),
                links,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              logo,
              const SizedBox(width: 18),
              const Expanded(child: links),
            ],
          );
        },
      ),
    );
  }

  Widget formulaImagesSection() {
    return shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TitleLine(Icons.image_outlined, 'Modelos utilizados'),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, c) {
              final cols = c.maxWidth > 1150 ? 4 : c.maxWidth > 760 ? 2 : 1;
              return GridView.builder(
                itemCount: formulaItems.length,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: cols == 1 ? 1.72 : 1.04,
                ),
                itemBuilder: (_, index) {
                  final item = formulaItems[index];
                  final letter = String.fromCharCode(65 + index);
                  return Container(
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: AppColors.border),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Center(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.asset(
                                'assets/formula_images/formula_$letter.png',
                                fit: BoxFit.contain,
                                width: double.infinity,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '$letter. ${item.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.blue,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.eq,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.blue,
                            fontFamily: 'serif',
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  Widget mainDesktopLayout() {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 760) {
          return Column(
            children: [
              inputCard(),
              const SizedBox(height: 16),
              elasticCard(),
              const SizedBox(height: 16),
              strengthCard(),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 42,
              child: inputCard(),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 58,
              child: Column(
                children: [
                  elasticCard(),
                  const SizedBox(height: 16),
                  strengthCard(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget topCardsLayout() {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 760) {
          return Column(
            children: [
              inputCard(),
              const SizedBox(height: 16),
              elasticCard(),
              const SizedBox(height: 16),
              strengthCard(),
            ],
          );
        }

        if (c.maxWidth < 1120) {
          return Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: inputCard()),
                  const SizedBox(width: 16),
                  Expanded(child: elasticCard()),
                ],
              ),
              const SizedBox(height: 16),
              strengthCard(),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 36, child: inputCard()),
            const SizedBox(width: 16),
            Expanded(flex: 34, child: elasticCard()),
            const SizedBox(width: 16),
            Expanded(flex: 30, child: strengthCard()),
          ],
        );
      },
    );
  }

  Widget bottomCardsLayout() {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 900) {
          return Column(
            children: [
              summaryCard(),
              const SizedBox(height: 16),
              formulasCard(),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 36, child: summaryCard()),
            const SizedBox(width: 16),
            Expanded(flex: 64, child: formulasCard()),
          ],
        );
      },
    );
  }

  Widget responsive(List<Widget> children, {required List<int> wideFlex}) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 950) {
          return Column(children: [
            for (int i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1) const SizedBox(height: 16),
            ]
          ]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < children.length; i++) ...[
              Expanded(flex: wideFlex[i], child: children[i]),
              if (i < children.length - 1) const SizedBox(width: 16),
            ],
          ],
        );
      },
    );
  }

  Widget header() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: Color(0xffe4e8f2)))),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                child: Image.asset(
                  'assets/app/rockmech_logo.png',
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('RockPhys', style: TextStyle(fontSize: 29, fontWeight: FontWeight.w900, color: Color(0xff061d50), height: 1)),
                  const SizedBox(height: 4),
                  const Text('Mechanical Properties App', style: TextStyle(color: Color(0xff5f6b85), letterSpacing: 1.15)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0x0F001A66),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0x2E001A66)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.circle, size: 8, color: AppColors.yellow),
                        SizedBox(width: 8),
                        Text(
                          'by Grupo Tanis · Ingeniería y Consultoría',
                          style: TextStyle(
                            color: Color(0xff5f6b85),
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            ],
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 285,
                child: DropdownButtonFormField<UnitSystem>(
                  value: system,
                  decoration: deco('Sistema de unidades'),
                  items: UnitSystem.values.map((s) {
                    final info = units[s]!;
                    return DropdownMenuItem(value: s, child: Text(info.name));
                  }).toList(),
                  onChanged: (v) => setState(() => system = v ?? system),
                ),
              ),
              FilledButton.icon(
                onPressed: newCalc,
                icon: const Icon(Icons.add),
                label: const Text('Nuevo cálculo'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.yellow, foregroundColor: AppColors.blue, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16)),
              ),
              OutlinedButton.icon(
                onPressed: results == null ? null : downloadPdf,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Descargar PDF'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.blue,
                  side: const BorderSide(color: AppColors.white),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget intro() {
    return shell(
      backgroundColor: AppColors.blue,
      borderColor: AppColors.blue,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 12,
        children: [
          const SizedBox(
            width: 750,
            child: Text(
              'Cálculo de propiedades mecánicas de roca',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22, color: AppColors.yellow),
            ),
          ),
          badge('Sistema activo: ${u.name}'),
        ],
      ),
    );
  }


  double? currentDtpUsFt() {
    final rawDtp = double.tryParse(dtp.text.trim());
    if (rawDtp == null || rawDtp <= 0) return null;
    // En modo estimado, ΔTp siempre se interpreta como μs/ft.
    return rawDtp;
  }

  double? currentVpEstimatedMps() {
    final dtpUsFt = currentDtpUsFt();
    if (dtpUsFt == null || dtpUsFt <= 0) return null;
    return 304800.0 / dtpUsFt;
  }

  double? currentVsCastagnaMps() {
    final vpMps = currentVpEstimatedMps();
    if (vpMps == null || vpMps <= 0) return null;
    final vpKmS = vpMps / 1000.0;
    final vsKmS = 0.862 * vpKmS - 1.172;
    if (vsKmS <= 0) return null;
    return vsKmS * 1000.0;
  }

  double? currentRhoGardnerGcc() {
    final vpMps = currentVpEstimatedMps();
    if (vpMps == null || vpMps <= 0) return null;
    return 0.31 * math.pow(vpMps, 0.25).toDouble();
  }

  String estimatedVpPreviewText() {
    final vpMps = currentVpEstimatedMps();
    if (vpMps == null) return 'Ingresa ΔTp para estimar Vp';
    final active = velocityFromSI(vpMps, system);
    final activeUnit = units[system]!.vUnit;
    if (activeUnit == 'm/s') return '${fmt(vpMps, 1)} m/s';
    return '${fmt(vpMps, 1)} m/s · ${fmt(active, 1)} $activeUnit';
  }

  String estimatedVsPreviewText() {
    final vsMps = currentVsCastagnaMps();
    if (vsMps == null) return 'Ingresa ΔTp para estimar Vs';
    final active = velocityFromSI(vsMps, system);
    final activeUnit = units[system]!.vUnit;
    if (activeUnit == 'm/s') return '${fmt(vsMps, 1)} m/s';
    return '${fmt(vsMps, 1)} m/s · ${fmt(active, 1)} $activeUnit';
  }

  String estimatedRhoPreviewText() {
    final rhoGcc = currentRhoGardnerGcc();
    if (rhoGcc == null) return 'Ingresa ΔTp para estimar ρ';
    final rhoKgM3 = rhoGcc * 1000.0;
    final active = densityFromSI(rhoKgM3, system);
    final activeUnit = units[system]!.rhoUnit;
    if (activeUnit == 'g/cm³') return '${fmt(rhoGcc, 3)} g/cm³';
    return '${fmt(rhoGcc, 3)} g/cm³ · ${fmt(active, 2)} $activeUnit';
  }

  Widget entryModeButton({
    required EntryMode mode,
    required String label,
  }) {
    final selectedMode = entryMode == mode;

    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            entryMode = mode;
            results = null;
            lastInput = null;
          });
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: selectedMode ? AppColors.yellow : AppColors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selectedMode ? AppColors.yellow : AppColors.border,
              width: selectedMode ? 1.4 : 1,
            ),
          ),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.blue,
                fontWeight: selectedMode ? FontWeight.w900 : FontWeight.w700,
                fontSize: 12,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget inputCard() {
    final isEstimated = entryMode == EntryMode.estimateFromDtp;

    return shell(
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TitleLine(Icons.input, '1. Datos de entrada'),
            const SizedBox(height: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Método de entrada',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    entryModeButton(
                      mode: EntryMode.estimateFromDtp,
                      label: 'Estimar Vp y densidad desde ΔTp',
                    ),
                    const SizedBox(width: 8),
                    entryModeButton(
                      mode: EntryMode.complete,
                      label: 'Datos completos',
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              isEstimated
                  ? 'Usa este modo cuando solo cuentes con ΔTp. En este modo ΔTp se captura en μs/ft; Vp se estima desde ΔTp, Vs con Castagna y la densidad con Gardner.'
                  : 'Usa este modo cuando cuentes con ΔTp, Vp, Vs y densidad.',
              style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35),
            ),
            const SizedBox(height: 14),
            numberField('Slowness / Tiempo de tránsito ΔTp', isEstimated ? 'μs/ft' : u.dtpUnit, dtp),
            const SizedBox(height: 12),
            if (!isEstimated) ...[
              numberField('Velocidad de onda P (Vp)', u.vUnit, vp),
              const SizedBox(height: 12),
              numberField('Velocidad de onda S (Vs)', u.vUnit, vs),
              const SizedBox(height: 12),
              numberField('Densidad (ρ)', u.rhoUnit, rho),
              const SizedBox(height: 12),
            ],
            if (isEstimated) ...[
              derivedModelPreview(),
              const SizedBox(height: 14),
            ],
            FilledButton.icon(
              onPressed: calculate,
              icon: const Icon(Icons.calculate_outlined),
              label: const Text('Calcular propiedades'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.yellow, foregroundColor: AppColors.blue, padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
            const SizedBox(height: 10),
            const Text('Los resultados solo se actualizan al presionar el botón.', style: TextStyle(color: AppColors.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget derivedModelPreview() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7D0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.yellow),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Datos derivados por modelo', style: TextStyle(color: AppColors.blue, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          SummaryRowInline(label: 'Vp estimada', value: estimatedVpPreviewText()),
          SummaryRowInline(label: 'Vs Castagna', value: estimatedVsPreviewText()),
          SummaryRowInline(label: 'ρ Gardner', value: estimatedRhoPreviewText()),
          const SizedBox(height: 6),
          const Text(
            'Vp, Vs y ρ se estiman desde ΔTp. Castagna usa Vp en km/s y entrega Vs en km/s.',
            style: TextStyle(color: AppColors.muted, fontSize: 11),
          ),
          const SizedBox(height: 3),
          const Text(
            'Modelos: Vp = 304800 / ΔTp ; Vs = 0.862·Vp - 1.172 ; ρ = 0.31·Vp^0.25',
            style: TextStyle(color: AppColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget numberField(String label, String unit, TextEditingController controller) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(color: AppColors.yellow, fontWeight: FontWeight.w700),
      decoration: deco(label).copyWith(suffixText: unit),
      onChanged: (_) {
        if (entryMode == EntryMode.estimateFromDtp) {
          setState(() {});
        }
      },
      validator: (v) {
        final t = v?.trim() ?? '';
        if (t.isEmpty) return 'Campo requerido';
        final n = double.tryParse(t);
        if (n == null) return 'Número inválido';
        if (n <= 0) return 'Debe ser mayor que cero';
        return null;
      },
    );
  }

  Widget elasticCard() {
    final r = results;
    return shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TitleLine(Icons.science_outlined, '2. Módulo elástico'),
          const SizedBox(height: 14),
          resultRow('Relación de Poisson (ν)', r == null ? '—' : fmt(r.nu, 2), '-'),
          resultRow('Módulo de Corte (G)', r == null ? '—' : fmt(r.elastic(system, r.g), 2), u.elasticUnit),
          resultRow('Módulo de Young (E)', r == null ? '—' : fmt(r.elastic(system, r.e), 2), u.elasticUnit),
          resultRow('Módulo de Volumen (K)', r == null ? '—' : fmt(r.elastic(system, r.k), 2), u.elasticUnit),
          resultRow('Compresibilidad (C)', r == null ? '—' : fmt(r.comp(system), 4), u.cUnit),
          const Text('Propiedades calculadas a partir de Vp, Vs y ρ.', style: TextStyle(color: Color(0xff6b7280), fontSize: 12)),
        ],
      ),
    );
  }

  Widget strengthCard() {
    final r = results;
    return shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TitleLine(Icons.shield_outlined, '3. Propiedades de resistencia'),
          const SizedBox(height: 14),
          resultRow('UCS', r == null ? '—' : fmt(r.strength(system, r.ucs), 1), u.strengthUnit),
          resultRow('Ángulo de Fricción Interna (FA)', r == null ? '—' : fmt(r.fa, 1), '°'),
          resultRow('Cohesión (So)', r == null ? '—' : fmt(r.strength(system, r.so), 1), u.strengthUnit),
          const Text('UCS usa ΔTp en μs/ft. FA y So usan Vp en km/s.', style: TextStyle(color: Color(0xff6b7280), fontSize: 12)),
        ],
      ),
    );
  }

  Widget resultRow(String label, String value, String unit) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: Color(0xff10193d))),
          const SizedBox(width: 8),
          SizedBox(width: 60, child: Text(unit, textAlign: TextAlign.right, style: const TextStyle(color: Color(0xff6b7280), fontSize: 12))),
        ],
      ),
    );
  }

  Widget metricStrip() {
    final r = results;
    final cards = [
      metric('ν', 'Relación de Poisson', r == null ? '—' : fmt(r.nu, 2), '-', AppColors.yellow, AppColors.blue),
      metric('G', 'Módulo de Corte', r == null ? '—' : fmt(r.elastic(system, r.g), 2), u.elasticUnit, AppColors.blue, Colors.white),
      metric('E', 'Módulo de Young', r == null ? '—' : fmt(r.elastic(system, r.e), 2), u.elasticUnit, const Color(0xFF00124A), Colors.white),
      metric('K', 'Módulo de Volumen', r == null ? '—' : fmt(r.elastic(system, r.k), 2), u.elasticUnit, AppColors.black, Colors.white),
      metric('C', 'Compresibilidad', r == null ? '—' : fmt(r.comp(system), 4), u.cUnit, Colors.white, AppColors.blue, border: AppColors.border),
    ];

    return LayoutBuilder(builder: (_, c) {
      final cols = c.maxWidth > 1050 ? 5 : c.maxWidth > 650 ? 3 : 1;
      return GridView.count(
        crossAxisCount: cols,
        childAspectRatio: cols == 1 ? 3.2 : 2.1,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        children: cards,
      );
    });
  }

  Widget metric(String symbol, String title, String value, String unit, Color bg, Color fg, {Color? border}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18), border: Border.all(color: border ?? Colors.transparent)),
      child: Row(
        children: [
          Text(symbol, style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: fg)),
          const SizedBox(width: 12),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: fg.withOpacity(.88), fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(value, style: TextStyle(fontSize: 22, color: fg, fontWeight: FontWeight.w900)),
                  Text(unit, style: TextStyle(color: fg.withOpacity(.88), fontSize: 12)),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget summaryCard() {
    final i = lastInput;
    return shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TitleLine(Icons.assignment_outlined, 'Resumen de entrada'),
          const SizedBox(height: 12),
          summary('Vp', i?.vpLabel ?? '—'),
          summary('Vs', i?.vsLabel ?? '—'),
          summary('ρ', i?.rhoLabel ?? '—'),
          summary('ΔTp', i?.dtpLabel ?? '—'),
          const Divider(height: 26),
          summary('Sistema', u.name),
          summary('Método', i == null ? (entryMode == EntryMode.estimateFromDtp ? 'Estimación desde ΔTp' : 'Datos completos') : (i.estimated ? 'Estimación desde ΔTp + Castagna + Gardner' : 'Datos completos')),
          summary('Registros', history.length.toString()),
        ],
      ),
    );
  }

  Widget formulasCard({bool singleColumn = false, bool tall = false}) {
    return shell(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: tall ? 520 : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TitleLine(Icons.functions, 'Fórmulas utilizadas'),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, c) {
                final cols = singleColumn ? 1 : (c.maxWidth > 680 ? 2 : 1);
                return GridView.builder(
                  itemCount: formulaItems.length,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: cols == 1 ? 8.0 : 6.0,
                  ),
                  itemBuilder: (_, index) {
                    final f = formulaItems[index];
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: AppColors.gray,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          f.eq,
                          style: const TextStyle(
                            fontFamily: 'serif',
                            fontWeight: FontWeight.w700,
                            color: AppColors.blue,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget illustratedFormulas() {
    return shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TitleLine(Icons.image_outlined, 'Fórmulas ilustradas'),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (_, c) {
            final cols = c.maxWidth > 1100 ? 4 : c.maxWidth > 700 ? 2 : 1;
            return GridView.builder(
              itemCount: formulaItems.length,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                childAspectRatio: cols == 1 ? 2.4 : 1.25,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemBuilder: (_, index) => FormulaCard(item: formulaItems[index]),
            );
          }),
        ],
      ),
    );
  }

  Widget historySection() {
    return shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TitleLine(
            Icons.history,
            'Historial de cálculos',
            trailing: TextButton.icon(
              onPressed: history.isEmpty ? null : () => setState(() { history.clear(); selected.clear(); }),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Borrar'),
            ),
          ),
          const SizedBox(height: 12),
          if (history.isEmpty) empty('Todavía no hay cálculos guardados.') else SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('ID')),
                DataColumn(label: Text('Fecha')),
                DataColumn(label: Text('Vp')),
                DataColumn(label: Text('Vs')),
                DataColumn(label: Text('E')),
                DataColumn(label: Text('G')),
                DataColumn(label: Text('Acción')),
              ],
              rows: history.map((r) => DataRow(cells: [
                DataCell(Text(r.id)),
                DataCell(Text(dateTxt(r.date))),
                DataCell(Text(r.input.vpLabel)),
                DataCell(Text(r.input.vsLabel)),
                DataCell(Text('${fmt(r.results.elastic(r.input.system, r.results.e), 2)} ${r.input.u.elasticUnit}')),
                DataCell(Text('${fmt(r.results.elastic(r.input.system, r.results.g), 2)} ${r.input.u.elasticUnit}')),
                DataCell(TextButton(onPressed: () => load(r), child: const Text('Cargar'))),
              ])).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget comparisonSection() {
    final selectedRecords = history.where((r) => selected.contains(r.id)).toList();

    return shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TitleLine(Icons.compare_arrows, 'Comparaciones'),
          const SizedBox(height: 8),
          const Text('Selecciona hasta 3 cálculos del historial para compararlos.', style: TextStyle(color: Color(0xff6b7280))),
          const SizedBox(height: 12),
          if (history.isEmpty) empty('Primero realiza cálculos para poder compararlos.') else Wrap(
            spacing: 8,
            runSpacing: 8,
            children: history.take(10).map((r) {
              final isSelected = selected.contains(r.id);
              return FilterChip(
                label: Text(r.id),
                selected: isSelected,
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      if (selected.length >= 3) {
                        showMsg('Solo puedes comparar hasta 3 cálculos.');
                        return;
                      }
                      selected.add(r.id);
                    } else {
                      selected.remove(r.id);
                    }
                  });
                },
              );
            }).toList(),
          ),
          if (selectedRecords.isNotEmpty) ...[
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [const DataColumn(label: Text('Propiedad')), ...selectedRecords.map((r) => DataColumn(label: Text(r.id)))],
                rows: [
                  compRow('ν', selectedRecords, (r) => fmt(r.results.nu, 2)),
                  compRow('G', selectedRecords, (r) => '${fmt(r.results.elastic(r.input.system, r.results.g), 2)} ${r.input.u.elasticUnit}'),
                  compRow('E', selectedRecords, (r) => '${fmt(r.results.elastic(r.input.system, r.results.e), 2)} ${r.input.u.elasticUnit}'),
                  compRow('K', selectedRecords, (r) => '${fmt(r.results.elastic(r.input.system, r.results.k), 2)} ${r.input.u.elasticUnit}'),
                  compRow('C', selectedRecords, (r) => '${fmt(r.results.comp(r.input.system), 4)} ${r.input.u.cUnit}'),
                  compRow('UCS', selectedRecords, (r) => '${fmt(r.results.strength(r.input.system, r.results.ucs), 1)} ${r.input.u.strengthUnit}'),
                  compRow('FA', selectedRecords, (r) => '${fmt(r.results.fa, 1)}°'),
                  compRow('So', selectedRecords, (r) => '${fmt(r.results.strength(r.input.system, r.results.so), 1)} ${r.input.u.strengthUnit}'),
                ],
              ),
            )
          ],
        ],
      ),
    );
  }

  DataRow compRow(String name, List<Record> records, String Function(Record r) value) {
    return DataRow(cells: [DataCell(Text(name, style: const TextStyle(fontWeight: FontWeight.w800))), ...records.map((r) => DataCell(Text(value(r))))]);
  }

  Widget reportSection() {
    final r = results;
    final i = lastInput;
    return shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const TitleLine(Icons.description_outlined, 'Reporte del último cálculo'),
          const SizedBox(height: 12),
          if (r == null || i == null) empty('No hay cálculo disponible para reportar.') else Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              summary('Método', i.estimated ? 'Estimación desde ΔTp + Castagna + Gardner' : 'Datos completos'),
              summary('Entradas', 'ΔTp ${i.dtpLabel}, Vp ${i.vpLabel}, Vs ${i.vsLabel}, ρ ${i.rhoLabel}'),
              summary('Elasticidad', 'ν ${fmt(r.nu, 2)}, G ${fmt(r.elastic(system, r.g), 2)} ${u.elasticUnit}, E ${fmt(r.elastic(system, r.e), 2)} ${u.elasticUnit}, K ${fmt(r.elastic(system, r.k), 2)} ${u.elasticUnit}'),
              summary('Resistencia', 'UCS ${fmt(r.strength(system, r.ucs), 1)} ${u.strengthUnit}, FA ${fmt(r.fa, 1)}°, So ${fmt(r.strength(system, r.so), 1)} ${u.strengthUnit}'),
              const SizedBox(height: 8),
              const Text('La exportación formal a PDF puede agregarse después con paquetes como pdf y printing.', style: TextStyle(color: Color(0xff6b7280), fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget helpSection() {
    return shell(
      child: LayoutBuilder(builder: (_, c) {
        final help = notes('Ayuda rápida', Icons.help_outline, [
          'Selecciona el sistema de unidades.',
          'Elige si usarás datos completos o estimación desde ΔTp.',
          'Ingresa los datos requeridos y presiona Calcular propiedades.',
          'Consulta resultados, historial, comparaciones y reporte en esta misma pantalla.',
        ]);
        final tech = notes('Notas técnicas', Icons.engineering_outlined, [
          'Los módulos se calculan internamente con Vp/Vs en m/s y ρ en kg/m³.',
          'UCS se calcula con ΔTp en μs/ft.',
          'FA y So se calculan con Vp en km/s.',
          'Los resultados son estimaciones preliminares.',
        ]);

        if (c.maxWidth < 850) return Column(children: [help, const SizedBox(height: 16), tech]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: help), const SizedBox(width: 18), Expanded(child: tech)]);
      }),
    );
  }

  Widget notes(String title, IconData icon, List<String> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TitleLine(icon, title),
        const SizedBox(height: 10),
        ...items.map((t) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.check_circle, size: 17, color: Color(0xff2437c9)),
            const SizedBox(width: 8),
            Expanded(child: Text(t, style: const TextStyle(color: Color(0xff4b5563), height: 1.35))),
          ]),
        )),
      ],
    );
  }

  Widget shell({
    required Widget child,
    Color backgroundColor = const Color(0xFFFFFFFF),
    Color borderColor = AppColors.border,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: AppColors.blue.withOpacity(.08), blurRadius: 24, offset: const Offset(0, 12))],
      ),
      child: child,
    );
  }

  Widget badge(String txt) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: const Color(0xFFFFF7D0), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFFE680))),
      child: Text(txt, style: const TextStyle(color: Color(0xff7a5100), fontWeight: FontWeight.w800)),
    );
  }

  InputDecoration deco(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xffe4e8f2))),
    );
  }

  Widget summary(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 105, child: Text(label, style: const TextStyle(color: Color(0xff6b7280)))),
        Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xff10193d)))),
      ]),
    );
  }

  Widget empty(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: AppColors.gray, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
      child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xff6b7280))),
    );
  }
}

class TitleLine extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;

  const TitleLine(this.icon, this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      CircleAvatar(radius: 18, backgroundColor: AppColors.blue, child: Icon(icon, color: AppColors.yellow, size: 20)),
      const SizedBox(width: 10),
      Expanded(child: Text(title.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xff162279), fontSize: 14))),
      if (trailing != null) trailing!,
    ]);
  }
}


class ContactPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String url;

  const ContactPill({
    super.key,
    required this.icon,
    required this.label,
    required this.url,
  });

  Future<void> _openLink() async {
    final uri = Uri.parse(url);
    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );

    if (!opened) {
      debugPrint('No se pudo abrir: $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFFF7D0),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: _openLink,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.yellow),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: AppColors.blue),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.blue,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LogoMark extends StatelessWidget {
  final double size;
  const LogoMark({super.key, required this.size});

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: LogoPainter());
}

class LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final blueFill = Paint()..color = AppColors.blue;
    final yellowFill = Paint()..color = AppColors.yellow;
    final whiteStroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .055
      ..strokeCap = StrokeCap.round;
    final blueStroke = Paint()
      ..color = AppColors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .055
      ..strokeCap = StrokeCap.round;

    final hex = Path()
      ..moveTo(size.width * .5, size.height * .06)
      ..lineTo(size.width * .88, size.height * .28)
      ..lineTo(size.width * .88, size.height * .72)
      ..lineTo(size.width * .5, size.height * .94)
      ..lineTo(size.width * .12, size.height * .72)
      ..lineTo(size.width * .12, size.height * .28)
      ..close();

    canvas.drawPath(hex, blueFill);

    final goldCorner = Path()
      ..moveTo(size.width * .50, size.height * .94)
      ..lineTo(size.width * .88, size.height * .72)
      ..lineTo(size.width * .88, size.height * .58)
      ..cubicTo(size.width * .70, size.height * .70, size.width * .63, size.height * .88, size.width * .50, size.height * .94)
      ..close();
    canvas.drawPath(goldCorner, yellowFill);

    final pWave = Path()
      ..moveTo(size.width * .18, size.height * .42)
      ..cubicTo(size.width * .28, size.height * .30, size.width * .34, size.height * .54, size.width * .45, size.height * .42)
      ..cubicTo(size.width * .56, size.height * .30, size.width * .60, size.height * .56, size.width * .72, size.height * .43)
      ..cubicTo(size.width * .78, size.height * .36, size.width * .83, size.height * .38, size.width * .88, size.height * .36);
    canvas.drawPath(pWave, Paint()
      ..color = AppColors.yellow
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .065
      ..strokeCap = StrokeCap.round);

    final sWave = Path()
      ..moveTo(size.width * .18, size.height * .60)
      ..cubicTo(size.width * .29, size.height * .50, size.width * .34, size.height * .70, size.width * .46, size.height * .59)
      ..cubicTo(size.width * .58, size.height * .48, size.width * .61, size.height * .73, size.width * .74, size.height * .61)
      ..cubicTo(size.width * .80, size.height * .56, size.width * .84, size.height * .58, size.width * .88, size.height * .55);
    canvas.drawPath(sWave, whiteStroke);

    final nodePaint = Paint()..color = AppColors.white;
    final nodeBorder = Paint()
      ..color = AppColors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .035;

    final nodes = [
      Offset(size.width * .28, size.height * .28),
      Offset(size.width * .42, size.height * .22),
      Offset(size.width * .55, size.height * .30),
      Offset(size.width * .68, size.height * .24),
      Offset(size.width * .73, size.height * .72),
      Offset(size.width * .56, size.height * .78),
    ];

    for (int i = 0; i < nodes.length - 1; i++) {
      canvas.drawLine(nodes[i], nodes[i + 1], blueStroke);
    }
    for (final n in nodes) {
      canvas.drawCircle(n, size.width * .045, nodePaint);
      canvas.drawCircle(n, size.width * .045, nodeBorder);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}


class SummaryRowInline extends StatelessWidget {
  final String label;
  final String value;

  const SummaryRowInline({
    super.key,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.blue,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FormulaItem {
  final String title, eq, desc;
  final int type;
  const FormulaItem(this.title, this.eq, this.desc, this.type);
}

const formulaItems = [
  FormulaItem('Razón de Poisson', 'ν = (Vp² − 2Vs²) / [2(Vp² − Vs²)]', 'Deformación lateral y axial.', 0),
  FormulaItem('Módulo de Young', 'E = ρVs²(3Vp² − 4Vs²) / (Vp² − Vs²)', 'Rigidez ante carga axial.', 1),
  FormulaItem('Módulo de corte', 'G = ρVs²', 'Resistencia a deformación por corte.', 2),
  FormulaItem('Módulo volumétrico', 'K = ρVp² − 4/3ρVs²', 'Compresión hidrostática.', 3),
  FormulaItem('Compresibilidad', 'C = 1 / (ρVp² − 4/3ρVs²)', 'Cambio volumétrico por presión.', 4),
  FormulaItem('UCS', 'UCS = 1200 · e^(−0.036ΔTp)', 'Resistencia compresiva simple.', 5),
  FormulaItem('Ángulo de fricción interna', 'FA = sin⁻¹[(Vp − 1) / (Vp + 1)]', 'Criterio de Mohr-Coulomb.', 6),
  FormulaItem('Cohesión', 'So = 5 · (Vp − 1) / √Vp', 'Intercepto cohesivo.', 7),
];

class FormulaCard extends StatelessWidget {
  final FormulaItem item;
  const FormulaCard({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: AppColors.gray, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.border)),
      child: Row(children: [
        AspectRatio(aspectRatio: 1, child: CustomPaint(painter: FormulaPainter(item.type))),
        const SizedBox(width: 12),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 240,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.title, style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xff10193d))),
                const SizedBox(height: 5),
                Text(item.eq, style: const TextStyle(fontFamily: 'serif', fontWeight: FontWeight.w700, color: Color(0xff162279))),
                const SizedBox(height: 5),
                Text(item.desc, style: const TextStyle(color: Color(0xff6b7280), fontSize: 12)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class FormulaPainter extends CustomPainter {
  final int type;
  FormulaPainter(this.type);

  @override
  void paint(Canvas canvas, Size size) {
    final navy = Paint()
      ..color = const Color(0xff102a75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final dark = Paint()
      ..color = const Color(0xff2f3447)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final fill = Paint()
      ..color = const Color(0xffd9dbe2)
      ..style = PaintingStyle.fill;
    final gold = Paint()..color = const Color(0xfff5b800);

    final w = size.width, h = size.height;

    void block(Rect r) {
      canvas.drawRect(r, fill);
      canvas.drawRect(r, dark);
      canvas.drawLine(r.topRight, Offset(r.right + 10, r.top + 9), dark);
      canvas.drawLine(r.bottomRight, Offset(r.right + 10, r.bottom + 9), dark);
      canvas.drawLine(Offset(r.right + 10, r.top + 9), Offset(r.right + 10, r.bottom + 9), dark);
      canvas.drawLine(r.topLeft, Offset(r.left + 10, r.top + 9), dark);
      canvas.drawLine(Offset(r.left + 10, r.top + 9), Offset(r.right + 10, r.top + 9), dark);
    }

    switch (type) {
      case 0:
        block(Rect.fromLTWH(w * .36, h * .24, w * .27, h * .48));
        canvas.drawLine(Offset(w * .5, h * .06), Offset(w * .5, h * .21), navy);
        canvas.drawLine(Offset(w * .5, h * .94), Offset(w * .5, h * .78), navy);
        canvas.drawLine(Offset(w * .09, h * .5), Offset(w * .32, h * .5), navy);
        canvas.drawLine(Offset(w * .91, h * .5), Offset(w * .68, h * .5), navy);
        break;
      case 1:
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w*.18,h*.26,w*.18,h*.48), const Radius.circular(14)), fill);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w*.18,h*.26,w*.18,h*.48), const Radius.circular(14)), dark);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w*.48,h*.36,w*.18,h*.38), const Radius.circular(14)), fill);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w*.48,h*.36,w*.18,h*.38), const Radius.circular(14)), dark);
        canvas.drawLine(Offset(w*.27,h*.06), Offset(w*.27,h*.22), navy);
        canvas.drawLine(Offset(w*.57,h*.07), Offset(w*.57,h*.32), navy);
        canvas.drawLine(Offset(w*.75,h*.78), Offset(w*.94,h*.55), navy);
        break;
      case 2:
        final p = Path()..moveTo(w*.25,h*.65)..lineTo(w*.67,h*.65)..lineTo(w*.77,h*.78)..lineTo(w*.34,h*.78)..close();
        final q = Path()..moveTo(w*.25,h*.34)..lineTo(w*.67,h*.34)..lineTo(w*.77,h*.47)..lineTo(w*.34,h*.47)..close();
        canvas.drawPath(p, fill); canvas.drawPath(p, dark); canvas.drawPath(q, fill); canvas.drawPath(q, dark);
        canvas.drawLine(Offset(w*.16,h*.78), Offset(w*.05,h*.78), navy);
        canvas.drawLine(Offset(w*.3,h*.18), Offset(w*.78,h*.18), navy);
        break;
      case 3:
        block(Rect.fromLTWH(w*.36,h*.34,w*.28,h*.28));
        canvas.drawLine(Offset(w*.5,h*.06), Offset(w*.5,h*.28), navy);
        canvas.drawLine(Offset(w*.5,h*.94), Offset(w*.5,h*.7), navy);
        canvas.drawLine(Offset(w*.1,h*.5), Offset(w*.3,h*.5), navy);
        canvas.drawLine(Offset(w*.9,h*.5), Offset(w*.7,h*.5), navy);
        break;
      case 4:
        block(Rect.fromLTWH(w*.14,h*.34,w*.24,h*.34));
        block(Rect.fromLTWH(w*.66,h*.42,w*.14,h*.2));
        canvas.drawLine(Offset(w*.44,h*.52), Offset(w*.6,h*.52), dark);
        canvas.drawLine(Offset(w*.9,h*.52), Offset(w*.82,h*.52), navy);
        break;
      case 5:
        canvas.drawLine(Offset(w*.12,h*.83), Offset(w*.12,h*.2), dark);
        canvas.drawLine(Offset(w*.12,h*.83), Offset(w*.45,h*.83), dark);
        final curve = Path()..moveTo(w*.16,h*.28)..cubicTo(w*.2,h*.62,w*.3,h*.76,w*.44,h*.78);
        canvas.drawPath(curve, navy);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w*.62,h*.25,w*.2,h*.55), const Radius.circular(18)), fill);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w*.62,h*.25,w*.2,h*.55), const Radius.circular(18)), dark);
        break;
      case 6:
        canvas.drawLine(Offset(w*.12,h*.82), Offset(w*.12,h*.2), dark);
        canvas.drawLine(Offset(w*.12,h*.82), Offset(w*.86,h*.82), dark);
        canvas.drawLine(Offset(w*.12,h*.75), Offset(w*.78,h*.25), navy);
        canvas.drawCircle(Offset(w*.42,h*.62), w*.16, dark);
        block(Rect.fromLTWH(w*.68,h*.38,w*.16,h*.28));
        break;
      case 7:
        canvas.drawLine(Offset(w*.18,h*.82), Offset(w*.18,h*.16), dark);
        canvas.drawLine(Offset(w*.18,h*.82), Offset(w*.88,h*.82), dark);
        canvas.drawCircle(Offset(w*.32,h*.66), w*.04, gold);
        canvas.drawLine(Offset(w*.32,h*.66), Offset(w*.82,h*.24), navy);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant FormulaPainter oldDelegate) => oldDelegate.type != type;
}

String fmt(double value, int decimals) => value.isFinite ? value.toStringAsFixed(decimals) : '—';

String fmtInput(double value) {
  return value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
}

String dateTxt(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}
