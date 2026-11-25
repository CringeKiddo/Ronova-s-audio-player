import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ffi/ronova_ffi_bindings.dart';
import '../models/eq_preset.dart';
import '../storage/preferences_store.dart';
import 'app_providers.dart';

/// Id of preset #1, the bit-transparent reference.
const String kFlatPresetId = 'flat_reference';

/// Id of preset #40, the slot the user fills with their own sound.
const String kCustomPresetId = 'custom';

/// Groups used by the preset browser's filter chips.
enum EqCategory {
  reference('Reference'),
  headset('Headset'),
  bass('Bass'),
  genre('Genre'),
  mood('Mood & Space'),
  voice('Voice'),
  custom('Custom');

  const EqCategory(this.label);
  final String label;
}

/// Display-only facts about a preset (kept outside [EqPreset] so the stored model stays small).
@immutable
class EqPresetMeta {
  const EqPresetMeta({required this.category, required this.blurb});

  final EqCategory category;
  final String blurb;
}

class _Seed {
  const _Seed(
    this.id,
    this.name,
    this.category,
    this.blurb,
    this.bands, {
    this.subBass = 0.0,
    this.width = 1.0,
    this.preamp = 0.0,
  });

  final String id;
  final String name;
  final EqCategory category;
  final String blurb;

  /// 20, 32, 50, 80, 125, 200, 315, 500, 800, 1.25k, 2k, 3.15k, 5k, 8k, 12.5k, 16k Hz.
  final List<double> bands;
  final double subBass;
  final double width;
  final double preamp;
}

