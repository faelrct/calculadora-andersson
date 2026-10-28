import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const CalculatorApp());

// =============================================================================
// APP
// =============================================================================

class CalculatorApp extends StatelessWidget {
  const CalculatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1F5FA8);
    return MaterialApp(
      title: 'Calculadora Científica',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const CalculatorPage(),
    );
  }
}

// =============================================================================
// DOMÍNIO / LÓGICA (independente de interface)
// =============================================================================

/// Operações binárias suportadas.
enum Operation {
  add('+'),
  subtract('−'),
  multiply('×'),
  divide('÷'),
  power('^');

  const Operation(this.symbol);
  final String symbol;
}

/// Erro de regra de negócio (ex.: divisão por zero).
class CalculatorException implements Exception {
  const CalculatorException(this.message);
  final String message;
}

/// Controla o estado e as regras da calculadora.
class CalculatorController extends ChangeNotifier {
  static const int _maxDigits = 15;

  // O visor é uma String; a conversão para double ocorre só no cálculo.
  String _display = '0';
  String _expression = '';
  double? _accumulator;
  Operation? _operation;
  bool _startNewNumber = true;
  String? _error;
  final List<String> _history = [];

  String get display => _error ?? _display;
  String get expression => _expression;
  bool get hasError => _error != null;
  List<String> get history => List.unmodifiable(_history);

  // ---------- Conversões ----------

  double _parse(String text) => double.tryParse(text.replaceAll(',', '.')) ?? 0;

  String _format(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    // Limita a precisão para evitar ruídos como 0.30000000000000004.
    return double.parse(value.toStringAsPrecision(12))
        .toString()
        .replaceAll('.', ',');
  }

  // ---------- Entrada ----------

  void inputDigit(String digit) {
    _clearErrorIfAny();
    if (_startNewNumber) {
      _display = digit;
      _startNewNumber = false;
    } else if (_display.replaceAll(RegExp(r'[-,]'), '').length < _maxDigits) {
      _display = _display == '0' ? digit : _display + digit;
    }
    notifyListeners();
  }

  void inputDecimal() {
    _clearErrorIfAny();
    if (_startNewNumber) {
      _display = '0,';
      _startNewNumber = false;
    } else if (!_display.contains(',')) {
      _display += ',';
    }
    notifyListeners();
  }

  void backspace() {
    if (hasError) return clear();
    if (_startNewNumber) return;
    _display = _display.length > 1 ? _display.substring(0, _display.length - 1) : '0';
    if (_display == '-') _display = '0';
    notifyListeners();
  }

  void toggleSign() {
    if (hasError || _display == '0') return;
    _display = _display.startsWith('-') ? _display.substring(1) : '-$_display';
    notifyListeners();
  }

  void clear() {
    _display = '0';
    _expression = '';
    _accumulator = null;
    _operation = null;
    _startNewNumber = true;
    _error = null;
    notifyListeners();
  }

  void clearHistory() {
    _history.clear();
    notifyListeners();
  }

  // ---------- Operações binárias ----------

  void setOperation(Operation op) {
    if (hasError) return;
    _guard(() {
      final current = _parse(_display);
      if (_operation != null && _accumulator != null && !_startNewNumber) {
        // Encadeamento: 2 + 3 + ... resolve a operação pendente primeiro.
        _accumulator = _compute(_accumulator!, _operation!, current);
        _display = _format(_accumulator!);
      } else if (_accumulator == null || _operation == null) {
        _accumulator = current;
      }
      _operation = op;
      _expression = '${_format(_accumulator!)} ${op.symbol}';
      _startNewNumber = true;
    });
  }

  void equals() {
    if (hasError || _operation == null || _accumulator == null) return;
    _guard(() {
      final a = _accumulator!;
      final op = _operation!;
      final b = _parse(_display);
      final result = _compute(a, op, b);
      _expression = '${_format(a)} ${op.symbol} ${_format(b)} =';
      _history.add('${_format(a)} ${op.symbol} ${_format(b)} = ${_format(result)}');
      _display = _format(result);
      _accumulator = null;
      _operation = null;
      _startNewNumber = true;
    });
  }

  /// Regra de negócio: escolhe a operação com `switch`.
  double _compute(double a, Operation op, double b) {
    final double result;
    switch (op) {
      case Operation.add:
        result = a + b;
      case Operation.subtract:
        result = a - b;
      case Operation.multiply:
        result = a * b;
      case Operation.divide:
        if (b == 0) {
          throw const CalculatorException('Não é possível dividir por zero');
        }
        result = a / b;
      case Operation.power:
        result = math.pow(a, b).toDouble();
    }
    return _validated(result);
  }

