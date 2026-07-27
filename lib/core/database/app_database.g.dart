// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $HealthEntriesTable extends HealthEntries
    with TableInfo<$HealthEntriesTable, HealthEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HealthEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _docIdMeta = const VerificationMeta('docId');
  @override
  late final GeneratedColumn<String> docId = GeneratedColumn<String>(
    'doc_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _moodMeta = const VerificationMeta('mood');
  @override
  late final GeneratedColumn<String> mood = GeneratedColumn<String>(
    'mood',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('—'),
  );
  static const VerificationMeta _waterIntakeMlMeta = const VerificationMeta(
    'waterIntakeMl',
  );
  @override
  late final GeneratedColumn<int> waterIntakeMl = GeneratedColumn<int>(
    'water_intake_ml',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _hasTakenPillTodayMeta = const VerificationMeta(
    'hasTakenPillToday',
  );
  @override
  late final GeneratedColumn<bool> hasTakenPillToday = GeneratedColumn<bool>(
    'has_taken_pill_today',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_taken_pill_today" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _menstrualCycleJsonMeta =
      const VerificationMeta('menstrualCycleJson');
  @override
  late final GeneratedColumn<String> menstrualCycleJson =
      GeneratedColumn<String>(
        'menstrual_cycle_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<DateTime> date = GeneratedColumn<DateTime>(
    'date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    docId,
    mood,
    waterIntakeMl,
    hasTakenPillToday,
    menstrualCycleJson,
    date,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'health_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<HealthEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('doc_id')) {
      context.handle(
        _docIdMeta,
        docId.isAcceptableOrUnknown(data['doc_id']!, _docIdMeta),
      );
    } else if (isInserting) {
      context.missing(_docIdMeta);
    }
    if (data.containsKey('mood')) {
      context.handle(
        _moodMeta,
        mood.isAcceptableOrUnknown(data['mood']!, _moodMeta),
      );
    }
    if (data.containsKey('water_intake_ml')) {
      context.handle(
        _waterIntakeMlMeta,
        waterIntakeMl.isAcceptableOrUnknown(
          data['water_intake_ml']!,
          _waterIntakeMlMeta,
        ),
      );
    }
    if (data.containsKey('has_taken_pill_today')) {
      context.handle(
        _hasTakenPillTodayMeta,
        hasTakenPillToday.isAcceptableOrUnknown(
          data['has_taken_pill_today']!,
          _hasTakenPillTodayMeta,
        ),
      );
    }
    if (data.containsKey('menstrual_cycle_json')) {
      context.handle(
        _menstrualCycleJsonMeta,
        menstrualCycleJson.isAcceptableOrUnknown(
          data['menstrual_cycle_json']!,
          _menstrualCycleJsonMeta,
        ),
      );
    }
    if (data.containsKey('date')) {
      context.handle(
        _dateMeta,
        date.isAcceptableOrUnknown(data['date']!, _dateMeta),
      );
    } else if (isInserting) {
      context.missing(_dateMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {docId};
  @override
  HealthEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HealthEntry(
      docId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}doc_id'],
      )!,
      mood: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mood'],
      )!,
      waterIntakeMl: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}water_intake_ml'],
      )!,
      hasTakenPillToday: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_taken_pill_today'],
      )!,
      menstrualCycleJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}menstrual_cycle_json'],
      ),
      date: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}date'],
      )!,
    );
  }

  @override
  $HealthEntriesTable createAlias(String alias) {
    return $HealthEntriesTable(attachedDatabase, alias);
  }
}

