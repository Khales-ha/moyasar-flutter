import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyasar/src/utils/before_payment_hook.dart';

void main() {
  test('allows the payment when no hook is given', () async {
    expect(await runBeforePaymentHook(null), isTrue);
  });

  test('allows the payment when the hook approves', () async {
    expect(await runBeforePaymentHook(() async => true), isTrue);
  });

  test('vetoes the payment when the hook refuses', () async {
    expect(await runBeforePaymentHook(() async => false), isFalse);
  });

  test('vetoes the payment when the hook throws', () async {
    // Fail closed: a host whose pre-charge work blew up has not completed it,
    // and an uncaught error here would otherwise let the sheet present.
    expect(
      await runBeforePaymentHook(() async => throw StateError('disk full')),
      isFalse,
    );
  });

  test('vetoes the payment when the hook throws synchronously', () async {
    expect(
      await runBeforePaymentHook(() => throw StateError('disk full')),
      isFalse,
    );
  });

  test('does not answer before the hook completes', () async {
    final gate = Completer<bool>();
    var answered = false;

    unawaited(runBeforePaymentHook(() => gate.future).then((_) {
      answered = true;
    }));

    await Future<void>.delayed(Duration.zero);
    expect(answered, isFalse);

    gate.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(answered, isTrue);
  });
}
