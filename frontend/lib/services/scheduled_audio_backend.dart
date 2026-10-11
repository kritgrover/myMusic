/// Small audio-clock boundary used by both the browser adapter and clock tests.
abstract interface class ScheduledAudioClip {
  double get seconds;
  int get decodedBytes;
}

abstract interface class ScheduledAudioVoice {
  void fadeOut(double start, double seconds);
  void resetGain(double now);
  void stop();
}

abstract interface class ScheduledAudioDecode {
  Future<ScheduledAudioClip> get result;
  void cancel();
}

abstract interface class ScheduledAudioBackend {
  double get now;
  ScheduledAudioDecode decode(String url, {required int maxDecodedBytes});
  Future<void> resume();
  ScheduledAudioVoice schedule(ScheduledAudioClip clip,
      {required double when,
      required double offset,
      required double fadeIn,
      required void Function() onEnded});
  void setVolume(double value);
  Future<void> dispose();
}
