Hey Siddharth,

This looks good. Few changes:

1. For readings (both for calibration and unknown concentration), can we start taking the readings after a delay of say 10 secs and take an average of 5 values?

2. Also, please create a drop-down for units, as the standards can be in ppm or ppb

3. Calibration plots of CL and FL have to be plotted separately

4. Also, if r2 is less (keep it from 0.99 to 0.95), ask the users to recalibrate or increase calibration to 5 points

I showed this application as a demo to the prof via recorded video.
So, go through the #codebase throughly and explain to me how to make these changes extensively. Explain all technical details, architecture, UI changes and everything.


Semantic workspace search is not currently available



Let me re-read the key files involved to give precise, line-level explanations.   

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#1-1), lines 1 to 200

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/measurement_screen.dart#1-1), lines 1 to 200

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/firmware/server.py#1-1), lines 1 to 100

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#200-200), lines 200 to 500

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/measurement_screen.dart#200-200), lines 200 to 460

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/math_utils.dart)

Now let me also read the remaining tail of calibration_screen (the `_concField` helper and chart card area):   

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#480-480), lines 480 to 600

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/app_state.dart)

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/firmware/sensor.py)

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#598-598), lines 598 to 640

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/firmware/config.py)

I now have a complete picture of the codebase. Here's the detailed breakdown of all four professor changes:

---

# Professor's Feedback — Full Implementation Plan

## Change 1: 10-Second Delay Before Readings + 5-Reading Average

### What the professor wants
When the user taps "Collect Level" (calibration) or "Measure Now" (measurement), the system should **wait 10 seconds** first (for the optical signal to stabilize in the cuvette), then take 5 readings and average them.

### What exists today

**Calibration** — calibration_screen.dart `_collectLevel()`:
- Sends `cal_start`, then immediately fires 5 `cal_sample` commands 400 ms apart
- No stabilization delay at all

**Measurement** — measurement_screen.dart `_measure()`:
- Immediately fires 5 `encodeMeasure()` commands 400 ms apart
- No stabilization delay

**Firmware** — server.py handles `cal_sample` by calling `read_sensors()` instantly. sensor.py takes 5 ADC samples 50 ms apart and returns the **median** (not average).

### Where to make the changes

**Option A (app-side delay — recommended):** The delay belongs in the app, not the firmware, because:
- The UI needs to show a countdown ("Stabilizing… 7 s remaining")
- The firmware doesn't know *when* the sample was placed — only the app knows the user just tapped "Collect"

**Calibration** — in `_collectLevel()` at calibration_screen.dart, insert a 10-second countdown **after** `conn.send(Protocol.encodeCalStart(levelLabel))` but **before** the sample-request loop:

```dart
// Notify firmware that calibration for this level is starting.
await conn.send(Protocol.encodeCalStart(levelLabel));

// ── NEW: 10-second stabilization delay with countdown ──
for (int s = 10; s > 0; s--) {
  if (!mounted) return;
  setState(() => _stabilizing = true; _stabilizeSeconds = s);
  await Future.delayed(const Duration(seconds: 1));
}
setState(() => _stabilizing = false);

// Request _samplesPerLevel readings, 400 ms apart.
for (int i = 0; i < _samplesPerLevel; i++) { ... }
```

New state variables needed:
```dart
bool _stabilizing = false;
int  _stabilizeSeconds = 0;
```

The UI needs to show this countdown. In the level table's `trailing:` area (around line 440), when the level is active and collecting:
- If `_stabilizing`: show "Stabilizing… X s" text instead of the progress indicator
- If collecting but not stabilizing: show the current sample progress (as it does now)

The Collect button label should update too:
```
_stabilizing ? 'Stabilizing… ($_stabilizeSeconds s)' : 'Collecting… ($_sampleCount/$_samplesPerLevel)'
```

**Measurement** — exact same pattern in `_measure()` at measurement_screen.dart. Insert a 10-second countdown after setting `_measuring = true` but before the sample loop:

```dart
setState(() {
  _measuring = true;
  _count = 0;
  ...
});

// ── NEW: 10-second stabilization delay ──
for (int s = 10; s > 0; s--) {
  if (!mounted) return;
  setState(() => _stabilizeSeconds = s);
  await Future.delayed(const Duration(seconds: 1));
}
setState(() => _stabilizeSeconds = 0);

// Request _samples readings from firmware...
```

In the progress card UI, show the countdown: when `_stabilizeSeconds > 0`, display "Stabilizing… X s" instead of "Measuring… (0/5)".

**Firmware stays unchanged** — `read_sensors()` in sensor.py already returns a median-filtered value per call. The 5 readings averaged by the app are 5 separate `read_sensors()` calls (each already internally median-filtered over 5 raw ADC samples). This two-level filtering is fine: inner median rejects electrical noise spikes, outer average across the 5 calls reduces systematic drift.

**Constants:** Add `static const int _stabilizeSeconds = 10;` in both screens (or put it in config.py and mirror it in the app). Keeping it in the Dart screens is simpler since the firmware doesn't use it.

---

## Change 2: Units Dropdown (ppm / ppb)

### What the professor wants
Standards can be prepared in **ppm (mg/kg)** or **ppb (μg/kg)**. The user should choose which unit they're entering concentrations in. Internally, $1\ \text{ppm} = 1000\ \text{ppb}$.

### What exists today

The MRL data in mrl_data.json is all in **mg/kg (= ppm)**. The calibration screen in calibration_screen.dart has three `TextEditingController`s for Low/Mid/High concentrations, and the label says "mg/L" everywhere. measurement_screen.dart displays concentrations in "mg/L". The `_ConcChip` widget at the bottom of the file hardcodes "mg/L".

### Where to make the changes

**New state variable** in `CalibrationScreen`:
```dart
String _unit = 'ppm'; // 'ppm' or 'ppb'
double get _unitMultiplier => _unit == 'ppb' ? 0.001 : 1.0;
// When user enters in ppb, multiply by 0.001 to convert to ppm (internal unit)
```

**Calibration screen UI** — Add a `DropdownButton<String>` next to the pesticide selector or inside the concentration-entry card. Place it in the card header at calibration_screen.dart:

```dart
Row(
  children: [
    const Text('Set calibration concentrations'),
    const Spacer(),
    DropdownButton<String>(
      value: _unit,
      items: const [
        DropdownMenuItem(value: 'ppm', child: Text('ppm (mg/kg)')),
        DropdownMenuItem(value: 'ppb', child: Text('ppb (μg/kg)')),
      ],
      onChanged: canEdit ? (v) => setState(() => _unit = v!) : null,
    ),
  ],
),
```

**Concentration getter** — `_concentrations` must convert user input to internal ppm:

