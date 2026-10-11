/// An owned download no longer exists. Callers may recover through a known
/// canonical source, while authorization failures remain ordinary errors.
class DownloadUnavailableException implements Exception {
  const DownloadUnavailableException();

  @override
  String toString() => 'This downloaded file is no longer available.';
}
