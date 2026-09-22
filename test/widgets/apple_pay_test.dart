import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  PaymentConfig buildConfig({int amount = 123}) => PaymentConfig(
        publishableApiKey: 'pk_test_key',
        amount: amount,
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
            config: buildConfig(amount: amount),
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

  /// Delivers [method] on [channelName] and answers whether a handler took it.
  /// A channel nobody listens on replies with no envelope at all, which is what
  /// a dead button looks like from the native side.
  Future<bool> sendTo(String channelName, String method,
      [Object? arguments]) async {
    ByteData? envelope;

    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channelName,
      channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (data) => envelope = data,
    );

    return envelope != null;
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

    /// Runs [body] as iOS. The widget reads the platform on every build and
    /// again on dispose, so a test that pumps more than once has to keep the
    /// override in place for all of them.
    Future<void> asIos(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<void> pumpWithHook(
      WidgetTester tester,
      Future<bool> Function()? hook, {
      Function? onPaymentResult,
    }) async {
      mockNativeAvailability('ready');

      await asIos(() async {
        await tester.pumpWidget(buildSubject(
          onBeforePayment: hook,
          onPaymentResult: onPaymentResult,
        ));
        await tester.pumpAndSettle();
      });
    }

    String creationParams(WidgetTester tester, [Finder? view]) =>
        tester.widget<UiKitView>(view ?? find.byType(UiKitView)).creationParams
            as String;

    /// The channel the rendered view was told to answer on. A view created
    /// without a hook was given no name and talks on the shared one.
    String viewChannel(String params) =>
        (jsonDecode(params) as Map<String, dynamic>)['viewChannel']
            as String? ??
        channel.name;

    /// Asks [channelName] for approval the way the native view does, carrying
    /// [arguments] as the params the pressed view holds.
    Future<Object?> askForApproval(
        String channelName, Object? arguments) async {
      Object? reply;

      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channelName,
        channel.codec
            .encodeMethodCall(MethodCall('onBeforePayment', arguments)),
        (data) => reply = channel.codec.decodeEnvelope(data!),
      );

      return reply;
    }

    /// Records the bodies of every charge [body] sets off.
    Future<List<String>> chargesDuring(Future<void> Function() body) async {
      final bodies = <String>[];
      final client = MockClient((request) async {
        bodies.add(request.body);
        return http.Response(jsonEncode({'type': 'network_error'}), 400);
      });

      await http.runWithClient(body, () => client);
      return bodies;
    }

    /// Presses a rendered button the way its native view does: on the channel
    /// it was created with, echoing the params it holds.
    Future<Object?> pressFromNative(WidgetTester tester, [Finder? view]) {
      final params = creationParams(tester, view);
      return askForApproval(viewChannel(params), params);
    }

    testWidgets('sends the pre-hook creationParams when no hook is given',
        (tester) async {
      await pumpWithHook(tester, null);

      expect(creationParams(tester), unhookedNativeConfig);
    });

    testWidgets('names this widget\'s own channel when a hook is given',
        (tester) async {
      // Without this the native press presents the sheet immediately, so the
      // hook would never be consulted and a veto would charge anyway. The name
      // is what ties the press to this widget rather than to whichever one
      // registered last on the shared channel.
      await pumpWithHook(tester, () async => true);

      expect(
        creationParams(tester),
        matches(RegExp('^'
            '${RegExp.escape(unhookedNativeConfig.substring(0, unhookedNativeConfig.length - 1))}'
            r',"viewChannel":"flutter\.moyasar\.com/apple_pay/view/\d+"}$')),
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

      expect(await pressFromNative(tester), isTrue);
    });

    testWidgets('answers false when the hook vetoes', (tester) async {
      await pumpWithHook(tester, () async => false);

      expect(await pressFromNative(tester), isFalse);
    });

    testWidgets('answers false when the hook throws', (tester) async {
      await pumpWithHook(tester, () async => throw StateError('disk full'));

      expect(await pressFromNative(tester), isFalse);
    });

    testWidgets('answers true when no hook is given', (tester) async {
      // Defensive: a native view that asks anyway must not be left hanging,
      // which would be a button that never presents.
      await pumpWithHook(tester, null);

      expect(await pressFromNative(tester), isTrue);
    });

    testWidgets('vetoes a press from a view it no longer renders',
        (tester) async {
      // The pressed view presents the sheet from the params it was created
      // with. Params this widget no longer renders mean a rebuild moved it to
      // another transaction, so approving would charge the one on screen a
      // moment ago.
      var runs = 0;
      await pumpWithHook(tester, () async {
        runs++;
        return true;
      });

      final params = creationParams(tester);
      final stale = params.replaceAll('"1.23"', '"9.99"');

      expect(await askForApproval(viewChannel(params), stale), isFalse);
      expect(runs, 0);
    });

    testWidgets('vetoes a press that carries no params at all', (tester) async {
      await pumpWithHook(tester, () async => true);

      expect(
        await askForApproval(viewChannel(creationParams(tester)), null),
        isFalse,
      );
    });

    testWidgets('does not answer until the hook completes', (tester) async {
      // The whole point of the hook: the native side is still waiting, so the
      // sheet has not presented, while the host's pre-charge work is in flight.
      final gate = Completer<bool>();
      await pumpWithHook(tester, () => gate.future);

      final params = creationParams(tester);
      Object? reply;
      var answered = false;
      final pending = binding.defaultBinaryMessenger.handlePlatformMessage(
        viewChannel(params),
        channel.codec.encodeMethodCall(MethodCall('onBeforePayment', params)),
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

    testWidgets('vetoes an approval that lands after the widget is gone',
        (tester) async {
      // Clearing the method handler does not cancel an invocation already in
      // flight: without the mounted check the native side would present the
      // sheet over whatever screen replaced this one.
      final gate = Completer<bool>();
      mockNativeAvailability('ready');

      await asIos(() async {
        await tester
            .pumpWidget(buildSubject(onBeforePayment: () => gate.future));
        await tester.pumpAndSettle();

        final params = creationParams(tester);
        Object? reply;
        final pending = binding.defaultBinaryMessenger.handlePlatformMessage(
          viewChannel(params),
          channel.codec.encodeMethodCall(MethodCall('onBeforePayment', params)),
          (data) => reply = channel.codec.decodeEnvelope(data!),
        );

        await tester.pumpWidget(const MaterialApp(home: Scaffold()));
        await tester.pumpAndSettle();

        gate.complete(true);
        await pending;

        expect(reply, isFalse);
      });
    });

    testWidgets('does not run the hook for any other native call',
        (tester) async {
      var runs = 0;
      final results = <dynamic>[];

      await pumpWithHook(tester, () async {
        runs++;
        return true;
      }, onPaymentResult: results.add);

      await binding.defaultBinaryMessenger.handlePlatformMessage(
        viewChannel(creationParams(tester)),
        channel.codec.encodeMethodCall(const MethodCall('onApplePayError')),
        (_) {},
      );
      await tester.pumpAndSettle();

      // The error was delivered — so `runs` is zero because the hook is not
      // consulted, not because nothing arrived.
      expect(results.single, isA<PaymentCanceledError>());
      expect(runs, 0);
    });

    testWidgets('asks the widget that rendered the pressed button',
        (tester) async {
      // Both widgets are mounted at once. On the shared channel only the last
      // one to register is ever asked, so pressing the first would run the
      // second's pre-charge work and then present the first's sheet.
      mockNativeAvailability('ready');
      final asked = <String>[];

      Widget button(String name, int amount) => ApplePay(
            config: buildConfig(amount: amount),
            onPaymentResult: (_) {},
            onBeforePayment: () async {
              asked.add(name);
              return true;
            },
          );

      await asIos(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Column(
              children: [button('first', 1000), button('second', 2000)],
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(find.byType(UiKitView), findsNWidgets(2));

        expect(
          await pressFromNative(tester, find.byType(UiKitView).first),
          isTrue,
        );
        expect(asked, ['first']);

        expect(
          await pressFromNative(tester, find.byType(UiKitView).last),
          isTrue,
        );
        expect(asked, ['first', 'second']);
      });
    });

    testWidgets('keeps an earlier button alive when a later one is disposed',
        (tester) async {
      // Disposing a widget that held the shared channel's single handler left
      // every earlier button answered by nobody: a dead button, vetoed for
      // good, with no way back.
      mockNativeAvailability('ready');
      final asked = <String>[];

      Widget button(String name, int amount) => ApplePay(
            config: buildConfig(amount: amount),
            onPaymentResult: (_) {},
            onBeforePayment: () async {
              asked.add(name);
              return true;
            },
          );

      Widget tree({required bool bothMounted}) => MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  button('first', 1000),
                  if (bothMounted) button('second', 2000),
                ],
              ),
            ),
          );

      await asIos(() async {
        await tester.pumpWidget(tree(bothMounted: true));
        await tester.pumpAndSettle();

        await tester.pumpWidget(tree(bothMounted: false));
        await tester.pumpAndSettle();

        expect(find.byType(UiKitView), findsOneWidget);
        expect(await pressFromNative(tester), isTrue);
        expect(asked, ['first']);
      });
    });

    testWidgets('charges the transaction it approved, not a later rebuild',
        (tester) async {
      // The sheet can stay up for as long as the customer likes, and the
      // widget can be rebuilt onto another order while it is. The charge must
      // be the one the host approved and the customer authorized.
      final bodies = <String>[];
      final client = MockClient((request) async {
        bodies.add(request.body);
        return http.Response(jsonEncode({'type': 'network_error'}), 400);
      });

      mockNativeAvailability('ready');
      final results = <dynamic>[];

      await http.runWithClient(() async {
        await asIos(() async {
          await tester.pumpWidget(buildSubject(
            amount: 10000,
            onPaymentResult: results.add,
            onBeforePayment: () async => true,
          ));
          await tester.pumpAndSettle();

          final approvedChannel = viewChannel(creationParams(tester));
          expect(await pressFromNative(tester), isTrue);

          await tester.pumpWidget(buildSubject(
            amount: 55555,
            onPaymentResult: results.add,
            onBeforePayment: () async => true,
          ));
          await tester.pumpAndSettle();

          await binding.defaultBinaryMessenger.handlePlatformMessage(
            approvedChannel,
            channel.codec.encodeMethodCall(
                const MethodCall('onApplePayResult', {'token': 'tok_test'})),
            (_) {},
          );
          await tester.pumpAndSettle();
        });
      }, () => client);

      expect(bodies, hasLength(1));
      expect(jsonDecode(bodies.single)['amount'], 10000);
      expect(results.single, isA<NetworkError>());
    });

    testWidgets('charges the amount on the button once the hook is gone',
        (tester) async {
      // The snapshot belongs to the press it was taken for. A widget that loses
      // its hook presents natively with no Dart round trip, so the customer
      // sees the live amount — and must be charged that, not the one an earlier
      // press approved.
      final bodies = <String>[];
      final client = MockClient((request) async {
        bodies.add(request.body);
        return http.Response(jsonEncode({'type': 'network_error'}), 400);
      });

      mockNativeAvailability('ready');

      await http.runWithClient(() async {
        await asIos(() async {
          await tester.pumpWidget(
              buildSubject(amount: 10000, onBeforePayment: () async => true));
          await tester.pumpAndSettle();

          expect(await pressFromNative(tester), isTrue);

          await tester.pumpWidget(buildSubject(amount: 55555));
          await tester.pumpAndSettle();

          // The button really is on the hookless path: it shows 555.55 and was
          // given no channel of its own, so its press never reaches Dart.
          expect(creationParams(tester), contains('"paymentAmount":"555.55"'));
          expect(viewChannel(creationParams(tester)), channel.name);

          await sendFromNative('onApplePayResult', {'token': 'tok_test'});
          await tester.pumpAndSettle();
        });
      }, () => client);

      expect(bodies, hasLength(1));
      expect(jsonDecode(bodies.single)['amount'], 55555);
    });

    testWidgets('leaves a hookless sibling answered when another gains a hook',
        (tester) async {
      // The shared channel holds one handler and the last to register owns it.
      // Clearing it on the way to a private channel, without checking who
      // installed it, left the sibling's button silently dead: the sheet still
      // presents, the customer authorizes, and nothing charges.
      mockNativeAvailability('ready');
      final sibling = <dynamic>[];

      // Cached on purpose, so the rebuild below hands Flutter the identical
      // widget and it skips this one's didUpdateWidget. Rebuilding both in the
      // same frame hides the bug: the sibling re-registers straight away.
      final cachedSibling = ApplePay(
        config: buildConfig(amount: 2000),
        onPaymentResult: sibling.add,
      );

      Widget tree({required bool firstHasHook}) => MaterialApp(
            home: Scaffold(
              body: Column(children: [
                ApplePay(
                  config: buildConfig(amount: 1000),
                  onPaymentResult: (_) {},
                  onBeforePayment: firstHasHook ? (() async => true) : null,
                ),
                cachedSibling,
              ]),
            ),
          );

      await asIos(() async {
        await tester.pumpWidget(tree(firstHasHook: false));
        await tester.pumpAndSettle();

        await sendFromNative('onApplePayError', null);
        await tester.pumpAndSettle();
        expect(sibling, hasLength(1),
            reason: 'the sibling registered last, so it owns the handler');

        await tester.pumpWidget(tree(firstHasHook: true));
        await tester.pumpAndSettle();

        await sendFromNative('onApplePayError', null);
        await tester.pumpAndSettle();
      });

      expect(sibling, hasLength(2));
    });

    testWidgets('stops answering the shared channel once it has a hook',
        (tester) async {
      // A hooked widget left squatting on the shared channel would answer
      // hookless presses meant for another button.
      mockNativeAvailability('ready');
      final results = <dynamic>[];

      await asIos(() async {
        await tester.pumpWidget(buildSubject(onPaymentResult: results.add));
        await tester.pumpAndSettle();

        expect(await sendTo(channel.name, 'onApplePayError'), isTrue);
        expect(results, hasLength(1));

        await tester.pumpWidget(buildSubject(
          onPaymentResult: results.add,
          onBeforePayment: () async => true,
        ));
        await tester.pumpAndSettle();

        expect(await sendTo(channel.name, 'onApplePayError'), isFalse);
      });

      expect(results, hasLength(1));
    });

    testWidgets('stops answering its own channel once it is gone',
        (tester) async {
      // Disposal clears the per-view handler, so a press the native side left
      // in flight reaches nobody rather than running a departed widget's hook.
      var runs = 0;
      await pumpWithHook(tester, () async {
        runs++;
        return true;
      });

      final params = creationParams(tester);
      final ownChannel = viewChannel(params);

      await asIos(() async {
        await tester.pumpWidget(const MaterialApp(home: Scaffold()));
        await tester.pumpAndSettle();
      });

      expect(await sendTo(ownChannel, 'onBeforePayment', params), isFalse);
      expect(runs, 0);
    });

    testWidgets('reports to the listener that was there when the charge began',
        (tester) async {
      // Moyasar.pay awaits. A rebuild while the request is in flight must not
      // hand the outcome to a listener that never saw this payment start.
      final inFlight = Completer<void>();
      final release = Completer<void>();
      final client = MockClient((request) async {
        inFlight.complete();
        await release.future;
        return http.Response(jsonEncode({'type': 'network_error'}), 400);
      });

      mockNativeAvailability('ready');
      final atResult = <dynamic>[];
      final later = <dynamic>[];

      await http.runWithClient(() async {
        await asIos(() async {
          await tester.pumpWidget(buildSubject(onPaymentResult: atResult.add));
          await tester.pumpAndSettle();

          await sendFromNative('onApplePayResult', {'token': 'tok_test'});
          await inFlight.future;

          await tester.pumpWidget(buildSubject(onPaymentResult: later.add));
          await tester.pumpAndSettle();

          release.complete();
          await tester.pumpAndSettle();
        });
      }, () => client);

      expect(atResult.single, isA<NetworkError>());
      expect(later, isEmpty);
    });

    testWidgets('charges the button for a result it was never asked about',
        (tester) async {
      // An approval covers one presentation. A second result with no approval
      // behind it has no transaction to honour, so it charges what the button
      // is showing rather than one already settled.
      mockNativeAvailability('ready');

      final bodies = await chargesDuring(() async {
        await asIos(() async {
          await tester.pumpWidget(
              buildSubject(amount: 10000, onBeforePayment: () async => true));
          await tester.pumpAndSettle();

          final ownChannel = viewChannel(creationParams(tester));
          expect(await pressFromNative(tester), isTrue);
          await sendTo(ownChannel, 'onApplePayResult', {'token': 'tok_test'});
          await tester.pumpAndSettle();

          await tester.pumpWidget(
              buildSubject(amount: 55555, onBeforePayment: () async => true));
          await tester.pumpAndSettle();

          // The same widget, so the same private channel — but nothing was
          // approved this time.
          expect(viewChannel(creationParams(tester)), ownChannel);
          await sendTo(ownChannel, 'onApplePayResult', {'token': 'tok_test'});
          await tester.pumpAndSettle();
        });
      });

      expect(bodies.map((b) => jsonDecode(b)['amount']), [10000, 55555]);
    });

    testWidgets('leaves no approval behind when the press came in hookless',
        (tester) async {
      // A hookless view presents its own sheet, so the defensive answer it gets
      // if it asks anyway must not leave a config behind for a later hooked
      // result to charge.
      mockNativeAvailability('ready');

      final bodies = await chargesDuring(() async {
        await asIos(() async {
          await tester.pumpWidget(buildSubject(amount: 10000));
          await tester.pumpAndSettle();

          expect(await pressFromNative(tester), isTrue);

          await tester.pumpWidget(
              buildSubject(amount: 55555, onBeforePayment: () async => true));
          await tester.pumpAndSettle();

          await sendTo(viewChannel(creationParams(tester)), 'onApplePayResult',
              {'token': 'tok_test'});
          await tester.pumpAndSettle();
        });
      });

      expect(bodies.map((b) => jsonDecode(b)['amount']), [55555]);
    });
  });
}
