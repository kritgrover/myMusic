import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';

class ApiService {
  final String baseUrl;
  
  ApiService({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.apiBaseUrl;
  
  Future<List<VideoInfo>> searchYoutube(String query, {bool deepSearch = true}) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/search'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'query': query,
          'deep_search': deepSearch,
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
  
  DownloadedFile({
    required this.filename,
    required this.filePath,
    required this.size,
  });
  
  factory DownloadedFile.fromJson(Map<String, dynamic> json) {
    return DownloadedFile(
      filename: json['filename'] ?? '',
      filePath: json['file_path'] ?? '',
      size: json['size'] ?? 0,
    );
  }
  
  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

