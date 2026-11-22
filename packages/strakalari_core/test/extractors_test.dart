import 'dart:convert';

import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/extractors.dart';

String mark(String subject, String grade, Object? weight, String date) {
  final blob = jsonEncode({
    'nazev': subject,
    'MarkText': grade,
    'vaha': weight,
    'udel_datum': date,
  });
  final esc = blob
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
  return '<div data-clasif="$esc"></div>';
}

String subjectRow(String rowId, String subject, String quarterly,
    {String note = ''}) {
  final name = subject
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('ý', '&#253;')
      .replaceAll(' ', '&#160;');
  return '<div id="$rowId" class="predmet-radek" '
      'data-testid="subjectview-subject-row">\r\n'
      '<div class="leva"><div class="obal _subject_detail link">'
      '<h3 title="$name">$name</h3></div>\r\n'
      '<div class="hlavni">\r\n'
      '    <div title=\'Čtvrtlet&#237; (prozat&#237;mn&#237; v&#253;sledn&#225; '
      'zn&#225;mka)\'>$quarterly</div>\r\n</div>\r\n'
      '<div class="dalsi-dva"><div class="modra-z" '
      'title="vážený průměr za pololetí">'
      '</div></div></div></div>\r\n'
      '<div class=\'vyjeddetail vyjeddetail_$rowId\'>'
      '<div class="bk-section-title"><span>Pozn&#225;mka ke čtvrtletn&#237; '
      'zn&#225;mce'
      '</span></div><span data-testid="subjectview-grade-details-note">'
      '$note</span></div>';
}

Map<String, Object?> excuseDetail(String dayFrom,
    [String? dayTo,
    (int, int)? hours,
    (String, String) times = ('', '')]) {
  final detail = <String, Object?>{
    'Kind': 'OMLUVENKA',
    'DateFrom': dayFrom,
    'DateTo': dayTo ?? dayFrom,
    'TimeFrom': times.$1,
    'TimeTo': times.$2,
  };
  if (hours != null) {
    detail['HourFrom'] = {'Caption': '${hours.$1}'};
    detail['HourTo'] = {'Caption': '${hours.$2}'};
  }
  return detail;
}

