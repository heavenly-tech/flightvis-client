import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/widgets/trail_length_chips.dart';

void main() {
  testWidgets('renders all 8 chips with Spanish copy, title, hint, keys, and semantics', (tester) async {
    final selections = <int?>[];

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: TrailLengthChips(
              selectedMinutes: null,
              onSelected: selections.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(FlightVisTestKeys.trailChips), findsOneWidget);
    expect(find.text('Estela en el mapa'), findsOneWidget);
    expect(
      find.text(
        'Cuántos minutos de tu recorrido se ven detrás de tu avión en el mapa del club.',
      ),
      findsOneWidget,
    );

    expect(find.byType(ChoiceChip), findsNWidgets(8));
    expect(find.text('Usar predeterminado del club'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    expect(find.text('2 min'), findsOneWidget);
    expect(find.text('5 min'), findsOneWidget);
    expect(find.text('10 min'), findsOneWidget);
    expect(find.text('15 min'), findsOneWidget);
    expect(find.text('30 min'), findsOneWidget);
    expect(find.text('Todo'), findsOneWidget);

    // Default chip is selected.
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(null))).selected,
      isTrue,
    );

    // Semantics label is present on chips.
    final handle = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('Estela en el mapa: Todo'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Estela en el mapa: No'),
      findsOneWidget,
    );
    handle.dispose();

    // Tap every chip and verify callback receives exact API values.
    await tester.tap(find.text('Todo'));
    await tester.tap(find.text('No'));
    await tester.tap(find.text('2 min'));
    await tester.tap(find.text('5 min'));
    await tester.tap(find.text('10 min'));
    await tester.tap(find.text('15 min'));
    await tester.tap(find.text('30 min'));
    await tester.tap(find.text('Usar predeterminado del club'));
    await tester.pump();

    expect(selections, [-1, 0, 2, 5, 10, 15, 30, null]);
  });

  testWidgets('shows club default in parentheses when known (5 min, No, Todo)', (tester) async {
    Future<void> pumpWithDefault(int? clubDefault) async {
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: Scaffold(
            body: TrailLengthChips(
              selectedMinutes: null,
              clubDefaultMinutes: clubDefault,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpWithDefault(5);
    expect(find.text('Usar predeterminado del club (5 min)'), findsOneWidget);

    await pumpWithDefault(0);
    expect(find.text('Usar predeterminado del club (No)'), findsOneWidget);

    await pumpWithDefault(-1);
    expect(find.text('Usar predeterminado del club (Todo)'), findsOneWidget);

    await pumpWithDefault(null);
    expect(find.text('Usar predeterminado del club'), findsOneWidget);
  });

  testWidgets('renders English copy when locale is en', (tester) async {
    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('en'),
        home: Scaffold(
          body: TrailLengthChips(
            selectedMinutes: 10,
            clubDefaultMinutes: 5,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Map trail'), findsOneWidget);
    expect(find.text('Use club default (5 min)'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(10))).selected,
      isTrue,
    );
  });
}
