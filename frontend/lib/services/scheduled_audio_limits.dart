import 'dart:typed_data';

class ScheduledAudioLimits {
  static const maxEncodedBytes = 64 * 1024 * 1024;

  /// Conservative metadata preflight for supported containers. The exact PCM
  /// allocation is checked after decode, before retaining the audio buffer.
  static int? channelBound(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    String tag(int offset) =>
        String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (bytes.length >= 44 && tag(0) == 'RIFF' && tag(8) == 'WAVE') {
      var offset = 12;
      while (offset + 8 <= bytes.length) {
        final size = view.getUint32(offset + 4, Endian.little);
        if (size > bytes.length - offset - 8) return null;
        if (tag(offset) == 'fmt ' && size >= 16) {
          final channels = view.getUint16(offset + 10, Endian.little);
          return channels > 0 && channels <= 32 ? channels : null;
        }
        offset += 8 + size + (size.isOdd ? 1 : 0);
      }
      return null;
    }
    var audioStart = 0;
    if (bytes.length >= 10 &&
        String.fromCharCodes(bytes.sublist(0, 3)) == 'ID3') {
      if (bytes[3] < 2 ||
          bytes[3] > 4 ||
          bytes.sublist(6, 10).any((value) => value & 0x80 != 0)) {
        return null;
      }
      final tagLength =
          (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
      audioStart = 10 + tagLength;
      if (bytes[3] == 4 && bytes[5] & 0x10 != 0) audioStart += 10;
    }
    if (_isMpegAudioHeader(bytes, audioStart)) return 2;
    if (bytes.length > 12 && tag(4) == 'ftyp') {
      for (var offset = 4; offset + 24 < bytes.length; offset++) {
        if (bytes[offset] == 0x6d && tag(offset) == 'mp4a') {
          final size = view.getUint32(offset - 4);
          final channels = view.getUint16(offset + 20);
          if (size >= 36 &&
              offset - 4 + size <= bytes.length &&
              channels > 0 &&
              channels <= 32) {
            return channels;
          }
        }
      }
    }
    return null;
  }

  static bool _isMpegAudioHeader(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return false;
    final second = bytes[offset + 1];
    final third = bytes[offset + 2];
    return bytes[offset] == 0xff &&
        second & 0xe0 == 0xe0 &&
        (second >> 3) & 3 != 1 && // Reserved MPEG version.
        (second >> 1) & 3 != 0 && // Layer 00 is AAC/ADTS, not MPEG audio.
        (third >> 4) != 15 &&
        (third >> 2) & 3 != 3;
  }
}
