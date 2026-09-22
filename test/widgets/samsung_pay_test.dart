import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyasar/moyasar.dart';

void main() {
  const channel = MethodChannel('samsung_pay_sdk_flutter');
  const startPayment = 'startInAppPayWithCustomSheet';

  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> nativeCalls;

  setUp(() {
    nativeCalls = <MethodCall>[];

    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      nativeCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  PaymentConfig buildConfig({
    int amount = 10000,
    String? orderNumber,
  }) =>
      PaymentConfig(
        publishableApiKey: 'pk_test_key_that_is_long',
        amount: amount,
        description: 'Test payment',
        samsungPay: SamsungPayConfig(
          serviceId: 'svc_test',
          merchantName: 'Test Store',
          orderNumber: orderNumber,
        ),
      );

  Widget buildSubject({
    required PaymentConfig config,
    Function? onPaymentResult,
    Future<bool> Function()? onBeforePayment,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: SamsungPay(
            config: config,
            onPaymentResult: onPaymentResult ?? (_) {},
            onBeforePayment: onBeforePayment,
          ),
        ),
      );

  /// Runs [body] as Android. The widget reads the platform on every build, so
  /// the override has to stay in place for all of a test's pumps.
  Future<void> asAndroid(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// Reports Samsung Pay as ready the way the native plugin does. The button
  /// renders nothing until this arrives.
  ///
  /// The reply is decoded rather than dropped: a handler that throws — a
  /// `setState` after dispose, say — is caught by the channel and returned as
  /// an error envelope, which nothing else in the test would notice.
  Future<void> reportReady() async {
    Object? reply;

    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(
        'samsungPayStatusFlutter',
        jsonEncode({
          'event': 'onSuccess',
          'status': 2,
          'bundle': <String, dynamic>{},
        }),
      )),
      (data) => reply = data,
    );

    channel.codec.decodeEnvelope(reply! as ByteData);
  }

  Future<void> pumpReady(WidgetTester tester, Widget subject) async {
    await tester.pumpWidget(subject);
    await tester.pump();
    await reportReady();
    await tester.pumpAndSettle();
  }

  Iterable<MethodCall> sheetCalls() =>
      nativeCalls.where((call) => call.method == startPayment);

  Map<String, dynamic> sheetPayload() =>
      jsonDecode(sheetCalls().single.arguments as String)
          as Map<String, dynamic>;

  /// The total the sheet will show the customer, in major units.
  double sheetTotal(Map<String, dynamic> payload) =>
      ((payload['customSheet']['sheetControls'] as List).single['items']
              as List)
          .single['dValue'] as double;

  testWidgets('renders nothing off Android', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(buildSubject(config: buildConfig()));
    await tester.pumpAndSettle();

    expect(find.byType(ElevatedButton), findsNothing);
    expect(nativeCalls, isEmpty);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('opens the sheet straight away when there is no hook',
      (tester) async {
    await asAndroid(() async {
      await pumpReady(
          tester, buildSubject(config: buildConfig(orderNumber: 'order-A')));

      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();
    });

    expect(sheetPayload()['orderNumber'], 'order-A');
    expect(sheetTotal(sheetPayload()), 100.0);
  });

  testWidgets('opens no sheet when the hook vetoes', (tester) async {
    final results = <dynamic>[];

    await asAndroid(() async {
      await pumpReady(
        tester,
        buildSubject(
          config: buildConfig(orderNumber: 'order-A'),
          onPaymentResult: results.add,
          onBeforePayment: () async => false,
        ),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();
    });

    expect(sheetCalls(), isEmpty);
    expect(results, isEmpty);
  });

  testWidgets('opens the sheet for the transaction that was tapped',
      (tester) async {
    // Only the callback used to be captured before the await. Amount, order
    // number, merchant config and API key were all read from the live widget
    // afterwards, so a rebuild during the hook turned an approval for one
    // order into a sheet — and a charge — for another.
    final gate = Completer<bool>();

    await asAndroid(() async {
      await pumpReady(
        tester,
        buildSubject(
          config: buildConfig(amount: 10000, orderNumber: 'order-A'),
          onBeforePayment: () => gate.future,
        ),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(sheetCalls(), isEmpty);

      // The host moves on to another order while the pre-charge work runs.
      await tester.pumpWidget(buildSubject(
        config: buildConfig(amount: 55555, orderNumber: 'order-B'),
        onBeforePayment: () => gate.future,
      ));
      await tester.pumpAndSettle();

      gate.complete(true);
      await tester.pumpAndSettle();
    });

    expect(sheetPayload()['orderNumber'], 'order-A');
    expect(sheetTotal(sheetPayload()), 100.0);
  });

  testWidgets('opens no sheet when the widget goes away during the hook',
      (tester) async {
    final gate = Completer<bool>();

    await asAndroid(() async {
      await pumpReady(
        tester,
        buildSubject(
          config: buildConfig(orderNumber: 'order-A'),
          onBeforePayment: () => gate.future,
        ),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pumpAndSettle();

      gate.complete(true);
      await tester.pumpAndSettle();
    });

    expect(sheetCalls(), isEmpty);
  });

  testWidgets('survives a readiness answer that lands after disposal',
      (tester) async {
    // The native readiness check is a channel round trip; a customer who
    // leaves before it answers used to get a setState() after dispose().
    await asAndroid(() async {
      await tester.pumpWidget(buildSubject(config: buildConfig()));
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pumpAndSettle();

      await reportReady();
      await tester.pumpAndSettle();
    });

    expect(tester.takeException(), isNull);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('ignores a second tap while the hook is still running',
      (tester) async {
    final gate = Completer<bool>();
    var runs = 0;

    await asAndroid(() async {
      await pumpReady(
        tester,
        buildSubject(
          config: buildConfig(orderNumber: 'order-A'),
          onBeforePayment: () {
            runs++;
            return gate.future;
          },
        ),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      gate.complete(true);
      await tester.pumpAndSettle();
    });

    expect(runs, 1);
    expect(sheetCalls(), hasLength(1));
  });
}