void main() {
  group('extractGrades', () {
    test('emptyAndNoneInput', () {
      expect(extractGrades(''), isEmpty);
      expect(extractGrades(null), isEmpty);
    });

    test('groupsBySubject', () {
      final html =
          mark('Matematika', '1', 10, '5.9.2026') + mark('Fyzika', '2', 5, '6.9.2026');
      final data = extractGrades(html);
      expect(data.keys.toSet(), {'Matematika', 'Fyzika'});
      expect(data['Matematika'],
          [{'Grade': '1', 'Weight': 10, 'Date': '5.9.2026'}]);
      expect(data['Fyzika'],
          [{'Grade': '2', 'Weight': 5, 'Date': '6.9.2026'}]);
    });

    test('sortsEachSubjectByDate', () {
      // Page groups by subject but leaves dates unordered — output must
      // be oldest-first per subject.
      final html = mark('Matematika', '3', 10, '12.09.2026') +
          mark('Matematika', '1', 10, '05.09.2026') +
          mark('Matematika', '2', 5, '08.09.2026');
      final dates = [
        for (final m in extractGrades(html)['Matematika']!) m['Date']
      ];
      expect(dates, ['05.09.2026', '08.09.2026', '12.09.2026']);
    });

    test('skipsMalformedAndIncomplete', () {
      final html = '<div data-clasif="{not json}"></div>'
          '<div data-clasif="{&quot;MarkText&quot;: &quot;1&quot;}"></div>'
          '<div data-clasif="{&quot;nazev&quot;: &quot;Chemie&quot;}"></div>'
          "${mark('Biologie', '1', 8, '1.9.2026')}";
      final data = extractGrades(html);
      expect(data, {
        'Biologie': [
          {'Grade': '1', 'Weight': 8, 'Date': '1.9.2026'}
        ]
      });
    });

    test('unparseableDatesSortLast', () {
      final html =
          mark('Dějepis', '2', 5, '???') + mark('Dějepis', '1', 5, '1.9.2026');
      final dates = [
        for (final m in extractGrades(html)['Dějepis']!) m['Date']
      ];
      expect(dates, ['1.9.2026', '???']);
    });

    test('optionalDetailsKeptWhenPresent', () {
      final blob = jsonEncode({
        'nazev': 'Finanční gramotnost',
        'MarkText': '?',
        'vaha': 2,
        'udel_datum': '13.9.2026',
        'strdatum': '15.1.2027',
        'id': 'BNXS=6=2=V',
        'caption': 'pololetní test',
        'poznamkakzobrazeni': '',
        'IsNew': true,
        'PointsText': '',
        'MarkTooltip': 'plánovaná klasifikace'
      });
      final esc = blob.replaceAll('"', '&quot;');
      final html = '<div data-clasif="$esc"></div>';
      final found = extractGrades(html)['Finanční gramotnost']![0];
      expect(found, {
        'Grade': '?',
        'Weight': 2,
        'Date': '13.9.2026',
        'Id': 'BNXS=6=2=V',
        'Caption': 'pololetní test',
        'TestDate': '15.1.2027',
        'New': true,
        'Planned': true,
      });
    });

    test('nestedBracesAndBraceInString', () {
      final blob = jsonEncode({
        'nazev': 'Matematika',
        'MarkText': '1',
        'vaha': 10,
        'udel_datum': '5.9.2026',
        'extra': {'note': 'a}b'}
      });
      final esc = blob.replaceAll('"', '&quot;');
      final html = '<div data-clasif="$esc"></div>';
      final data = extractGrades(html);
      expect(data['Matematika'],
          [{'Grade': '1', 'Weight': 10, 'Date': '5.9.2026'}]);
    });
  });

  group('extractQuarterlyMarks', () {
    test('readsQuarterlyMarks', () {
      final html = subjectRow('70', 'Český jazyk a literatura', '3') +
          subjectRow('4Q', 'Finanční gramotnost', ' ') +
          subjectRow('10', 'Matematika', '1', note: 'Za aktivitu') +
          subjectRow('63', 'Seminář z matematiky S', '2');
      expect(extractQuarterlyMarks(html), {
        'Český jazyk a literatura': {'Grade': '3'},
        'Matematika': {'Grade': '1', 'Note': 'Za aktivitu'},
        // Same key as the marks' nazev, no-break space included.
        'Seminář z matematiky S': {'Grade': '2'},
      });
      expect(extractQuarterlyMarks(''), isEmpty);
      expect(extractQuarterlyMarks(null), isEmpty);
    });
  });

  group('sentExcuseEntries', () {
    test('lessonsYieldEveryHourShape', () {
      // One hour-based web excuse dedupes against every local shape.
      expect(
          sentExcuseEntries(
              excuseDetail('3.9.2026', null, (3, 3), ('10:05', '10:50'))),
          [
            for (final t in ['income', 'soon', 'days and hours'])
              {
                'type': t,
                'starting_day': '03.09.2026',
                'ending_day': '03.09.2026',
                'starting_lesson': 3,
                'ending_lesson': 3,
              }
          ]);
    });

    test('wholeDays', () {
      expect(sentExcuseEntries(excuseDetail('25.9.2026', '26.9.2026')),
          [
            {
              'type': 'pure days',
              'starting_day': '25.09.2026',
              'ending_day': '26.09.2026',
            }
          ]);
    });

    test('clockTimesWithoutLessonsLearnNothing', () {
      // Unknown lessons must never be recorded as a whole excused day.
      expect(
          sentExcuseEntries(
              excuseDetail('3.9.2026', null, null, ('10:05', '10:50'))),
          isEmpty);
    });

    test('otherMessagesAndGarbageLearnNothing', () {
      expect(
          sentExcuseEntries(
              {...excuseDetail('3.9.2026'), 'Kind': 'OBECNA'}),
          isEmpty);
      expect(
          sentExcuseEntries(
              {'Kind': 'OMLUVENKA', 'DateFrom': 'nikdy'}),
          isEmpty);
      expect(sentExcuseEntries(null), isEmpty);
    });

    test('webHourExcuseDedupesSoon', () {
      final detail = {
        'Kind': 'OMLUVENKA',
        'DateFrom': '10.9.2026',
        'DateTo': '10.9.2026',
        'TimeFrom': '08:55',
        'TimeTo': '09:40',
        'HourFrom': {'Caption': '2'},
        'HourTo': {'Caption': '2'},
      };
      final result = sentExcuseEntries(detail);
      expect(result.map((e) => e['type']).toList(),
          ['income', 'soon', 'days and hours']);
      expect(result[1], {
        'type': 'soon',
        'starting_day': '10.09.2026',
        'ending_day': '10.09.2026',
        'starting_lesson': 2,
        'ending_lesson': 2,
      });
    });
  });

  group('absenceFromSubjects', () {
    test('parsesFractionsFiltersSummaryKeepsMax', () {
      final rows = [
        {
          'Name': 'Matematika',
          'LessonCount': 100,
          'Count': 12,
          'Percent': 0.12,
        },
        {
          'Name': 'Celkem',
          'LessonCount': 500,
          'Count': 60,
          'Percent': 0.12,
        },
        {
          'Name': 'Fyzika',
          'LessonCount': 80,
          'Count': 20,
          'Percent': 0.25,
        },
        {
          'Name': 'Fyzika',
          'LessonCount': 80,
          'Count': 8,
          'Percent': 0.1,
        },
        {'Name': '', 'Percent': 0.5},
      ];
      final (percentages, details) = absenceFromSubjects(rows);
      expect(percentages, {'Matematika': 12.0, 'Fyzika': 25.0});
      expect(details['Matematika'], {
        'percent': 12.0,
        'total_hours': 100.0,
        'missed_hours': 12.0,
        'approaching': false,
        'unclassifiable': false,
      });
      expect(details['Fyzika']!['percent'], 25.0);
    });

    test('garbageRowsNeverRaise', () {
      expect(absenceFromSubjects(null).$1, isEmpty);
      expect(absenceFromSubjects('garbage').$1, isEmpty);
      expect(absenceFromSubjects([null, 'x']).$1, isEmpty);
    });
  });

  group('subjectDirectoryFromRows', () {
    test('mapsSubjectToTeacher', () {
      expect(
          subjectDirectoryFromRows([
            {
              'SubjectName': 'Matematika',
              'TeacherName': 'Mgr. Jan Novák',
            },
            {'SubjectName': '', 'TeacherName': 'X'},
          ]),
          {'Matematika': 'Mgr. Jan Novák'});
      expect(subjectDirectoryFromRows(null), isEmpty);
    });
  });

  group('timetableDetails', () {
    test('unwrapsAtomsSkipsGarbage', () {
      final Map<String, Object?> content = {
        'Days': [
          {
            'Hours': [
              {
                'Atoms': [
                  {'TooltipDetails': '{"teacher": "T"}'},
                  {'TooltipDetails': '{broken'},
                  <String, Object?>{},
                ]
              },
              <String, Object?>{},
            ]
          },
          <String, Object?>{},
        ]
      };
      expect(timetableDetails(content), [
        {'teacher': 'T'}
      ]);
      expect(timetableDetails(null), isEmpty);
      expect(timetableDetails('garbage'), isEmpty);
    });
  });

  group('absenceDateRange', () {
    test('readsDefaultsFromPage', () {
      final html = 'DatesInformations = ko.mapping.fromJS('
          '{"DefaultDateFrom": {"DefaultValue": "01.09.2026"}, '
          '"DefaultDateTo": {"DefaultValue": "30.09.2026"}});';
      expect(absenceDateRange(html), ('01.09.2026', '30.09.2026'));
      expect(absenceDateRange('<html></html>'), isNull);
      expect(absenceDateRange(null), isNull);
    });
  });

  group('substitutionsFromWeeks', () {
    Map<String, Object?> change(String day, String hour, String time,
            String kind, String subject, String description) => {
          'Day': day,
          'HourLabel': hour,
          'TimeLabel': time,
          'ChangeType': kind,
          'Description': description,
          'ChangeLessonInfo': {
            'ClassAbbrev': '8.1',
            'IsClassGroup': true,
            'SubjectAbbrev': subject,
            'RoomAbbrev': 'VIII',
          }
        };

    test('readsBadgesAndDays', () {
      final entries = substitutionsFromWeeks([
        {
          'Title': '',
          'Changes': [
            change('čtvrtek 17.9.2026', '3', '10:05 - 10:50', 'RoomChanged',
                'M', 'Změna místnosti: VIII'),
            change('pátek 18.9.2026', '7', '13:40 - 14:25', 'Canceled', 'FG',
                'Zrušeno'),
          ]
        }
      ]);
      expect(entries, hasLength(2));
      expect(entries[0], {
        'day': '17.9.2026',
        'period': 3,
        'time': '10:05 - 10:50',
        'badge': 'M',
        'info': '8.1 | M | VIII',
        'subject_short': 'M',
        'description': 'Změna místnosti: VIII',
      });
      expect(entries[1]['badge'], 'O');
      expect(entries[1]['day'], '18.9.2026');
      expect(entries[1]['period'], 7);
      expect(entries[1]['subject_short'], 'FG');
    });

    test('neverRaises', () {
      expect(substitutionsFromWeeks(null), isEmpty);
      expect(substitutionsFromWeeks('garbage'), isEmpty);
      // A change without a date is skipped.
      expect(
          substitutionsFromWeeks([
            {
              'Changes': [
                {'Day': 'nikdy', 'ChangeType': 'Canceled'}
              ]
            }
          ]),
          isEmpty);
    });
  });

  group('outboxExcuseIds', () {
    test('readsOmluvenkaRowsInOrderDeduped', () {
      final html = '<table data-idmsg="501" data-msgtype="OMLUVENKA">'
          '<table data-idmsg="502" data-msgtype="OBECNA">'
          '<table data-idmsg="501" data-msgtype="OMLUVENKA">'
          '<table data-idmsg="503" data-msgtype="OMLUVENKA">';
      expect(outboxExcuseIds(html), ['501', '503']);
      expect(outboxExcuseIds(''), isEmpty);
      expect(outboxExcuseIds(null), isEmpty);
    });

    test('outboxMessageIdsIncludesAllMessageTypesDeduped', () {
      final html = '<table data-idmsg="501" data-msgtype="OMLUVENKA">'
          '<table data-idmsg="502" data-msgtype="OBECNA">'
          '<table data-idmsg="501" data-msgtype="OMLUVENKA">'
          '<table data-idmsg="503" data-msgtype="SYSTEMOVA">';
      expect(outboxMessageIds(html), ['501', '502', '503']);
      expect(outboxMessageIds(''), isEmpty);
      expect(outboxMessageIds(null), isEmpty);
    });

    test('outboxExcuseCacheKeysReadsSortDateAndAttributeOrder', () {
      final html =
          '<table data-idmsg="501" data-sortdate="0:2026-10-01T07:12:45" data-msgtype="OMLUVENKA">'
          '<table data-idmsg="502" data-sortdate="0:2026-10-02T08:00:00" data-msgtype="OBECNA">'
          '<table data-msgtype="OMLUVENKA" data-idmsg="503">'
          '<table data-idmsg="504" data-sortdate="" data-msgtype="OMLUVENKA">';
      expect(outboxExcuseCacheKeys(html), {
        '501': '501|0:2026-10-01T07:12:45',
        '503': '503',
        '504': '504',
      });
      expect(outboxExcuseCacheKeys(''), isEmpty);
      expect(outboxExcuseCacheKeys(null), isEmpty);
    });

    test('parseOutboxSortDateReadsCalendarDayAndRejectsInvalid (R4 Q1)', () {
      expect(parseOutboxSortDate('0:2026-10-15T08:00:00'), DateTime(2026, 10, 15));
      expect(parseOutboxSortDate('2026-10-15'), DateTime(2026, 10, 15));
      expect(parseOutboxSortDate('0:2026-02-30T08:00:00'), isNull);
      expect(parseOutboxSortDate(''), isNull);
      expect(parseOutboxSortDate(null), isNull);
      expect(parseOutboxSortDate('garbage'), isNull);
    });
  });

  group('storeRows', () {
    test('unwrapsStoreReplies', () {
      expect(storeRows([1, 2]), [1, 2]);
      expect(
          storeRows({
            'data': [1],
            'totalCount': 1,
          }),
          [1]);
      expect(storeRows({'data': 'x'}), isNull);
      expect(storeRows(null), isNull);
    });
  });

  group('f6Extractors', () {
    test('extractMarksWidgetTriStateAndEntities', () {
      // Missing container -> null (parse failure).
      expect(extractMarksWidget(null), isNull);
      expect(extractMarksWidget('<html><body>Error 500</body></html>'), isNull);

      // Valid empty container -> [].
      expect(extractMarksWidget('<div class="bk-widget-marks"></div>'), isEmpty);

      // Valid items with isNew + HTML entities + whitespace normalization.
      const html = '''
<div class="bk-widget-marks">
  <div class="mark-line" onclick="window.location.href = appRoot + 'next/prubzna.aspx'">
    <span class="mark-displayGrade isNew"> 1- </span>
    <span class="mark-subjectName">Matematika &amp; Fyzika</span>
    <span class="mark-note">Písemka:   zlomky</span>
    <span class="mark-date">5.11.</span>
  </div>
  <div class="mark-line">
    <span class="mark-displayGrade">2</span>
    <span class="mark-subjectName">Český jazyk</span>
    <span class="mark-note"></span>
    <span class="mark-date">3.11.</span>
  </div>
</div>
''';
      expect(extractMarksWidget(html), [
        {
          'grade': '1-',
          'subject': 'Matematika & Fyzika',
          'note': 'Písemka: zlomky',
          'date': '5.11.',
          'is_new': true,
        },
        {
          'grade': '2',
          'subject': 'Český jazyk',
          'note': '',
          'date': '3.11.',
          'is_new': false,
        },
      ]);
    });

    test('substitutionsByWeekHashesBucketsDeterministicallyAndHandlesEmpty', () {
      final mon1 = DateTime(2026, 9, 7);
      final mon2 = DateTime(2026, 9, 14);
      final feedA = [
        {'day': '08.09.2026', 'hour': '2', 'type': 'Canceled', 'subject': 'M'},
        {'day': '07.09.2026', 'hour': '1', 'type': 'RoomChanged', 'subject': 'F'},
      ];
      // Same entries in opposite order with reversed key insertion order.
      final feedB = [
        {'subject': 'F', 'type': 'RoomChanged', 'hour': '1', 'day': '07.09.2026'},
        {'subject': 'M', 'type': 'Canceled', 'hour': '2', 'day': '08.09.2026'},
      ];
      final hA = substitutionsByWeekHashes(feedA, [mon1, mon2]);
      final hB = substitutionsByWeekHashes(feedB, [mon1, mon2]);
      expect(hA['2026-09-07'], hB['2026-09-07']);
      expect(hA['2026-09-14'], hB['2026-09-14']);
      expect(hA['2026-09-07'], isNot(hA['2026-09-14']));

      // Modifying a week-2 entry changes only week 2's hash.
      final feedC = [
        ...feedA,
        {'day': '15.09.2026', 'hour': '3', 'type': 'Substitution', 'subject': 'ČJ'},
      ];
      final hC = substitutionsByWeekHashes(feedC, [mon1, mon2]);
      expect(hC['2026-09-07'], hA['2026-09-07']);
      expect(hC['2026-09-14'], isNot(hA['2026-09-14']));
    });

    test('absenceCountsIncreasedIgnoresLessonCountGrowth', () {
      final prev = {
        'Matematika': {'missed_hours': 2, 'total_hours': 10},
        'Fyzika': {'missed_hours': 0, 'total_hours': 8},
      };
      // Only total_hours grew -> false.
      expect(
        absenceCountsIncreased(prev, {
          'Matematika': {'missed_hours': 2, 'total_hours': 12},
          'Fyzika': {'missed_hours': 0, 'total_hours': 9},
        }),
        isFalse,
      );
      // missed_hours grew -> true.
      expect(
        absenceCountsIncreased(prev, {
          'Matematika': {'missed_hours': 3, 'total_hours': 12},
          'Fyzika': {'missed_hours': 0, 'total_hours': 9},
        }),
        isTrue,
      );
      // Brand new subject with missed_hours > 0 -> true.
      expect(
        absenceCountsIncreased(prev, {
          ...prev,
          'Chemie': {'missed_hours': 1, 'total_hours': 4},
        }),
        isTrue,
      );
    });
  });
}
