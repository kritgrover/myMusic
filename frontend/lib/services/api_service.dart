import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';

class ApiService {
  final String baseUrl;
  
  ApiService({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.apiBaseUrl;
  
  Future<List<VideoInfo>> searchYoutube(String query) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/search'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'query': query,
          'duration_min': 0,
          'duration_max': 600,
        }),
      );
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((item) => VideoInfo.fromJson(item)).toList();
      } else {
        throw Exception('Failed to search: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Search error: $e');
    }
  }
  
  Future<StreamResult> getStreamingUrl({
    required String url,
    required String title,
    String artist = '',
  }) async {
    try {
      // Encode the YouTube URL for use in the proxy endpoint
      final encodedUrl = Uri.encodeComponent(url);
      // Return the proxied streaming URL (backend will handle the actual streaming)
      return StreamResult(
        success: true,
        streamingUrl: '$baseUrl/stream/$encodedUrl',
        title: title,
        artist: artist,
      );
    } catch (e) {
      throw Exception('Stream error: $e');
    }
  }
  
  Future<DownloadResult> downloadAudio({
    required String url,
    required String title,
    String artist = '',
    String album = '',
    String outputFormat = 'm4a',
    bool embedThumbnail = false,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/download'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'url': url,
          'title': title,
          'artist': artist,
          'album': album,
          'output_format': outputFormat,
          'embed_thumbnail': embedThumbnail,
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return DownloadResult.fromJson(data);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Download failed');
      }
    } catch (e) {
      throw Exception('Download error: $e');
    }
  }
  
  Future<List<DownloadedFile>> listDownloads() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/downloads'));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> files = data['files'];
        return files.map((item) => DownloadedFile.fromJson(item)).toList();
      } else {
        throw Exception('Failed to list downloads: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('List downloads error: $e');
    }
  }

  Future<void> deleteDownload(String filename) async {
    try {
      final encodedFilename = Uri.encodeComponent(filename);
      final response = await http.delete(Uri.parse('$baseUrl/downloads/$encodedFilename'));
      
      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Delete failed');
      }
    } catch (e) {
      throw Exception('Delete error: $e');
    }
  }

  // CSV Upload and Conversion
  Future<CsvUploadResult> uploadCsv(String filePath) async {
    try {
      final file = await http.MultipartFile.fromPath('file', filePath);
      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/csv/upload'));
      request.files.add(file);
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return CsvUploadResult.fromJson(data);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Upload failed');
      }
    } catch (e) {
      throw Exception('CSV upload error: $e');
    }
  }

  Future<CsvUploadResult> uploadCsvBytes(List<int> fileBytes, String filename) async {
    try {
      final file = http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: filename,
      );
      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/csv/upload'));
      request.files.add(file);
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return CsvUploadResult.fromJson(data);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Upload failed');
      }
    } catch (e) {
      throw Exception('CSV upload error: $e');
    }
  }

  Future<CsvProgress> getCsvProgress(String filename) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/csv/progress/$filename'));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return CsvProgress.fromJson(data);
      } else {
        throw Exception('Failed to get progress: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Get progress error: $e');
    }
  }

  Future<CsvConversionResult> convertCsv(String filename, {
    int durationMin = 0,
    double durationMax = 600,
    bool excludeInstrumentals = false,
    List<String> variants = const [],
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/csv/convert/$filename'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'duration_min': durationMin,
          'duration_max': durationMax,
          'exclude_instrumentals': excludeInstrumentals,
          'variants': variants,
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return CsvConversionResult.fromJson(data);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Conversion failed');
      }
    } catch (e) {
      throw Exception('CSV conversion error: $e');
    }
  }

  Future<void> addSongToPlaylist(String playlistId, Map<String, dynamic> songData) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/playlists/$playlistId/songs'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(songData),
      );
      
      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['detail'] ?? 'Failed to add song');
      }
    } catch (e) {
      throw Exception('Add song error: $e');
    }
  }

  Future<List<CsvConvertedFile>> listCsvFiles(String playlistName) async {
    try {
      final encodedName = Uri.encodeComponent(playlistName);
      final response = await http.get(Uri.parse('$baseUrl/csv/files/$encodedName'));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> files = data['files'];
        return files.map((item) => CsvConvertedFile.fromJson(item)).toList();
      } else {
        throw Exception('Failed to list CSV files: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('List CSV files error: $e');
    }
  }
}

class VideoInfo {
  final String id;
  final String title;
  final String uploader;
  final double duration;
  final String url;
  final String thumbnail;
  