```dart
List<double> get _concentrations => [
      0.00,
      (double.tryParse(_lowCtrl.text.trim())  ?? 0.10) * _unitMultiplier,
      (double.tryParse(_midCtrl.text.trim())  ?? 0.50) * _unitMultiplier,
      (double.tryParse(_highCtrl.text.trim()) ?? 1.00) * _unitMultiplier,
    ];
```

This means all calibration math (`linearFit`, R², slope/intercept) operates in **ppm internally**. The slope/intercept stored in `AppState` are always ppm-based.

**Display labels throughout** — wherever you currently show "mg/L", show the selected unit string instead. The level table at line ~440 shows `$conc mg/L` — change to `$conc $_unit`. The coefficients card at line ~548 says "mg/L" — update.

**Measurement screen** — needs the same dropdown, but here it controls the **display unit** for the result. When MRL comparison is always in ppm internally, but the displayed concentration to the user should match their selected unit:

```dart
// In MeasurementScreen, add:
String _displayUnit = 'ppm';
double get _displayFactor => _displayUnit == 'ppb' ? 1000.0 : 1.0;

// When displaying:
'${(_concCL * _displayFactor).toStringAsFixed(3)} $_displayUnit'
```

The MRL comparison stays in ppm: `_avgConc <= mrl` (both ppm). But the display shows the value multiplied by `_displayFactor`.

**Persistence** — Store the selected unit in `AppState` → `SharedPreferences` so it survives restarts:
- Add `String? selectedUnit;` to app_state.dart
- Save/load alongside `selected_pesticide`

**Database** — The `measurements` table in database_helper.dart stores values in ppm (the internal canonical unit). No schema change needed. The unit is purely a display concern.

**Firmware** — No changes. The firmware returns normalized ADC values [0,1]. Unit conversion is entirely an app concept.

---

## Change 3: Separate CL and FL Calibration Plots

### What the professor wants
Currently, CL and FL curves are overlaid on a **single** chart. The professor wants **two separate charts** — one for CL, one for FL.

### What exists today

The chart is built by `_buildChart()` at calibration_screen.dart, which creates a single `LineChart` widget with **4** bar data series (CL dots, CL regression line, FL dots, FL regression line) all on one set of axes. This is rendered inside a single `Card` at line ~575.

### Where to make the changes

**Split `_buildChart()` into `_buildClChart()` and `_buildFlChart()`:**

```dart
Widget _buildSingleChart({
  required List<double> means,
  required double slope,
  required double intercept,
  required double r2,
  required Color color,
  required String label,
}) {
  return SizedBox(
    height: 180,
    child: LineChart(
      LineChartData(
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: true),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            axisNameWidget: const Text('ADC reading (norm.)',
                style: TextStyle(fontSize: 10)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(2),
                style: const TextStyle(fontSize: 9),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: Text('Conc. ($_unit)',
                style: const TextStyle(fontSize: 10)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(2),
                style: const TextStyle(fontSize: 9),
              ),
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineBarsData: [
          _chartLine(means, slope, intercept, color),
          _chartDots(means, color),
        ],
      ),
    ),
  );
}
```

**In the UI**, replace the single chart `Card` (~line 575) with **two** cards:

```dart
// CL calibration curve
Card(
  child: Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('CL Calibration  (R² = ${_clR2.toStringAsFixed(4)})',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        _buildSingleChart(
          means: _clMeans, slope: _clSlope, intercept: _clIntercept,
          r2: _clR2, color: Colors.blue.shade600, label: 'CL',
        ),
      ],
    ),
  ),
),
const SizedBox(height: 8),
// FL calibration curve
Card(
  child: Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('FL Calibration  (R² = ${_flR2.toStringAsFixed(4)})',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        _buildSingleChart(
          means: _flMeans, slope: _flSlope, intercept: _flIntercept,
          r2: _flR2, color: Colors.orange.shade600, label: 'FL',
        ),
      ],
    ),
  ),
),
```

**Scrollability concern** — Two 180px charts + coefficients card + buttons won't fit in the current `Column` layout after calibration. The calibrated-state section (from line ~530 onwards) should be wrapped in a `SingleChildScrollView` or the entire body should use a `ListView` instead of `Column`. Currently the level list is in an `Expanded(child: ListView(...))`, so the simplest fix is to make the *calibrated* section also scrollable — replace the `Expanded(child: ListView.separated(...))` + bottom buttons area with a single `Expanded(child: ListView(...))` that dynamically contains either the level table (during collection) or the result cards + charts (after calibration).

**Remove the old combined `_buildChart()`** and the legend dots helper.

---

## Change 4: R² Threshold 0.95 + Option to Add a 5th Calibration Point

### What the professor wants
Lower the R² acceptance threshold from 0.99 to **0.95**. If R² falls between 0.95 and some lower bound, **offer the user a choice**: recalibrate entirely, or **add a 5th calibration point** to improve the fit.

### What exists today

In `_computeCalibration()` at calibration_screen.dart:
```dart
if (_clR2 < 0.99 || _flR2 < 0.99) {
  _warning = 'R² below 0.99 — linearity is poor. Clean the cuvette and recalibrate.';
}
_calibrated = true;  // always sets calibrated to true regardless of R²
```

The level count is hardcoded at 4 (Blank + 3 user-entered). `_levelNames` is `['Blank', 'Low', 'Mid', 'High']`. The `_concentrations` getter produces exactly 4 values. The concentration-entry UI shows exactly 3+1 fields.

### Where to make the changes

This is the most structurally significant change. The calibration must become **dynamic** in the number of levels.

**A. Make the level system dynamic:**

Replace the fixed lists with a dynamic approach:

```dart
// Replace the fixed _levelNames and _concentrations getter:
final List<TextEditingController> _concControllers = [
  TextEditingController(text: '0.10'),
  TextEditingController(text: '0.50'),
  TextEditingController(text: '1.00'),
];

List<String> get _levelNames => [
  'Blank',
  for (int i = 0; i < _concControllers.length; i++) 'Std ${i + 1}',
];

List<double> get _concentrations => [
  0.00, // Blank is always first
  ..._concControllers.map(
    (c) => (double.tryParse(c.text.trim()) ?? 0.0) * _unitMultiplier,
  ),
];
```

**B. "Add Point" button:**

When R² is below 0.95 (or even between 0.95–0.99), show an action dialog with two choices:

