// Renders one or more bench_viz JSON sample files into an HTML report with
// log-scale-x histogram SVGs.
//
// Usage:
//   dart bin/render.dart out/skeletal.json [out/foo.json ...] --out report.html

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

class BenchData {
  final String name;
  final int iterationsPerSample;
  final double durationSeconds;
  final List<double> meanMicrosPerOp;

  BenchData({
    required this.name,
    required this.iterationsPerSample,
    required this.durationSeconds,
    required this.meanMicrosPerOp,
  });

  factory BenchData.fromJson(Map<String, dynamic> j) {
    final iters = j['iterationsPerSample'] as int;
    final samples = (j['samples'] as List).cast<Map<String, dynamic>>();
    return BenchData(
      name: j['name'] as String,
      iterationsPerSample: iters,
      durationSeconds: (j['durationSeconds'] as num).toDouble(),
      meanMicrosPerOp: [
        for (final s in samples) (s['us'] as num).toDouble() / (s['iters'] as num),
      ],
    );
  }
}

void main(List<String> args) async {
  final inputs = <String>[];
  var outPath = 'out/report.html';
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--out' && i + 1 < args.length) {
      outPath = args[++i];
    } else {
      inputs.add(a);
    }
  }
  if (inputs.isEmpty) {
    stderr.writeln('Usage: dart bin/render.dart <json...> [--out report.html]');
    exit(64);
  }

  final benches = <BenchData>[];
  for (final p in inputs) {
    final raw = await File(p).readAsString();
    benches.add(BenchData.fromJson(jsonDecode(raw) as Map<String, dynamic>));
  }

  final out = File(outPath);
  await out.parent.create(recursive: true);
  await out.writeAsString(_renderHtml(benches));
  stdout.writeln('Wrote ${out.path}.');
}

// ---------------------------------------------------------------------------
// HTML / SVG rendering.
// ---------------------------------------------------------------------------

const _w = 720.0;
const _h = 240.0;
const _padL = 60.0;
const _padR = 20.0;
const _padT = 20.0;
const _padB = 40.0;
const _bins = 60;

