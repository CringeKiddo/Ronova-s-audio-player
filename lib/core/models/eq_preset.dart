import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A 16-band parametric EQ preset with 808 sub-bass, stereo width and pre-amp trim dials.
///
/// * [bandGainsDb]: exactly [bandCount] gains, each clamped to +/-[maxGainDb].
/// * [subBass]: 808 sub-bass exciter amount, 0.0 .. 1.0.
/// * [stereoWidth]: 0.0 (mono) .. 2.0 (extra wide); 1.0 is neutral.
/// * [preampDb]: pre-amp trim in front of the EQ, -12 .. +12 dB.
@immutable
class EqPreset {
  EqPreset({
    required this.id,
    required this.name,
    required List<double> bandGainsDb,
    double subBass = 0.0,
    double stereoWidth = 1.0,
    double preampDb = 0.0,
    this.isFavorite = false,
    this.isBuiltIn = false,
  })  : bandGainsDb = List<double>.unmodifiable(_normalizeBands(bandGainsDb)),
        subBass = subBass.clamp(0.0, 1.0).toDouble(),
        stereoWidth = stereoWidth.clamp(0.0, 2.0).toDouble(),
        preampDb = preampDb.isNaN ? 0.0 : preampDb.clamp(minPreampDb, maxPreampDb).toDouble();

  static const int bandCount = 16;
  static const double minGainDb = -12.0;
  static const double maxGainDb = 12.0;
  static const double minPreampDb = -12.0;
  static const double maxPreampDb = 12.0;
  static const double defaultQ = 1.41;

  /// Center frequency of each of the 16 bands in Hz (20 Hz .. 16 kHz).
  static const List<double> bandFrequenciesHz = <double>[
    20, 32, 50, 80, 125, 200, 315, 500, //
    800, 1250, 2000, 3150, 5000, 8000, 12500, 16000,
  ];

  final String id;
  final String name;
  final List<double> bandGainsDb;
  final double subBass;
  final double stereoWidth;
  final double preampDb;
  final bool isFavorite;
  final bool isBuiltIn;

  /// Neutral preset: all bands 0 dB, no sub-bass boost, neutral width.
  factory EqPreset.flat() {
    return EqPreset(
      id: 'flat',
      name: 'Flat',
      bandGainsDb: List<double>.filled(bandCount, 0.0),
      isBuiltIn: true,
    );
  }

  static List<double> _normalizeBands(List<double> input) {
    final result = List<double>.filled(bandCount, 0.0);
    for (var i = 0; i < bandCount && i < input.length; i++) {
      final value = input[i];
      result[i] = value.isNaN ? 0.0 : value.clamp(minGainDb, maxGainDb).toDouble();
    }
    return result;
  }

  EqPreset copyWith({
    String? id,
    String? name,
    List<double>? bandGainsDb,
    double? subBass,
    double? stereoWidth,
    double? preampDb,
    bool? isFavorite,
    bool? isBuiltIn,
  }) {
    return EqPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      bandGainsDb: bandGainsDb ?? this.bandGainsDb,
      subBass: subBass ?? this.subBass,
      stereoWidth: stereoWidth ?? this.stereoWidth,
      preampDb: preampDb ?? this.preampDb,
      isFavorite: isFavorite ?? this.isFavorite,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'bands': bandGainsDb,
      'subBass': subBass,
      'stereoWidth': stereoWidth,
      'preampDb': preampDb,
      'isFavorite': isFavorite,
      'isBuiltIn': isBuiltIn,
    };
  }

  factory EqPreset.fromJson(Map<String, Object?> json) {
    final rawBands = json['bands'];
    final bands = <double>[
      if (rawBands is List)
        for (final value in rawBands) value is num ? value.toDouble() : 0.0,
    ];
    final rawSubBass = json['subBass'];
    final rawWidth = json['stereoWidth'];
    final rawPreamp = json['preampDb'];
    return EqPreset(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      bandGainsDb: bands,
      subBass: rawSubBass is num ? rawSubBass.toDouble() : 0.0,
      stereoWidth: rawWidth is num ? rawWidth.toDouble() : 1.0,
      preampDb: rawPreamp is num ? rawPreamp.toDouble() : 0.0,
      isFavorite: json['isFavorite'] == true,
      isBuiltIn: json['isBuiltIn'] == true,
    );
  }

  /// Serializes a full preset library (e.g. all 40 presets) to a JSON string.
  static String encodeList(List<EqPreset> presets) {
    return jsonEncode(presets.map((p) => p.toJson()).toList());
  }

  /// Parses a preset library JSON string. Malformed input yields an empty list.
  static List<EqPreset> decodeList(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! List) return const <EqPreset>[];
      return <EqPreset>[
        for (final item in decoded)
          if (item is Map) EqPreset.fromJson(Map<String, Object?>.from(item)),
      ];
    } on FormatException {
      return const <EqPreset>[];
    }
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is EqPreset &&
            other.id == id &&
            other.name == name &&
            listEquals(other.bandGainsDb, bandGainsDb) &&
            other.subBass == subBass &&
            other.stereoWidth == stereoWidth &&
            other.preampDb == preampDb &&
            other.isFavorite == isFavorite &&
            other.isBuiltIn == isBuiltIn;
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        Object.hashAll(bandGainsDb),
        subBass,
        stereoWidth,
        preampDb,
        isFavorite,
        isBuiltIn,
      );

  @override
  String toString() => 'EqPreset($id, $name)';
}