```dart
void _computeCalibration() {
  // ... existing linearFit code ...

  final minR2 = _clR2 < _flR2 ? _clR2 : _flR2;

  if (minR2 < 0.95) {
    // Below absolute minimum — must recalibrate or add point
    _calibrated = false;
    _warning = 'R² = ${minR2.toStringAsFixed(4)} — below 0.95. '
        'Add another calibration point or recalibrate.';
    _showAddPointOption = true;
  } else if (minR2 < 0.99) {
    // Acceptable but not great — proceed but warn
    _calibrated = true;
    _warning = 'R² = ${minR2.toStringAsFixed(4)} — between 0.95 and 0.99. '
        'Consider adding a point to improve linearity.';
    _showAddPointOption = true;
    // Still save calibration since ≥ 0.95
    _saveCalibration();
  } else {
    // ≥ 0.99 — excellent
    _calibrated = true;
    _showAddPointOption = false;
    _saveCalibration();
  }

  setState(() {});
}
```

Add state:
```dart
bool _showAddPointOption = false;
```

**C. Adding a 5th (or 6th, ...) point:**

```dart
void _addCalibrationPoint() {
  setState(() {
    _concControllers.add(TextEditingController(text: ''));
    _calibrated = false;
    _showAddPointOption = false;
    _warning = null;
    // _currentLevel is already at the end — the new level becomes the next to collect
    // Don't clear existing _clMeans/_flMeans — keep the data already collected
  });
}
```

The level table `ListView` and concentration-entry UI automatically adapt because they read from `_concentrations` (which now includes the new entry). The `_currentLevel` stays where it was (pointing at the new level to collect). After collecting the new level, the user taps "Compute Calibration" again and R² should improve.

**D. UI for the "add point" option:**

After the warning card (~line 530), add:

```dart
if (_showAddPointOption) ...[
  const SizedBox(height: 8),
  Row(
    children: [
      Expanded(
        child: OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add Point'),
          onPressed: _addCalibrationPoint,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: OutlinedButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Recalibrate'),
          onPressed: _reset,
        ),
      ),
    ],
  ),
],
```

**E. Concentration entry UI — dynamic fields:**

Replace the fixed `Row(children: [_concField('Blank', null), _concField('Low', ...), ...])` with:

```dart
Wrap(
  spacing: 8,
  runSpacing: 8,
  children: [
    _concField('Blank', null), // fixed 0.00
    for (int i = 0; i < _concControllers.length; i++)
      _concField('Std ${i + 1}', _concControllers[i]),
  ],
)
```

Make `_concField` return a fixed-width `SizedBox(width: 70, ...)` instead of `Expanded` so the `Wrap` can flow to the next line when there are 5+ fields.

**F. Dispose controllers:**

```dart
@override
void dispose() {
  _sub?.cancel();
  for (final c in _concControllers) { c.dispose(); }
  super.dispose();
}
```

**G. CLAUDE.md update:**

Change this line:
> R² ≥ 0.99 required — warning shown if below.

To:
> R² ≥ 0.95 is the minimum acceptance threshold. R² between 0.95–0.99 will warn the user and offer to add another calibration point. R² < 0.95 blocks proceeding until the user adds a point or recalibrates.

---

## Files Affected — Summary

| File | Changes |
|------|---------|
| calibration_screen.dart | **Major**: 10s delay + countdown UI, unit dropdown, dynamic level count, split charts, R² threshold logic, add-point button |
| measurement_screen.dart | **Moderate**: 10s delay + countdown UI, unit display dropdown, display factor for ppb |
| app_state.dart | **Minor**: add `selectedUnit` field, persist/load it |
| math_utils.dart | **None** — pure math, unit-agnostic |
| database_helper.dart | **None** — stores ppm internally |
| history_screen.dart | **Minor**: show unit in display (optional — could always show ppm) |
| server.py | **None** |
| sensor.py | **None** |
| config.py | **None** |
| protocol.py | **None** |
| CLAUDE.md | **Minor**: update R² threshold, document units, document stabilization delay |
| test/math_utils_test.dart | **None** — math is unchanged |

All four changes are **app-side only** — the firmware doesn't need any modifications.





Let me re-read the exact code paths involved to give precise line references.   

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#92-92), lines 92 to 160

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/measurement_screen.dart#68-68), lines 68 to 200

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/firmware/sensor.py)

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#26-26), lines 26 to 55

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#160-160), lines 160 to 200

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#216-216), lines 216 to 320

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#370-370), lines 370 to 470

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/calibration_screen.dart#530-530), lines 530 to 650

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/measurement_screen.dart#260-260), lines 260 to 460

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/measurement_screen.dart#1-1), lines 1 to 30

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/history_screen.dart#55-55), lines 55 to 100