  // ---------- Operações científicas ----------

  void squareRoot() => _unary('√', (x) {
        if (x < 0) {
          throw const CalculatorException('Raiz de número negativo é inválida');
        }
        return math.sqrt(x);
      });

  void square() => _unary('sqr', (x) => x * x);

  void factorial() => _unary('fact', (x) {
        if (x < 0 || x != x.truncateToDouble()) {
          throw const CalculatorException('Fatorial exige inteiro ≥ 0');
        }
        if (x > 170) {
          throw const CalculatorException('Resultado muito grande');
        }
        double r = 1;
        for (int i = 2; i <= x.toInt(); i++) {
          r *= i;
        }
        return r;
      });

  void percent() => _unary('%', (x) {
        // Com + ou − pendente, calcula a porcentagem do primeiro operando.
        final base = _accumulator;
        if (base != null &&
            (_operation == Operation.add || _operation == Operation.subtract)) {
          return base * x / 100;
        }
        return x / 100;
      });

  void _unary(String label, double Function(double) fn) {
    if (hasError) return;
    _guard(() {
      final x = _parse(_display);
      final r = _validated(fn(x));
      final shown = switch (label) {
        '√' => '√(${_format(x)})',
        'sqr' => 'sqr(${_format(x)})',
        'fact' => '${_format(x)}!',
        _ => '${_format(x)}%',
      };
      _history.add('$shown = ${_format(r)}');
      _display = _format(r);
      _startNewNumber = true;
    });
  }

  // ---------- Utilidades internas ----------

  double _validated(double value) {
    if (value.isNaN || value.isInfinite) {
      throw const CalculatorException('Resultado inválido');
    }
    return value;
  }

  void _clearErrorIfAny() {
    if (hasError) {
      _error = null;
      _display = '0';
      _startNewNumber = true;
    }
  }

  /// Executa uma ação convertendo erros de negócio em mensagem no visor.
  void _guard(VoidCallback action) {
    try {
      action();
    } on CalculatorException catch (e) {
      _error = e.message;
      _accumulator = null;
      _operation = null;
      _expression = '';
      _startNewNumber = true;
    }
    notifyListeners();
  }
}

// =============================================================================
// INTERFACE
// =============================================================================

enum KeyKind { digit, operator, scientific, clear, equals }

