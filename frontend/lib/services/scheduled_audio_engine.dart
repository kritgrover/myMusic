enum EngineState { stopped, paused, playing, buffering }

enum ScheduledAudioFallbackReason { unsupported, oversized, network }

/// Safe to surface or log: this exception never retains a signed media URL.
class ScheduledAudioFallbackException implements Exception {
  final ScheduledAudioFallbackReason reason;
  final String message;
  const ScheduledAudioFallbackException(this.reason, this.message);
  @override
  String toString() => message;
}

abstract interface class ScheduledAudioEngine {
  Duration get position;
  Duration get duration;
  double get volume;
  bool get isPlaying;
  bool get isBuffering;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<double> get volumeStream;
  Stream<EngineState> get stateStream;
  Stream<String> get errorStream;
  Stream<void> get completionStream;
  Stream<Object> get handoffStream;
  void synchronize();

  Future<void> load(String authorizedUrl, {Duration position = Duration.zero});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> stageNext(String authorizedUrl,
      {required Object token, Duration crossfade = Duration.zero});
  Future<void> clearNext();
  Future<void> dispose();
}
