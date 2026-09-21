public struct ApplePayConfig: Codable {
    let merchantIdentifier: String
    let paymentLabel: String
    let merchantCapabilities: [String]
    let supportedNetworks: [String]
    let countryCode: String
    let currencyCode: String
    let paymentAmount: String
    let buttonType: String?
    let buttonStyle: String?

    /// Sent by the Dart widget only when the host passed an `onBeforePayment`
    /// callback, so its absence means the press goes straight to the sheet.
    let hasBeforePaymentHook: Bool?
}
