import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyasar/moyasar.dart';

void main() {
  const channel = MethodChannel('flutter.moyasar.com/apple_pay');

  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  /// Records the calls the widget makes, and replies with [availability].
  List<MethodCall> mockNativeAvailability(String? availability) {
    final calls = <MethodCall>[];

    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      return availability;
    });

    return calls;
  }

  PaymentConfig buildConfig() => PaymentConfig(
        publishableApiKey: 'pk_test_key',
        amount: 123,
        description: 'Test payment',
        applePay: ApplePayConfig(
          merchantId: 'merchant.com.test',
          label: 'Test Store',
          manual: false,
          saveCard: false,
        ),
      );

  Widget buildSubject({
    int amount = 123,
    Function? onPaymentResult,
    Future<bool> Function()? onBeforePayment,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: ApplePay(
            config: PaymentConfig(
              publishableApiKey: 'pk_test_key',
              amount: amount,
              description: 'Test payment',
              applePay: ApplePayConfig(
                merchantId: 'merchant.com.test',
                label: 'Test Store',
                manual: false,
                saveCard: false,
              ),
            ),
            onPaymentResult: onPaymentResult ?? (_) {},
            onBeforePayment: onBeforePayment,
          ),
        ),
      );

  /// Delivers [arguments] to the widget's handler the way the native side
  /// would, going through the real codec rather than calling the handler
  /// directly.
  Future<void> sendFromNative(String method, Object? arguments) {
    return binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  /// Delivers [method] the way the native side would and returns what Dart
  /// answered, decoded from the reply envelope.
  Future<Object?> callFromNative(String method) async {
    Object? reply;

    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method)),
      (data) => reply = channel.codec.decodeEnvelope(data!),
    );

    return reply;
  }

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  /// Pumps the widget as [platform], restoring the override before the test
  /// ends — the framework asserts debug variables are unset by then.
  Future<void> pumpAs(WidgetTester tester, TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('renders nothing on Android without calling the native side',
      (tester) async {
    final calls = mockNativeAvailability('ready');

    await pumpAs(tester, TargetPlatform.android);

    expect(find.byType(UiKitView), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets('renders nothing when the device cannot support Apple Pay',
      (tester) async {
    mockNativeAvailability('notSupported');

    await pumpAs(tester, TargetPlatform.iOS);

    expect(find.byType(UiKitView), findsNothing);
  });

  testWidgets('asks the native side for availability on iOS', (tester) async {
    final calls = mockNativeAvailability('notSupported');

    await pumpAs(tester, TargetPlatform.iOS);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'getApplePayAvailability');
    expect(
      (calls.single.arguments as Map)['supportedNetworks'],
      buildConfig().supportedNetworks.map((e) => e.toJson()).toList(),
    );
  });

  testWidgets('rebuilds the native view when the amount changes',
      (tester) async {
    // A native view reads its creationParams once, so a changed amount must
    // produce a new key — otherwise the button would charge the stale amount.
    mockNativeAvailability('ready');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(buildSubject(amount: 10000));
    await tester.pumpAndSettle();
    final firstKey = tester.widget<UiKitView>(find.byType(UiKitView)).key;

    await tester.pumpWidget(buildSubject(amount: 20000));
    await tester.pumpAndSettle();
    final secondKey = tester.widget<UiKitView>(find.byType(UiKitView)).key;

    expect(secondKey, isNot(firstKey));
    expect(
      tester.widget<UiKitView>(find.byType(UiKitView)).creationParams,
      contains('"paymentAmount":"200.00"'),
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('reports an error when the native result is not a map',
      (tester) async {
    // A malformed payload must still reach onPaymentResult — throwing here
    // would be swallowed by the channel and the payment would never respond.
    mockNativeAvailability('ready');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final results = <dynamic>[];
    await tester.pumpWidget(buildSubject(onPaymentResult: results.add));
    await tester.pumpAndSettle();

    await sendFromNative('onApplePayResult', null);
    await sendFromNative('onApplePayResult', 'not-a-map');
    await tester.pumpAndSettle();

    expect(results, hasLength(2));
    expect(results.every((r) => r is UnprocessableTokenError), isTrue);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('reports a canceled payment when the native side errors',
      (tester) async {
    mockNativeAvailability('ready');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final results = <dynamic>[];
    await tester.pumpWidget(buildSubject(onPaymentResult: results.add));
    await tester.pumpAndSettle();

    await sendFromNative('onApplePayError', null);
    await tester.pumpAndSettle();

    expect(results.single, isA<PaymentCanceledError>());

    debugDefaultTargetPlatformOverride = null;
  });

  group('onBeforePayment', () {
    /// The exact creationParams 3.0.5 sent for [buildSubject]'s config, copied
    /// off the pre-hook build. A consumer that passes no hook must still get
    /// this payload byte for byte, since it is what the native press path
    /// branches on.
    const unhookedNativeConfig =
        '{"merchantIdentifier":"merchant.com.test","paymentLabel":"Test Store","merchantCapabilities":["3DS","debit","credit"],"supportedCountries":["SA"],"supportedNetworks":["visa","mada","masterCard","unionpay"],"countryCode":"SA","currencyCode":"SAR","paymentAmount":"1.23","buttonType":"inStore","buttonStyle":"black"}';

    Future<void> pumpWithHook(
      WidgetTester tester,
      Future<bool> Function()? hook,
    ) async {
      mockNativeAvailability('ready');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await tester.pumpWidget(buildSubject(onBeforePayment: hook));
      await tester.pumpAndSettle();

      debugDefaultTargetPlatformOverride = null;
    }

    String creationParams(WidgetTester tester) =>
        tester.widget<UiKitView>(find.byType(UiKitView)).creationParams
            as String;

    testWidgets('sends the pre-hook creationParams when no hook is given',
        (tester) async {
      await pumpWithHook(tester, null);

      expect(creationParams(tester), unhookedNativeConfig);
    });

    testWidgets('flags the native side when a hook is given', (tester) async {
      // Without this flag the native press presents the sheet immediately, so
      // the hook would never be consulted and a veto would charge anyway.
      await pumpWithHook(tester, () async => true);

      expect(
        creationParams(tester),
        '${unhookedNativeConfig.substring(0, unhookedNativeConfig.length - 1)}'
        ',"hasBeforePaymentHook":true}',
      );
    });

    testWidgets('recreates the native view when a hook is added',
        (tester) async {
      // The native view reads creationParams once. A hook added to a live
      // widget must change the key, or the button keeps presenting without it.
      mockNativeAvailability('ready');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();
      final unhookedKey = tester.widget<UiKitView>(find.byType(UiKitView)).key;

      await tester.pumpWidget(buildSubject(onBeforePayment: () async => true));
      await tester.pumpAndSettle();

      expect(
        tester.widget<UiKitView>(find.byType(UiKitView)).key,
        isNot(unhookedKey),
      );

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('answers true when the hook approves', (tester) async {
      await pumpWithHook(tester, () async => true);

      expect(await callFromNative('onBeforePayment'), isTrue);
    });

    testWidgets('answers false when the hook vetoes', (tester) async {
      await pumpWithHook(tester, () async => false);

      expect(await callFromNative('onBeforePayment'), isFalse);
    });

    testWidgets('answers false when the hook throws', (tester) async {
      await pumpWithHook(tester, () async => throw StateError('disk full'));

      expect(await callFromNative('onBeforePayment'), isFalse);
    });

    testWidgets('answers true when no hook is given', (tester) async {
      // Defensive: a native view that asks anyway must not be left hanging,
      // which would be a button that never presents.
      await pumpWithHook(tester, null);

      expect(await callFromNative('onBeforePayment'), isTrue);
    });

    testWidgets('does not answer until the hook completes', (tester) async {
      // The whole point of the hook: the native side is still waiting, so the
      // sheet has not presented, while the host's pre-charge work is in flight.
      final gate = Completer<bool>();
      await pumpWithHook(tester, () => gate.future);

      Object? reply;
      var answered = false;
      final pending = binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('onBeforePayment')),
        (data) {
          answered = true;
          reply = channel.codec.decodeEnvelope(data!);
        },
      );

      await tester.pump();
      expect(answered, isFalse);

      gate.complete(true);
      await pending;

      expect(reply, isTrue);
    });

    testWidgets('does not run the hook for any other native call',
        (tester) async {
      var runs = 0;
      await pumpWithHook(tester, () async {
        runs++;
        return true;
      });

      await sendFromNative('onApplePayError', null);
      await tester.pumpAndSettle();

      expect(runs, 0);
    });
  });
}
