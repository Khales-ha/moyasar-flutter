import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:moyasar/moyasar.dart';
import 'package:moyasar/src/models/apple_pay_availability.dart';
import 'package:moyasar/src/utils/before_payment_hook.dart';
import 'dart:convert';

/// The widget that shows the Apple Pay button.
///
/// The button hides itself on non-iOS platforms and on devices that can't use
/// Apple Pay, so apps don't need to guard it with their own platform check.
///
/// A user with no card in Wallet still sees the normal payment button: since
/// iOS 15 they can add one from inside the payment sheet. On iOS 14 and below
/// the sheet can't do that, so the widget shows Apple's "Set Up Apple Pay"
/// button instead, which opens Wallet; it switches back to the payment button
/// once the user returns.
class ApplePay extends StatefulWidget {
  ApplePay(
      {super.key,
      required this.config,
      required this.onPaymentResult,
      this.buttonType = ApplePayButtonType.inStore,
      this.buttonStyle = ApplePayButtonStyle.black,
      this.onBeforePayment})
      : assert(config.applePay != null,
            "Please add applePayConfig when instantiating the paymentConfig.");

  final PaymentConfig config;
  final Function onPaymentResult;

  /// Runs after the button is pressed and before the Apple Pay sheet is
  /// presented, so the app can finish pre-charge work — persisting an
  /// idempotency record, for instance — while nothing has been charged yet.
  ///
  /// The native side waits for this future: the sheet is presented only once
  /// it completes `true`. Completing `false` or throwing **vetoes** the
  /// payment — no sheet, and no [onPaymentResult] call, since the app that
  /// vetoed already knows why.
  ///
  /// Keep it short. It sits between the user's tap and Apple's sheet.
  ///
  /// When it is null the button presents the sheet natively, exactly as it
  /// did before this callback existed.
  final Future<bool> Function()? onBeforePayment;

  /// The wording Apple shows on the button, e.g. "Buy with Apple Pay" for
  /// [ApplePayButtonType.buy]. Pick the one that matches the action the user
  /// is completing. Defaults to [ApplePayButtonType.inStore].
  final ApplePayButtonType buttonType;

  /// The button's color scheme. Use [ApplePayButtonStyle.automatic] to follow
  /// the system light/dark appearance. Defaults to [ApplePayButtonStyle.black].
  final ApplePayButtonStyle buttonStyle;
  final MethodChannel channel =
      const MethodChannel('flutter.moyasar.com/apple_pay');

  @override
  State<ApplePay> createState() => _ApplePayState();
}

class _ApplePayState extends State<ApplePay> with WidgetsBindingObserver {
  static const String _applePayButtonViewNativeId =
      "flutter.moyasar.com/apple_pay/button";

  static const String _beforePaymentMethod = "onBeforePayment";

  /// Names each widget's own channel apart. Only ever increases, so a name is
  /// never handed out twice and a press left in flight by a disposed widget
  /// cannot reach a later one.
  static int _nextViewChannelId = 0;

  /// The channel this widget alone answers on, whose name the native view is
  /// given in its `creationParams`. The shared plugin channel holds a single
  /// handler, so with more than one button mounted the last one to register
  /// there answers every press and every result, and its disposal clears the
  /// handler out from under the others.
  late final MethodChannel _viewChannel = MethodChannel(
      'flutter.moyasar.com/apple_pay/view/${_nextViewChannelId++}');

  /// Whether this widget installed the handler currently on the shared
  /// channel. It may only clear a handler it installed itself.
  bool _listensOnSharedChannel = false;

  /// The config that was on screen when this widget approved the press the
  /// native side is presenting, so the charge is for the transaction the host
  /// approved rather than whatever a later rebuild left behind.
  PaymentConfig? _approvedConfig;

  /// `null` while the native readiness check is still in flight.
  ApplePayAvailability? _availability;

  bool get _isRunningOnIos => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();

    // Apple Pay only exists on iOS. Bail out before touching the channel so the
    // widget is inert on other platforms instead of relying on the host app to
    // wrap it in a platform check.
    if (!_isRunningOnIos) {
      return;
    }