  VideoInfo({
    required this.id,
    required this.title,
    required this.uploader,
    required this.duration,
    required this.url,
    required this.thumbnail,
  });
  
  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    return VideoInfo(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      uploader: json['uploader'] ?? '',
      duration: (json['duration'] ?? 0).toDouble(),
      url: json['url'] ?? '',
      thumbnail: json['thumbnail'] ?? '',
    );
  }
  
  String get formattedDuration {
    final minutes = (duration / 60).floor();
    final seconds = (duration % 60).floor();
    return '${minutes}:${seconds.toString().padLeft(2, '0')}';
  }
}

class StreamResult {
  final bool success;
  final String streamingUrl;
  final String title;
  final String artist;
  
  StreamResult({
    required this.success,
    required this.streamingUrl,
    required this.title,
    required this.artist,
  });
  
  factory StreamResult.fromJson(Map<String, dynamic> json) {
    return StreamResult(
      success: json['success'] ?? false,
      streamingUrl: json['streaming_url'] ?? '',
      title: json['title'] ?? '',
      artist: json['artist'] ?? '',
    );
  }
}

class DownloadResult {
  final bool success;
  final String filePath;
  final String filename;
  final String title;
  final String artist;
  final String album;
  
  DownloadResult({
    required this.success,
    required this.filePath,
    required this.filename,
    required this.title,
    required this.artist,
    required this.album,
  });
  
  factory DownloadResult.fromJson(Map<String, dynamic> json) {
    return DownloadResult(
      success: json['success'] ?? false,
      filePath: json['file_path'] ?? '',
      filename: json['filename'] ?? '',
      title: json['title'] ?? '',
      artist: json['artist'] ?? '',
      album: json['album'] ?? '',
    );
  }
}

class DownloadedFile {
  final String filename;
  final String filePath;
  final int size;
  final String? title;
  final String? artist;
  
  DownloadedFile({
    required this.filename,
    required this.filePath,
    required this.size,
    this.title,
    this.artist,
  });
  
  factory DownloadedFile.fromJson(Map<String, dynamic> json) {
    return DownloadedFile(
      filename: json['filename'] ?? '',
      filePath: json['file_path'] ?? '',
      size: json['size'] ?? 0,
      title: json['title'],
      artist: json['artist'],
    );
  }
  
  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class CsvUploadResult {
  final bool success;
  final String filename;
  final String filePath;
  
  CsvUploadResult({
    required this.success,
    required this.filename,
    required this.filePath,
  });
  
  factory CsvUploadResult.fromJson(Map<String, dynamic> json) {
    return CsvUploadResult(
      success: json['success'] ?? false,
      filename: json['filename'] ?? '',
      filePath: json['file_path'] ?? '',
    );
  }
}

class CsvConversionResult {
  final bool success;
  final List<Map<String, dynamic>> tracks;
  final List<Map<String, dynamic>> notFound;
  final int total;
  final int successCount;
  final String? playlistId;
  final String? playlistName;
  final bool playlistCreated;
  
  CsvConversionResult({
    required this.success,
    required this.tracks,
    required this.notFound,
    required this.total,
    required this.successCount,
    this.playlistId,
    this.playlistName,
    this.playlistCreated = false,
  });
  
  factory CsvConversionResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> tracksList = json['tracks'] ?? [];
    return CsvConversionResult(
      success: json['success'] ?? false,
      tracks: List<Map<String, dynamic>>.from(tracksList),
      notFound: List<Map<String, dynamic>>.from(json['not_found'] ?? []),
      total: json['total'] ?? 0,
      successCount: json['success_count'] ?? 0,
      playlistId: json['playlist_id'],
      playlistName: json['playlist_name'],
      playlistCreated: json['playlist_created'] ?? false,
    );
  }
}

class CsvConvertedFile {
  final String filename;
  final String filePath;
  final int size;
  final String downloadUrl;
  
  CsvConvertedFile({
    required this.filename,
    required this.filePath,
    required this.size,
    required this.downloadUrl,
  });
  
  factory CsvConvertedFile.fromJson(Map<String, dynamic> json) {
    return CsvConvertedFile(
      filename: json['filename'] ?? '',
      filePath: json['file_path'] ?? '',
      size: json['size'] ?? 0,
      downloadUrl: json['download_url'] ?? '',
    );
  }
  
  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class CsvProgress {
  final int current;
  final int total;
  final String status;
  final int processed;
  final int notFound;
  
  CsvProgress({
    required this.current,
    required this.total,
    required this.status,
    required this.processed,
    required this.notFound,
  });
  
  factory CsvProgress.fromJson(Map<String, dynamic> json) {
    return CsvProgress(
      current: json['current'] ?? 0,
      total: json['total'] ?? 0,
      status: json['status'] ?? '',
      processed: json['processed'] ?? 0,
      notFound: json['not_found'] ?? 0,
    );
  }
  
  bool get isCompleted => status == 'completed';
  bool get hasError => status.startsWith('error');
  double get progress => total > 0 ? current / total : 0.0;
}

