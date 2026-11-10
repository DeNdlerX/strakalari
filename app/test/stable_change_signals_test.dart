import 'package:app/features/timetable/timetable_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of the UI test cases from `tests/test_stable_change_signals.py`.

Map<String, List<Map<String, Object?>>> _swappedSlot() => {
      '02.09.2026': [
        {
          'subject': 'Informatika a výpočetní technika',
          'teacher': 'Sixta Roman',
          'room': 'IVT2',
          'time': '5 (11:55 - 12:40)',
          'date': '02.09.2026',
          'notice': 'Přesun z  2.9., 14:30: IVT, Sixta Roman, IVT2',
          'changeinfo': 'Přesun z  2.9., 14:30: IVT, Sixta Roman, IVT2',
          'infoChangeCode': 'Added',
          'changeBadgeChar': 'N',
        },
        {
          'subject': 'Tv',
          'subject_short': 'Tv',
          'teacher': 'Neumannová Adéla',
          'room': '',
          'time': '11:55 - 12:40',
          'date': '02.09.2026',
          'notice': 'Zrušeno (Tv, Neumannová Adéla)',
          'removedinfo': 'Zrušeno (Tv, Neumannová Adéla)',
          'status': 'cancelled',
          'type': 'removed',
          'hourIndex': 7,
        },
      ],
    };

List<Map<String, Object?>> _mondayWithCancelledNj() {
  Map<String, Object?> atom(
    int period,
    String clock,
    String subject, {
    Map<String, Object?> extra = const {},
  }) =>
      {
        'subject': subject,
        'teacher': 'T',
        'room': 'VIII',
        'time': '$period ($clock)',
        'period': period,
        'infoChangeCode': 'NoChange',
        'absenceType': 'NoAbsent',
        ...extra,
      };

  return [
    atom(1, '8:00 - 8:45', 'Seminář z matematiky S'),
    atom(
      4,
      '11:00 - 11:45',
      'Anglický jazyk',
      extra: {
        'infoChangeCode': 'RoomChanged',
        'changeinfo': 'Změna místnosti: VIII (Hv)',
        'notice': 'Změna místnosti: VIII (Hv)',
      },
    ),
    atom(6, '12:50 - 13:35', 'Český jazyk a literatura'),
    atom(
      8,
      '14:30 - 15:15',
      'Maturita Preparation in Conversational E',
      extra: {'absenceType': 'Absent'},
    ),
    {
      'subject': 'Německý jazyk',
      'teacher': 'Odcházelová Kateřina',
      'room': 'VIII',
      'time': '13:40 - 14:25',
      'period': 7,
      'notice': 'Zrušeno (Nj, Odcházelová Kateřina)',
      'removedinfo': 'Zrušeno (Nj, Odcházelová Kateřina)',
      'type': 'removed',
      'status': 'cancelled',
    },
  ];
}

void main() {
  final c = TimetableController();

  test('listViewOrdersCancelledRowIntoItsPeriod', () {
    final day = DateTime(2026, 10, 5);
    final rows = List<Map<String, Object?>>.from(_mondayWithCancelledNj())
      ..sort((a, b) => c.listOrderKey(a, day).compareTo(c.listOrderKey(b, day)));

    expect(
      [for (final r in rows) r['period']],
      [1, 4, 6, 7, 8],
    );

    // Swapped slot: the taught lesson first, the cancelled original after it.
    final swappedDay = DateTime(2026, 9, 2);
    final swappedList =
        List<Map<String, Object?>>.from(_swappedSlot()['02.09.2026']!.reversed)
          ..sort((a, b) => c.listOrderKey(a, swappedDay).compareTo(c.listOrderKey(b, swappedDay)));

    expect(Lesson.fromLegacy(swappedList[0]).status, '');
    // The day's lesson count leaves the cancelled one out.
    expect(c.taught(_mondayWithCancelledNj()), hasLength(4));
  });

  test('cancelledLessonIsNeverRunningOrAhead', () {
    final day = _mondayWithCancelledNj();
    final duringNj = resolveDayLessons(
      day,
      DateTime(2026, 10, 5, 13, 50),
      '05.10.2026',
    );
    expect(duringNj['phase'], 'between');
    final upcoming = duringNj['upcoming'] as Map<Object?, Object?>?;
    expect('${upcoming?['subject']}'.startsWith('Maturita'), isTrue);

    // Only the cancelled Nj and Maturita are left at 13:36: one to skip.
    expect(
      futureLessons(day, DateTime(2026, 10, 5, 13, 36), '05.10.2026'),
      hasLength(1),
    );
  });

  test('gridCellShowsTaughtLessonOfSwappedSlot', () {
    final slot = _swappedSlot()['02.09.2026']!;
    for (final rows in [slot, slot.reversed.toList()]) {
      final cell = c.combinedCell(rows);
      expect(cell?['subject'], 'Informatika a výpočetní technika');
      expect(Lesson.fromLegacy(cell!).status, '');
    }
    // Nothing replaced it: the cancelled lesson still shows.
    final removed = slot[1];
    expect(Lesson.fromLegacy(c.combinedCell([removed])!).status, 'cancelled');
  });
}