    _syncMethodCallHandler();
    WidgetsBinding.instance.addObserver(this);
    _refreshAvailability();
  }

  @override
  void didUpdateWidget(covariant ApplePay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!_isRunningOnIos) {
      return;
    }

    // Adding or removing the hook moves this widget between the shared channel
    // and its own.
    _syncMethodCallHandler();

    // Readiness is decided from the accepted networks, so it has to be
    // re-checked when they change.
    if (!listEquals(
        oldWidget.config.supportedNetworks, widget.config.supportedNetworks)) {
      _refreshAvailability();
    }
  }

  @override
  void dispose() {
    if (_isRunningOnIos) {
      WidgetsBinding.instance.removeObserver(this);
      _viewChannel.setMethodCallHandler(null);

      if (_listensOnSharedChannel) {
        widget.channel.setMethodCallHandler(null);
      }
    }

    super.dispose();
  }

  /// Points this widget's handler at the channel the native side will use for
  /// it: its own when there is a hook, the shared plugin channel otherwise,
  /// which is the path a hookless widget has always taken.
  void _syncMethodCallHandler() {
    if (widget.onBeforePayment != null) {
      _viewChannel.setMethodCallHandler(_handleNativeCall);

      if (_listensOnSharedChannel) {
        widget.channel.setMethodCallHandler(null);
        _listensOnSharedChannel = false;
      }

      return;
    }

    _viewChannel.setMethodCallHandler(null);
    widget.channel.setMethodCallHandler(_handleNativeCall);
    _listensOnSharedChannel = true;
  }

  /// Re-checks readiness whenever the app is foregrounded, so the button
  /// updates after the user adds a card in Wallet and comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAvailability();
    }
  }

  Future<void> _refreshAvailability() async {
    ApplePayAvailability availability;

    try {
      final name =
          await widget.channel.invokeMethod<String>("getApplePayAvailability", {
        "supportedNetworks":
            widget.config.supportedNetworks.map((e) => e.toJson()).toList()
      });

      // An unrecognized response shouldn't hide a button that may well work, so
      // fall back to showing the normal payment button.
      availability =
          ApplePayAvailability.fromName(name) ?? ApplePayAvailability.ready;
    } catch (error) {
      debugPrint("Apple Pay availability check failed: $error");
      availability = ApplePayAvailability.ready;
    }

    if (!mounted || availability == _availability) {
      return;
    }

    setState(() {
      _availability = availability;
    });
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onApplePayResult') {
      final arguments = call.arguments;

      // Values decoded by the standard codec arrive as `Map<Object?, Object?>`.
      // Anything else means the payload is malformed; report it rather than
      // throwing, which would leave the payment with no response at all.
      if (arguments is! Map) {
        widget.onPaymentResult(UnprocessableTokenError());
        return null;
      }

      onApplePayResult(Map<String, dynamic>.from(arguments));
    } else if (call.method == 'onApplePayError') {
      onApplePayError();
    } else if (call.method == _beforePaymentMethod) {
      // Returned, not awaited-and-dropped: the native side blocks the sheet on
      // this reply.
      return _approveBeforePayment(call.arguments);
    }

    return null;
  }

  /// Answers whether the sheet may be presented for the press that carried
  /// [pressedNativeConfig] — the `creationParams` of the view that was pressed.
  Future<bool> _approveBeforePayment(Object? pressedNativeConfig) async {
    // The native view presents the sheet from the params it was created with,
    // so a press carrying anything else came from a button showing a
    // transaction this widget no longer renders.
    if (pressedNativeConfig != createCustomNativeConfig()) {
      return false;
    }

    final pressedConfig = widget.config;
    final approved = await runBeforePaymentHook(widget.onBeforePayment);

    // Clearing the handler does not cancel an invocation already in flight, so
    // without this an approval landing after the customer navigated away would
    // present the sheet over whatever replaced this widget.
    if (!approved || !mounted) {
      return false;
    }

    _approvedConfig = pressedConfig;
    return true;
  }

  void onApplePayError() {
    widget.onPaymentResult(PaymentCanceledError());
  }

  void onApplePayResult(Map<String, dynamic> paymentResult) async {
    // Read before the charge, which awaits: a rebuild during the sheet or the
    // request would otherwise move the charge onto a different transaction and
    // report it to a different listener.
    final onPaymentResult = widget.onPaymentResult;
    final config = _approvedConfig ?? widget.config;
    final token = paymentResult['token'];

    if (((token ?? '') == '')) {
      onPaymentResult(UnprocessableTokenError());
      return;
    }

    final source = ApplePayPaymentRequestSource(
        token, config.applePay!.manual, config.applePay!.saveCard);
    final paymentRequest = PaymentRequest(config, source);

    final result = await Moyasar.pay(
        apiKey: config.publishableApiKey, paymentRequest: paymentRequest);

    onPaymentResult(result);
  }

  String createCustomNativeConfig() {
    return jsonEncode({
      "merchantIdentifier": "${widget.config.applePay?.merchantId}",
      "paymentLabel": "${widget.config.applePay?.label}",
      "merchantCapabilities": widget.config.applePay?.merchantCapabilities,
      "supportedCountries": widget.config.applePay?.supportedCountries,
      "supportedNetworks":
          widget.config.supportedNetworks.map((e) => e.toJson()).toList(),
      "countryCode": "SA",
      "currencyCode": "SAR",
      "paymentAmount": (widget.config.amount / 100).toStringAsFixed(2),
      "buttonType": widget.buttonType.name,
      "buttonStyle": widget.buttonStyle.name,
      // Only emitted when there is a hook, so a caller that passes none sends
      // the same params as before and keeps the straight-to-sheet press. Its
      // presence is also what tells the native side to ask this widget — and
      // not whichever one registered last on the shared channel — and to
      // deliver that press's result back on the same channel. The view's key
      // is derived from this JSON, so adding or removing the hook rebuilds the
      // native view rather than leaving it on the wrong path.
      if (widget.onBeforePayment != null) "viewChannel": _viewChannel.name,
    });
  }

  @override
  Widget build(BuildContext context) {
    final availability = _availability;

    // Render nothing off iOS, while the check is still running, and on devices
    // that can't use Apple Pay at all.
    if (!_isRunningOnIos ||
        availability == null ||
        availability == ApplePayAvailability.notSupported) {
      return const SizedBox.shrink();
    }

    final nativeConfig = createCustomNativeConfig();

    return ConstrainedBox(
      constraints: BoxConstraints.tightFor(
        width: MediaQuery.of(context).size.width,
        height: 40,
      ),
      child: UiKitView(
        // A native view reads `creationParams` once, when it is created, and
        // Flutter only recreates it when the key changes. Keying on the config
        // itself means any change the native side depends on — the amount above
        // all — produces a fresh view instead of a button holding stale data.
        key: ValueKey('${availability.name}|$nativeConfig'),
        viewType: _applePayButtonViewNativeId,
        creationParamsCodec: const StandardMessageCodec(),
        creationParams: nativeConfig,
      ),
    );
  }
}
