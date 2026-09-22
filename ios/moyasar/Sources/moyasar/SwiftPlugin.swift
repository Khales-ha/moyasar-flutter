import Flutter
import PassKit
import UIKit

public class SwiftPlugin: NSObject, FlutterPlugin {
    
    let applePayChannelId = "flutter.moyasar.com/apple_pay"
    let applePayButtonId = "flutter.moyasar.com/apple_pay/button"
    let beforePaymentMethod = "onBeforePayment"
    
    private let applePayHandler: ApplePayPaymentHandler
    private let channel: FlutterMethodChannel
    private var isAwaitingBeforePayment = false
    
    init(flutterMessenger: FlutterBinaryMessenger) {
        self.channel = FlutterMethodChannel(name: applePayChannelId, binaryMessenger: flutterMessenger)
        self.applePayHandler = ApplePayPaymentHandler(channel: channel)
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftPlugin(flutterMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: instance.channel)
        
        let applePayViewFactory = ApplePayViewFactory(messenger: registrar.messenger(), delegate: instance)
        registrar.register(applePayViewFactory, withId: instance.applePayButtonId)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getApplePayAvailability":
            guard let args = call.arguments as? [String: Any],
                  let supportedNetworks = args["supportedNetworks"] as? [String] else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
                return
            }

            result(ApplePayAvailability.current(supportedNetworks: supportedNetworks).rawValue)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

extension SwiftPlugin: ApplePayButtonHandler {
    func onApplePayButtonPressed(applePayConfig: Any?, viewChannel: FlutterMethodChannel?) {
        guard let viewChannel = viewChannel else {
            applePayHandler.presentApplePay(applePayConfig: applePayConfig, replyChannel: channel)
            return
        }

        // Awaiting Dart opens a window the synchronous path never had, in which
        // a second press would stack a second sheet. `channel` is built with no
        // task queue, so its reply arrives on the platform thread — the same one
        // the button target runs on — and a plain flag is enough to serialize them.
        guard !isAwaitingBeforePayment else { return }
        isAwaitingBeforePayment = true

        // The config is echoed back so Dart can check the press came from the
        // view it is currently rendering, and not one left behind by a rebuild.
        viewChannel.invokeMethod(beforePaymentMethod, arguments: applePayConfig) { [weak self] approval in
            guard let self = self else { return }
            self.isAwaitingBeforePayment = false

            // Present only on an explicit `true`. A `false`, an error, a missing
            // handler and a malformed reply all veto the payment: the host's
            // pre-charge work did not complete, so the charge is not allowed.
            guard (approval as? Bool) == true else { return }

            self.applePayHandler.presentApplePay(applePayConfig: applePayConfig, replyChannel: viewChannel)
        }
    }

    func onApplePaySetupButtonPressed() {
        applePayHandler.openApplePaySetup()
    }
}
