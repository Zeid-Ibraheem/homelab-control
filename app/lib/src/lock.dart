// Verrou de l'application : empreinte digitale, ou code du téléphone.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

abstract final class AppLock {
  static final _auth = LocalAuthentication();

  /// Renvoie null si le déverrouillage a réussi, sinon la raison de l'échec.
  static Future<String?> unlock() async {
    try {
      if (!await _auth.isDeviceSupported()) {
        return _noLock;
      }
      final ok = await _auth.authenticate(
        localizedReason: 'Déverrouiller Homelab',
        persistAcrossBackgrounding: true,
      );
      return ok ? null : 'Déverrouillage annulé.';
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout =>
          'Déverrouillage annulé.',
        LocalAuthExceptionCode.noCredentialsSet => _noLock,
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout =>
          "Trop d'essais : attends un peu, ou déverrouille d'abord le téléphone avec son code.",
        _ => 'Déverrouillage impossible : ${e.description ?? e.code.name}',
      };
    } on PlatformException catch (e) {
      return 'Déverrouillage impossible : ${e.message ?? e.code}';
    }
  }

  static const _noLock = "Configure d'abord un verrouillage d'écran (code ou empreinte) sur le téléphone.";
}

/// Écran affiché tant que l'application est verrouillée : rien d'autre n'est
/// chargé en mémoire avant le déverrouillage.
class LockScreen extends StatelessWidget {
  const LockScreen({super.key, required this.busy, this.error, required this.onUnlock});

  final bool busy;
  final String? error;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 16),
                Text('Homelab est verrouillé', style: theme.textTheme.titleLarge),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: busy ? null : onUnlock,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Déverrouiller'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
