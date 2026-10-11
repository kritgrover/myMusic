/// Keep provider logs, local paths, and request credentials out of download UI.
String downloadFailureMessage(Object? error) {
  final detail = error.toString().toLowerCase();
  if (detail.contains('401') || detail.contains('session expired')) {
    return 'Your session has expired. Sign in again and retry.';
  }
  if (detail.contains('ffmpeg') ||
      detail.contains('ffprobe') ||
      detail.contains('conversion')) {
    return 'The server could not convert the audio. Please retry.';
  }
  if (detail.contains('sign in') ||
      detail.contains('bot') ||
      detail.contains('403') ||
      detail.contains('video unavailable') ||
      detail.contains('video is unavailable') ||
      detail.contains('recording unavailable') ||
      detail.contains('private video') ||
      detail.contains('removed')) {
    return 'The audio provider could not supply this recording. Try another source.';
  }
  if (detail.contains('no audio source') ||
      detail.contains('no confident') ||
      detail.contains('no playable') ||
      detail.contains('no matching')) {
    return 'No matching recording was found. Choose a source and retry.';
  }
  if (detail.contains('no space left') ||
      detail.contains('not enough space') ||
      detail.contains('disk is full') ||
      detail.contains('disk full') ||
      detail.contains('errno = 28') ||
      detail.contains('errno = 112')) {
    return 'There is not enough available storage for this download.';
  }
  if (detail.contains('permission denied') ||
      detail.contains('access is denied') ||
      detail.contains('filesystemexception') ||
      detail.contains('storage')) {
    return 'Could not save the audio on this device. Check access to device storage and retry.';
  }
  if (detail.contains('timeout') ||
      detail.contains('connection') ||
      detail.contains('network') ||
      detail.contains('socket')) {
    return 'The connection was interrupted. Check your connection and retry.';
  }
  return 'The audio could not be downloaded. Try another source or retry.';
}