Read [](file:///c%3A/Users/z00541ce/Documents/Coding/Thesis/pestisafe/lib/database_helper.dart#20-20), lines 20 to 90

Now I have every detail needed. Here is the full deep dive.

---

# Change 1: 10-Second Stabilization Delay Before Readings

## Why the professor wants this

In optical spectroscopy, when you place a cuvette containing a standard or unknown sample into the detector, the signal isn't immediately stable. There's thermal equilibration, meniscus settling, and air-bubble dissipation. A 10-second wait lets the optical path stabilize before the ADC starts sampling. Without it, early readings may be systematically biased.

## The two-level filtering architecture you need to understand

Today, readings go through **two** layers of noise reduction. Understanding both is essential:

**Layer 1 — firmware (`read_sensors()`):** Each call to `read_sensors()` in sensor.py collects 5 raw ADC values 50 ms apart and returns the **median**. This rejects electrical spike noise (e.g., one ADC value is 60000 while the rest are ~30000 — the median ignores that outlier). This happens per-call; the app doesn't control it.

**Layer 2 — app-side averaging:** The app sends 5 separate `cal_sample` or `measure` commands, each getting back one median-filtered value, and then **averages** those 5 values. This reduces systematic drift (e.g., the signal gradually increasing as the lamp warms up — averaging 5 readings spaced over 2 seconds smooths that out).

The 10-second delay goes **before** Layer 2 starts — i.e., after the user taps "Collect" or "Measure" but before the first sample request is sent. Layer 1 and Layer 2 mechanics don't change at all.

## What to change in calibration_screen.dart

### New state variables (add at calibration_screen.dart)

Currently, the state section has:
```dart
int  _currentLevel = 0;
int  _sampleCount  = 0;
bool _collecting   = false;
bool _calibrated   = false;
String? _warning;
```

Add two more:
```dart
bool _stabilizing      = false;   // true during the 10-second countdown
int  _stabilizeRemain  = 0;       // seconds remaining in countdown
```

### The delay injection in `_collectLevel()` (modify calibration_screen.dart)

The current flow is:

```
1. conn.send(Protocol.encodeCalStart(levelLabel))    ← tells firmware "calibrating"
2. for (i = 0; i < 5; i++)                           ← immediately sends 5 sample requests
     conn.send(Protocol.encodeCalSample(levelLabel, i))
     await Future.delayed(400ms)
3. Wait for responses
```

The new flow becomes:

```
1. conn.send(Protocol.encodeCalStart(levelLabel))    ← tells firmware "calibrating"
2. ── NEW: 10-second countdown ──
   for (s = 10; s > 0; s--)
     setState(() { _stabilizing = true; _stabilizeRemain = s; })
     await Future.delayed(1 second)
   setState(() { _stabilizing = false; })
3. for (i = 0; i < 5; i++)                           ← now sends sample requests
     conn.send(Protocol.encodeCalSample(levelLabel, i))
     await Future.delayed(400ms)
4. Wait for responses
```

Specifically, right after this line at calibration_screen.dart:
```dart
await conn.send(Protocol.encodeCalStart(levelLabel));
```

Insert:
```dart
// 10-second stabilization delay — let sample settle in cuvette
for (int s = 10; s > 0; s--) {
  if (!mounted) return;
  setState(() {
    _stabilizing = true;
    _stabilizeRemain = s;
  });
  await Future.delayed(const Duration(seconds: 1));
}
setState(() => _stabilizing = false);
```

The `if (!mounted) return;` guard prevents calling `setState` on a disposed widget if the user navigates away during the countdown.

### UI changes for the countdown

**In the level table's `trailing:` widget** ([lines 455–467](pestisafe/lib/calibration_screen.dart#L455)), currently:
```dart
trailing: done
    ? Icon(Icons.check_circle, color: Colors.green.shade700)
    : (active && _collecting)
        ? SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: _samplesPerLevel > 0
                  ? _sampleCount / _samplesPerLevel
                  : null,
            ),
          )
        : null,
```

This needs a third branch. When `_stabilizing` is true but we're on the active level, show the countdown:
```dart
trailing: done
    ? Icon(Icons.check_circle, color: Colors.green.shade700)
    : (active && _collecting && _stabilizing)
        ? Text('${_stabilizeRemain}s',
            style: TextStyle(
              color: cs.primary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ))
        : (active && _collecting)
            ? SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: _sampleCount / _samplesPerLevel,
                ),
              )
            : null,
```

**In the subtitle of the active level tile** ([line 449](pestisafe/lib/calibration_screen.dart#L449)):
```dart
subtitle: done
    ? Text('CL: ${_clMeans[i].toStringAsFixed(4)} ...')
    : Text(
        active
            ? (_stabilizing
                ? 'Stabilizing… ${_stabilizeRemain}s remaining'
                : 'Ready — place standard')
            : 'Waiting…',
        style: const TextStyle(color: Colors.black45),
      ),
```

**In the Collect button label** ([lines 498–503](pestisafe/lib/calibration_screen.dart#L498)):
```dart
label: Text(
  _collecting
      ? (_stabilizing
          ? 'Stabilizing… (${_stabilizeRemain}s)'
          : 'Collecting… ($_sampleCount/$_samplesPerLevel)')
      : 'Collect Level ${_currentLevel + 1} (${_levelNames[_currentLevel]})',
),
```

### Reset method

In `_reset()` at calibration_screen.dart, add:
```dart
_stabilizing = false;
_stabilizeRemain = 0;
```

## What to change in measurement_screen.dart

### New state variables (add at measurement_screen.dart)

Currently:
```dart
bool _measuring  = false;
int  _count      = 0;
```

Add:
```dart
int _stabilizeRemain = 0;
```

We reuse `_measuring` as the overall "busy" flag. When `_stabilizeRemain > 0`, the UI shows the countdown. When it reaches 0 and `_count` starts incrementing, it shows "Measuring (N/5)".

### The delay injection in `_measure()` (modify measurement_screen.dart)

Currently, right after `setState(() { _measuring = true; ... })`, the code immediately sets up the listener and starts sending `encodeMeasure()`. Insert the delay after the setState block but before the listener:

```dart
setState(() {
  _measuring   = true;
  _count       = 0;
  ...
});

// 10-second stabilization delay
for (int s = 10; s > 0; s--) {
  if (!mounted) return;
  setState(() => _stabilizeRemain = s);
  await Future.delayed(const Duration(seconds: 1));
}
setState(() => _stabilizeRemain = 0);

// Now set up listener and start sampling...
double clSum = 0, flSum = 0;
int received = 0;
final completer = Completer<void>();
_sub = conn.messages.listen((raw) { ... });
```

### UI changes in measurement screen

**Progress card text** at measurement_screen.dart:
```dart
Text(
  _measuring
      ? (_stabilizeRemain > 0
          ? 'Stabilizing… (${_stabilizeRemain}s)'
          : 'Measuring… ($_count/$_samples)')
      : _tier == _SafetyTier.unknown
          ? 'Ready'
          : 'Done',
  ...
),
```

**Progress bar** at measurement_screen.dart:
```dart
LinearProgressIndicator(
  value: _measuring
      ? (_stabilizeRemain > 0
          ? null  // indeterminate during stabilization
          : (_samples > 0 ? _count / _samples : null))
      : _tier != _SafetyTier.unknown ? 1.0 : 0.0,
  ...
),
```

During stabilization, `value: null` makes the progress bar animate in indeterminate mode (a moving stripe) which clearly distinguishes it from the determinate sample-counting phase.

**Measure button label** at measurement_screen.dart:
```dart
label: Text(_measuring
    ? (_stabilizeRemain > 0 ? 'Stabilizing…' : 'Measuring…')
    : 'Measure Now'),
```

## Firmware impact

**None.** The firmware doesn't change. The delay lives entirely in the Dart code. The firmware still responds to `cal_sample` and `measure` exactly as before — it just gets those commands 10 seconds later than it used to.

## Testing impact

Unit tests in math_utils_test.dart are unaffected — they test pure math. Widget tests in widget_test.dart only test `HomeScreen` rendering, which doesn't involve the delay logic. If you add widget tests for the calibration or measurement screens later, you'd use `tester.pump(Duration(seconds: 10))` to fast-forward past the delay.

---

# Change 2: Units Dropdown (ppm / ppb)

## The science

Concentrations in pesticide analysis are expressed in either:
- **ppm** (parts per million) = mg/kg = mg/L (in dilute aqueous solution, density ≈ 1)
- **ppb** (parts per billion) = μg/kg = μg/L

The conversion is $1\ \text{ppm} = 1000\ \text{ppb}$.

The MRL data in mrl_data.json is stored as `mrl_mg_kg` — i.e., ppm. The calibration math (`linearFit`) and the measurement comparison (`avgConc <= mrl`) all operate in consistent units. The question is: should the **internal** unit change, or just the **display** unit?

**Answer: internal stays ppm, display adapts.** This is the cleanest approach because:
1. MRL data doesn't need two versions
2. The database stores one canonical unit
3. Only two places convert: input (calibration entry fields) and output (display everywhere)

## Every location in the code that shows or reads a unit

| File | Line(s) | What it says | What changes |
|------|---------|-------------|-------------|
| calibration_screen.dart | ~380 | `'Set calibration concentrations (mg/L)'` | Show selected unit |
| calibration_screen.dart | ~445 | `'$label  •  $conc mg/L'` in level table | Show selected unit |
| calibration_screen.dart | ~548–555 | CL/FL coefficient display `'m=... b=... R²=...'` | No unit shown here (dimensionless), no change needed |
| calibration_screen.dart | ~289 | Chart Y-axis: `'Conc. (mg/L)'` | Show selected unit |
| calibration_screen.dart | ~642 | `_concField` suffix: `Text('mg/L')` | Show selected unit |
| measurement_screen.dart | ~276 | `'MRL: ${mrl.toStringAsFixed(2)} mg/L'` | Show selected unit, convert value if ppb |
| measurement_screen.dart | ~444 | `_ConcChip` shows `'${value.toStringAsFixed(4)} mg/L'` | Show selected unit, convert value if ppb |
| history_screen.dart | ~65 | CSV header: `'CL (mg/L)', 'FL (mg/L)', 'Avg (mg/L)', 'MRL (mg/L)'` | Show selected unit in CSV |
| history_screen.dart | ~399 | `'Avg ... mg/L / MRL ... mg/L'` | Show selected unit |

## State management — where the unit lives

The unit selection should persist across restarts (user preference), so it goes into `AppState`:

**In app_state.dart**, add:
```dart
// ── Unit Selection ─────────────────────────────────────────────────────
String selectedUnit = 'ppm'; // 'ppm' or 'ppb'

void setSelectedUnit(String unit) {
  selectedUnit = unit;
  notifyListeners();
  _saveToPrefs();
}
```

In `_saveToPrefs()` at app_state.dart, add:
```dart
await prefs.setString('selected_unit', selectedUnit);
```

In `loadSavedCalibration()` at app_state.dart, add:
```dart
selectedUnit = prefs.getString('selected_unit') ?? 'ppm';
```

In `_clearPrefs()` at app_state.dart, add `'selected_unit'` to the removal list.

## Calibration screen changes

### New computed properties

At the top of `_CalibrationScreenState`:
```dart
String get _unit {
  return Provider.of<AppState>(context, listen: false).selectedUnit;
}

String get _unitLabel => _unit == 'ppb' ? 'ppb (μg/kg)' : 'ppm (mg/kg)';

/// Multiplier to convert user-entered value to internal ppm.
/// If user enters "500" in ppb mode, internal value = 500 × 0.001 = 0.5 ppm.
double get _toPpm => _unit == 'ppb' ? 0.001 : 1.0;

/// Multiplier to convert internal ppm to display unit.
/// If internal = 0.5 ppm and unit = ppb, display = 0.5 × 1000 = 500 ppb.
double get _fromPpm => _unit == 'ppb' ? 1000.0 : 1.0;
```

### The `_concentrations` getter changes

Currently at calibration_screen.dart:
```dart
List<double> get _concentrations => [
      0.00,
      double.tryParse(_lowCtrl.text.trim())  ?? 0.10,
      double.tryParse(_midCtrl.text.trim())  ?? 0.50,
      double.tryParse(_highCtrl.text.trim()) ?? 1.00,
    ];
```

Becomes:
```dart
List<double> get _concentrations => [
      0.00,
      (double.tryParse(_lowCtrl.text.trim())  ?? 0.10) * _toPpm,
      (double.tryParse(_midCtrl.text.trim())  ?? 0.50) * _toPpm,
      (double.tryParse(_highCtrl.text.trim()) ?? 1.00) * _toPpm,
    ];
```

The user types `500` in ppb mode. `_toPpm = 0.001`. `_concentrations[1] = 500 * 0.001 = 0.5 ppm`. The `linearFit()` call, which maps ADC→concentration, now produces a slope/intercept in ppm. Everything downstream — `AppState`, `SharedPreferences`, `DatabaseHelper` — stays in ppm.

### Unit dropdown in the UI

Place it in the pesticide selector row or the concentration card. The natural place is next to the "Set calibration concentrations" header at calibration_screen.dart:

```dart
Row(
  children: [
    const Text('Set calibration concentrations',
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
    const Spacer(),
    DropdownButton<String>(
      value: _unit,
      underline: const SizedBox(),
      style: const TextStyle(fontSize: 12, color: Colors.black87),
      items: const [
        DropdownMenuItem(value: 'ppm', child: Text('ppm')),
        DropdownMenuItem(value: 'ppb', child: Text('ppb')),
      ],
      onChanged: canEdit
          ? (v) {
              Provider.of<AppState>(context, listen: false).setSelectedUnit(v!);
              setState(() {});
            }
          : null,
    ),
  ],
),
```

### Display conversions in the UI

In the level table title at calibration_screen.dart:
```dart
// Before:
'$label  •  $conc mg/L'
// After:
'$label  •  ${(concs[i] * _fromPpm).toStringAsFixed(2)} $_unit'
```

Note: `concs[i]` is already in ppm (from `_concentrations`), so multiply by `_fromPpm` to display.

In the `_concField` suffix at calibration_screen.dart:
```dart
// Before:
suffix: const Text('mg/L', style: TextStyle(fontSize: 10)),
// After:
suffix: Text(_unit, style: const TextStyle(fontSize: 10)),
```

In the chart Y-axis label at calibration_screen.dart:
```dart
// Before:
axisNameWidget: const Text('Conc. (mg/L)', style: TextStyle(fontSize: 10)),
// After:
axisNameWidget: Text('Conc. ($_unit)', style: const TextStyle(fontSize: 10)),
```

## Measurement screen changes

### The display unit

`MeasurementScreen` needs to read the unit from `AppState` to display results. It does **not** need its own unit dropdown — it inherits the unit chosen during calibration. But the professor might want a display toggle here too. The simplest approach: read `appState.selectedUnit` and apply `_fromPpm` to every displayed concentration.

Add computed properties:
```dart
String get _unit =>
    Provider.of<AppState>(context, listen: false).selectedUnit;
double get _fromPpm => _unit == 'ppb' ? 1000.0 : 1.0;
```

**MRL display** at measurement_screen.dart:
```dart
// Before:
'MRL: ${mrl.toStringAsFixed(2)} mg/L'
// After:
'MRL: ${(mrl * _fromPpm).toStringAsFixed(2)} $_unit'
```

**Result message** at measurement_screen.dart:
```dart
// Internally _avgConc and mrl are both in ppm, so the % comparison is unchanged.
// Only the display text changes. The SAFE/UNSAFE logic doesn't touch units at all.
```

**`_ConcChip`** at measurement_screen.dart currently shows:
```dart
'${value.toStringAsFixed(4)} mg/L'
```

This widget is a private `StatelessWidget` with no access to `AppState`. Two options:
- **Option A**: add a `unit` parameter to `_ConcChip` and pass `_unit` from the parent
- **Option B**: convert the values before passing them to `_ConcChip`

Option A is cleaner:
```dart
class _ConcChip extends StatelessWidget {
  final String label;
  final double value;
  final String unit;       // ← new
  final bool bold;

  const _ConcChip({required this.label, required this.value,
                    this.unit = 'ppm', this.bold = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, ...),
        Text('${value.toStringAsFixed(4)} $unit', ...),
      ],
    );
  }
}
```

And at the call sites:
```dart
_ConcChip(label: 'CL', value: _concCL * _fromPpm, unit: _unit),
_ConcChip(label: 'FL', value: _concFL * _fromPpm, unit: _unit),
_ConcChip(label: 'Avg', value: _avgConc * _fromPpm, unit: _unit, bold: true),
```

## Database impact

**The database stores ppm.** The `cl_conc`, `fl_conc`, `avg_conc`, and `mrl` columns in database_helper.dart all contain ppm values. No schema change. When history screen displays them, it applies `_fromPpm`.

Optionally, you could store the unit as a column so the history record remembers what unit was active. But this is unnecessary when using a conversion factor at display time — the stored ppm value is canonical, and the display unit is a user preference applied at render time.

## CSV export impact

In history_screen.dart, the CSV headers say `'CL (mg/L)'`. These should use the current unit:
```dart
'CL ($_unit)', 'FL ($_unit)', 'Avg ($_unit)', 'MRL ($_unit)',
```

And the values should be multiplied by `_fromPpm`. But `HistoryScreen` doesn't currently have access to the unit — it would need to read from `AppState` via `Provider.of<AppState>(context, listen: false).selectedUnit`.

---

# Change 3: Separate CL and FL Calibration Plots

## What exists today

The chart is built by `_buildChart()` at calibration_screen.dart. It creates **one** `LineChart` widget containing **four** `LineChartBarData` entries:

```dart
lineBarsData: [
  _chartLine(_clMeans, _clSlope, _clIntercept, Colors.blue.shade600),   // CL regression line
  _chartDots(_clMeans, Colors.blue.shade600),                            // CL scatter dots
  _chartLine(_flMeans, _flSlope, _flIntercept, Colors.orange.shade600), // FL regression line
  _chartDots(_flMeans, Colors.orange.shade600),                          // FL scatter dots
],
```

These helpers at calibration_screen.dart create:
- `_chartLine()`: a 2-point series (xMin→xMax) representing the regression line, with `dotData: FlDotData(show: false)` to hide dots on the line itself
- `_chartDots()`: a series with `barWidth: 0` (no connecting line) that only renders scatter points using `FlDotCirclePainter`

The single chart is shown inside a `Card` at calibration_screen.dart, with a legend row showing `CL` (blue) and `FL` (orange).

## Why the professor wants them separate

When CL and FL have very different scales (e.g., CL reads 0.2–0.8 normalized while FL reads 0.1–0.4), overlaying them on the same Y-axis compresses one series visually. Separate charts let each have its own auto-scaled axes, making it easier to visually verify linearity independently.

## How to implement it

### Step 1: Create a parameterized single-channel chart builder

Replace `_buildChart()` with:

```dart
Widget _buildSingleChart({
  required List<double> means,
  required double slope,
  required double intercept,
  required double r2,
  required Color color,
  required String channelName,
}) {
  final concs = _concentrations;
  return SizedBox(
    height: 180,
    child: LineChart(
      LineChartData(
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: true),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            axisNameWidget: const Text('ADC reading (norm.)',
                style: TextStyle(fontSize: 10)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(2),
                style: const TextStyle(fontSize: 9),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: Text('Conc. ($_unit)',
                style: const TextStyle(fontSize: 10)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(2),
                style: const TextStyle(fontSize: 9),
              ),
            ),
          ),
          topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false)),
        ),
        lineBarsData: [
          _chartLine(means, slope, intercept, color),
          _chartDots(means, color),
        ],
      ),
    ),
  );
}
```

`_chartLine()` and `_chartDots()` stay identical — they already accept `means`, `slope`, `intercept`, `color` as parameters.

### Step 2: Replace the single chart Card with two Cards

At calibration_screen.dart, currently:

```dart
Card(
  child: Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
    child: Column(
      children: [
        Row(children: [
          Text('Calibration Curve', ...),
          Spacer(),
          _legendDot(Colors.blue.shade600, 'CL'),
          SizedBox(width: 10),
          _legendDot(Colors.orange.shade600, 'FL'),
        ]),
        SizedBox(height: 6),
        _buildChart(),  // ← one combined chart
      ],
    ),
  ),
),
```

Replace with:

```dart
// CL chart
Card(
  child: Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CL Calibration  •  R² = ${_clR2.toStringAsFixed(4)}',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Colors.blue.shade600,
          ),
        ),
        const SizedBox(height: 6),
        _buildSingleChart(
          means: _clMeans,
          slope: _clSlope,
          intercept: _clIntercept,
          r2: _clR2,
          color: Colors.blue.shade600,
          channelName: 'CL',
        ),
      ],
    ),
  ),
),
const SizedBox(height: 8),
// FL chart
Card(
  child: Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'FL Calibration  •  R² = ${_flR2.toStringAsFixed(4)}',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Colors.orange.shade600,
          ),
        ),
        const SizedBox(height: 6),
        _buildSingleChart(
          means: _flMeans,
          slope: _flSlope,
          intercept: _flIntercept,
          r2: _flR2,
          color: Colors.orange.shade600,
          channelName: 'FL',
        ),
      ],
    ),
  ),
),
```

Each chart has its own title with the R² value prominently displayed. The `_legendDot()` helper is no longer needed (each chart has only one color) and can be removed.

### Step 3: Scroll overflow fix

The calibrated view now has: coefficients card (~80px) + CL chart card (~210px) + FL chart card (~210px) + "Proceed to Measurement" button (~50px) = ~550px. On most phones this exceeds the available space below the level table.

The fix: the `if (_calibrated) ...[` section (starting at calibration_screen.dart) currently dumps all its children into the outer `Column`. Instead, wrap the calibrated content in a `SingleChildScrollView`:

The current structure of the outer `Column` is:
```
Column(
  children: [
    Text('Step 2 • Calibration'),     // fixed header
    Text('Select pesticide...'),       // fixed subtitle
    Pesticide selector Row,            // fixed
    Concentration entry Card,          // hidden after collection starts
    Expanded(child: ListView(...)),    // level table (scrolls independently)
    Action buttons,                    // Collect / Compute
    if (_calibrated) ...[              // charts + coefficients + proceed button
      Card(coefficients),
      Card(CL chart),
      Card(FL chart),
      FilledButton(proceed),
    ],
  ],
)
```

The problem: when calibrated, both the `Expanded(ListView)` and the calibrated cards fight for space. The solution is to replace the `Expanded(ListView)` + calibrated cards with a **single** `Expanded` that switches content:

```dart
Expanded(
  child: _calibrated
      ? SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Level summary (compact, not full ListView)
              ...List.generate(concs.length, (i) => /* compact level tile */),
              SizedBox(height: 8),
              // Coefficients card
              Card(...),
              SizedBox(height: 8),
              // CL chart card
              Card(...),
              SizedBox(height: 8),
              // FL chart card
              Card(...),
              SizedBox(height: 10),
              // Proceed button
              FilledButton.icon(...),
            ],
          ),
        )
      : ListView.separated(
          itemCount: concs.length,
          // ... existing level table builder
        ),
),
```

This way, before calibration: the level table fills the space. After calibration: everything becomes scrollable.

### What to delete

- The old `_buildChart()` method (entire method)
- The `_legendDot()` helper widget (no longer needed)

---

# Change 4: R² Threshold 0.95 + Dynamic Point Addition

## The science behind this change

Currently `_computeCalibration()` at calibration_screen.dart does:
```dart
if (_clR2 < 0.99 || _flR2 < 0.99) {
  _warning = 'R² below 0.99 — linearity is poor. ...';
}
_calibrated = true;  // always proceeds
```

This is too strict (0.99) and too permissive (always sets `_calibrated = true` even with terrible R²). The professor wants:
- **R² ≥ 0.99**: excellent, proceed normally
- **0.95 ≤ R² < 0.99**: acceptable but warn; suggest adding a 5th point to improve
- **R² < 0.95**: block proceeding; require adding a point or recalibrating

The scientific basis: Beer-Lambert law says absorbance is linear with concentration. An R² < 0.95 means the relationship is significantly nonlinear, which could be due to a contaminated blank, air bubbles, or lamp drift on one reading. Adding a 5th concentration point gives the linear fit more data to work with and can improve R² if the issue was a single bad reading pulling the fit off.

## Data model changes — making levels dynamic

This is the most invasive change. Today, the number of calibration levels is fixed at 4.

### Current data structures

```dart
// Lines 27-28: Fixed constants
static const List<String> _levelNames = ['Blank', 'Low', 'Mid', 'High'];
static const int _samplesPerLevel = 5;

// Lines 31-33: Fixed controllers
final _lowCtrl  = TextEditingController(text: '0.10');
final _midCtrl  = TextEditingController(text: '0.50');
final _highCtrl = TextEditingController(text: '1.00');

// Lines 35-40: Fixed getter
List<double> get _concentrations => [
      0.00,
      double.tryParse(_lowCtrl.text.trim())  ?? 0.10,
      double.tryParse(_midCtrl.text.trim())  ?? 0.50,
      double.tryParse(_highCtrl.text.trim()) ?? 1.00,
    ];
```

### New data structures

```dart
// Dynamic controller list (starts with 3, can grow)
final List<TextEditingController> _concControllers = [
  TextEditingController(text: '0.10'),
  TextEditingController(text: '0.50'),
  TextEditingController(text: '1.00'),
];

// Dynamic level names
List<String> get _levelNames => [
  'Blank',
  for (int i = 0; i < _concControllers.length; i++) 'Std ${i + 1}',
];

// Dynamic concentrations (Blank fixed at 0.00 + all controllers)
List<double> get _concentrations => [
  0.00,
  ..._concControllers.map(
    (c) => (double.tryParse(c.text.trim()) ?? 0.0) * _toPpm,
  ),
];
```

Remove `_lowCtrl`, `_midCtrl`, `_highCtrl` as individual fields.

### New state variable

```dart
bool _showAddPointOption = false;
```

### Changes to `_computeCalibration()`

Replace the current body at calibration_screen.dart:

```dart
void _computeCalibration() {
  final concs = _concentrations;
  final clFit = linearFit(_clMeans, concs.sublist(0, _clMeans.length));
  final flFit = linearFit(_flMeans, concs.sublist(0, _flMeans.length));

  _clSlope = clFit[0]; _clIntercept = clFit[1]; _clR2 = clFit[2];
  _flSlope = flFit[0]; _flIntercept = flFit[1]; _flR2 = flFit[2];

  final minR2 = _clR2 < _flR2 ? _clR2 : _flR2;

  if (minR2 < 0.95) {
    // ── Below 0.95: block proceeding ──
    _calibrated = false;
    _showAddPointOption = true;
    _warning = 'R² = ${minR2.toStringAsFixed(4)} (below 0.95). '
        'Add another calibration point or recalibrate from scratch.';
    setState(() {});
    return; // do NOT save to AppState or send cal_end
  }

  if (minR2 < 0.99) {
    // ── Between 0.95 and 0.99: proceed with warning ──
    _warning = 'R² = ${minR2.toStringAsFixed(4)} (below 0.99). '
        'Consider adding a point to improve linearity.';
    _showAddPointOption = true;
  } else {
    // ── ≥ 0.99: excellent ──
    _warning = null;
    _showAddPointOption = false;
  }

  _calibrated = true;

  final appState = Provider.of<AppState>(context, listen: false);
  appState.updateCalibration(
    clSlope:     _clSlope,
    clIntercept: _clIntercept,
    flSlope:     _flSlope,
    flIntercept: _flIntercept,
    clR2:        _clR2,
    flR2:        _flR2,
    pesticide:   _selectedPesticide,
  );
  appState.connection?.send(Protocol.encodeCalEnd());
  setState(() {});
}
```

The key behavioral difference: when R² < 0.95, `_calibrated` stays `false`, the calibration is NOT saved to `AppState`, and `cal_end` is NOT sent to the firmware. The user must either add a point or recalibrate.

### The `_addCalibrationPoint()` method (new)

```dart
void _addCalibrationPoint() {
  setState(() {
    // Add a new empty controller for the extra level
    _concControllers.add(TextEditingController(text: ''));
    
    // Reset calibration state but KEEP existing collected means
    _calibrated = false;
    _showAddPointOption = false;
    _warning = null;
    
    // _currentLevel should point to the next uncollected level.
    // _clMeans.length tells us how many levels have been collected already.
    // The new level becomes the next one to collect.
    _currentLevel = _clMeans.length;
  });
}
```

Critical detail: **we do NOT clear `_clMeans` and `_flMeans`**. The data for the first 4 levels is still valid. We only need to collect the new 5th level. After collection, the user taps "Compute Calibration" again, and `linearFit()` now gets 5 data points instead of 4, which should improve R².

### UI for the add-point option

After the warning card (at calibration_screen.dart), add:

```dart
if (_showAddPointOption) ...[
  const SizedBox(height: 8),
  Row(
    children: [
      Expanded(
        child: OutlinedButton.icon(
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('Add Point'),
          onPressed: _addCalibrationPoint,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: OutlinedButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Start Over'),
          onPressed: _reset,
        ),
      ),
    ],
  ),
],
```

When the user taps "Add Point":
1. A new empty `TextEditingController` is added to `_concControllers`
2. The concentration entry UI reappears (because `_calibrated` is false and if R² < 0.95, it was never set true)
3. The level table shows 5 levels — the first 4 with green checkmarks, the 5th as "Ready"
4. The user enters a concentration value in the new field
5. Taps "Collect Level 5 (Std 4)"
6. After collection, taps "Compute Calibration" again
7. If R² is now ≥ 0.95, proceeds normally

### Concentration entry UI — making it dynamic

The current fixed `Row` with 4 fields at calibration_screen.dart:

```dart
Row(
  children: [
    _concField('Blank', null),
    SizedBox(width: 8),
    _concField('Low',  _lowCtrl),
    SizedBox(width: 8),
    _concField('Mid',  _midCtrl),
    SizedBox(width: 8),
    _concField('High', _highCtrl),
  ],
),
```

This won't work when there are 5+ fields — they'd overflow the row. Replace with `Wrap`:

```dart
Wrap(
  spacing: 8,
  runSpacing: 8,
  children: [
    SizedBox(width: 70, child: _concField('Blank', null)),
    for (int i = 0; i < _concControllers.length; i++)
      SizedBox(width: 70, child: _concField('Std ${i + 1}', _concControllers[i])),
  ],
),
```

The `_concField` helper at calibration_screen.dart currently returns `Expanded(...)`. Change it to return just the `Column(...)` without `Expanded`, since the parent `SizedBox(width: 70)` now controls width.

### `canEdit` guard update

Currently at calibration_screen.dart:
```dart
final canEdit = !_collecting && !_calibrated && _clMeans.isEmpty;
```

This blocks editing once any level is collected. But for the add-point flow, we need to let the user edit the NEW field while keeping old data. Change to:

```dart
final canEdit = !_collecting && !_calibrated;
```

However, we still want to prevent changing already-collected levels' concentrations. The solution: make `_concField` read-only for controllers whose index is < `_clMeans.length - 1` (i.e., levels already collected). For the newly added empty controller, it stays editable.

Alternatively, a simpler approach: the concentration entry card appears whenever `!_calibrated`. The old collected values are shown as read-only in the level table. The new empty field is the only one the user interacts with. To enforce this, pass `enabled: i >= _clMeans.length` to each `_concField`'s `TextField`.

### `_reset()` method update

At calibration_screen.dart, update to work with dynamic controllers:

```dart
void _reset() {
  Provider.of<AppState>(context, listen: false).clearCalibration();
  setState(() {
    _clMeans.clear();
    _flMeans.clear();
    _currentLevel = 0;
    _sampleCount  = 0;
    _collecting   = false;
    _calibrated   = false;
    _warning      = null;
    _showAddPointOption = false;
    _stabilizing = false;
    _stabilizeRemain = 0;
    _clSlope = _clIntercept = _clR2 = 0;
    _flSlope = _flIntercept = _flR2 = 0;
    // Reset controllers back to default 3
    for (final c in _concControllers) { c.dispose(); }
    _concControllers.clear();
    _concControllers.addAll([
      TextEditingController(text: '0.10'),
      TextEditingController(text: '0.50'),
      TextEditingController(text: '1.00'),
    ]);
  });
}
```

### `dispose()` update

At calibration_screen.dart:
```dart
@override
void dispose() {
  _sub?.cancel();
  for (final c in _concControllers) { c.dispose(); }
  super.dispose();
}
```

Remove the old `_lowCtrl.dispose(); _midCtrl.dispose(); _highCtrl.dispose();` lines.

### Level table `itemCount` already works

At calibration_screen.dart:
```dart
itemCount: concs.length,
```

Since `concs` comes from the dynamic `_concentrations` getter, the list naturally shows 5 rows when a 5th point is added. No change needed.

### `allLevelsCollected` already works

At calibration_screen.dart:
```dart
final allLevelsCollected = _clMeans.length == concs.length;
```

After adding a 5th point: `_clMeans.length` = 4, `concs.length` = 5, so `allLevelsCollected` = false. The "Collect Level 5" button appears. After collecting it: both = 5, so "Compute Calibration" appears. Everything works automatically.

## Firmware and protocol impact

**None.** The firmware doesn't care how many levels there are — it simply responds to each `cal_sample` with an ADC reading. The protocol messages are level-agnostic (they carry the level label as a string, not an index).

## Test impact

The `linearFit()` function in math_utils.dart already handles any number of points ≥ 2. The test at math_utils_test.dart uses 4-point data. You should add a test with 5 points to verify:

```dart
test('5-point data produces R² ≥ 0.99', () {
  final x = [0.0, 0.25, 0.5, 0.75, 1.0];
  final y = [0.0, 0.25, 0.50, 0.75, 1.00];
  final fit = linearFit(x, y);
  expect(fit[2], closeTo(1.0, 1e-9));
});
```

---

## Summary: Complete File Impact Map

| File | Change 1 (delay) | Change 2 (units) | Change 3 (split charts) | Change 4 (R² + add point) |
|------|:-:|:-:|:-:|:-:|
| calibration_screen.dart | Add `_stabilizing`/`_stabilizeRemain` state, 10s countdown loop, UI countdown text | Unit dropdown, `_toPpm`/`_fromPpm` getters, convert `_concentrations`, update all display labels | Replace `_buildChart()` with `_buildSingleChart()`, two `Card`s, fix scroll overflow | Dynamic `_concControllers`, `_addCalibrationPoint()`, tiered R² logic, `_showAddPointOption` UI, `Wrap` layout |
| measurement_screen.dart | Add `_stabilizeRemain`, 10s countdown loop, UI update | `_fromPpm` getter, convert displayed values, update `_ConcChip` | — | — |
| app_state.dart | — | Add `selectedUnit` field + persist/load | — | — |
| history_screen.dart | — | Read unit from AppState, apply to display + CSV headers | — | — |
| math_utils_test.dart | — | — | — | Add 5-point test case |
| CLAUDE.md | Document stabilization delay | Document unit system | — | Update R² threshold documentation |
| All firmware files | **No changes** | **No changes** | **No changes** | **No changes** |