class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key});

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  final CalculatorController _c = CalculatorController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Suporte ao teclado físico (útil em desktop e web).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ch = event.character ?? '';

    if (RegExp(r'^[0-9]$').hasMatch(ch)) {
      _c.inputDigit(ch);
    } else if (ch == ',' || ch == '.') {
      _c.inputDecimal();
    } else if (ch == '+') {
      _c.setOperation(Operation.add);
    } else if (ch == '-') {
      _c.setOperation(Operation.subtract);
    } else if (ch == '*') {
      _c.setOperation(Operation.multiply);
    } else if (ch == '/') {
      _c.setOperation(Operation.divide);
    } else if (ch == '^') {
      _c.setOperation(Operation.power);
    } else if (ch == '%') {
      _c.percent();
    } else if (ch == '!') {
      _c.factorial();
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        ch == '=') {
      _c.equals();
    } else if (key == LogicalKeyboardKey.backspace) {
      _c.backspace();
    } else if (key == LogicalKeyboardKey.escape) {
      _c.clear();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _showHistory() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListenableBuilder(
        listenable: _c,
        builder: (context, _) {
          final items = _c.history.reversed.toList();
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Text('Histórico',
                            style: Theme.of(context).textTheme.titleLarge),
                        const Spacer(),
                        TextButton(
                          onPressed: items.isEmpty ? null : _c.clearHistory,
                          child: const Text('Limpar'),
                        ),
                      ],
                    ),
                  ),
                  if (items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('Nenhum cálculo realizado ainda.'),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(items[i],
                              style: Theme.of(context).textTheme.bodyLarge),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Calculadora Científica'),
          actions: [
            IconButton(
              tooltip: 'Histórico',
              icon: const Icon(Icons.history),
              onPressed: _showHistory,
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: ListenableBuilder(
                  listenable: _c,
                  builder: (context, _) => Column(
                    children: [
                      Expanded(flex: 3, child: _DisplayPanel(controller: _c)),
                      const SizedBox(height: 12),
                      Expanded(flex: 8, child: _Keypad(controller: _c)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DisplayPanel extends StatelessWidget {
  const _DisplayPanel({required this.controller});
  final CalculatorController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background =
        isDark ? scheme.surfaceContainerLowest : const Color(0xFF14202B);
    final error = controller.hasError;

    return Semantics(
      liveRegion: true,
      label: 'Visor: ${controller.display}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              controller.expression,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, color: Color(0xA6FFFFFF)),
            ),
            if (error)
              Row(
                children: [
                  const Icon(Icons.error_outline,
                      color: Color(0xFFFF8A80), size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      controller.display,
                      style: const TextStyle(
                        fontSize: 20,
                        color: Color(0xFFFF8A80),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              )
            else
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  controller.display,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 52,
                    color: Colors.white,
                    fontWeight: FontWeight.w300,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.controller});
  final CalculatorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final rows = <List<_KeySpec>>[
      [
        _KeySpec('√', KeyKind.scientific, c.squareRoot),
        _KeySpec('x²', KeyKind.scientific, c.square),
        _KeySpec('xʸ', KeyKind.scientific, () => c.setOperation(Operation.power)),
        _KeySpec('x!', KeyKind.scientific, c.factorial),
      ],
      [
        _KeySpec('C', KeyKind.clear, c.clear),
        _KeySpec('⌫', KeyKind.clear, c.backspace),
        _KeySpec('%', KeyKind.scientific, c.percent),
        _KeySpec('÷', KeyKind.operator, () => c.setOperation(Operation.divide)),
      ],
      [
        _KeySpec('7', KeyKind.digit, () => c.inputDigit('7')),
        _KeySpec('8', KeyKind.digit, () => c.inputDigit('8')),
        _KeySpec('9', KeyKind.digit, () => c.inputDigit('9')),
        _KeySpec('×', KeyKind.operator, () => c.setOperation(Operation.multiply)),
      ],
      [
        _KeySpec('4', KeyKind.digit, () => c.inputDigit('4')),
        _KeySpec('5', KeyKind.digit, () => c.inputDigit('5')),
        _KeySpec('6', KeyKind.digit, () => c.inputDigit('6')),
        _KeySpec('−', KeyKind.operator, () => c.setOperation(Operation.subtract)),
      ],
      [
        _KeySpec('1', KeyKind.digit, () => c.inputDigit('1')),
        _KeySpec('2', KeyKind.digit, () => c.inputDigit('2')),
        _KeySpec('3', KeyKind.digit, () => c.inputDigit('3')),
        _KeySpec('+', KeyKind.operator, () => c.setOperation(Operation.add)),
      ],
      [
        _KeySpec('±', KeyKind.digit, c.toggleSign),
        _KeySpec('0', KeyKind.digit, () => c.inputDigit('0')),
        _KeySpec(',', KeyKind.digit, c.inputDecimal),
        _KeySpec('=', KeyKind.equals, c.equals),
      ],
    ];

    return Column(
      children: [
        for (final row in rows)
          Expanded(
            child: Row(
              children: [
                for (final key in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _CalcButton(spec: key),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _KeySpec {
  const _KeySpec(this.label, this.kind, this.onPressed);
  final String label;
  final KeyKind kind;
  final VoidCallback onPressed;
}

class _CalcButton extends StatelessWidget {
  const _CalcButton({required this.spec});
  final _KeySpec spec;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (spec.kind) {
      KeyKind.digit => (s.surfaceContainerHighest, s.onSurface),
      KeyKind.operator => (s.secondaryContainer, s.onSecondaryContainer),
      KeyKind.scientific => (s.tertiaryContainer, s.onTertiaryContainer),
      KeyKind.clear => (s.errorContainer, s.onErrorContainer),
      KeyKind.equals => (s.primary, s.onPrimary),
    };

    return Semantics(
      button: true,
      label: spec.label,
      excludeSemantics: true,
      child: SizedBox.expand(
        child: FilledButton(
          onPressed: () {
            HapticFeedback.selectionClick();
            spec.onPressed();
          },
          style: FilledButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: fg,
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: Text(
            spec.label,
            style: TextStyle(
              fontSize: 24,
              fontWeight:
                  spec.kind == KeyKind.equals ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
