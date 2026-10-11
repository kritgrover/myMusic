import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/utils/download_error_utils.dart';

void main() {
  test('storage access errors do not claim the disk is full', () {
    final message = downloadFailureMessage(
        r'FileSystemException: Access is denied, C:\private\storage\index.json');
    expect(message, contains('access to device storage'));
    expect(message, isNot(contains('not enough')));
    expect(message, isNot(contains('private')));
    expect(downloadFailureMessage('Device storage is unavailable'),
        contains('access to device storage'));
  });

  test('actual disk exhaustion explains insufficient space', () {
    expect(
        downloadFailureMessage('FileSystemException: No space left on device'),
        contains('not enough available storage'));
  });

  test('expired authentication gives a sign-in action', () {
    expect(downloadFailureMessage('Audio download failed (401).'),
        contains('Sign in again'));
  });

  test('unknown failures never expose raw paths or request tokens', () {
    final message = downloadFailureMessage(
        'unknown failure https://example.com/audio?token=private-token');
    expect(message, contains('retry'));
    expect(message, isNot(contains('private-token')));
    expect(message, isNot(contains('https://')));
  });
}