class HealthEntry extends DataClass implements Insertable<HealthEntry> {
  final String docId;
  final String mood;
  final int waterIntakeMl;
  final bool hasTakenPillToday;
  final String? menstrualCycleJson;
  final DateTime date;
  const HealthEntry({
    required this.docId,
    required this.mood,
    required this.waterIntakeMl,
    required this.hasTakenPillToday,
    this.menstrualCycleJson,
    required this.date,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['doc_id'] = Variable<String>(docId);
    map['mood'] = Variable<String>(mood);
    map['water_intake_ml'] = Variable<int>(waterIntakeMl);
    map['has_taken_pill_today'] = Variable<bool>(hasTakenPillToday);
    if (!nullToAbsent || menstrualCycleJson != null) {
      map['menstrual_cycle_json'] = Variable<String>(menstrualCycleJson);
    }
    map['date'] = Variable<DateTime>(date);
    return map;
  }

  HealthEntriesCompanion toCompanion(bool nullToAbsent) {
    return HealthEntriesCompanion(
      docId: Value(docId),
      mood: Value(mood),
      waterIntakeMl: Value(waterIntakeMl),
      hasTakenPillToday: Value(hasTakenPillToday),
      menstrualCycleJson: menstrualCycleJson == null && nullToAbsent
          ? const Value.absent()
          : Value(menstrualCycleJson),
      date: Value(date),
    );
  }

  factory HealthEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HealthEntry(
      docId: serializer.fromJson<String>(json['docId']),
      mood: serializer.fromJson<String>(json['mood']),
      waterIntakeMl: serializer.fromJson<int>(json['waterIntakeMl']),
      hasTakenPillToday: serializer.fromJson<bool>(json['hasTakenPillToday']),
      menstrualCycleJson: serializer.fromJson<String?>(
        json['menstrualCycleJson'],
      ),
      date: serializer.fromJson<DateTime>(json['date']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'docId': serializer.toJson<String>(docId),
      'mood': serializer.toJson<String>(mood),
      'waterIntakeMl': serializer.toJson<int>(waterIntakeMl),
      'hasTakenPillToday': serializer.toJson<bool>(hasTakenPillToday),
      'menstrualCycleJson': serializer.toJson<String?>(menstrualCycleJson),
      'date': serializer.toJson<DateTime>(date),
    };
  }

  HealthEntry copyWith({
    String? docId,
    String? mood,
    int? waterIntakeMl,
    bool? hasTakenPillToday,
    Value<String?> menstrualCycleJson = const Value.absent(),
    DateTime? date,
  }) => HealthEntry(
    docId: docId ?? this.docId,
    mood: mood ?? this.mood,
    waterIntakeMl: waterIntakeMl ?? this.waterIntakeMl,
    hasTakenPillToday: hasTakenPillToday ?? this.hasTakenPillToday,
    menstrualCycleJson: menstrualCycleJson.present
        ? menstrualCycleJson.value
        : this.menstrualCycleJson,
    date: date ?? this.date,
  );
  HealthEntry copyWithCompanion(HealthEntriesCompanion data) {
    return HealthEntry(
      docId: data.docId.present ? data.docId.value : this.docId,
      mood: data.mood.present ? data.mood.value : this.mood,
      waterIntakeMl: data.waterIntakeMl.present
          ? data.waterIntakeMl.value
          : this.waterIntakeMl,
      hasTakenPillToday: data.hasTakenPillToday.present
          ? data.hasTakenPillToday.value
          : this.hasTakenPillToday,
      menstrualCycleJson: data.menstrualCycleJson.present
          ? data.menstrualCycleJson.value
          : this.menstrualCycleJson,
      date: data.date.present ? data.date.value : this.date,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HealthEntry(')
          ..write('docId: $docId, ')
          ..write('mood: $mood, ')
          ..write('waterIntakeMl: $waterIntakeMl, ')
          ..write('hasTakenPillToday: $hasTakenPillToday, ')
          ..write('menstrualCycleJson: $menstrualCycleJson, ')
          ..write('date: $date')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    docId,
    mood,
    waterIntakeMl,
    hasTakenPillToday,
    menstrualCycleJson,
    date,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HealthEntry &&
          other.docId == this.docId &&
          other.mood == this.mood &&
          other.waterIntakeMl == this.waterIntakeMl &&
          other.hasTakenPillToday == this.hasTakenPillToday &&
          other.menstrualCycleJson == this.menstrualCycleJson &&
          other.date == this.date);
}

class HealthEntriesCompanion extends UpdateCompanion<HealthEntry> {
  final Value<String> docId;
  final Value<String> mood;
  final Value<int> waterIntakeMl;
  final Value<bool> hasTakenPillToday;
  final Value<String?> menstrualCycleJson;
  final Value<DateTime> date;
  final Value<int> rowid;
  const HealthEntriesCompanion({
    this.docId = const Value.absent(),
    this.mood = const Value.absent(),
    this.waterIntakeMl = const Value.absent(),
    this.hasTakenPillToday = const Value.absent(),
    this.menstrualCycleJson = const Value.absent(),
    this.date = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HealthEntriesCompanion.insert({
    required String docId,
    this.mood = const Value.absent(),
    this.waterIntakeMl = const Value.absent(),
    this.hasTakenPillToday = const Value.absent(),
    this.menstrualCycleJson = const Value.absent(),
    required DateTime date,
    this.rowid = const Value.absent(),
  }) : docId = Value(docId),
       date = Value(date);
  static Insertable<HealthEntry> custom({
    Expression<String>? docId,
    Expression<String>? mood,
    Expression<int>? waterIntakeMl,
    Expression<bool>? hasTakenPillToday,
    Expression<String>? menstrualCycleJson,
    Expression<DateTime>? date,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (docId != null) 'doc_id': docId,
      if (mood != null) 'mood': mood,
      if (waterIntakeMl != null) 'water_intake_ml': waterIntakeMl,
      if (hasTakenPillToday != null) 'has_taken_pill_today': hasTakenPillToday,
      if (menstrualCycleJson != null)
        'menstrual_cycle_json': menstrualCycleJson,
      if (date != null) 'date': date,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HealthEntriesCompanion copyWith({
    Value<String>? docId,
    Value<String>? mood,
    Value<int>? waterIntakeMl,
    Value<bool>? hasTakenPillToday,
    Value<String?>? menstrualCycleJson,
    Value<DateTime>? date,
    Value<int>? rowid,
  }) {
    return HealthEntriesCompanion(
      docId: docId ?? this.docId,
      mood: mood ?? this.mood,
      waterIntakeMl: waterIntakeMl ?? this.waterIntakeMl,
      hasTakenPillToday: hasTakenPillToday ?? this.hasTakenPillToday,
      menstrualCycleJson: menstrualCycleJson ?? this.menstrualCycleJson,
      date: date ?? this.date,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (docId.present) {
      map['doc_id'] = Variable<String>(docId.value);
    }
    if (mood.present) {
      map['mood'] = Variable<String>(mood.value);
    }
    if (waterIntakeMl.present) {
      map['water_intake_ml'] = Variable<int>(waterIntakeMl.value);
    }
    if (hasTakenPillToday.present) {
      map['has_taken_pill_today'] = Variable<bool>(hasTakenPillToday.value);
    }
    if (menstrualCycleJson.present) {
      map['menstrual_cycle_json'] = Variable<String>(menstrualCycleJson.value);
    }
    if (date.present) {
      map['date'] = Variable<DateTime>(date.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HealthEntriesCompanion(')
          ..write('docId: $docId, ')
          ..write('mood: $mood, ')
          ..write('waterIntakeMl: $waterIntakeMl, ')
          ..write('hasTakenPillToday: $hasTakenPillToday, ')
          ..write('menstrualCycleJson: $menstrualCycleJson, ')
          ..write('date: $date, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MedicationsTable extends Medications
    with TableInfo<$MedicationsTable, Medication> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MedicationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _firestoreIdMeta = const VerificationMeta(
    'firestoreId',
  );
  @override
  late final GeneratedColumn<String> firestoreId = GeneratedColumn<String>(
    'firestore_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startDateMeta = const VerificationMeta(
    'startDate',
  );
  @override
  late final GeneratedColumn<DateTime> startDate = GeneratedColumn<DateTime>(
    'start_date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationDaysMeta = const VerificationMeta(
    'durationDays',
  );
  @override
  late final GeneratedColumn<int> durationDays = GeneratedColumn<int>(
    'duration_days',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _endDateMeta = const VerificationMeta(
    'endDate',
  );
  @override
  late final GeneratedColumn<DateTime> endDate = GeneratedColumn<DateTime>(
    'end_date',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    firestoreId,
    name,
    startDate,
    durationDays,
    endDate,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'medications';
  @override
  VerificationContext validateIntegrity(
    Insertable<Medication> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('firestore_id')) {
      context.handle(
        _firestoreIdMeta,
        firestoreId.isAcceptableOrUnknown(
          data['firestore_id']!,
          _firestoreIdMeta,
        ),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('start_date')) {
      context.handle(
        _startDateMeta,
        startDate.isAcceptableOrUnknown(data['start_date']!, _startDateMeta),
      );
    } else if (isInserting) {
      context.missing(_startDateMeta);
    }
    if (data.containsKey('duration_days')) {
      context.handle(
        _durationDaysMeta,
        durationDays.isAcceptableOrUnknown(
          data['duration_days']!,
          _durationDaysMeta,
        ),
      );
    }
    if (data.containsKey('end_date')) {
      context.handle(
        _endDateMeta,
        endDate.isAcceptableOrUnknown(data['end_date']!, _endDateMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Medication map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Medication(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      firestoreId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}firestore_id'],
      ),
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      startDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}start_date'],
      )!,
      durationDays: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_days'],
      ),
      endDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}end_date'],
      ),
    );
  }

  @override
  $MedicationsTable createAlias(String alias) {
    return $MedicationsTable(attachedDatabase, alias);
  }
}

class Medication extends DataClass implements Insertable<Medication> {
  final int id;
  final String? firestoreId;
  final String name;
  final DateTime startDate;
  final int? durationDays;
  final DateTime? endDate;
  const Medication({
    required this.id,
    this.firestoreId,
    required this.name,
    required this.startDate,
    this.durationDays,
    this.endDate,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || firestoreId != null) {
      map['firestore_id'] = Variable<String>(firestoreId);
    }
    map['name'] = Variable<String>(name);
    map['start_date'] = Variable<DateTime>(startDate);
    if (!nullToAbsent || durationDays != null) {
      map['duration_days'] = Variable<int>(durationDays);
    }
    if (!nullToAbsent || endDate != null) {
      map['end_date'] = Variable<DateTime>(endDate);
    }
    return map;
  }

  MedicationsCompanion toCompanion(bool nullToAbsent) {
    return MedicationsCompanion(
      id: Value(id),
      firestoreId: firestoreId == null && nullToAbsent
          ? const Value.absent()
          : Value(firestoreId),
      name: Value(name),
      startDate: Value(startDate),
      durationDays: durationDays == null && nullToAbsent
          ? const Value.absent()
          : Value(durationDays),
      endDate: endDate == null && nullToAbsent
          ? const Value.absent()
          : Value(endDate),
    );
  }

  factory Medication.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Medication(
      id: serializer.fromJson<int>(json['id']),
      firestoreId: serializer.fromJson<String?>(json['firestoreId']),
      name: serializer.fromJson<String>(json['name']),
      startDate: serializer.fromJson<DateTime>(json['startDate']),
      durationDays: serializer.fromJson<int?>(json['durationDays']),
      endDate: serializer.fromJson<DateTime?>(json['endDate']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'firestoreId': serializer.toJson<String?>(firestoreId),
      'name': serializer.toJson<String>(name),
      'startDate': serializer.toJson<DateTime>(startDate),
      'durationDays': serializer.toJson<int?>(durationDays),
      'endDate': serializer.toJson<DateTime?>(endDate),
    };
  }

  Medication copyWith({
    int? id,
    Value<String?> firestoreId = const Value.absent(),
    String? name,
    DateTime? startDate,
    Value<int?> durationDays = const Value.absent(),
    Value<DateTime?> endDate = const Value.absent(),
  }) => Medication(
    id: id ?? this.id,
    firestoreId: firestoreId.present ? firestoreId.value : this.firestoreId,
    name: name ?? this.name,
    startDate: startDate ?? this.startDate,
    durationDays: durationDays.present ? durationDays.value : this.durationDays,
    endDate: endDate.present ? endDate.value : this.endDate,
  );
  Medication copyWithCompanion(MedicationsCompanion data) {
    return Medication(
      id: data.id.present ? data.id.value : this.id,
      firestoreId: data.firestoreId.present
          ? data.firestoreId.value
          : this.firestoreId,
      name: data.name.present ? data.name.value : this.name,
      startDate: data.startDate.present ? data.startDate.value : this.startDate,
      durationDays: data.durationDays.present
          ? data.durationDays.value
          : this.durationDays,
      endDate: data.endDate.present ? data.endDate.value : this.endDate,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Medication(')
          ..write('id: $id, ')
          ..write('firestoreId: $firestoreId, ')
          ..write('name: $name, ')
          ..write('startDate: $startDate, ')
          ..write('durationDays: $durationDays, ')
          ..write('endDate: $endDate')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, firestoreId, name, startDate, durationDays, endDate);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Medication &&
          other.id == this.id &&
          other.firestoreId == this.firestoreId &&
          other.name == this.name &&
          other.startDate == this.startDate &&
          other.durationDays == this.durationDays &&
          other.endDate == this.endDate);
}

class MedicationsCompanion extends UpdateCompanion<Medication> {
  final Value<int> id;
  final Value<String?> firestoreId;
  final Value<String> name;
  final Value<DateTime> startDate;
  final Value<int?> durationDays;
  final Value<DateTime?> endDate;
  const MedicationsCompanion({
    this.id = const Value.absent(),
    this.firestoreId = const Value.absent(),
    this.name = const Value.absent(),
    this.startDate = const Value.absent(),
    this.durationDays = const Value.absent(),
    this.endDate = const Value.absent(),
  });
  MedicationsCompanion.insert({
    this.id = const Value.absent(),
    this.firestoreId = const Value.absent(),
    required String name,
    required DateTime startDate,
    this.durationDays = const Value.absent(),
    this.endDate = const Value.absent(),
  }) : name = Value(name),
       startDate = Value(startDate);
  static Insertable<Medication> custom({
    Expression<int>? id,
    Expression<String>? firestoreId,
    Expression<String>? name,
    Expression<DateTime>? startDate,
    Expression<int>? durationDays,
    Expression<DateTime>? endDate,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (firestoreId != null) 'firestore_id': firestoreId,
      if (name != null) 'name': name,
      if (startDate != null) 'start_date': startDate,
      if (durationDays != null) 'duration_days': durationDays,
      if (endDate != null) 'end_date': endDate,
    });
  }

  MedicationsCompanion copyWith({
    Value<int>? id,
    Value<String?>? firestoreId,
    Value<String>? name,
    Value<DateTime>? startDate,
    Value<int?>? durationDays,
    Value<DateTime?>? endDate,
  }) {
    return MedicationsCompanion(
      id: id ?? this.id,
      firestoreId: firestoreId ?? this.firestoreId,
      name: name ?? this.name,
      startDate: startDate ?? this.startDate,
      durationDays: durationDays ?? this.durationDays,
      endDate: endDate ?? this.endDate,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (firestoreId.present) {
      map['firestore_id'] = Variable<String>(firestoreId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (startDate.present) {
      map['start_date'] = Variable<DateTime>(startDate.value);
    }
    if (durationDays.present) {
      map['duration_days'] = Variable<int>(durationDays.value);
    }
    if (endDate.present) {
      map['end_date'] = Variable<DateTime>(endDate.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MedicationsCompanion(')
          ..write('id: $id, ')
          ..write('firestoreId: $firestoreId, ')
          ..write('name: $name, ')
          ..write('startDate: $startDate, ')
          ..write('durationDays: $durationDays, ')
          ..write('endDate: $endDate')
          ..write(')'))
        .toString();
  }
}

class $TransactionsTable extends Transactions
    with TableInfo<$TransactionsTable, Transaction> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TransactionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _firestoreIdMeta = const VerificationMeta(
    'firestoreId',
  );
  @override
  late final GeneratedColumn<String> firestoreId = GeneratedColumn<String>(
    'firestore_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _amountMeta = const VerificationMeta('amount');
  @override
  late final GeneratedColumn<double> amount = GeneratedColumn<double>(
    'amount',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<DateTime> date = GeneratedColumn<DateTime>(
    'date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    firestoreId,
    title,
    amount,
    type,
    category,
    date,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'transactions';
  @override
  VerificationContext validateIntegrity(
    Insertable<Transaction> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('firestore_id')) {
      context.handle(
        _firestoreIdMeta,
        firestoreId.isAcceptableOrUnknown(
          data['firestore_id']!,
          _firestoreIdMeta,
        ),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('amount')) {
      context.handle(
        _amountMeta,
        amount.isAcceptableOrUnknown(data['amount']!, _amountMeta),
      );
    } else if (isInserting) {
      context.missing(_amountMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    } else if (isInserting) {
      context.missing(_categoryMeta);
    }
    if (data.containsKey('date')) {
      context.handle(
        _dateMeta,
        date.isAcceptableOrUnknown(data['date']!, _dateMeta),
      );
    } else if (isInserting) {
      context.missing(_dateMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Transaction map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Transaction(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      firestoreId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}firestore_id'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      amount: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}amount'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      )!,
      date: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}date'],
      )!,
    );
  }

  @override
  $TransactionsTable createAlias(String alias) {
    return $TransactionsTable(attachedDatabase, alias);
  }
}

class Transaction extends DataClass implements Insertable<Transaction> {
  final int id;
  final String? firestoreId;
  final String title;
  final double amount;
  final String type;
  final String category;
  final DateTime date;
  const Transaction({
    required this.id,
    this.firestoreId,
    required this.title,
    required this.amount,
    required this.type,
    required this.category,
    required this.date,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || firestoreId != null) {
      map['firestore_id'] = Variable<String>(firestoreId);
    }
    map['title'] = Variable<String>(title);
    map['amount'] = Variable<double>(amount);
    map['type'] = Variable<String>(type);
    map['category'] = Variable<String>(category);
    map['date'] = Variable<DateTime>(date);
    return map;
  }

  TransactionsCompanion toCompanion(bool nullToAbsent) {
    return TransactionsCompanion(
      id: Value(id),
      firestoreId: firestoreId == null && nullToAbsent
          ? const Value.absent()
          : Value(firestoreId),
      title: Value(title),
      amount: Value(amount),
      type: Value(type),
      category: Value(category),
      date: Value(date),
    );
  }

  factory Transaction.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Transaction(
      id: serializer.fromJson<int>(json['id']),
      firestoreId: serializer.fromJson<String?>(json['firestoreId']),
      title: serializer.fromJson<String>(json['title']),
      amount: serializer.fromJson<double>(json['amount']),
      type: serializer.fromJson<String>(json['type']),
      category: serializer.fromJson<String>(json['category']),
      date: serializer.fromJson<DateTime>(json['date']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'firestoreId': serializer.toJson<String?>(firestoreId),
      'title': serializer.toJson<String>(title),
      'amount': serializer.toJson<double>(amount),
      'type': serializer.toJson<String>(type),
      'category': serializer.toJson<String>(category),
      'date': serializer.toJson<DateTime>(date),
    };
  }

  Transaction copyWith({
    int? id,
    Value<String?> firestoreId = const Value.absent(),
    String? title,
    double? amount,
    String? type,
    String? category,
    DateTime? date,
  }) => Transaction(
    id: id ?? this.id,
    firestoreId: firestoreId.present ? firestoreId.value : this.firestoreId,
    title: title ?? this.title,
    amount: amount ?? this.amount,
    type: type ?? this.type,
    category: category ?? this.category,
    date: date ?? this.date,
  );
  Transaction copyWithCompanion(TransactionsCompanion data) {
    return Transaction(
      id: data.id.present ? data.id.value : this.id,
      firestoreId: data.firestoreId.present
          ? data.firestoreId.value
          : this.firestoreId,
      title: data.title.present ? data.title.value : this.title,
      amount: data.amount.present ? data.amount.value : this.amount,
      type: data.type.present ? data.type.value : this.type,
      category: data.category.present ? data.category.value : this.category,
      date: data.date.present ? data.date.value : this.date,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Transaction(')
          ..write('id: $id, ')
          ..write('firestoreId: $firestoreId, ')
          ..write('title: $title, ')
          ..write('amount: $amount, ')
          ..write('type: $type, ')
          ..write('category: $category, ')
          ..write('date: $date')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, firestoreId, title, amount, type, category, date);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Transaction &&
          other.id == this.id &&
          other.firestoreId == this.firestoreId &&
          other.title == this.title &&
          other.amount == this.amount &&
          other.type == this.type &&
          other.category == this.category &&
          other.date == this.date);
}

class TransactionsCompanion extends UpdateCompanion<Transaction> {
  final Value<int> id;
  final Value<String?> firestoreId;
  final Value<String> title;
  final Value<double> amount;
  final Value<String> type;
  final Value<String> category;
  final Value<DateTime> date;
  const TransactionsCompanion({
    this.id = const Value.absent(),
    this.firestoreId = const Value.absent(),
    this.title = const Value.absent(),
    this.amount = const Value.absent(),
    this.type = const Value.absent(),
    this.category = const Value.absent(),
    this.date = const Value.absent(),
  });
  TransactionsCompanion.insert({
    this.id = const Value.absent(),
    this.firestoreId = const Value.absent(),
    required String title,
    required double amount,
    required String type,
    required String category,
    required DateTime date,
  }) : title = Value(title),
       amount = Value(amount),
       type = Value(type),
       category = Value(category),
       date = Value(date);
  static Insertable<Transaction> custom({
    Expression<int>? id,
    Expression<String>? firestoreId,
    Expression<String>? title,
    Expression<double>? amount,
    Expression<String>? type,
    Expression<String>? category,
    Expression<DateTime>? date,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (firestoreId != null) 'firestore_id': firestoreId,
      if (title != null) 'title': title,
      if (amount != null) 'amount': amount,
      if (type != null) 'type': type,
      if (category != null) 'category': category,
      if (date != null) 'date': date,
    });
  }

  TransactionsCompanion copyWith({
    Value<int>? id,
    Value<String?>? firestoreId,
    Value<String>? title,
    Value<double>? amount,
    Value<String>? type,
    Value<String>? category,
    Value<DateTime>? date,
  }) {
    return TransactionsCompanion(
      id: id ?? this.id,
      firestoreId: firestoreId ?? this.firestoreId,
      title: title ?? this.title,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      category: category ?? this.category,
      date: date ?? this.date,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (firestoreId.present) {
      map['firestore_id'] = Variable<String>(firestoreId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (amount.present) {
      map['amount'] = Variable<double>(amount.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (date.present) {
      map['date'] = Variable<DateTime>(date.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TransactionsCompanion(')
          ..write('id: $id, ')
          ..write('firestoreId: $firestoreId, ')
          ..write('title: $title, ')
          ..write('amount: $amount, ')
          ..write('type: $type, ')
          ..write('category: $category, ')
          ..write('date: $date')
          ..write(')'))
        .toString();
  }
}

class $TaskTableTable extends TaskTable
    with TableInfo<$TaskTableTable, TaskTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _priorityMeta = const VerificationMeta(
    'priority',
  );
  @override
  late final GeneratedColumn<String> priority = GeneratedColumn<String>(
    'priority',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isCompletedMeta = const VerificationMeta(
    'isCompleted',
  );
  @override
  late final GeneratedColumn<bool> isCompleted = GeneratedColumn<bool>(
    'is_completed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_completed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _dateMeta = const VerificationMeta('date');
  @override
  late final GeneratedColumn<DateTime> date = GeneratedColumn<DateTime>(
    'date',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    priority,
    isCompleted,
    date,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('priority')) {
      context.handle(
        _priorityMeta,
        priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta),
      );
    } else if (isInserting) {
      context.missing(_priorityMeta);
    }
    if (data.containsKey('is_completed')) {
      context.handle(
        _isCompletedMeta,
        isCompleted.isAcceptableOrUnknown(
          data['is_completed']!,
          _isCompletedMeta,
        ),
      );
    }
    if (data.containsKey('date')) {
      context.handle(
        _dateMeta,
        date.isAcceptableOrUnknown(data['date']!, _dateMeta),
      );
    } else if (isInserting) {
      context.missing(_dateMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TaskTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      priority: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}priority'],
      )!,
      isCompleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_completed'],
      )!,
      date: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}date'],
      )!,
    );
  }

  @override
  $TaskTableTable createAlias(String alias) {
    return $TaskTableTable(attachedDatabase, alias);
  }
}

class TaskTableData extends DataClass implements Insertable<TaskTableData> {
  final String id;
  final String title;
  final String priority;
  final bool isCompleted;
  final DateTime date;
  const TaskTableData({
    required this.id,
    required this.title,
    required this.priority,
    required this.isCompleted,
    required this.date,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['priority'] = Variable<String>(priority);
    map['is_completed'] = Variable<bool>(isCompleted);
    map['date'] = Variable<DateTime>(date);
    return map;
  }

  TaskTableCompanion toCompanion(bool nullToAbsent) {
    return TaskTableCompanion(
      id: Value(id),
      title: Value(title),
      priority: Value(priority),
      isCompleted: Value(isCompleted),
      date: Value(date),
    );
  }

  factory TaskTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskTableData(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      priority: serializer.fromJson<String>(json['priority']),
      isCompleted: serializer.fromJson<bool>(json['isCompleted']),
      date: serializer.fromJson<DateTime>(json['date']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'priority': serializer.toJson<String>(priority),
      'isCompleted': serializer.toJson<bool>(isCompleted),
      'date': serializer.toJson<DateTime>(date),
    };
  }

  TaskTableData copyWith({
    String? id,
    String? title,
    String? priority,
    bool? isCompleted,
    DateTime? date,
  }) => TaskTableData(
    id: id ?? this.id,
    title: title ?? this.title,
    priority: priority ?? this.priority,
    isCompleted: isCompleted ?? this.isCompleted,
    date: date ?? this.date,
  );
  TaskTableData copyWithCompanion(TaskTableCompanion data) {
    return TaskTableData(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      priority: data.priority.present ? data.priority.value : this.priority,
      isCompleted: data.isCompleted.present
          ? data.isCompleted.value
          : this.isCompleted,
      date: data.date.present ? data.date.value : this.date,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskTableData(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('priority: $priority, ')
          ..write('isCompleted: $isCompleted, ')
          ..write('date: $date')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, priority, isCompleted, date);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskTableData &&
          other.id == this.id &&
          other.title == this.title &&
          other.priority == this.priority &&
          other.isCompleted == this.isCompleted &&
          other.date == this.date);
}

class TaskTableCompanion extends UpdateCompanion<TaskTableData> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> priority;
  final Value<bool> isCompleted;
  final Value<DateTime> date;
  final Value<int> rowid;
  const TaskTableCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.priority = const Value.absent(),
    this.isCompleted = const Value.absent(),
    this.date = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TaskTableCompanion.insert({
    required String id,
    required String title,
    required String priority,
    this.isCompleted = const Value.absent(),
    required DateTime date,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       priority = Value(priority),
       date = Value(date);
  static Insertable<TaskTableData> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? priority,
    Expression<bool>? isCompleted,
    Expression<DateTime>? date,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (priority != null) 'priority': priority,
      if (isCompleted != null) 'is_completed': isCompleted,
      if (date != null) 'date': date,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TaskTableCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? priority,
    Value<bool>? isCompleted,
    Value<DateTime>? date,
    Value<int>? rowid,
  }) {
    return TaskTableCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      priority: priority ?? this.priority,
      isCompleted: isCompleted ?? this.isCompleted,
      date: date ?? this.date,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (priority.present) {
      map['priority'] = Variable<String>(priority.value);
    }
    if (isCompleted.present) {
      map['is_completed'] = Variable<bool>(isCompleted.value);
    }
    if (date.present) {
      map['date'] = Variable<DateTime>(date.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskTableCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('priority: $priority, ')
          ..write('isCompleted: $isCompleted, ')
          ..write('date: $date, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HabitsTable extends Habits with TableInfo<$HabitsTable, Habit> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HabitsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _completedDatesMeta = const VerificationMeta(
    'completedDates',
  );
  @override
  late final GeneratedColumn<String> completedDates = GeneratedColumn<String>(
    'completed_dates',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, title, completedDates];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'habits';
  @override
  VerificationContext validateIntegrity(
    Insertable<Habit> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('completed_dates')) {
      context.handle(
        _completedDatesMeta,
        completedDates.isAcceptableOrUnknown(
          data['completed_dates']!,
          _completedDatesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_completedDatesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Habit map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Habit(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      completedDates: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}completed_dates'],
      )!,
    );
  }

  @override
  $HabitsTable createAlias(String alias) {
    return $HabitsTable(attachedDatabase, alias);
  }
}

class Habit extends DataClass implements Insertable<Habit> {
  final String id;
  final String title;
  final String completedDates;
  const Habit({
    required this.id,
    required this.title,
    required this.completedDates,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['completed_dates'] = Variable<String>(completedDates);
    return map;
  }

  HabitsCompanion toCompanion(bool nullToAbsent) {
    return HabitsCompanion(
      id: Value(id),
      title: Value(title),
      completedDates: Value(completedDates),
    );
  }

  factory Habit.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Habit(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      completedDates: serializer.fromJson<String>(json['completedDates']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'completedDates': serializer.toJson<String>(completedDates),
    };
  }

  Habit copyWith({String? id, String? title, String? completedDates}) => Habit(
    id: id ?? this.id,
    title: title ?? this.title,
    completedDates: completedDates ?? this.completedDates,
  );
  Habit copyWithCompanion(HabitsCompanion data) {
    return Habit(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      completedDates: data.completedDates.present
          ? data.completedDates.value
          : this.completedDates,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Habit(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('completedDates: $completedDates')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, completedDates);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Habit &&
          other.id == this.id &&
          other.title == this.title &&
          other.completedDates == this.completedDates);
}

class HabitsCompanion extends UpdateCompanion<Habit> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> completedDates;
  final Value<int> rowid;
  const HabitsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.completedDates = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HabitsCompanion.insert({
    required String id,
    required String title,
    required String completedDates,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       completedDates = Value(completedDates);
  static Insertable<Habit> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? completedDates,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (completedDates != null) 'completed_dates': completedDates,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HabitsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? completedDates,
    Value<int>? rowid,
  }) {
    return HabitsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      completedDates: completedDates ?? this.completedDates,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (completedDates.present) {
      map['completed_dates'] = Variable<String>(completedDates.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HabitsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('completedDates: $completedDates, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StudyStatsTable extends StudyStats
    with TableInfo<$StudyStatsTable, StudyStat> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StudyStatsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _streakMeta = const VerificationMeta('streak');
  @override
  late final GeneratedColumn<int> streak = GeneratedColumn<int>(
    'streak',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reviewQueueMeta = const VerificationMeta(
    'reviewQueue',
  );
  @override
  late final GeneratedColumn<int> reviewQueue = GeneratedColumn<int>(
    'review_queue',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _progressMeta = const VerificationMeta(
    'progress',
  );
  @override
  late final GeneratedColumn<double> progress = GeneratedColumn<double>(
    'progress',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastStudyDateMeta = const VerificationMeta(
    'lastStudyDate',
  );
  @override
  late final GeneratedColumn<int> lastStudyDate = GeneratedColumn<int>(
    'last_study_date',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    streak,
    reviewQueue,
    progress,
    lastStudyDate,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'study_stats';
  @override
  VerificationContext validateIntegrity(
    Insertable<StudyStat> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('streak')) {
      context.handle(
        _streakMeta,
        streak.isAcceptableOrUnknown(data['streak']!, _streakMeta),
      );
    } else if (isInserting) {
      context.missing(_streakMeta);
    }
    if (data.containsKey('review_queue')) {
      context.handle(
        _reviewQueueMeta,
        reviewQueue.isAcceptableOrUnknown(
          data['review_queue']!,
          _reviewQueueMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_reviewQueueMeta);
    }
    if (data.containsKey('progress')) {
      context.handle(
        _progressMeta,
        progress.isAcceptableOrUnknown(data['progress']!, _progressMeta),
      );
    } else if (isInserting) {
      context.missing(_progressMeta);
    }
    if (data.containsKey('last_study_date')) {
      context.handle(
        _lastStudyDateMeta,
        lastStudyDate.isAcceptableOrUnknown(
          data['last_study_date']!,
          _lastStudyDateMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StudyStat map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StudyStat(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      streak: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}streak'],
      )!,
      reviewQueue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}review_queue'],
      )!,
      progress: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}progress'],
      )!,
      lastStudyDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_study_date'],
      ),
    );
  }

  @override
  $StudyStatsTable createAlias(String alias) {
    return $StudyStatsTable(attachedDatabase, alias);
  }
}

class StudyStat extends DataClass implements Insertable<StudyStat> {
  final String id;
  final int streak;
  final int reviewQueue;
  final double progress;
  final int? lastStudyDate;
  const StudyStat({
    required this.id,
    required this.streak,
    required this.reviewQueue,
    required this.progress,
    this.lastStudyDate,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['streak'] = Variable<int>(streak);
    map['review_queue'] = Variable<int>(reviewQueue);
    map['progress'] = Variable<double>(progress);
    if (!nullToAbsent || lastStudyDate != null) {
      map['last_study_date'] = Variable<int>(lastStudyDate);
    }
    return map;
  }

  StudyStatsCompanion toCompanion(bool nullToAbsent) {
    return StudyStatsCompanion(
      id: Value(id),
      streak: Value(streak),
      reviewQueue: Value(reviewQueue),
      progress: Value(progress),
      lastStudyDate: lastStudyDate == null && nullToAbsent
          ? const Value.absent()
          : Value(lastStudyDate),
    );
  }

  factory StudyStat.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StudyStat(
      id: serializer.fromJson<String>(json['id']),
      streak: serializer.fromJson<int>(json['streak']),
      reviewQueue: serializer.fromJson<int>(json['reviewQueue']),
      progress: serializer.fromJson<double>(json['progress']),
      lastStudyDate: serializer.fromJson<int?>(json['lastStudyDate']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'streak': serializer.toJson<int>(streak),
      'reviewQueue': serializer.toJson<int>(reviewQueue),
      'progress': serializer.toJson<double>(progress),
      'lastStudyDate': serializer.toJson<int?>(lastStudyDate),
    };
  }

  StudyStat copyWith({
    String? id,
    int? streak,
    int? reviewQueue,
    double? progress,
    Value<int?> lastStudyDate = const Value.absent(),
  }) => StudyStat(
    id: id ?? this.id,
    streak: streak ?? this.streak,
    reviewQueue: reviewQueue ?? this.reviewQueue,
    progress: progress ?? this.progress,
    lastStudyDate: lastStudyDate.present
        ? lastStudyDate.value
        : this.lastStudyDate,
  );
  StudyStat copyWithCompanion(StudyStatsCompanion data) {
    return StudyStat(
      id: data.id.present ? data.id.value : this.id,
      streak: data.streak.present ? data.streak.value : this.streak,
      reviewQueue: data.reviewQueue.present
          ? data.reviewQueue.value
          : this.reviewQueue,
      progress: data.progress.present ? data.progress.value : this.progress,
      lastStudyDate: data.lastStudyDate.present
          ? data.lastStudyDate.value
          : this.lastStudyDate,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StudyStat(')
          ..write('id: $id, ')
          ..write('streak: $streak, ')
          ..write('reviewQueue: $reviewQueue, ')
          ..write('progress: $progress, ')
          ..write('lastStudyDate: $lastStudyDate')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, streak, reviewQueue, progress, lastStudyDate);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StudyStat &&
          other.id == this.id &&
          other.streak == this.streak &&
          other.reviewQueue == this.reviewQueue &&
          other.progress == this.progress &&
          other.lastStudyDate == this.lastStudyDate);
}

class StudyStatsCompanion extends UpdateCompanion<StudyStat> {
  final Value<String> id;
  final Value<int> streak;
  final Value<int> reviewQueue;
  final Value<double> progress;
  final Value<int?> lastStudyDate;
  final Value<int> rowid;
  const StudyStatsCompanion({
    this.id = const Value.absent(),
    this.streak = const Value.absent(),
    this.reviewQueue = const Value.absent(),
    this.progress = const Value.absent(),
    this.lastStudyDate = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StudyStatsCompanion.insert({
    required String id,
    required int streak,
    required int reviewQueue,
    required double progress,
    this.lastStudyDate = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       streak = Value(streak),
       reviewQueue = Value(reviewQueue),
       progress = Value(progress);
  static Insertable<StudyStat> custom({
    Expression<String>? id,
    Expression<int>? streak,
    Expression<int>? reviewQueue,
    Expression<double>? progress,
    Expression<int>? lastStudyDate,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (streak != null) 'streak': streak,
      if (reviewQueue != null) 'review_queue': reviewQueue,
      if (progress != null) 'progress': progress,
      if (lastStudyDate != null) 'last_study_date': lastStudyDate,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StudyStatsCompanion copyWith({
    Value<String>? id,
    Value<int>? streak,
    Value<int>? reviewQueue,
    Value<double>? progress,
    Value<int?>? lastStudyDate,
    Value<int>? rowid,
  }) {
    return StudyStatsCompanion(
      id: id ?? this.id,
      streak: streak ?? this.streak,
      reviewQueue: reviewQueue ?? this.reviewQueue,
      progress: progress ?? this.progress,
      lastStudyDate: lastStudyDate ?? this.lastStudyDate,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (streak.present) {
      map['streak'] = Variable<int>(streak.value);
    }
    if (reviewQueue.present) {
      map['review_queue'] = Variable<int>(reviewQueue.value);
    }
    if (progress.present) {
      map['progress'] = Variable<double>(progress.value);
    }
    if (lastStudyDate.present) {
      map['last_study_date'] = Variable<int>(lastStudyDate.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StudyStatsCompanion(')
          ..write('id: $id, ')
          ..write('streak: $streak, ')
          ..write('reviewQueue: $reviewQueue, ')
          ..write('progress: $progress, ')
          ..write('lastStudyDate: $lastStudyDate, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SubjectsTable extends Subjects with TableInfo<$SubjectsTable, Subject> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SubjectsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cardsToReviewMeta = const VerificationMeta(
    'cardsToReview',
  );
  @override
  late final GeneratedColumn<int> cardsToReview = GeneratedColumn<int>(
    'cards_to_review',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _streakDaysMeta = const VerificationMeta(
    'streakDays',
  );
  @override
  late final GeneratedColumn<int> streakDays = GeneratedColumn<int>(
    'streak_days',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _progressMeta = const VerificationMeta(
    'progress',
  );
  @override
  late final GeneratedColumn<double> progress = GeneratedColumn<double>(
    'progress',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hasExamMeta = const VerificationMeta(
    'hasExam',
  );
  @override
  late final GeneratedColumn<bool> hasExam = GeneratedColumn<bool>(
    'has_exam',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_exam" IN (0, 1))',
    ),
  );
  static const VerificationMeta _examDateMeta = const VerificationMeta(
    'examDate',
  );
  @override
  late final GeneratedColumn<int> examDate = GeneratedColumn<int>(
    'exam_date',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    cardsToReview,
    streakDays,
    progress,
    hasExam,
    examDate,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'subjects';
  @override
  VerificationContext validateIntegrity(
    Insertable<Subject> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('cards_to_review')) {
      context.handle(
        _cardsToReviewMeta,
        cardsToReview.isAcceptableOrUnknown(
          data['cards_to_review']!,
          _cardsToReviewMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_cardsToReviewMeta);
    }
    if (data.containsKey('streak_days')) {
      context.handle(
        _streakDaysMeta,
        streakDays.isAcceptableOrUnknown(data['streak_days']!, _streakDaysMeta),
      );
    } else if (isInserting) {
      context.missing(_streakDaysMeta);
    }
    if (data.containsKey('progress')) {
      context.handle(
        _progressMeta,
        progress.isAcceptableOrUnknown(data['progress']!, _progressMeta),
      );
    } else if (isInserting) {
      context.missing(_progressMeta);
    }
    if (data.containsKey('has_exam')) {
      context.handle(
        _hasExamMeta,
        hasExam.isAcceptableOrUnknown(data['has_exam']!, _hasExamMeta),
      );
    } else if (isInserting) {
      context.missing(_hasExamMeta);
    }
    if (data.containsKey('exam_date')) {
      context.handle(
        _examDateMeta,
        examDate.isAcceptableOrUnknown(data['exam_date']!, _examDateMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Subject map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Subject(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      cardsToReview: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cards_to_review'],
      )!,
      streakDays: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}streak_days'],
      )!,
      progress: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}progress'],
      )!,
      hasExam: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_exam'],
      )!,
      examDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}exam_date'],
      ),
    );
  }

  @override
  $SubjectsTable createAlias(String alias) {
    return $SubjectsTable(attachedDatabase, alias);
  }
}

class Subject extends DataClass implements Insertable<Subject> {
  final String id;
  final String title;
  final int cardsToReview;
  final int streakDays;
  final double progress;
  final bool hasExam;
  final int? examDate;
  const Subject({
    required this.id,
    required this.title,
    required this.cardsToReview,
    required this.streakDays,
    required this.progress,
    required this.hasExam,
    this.examDate,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['cards_to_review'] = Variable<int>(cardsToReview);
    map['streak_days'] = Variable<int>(streakDays);
    map['progress'] = Variable<double>(progress);
    map['has_exam'] = Variable<bool>(hasExam);
    if (!nullToAbsent || examDate != null) {
      map['exam_date'] = Variable<int>(examDate);
    }
    return map;
  }

  SubjectsCompanion toCompanion(bool nullToAbsent) {
    return SubjectsCompanion(
      id: Value(id),
      title: Value(title),
      cardsToReview: Value(cardsToReview),
      streakDays: Value(streakDays),
      progress: Value(progress),
      hasExam: Value(hasExam),
      examDate: examDate == null && nullToAbsent
          ? const Value.absent()
          : Value(examDate),
    );
  }

  factory Subject.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Subject(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      cardsToReview: serializer.fromJson<int>(json['cardsToReview']),
      streakDays: serializer.fromJson<int>(json['streakDays']),
      progress: serializer.fromJson<double>(json['progress']),
      hasExam: serializer.fromJson<bool>(json['hasExam']),
      examDate: serializer.fromJson<int?>(json['examDate']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'cardsToReview': serializer.toJson<int>(cardsToReview),
      'streakDays': serializer.toJson<int>(streakDays),
      'progress': serializer.toJson<double>(progress),
      'hasExam': serializer.toJson<bool>(hasExam),
      'examDate': serializer.toJson<int?>(examDate),
    };
  }

  Subject copyWith({
    String? id,
    String? title,
    int? cardsToReview,
    int? streakDays,
    double? progress,
    bool? hasExam,
    Value<int?> examDate = const Value.absent(),
  }) => Subject(
    id: id ?? this.id,
    title: title ?? this.title,
    cardsToReview: cardsToReview ?? this.cardsToReview,
    streakDays: streakDays ?? this.streakDays,
    progress: progress ?? this.progress,
    hasExam: hasExam ?? this.hasExam,
    examDate: examDate.present ? examDate.value : this.examDate,
  );
  Subject copyWithCompanion(SubjectsCompanion data) {
    return Subject(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      cardsToReview: data.cardsToReview.present
          ? data.cardsToReview.value
          : this.cardsToReview,
      streakDays: data.streakDays.present
          ? data.streakDays.value
          : this.streakDays,
      progress: data.progress.present ? data.progress.value : this.progress,
      hasExam: data.hasExam.present ? data.hasExam.value : this.hasExam,
      examDate: data.examDate.present ? data.examDate.value : this.examDate,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Subject(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('cardsToReview: $cardsToReview, ')
          ..write('streakDays: $streakDays, ')
          ..write('progress: $progress, ')
          ..write('hasExam: $hasExam, ')
          ..write('examDate: $examDate')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    cardsToReview,
    streakDays,
    progress,
    hasExam,
    examDate,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Subject &&
          other.id == this.id &&
          other.title == this.title &&
          other.cardsToReview == this.cardsToReview &&
          other.streakDays == this.streakDays &&
          other.progress == this.progress &&
          other.hasExam == this.hasExam &&
          other.examDate == this.examDate);
}

class SubjectsCompanion extends UpdateCompanion<Subject> {
  final Value<String> id;
  final Value<String> title;
  final Value<int> cardsToReview;
  final Value<int> streakDays;
  final Value<double> progress;
  final Value<bool> hasExam;
  final Value<int?> examDate;
  final Value<int> rowid;
  const SubjectsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.cardsToReview = const Value.absent(),
    this.streakDays = const Value.absent(),
    this.progress = const Value.absent(),
    this.hasExam = const Value.absent(),
    this.examDate = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SubjectsCompanion.insert({
    required String id,
    required String title,
    required int cardsToReview,
    required int streakDays,
    required double progress,
    required bool hasExam,
    this.examDate = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       cardsToReview = Value(cardsToReview),
       streakDays = Value(streakDays),
       progress = Value(progress),
       hasExam = Value(hasExam);
  static Insertable<Subject> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<int>? cardsToReview,
    Expression<int>? streakDays,
    Expression<double>? progress,
    Expression<bool>? hasExam,
    Expression<int>? examDate,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (cardsToReview != null) 'cards_to_review': cardsToReview,
      if (streakDays != null) 'streak_days': streakDays,
      if (progress != null) 'progress': progress,
      if (hasExam != null) 'has_exam': hasExam,
      if (examDate != null) 'exam_date': examDate,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SubjectsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<int>? cardsToReview,
    Value<int>? streakDays,
    Value<double>? progress,
    Value<bool>? hasExam,
    Value<int?>? examDate,
    Value<int>? rowid,
  }) {
    return SubjectsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      cardsToReview: cardsToReview ?? this.cardsToReview,
      streakDays: streakDays ?? this.streakDays,
      progress: progress ?? this.progress,
      hasExam: hasExam ?? this.hasExam,
      examDate: examDate ?? this.examDate,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (cardsToReview.present) {
      map['cards_to_review'] = Variable<int>(cardsToReview.value);
    }
    if (streakDays.present) {
      map['streak_days'] = Variable<int>(streakDays.value);
    }
    if (progress.present) {
      map['progress'] = Variable<double>(progress.value);
    }
    if (hasExam.present) {
      map['has_exam'] = Variable<bool>(hasExam.value);
    }
    if (examDate.present) {
      map['exam_date'] = Variable<int>(examDate.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SubjectsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('cardsToReview: $cardsToReview, ')
          ..write('streakDays: $streakDays, ')
          ..write('progress: $progress, ')
          ..write('hasExam: $hasExam, ')
          ..write('examDate: $examDate, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FlashcardsTable extends Flashcards
    with TableInfo<$FlashcardsTable, Flashcard> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FlashcardsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectIdMeta = const VerificationMeta(
    'subjectId',
  );
  @override
  late final GeneratedColumn<String> subjectId = GeneratedColumn<String>(
    'subject_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES subjects (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _questionMeta = const VerificationMeta(
    'question',
  );
  @override
  late final GeneratedColumn<String> question = GeneratedColumn<String>(
    'question',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _answerMeta = const VerificationMeta('answer');
  @override
  late final GeneratedColumn<String> answer = GeneratedColumn<String>(
    'answer',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastReviewedMeta = const VerificationMeta(
    'lastReviewed',
  );
  @override
  late final GeneratedColumn<int> lastReviewed = GeneratedColumn<int>(
    'last_reviewed',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    subjectId,
    question,
    answer,
    lastReviewed,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'flashcards';
  @override
  VerificationContext validateIntegrity(
    Insertable<Flashcard> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('subject_id')) {
      context.handle(
        _subjectIdMeta,
        subjectId.isAcceptableOrUnknown(data['subject_id']!, _subjectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectIdMeta);
    }
    if (data.containsKey('question')) {
      context.handle(
        _questionMeta,
        question.isAcceptableOrUnknown(data['question']!, _questionMeta),
      );
    } else if (isInserting) {
      context.missing(_questionMeta);
    }
    if (data.containsKey('answer')) {
      context.handle(
        _answerMeta,
        answer.isAcceptableOrUnknown(data['answer']!, _answerMeta),
      );
    } else if (isInserting) {
      context.missing(_answerMeta);
    }
    if (data.containsKey('last_reviewed')) {
      context.handle(
        _lastReviewedMeta,
        lastReviewed.isAcceptableOrUnknown(
          data['last_reviewed']!,
          _lastReviewedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Flashcard map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Flashcard(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      subjectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_id'],
      )!,
      question: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question'],
      )!,
      answer: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}answer'],
      )!,
      lastReviewed: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_reviewed'],
      ),
    );
  }

  @override
  $FlashcardsTable createAlias(String alias) {
    return $FlashcardsTable(attachedDatabase, alias);
  }
}

class Flashcard extends DataClass implements Insertable<Flashcard> {
  final String id;
  final String subjectId;
  final String question;
  final String answer;
  final int? lastReviewed;
  const Flashcard({
    required this.id,
    required this.subjectId,
    required this.question,
    required this.answer,
    this.lastReviewed,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['subject_id'] = Variable<String>(subjectId);
    map['question'] = Variable<String>(question);
    map['answer'] = Variable<String>(answer);
    if (!nullToAbsent || lastReviewed != null) {
      map['last_reviewed'] = Variable<int>(lastReviewed);
    }
    return map;
  }

  FlashcardsCompanion toCompanion(bool nullToAbsent) {
    return FlashcardsCompanion(
      id: Value(id),
      subjectId: Value(subjectId),
      question: Value(question),
      answer: Value(answer),
      lastReviewed: lastReviewed == null && nullToAbsent
          ? const Value.absent()
          : Value(lastReviewed),
    );
  }

  factory Flashcard.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Flashcard(
      id: serializer.fromJson<String>(json['id']),
      subjectId: serializer.fromJson<String>(json['subjectId']),
      question: serializer.fromJson<String>(json['question']),
      answer: serializer.fromJson<String>(json['answer']),
      lastReviewed: serializer.fromJson<int?>(json['lastReviewed']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'subjectId': serializer.toJson<String>(subjectId),
      'question': serializer.toJson<String>(question),
      'answer': serializer.toJson<String>(answer),
      'lastReviewed': serializer.toJson<int?>(lastReviewed),
    };
  }

  Flashcard copyWith({
    String? id,
    String? subjectId,
    String? question,
    String? answer,
    Value<int?> lastReviewed = const Value.absent(),
  }) => Flashcard(
    id: id ?? this.id,
    subjectId: subjectId ?? this.subjectId,
    question: question ?? this.question,
    answer: answer ?? this.answer,
    lastReviewed: lastReviewed.present ? lastReviewed.value : this.lastReviewed,
  );
  Flashcard copyWithCompanion(FlashcardsCompanion data) {
    return Flashcard(
      id: data.id.present ? data.id.value : this.id,
      subjectId: data.subjectId.present ? data.subjectId.value : this.subjectId,
      question: data.question.present ? data.question.value : this.question,
      answer: data.answer.present ? data.answer.value : this.answer,
      lastReviewed: data.lastReviewed.present
          ? data.lastReviewed.value
          : this.lastReviewed,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Flashcard(')
          ..write('id: $id, ')
          ..write('subjectId: $subjectId, ')
          ..write('question: $question, ')
          ..write('answer: $answer, ')
          ..write('lastReviewed: $lastReviewed')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, subjectId, question, answer, lastReviewed);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Flashcard &&
          other.id == this.id &&
          other.subjectId == this.subjectId &&
          other.question == this.question &&
          other.answer == this.answer &&
          other.lastReviewed == this.lastReviewed);
}

class FlashcardsCompanion extends UpdateCompanion<Flashcard> {
  final Value<String> id;
  final Value<String> subjectId;
  final Value<String> question;
  final Value<String> answer;
  final Value<int?> lastReviewed;
  final Value<int> rowid;
  const FlashcardsCompanion({
    this.id = const Value.absent(),
    this.subjectId = const Value.absent(),
    this.question = const Value.absent(),
    this.answer = const Value.absent(),
    this.lastReviewed = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FlashcardsCompanion.insert({
    required String id,
    required String subjectId,
    required String question,
    required String answer,
    this.lastReviewed = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       subjectId = Value(subjectId),
       question = Value(question),
       answer = Value(answer);
  static Insertable<Flashcard> custom({
    Expression<String>? id,
    Expression<String>? subjectId,
    Expression<String>? question,
    Expression<String>? answer,
    Expression<int>? lastReviewed,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (subjectId != null) 'subject_id': subjectId,
      if (question != null) 'question': question,
      if (answer != null) 'answer': answer,
      if (lastReviewed != null) 'last_reviewed': lastReviewed,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FlashcardsCompanion copyWith({
    Value<String>? id,
    Value<String>? subjectId,
    Value<String>? question,
    Value<String>? answer,
    Value<int?>? lastReviewed,
    Value<int>? rowid,
  }) {
    return FlashcardsCompanion(
      id: id ?? this.id,
      subjectId: subjectId ?? this.subjectId,
      question: question ?? this.question,
      answer: answer ?? this.answer,
      lastReviewed: lastReviewed ?? this.lastReviewed,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (subjectId.present) {
      map['subject_id'] = Variable<String>(subjectId.value);
    }
    if (question.present) {
      map['question'] = Variable<String>(question.value);
    }
    if (answer.present) {
      map['answer'] = Variable<String>(answer.value);
    }
    if (lastReviewed.present) {
      map['last_reviewed'] = Variable<int>(lastReviewed.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FlashcardsCompanion(')
          ..write('id: $id, ')
          ..write('subjectId: $subjectId, ')
          ..write('question: $question, ')
          ..write('answer: $answer, ')
          ..write('lastReviewed: $lastReviewed, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GoalsTable extends Goals with TableInfo<$GoalsTable, Goal> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GoalsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _periodMeta = const VerificationMeta('period');
  @override
  late final GeneratedColumn<String> period = GeneratedColumn<String>(
    'period',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _currentValueMeta = const VerificationMeta(
    'currentValue',
  );
  @override
  late final GeneratedColumn<int> currentValue = GeneratedColumn<int>(
    'current_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _targetValueMeta = const VerificationMeta(
    'targetValue',
  );
  @override
  late final GeneratedColumn<int> targetValue = GeneratedColumn<int>(
    'target_value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastResetMeta = const VerificationMeta(
    'lastReset',
  );
  @override
  late final GeneratedColumn<int> lastReset = GeneratedColumn<int>(
    'last_reset',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    period,
    currentValue,
    targetValue,
    createdAt,
    lastReset,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'goals';
  @override
  VerificationContext validateIntegrity(
    Insertable<Goal> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('period')) {
      context.handle(
        _periodMeta,
        period.isAcceptableOrUnknown(data['period']!, _periodMeta),
      );
    } else if (isInserting) {
      context.missing(_periodMeta);
    }
    if (data.containsKey('current_value')) {
      context.handle(
        _currentValueMeta,
        currentValue.isAcceptableOrUnknown(
          data['current_value']!,
          _currentValueMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_currentValueMeta);
    }
    if (data.containsKey('target_value')) {
      context.handle(
        _targetValueMeta,
        targetValue.isAcceptableOrUnknown(
          data['target_value']!,
          _targetValueMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_targetValueMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_reset')) {
      context.handle(
        _lastResetMeta,
        lastReset.isAcceptableOrUnknown(data['last_reset']!, _lastResetMeta),
      );
    } else if (isInserting) {
      context.missing(_lastResetMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Goal map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Goal(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      period: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}period'],
      )!,
      currentValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}current_value'],
      )!,
      targetValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}target_value'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      lastReset: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_reset'],
      )!,
    );
  }

  @override
  $GoalsTable createAlias(String alias) {
    return $GoalsTable(attachedDatabase, alias);
  }
}

class Goal extends DataClass implements Insertable<Goal> {
  final String id;
  final String title;
  final String period;
  final int currentValue;
  final int targetValue;
  final int createdAt;
  final int lastReset;
  const Goal({
    required this.id,
    required this.title,
    required this.period,
    required this.currentValue,
    required this.targetValue,
    required this.createdAt,
    required this.lastReset,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['period'] = Variable<String>(period);
    map['current_value'] = Variable<int>(currentValue);
    map['target_value'] = Variable<int>(targetValue);
    map['created_at'] = Variable<int>(createdAt);
    map['last_reset'] = Variable<int>(lastReset);
    return map;
  }

  GoalsCompanion toCompanion(bool nullToAbsent) {
    return GoalsCompanion(
      id: Value(id),
      title: Value(title),
      period: Value(period),
      currentValue: Value(currentValue),
      targetValue: Value(targetValue),
      createdAt: Value(createdAt),
      lastReset: Value(lastReset),
    );
  }

  factory Goal.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Goal(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      period: serializer.fromJson<String>(json['period']),
      currentValue: serializer.fromJson<int>(json['currentValue']),
      targetValue: serializer.fromJson<int>(json['targetValue']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      lastReset: serializer.fromJson<int>(json['lastReset']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'period': serializer.toJson<String>(period),
      'currentValue': serializer.toJson<int>(currentValue),
      'targetValue': serializer.toJson<int>(targetValue),
      'createdAt': serializer.toJson<int>(createdAt),
      'lastReset': serializer.toJson<int>(lastReset),
    };
  }

  Goal copyWith({
    String? id,
    String? title,
    String? period,
    int? currentValue,
    int? targetValue,
    int? createdAt,
    int? lastReset,
  }) => Goal(
    id: id ?? this.id,
    title: title ?? this.title,
    period: period ?? this.period,
    currentValue: currentValue ?? this.currentValue,
    targetValue: targetValue ?? this.targetValue,
    createdAt: createdAt ?? this.createdAt,
    lastReset: lastReset ?? this.lastReset,
  );
  Goal copyWithCompanion(GoalsCompanion data) {
    return Goal(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      period: data.period.present ? data.period.value : this.period,
      currentValue: data.currentValue.present
          ? data.currentValue.value
          : this.currentValue,
      targetValue: data.targetValue.present
          ? data.targetValue.value
          : this.targetValue,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastReset: data.lastReset.present ? data.lastReset.value : this.lastReset,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Goal(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('period: $period, ')
          ..write('currentValue: $currentValue, ')
          ..write('targetValue: $targetValue, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastReset: $lastReset')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    period,
    currentValue,
    targetValue,
    createdAt,
    lastReset,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Goal &&
          other.id == this.id &&
          other.title == this.title &&
          other.period == this.period &&
          other.currentValue == this.currentValue &&
          other.targetValue == this.targetValue &&
          other.createdAt == this.createdAt &&
          other.lastReset == this.lastReset);
}

class GoalsCompanion extends UpdateCompanion<Goal> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> period;
  final Value<int> currentValue;
  final Value<int> targetValue;
  final Value<int> createdAt;
  final Value<int> lastReset;
  final Value<int> rowid;
  const GoalsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.period = const Value.absent(),
    this.currentValue = const Value.absent(),
    this.targetValue = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastReset = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GoalsCompanion.insert({
    required String id,
    required String title,
    required String period,
    required int currentValue,
    required int targetValue,
    required int createdAt,
    required int lastReset,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       period = Value(period),
       currentValue = Value(currentValue),
       targetValue = Value(targetValue),
       createdAt = Value(createdAt),
       lastReset = Value(lastReset);
  static Insertable<Goal> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? period,
    Expression<int>? currentValue,
    Expression<int>? targetValue,
    Expression<int>? createdAt,
    Expression<int>? lastReset,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (period != null) 'period': period,
      if (currentValue != null) 'current_value': currentValue,
      if (targetValue != null) 'target_value': targetValue,
      if (createdAt != null) 'created_at': createdAt,
      if (lastReset != null) 'last_reset': lastReset,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GoalsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? period,
    Value<int>? currentValue,
    Value<int>? targetValue,
    Value<int>? createdAt,
    Value<int>? lastReset,
    Value<int>? rowid,
  }) {
    return GoalsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      period: period ?? this.period,
      currentValue: currentValue ?? this.currentValue,
      targetValue: targetValue ?? this.targetValue,
      createdAt: createdAt ?? this.createdAt,
      lastReset: lastReset ?? this.lastReset,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (period.present) {
      map['period'] = Variable<String>(period.value);
    }
    if (currentValue.present) {
      map['current_value'] = Variable<int>(currentValue.value);
    }
    if (targetValue.present) {
      map['target_value'] = Variable<int>(targetValue.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (lastReset.present) {
      map['last_reset'] = Variable<int>(lastReset.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GoalsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('period: $period, ')
          ..write('currentValue: $currentValue, ')
          ..write('targetValue: $targetValue, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastReset: $lastReset, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FocusLogsTable extends FocusLogs
    with TableInfo<$FocusLogsTable, FocusLog> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FocusLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _targetIdMeta = const VerificationMeta(
    'targetId',
  );
  @override
  late final GeneratedColumn<String> targetId = GeneratedColumn<String>(
    'target_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _targetTypeMeta = const VerificationMeta(
    'targetType',
  );
  @override
  late final GeneratedColumn<String> targetType = GeneratedColumn<String>(
    'target_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationSecondsMeta = const VerificationMeta(
    'durationSeconds',
  );
  @override
  late final GeneratedColumn<int> durationSeconds = GeneratedColumn<int>(
    'duration_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timestampMeta = const VerificationMeta(
    'timestamp',
  );
  @override
  late final GeneratedColumn<int> timestamp = GeneratedColumn<int>(
    'timestamp',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    targetId,
    targetType,
    durationSeconds,
    timestamp,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'focus_logs';
  @override
  VerificationContext validateIntegrity(
    Insertable<FocusLog> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('target_id')) {
      context.handle(
        _targetIdMeta,
        targetId.isAcceptableOrUnknown(data['target_id']!, _targetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_targetIdMeta);
    }
    if (data.containsKey('target_type')) {
      context.handle(
        _targetTypeMeta,
        targetType.isAcceptableOrUnknown(data['target_type']!, _targetTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_targetTypeMeta);
    }
    if (data.containsKey('duration_seconds')) {
      context.handle(
        _durationSecondsMeta,
        durationSeconds.isAcceptableOrUnknown(
          data['duration_seconds']!,
          _durationSecondsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_durationSecondsMeta);
    }
    if (data.containsKey('timestamp')) {
      context.handle(
        _timestampMeta,
        timestamp.isAcceptableOrUnknown(data['timestamp']!, _timestampMeta),
      );
    } else if (isInserting) {
      context.missing(_timestampMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  FocusLog map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FocusLog(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      targetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_id'],
      )!,
      targetType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_type'],
      )!,
      durationSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_seconds'],
      )!,
      timestamp: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}timestamp'],
      )!,
    );
  }

  @override
  $FocusLogsTable createAlias(String alias) {
    return $FocusLogsTable(attachedDatabase, alias);
  }
}

class FocusLog extends DataClass implements Insertable<FocusLog> {
  final int id;
  final String targetId;
  final String targetType;
  final int durationSeconds;
  final int timestamp;
  const FocusLog({
    required this.id,
    required this.targetId,
    required this.targetType,
    required this.durationSeconds,
    required this.timestamp,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['target_id'] = Variable<String>(targetId);
    map['target_type'] = Variable<String>(targetType);
    map['duration_seconds'] = Variable<int>(durationSeconds);
    map['timestamp'] = Variable<int>(timestamp);
    return map;
  }

  FocusLogsCompanion toCompanion(bool nullToAbsent) {
    return FocusLogsCompanion(
      id: Value(id),
      targetId: Value(targetId),
      targetType: Value(targetType),
      durationSeconds: Value(durationSeconds),
      timestamp: Value(timestamp),
    );
  }

  factory FocusLog.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FocusLog(
      id: serializer.fromJson<int>(json['id']),
      targetId: serializer.fromJson<String>(json['targetId']),
      targetType: serializer.fromJson<String>(json['targetType']),
      durationSeconds: serializer.fromJson<int>(json['durationSeconds']),
      timestamp: serializer.fromJson<int>(json['timestamp']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'targetId': serializer.toJson<String>(targetId),
      'targetType': serializer.toJson<String>(targetType),
      'durationSeconds': serializer.toJson<int>(durationSeconds),
      'timestamp': serializer.toJson<int>(timestamp),
    };
  }

  FocusLog copyWith({
    int? id,
    String? targetId,
    String? targetType,
    int? durationSeconds,
    int? timestamp,
  }) => FocusLog(
    id: id ?? this.id,
    targetId: targetId ?? this.targetId,
    targetType: targetType ?? this.targetType,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    timestamp: timestamp ?? this.timestamp,
  );
  FocusLog copyWithCompanion(FocusLogsCompanion data) {
    return FocusLog(
      id: data.id.present ? data.id.value : this.id,
      targetId: data.targetId.present ? data.targetId.value : this.targetId,
      targetType: data.targetType.present
          ? data.targetType.value
          : this.targetType,
      durationSeconds: data.durationSeconds.present
          ? data.durationSeconds.value
          : this.durationSeconds,
      timestamp: data.timestamp.present ? data.timestamp.value : this.timestamp,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FocusLog(')
          ..write('id: $id, ')
          ..write('targetId: $targetId, ')
          ..write('targetType: $targetType, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('timestamp: $timestamp')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, targetId, targetType, durationSeconds, timestamp);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FocusLog &&
          other.id == this.id &&
          other.targetId == this.targetId &&
          other.targetType == this.targetType &&
          other.durationSeconds == this.durationSeconds &&
          other.timestamp == this.timestamp);
}

class FocusLogsCompanion extends UpdateCompanion<FocusLog> {
  final Value<int> id;
  final Value<String> targetId;
  final Value<String> targetType;
  final Value<int> durationSeconds;
  final Value<int> timestamp;
  const FocusLogsCompanion({
    this.id = const Value.absent(),
    this.targetId = const Value.absent(),
    this.targetType = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.timestamp = const Value.absent(),
  });
  FocusLogsCompanion.insert({
    this.id = const Value.absent(),
    required String targetId,
    required String targetType,
    required int durationSeconds,
    required int timestamp,
  }) : targetId = Value(targetId),
       targetType = Value(targetType),
       durationSeconds = Value(durationSeconds),
       timestamp = Value(timestamp);
  static Insertable<FocusLog> custom({
    Expression<int>? id,
    Expression<String>? targetId,
    Expression<String>? targetType,
    Expression<int>? durationSeconds,
    Expression<int>? timestamp,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (targetId != null) 'target_id': targetId,
      if (targetType != null) 'target_type': targetType,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (timestamp != null) 'timestamp': timestamp,
    });
  }

  FocusLogsCompanion copyWith({
    Value<int>? id,
    Value<String>? targetId,
    Value<String>? targetType,
    Value<int>? durationSeconds,
    Value<int>? timestamp,
  }) {
    return FocusLogsCompanion(
      id: id ?? this.id,
      targetId: targetId ?? this.targetId,
      targetType: targetType ?? this.targetType,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (targetId.present) {
      map['target_id'] = Variable<String>(targetId.value);
    }
    if (targetType.present) {
      map['target_type'] = Variable<String>(targetType.value);
    }
    if (durationSeconds.present) {
      map['duration_seconds'] = Variable<int>(durationSeconds.value);
    }
    if (timestamp.present) {
      map['timestamp'] = Variable<int>(timestamp.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FocusLogsCompanion(')
          ..write('id: $id, ')
          ..write('targetId: $targetId, ')
          ..write('targetType: $targetType, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('timestamp: $timestamp')
          ..write(')'))
        .toString();
  }
}

class $CheckInTableTable extends CheckInTable
    with TableInfo<$CheckInTableTable, CheckInEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CheckInTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _energyMeta = const VerificationMeta('energy');
  @override
  late final GeneratedColumn<double> energy = GeneratedColumn<double>(
    'energy',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _focusMeta = const VerificationMeta('focus');
  @override
  late final GeneratedColumn<double> focus = GeneratedColumn<double>(
    'focus',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _motivationMeta = const VerificationMeta(
    'motivation',
  );
  @override
  late final GeneratedColumn<double> motivation = GeneratedColumn<double>(
    'motivation',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isSyncedMeta = const VerificationMeta(
    'isSynced',
  );
  @override
  late final GeneratedColumn<bool> isSynced = GeneratedColumn<bool>(
    'is_synced',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_synced" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    energy,
    focus,
    motivation,
    createdAt,
    isSynced,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'check_in_table';
  @override
  VerificationContext validateIntegrity(
    Insertable<CheckInEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('energy')) {
      context.handle(
        _energyMeta,
        energy.isAcceptableOrUnknown(data['energy']!, _energyMeta),
      );
    } else if (isInserting) {
      context.missing(_energyMeta);
    }
    if (data.containsKey('focus')) {
      context.handle(
        _focusMeta,
        focus.isAcceptableOrUnknown(data['focus']!, _focusMeta),
      );
    } else if (isInserting) {
      context.missing(_focusMeta);
    }
    if (data.containsKey('motivation')) {
      context.handle(
        _motivationMeta,
        motivation.isAcceptableOrUnknown(data['motivation']!, _motivationMeta),
      );
    } else if (isInserting) {
      context.missing(_motivationMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('is_synced')) {
      context.handle(
        _isSyncedMeta,
        isSynced.isAcceptableOrUnknown(data['is_synced']!, _isSyncedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CheckInEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CheckInEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      energy: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}energy'],
      )!,
      focus: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}focus'],
      )!,
      motivation: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}motivation'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      isSynced: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_synced'],
      )!,
    );
  }

  @override
  $CheckInTableTable createAlias(String alias) {
    return $CheckInTableTable(attachedDatabase, alias);
  }
}

class CheckInEntry extends DataClass implements Insertable<CheckInEntry> {
  final String id;
  final double energy;
  final double focus;
  final double motivation;
  final DateTime createdAt;
  final bool isSynced;
  const CheckInEntry({
    required this.id,
    required this.energy,
    required this.focus,
    required this.motivation,
    required this.createdAt,
    required this.isSynced,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['energy'] = Variable<double>(energy);
    map['focus'] = Variable<double>(focus);
    map['motivation'] = Variable<double>(motivation);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['is_synced'] = Variable<bool>(isSynced);
    return map;
  }

  CheckInTableCompanion toCompanion(bool nullToAbsent) {
    return CheckInTableCompanion(
      id: Value(id),
      energy: Value(energy),
      focus: Value(focus),
      motivation: Value(motivation),
      createdAt: Value(createdAt),
      isSynced: Value(isSynced),
    );
  }

  factory CheckInEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CheckInEntry(
      id: serializer.fromJson<String>(json['id']),
      energy: serializer.fromJson<double>(json['energy']),
      focus: serializer.fromJson<double>(json['focus']),
      motivation: serializer.fromJson<double>(json['motivation']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      isSynced: serializer.fromJson<bool>(json['isSynced']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'energy': serializer.toJson<double>(energy),
      'focus': serializer.toJson<double>(focus),
      'motivation': serializer.toJson<double>(motivation),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'isSynced': serializer.toJson<bool>(isSynced),
    };
  }

  CheckInEntry copyWith({
    String? id,
    double? energy,
    double? focus,
    double? motivation,
    DateTime? createdAt,
    bool? isSynced,
  }) => CheckInEntry(
    id: id ?? this.id,
    energy: energy ?? this.energy,
    focus: focus ?? this.focus,
    motivation: motivation ?? this.motivation,
    createdAt: createdAt ?? this.createdAt,
    isSynced: isSynced ?? this.isSynced,
  );
  CheckInEntry copyWithCompanion(CheckInTableCompanion data) {
    return CheckInEntry(
      id: data.id.present ? data.id.value : this.id,
      energy: data.energy.present ? data.energy.value : this.energy,
      focus: data.focus.present ? data.focus.value : this.focus,
      motivation: data.motivation.present
          ? data.motivation.value
          : this.motivation,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      isSynced: data.isSynced.present ? data.isSynced.value : this.isSynced,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CheckInEntry(')
          ..write('id: $id, ')
          ..write('energy: $energy, ')
          ..write('focus: $focus, ')
          ..write('motivation: $motivation, ')
          ..write('createdAt: $createdAt, ')
          ..write('isSynced: $isSynced')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, energy, focus, motivation, createdAt, isSynced);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CheckInEntry &&
          other.id == this.id &&
          other.energy == this.energy &&
          other.focus == this.focus &&
          other.motivation == this.motivation &&
          other.createdAt == this.createdAt &&
          other.isSynced == this.isSynced);
}

class CheckInTableCompanion extends UpdateCompanion<CheckInEntry> {
  final Value<String> id;
  final Value<double> energy;
  final Value<double> focus;
  final Value<double> motivation;
  final Value<DateTime> createdAt;
  final Value<bool> isSynced;
  final Value<int> rowid;
  const CheckInTableCompanion({
    this.id = const Value.absent(),
    this.energy = const Value.absent(),
    this.focus = const Value.absent(),
    this.motivation = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.isSynced = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CheckInTableCompanion.insert({
    required String id,
    required double energy,
    required double focus,
    required double motivation,
    required DateTime createdAt,
    this.isSynced = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       energy = Value(energy),
       focus = Value(focus),
       motivation = Value(motivation),
       createdAt = Value(createdAt);
  static Insertable<CheckInEntry> custom({
    Expression<String>? id,
    Expression<double>? energy,
    Expression<double>? focus,
    Expression<double>? motivation,
    Expression<DateTime>? createdAt,
    Expression<bool>? isSynced,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (energy != null) 'energy': energy,
      if (focus != null) 'focus': focus,
      if (motivation != null) 'motivation': motivation,
      if (createdAt != null) 'created_at': createdAt,
      if (isSynced != null) 'is_synced': isSynced,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CheckInTableCompanion copyWith({
    Value<String>? id,
    Value<double>? energy,
    Value<double>? focus,
    Value<double>? motivation,
    Value<DateTime>? createdAt,
    Value<bool>? isSynced,
    Value<int>? rowid,
  }) {
    return CheckInTableCompanion(
      id: id ?? this.id,
      energy: energy ?? this.energy,
      focus: focus ?? this.focus,
      motivation: motivation ?? this.motivation,
      createdAt: createdAt ?? this.createdAt,
      isSynced: isSynced ?? this.isSynced,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (energy.present) {
      map['energy'] = Variable<double>(energy.value);
    }
    if (focus.present) {
      map['focus'] = Variable<double>(focus.value);
    }
    if (motivation.present) {
      map['motivation'] = Variable<double>(motivation.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (isSynced.present) {
      map['is_synced'] = Variable<bool>(isSynced.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CheckInTableCompanion(')
          ..write('id: $id, ')
          ..write('energy: $energy, ')
          ..write('focus: $focus, ')
          ..write('motivation: $motivation, ')
          ..write('createdAt: $createdAt, ')
          ..write('isSynced: $isSynced, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $HealthEntriesTable healthEntries = $HealthEntriesTable(this);
  late final $MedicationsTable medications = $MedicationsTable(this);
  late final $TransactionsTable transactions = $TransactionsTable(this);
  late final $TaskTableTable taskTable = $TaskTableTable(this);
  late final $HabitsTable habits = $HabitsTable(this);
  late final $StudyStatsTable studyStats = $StudyStatsTable(this);
  late final $SubjectsTable subjects = $SubjectsTable(this);
  late final $FlashcardsTable flashcards = $FlashcardsTable(this);
  late final $GoalsTable goals = $GoalsTable(this);
  late final $FocusLogsTable focusLogs = $FocusLogsTable(this);
  late final $CheckInTableTable checkInTable = $CheckInTableTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    healthEntries,
    medications,
    transactions,
    taskTable,
    habits,
    studyStats,
    subjects,
    flashcards,
    goals,
    focusLogs,
    checkInTable,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'subjects',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('flashcards', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$HealthEntriesTableCreateCompanionBuilder =
    HealthEntriesCompanion Function({
      required String docId,
      Value<String> mood,
      Value<int> waterIntakeMl,
      Value<bool> hasTakenPillToday,
      Value<String?> menstrualCycleJson,
      required DateTime date,
      Value<int> rowid,
    });
typedef $$HealthEntriesTableUpdateCompanionBuilder =
    HealthEntriesCompanion Function({
      Value<String> docId,
      Value<String> mood,
      Value<int> waterIntakeMl,
      Value<bool> hasTakenPillToday,
      Value<String?> menstrualCycleJson,
      Value<DateTime> date,
      Value<int> rowid,
    });

class $$HealthEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $HealthEntriesTable> {
  $$HealthEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get docId => $composableBuilder(
    column: $table.docId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mood => $composableBuilder(
    column: $table.mood,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get waterIntakeMl => $composableBuilder(
    column: $table.waterIntakeMl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasTakenPillToday => $composableBuilder(
    column: $table.hasTakenPillToday,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get menstrualCycleJson => $composableBuilder(
    column: $table.menstrualCycleJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HealthEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $HealthEntriesTable> {
  $$HealthEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get docId => $composableBuilder(
    column: $table.docId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mood => $composableBuilder(
    column: $table.mood,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get waterIntakeMl => $composableBuilder(
    column: $table.waterIntakeMl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasTakenPillToday => $composableBuilder(
    column: $table.hasTakenPillToday,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get menstrualCycleJson => $composableBuilder(
    column: $table.menstrualCycleJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HealthEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $HealthEntriesTable> {
  $$HealthEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get docId =>
      $composableBuilder(column: $table.docId, builder: (column) => column);

  GeneratedColumn<String> get mood =>
      $composableBuilder(column: $table.mood, builder: (column) => column);

  GeneratedColumn<int> get waterIntakeMl => $composableBuilder(
    column: $table.waterIntakeMl,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get hasTakenPillToday => $composableBuilder(
    column: $table.hasTakenPillToday,
    builder: (column) => column,
  );

  GeneratedColumn<String> get menstrualCycleJson => $composableBuilder(
    column: $table.menstrualCycleJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);
}

class $$HealthEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $HealthEntriesTable,
          HealthEntry,
          $$HealthEntriesTableFilterComposer,
          $$HealthEntriesTableOrderingComposer,
          $$HealthEntriesTableAnnotationComposer,
          $$HealthEntriesTableCreateCompanionBuilder,
          $$HealthEntriesTableUpdateCompanionBuilder,
          (
            HealthEntry,
            BaseReferences<_$AppDatabase, $HealthEntriesTable, HealthEntry>,
          ),
          HealthEntry,
          PrefetchHooks Function()
        > {
  $$HealthEntriesTableTableManager(_$AppDatabase db, $HealthEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HealthEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HealthEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HealthEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> docId = const Value.absent(),
                Value<String> mood = const Value.absent(),
                Value<int> waterIntakeMl = const Value.absent(),
                Value<bool> hasTakenPillToday = const Value.absent(),
                Value<String?> menstrualCycleJson = const Value.absent(),
                Value<DateTime> date = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HealthEntriesCompanion(
                docId: docId,
                mood: mood,
                waterIntakeMl: waterIntakeMl,
                hasTakenPillToday: hasTakenPillToday,
                menstrualCycleJson: menstrualCycleJson,
                date: date,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String docId,
                Value<String> mood = const Value.absent(),
                Value<int> waterIntakeMl = const Value.absent(),
                Value<bool> hasTakenPillToday = const Value.absent(),
                Value<String?> menstrualCycleJson = const Value.absent(),
                required DateTime date,
                Value<int> rowid = const Value.absent(),
              }) => HealthEntriesCompanion.insert(
                docId: docId,
                mood: mood,
                waterIntakeMl: waterIntakeMl,
                hasTakenPillToday: hasTakenPillToday,
                menstrualCycleJson: menstrualCycleJson,
                date: date,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HealthEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $HealthEntriesTable,
      HealthEntry,
      $$HealthEntriesTableFilterComposer,
      $$HealthEntriesTableOrderingComposer,
      $$HealthEntriesTableAnnotationComposer,
      $$HealthEntriesTableCreateCompanionBuilder,
      $$HealthEntriesTableUpdateCompanionBuilder,
      (
        HealthEntry,
        BaseReferences<_$AppDatabase, $HealthEntriesTable, HealthEntry>,
      ),
      HealthEntry,
      PrefetchHooks Function()
    >;
typedef $$MedicationsTableCreateCompanionBuilder =
    MedicationsCompanion Function({
      Value<int> id,
      Value<String?> firestoreId,
      required String name,
      required DateTime startDate,
      Value<int?> durationDays,
      Value<DateTime?> endDate,
    });
typedef $$MedicationsTableUpdateCompanionBuilder =
    MedicationsCompanion Function({
      Value<int> id,
      Value<String?> firestoreId,
      Value<String> name,
      Value<DateTime> startDate,
      Value<int?> durationDays,
      Value<DateTime?> endDate,
    });

class $$MedicationsTableFilterComposer
    extends Composer<_$AppDatabase, $MedicationsTable> {
  $$MedicationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get firestoreId => $composableBuilder(
    column: $table.firestoreId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get startDate => $composableBuilder(
    column: $table.startDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationDays => $composableBuilder(
    column: $table.durationDays,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get endDate => $composableBuilder(
    column: $table.endDate,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MedicationsTableOrderingComposer
    extends Composer<_$AppDatabase, $MedicationsTable> {
  $$MedicationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get firestoreId => $composableBuilder(
    column: $table.firestoreId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get startDate => $composableBuilder(
    column: $table.startDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationDays => $composableBuilder(
    column: $table.durationDays,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get endDate => $composableBuilder(
    column: $table.endDate,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MedicationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MedicationsTable> {
  $$MedicationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get firestoreId => $composableBuilder(
    column: $table.firestoreId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<DateTime> get startDate =>
      $composableBuilder(column: $table.startDate, builder: (column) => column);

  GeneratedColumn<int> get durationDays => $composableBuilder(
    column: $table.durationDays,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get endDate =>
      $composableBuilder(column: $table.endDate, builder: (column) => column);
}

class $$MedicationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MedicationsTable,
          Medication,
          $$MedicationsTableFilterComposer,
          $$MedicationsTableOrderingComposer,
          $$MedicationsTableAnnotationComposer,
          $$MedicationsTableCreateCompanionBuilder,
          $$MedicationsTableUpdateCompanionBuilder,
          (
            Medication,
            BaseReferences<_$AppDatabase, $MedicationsTable, Medication>,
          ),
          Medication,
          PrefetchHooks Function()
        > {
  $$MedicationsTableTableManager(_$AppDatabase db, $MedicationsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MedicationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MedicationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MedicationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> firestoreId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<DateTime> startDate = const Value.absent(),
                Value<int?> durationDays = const Value.absent(),
                Value<DateTime?> endDate = const Value.absent(),
              }) => MedicationsCompanion(
                id: id,
                firestoreId: firestoreId,
                name: name,
                startDate: startDate,
                durationDays: durationDays,
                endDate: endDate,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> firestoreId = const Value.absent(),
                required String name,
                required DateTime startDate,
                Value<int?> durationDays = const Value.absent(),
                Value<DateTime?> endDate = const Value.absent(),
              }) => MedicationsCompanion.insert(
                id: id,
                firestoreId: firestoreId,
                name: name,
                startDate: startDate,
                durationDays: durationDays,
                endDate: endDate,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MedicationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MedicationsTable,
      Medication,
      $$MedicationsTableFilterComposer,
      $$MedicationsTableOrderingComposer,
      $$MedicationsTableAnnotationComposer,
      $$MedicationsTableCreateCompanionBuilder,
      $$MedicationsTableUpdateCompanionBuilder,
      (
        Medication,
        BaseReferences<_$AppDatabase, $MedicationsTable, Medication>,
      ),
      Medication,
      PrefetchHooks Function()
    >;
typedef $$TransactionsTableCreateCompanionBuilder =
    TransactionsCompanion Function({
      Value<int> id,
      Value<String?> firestoreId,
      required String title,
      required double amount,
      required String type,
      required String category,
      required DateTime date,
    });
typedef $$TransactionsTableUpdateCompanionBuilder =
    TransactionsCompanion Function({
      Value<int> id,
      Value<String?> firestoreId,
      Value<String> title,
      Value<double> amount,
      Value<String> type,
      Value<String> category,
      Value<DateTime> date,
    });

class $$TransactionsTableFilterComposer
    extends Composer<_$AppDatabase, $TransactionsTable> {
  $$TransactionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get firestoreId => $composableBuilder(
    column: $table.firestoreId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get amount => $composableBuilder(
    column: $table.amount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TransactionsTableOrderingComposer
    extends Composer<_$AppDatabase, $TransactionsTable> {
  $$TransactionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get firestoreId => $composableBuilder(
    column: $table.firestoreId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get amount => $composableBuilder(
    column: $table.amount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TransactionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TransactionsTable> {
  $$TransactionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get firestoreId => $composableBuilder(
    column: $table.firestoreId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<double> get amount =>
      $composableBuilder(column: $table.amount, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<DateTime> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);
}

class $$TransactionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TransactionsTable,
          Transaction,
          $$TransactionsTableFilterComposer,
          $$TransactionsTableOrderingComposer,
          $$TransactionsTableAnnotationComposer,
          $$TransactionsTableCreateCompanionBuilder,
          $$TransactionsTableUpdateCompanionBuilder,
          (
            Transaction,
            BaseReferences<_$AppDatabase, $TransactionsTable, Transaction>,
          ),
          Transaction,
          PrefetchHooks Function()
        > {
  $$TransactionsTableTableManager(_$AppDatabase db, $TransactionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TransactionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TransactionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TransactionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> firestoreId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<double> amount = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> category = const Value.absent(),
                Value<DateTime> date = const Value.absent(),
              }) => TransactionsCompanion(
                id: id,
                firestoreId: firestoreId,
                title: title,
                amount: amount,
                type: type,
                category: category,
                date: date,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> firestoreId = const Value.absent(),
                required String title,
                required double amount,
                required String type,
                required String category,
                required DateTime date,
              }) => TransactionsCompanion.insert(
                id: id,
                firestoreId: firestoreId,
                title: title,
                amount: amount,
                type: type,
                category: category,
                date: date,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TransactionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TransactionsTable,
      Transaction,
      $$TransactionsTableFilterComposer,
      $$TransactionsTableOrderingComposer,
      $$TransactionsTableAnnotationComposer,
      $$TransactionsTableCreateCompanionBuilder,
      $$TransactionsTableUpdateCompanionBuilder,
      (
        Transaction,
        BaseReferences<_$AppDatabase, $TransactionsTable, Transaction>,
      ),
      Transaction,
      PrefetchHooks Function()
    >;
typedef $$TaskTableTableCreateCompanionBuilder =
    TaskTableCompanion Function({
      required String id,
      required String title,
      required String priority,
      Value<bool> isCompleted,
      required DateTime date,
      Value<int> rowid,
    });
typedef $$TaskTableTableUpdateCompanionBuilder =
    TaskTableCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String> priority,
      Value<bool> isCompleted,
      Value<DateTime> date,
      Value<int> rowid,
    });

class $$TaskTableTableFilterComposer
    extends Composer<_$AppDatabase, $TaskTableTable> {
  $$TaskTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isCompleted => $composableBuilder(
    column: $table.isCompleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TaskTableTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskTableTable> {
  $$TaskTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isCompleted => $composableBuilder(
    column: $table.isCompleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get date => $composableBuilder(
    column: $table.date,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TaskTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskTableTable> {
  $$TaskTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get priority =>
      $composableBuilder(column: $table.priority, builder: (column) => column);

  GeneratedColumn<bool> get isCompleted => $composableBuilder(
    column: $table.isCompleted,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get date =>
      $composableBuilder(column: $table.date, builder: (column) => column);
}

class $$TaskTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskTableTable,
          TaskTableData,
          $$TaskTableTableFilterComposer,
          $$TaskTableTableOrderingComposer,
          $$TaskTableTableAnnotationComposer,
          $$TaskTableTableCreateCompanionBuilder,
          $$TaskTableTableUpdateCompanionBuilder,
          (
            TaskTableData,
            BaseReferences<_$AppDatabase, $TaskTableTable, TaskTableData>,
          ),
          TaskTableData,
          PrefetchHooks Function()
        > {
  $$TaskTableTableTableManager(_$AppDatabase db, $TaskTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TaskTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TaskTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> priority = const Value.absent(),
                Value<bool> isCompleted = const Value.absent(),
                Value<DateTime> date = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskTableCompanion(
                id: id,
                title: title,
                priority: priority,
                isCompleted: isCompleted,
                date: date,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required String priority,
                Value<bool> isCompleted = const Value.absent(),
                required DateTime date,
                Value<int> rowid = const Value.absent(),
              }) => TaskTableCompanion.insert(
                id: id,
                title: title,
                priority: priority,
                isCompleted: isCompleted,
                date: date,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TaskTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskTableTable,
      TaskTableData,
      $$TaskTableTableFilterComposer,
      $$TaskTableTableOrderingComposer,
      $$TaskTableTableAnnotationComposer,
      $$TaskTableTableCreateCompanionBuilder,
      $$TaskTableTableUpdateCompanionBuilder,
      (
        TaskTableData,
        BaseReferences<_$AppDatabase, $TaskTableTable, TaskTableData>,
      ),
      TaskTableData,
      PrefetchHooks Function()
    >;
typedef $$HabitsTableCreateCompanionBuilder =
    HabitsCompanion Function({
      required String id,
      required String title,
      required String completedDates,
      Value<int> rowid,
    });
typedef $$HabitsTableUpdateCompanionBuilder =
    HabitsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String> completedDates,
      Value<int> rowid,
    });

class $$HabitsTableFilterComposer
    extends Composer<_$AppDatabase, $HabitsTable> {
  $$HabitsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get completedDates => $composableBuilder(
    column: $table.completedDates,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HabitsTableOrderingComposer
    extends Composer<_$AppDatabase, $HabitsTable> {
  $$HabitsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get completedDates => $composableBuilder(
    column: $table.completedDates,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HabitsTableAnnotationComposer
    extends Composer<_$AppDatabase, $HabitsTable> {
  $$HabitsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get completedDates => $composableBuilder(
    column: $table.completedDates,
    builder: (column) => column,
  );
}

class $$HabitsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $HabitsTable,
          Habit,
          $$HabitsTableFilterComposer,
          $$HabitsTableOrderingComposer,
          $$HabitsTableAnnotationComposer,
          $$HabitsTableCreateCompanionBuilder,
          $$HabitsTableUpdateCompanionBuilder,
          (Habit, BaseReferences<_$AppDatabase, $HabitsTable, Habit>),
          Habit,
          PrefetchHooks Function()
        > {
  $$HabitsTableTableManager(_$AppDatabase db, $HabitsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HabitsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HabitsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HabitsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> completedDates = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HabitsCompanion(
                id: id,
                title: title,
                completedDates: completedDates,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required String completedDates,
                Value<int> rowid = const Value.absent(),
              }) => HabitsCompanion.insert(
                id: id,
                title: title,
                completedDates: completedDates,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HabitsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $HabitsTable,
      Habit,
      $$HabitsTableFilterComposer,
      $$HabitsTableOrderingComposer,
      $$HabitsTableAnnotationComposer,
      $$HabitsTableCreateCompanionBuilder,
      $$HabitsTableUpdateCompanionBuilder,
      (Habit, BaseReferences<_$AppDatabase, $HabitsTable, Habit>),
      Habit,
      PrefetchHooks Function()
    >;
typedef $$StudyStatsTableCreateCompanionBuilder =
    StudyStatsCompanion Function({
      required String id,
      required int streak,
      required int reviewQueue,
      required double progress,
      Value<int?> lastStudyDate,
      Value<int> rowid,
    });
typedef $$StudyStatsTableUpdateCompanionBuilder =
    StudyStatsCompanion Function({
      Value<String> id,
      Value<int> streak,
      Value<int> reviewQueue,
      Value<double> progress,
      Value<int?> lastStudyDate,
      Value<int> rowid,
    });

class $$StudyStatsTableFilterComposer
    extends Composer<_$AppDatabase, $StudyStatsTable> {
  $$StudyStatsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get streak => $composableBuilder(
    column: $table.streak,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reviewQueue => $composableBuilder(
    column: $table.reviewQueue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastStudyDate => $composableBuilder(
    column: $table.lastStudyDate,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StudyStatsTableOrderingComposer
    extends Composer<_$AppDatabase, $StudyStatsTable> {
  $$StudyStatsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get streak => $composableBuilder(
    column: $table.streak,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reviewQueue => $composableBuilder(
    column: $table.reviewQueue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastStudyDate => $composableBuilder(
    column: $table.lastStudyDate,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StudyStatsTableAnnotationComposer
    extends Composer<_$AppDatabase, $StudyStatsTable> {
  $$StudyStatsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get streak =>
      $composableBuilder(column: $table.streak, builder: (column) => column);

  GeneratedColumn<int> get reviewQueue => $composableBuilder(
    column: $table.reviewQueue,
    builder: (column) => column,
  );

  GeneratedColumn<double> get progress =>
      $composableBuilder(column: $table.progress, builder: (column) => column);

  GeneratedColumn<int> get lastStudyDate => $composableBuilder(
    column: $table.lastStudyDate,
    builder: (column) => column,
  );
}

class $$StudyStatsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $StudyStatsTable,
          StudyStat,
          $$StudyStatsTableFilterComposer,
          $$StudyStatsTableOrderingComposer,
          $$StudyStatsTableAnnotationComposer,
          $$StudyStatsTableCreateCompanionBuilder,
          $$StudyStatsTableUpdateCompanionBuilder,
          (
            StudyStat,
            BaseReferences<_$AppDatabase, $StudyStatsTable, StudyStat>,
          ),
          StudyStat,
          PrefetchHooks Function()
        > {
  $$StudyStatsTableTableManager(_$AppDatabase db, $StudyStatsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StudyStatsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StudyStatsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StudyStatsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> streak = const Value.absent(),
                Value<int> reviewQueue = const Value.absent(),
                Value<double> progress = const Value.absent(),
                Value<int?> lastStudyDate = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StudyStatsCompanion(
                id: id,
                streak: streak,
                reviewQueue: reviewQueue,
                progress: progress,
                lastStudyDate: lastStudyDate,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int streak,
                required int reviewQueue,
                required double progress,
                Value<int?> lastStudyDate = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StudyStatsCompanion.insert(
                id: id,
                streak: streak,
                reviewQueue: reviewQueue,
                progress: progress,
                lastStudyDate: lastStudyDate,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StudyStatsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $StudyStatsTable,
      StudyStat,
      $$StudyStatsTableFilterComposer,
      $$StudyStatsTableOrderingComposer,
      $$StudyStatsTableAnnotationComposer,
      $$StudyStatsTableCreateCompanionBuilder,
      $$StudyStatsTableUpdateCompanionBuilder,
      (StudyStat, BaseReferences<_$AppDatabase, $StudyStatsTable, StudyStat>),
      StudyStat,
      PrefetchHooks Function()
    >;
typedef $$SubjectsTableCreateCompanionBuilder =
    SubjectsCompanion Function({
      required String id,
      required String title,
      required int cardsToReview,
      required int streakDays,
      required double progress,
      required bool hasExam,
      Value<int?> examDate,
      Value<int> rowid,
    });
typedef $$SubjectsTableUpdateCompanionBuilder =
    SubjectsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<int> cardsToReview,
      Value<int> streakDays,
      Value<double> progress,
      Value<bool> hasExam,
      Value<int?> examDate,
      Value<int> rowid,
    });

final class $$SubjectsTableReferences
    extends BaseReferences<_$AppDatabase, $SubjectsTable, Subject> {
  $$SubjectsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$FlashcardsTable, List<Flashcard>>
  _flashcardsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.flashcards,
    aliasName: 'subjects__id__flashcards__subject_id',
  );

  $$FlashcardsTableProcessedTableManager get flashcardsRefs {
    final manager = $$FlashcardsTableTableManager(
      $_db,
      $_db.flashcards,
    ).filter((f) => f.subjectId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_flashcardsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SubjectsTableFilterComposer
    extends Composer<_$AppDatabase, $SubjectsTable> {
  $$SubjectsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cardsToReview => $composableBuilder(
    column: $table.cardsToReview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get streakDays => $composableBuilder(
    column: $table.streakDays,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasExam => $composableBuilder(
    column: $table.hasExam,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get examDate => $composableBuilder(
    column: $table.examDate,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> flashcardsRefs(
    Expression<bool> Function($$FlashcardsTableFilterComposer f) f,
  ) {
    final $$FlashcardsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.flashcards,
      getReferencedColumn: (t) => t.subjectId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FlashcardsTableFilterComposer(
            $db: $db,
            $table: $db.flashcards,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SubjectsTableOrderingComposer
    extends Composer<_$AppDatabase, $SubjectsTable> {
  $$SubjectsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cardsToReview => $composableBuilder(
    column: $table.cardsToReview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get streakDays => $composableBuilder(
    column: $table.streakDays,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasExam => $composableBuilder(
    column: $table.hasExam,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get examDate => $composableBuilder(
    column: $table.examDate,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SubjectsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SubjectsTable> {
  $$SubjectsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get cardsToReview => $composableBuilder(
    column: $table.cardsToReview,
    builder: (column) => column,
  );

  GeneratedColumn<int> get streakDays => $composableBuilder(
    column: $table.streakDays,
    builder: (column) => column,
  );

  GeneratedColumn<double> get progress =>
      $composableBuilder(column: $table.progress, builder: (column) => column);

  GeneratedColumn<bool> get hasExam =>
      $composableBuilder(column: $table.hasExam, builder: (column) => column);

  GeneratedColumn<int> get examDate =>
      $composableBuilder(column: $table.examDate, builder: (column) => column);

  Expression<T> flashcardsRefs<T extends Object>(
    Expression<T> Function($$FlashcardsTableAnnotationComposer a) f,
  ) {
    final $$FlashcardsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.flashcards,
      getReferencedColumn: (t) => t.subjectId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FlashcardsTableAnnotationComposer(
            $db: $db,
            $table: $db.flashcards,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SubjectsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SubjectsTable,
          Subject,
          $$SubjectsTableFilterComposer,
          $$SubjectsTableOrderingComposer,
          $$SubjectsTableAnnotationComposer,
          $$SubjectsTableCreateCompanionBuilder,
          $$SubjectsTableUpdateCompanionBuilder,
          (Subject, $$SubjectsTableReferences),
          Subject,
          PrefetchHooks Function({bool flashcardsRefs})
        > {
  $$SubjectsTableTableManager(_$AppDatabase db, $SubjectsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SubjectsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SubjectsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SubjectsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int> cardsToReview = const Value.absent(),
                Value<int> streakDays = const Value.absent(),
                Value<double> progress = const Value.absent(),
                Value<bool> hasExam = const Value.absent(),
                Value<int?> examDate = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SubjectsCompanion(
                id: id,
                title: title,
                cardsToReview: cardsToReview,
                streakDays: streakDays,
                progress: progress,
                hasExam: hasExam,
                examDate: examDate,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required int cardsToReview,
                required int streakDays,
                required double progress,
                required bool hasExam,
                Value<int?> examDate = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SubjectsCompanion.insert(
                id: id,
                title: title,
                cardsToReview: cardsToReview,
                streakDays: streakDays,
                progress: progress,
                hasExam: hasExam,
                examDate: examDate,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SubjectsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({flashcardsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (flashcardsRefs) db.flashcards],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (flashcardsRefs)
                    await $_getPrefetchedData<
                      Subject,
                      $SubjectsTable,
                      Flashcard
                    >(
                      currentTable: table,
                      referencedTable: $$SubjectsTableReferences
                          ._flashcardsRefsTable(db),
                      managerFromTypedResult: (p0) => $$SubjectsTableReferences(
                        db,
                        table,
                        p0,
                      ).flashcardsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.subjectId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$SubjectsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SubjectsTable,
      Subject,
      $$SubjectsTableFilterComposer,
      $$SubjectsTableOrderingComposer,
      $$SubjectsTableAnnotationComposer,
      $$SubjectsTableCreateCompanionBuilder,
      $$SubjectsTableUpdateCompanionBuilder,
      (Subject, $$SubjectsTableReferences),
      Subject,
      PrefetchHooks Function({bool flashcardsRefs})
    >;
typedef $$FlashcardsTableCreateCompanionBuilder =
    FlashcardsCompanion Function({
      required String id,
      required String subjectId,
      required String question,
      required String answer,
      Value<int?> lastReviewed,
      Value<int> rowid,
    });
typedef $$FlashcardsTableUpdateCompanionBuilder =
    FlashcardsCompanion Function({
      Value<String> id,
      Value<String> subjectId,
      Value<String> question,
      Value<String> answer,
      Value<int?> lastReviewed,
      Value<int> rowid,
    });

final class $$FlashcardsTableReferences
    extends BaseReferences<_$AppDatabase, $FlashcardsTable, Flashcard> {
  $$FlashcardsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SubjectsTable _subjectIdTable(_$AppDatabase db) =>
      db.subjects.createAlias('flashcards__subject_id__subjects__id');

  $$SubjectsTableProcessedTableManager get subjectId {
    final $_column = $_itemColumn<String>('subject_id')!;

    final manager = $$SubjectsTableTableManager(
      $_db,
      $_db.subjects,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_subjectIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$FlashcardsTableFilterComposer
    extends Composer<_$AppDatabase, $FlashcardsTable> {
  $$FlashcardsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get question => $composableBuilder(
    column: $table.question,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get answer => $composableBuilder(
    column: $table.answer,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastReviewed => $composableBuilder(
    column: $table.lastReviewed,
    builder: (column) => ColumnFilters(column),
  );

  $$SubjectsTableFilterComposer get subjectId {
    final $$SubjectsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.subjectId,
      referencedTable: $db.subjects,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SubjectsTableFilterComposer(
            $db: $db,
            $table: $db.subjects,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FlashcardsTableOrderingComposer
    extends Composer<_$AppDatabase, $FlashcardsTable> {
  $$FlashcardsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get question => $composableBuilder(
    column: $table.question,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get answer => $composableBuilder(
    column: $table.answer,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastReviewed => $composableBuilder(
    column: $table.lastReviewed,
    builder: (column) => ColumnOrderings(column),
  );

  $$SubjectsTableOrderingComposer get subjectId {
    final $$SubjectsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.subjectId,
      referencedTable: $db.subjects,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SubjectsTableOrderingComposer(
            $db: $db,
            $table: $db.subjects,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FlashcardsTableAnnotationComposer
    extends Composer<_$AppDatabase, $FlashcardsTable> {
  $$FlashcardsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get question =>
      $composableBuilder(column: $table.question, builder: (column) => column);

  GeneratedColumn<String> get answer =>
      $composableBuilder(column: $table.answer, builder: (column) => column);

  GeneratedColumn<int> get lastReviewed => $composableBuilder(
    column: $table.lastReviewed,
    builder: (column) => column,
  );

  $$SubjectsTableAnnotationComposer get subjectId {
    final $$SubjectsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.subjectId,
      referencedTable: $db.subjects,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SubjectsTableAnnotationComposer(
            $db: $db,
            $table: $db.subjects,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FlashcardsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $FlashcardsTable,
          Flashcard,
          $$FlashcardsTableFilterComposer,
          $$FlashcardsTableOrderingComposer,
          $$FlashcardsTableAnnotationComposer,
          $$FlashcardsTableCreateCompanionBuilder,
          $$FlashcardsTableUpdateCompanionBuilder,
          (Flashcard, $$FlashcardsTableReferences),
          Flashcard,
          PrefetchHooks Function({bool subjectId})
        > {
  $$FlashcardsTableTableManager(_$AppDatabase db, $FlashcardsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FlashcardsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FlashcardsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FlashcardsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> subjectId = const Value.absent(),
                Value<String> question = const Value.absent(),
                Value<String> answer = const Value.absent(),
                Value<int?> lastReviewed = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FlashcardsCompanion(
                id: id,
                subjectId: subjectId,
                question: question,
                answer: answer,
                lastReviewed: lastReviewed,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String subjectId,
                required String question,
                required String answer,
                Value<int?> lastReviewed = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FlashcardsCompanion.insert(
                id: id,
                subjectId: subjectId,
                question: question,
                answer: answer,
                lastReviewed: lastReviewed,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$FlashcardsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({subjectId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (subjectId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.subjectId,
                                referencedTable: $$FlashcardsTableReferences
                                    ._subjectIdTable(db),
                                referencedColumn: $$FlashcardsTableReferences
                                    ._subjectIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$FlashcardsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $FlashcardsTable,
      Flashcard,
      $$FlashcardsTableFilterComposer,
      $$FlashcardsTableOrderingComposer,
      $$FlashcardsTableAnnotationComposer,
      $$FlashcardsTableCreateCompanionBuilder,
      $$FlashcardsTableUpdateCompanionBuilder,
      (Flashcard, $$FlashcardsTableReferences),
      Flashcard,
      PrefetchHooks Function({bool subjectId})
    >;
typedef $$GoalsTableCreateCompanionBuilder =
    GoalsCompanion Function({
      required String id,
      required String title,
      required String period,
      required int currentValue,
      required int targetValue,
      required int createdAt,
      required int lastReset,
      Value<int> rowid,
    });
typedef $$GoalsTableUpdateCompanionBuilder =
    GoalsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String> period,
      Value<int> currentValue,
      Value<int> targetValue,
      Value<int> createdAt,
      Value<int> lastReset,
      Value<int> rowid,
    });

class $$GoalsTableFilterComposer extends Composer<_$AppDatabase, $GoalsTable> {
  $$GoalsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get period => $composableBuilder(
    column: $table.period,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get currentValue => $composableBuilder(
    column: $table.currentValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get targetValue => $composableBuilder(
    column: $table.targetValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastReset => $composableBuilder(
    column: $table.lastReset,
    builder: (column) => ColumnFilters(column),
  );
}

class $$GoalsTableOrderingComposer
    extends Composer<_$AppDatabase, $GoalsTable> {
  $$GoalsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get period => $composableBuilder(
    column: $table.period,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get currentValue => $composableBuilder(
    column: $table.currentValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get targetValue => $composableBuilder(
    column: $table.targetValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastReset => $composableBuilder(
    column: $table.lastReset,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GoalsTableAnnotationComposer
    extends Composer<_$AppDatabase, $GoalsTable> {
  $$GoalsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get period =>
      $composableBuilder(column: $table.period, builder: (column) => column);

  GeneratedColumn<int> get currentValue => $composableBuilder(
    column: $table.currentValue,
    builder: (column) => column,
  );

  GeneratedColumn<int> get targetValue => $composableBuilder(
    column: $table.targetValue,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get lastReset =>
      $composableBuilder(column: $table.lastReset, builder: (column) => column);
}

class $$GoalsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GoalsTable,
          Goal,
          $$GoalsTableFilterComposer,
          $$GoalsTableOrderingComposer,
          $$GoalsTableAnnotationComposer,
          $$GoalsTableCreateCompanionBuilder,
          $$GoalsTableUpdateCompanionBuilder,
          (Goal, BaseReferences<_$AppDatabase, $GoalsTable, Goal>),
          Goal,
          PrefetchHooks Function()
        > {
  $$GoalsTableTableManager(_$AppDatabase db, $GoalsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GoalsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GoalsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GoalsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> period = const Value.absent(),
                Value<int> currentValue = const Value.absent(),
                Value<int> targetValue = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> lastReset = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GoalsCompanion(
                id: id,
                title: title,
                period: period,
                currentValue: currentValue,
                targetValue: targetValue,
                createdAt: createdAt,
                lastReset: lastReset,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required String period,
                required int currentValue,
                required int targetValue,
                required int createdAt,
                required int lastReset,
                Value<int> rowid = const Value.absent(),
              }) => GoalsCompanion.insert(
                id: id,
                title: title,
                period: period,
                currentValue: currentValue,
                targetValue: targetValue,
                createdAt: createdAt,
                lastReset: lastReset,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$GoalsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GoalsTable,
      Goal,
      $$GoalsTableFilterComposer,
      $$GoalsTableOrderingComposer,
      $$GoalsTableAnnotationComposer,
      $$GoalsTableCreateCompanionBuilder,
      $$GoalsTableUpdateCompanionBuilder,
      (Goal, BaseReferences<_$AppDatabase, $GoalsTable, Goal>),
      Goal,
      PrefetchHooks Function()
    >;
typedef $$FocusLogsTableCreateCompanionBuilder =
    FocusLogsCompanion Function({
      Value<int> id,
      required String targetId,
      required String targetType,
      required int durationSeconds,
      required int timestamp,
    });
typedef $$FocusLogsTableUpdateCompanionBuilder =
    FocusLogsCompanion Function({
      Value<int> id,
      Value<String> targetId,
      Value<String> targetType,
      Value<int> durationSeconds,
      Value<int> timestamp,
    });

class $$FocusLogsTableFilterComposer
    extends Composer<_$AppDatabase, $FocusLogsTable> {
  $$FocusLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FocusLogsTableOrderingComposer
    extends Composer<_$AppDatabase, $FocusLogsTable> {
  $$FocusLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetId => $composableBuilder(
    column: $table.targetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get timestamp => $composableBuilder(
    column: $table.timestamp,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FocusLogsTableAnnotationComposer
    extends Composer<_$AppDatabase, $FocusLogsTable> {
  $$FocusLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get targetId =>
      $composableBuilder(column: $table.targetId, builder: (column) => column);

  GeneratedColumn<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<int> get timestamp =>
      $composableBuilder(column: $table.timestamp, builder: (column) => column);
}

class $$FocusLogsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $FocusLogsTable,
          FocusLog,
          $$FocusLogsTableFilterComposer,
          $$FocusLogsTableOrderingComposer,
          $$FocusLogsTableAnnotationComposer,
          $$FocusLogsTableCreateCompanionBuilder,
          $$FocusLogsTableUpdateCompanionBuilder,
          (FocusLog, BaseReferences<_$AppDatabase, $FocusLogsTable, FocusLog>),
          FocusLog,
          PrefetchHooks Function()
        > {
  $$FocusLogsTableTableManager(_$AppDatabase db, $FocusLogsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FocusLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FocusLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FocusLogsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> targetId = const Value.absent(),
                Value<String> targetType = const Value.absent(),
                Value<int> durationSeconds = const Value.absent(),
                Value<int> timestamp = const Value.absent(),
              }) => FocusLogsCompanion(
                id: id,
                targetId: targetId,
                targetType: targetType,
                durationSeconds: durationSeconds,
                timestamp: timestamp,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String targetId,
                required String targetType,
                required int durationSeconds,
                required int timestamp,
              }) => FocusLogsCompanion.insert(
                id: id,
                targetId: targetId,
                targetType: targetType,
                durationSeconds: durationSeconds,
                timestamp: timestamp,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FocusLogsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $FocusLogsTable,
      FocusLog,
      $$FocusLogsTableFilterComposer,
      $$FocusLogsTableOrderingComposer,
      $$FocusLogsTableAnnotationComposer,
      $$FocusLogsTableCreateCompanionBuilder,
      $$FocusLogsTableUpdateCompanionBuilder,
      (FocusLog, BaseReferences<_$AppDatabase, $FocusLogsTable, FocusLog>),
      FocusLog,
      PrefetchHooks Function()
    >;
typedef $$CheckInTableTableCreateCompanionBuilder =
    CheckInTableCompanion Function({
      required String id,
      required double energy,
      required double focus,
      required double motivation,
      required DateTime createdAt,
      Value<bool> isSynced,
      Value<int> rowid,
    });
typedef $$CheckInTableTableUpdateCompanionBuilder =
    CheckInTableCompanion Function({
      Value<String> id,
      Value<double> energy,
      Value<double> focus,
      Value<double> motivation,
      Value<DateTime> createdAt,
      Value<bool> isSynced,
      Value<int> rowid,
    });

class $$CheckInTableTableFilterComposer
    extends Composer<_$AppDatabase, $CheckInTableTable> {
  $$CheckInTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get energy => $composableBuilder(
    column: $table.energy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get focus => $composableBuilder(
    column: $table.focus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get motivation => $composableBuilder(
    column: $table.motivation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isSynced => $composableBuilder(
    column: $table.isSynced,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CheckInTableTableOrderingComposer
    extends Composer<_$AppDatabase, $CheckInTableTable> {
  $$CheckInTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get energy => $composableBuilder(
    column: $table.energy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get focus => $composableBuilder(
    column: $table.focus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get motivation => $composableBuilder(
    column: $table.motivation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isSynced => $composableBuilder(
    column: $table.isSynced,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CheckInTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $CheckInTableTable> {
  $$CheckInTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<double> get energy =>
      $composableBuilder(column: $table.energy, builder: (column) => column);

  GeneratedColumn<double> get focus =>
      $composableBuilder(column: $table.focus, builder: (column) => column);

  GeneratedColumn<double> get motivation => $composableBuilder(
    column: $table.motivation,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<bool> get isSynced =>
      $composableBuilder(column: $table.isSynced, builder: (column) => column);
}

class $$CheckInTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CheckInTableTable,
          CheckInEntry,
          $$CheckInTableTableFilterComposer,
          $$CheckInTableTableOrderingComposer,
          $$CheckInTableTableAnnotationComposer,
          $$CheckInTableTableCreateCompanionBuilder,
          $$CheckInTableTableUpdateCompanionBuilder,
          (
            CheckInEntry,
            BaseReferences<_$AppDatabase, $CheckInTableTable, CheckInEntry>,
          ),
          CheckInEntry,
          PrefetchHooks Function()
        > {
  $$CheckInTableTableTableManager(_$AppDatabase db, $CheckInTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CheckInTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CheckInTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CheckInTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<double> energy = const Value.absent(),
                Value<double> focus = const Value.absent(),
                Value<double> motivation = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<bool> isSynced = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CheckInTableCompanion(
                id: id,
                energy: energy,
                focus: focus,
                motivation: motivation,
                createdAt: createdAt,
                isSynced: isSynced,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required double energy,
                required double focus,
                required double motivation,
                required DateTime createdAt,
                Value<bool> isSynced = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CheckInTableCompanion.insert(
                id: id,
                energy: energy,
                focus: focus,
                motivation: motivation,
                createdAt: createdAt,
                isSynced: isSynced,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CheckInTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CheckInTableTable,
      CheckInEntry,
      $$CheckInTableTableFilterComposer,
      $$CheckInTableTableOrderingComposer,
      $$CheckInTableTableAnnotationComposer,
      $$CheckInTableTableCreateCompanionBuilder,
      $$CheckInTableTableUpdateCompanionBuilder,
      (
        CheckInEntry,
        BaseReferences<_$AppDatabase, $CheckInTableTable, CheckInEntry>,
      ),
      CheckInEntry,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$HealthEntriesTableTableManager get healthEntries =>
      $$HealthEntriesTableTableManager(_db, _db.healthEntries);
  $$MedicationsTableTableManager get medications =>
      $$MedicationsTableTableManager(_db, _db.medications);
  $$TransactionsTableTableManager get transactions =>
      $$TransactionsTableTableManager(_db, _db.transactions);
  $$TaskTableTableTableManager get taskTable =>
      $$TaskTableTableTableManager(_db, _db.taskTable);
  $$HabitsTableTableManager get habits =>
      $$HabitsTableTableManager(_db, _db.habits);
  $$StudyStatsTableTableManager get studyStats =>
      $$StudyStatsTableTableManager(_db, _db.studyStats);
  $$SubjectsTableTableManager get subjects =>
      $$SubjectsTableTableManager(_db, _db.subjects);
  $$FlashcardsTableTableManager get flashcards =>
      $$FlashcardsTableTableManager(_db, _db.flashcards);
  $$GoalsTableTableManager get goals =>
      $$GoalsTableTableManager(_db, _db.goals);
  $$FocusLogsTableTableManager get focusLogs =>
      $$FocusLogsTableTableManager(_db, _db.focusLogs);
  $$CheckInTableTableTableManager get checkInTable =>
      $$CheckInTableTableTableManager(_db, _db.checkInTable);
}
