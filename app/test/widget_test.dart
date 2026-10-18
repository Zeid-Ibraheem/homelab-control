import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homelab_control/src/lock.dart';

void main() {
  testWidgets("écran de verrouillage : message et bouton", (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: LockScreen(busy: false, error: 'Déverrouillage annulé.', onUnlock: () => taps++),
    ));
    expect(find.text('Homelab est verrouillé'), findsOneWidget);
    expect(find.text('Déverrouillage annulé.'), findsOneWidget);
    await tester.tap(find.text('Déverrouiller'));
    expect(taps, 1);
  });

  testWidgets('bouton inactif pendant le déverrouillage', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: LockScreen(busy: true, onUnlock: () => taps++),
    ));
    await tester.tap(find.text('Déverrouiller'));
    expect(taps, 0);
  });
}
