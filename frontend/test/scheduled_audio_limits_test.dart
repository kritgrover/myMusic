import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/services/scheduled_audio_limits.dart';

void main() {
  test('MPEG frames are bounded to stereo but ADTS/reserved headers fall back',
      () {
    expect(
        ScheduledAudioLimits.channelBound(
            Uint8List.fromList([0xff, 0xfb, 0x90, 0])),
        2);
    expect(
        ScheduledAudioLimits.channelBound(
            Uint8List.fromList([0xff, 0xf3, 0x90, 0])),
        2);
    expect(
        ScheduledAudioLimits.channelBound(
            Uint8List.fromList([0xff, 0xf1, 0x90, 0])),
        isNull);
    expect(
        ScheduledAudioLimits.channelBound(
            Uint8List.fromList([0xff, 0xeb, 0x90, 0])),
        isNull);
    expect(
        ScheduledAudioLimits.channelBound(
            Uint8List.fromList([0xff, 0xfb, 0xfc, 0])),
        isNull);
  });
  test('ID3 header is skipped and actual MPEG frame is required', () {
    final bytes = Uint8List.fromList([
      ...'ID3'.codeUnits,
      4,
      0,
      0,
      0,
      0,
      0,
      4,
      0,
      0,
      0,
      0,
      0xff,
      0xfb,
      0x90,
      0
    ]);
    expect(ScheduledAudioLimits.channelBound(bytes), 2);
    bytes[15] = 0xf1;
    expect(ScheduledAudioLimits.channelBound(bytes), isNull);
    bytes[6] = 0x80;
    expect(ScheduledAudioLimits.channelBound(bytes), isNull);
  });
  test('truncated and oversized ID3 tags fall back without out of bounds reads',
      () {
    expect(ScheduledAudioLimits.channelBound(Uint8List(2)), isNull);
    final bytes = Uint8List.fromList(
        [...'ID3'.codeUnits, 4, 0, 0, 0x7f, 0x7f, 0x7f, 0x7f]);
    expect(ScheduledAudioLimits.channelBound(bytes), isNull);
  });
  test('WAV parser honors chunk sizes, padding and channel count', () {
    final bytes = Uint8List(54);
    final view = ByteData.sublistView(bytes);
    bytes.setRange(0, 4, 'RIFF'.codeUnits);
    bytes.setRange(8, 12, 'WAVE'.codeUnits);
    bytes.setRange(12, 16, 'JUNK'.codeUnits);
    view.setUint32(16, 1, Endian.little);
    bytes.setRange(22, 26, 'fmt '.codeUnits);
    view.setUint32(26, 16, Endian.little);
    view.setUint16(32, 6, Endian.little);
    expect(ScheduledAudioLimits.channelBound(bytes), 6);
    view.setUint32(26, 200, Endian.little);
    expect(ScheduledAudioLimits.channelBound(bytes), isNull);
  });
  test(
      'MP4 audio entry channel count is bounded and malformed entries fall back',
      () {
    final bytes = Uint8List(52);
    final view = ByteData.sublistView(bytes);
    view.setUint32(0, 16);
    bytes.setRange(4, 8, 'ftyp'.codeUnits);
    view.setUint32(16, 36);
    bytes.setRange(20, 24, 'mp4a'.codeUnits);
    view.setUint16(40, 2);
    expect(ScheduledAudioLimits.channelBound(bytes), 2);
    view.setUint16(40, 33);
    expect(ScheduledAudioLimits.channelBound(bytes), isNull);
    view.setUint16(40, 2);
    view.setUint32(16, 300);
    expect(ScheduledAudioLimits.channelBound(bytes), isNull);
  });
}
