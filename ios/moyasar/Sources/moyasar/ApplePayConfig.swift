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

    /// Name of the channel belonging to the one Dart widget that rendered this
    /// button. Sent only when the host passed an `onBeforePayment` callback, so
    /// its absence means the press goes straight to the sheet and the result
    /// goes back on the plugin's shared channel, as it always has.
    ///
    /// When it is present both the hook and that press's result travel on it,
    /// which is what keeps a press tied to the widget that was pressed: the
    /// shared channel has a single handler, so with more than one button
    /// mounted it would answer only the widget that registered last.
    let viewChannel: String?
}
