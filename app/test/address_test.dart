import 'package:flutter_test/flutter_test.dart';
import 'package:homelab_control/src/ssh_link.dart';

void main() {
  test('une ou deux adresses de la tour', () {
    expect(parseAddresses('10.0.0.2'), ['10.0.0.2']);
    expect(parseAddresses('10.0.0.2 ma-tour'), ['10.0.0.2', 'ma-tour']);
    expect(parseAddresses(' 10.0.0.2,  ma-tour '), ['10.0.0.2', 'ma-tour']);
    expect(parseAddresses('10.0.0.2, ma-tour.exemple.ts.net'), ['10.0.0.2', 'ma-tour.exemple.ts.net']);
  });

  test('saisies refusées', () {
    expect(parseAddresses(''), isNull);
    expect(parseAddresses('   '), isNull);
    expect(parseAddresses('a b c'), isNull); // trois adresses
    expect(parseAddresses('10.0.0.2;rm'), isNull);
    expect(parseAddresses('ma tour!'), isNull);
  });
}