/// The 40 curated presets, in browser order. Every curve was written for the 16 fixed centre
/// frequencies of [EqPreset.bandFrequenciesHz]; pre-amp values leave headroom for the boosts.
const List<_Seed> _seeds = <_Seed>[
  _Seed(
    'flat_reference',
    'Flat Reference (32-Bit Pure)',
    EqCategory.reference,
    'Bit-transparent. Every dial at zero, nothing added.',
    <double>[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    subBass: 0.00,
    width: 1.00,
    preamp: 0.0,
  ),
  _Seed(
    'arctis_nova_5_wireless',
    'Arctis Nova 5 Wireless Boost',
    EqCategory.headset,
    'Wins back the sub-bass and air that Bluetooth AAC rounds off.',
    <double>[2.0, 3.0, 2.5, 1.5, 0.5, -0.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 2.0],
    subBass: 0.30,
    width: 1.10,
    preamp: -1.5,
  ),
  _Seed(
    'arctis_nova_3_wired',
    'Arctis Nova 3 Wired Studio',
    EqCategory.headset,
    'Tight, honest wired tuning with a touch of presence.',
    <double>[0.5, 1.0, 1.0, 0.5, 0.0, -0.5, -0.5, 0.0, 0.5, 1.0, 1.5, 1.0, 0.5, 1.0, 1.5, 1.0],
    subBass: 0.12,
    width: 1.05,
    preamp: -1.0,
  ),
  _Seed(
    'earthquake_808',
    '808 Earthquake (Sub-Harmonic)',
    EqCategory.bass,
    'Deep sub shelf plus heavy harmonic synthesis for 808 slides.',
    <double>[5.5, 7.0, 6.0, 3.5, 1.0, -1.5, -2.5, -2.0, -1.0, 0.0, 0.5, 1.0, 1.0, 1.0, 0.5, 0.0],
    subBass: 0.85,
    width: 1.00,
    preamp: -4.0,
  ),
  _Seed(
    'drill_trap_punch',
    'Drill & Trap Punch',
    EqCategory.bass,
    'Slide-808 weight, scooped mud and snappy hi-hat edge.',
    <double>[3.5, 5.0, 4.5, 3.0, 0.5, -2.0, -3.0, -1.5, 0.5, 2.0, 3.0, 3.0, 1.5, 2.0, 1.0, 0.5],
    subBass: 0.60,
    width: 1.15,
    preamp: -3.0,
  ),
  _Seed(
    'slowed_reverb_velvet',
    'Slowed + Reverb Velvet',
    EqCategory.mood,
    'Warm, softened top end that melts into slowed reverb tails.',
    <double>[2.0, 3.0, 3.0, 2.5, 2.0, 1.0, 0.5, 0.0, -0.5, -1.0, -1.5, -2.5, -3.5, -4.5, -5.0, -5.5],
    subBass: 0.35,
    width: 1.35,
    preamp: -2.0,
  ),
  _Seed(
    'nightcore_crystal',
    'Nightcore Crystal',
    EqCategory.mood,
    'Glassy, forward and bright for sped-up vocals.',
    <double>[-3.0, -3.5, -3.0, -2.5, -1.5, -1.0, 0.0, 0.5, 1.5, 2.5, 3.5, 4.5, 5.0, 5.5, 6.0, 5.0],
    subBass: 0.00,
    width: 1.30,
    preamp: -3.0,
  ),
  _Seed(
    'headphone_soundstage_wide',
    'Headphone Soundstage Wide',
    EqCategory.headset,
    'Clears the mud and widens the image beyond your ears.',
    <double>[0.5, 0.5, 0.0, -0.5, -1.0, -1.5, -1.0, 0.0, 0.5, 1.0, 1.5, 2.5, 3.0, 2.5, 2.0, 1.5],
    subBass: 0.10,
    width: 1.65,
    preamp: -2.0,
  ),
  _Seed(
    'sub_bass_chest_thump',
    'Sub-Bass Chest Thump',
    EqCategory.bass,
    'Pure low-end pressure you can feel in your sternum.',
    <double>[4.0, 6.0, 5.5, 4.0, 2.0, 0.0, -1.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.0],
    subBass: 0.70,
    width: 1.00,
    preamp: -3.5,
  ),
  _Seed(
    'vocal_lyric_clarity',
    'Vocal & Lyric Clarity',
    EqCategory.voice,
    'Pushes the 1-4 kHz vocal band so every lyric is intelligible.',
    <double>[-4.0, -3.5, -3.0, -2.0, -1.0, -0.5, 0.5, 1.5, 2.5, 3.5, 4.0, 3.5, 2.0, 0.5, 0.0, -0.5],
    subBass: 0.00,
    width: 1.00,
    preamp: -2.5,
  ),
  _Seed(
    'hip_hop_classic',
    'Hip-Hop Classic',
    EqCategory.genre,
    'Thick kick, punchy snare, forward rap vocals.',
    <double>[3.5, 4.5, 4.0, 3.0, 1.5, 0.0, -1.0, -0.5, 0.5, 1.0, 2.0, 2.5, 1.5, 1.0, 1.0, 0.5],
    subBass: 0.45,
    width: 1.10,
    preamp: -2.5,
  ),
  _Seed(
    'rnb_silk',
    'R&B Silk',
    EqCategory.genre,
    'Smooth low-mid warmth with silky, airy vocals.',
    <double>[2.0, 3.0, 3.0, 2.5, 2.0, 1.0, 0.0, -0.5, 0.0, 1.0, 2.0, 2.5, 1.5, 1.0, 1.5, 1.0],
    subBass: 0.30,
    width: 1.20,
    preamp: -2.0,
  ),
  _Seed(
    'phonk_cowbell_grit',
    'Phonk Cowbell Grit',
    EqCategory.genre,
    'Distorted 808s and a cutting cowbell mid-range.',
    <double>[4.0, 5.0, 4.5, 3.0, 1.0, -1.0, -2.0, -1.0, 1.0, 2.5, 3.5, 3.5, 2.0, 1.0, -0.5, -1.5],
    subBass: 0.65,
    width: 1.20,
    preamp: -3.5,
  ),
  _Seed(
    'lofi_tape_warmth',
    'Lo-Fi Tape Warmth',
    EqCategory.genre,
    'Cozy low end with a gently dulled, tape-worn top.',
    <double>[1.0, 2.0, 2.5, 2.5, 2.0, 1.0, 0.5, 0.0, -0.5, -1.0, -2.0, -3.0, -4.0, -5.0, -6.0, -7.0],
    subBass: 0.15,
    width: 1.10,
    preamp: -1.5,
  ),
  _Seed(
    'edm_festival',
    'EDM Festival',
    EqCategory.genre,
    'Big-room kick, sparkling leads, wide stage.',
    <double>[3.0, 4.0, 3.5, 2.0, 0.5, -1.0, -1.5, -1.0, 0.0, 1.0, 2.0, 3.0, 3.5, 3.5, 3.0, 2.5],
    subBass: 0.50,
    width: 1.35,
    preamp: -3.5,
  ),
  _Seed(
    'techno_warehouse',
    'Techno Warehouse',
    EqCategory.genre,
    'Hypnotic kick weight with crisp, industrial hats.',
    <double>[2.0, 3.5, 4.0, 3.0, 1.0, -1.0, -2.0, -1.5, 0.0, 1.0, 2.0, 2.5, 3.0, 2.5, 1.5, 0.5],
    subBass: 0.50,
    width: 1.20,
    preamp: -3.0,
  ),
  _Seed(
    'dubstep_wobble_floor',
    'Dubstep Wobble Floor',
    EqCategory.genre,
    'Floor-shaking sub with razor mid-range growls.',
    <double>[5.0, 6.5, 6.0, 3.5, 0.5, -2.0, -3.0, -2.5, -1.0, 0.5, 2.0, 3.0, 3.0, 2.5, 2.0, 1.0],
    subBass: 0.80,
    width: 1.25,
    preamp: -4.0,
  ),
  _Seed(
    'rock_stage',
    'Rock Stage',
    EqCategory.genre,
    'Crunchy guitars, driving drums and a live-room feel.',
    <double>[1.0, 2.0, 2.5, 2.0, 1.0, 0.0, -1.0, -1.5, -0.5, 1.0, 2.5, 3.0, 3.0, 2.5, 2.0, 1.0],
    subBass: 0.15,
    width: 1.20,
    preamp: -2.0,
  ),
  _Seed(
    'metal_precision',
    'Metal Precision',
    EqCategory.genre,
    'Tight low-end, scooped mids and cutting attack.',
    <double>[1.5, 2.5, 2.5, 1.5, -0.5, -2.5, -3.5, -2.5, -0.5, 1.5, 3.0, 4.0, 3.5, 3.0, 2.0, 1.0],
    subBass: 0.20,
    width: 1.30,
    preamp: -3.0,
  ),
  _Seed(
    'jazz_club',
    'Jazz Club',
    EqCategory.genre,
    'Woody upright bass, natural brass and smoky air.',
    <double>[0.0, 0.5, 1.0, 1.5, 1.5, 1.0, 0.5, 0.0, 0.5, 1.0, 1.5, 1.5, 1.0, 1.0, 0.5, 0.0],
    subBass: 0.05,
    width: 1.15,
    preamp: -1.0,
  ),
  _Seed(
    'classical_concert',
    'Classical Concert',
    EqCategory.genre,
    'Neutral, spacious and gently lifted in the highs.',
    <double>[-0.5, 0.0, 0.5, 0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.5, 1.0, 1.0, 1.0, 1.5, 1.5, 1.0],
    subBass: 0.00,
    width: 1.35,
    preamp: -1.0,
  ),
  _Seed(
    'acoustic_intimacy',
    'Acoustic Intimacy',
    EqCategory.genre,
    'Body for guitar and voice, close and unprocessed.',
    <double>[-1.5, -1.0, 0.0, 1.0, 2.0, 1.5, 0.5, 0.0, 0.5, 1.5, 2.0, 2.0, 1.5, 1.5, 1.0, 0.5],
    subBass: 0.00,
    width: 1.10,
    preamp: -1.5,
  ),
  _Seed(
    'bass_treble_v_shape',
    'Bass & Treble V-Shape',
    EqCategory.bass,
    'The classic smile curve: big lows, sparkling highs.',
    <double>[4.0, 5.0, 4.5, 3.0, 1.0, -1.0, -2.5, -3.0, -2.5, -1.0, 1.0, 2.5, 3.5, 4.5, 5.0, 4.0],
    subBass: 0.35,
    width: 1.15,
    preamp: -4.0,
  ),
  _Seed(
    'warm_tube_analog',
    'Warm Tube Analog',
    EqCategory.mood,
    'Vintage valve warmth with a soft, rounded top.',
    <double>[1.0, 2.0, 2.5, 2.0, 1.5, 1.0, 0.5, 0.5, 0.0, -0.5, -1.0, -1.0, -1.5, -2.0, -2.5, -3.0],
    subBass: 0.20,
    width: 1.05,
    preamp: -1.5,
  ),
  _Seed(
    'bright_air_sheen',
    'Bright Air Sheen',
    EqCategory.mood,
    'Open, airy top end for detail and sparkle.',
    <double>[-1.0, -1.0, -0.5, -0.5, 0.0, 0.0, 0.0, 0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 5.0],
    subBass: 0.00,
    width: 1.20,
    preamp: -2.5,
  ),
  _Seed(
    'late_night_low_volume',
    'Late Night Low-Volume',
    EqCategory.mood,
    'Loudness contour that keeps bass and treble alive when quiet.',
    <double>[4.0, 5.0, 4.0, 2.5, 1.0, 0.0, -0.5, -0.5, 0.0, 1.0, 2.0, 3.0, 3.0, 3.5, 4.0, 3.0],
    subBass: 0.25,
    width: 1.00,
    preamp: -1.0,
  ),
  _Seed(
    'gaming_footsteps_music',
    'Gaming Footsteps + Music',
    EqCategory.headset,
    'Lifts the 2-5 kHz footstep range while music stays full.',
    <double>[-1.0, -1.0, 0.0, 0.0, -1.0, -2.0, -2.0, -1.0, 0.5, 2.0, 3.5, 4.5, 4.0, 2.5, 1.0, 0.0],
    subBass: 0.10,
    width: 1.50,
    preamp: -3.0,
  ),
  _Seed(
    'car_audio_sub',
    'Car Audio Sub',
    EqCategory.bass,
    'Cabin-style bass boost with a punchy kick and clear vocals.',
    <double>[3.0, 4.0, 4.0, 3.0, 1.5, 0.0, -0.5, 0.0, 0.5, 1.0, 2.0, 2.5, 2.0, 1.5, 1.5, 1.0],
    subBass: 0.55,
    width: 1.00,
    preamp: -3.0,
  ),
  _Seed(
    'iem_harman_target',
    'IEM Harman Target',
    EqCategory.headset,
    'Bass shelf, ear-gain lift and a tamed treble for in-ears.',
    <double>[2.5, 3.5, 4.0, 3.5, 2.0, 0.5, 0.0, 0.0, 0.5, 1.5, 3.0, 3.5, 1.5, -1.0, 0.5, -0.5],
    subBass: 0.20,
    width: 1.00,
    preamp: -3.0,
  ),
  _Seed(
    'open_back_planar',
    'Open-Back Planar',
    EqCategory.headset,
    'Adds the sub-bass open-back planars cannot reproduce on their own.',
    <double>[3.5, 3.5, 2.5, 1.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.0, 0.5, 1.0, 0.5, 0.0],
    subBass: 0.30,
    width: 1.20,
    preamp: -2.0,
  ),
  _Seed(
    'closed_back_tight',
    'Closed-Back Tight',
    EqCategory.headset,
    'Trims boom and cup resonance for a controlled, tight sound.',
    <double>[0.0, 0.0, -0.5, -1.5, -2.5, -2.5, -1.5, 0.0, 0.5, 1.0, 1.5, 1.5, 1.0, 1.0, 0.5, 0.0],
    subBass: 0.05,
    width: 1.25,
    preamp: -1.0,
  ),
  _Seed(
    'deep_house_pulse',
    'Deep House Pulse',
    EqCategory.genre,
    'Round sub-bass groove with silky, shimmering hats.',
    <double>[2.5, 3.5, 3.5, 3.0, 2.0, 0.5, -0.5, -0.5, 0.0, 0.5, 1.0, 1.5, 1.5, 1.5, 1.0, 0.5],
    subBass: 0.45,
    width: 1.30,
    preamp: -2.5,
  ),
  _Seed(
    'afrobeats_groove',
    'Afrobeats Groove',
    EqCategory.genre,
    'Bouncy bass, lively percussion and bright vocals.',
    <double>[2.0, 3.0, 3.0, 2.5, 1.5, 0.5, 0.0, 0.5, 1.5, 2.0, 2.5, 2.5, 2.0, 1.5, 1.0, 0.5],
    subBass: 0.40,
    width: 1.20,
    preamp: -2.5,
  ),
  _Seed(
    'dancehall_sub',
    'Dancehall Sub',
    EqCategory.bass,
    'Rolling sub-bass riddims with crisp snare and vocal bite.',
    <double>[4.5, 6.0, 5.5, 3.5, 1.0, -0.5, -1.0, 0.0, 1.0, 1.5, 2.0, 2.0, 1.5, 1.0, 0.5, 0.0],
    subBass: 0.75,
    width: 1.10,
    preamp: -4.0,
  ),
  _Seed(
    'reggae_dub',
    'Reggae Dub',
    EqCategory.genre,
    'Fat, round bass and cavernous dub space.',
    <double>[3.0, 4.5, 4.5, 3.5, 2.0, 0.5, -1.0, -1.5, -0.5, 0.5, 1.0, 1.0, 0.5, 0.0, -0.5, -1.0],
    subBass: 0.55,
    width: 1.40,
    preamp: -3.0,
  ),
  _Seed(
    'synthwave_neon',
    'Synthwave Neon',
    EqCategory.genre,
    'Glossy analog synths, gated drums and neon width.',
    <double>[2.5, 3.0, 2.5, 1.5, 0.5, -0.5, -1.0, 0.0, 1.0, 2.0, 2.5, 3.0, 3.0, 3.0, 3.5, 3.0],
    subBass: 0.35,
    width: 1.45,
    preamp: -3.0,
  ),
  _Seed(
    'orchestral_hall',
    'Orchestral Hall',
    EqCategory.genre,
    'Wide hall stage with natural strings and brass.',
    <double>[-1.5, -0.5, 0.5, 1.0, 1.5, 1.0, 0.5, 0.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 2.0],
    subBass: 0.05,
    width: 1.55,
    preamp: -1.5,
  ),
  _Seed(
    'podcast_voice',
    'Podcast Voice',
    EqCategory.voice,
    'Removes rumble and hiss, centres and warms speech.',
    <double>[-9.0, -7.0, -5.0, -3.5, -1.0, 0.5, 1.5, 2.5, 3.0, 3.5, 3.0, 2.0, 0.5, -1.0, -2.5, -4.0],
    subBass: 0.00,
    width: 0.70,
    preamp: -2.0,
  ),
  _Seed(
    'ultra_clean_master',
    'Ultra Clean Master',
    EqCategory.reference,
    'Mastering-grade polish: sub rumble out, gentle air in.',
    <double>[-4.0, -2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.5, 1.0, 1.0, 1.0],
    subBass: 0.00,
    width: 1.00,
    preamp: 0.0,
  ),
  _Seed(
    'custom',
    'Custom User Slot',
    EqCategory.custom,
    'Your own sound. Turn any dial, then save it here.',
    <double>[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    subBass: 0.00,
    width: 1.00,
    preamp: 0.0,
  ),
];

/// The built-in 40-preset audiophile library.
abstract final class EqLibrary {
  static const int presetCount = 40;

  static final List<EqPreset> builtIn = List<EqPreset>.unmodifiable(<EqPreset>[
    for (final seed in _seeds)
      EqPreset(
        id: seed.id,
        name: seed.name,
        bandGainsDb: seed.bands,
        subBass: seed.subBass,
        stereoWidth: seed.width,
        preampDb: seed.preamp,
        isBuiltIn: seed.id != kCustomPresetId,
      ),
  ]);

  static final Map<String, EqPresetMeta> meta = <String, EqPresetMeta>{
    for (final seed in _seeds) seed.id: EqPresetMeta(category: seed.category, blurb: seed.blurb),
  };

  static EqPresetMeta metaFor(String id) {
    return meta[id] ?? const EqPresetMeta(category: EqCategory.custom, blurb: '');
  }

  /// Starred on first launch so the Mini Favorites bar is never empty. Once the user changes
  /// their favourites, their own choice is stored and these defaults are never re-applied.
  static const List<String> defaultFavoriteIds = <String>[
    'flat_reference',
    'arctis_nova_5_wireless',
    'earthquake_808',
    'slowed_reverb_velvet',
    'vocal_lyric_clarity',
  ];
}

/// Everything the equalizer screen and the engine push read: the active dial positions, the
/// 40 presets and which of them are favourites.
@immutable
class EqualizerState {
  const EqualizerState({
    required this.presets,
    required this.activePresetId,
    required this.bandGainsDb,
    required this.subBass,
    required this.stereoWidth,
    required this.preampDb,
    required this.modified,
    required this.favoriteIds,
    required this.engineAvailable,
  });

  factory EqualizerState.initial() {
    final flat = EqLibrary.builtIn.first;
    return EqualizerState(
      presets: EqLibrary.builtIn,
      activePresetId: flat.id,
      bandGainsDb: flat.bandGainsDb,
      subBass: flat.subBass,
      stereoWidth: flat.stereoWidth,
      preampDb: flat.preampDb,
      modified: false,
      favoriteIds: const <String>{},
      engineAvailable: false,
    );
  }

  /// All 40 presets in browser order (the last one is the user's custom slot).
  final List<EqPreset> presets;
  final String activePresetId;

  /// 16 gains in dB (-12 .. +12), one per [EqPreset.bandFrequenciesHz] entry.
  final List<double> bandGainsDb;

  /// 808 sub-bass exciter amount, 0.0 .. 1.0 (shown as 0 - 100 %).
  final double subBass;

  /// Stereo stage width, 0.0 .. 2.0 (shown as 0 - 200 %).
  final double stereoWidth;

  /// Pre-amp trim, -12 .. +12 dB.
  final double preampDb;

  /// True when the dials were moved away from the active preset's stored values.
  final bool modified;
  final Set<String> favoriteIds;
  final bool engineAvailable;

  EqPreset get activePreset {
    for (final preset in presets) {
      if (preset.id == activePresetId) return preset;
    }
    return presets.first;
  }

  EqPreset get customPreset {
    for (final preset in presets) {
      if (preset.id == kCustomPresetId) return preset;
    }
    return presets.last;
  }

  bool get isCustomActive => activePresetId == kCustomPresetId;

  /// Favourite presets in library order (what the Mini Favorites bar shows).
  List<EqPreset> get favoritePresets {
    return <EqPreset>[
      for (final preset in presets)
        if (favoriteIds.contains(preset.id)) preset,
    ];
  }

  bool isFavorite(String id) => favoriteIds.contains(id);

  String get activeLabel => modified ? '${activePreset.name} · edited' : activePreset.name;

  EqualizerState copyWith({
    List<EqPreset>? presets,
    String? activePresetId,
    List<double>? bandGainsDb,
    double? subBass,
    double? stereoWidth,
    double? preampDb,
    bool? modified,
    Set<String>? favoriteIds,
    bool? engineAvailable,
  }) {
    return EqualizerState(
      presets: presets ?? this.presets,
      activePresetId: activePresetId ?? this.activePresetId,
      bandGainsDb: bandGainsDb ?? this.bandGainsDb,
      subBass: subBass ?? this.subBass,
      stereoWidth: stereoWidth ?? this.stereoWidth,
      preampDb: preampDb ?? this.preampDb,
      modified: modified ?? this.modified,
      favoriteIds: favoriteIds ?? this.favoriteIds,
      engineAvailable: engineAvailable ?? this.engineAvailable,
    );
  }
}

/// Owns the 16 EQ dials, the 808 sub-bass / stereo width / pre-amp dials, the 40 presets and the
/// favourites. Every change is pushed live to the C++ engine and saved (debounced) to
/// SharedPreferences; the saved state is re-applied to the engine as soon as the controller is
/// created at app start.
class EqualizerController extends StateNotifier<EqualizerState> {
  EqualizerController(this._ref) : super(EqualizerState.initial()) {
    _ffi = _ref.read(ffiBindingsProvider);
    _prefs = _ref.read(preferencesStoreProvider);
    _restore();
    state = state.copyWith(engineAvailable: _ffi != null);
    applyToEngine();
  }

  final Ref _ref;
  late final RonovaFfiBindings? _ffi;
  late final PreferencesStore? _prefs;
  Timer? _saveTimer;

  static const Duration _saveDelay = Duration(milliseconds: 350);

  // ------------------------------------------------------------------------------------------
  // Quantisers (dial detents)
  // ------------------------------------------------------------------------------------------

  /// EQ band gain: 0.5 dB detents within +/-12 dB.
  static double snapGain(double value) {
    if (value.isNaN) return 0.0;
    final clamped = value.clamp(EqPreset.minGainDb, EqPreset.maxGainDb).toDouble();
    return (clamped * 2).round() / 2.0;
  }

  /// Pre-amp trim: 0.5 dB detents within +/-12 dB.
  static double snapPreamp(double value) {
    if (value.isNaN) return 0.0;
    final clamped = value.clamp(EqPreset.minPreampDb, EqPreset.maxPreampDb).toDouble();
    return (clamped * 2).round() / 2.0;
  }

  /// Sub-bass / stereo width: 1 % detents inside [min] .. [max].
  static double snapUnit(double value, double min, double max) {
    if (value.isNaN) return min;
    final clamped = value.clamp(min, max).toDouble();
    return (clamped * 100).round() / 100.0;
  }

  // ------------------------------------------------------------------------------------------
  // Restore
  // ------------------------------------------------------------------------------------------

  void _restore() {
    final prefs = _prefs;
    final raw = prefs?.loadEqState() ?? const <String, Object?>{};

    // The user's custom slot survives relaunches.
    var presets = EqLibrary.builtIn;
    final customRaw = raw['custom'];
    if (customRaw is Map) {
      final restored = EqPreset.fromJson(Map<String, Object?>.from(customRaw)).copyWith(
        id: kCustomPresetId,
        name: 'Custom User Slot',
        isBuiltIn: false,
      );
      presets = _swapPreset(presets, restored);
    }

    // Favourites: seeded once, then fully user-controlled.
    Set<String> favorites;
    if (prefs != null && prefs.hasSavedFavoritePresetIds) {
      final known = <String>{for (final p in presets) p.id};
      favorites = prefs.loadFavoritePresetIds().where(known.contains).toSet();
    } else {
      favorites = EqLibrary.defaultFavoriteIds.toSet();
      if (prefs != null) unawaited(prefs.saveFavoritePresetIds(favorites));
    }

    // Active preset + the exact dial positions (which may differ from the preset's if edited).
    final rawActive = raw['active'] ?? prefs?.activeEqPresetId;
    var activeId = kFlatPresetId;
    if (rawActive is String) {
      for (final p in presets) {
        if (p.id == rawActive) {
          activeId = p.id;
          break;
        }
      }
    }
    EqPreset active = presets.first;
    for (final p in presets) {
      if (p.id == activeId) {
        active = p;
        break;
      }
    }

    double readDouble(String key, double fallback) {
      final value = raw[key];
      return value is num ? value.toDouble() : fallback;
    }

    var bands = active.bandGainsDb;
    final rawBands = raw['bands'];
    if (rawBands is List && rawBands.length == EqPreset.bandCount) {
      bands = List<double>.unmodifiable(<double>[
        for (final value in rawBands) snapGain(value is num ? value.toDouble() : 0.0),
      ]);
    }

    state = state.copyWith(
      presets: presets,
      activePresetId: activeId,
      bandGainsDb: bands,
      subBass: snapUnit(readDouble('subBass', active.subBass), 0.0, 1.0),
      stereoWidth: snapUnit(readDouble('stereoWidth', active.stereoWidth), 0.0, 2.0),
      preampDb: snapPreamp(readDouble('preampDb', active.preampDb)),
      modified: raw['modified'] == true,
      favoriteIds: favorites,
    );
  }

  // ------------------------------------------------------------------------------------------
  // Engine push
  // ------------------------------------------------------------------------------------------

  /// Pushes every dial to the C++ engine (called at start-up and whenever a preset is chosen).
  void applyToEngine() {
    final ffi = _ffi;
    if (ffi == null) return;
    final s = state;
    ffi.setPreampDb(s.preampDb);
    for (var i = 0; i < EqPreset.bandCount; i++) {
      _pushBand(i);
    }
    ffi.setSubBassBoost(s.subBass);
    ffi.setStereoWidth(s.stereoWidth);
  }

  void _pushBand(int index) {
    _ffi?.setEqBand(
      index,
      freqHz: EqPreset.bandFrequenciesHz[index],
      gainDb: state.bandGainsDb[index],
      q: EqPreset.defaultQ,
    );
  }

  // ------------------------------------------------------------------------------------------
  // Presets & favourites
  // ------------------------------------------------------------------------------------------

  EqPreset? _find(String id) {
    for (final preset in state.presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// Loads a preset into every dial and onto the engine.
  void selectPreset(String id) {
    final preset = _find(id);
    if (preset == null) return;
    state = state.copyWith(
      activePresetId: preset.id,
      bandGainsDb: preset.bandGainsDb,
      subBass: preset.subBass,
      stereoWidth: preset.stereoWidth,
      preampDb: preset.preampDb,
      modified: false,
    );
    applyToEngine();
    _scheduleSave();
  }

  void toggleFavorite(String id) {
    if (_find(id) == null) return;
    final next = Set<String>.of(state.favoriteIds);
    if (!next.remove(id)) next.add(id);
    state = state.copyWith(favoriteIds: next);
    final prefs = _prefs;
    if (prefs != null) unawaited(prefs.saveFavoritePresetIds(next));
  }

  /// Undoes dial edits (restores the active preset). On the custom slot this clears it to flat.
  void resetActive() {
    if (state.isCustomActive) {
      state = _settle(
        state.copyWith(
          bandGainsDb: List<double>.filled(EqPreset.bandCount, 0.0),
          subBass: 0.0,
          stereoWidth: 1.0,
          preampDb: 0.0,
        ),
      );
      applyToEngine();
      _scheduleSave();
      return;
    }
    selectPreset(state.activePresetId);
  }

  /// Stores the current dial positions in the Custom User Slot and makes it the active preset.
  void saveToCustomSlot() {
    final custom = _customFrom(state);
    state = state.copyWith(
      presets: _swapPreset(state.presets, custom),
      activePresetId: kCustomPresetId,
      modified: false,
    );
    _scheduleSave();
  }

  // ------------------------------------------------------------------------------------------
  // Dials
  // ------------------------------------------------------------------------------------------

  void setBandGain(int index, double gainDb) {
    if (index < 0 || index >= EqPreset.bandCount) return;
    final gain = snapGain(gainDb);
    if (gain == state.bandGainsDb[index]) return;
    final next = List<double>.of(state.bandGainsDb)..[index] = gain;
    state = _settle(state.copyWith(bandGainsDb: List<double>.unmodifiable(next)));
    _pushBand(index);
    _scheduleSave();
  }

  /// 808 sub-bass exciter, 0.0 .. 1.0.
  void setSubBass(double amount) {
    final value = snapUnit(amount, 0.0, 1.0);
    if (value == state.subBass) return;
    state = _settle(state.copyWith(subBass: value));
    _ffi?.setSubBassBoost(value);
    _scheduleSave();
  }

  /// Stereo stage width, 0.0 .. 2.0 (1.0 neutral).
  void setStereoWidth(double width) {
    final value = snapUnit(width, 0.0, 2.0);
    if (value == state.stereoWidth) return;
    state = _settle(state.copyWith(stereoWidth: value));
    _ffi?.setStereoWidth(value);
    _scheduleSave();
  }

  /// Pre-amp trim, -12 .. +12 dB.
  void setPreampDb(double gainDb) {
    final value = snapPreamp(gainDb);
    if (value == state.preampDb) return;
    state = _settle(state.copyWith(preampDb: value));
    _ffi?.setPreampDb(value);
    _scheduleSave();
  }

  // ------------------------------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------------------------------

  static List<EqPreset> _swapPreset(List<EqPreset> list, EqPreset replacement) {
    return <EqPreset>[
      for (final preset in list) preset.id == replacement.id ? replacement : preset,
    ];
  }

  static EqPreset _customFrom(EqualizerState s) {
    return EqPreset(
      id: kCustomPresetId,
      name: 'Custom User Slot',
      bandGainsDb: s.bandGainsDb,
      subBass: s.subBass,
      stereoWidth: s.stereoWidth,
      preampDb: s.preampDb,
    );
  }

  /// Recomputes the "edited" flag; while the custom slot is active it simply follows the dials.
  static EqualizerState _settle(EqualizerState s) {
    if (s.activePresetId == kCustomPresetId) {
      return s.copyWith(presets: _swapPreset(s.presets, _customFrom(s)), modified: false);
    }
    EqPreset? base;
    for (final preset in s.presets) {
      if (preset.id == s.activePresetId) {
        base = preset;
        break;
      }
    }
    final same = base != null &&
        listEquals(base.bandGainsDb, s.bandGainsDb) &&
        base.subBass == s.subBass &&
        base.stereoWidth == s.stereoWidth &&
        base.preampDb == s.preampDb;
    return s.copyWith(modified: !same);
  }

  // ------------------------------------------------------------------------------------------
  // Persistence
  // ------------------------------------------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _flush);
  }

  void _flush() {
    _saveTimer = null;
    final prefs = _prefs;
    if (prefs == null) return;
    final s = state;
    unawaited(
      prefs.saveEqState(<String, Object?>{
        'active': s.activePresetId,
        'bands': s.bandGainsDb,
        'subBass': s.subBass,
        'stereoWidth': s.stereoWidth,
        'preampDb': s.preampDb,
        'modified': s.modified,
        'custom': s.customPreset.toJson(),
      }),
    );
    unawaited(prefs.setActiveEqPresetId(s.activePresetId));
  }

  @override
  void dispose() {
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      _flush();
    }
    super.dispose();
  }
}

/// Live EQ state. Read once in `main()` so the saved preset and dials are on the engine from the
/// first second of the app.
final equalizerProvider = StateNotifierProvider<EqualizerController, EqualizerState>((ref) {
  return EqualizerController(ref);
});

/// The composite magnitude response of the 16 biquads (RBJ peaking, the same maths the C++ engine
/// uses) plus the pre-amp trim, for the live curve visualiser.
abstract final class EqResponse {
  static const double minHz = 20.0;
  static const double maxHz = 20000.0;

  /// Frequency of curve point [index] out of [points] on a logarithmic axis.
  static double frequencyAt(int index, int points) {
    final t = points <= 1 ? 0.0 : index / (points - 1);
    return minHz * math.pow(maxHz / minHz, t).toDouble();
  }

  /// Response in dB at [points] log-spaced frequencies from [minHz] to [maxHz].
  static List<double> curveDb({
    required List<double> gainsDb,
    required double preampDb,
    int points = 96,
    double sampleRate = 48000.0,
  }) {
    // Per active band: b0 b1 b2 a0 a1 a2 (RBJ peaking, Q = EqPreset.defaultQ).
    final coefficients = <List<double>>[];
    for (var band = 0; band < EqPreset.bandCount && band < gainsDb.length; band++) {
      final gain = gainsDb[band];
      if (gain.abs() < 0.01) continue;
      final a = math.pow(10.0, gain / 40.0).toDouble();
      final w0 = 2.0 * math.pi * EqPreset.bandFrequenciesHz[band] / sampleRate;
      final alpha = math.sin(w0) / (2.0 * EqPreset.defaultQ);
      final cw = math.cos(w0);
      coefficients.add(<double>[
        1.0 + alpha * a,
        -2.0 * cw,
        1.0 - alpha * a,
        1.0 + alpha / a,
        -2.0 * cw,
        1.0 - alpha / a,
      ]);
    }

    final result = List<double>.filled(points, preampDb);
    for (var i = 0; i < points; i++) {
      final w = 2.0 * math.pi * frequencyAt(i, points) / sampleRate;
      final c1 = math.cos(w);
      final s1 = math.sin(w);
      final c2 = math.cos(2.0 * w);
      final s2 = math.sin(2.0 * w);
      var db = preampDb;
      for (final k in coefficients) {
        final numRe = k[0] + k[1] * c1 + k[2] * c2;
        final numIm = k[1] * s1 + k[2] * s2;
        final denRe = k[3] + k[4] * c1 + k[5] * c2;
        final denIm = k[4] * s1 + k[5] * s2;
        final den = denRe * denRe + denIm * denIm;
        if (den <= 0.0) continue;
        final magSquared = (numRe * numRe + numIm * numIm) / den;
        if (magSquared <= 0.0) continue;
        db += 10.0 * math.log(magSquared) / math.ln10;
      }
      result[i] = db;
    }
    return result;
  }
}
