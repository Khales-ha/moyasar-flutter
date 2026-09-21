import 'package:flutter/foundation.dart';

/// Runs a wallet widget's pre-charge hook and answers whether the payment may
/// proceed.
///
/// Shared by both wallets so the veto rule is one implementation: the payment
/// proceeds **only** on an explicit `true`. A `false` and a thrown error both
/// veto it — a host whose pre-charge work did not complete has not agreed to
/// the charge. A `null` [hook] means there is nothing to wait for, so the
/// widget keeps its unhooked behaviour.
Future<bool> runBeforePaymentHook(Future<bool> Function()? hook) async {
  if (hook == null) {
    return true;
  }

  try {
    return await hook();
  } catch (error) {
    debugPrint('onBeforePayment failed, so the payment was vetoed: $error');
    return false;
  }
}