String _renderHtml(List<BenchData> benches) {
  final sb = StringBuffer();
  sb.writeln('<!doctype html><html><head><meta charset="utf-8">');
  sb.writeln('<title>bench_viz report</title>');
  sb.writeln('<style>');
  sb.writeln('body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;'
      'margin:24px;color:#222;background:#fafafa}');
  sb.writeln('h1{font-size:18px;margin:0 0 16px} h2{font-size:15px;margin:24px 0 4px}');
  sb.writeln('.meta{color:#666;font-size:12px;margin-bottom:8px}');
  sb.writeln('.bar{fill:#4a86c5} .bar:hover{fill:#2a5e9a}');
  sb.writeln('.strip .iqr{fill:#4a86c5;fill-opacity:0.7}');
  sb.writeln('.strip .whisker{stroke:#888;stroke-width:1}');
  sb.writeln('.strip .med{fill:#222}');
  sb.writeln('.rowlbl{font-family:ui-monospace,monospace;font-size:9.5px;fill:#222}');
  sb.writeln('.axis{stroke:#333;stroke-width:1;fill:none}');
  sb.writeln('.tick{stroke:#333;stroke-width:1}');
  sb.writeln('.tlbl{font-size:10px;fill:#333;font-family:ui-monospace,monospace}');
  sb.writeln('.glbl{font-size:11px;fill:#333}');
  sb.writeln('.stat{font-family:ui-monospace,monospace;font-size:11px;'
      'color:#333;margin:4px 0 12px}');
  sb.writeln('.summary{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:12px;margin-top:24px}');
  sb.writeln('.box{background:#fff;border:1px solid #e0e0e0;padding:8px;border-radius:4px}');
  sb.writeln('</style></head><body>');
  sb.writeln('<h1>bench_viz: per-sample timing distributions</h1>');
  sb.writeln('<div class="meta">${benches.length} benchmarks</div>');

  // All-in-one strip chart: one row per benchmark on a shared log-x axis.
  if (benches.isNotEmpty) {
    sb.writeln('<h2>All benchmarks (one row each, shared log-x)</h2>');
    sb.writeln(_renderStripChart(benches));
  }

  // Per-benchmark detail blocks.
  for (final b in benches) {
    sb.writeln('<h2>${_esc(b.name)}</h2>');
    sb.writeln('<div class="meta">'
        'samples=${b.meanMicrosPerOp.length}, '
        'iters/sample=${b.iterationsPerSample}, '
        'duration=${b.durationSeconds.toStringAsFixed(1)}s'
        '</div>');
    sb.writeln(_renderHistogram(b.meanMicrosPerOp));
    sb.writeln('<div class="stat">${_statsLine(b.meanMicrosPerOp)}</div>');
  }

  // Summary: small multiples on a shared x-axis range.
  if (benches.length > 1) {
    sb.writeln('<h2>Summary (shared x-axis)</h2>');
    final range = _rangeAcrossBenches(benches);
    sb.writeln('<div class="summary">');
    for (final b in benches) {
      sb.writeln('<div class="box">');
      sb.writeln('<div class="meta">${_esc(b.name)}</div>');
      sb.writeln(_renderHistogram(b.meanMicrosPerOp, fixedRange: range));
      sb.writeln('</div>');
    }
    sb.writeln('</div>');
  }

  sb.writeln('</body></html>');
  return sb.toString();
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _renderStripChart(List<BenchData> benches) {
  // Layout.
  const labelW = 260.0;
  const padL = labelW + 4.0;
  const padR = 16.0;
  const padT = 36.0;
  const padB = 22.0;
  const rowH = 12.0;
  const w = 1180.0;
  final h = padT + padB + benches.length * rowH;
  final plotW = w - padL - padR;
  final plotH = benches.length * rowH;

  // Range covers every benchmark's full distribution. Pooling the raw
  // samples and trimming would let the bulk (fast benchmarks with many
  // samples each) drown out the slow benchmarks; instead we span from the
  // smallest min to the largest max across benches, snapped to whole
  // decades.
  final range = _rangeAcrossBenches(benches);
  double xPos(double us) {
    final lx = math.log(us) / math.ln10;
    return padL + plotW * (lx - range.loLog) / (range.hiLog - range.loLog);
  }

  // Sort benches by median for an easier read.
  final sorted = [...benches]..sort((a, b) {
    final am = _percentile(a.meanMicrosPerOp, 0.5);
    final bm = _percentile(b.meanMicrosPerOp, 0.5);
    return am.compareTo(bm);
  });

  final sb = StringBuffer();
  sb.writeln('<svg viewBox="0 0 $w ${_n(h)}" xmlns="http://www.w3.org/2000/svg" '
      'class="strip">');

  // X-axis at top.
  sb.writeln('<path class="axis" d="M${_n(padL)} ${_n(padT - 2)} '
      'L${_n(padL + plotW)} ${_n(padT - 2)}"/>');
  for (final t in _logTicks(range.loLog, range.hiLog)) {
    final x = padL + plotW * (t.logV - range.loLog) / (range.hiLog - range.loLog);
    final tickH = t.major ? 6.0 : 3.0;
    sb.writeln('<line class="tick" x1="${_n(x)}" y1="${_n(padT - 2)}" '
        'x2="${_n(x)}" y2="${_n(padT - 2 - tickH)}"/>');
    if (t.label != null) {
      sb.writeln('<text class="tlbl" x="${_n(x)}" y="${_n(padT - 14)}" '
          'text-anchor="middle">${t.label}</text>');
    }
    // Faint vertical guide running through every row.
    sb.writeln('<line x1="${_n(x)}" y1="${_n(padT - 2)}" '
        'x2="${_n(x)}" y2="${_n(padT - 2 + plotH)}" '
        'stroke="${t.major ? '#dcdcdc' : '#ececec'}" stroke-width="0.5"/>');
  }

  // Rows.
  for (var i = 0; i < sorted.length; i++) {
    final b = sorted[i];
    final yMid = padT + i * rowH + rowH / 2;
    // Label.
    sb.writeln('<text class="rowlbl" x="${_n(labelW - 4)}" '
        'y="${_n(yMid + 3)}" text-anchor="end">${_esc(b.name)}</text>');

    final s = b.meanMicrosPerOp.where((x) => x > 0).toList();
    if (s.isEmpty) continue;
    s.sort();
    final p01 = _percentile(s, 0.01);
    final p25 = _percentile(s, 0.25);
    final p50 = _percentile(s, 0.5);
    final p75 = _percentile(s, 0.75);
    final p99 = _percentile(s, 0.99);
    final mn = s.first, mx = s.last;

    // Whisker p1..p99.
    sb.writeln('<line class="whisker" x1="${_n(xPos(p01))}" '
        'y1="${_n(yMid)}" x2="${_n(xPos(p99))}" y2="${_n(yMid)}"/>');
    // Min/max marks (faint).
    sb.writeln('<circle cx="${_n(xPos(mn))}" cy="${_n(yMid)}" r="1.2" '
        'fill="#bbb"><title>min ${_us(mn)}</title></circle>');
    sb.writeln('<circle cx="${_n(xPos(mx))}" cy="${_n(yMid)}" r="1.2" '
        'fill="#bbb"><title>max ${_us(mx)}</title></circle>');
    // IQR box.
    final boxX = xPos(p25);
    final boxW = math.max(xPos(p75) - boxX, 1.0);
    sb.writeln('<rect class="iqr" x="${_n(boxX)}" '
        'y="${_n(yMid - 3)}" width="${_n(boxW)}" height="6">'
        '<title>p25 ${_us(p25)}, p75 ${_us(p75)}</title></rect>');
    // Median dot.
    sb.writeln('<circle class="med" cx="${_n(xPos(p50))}" cy="${_n(yMid)}" '
        'r="2.5"><title>median ${_us(p50)}</title></circle>');
  }

  sb.writeln('<text class="glbl" x="${_n(padL + plotW / 2)}" '
      'y="${_n(padT - 24)}" text-anchor="middle">'
      'time per op (microseconds, log scale)</text>');

  sb.writeln('</svg>');
  return sb.toString();
}

({double loLog, double hiLog}) _rangeAcrossBenches(List<BenchData> benches) {
  var lo = double.infinity, hi = -double.infinity;
  for (final b in benches) {
    for (final v in b.meanMicrosPerOp) {
      if (v <= 0) continue;
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
  }
  if (!lo.isFinite || !hi.isFinite) return (loLog: 0.0, hiLog: 1.0);
  var loLog = math.log(lo) / math.ln10;
  var hiLog = math.log(hi) / math.ln10;
  if ((hiLog - loLog).abs() < 0.2) {
    final mid = (loLog + hiLog) / 2;
    return (loLog: mid - 0.5, hiLog: mid + 0.5);
  }
  return (loLog: loLog.floorToDouble(), hiLog: hiLog.ceilToDouble());
}

double _percentile(List<double> sorted, double q) {
  if (sorted.isEmpty) return 0;
  final i = (sorted.length * q).floor().clamp(0, sorted.length - 1);
  return sorted[i];
}

({double loLog, double hiLog}) _logRange(List<double> xs) {
  final positive = xs.where((x) => x > 0).toList();
  if (positive.isEmpty) return (loLog: 0.0, hiLog: 1.0);
  positive.sort();
  // Trim 0.5%/99.5% so a stray giant outlier doesn't squash the chart.
  final lo = positive[(positive.length * 0.005).floor()];
  final hi = positive[(positive.length * 0.995).ceil() - 1];
  var loLog = math.log(lo) / math.ln10;
  var hiLog = math.log(hi) / math.ln10;
  if ((hiLog - loLog).abs() < 0.2) {
    // Pad if everything is in one decade so the chart isn't a single bar.
    final mid = (loLog + hiLog) / 2;
    loLog = mid - 0.5;
    hiLog = mid + 0.5;
  } else {
    // Snap to whole decades for nicer ticks.
    loLog = loLog.floorToDouble();
    hiLog = hiLog.ceilToDouble();
  }
  return (loLog: loLog, hiLog: hiLog);
}

String _renderHistogram(List<double> xs,
    {({double loLog, double hiLog})? fixedRange}) {
  final range = fixedRange ?? _logRange(xs);
  final counts = List<int>.filled(_bins, 0);
  for (final x in xs) {
    if (x <= 0) continue;
    final lx = math.log(x) / math.ln10;
    final t = (lx - range.loLog) / (range.hiLog - range.loLog);
    if (t < 0 || t >= 1) continue;
    counts[(t * _bins).floor().clamp(0, _bins - 1)]++;
  }
  final maxCount = counts.fold<int>(0, math.max);
  final plotW = _w - _padL - _padR;
  final plotH = _h - _padT - _padB;
  final binW = plotW / _bins;

  // Log10-scaled y axis. We map count c >= 1 to log10(c) in [0, log10(max)].
  // Bins with c == 0 are simply not drawn.
  final yMaxLog = maxCount > 0 ? math.log(maxCount) / math.ln10 : 0.0;
  double yPos(int c) {
    if (c <= 0 || yMaxLog <= 0) return _padT + plotH;
    final t = (math.log(c) / math.ln10) / yMaxLog;
    return _padT + plotH - plotH * t;
  }

  final sb = StringBuffer();
  sb.writeln(
      '<svg viewBox="0 0 $_w $_h" xmlns="http://www.w3.org/2000/svg">');

  // Bars (log y).
  for (var i = 0; i < _bins; i++) {
    final c = counts[i];
    if (c == 0) continue;
    final yTop = yPos(c);
    final barH = (_padT + plotH) - yTop;
    final x = _padL + binW * i;
    sb.writeln('<rect class="bar" x="${_n(x)}" y="${_n(yTop)}" '
        'width="${_n(math.max(binW - 1, 0.5))}" height="${_n(barH)}">'
        '<title>n=$c</title></rect>');
  }

  // Axes.
  final axisY = _padT + plotH;
  sb.writeln('<path class="axis" d="M$_padL ${_n(axisY)} '
      'L${_n(_padL + plotW)} ${_n(axisY)}"/>');
  sb.writeln('<path class="axis" d="M$_padL $_padT '
      'L$_padL ${_n(axisY)}"/>');

  // X-axis: ticks at 1, 2, 5 inside every decade for finer labels.
  for (final t in _logTicks(range.loLog, range.hiLog)) {
    final pos = _padL + plotW * (t.logV - range.loLog) / (range.hiLog - range.loLog);
    final tickH = t.major ? 6.0 : 3.0;
    sb.writeln('<line class="tick" x1="${_n(pos)}" y1="${_n(axisY)}" '
        'x2="${_n(pos)}" y2="${_n(axisY + tickH)}"/>');
    if (t.label != null) {
      sb.writeln('<text class="tlbl" x="${_n(pos)}" y="${_n(axisY + 16)}" '
          'text-anchor="middle">${t.label}</text>');
    }
  }
  sb.writeln('<text class="glbl" x="${_n(_padL + plotW / 2)}" '
      'y="${_n(_h - 6)}" text-anchor="middle">'
      'time per op (microseconds, log scale)</text>');

  // Y-axis ticks (log scale): a tick at every decade 1, 10, 100, ...
  final yMaxDecade = yMaxLog.ceil();
  for (var d = 0; d <= yMaxDecade; d++) {
    final c = math.pow(10, d).toInt();
    final y = yPos(c);
    sb.writeln('<line class="tick" x1="${_n(_padL - 4)}" y1="${_n(y)}" '
        'x2="$_padL" y2="${_n(y)}"/>');
    sb.writeln('<text class="tlbl" x="${_n(_padL - 8)}" y="${_n(y + 3)}" '
        'text-anchor="end">$c</text>');
  }
  sb.writeln('<text class="glbl" '
      'transform="translate(14,${_n(_padT + plotH / 2)}) rotate(-90)" '
      'text-anchor="middle">samples per bin (log)</text>');

  sb.writeln('</svg>');
  return sb.toString();
}

class _Tick {
  final double logV;   // log10(value-in-microseconds)
  final bool major;    // 1 * 10^d
  final String? label; // null = no text label
  const _Tick(this.logV, this.major, this.label);
}

// Generates 1/2/5-per-decade ticks (in log10 microseconds) within [lo, hi].
// Major ticks (1) get a long mark and a text label. Sub-ticks (2, 5) get a
// shorter mark and a label only when they fit (we always label them here
// because the axis is wide enough; downstream callers can choose to skip).
Iterable<_Tick> _logTicks(double lo, double hi) sync* {
  final loDecade = lo.floor();
  final hiDecade = hi.ceil();
  // log10 of 1, 2, 5.
  const subs = <(double, int)>[(0.0, 1), (0.30103, 2), (0.69897, 5)];
  for (var d = loDecade; d <= hiDecade; d++) {
    for (final s in subs) {
      final logV = d + s.$1;
      if (logV < lo - 1e-9 || logV > hi + 1e-9) continue;
      final isMajor = s.$2 == 1;
      yield _Tick(logV, isMajor, _logLabel(d, s.$2));
    }
  }
}

String _logLabel(int d, int leading) {
  // d = log10(microseconds) of the decade base.
  // Pick a unit so the printed mantissa stays in [1, 999].
  String unit;
  int shift;
  if (d <= -4) { unit = 'ps'; shift = -6; }
  else if (d <= -1) { unit = 'ns'; shift = -3; }
  else if (d <= 2) { unit = 'us'; shift = 0; }
  else if (d <= 5) { unit = 'ms'; shift = 3; }
  else { unit = 's'; shift = 6; }
  final exp = d - shift;
  // value = leading * 10^exp, in `unit`.
  final v = leading * math.pow(10, exp);
  if (v >= 1 && v < 1000) return '${v.toStringAsFixed(0)}$unit';
  // Fallback if outside the comfortable range.
  return '${(leading * math.pow(10, d)).toStringAsExponential(0)}us';
}

String _statsLine(List<double> xs) {
  if (xs.isEmpty) return 'no samples';
  final s = [...xs]..sort();
  final n = s.length;
  final mean = xs.reduce((a, b) => a + b) / n;
  final p50 = s[n ~/ 2];
  final p1 = s[(n * 0.01).floor().clamp(0, n - 1)];
  final p99 = s[(n * 0.99).floor().clamp(0, n - 1)];
  final mn = s.first, mx = s.last;
  return 'n=$n  min=${_us(mn)}  p1=${_us(p1)}  median=${_us(p50)}  '
      'mean=${_us(mean)}  p99=${_us(p99)}  max=${_us(mx)}';
}

String _us(double v) => '${v.toStringAsFixed(3)}us';

String _n(double v) {
  // Trim float noise in the SVG output.
  final fixed = v.toStringAsFixed(2);
  return fixed.endsWith('.00') ? fixed.substring(0, fixed.length - 3) : fixed;
}
