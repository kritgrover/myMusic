import 'package:flutter/material.dart';
import 'dart:html' as html;
import 'dart:typed_data';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../config.dart';

class CsvUploadScreen extends StatefulWidget {
  final Function(String filename)? onConversionStart;
  final Function(CsvConversionResult)? onConversionComplete;
  
  const CsvUploadScreen({
    super.key,
    this.onConversionStart,
    this.onConversionComplete,
  });

  @override
  State<CsvUploadScreen> createState() => _CsvUploadScreenState();
}

class _CsvUploadScreenState extends State<CsvUploadScreen> {
  final ApiService _apiService = ApiService();
  final PlaylistService _playlistService = PlaylistService();
  String? _uploadedFilename;
  String? _playlistName;
  bool _isConverting = false;
  bool _conversionComplete = false;
  CsvConversionResult? _conversionResult;
  bool _excludeInstrumentals = false;
  int _durationMin = 0;
  double _durationMax = 600.0;
  late TextEditingController _durationMinController;
  late TextEditingController _durationMaxController;

  @override
  void initState() {
    super.initState();
    _durationMinController = TextEditingController(text: _durationMin.toString());
    _durationMaxController = TextEditingController(text: _durationMax.toStringAsFixed(0));
    _durationMinController.addListener(_updateDurationMin);
    _durationMaxController.addListener(_updateDurationMax);
  }

  @override
  void dispose() {
    _durationMinController.dispose();
    _durationMaxController.dispose();
    super.dispose();
  }

  void _updateDurationMin() {
    if (!mounted) return;
    final value = int.tryParse(_durationMinController.text);
    if (value != null && value != _durationMin) {
      setState(() {
        _durationMin = value;
      });
    }
  }

  void _updateDurationMax() {
    if (!mounted) return;
    final value = double.tryParse(_durationMaxController.text);
    if (value != null && value != _durationMax) {
      setState(() {
        _durationMax = value;
      });
    }
  }

  Future<void> _pickFile() async {
    final input = html.FileUploadInputElement()..accept = '.csv';
    input.click();

    input.onChange.listen((e) async {
      final files = input.files;
      if (files != null && files.isNotEmpty) {
        final file = files[0];
        await _uploadFile(file);
      }
    });
  }

  Future<void> _uploadFile(html.File file) async {
    try {
      if (mounted) {
        setState(() {
          _isConverting = true;
          _conversionComplete = false;
          _uploadedFilename = file.name;
          _playlistName = file.name.replaceAll('.csv', '');
        });
      }

      // Read file as bytes
      final reader = html.FileReader();
      reader.readAsArrayBuffer(file);
      await reader.onLoad.first;
      
      // Handle both ByteBuffer and Uint8List cases
      Uint8List fileBytes;
      if (reader.result is Uint8List) {
        fileBytes = reader.result as Uint8List;
      } else if (reader.result is ByteBuffer) {
        fileBytes = (reader.result as ByteBuffer).asUint8List();
      } else {
        throw Exception('Unexpected file reader result type');
      }
      
      // Upload file using API service
      final uploadResult = await _apiService.uploadCsvBytes(fileBytes, file.name);
      
      // Notify parent that conversion started
      widget.onConversionStart?.call(uploadResult.filename);
      
      // Convert CSV (this will run in background, progress is polled by home screen)
      final conversionResult = await _apiService.convertCsv(
        uploadResult.filename,
        durationMin: _durationMin,
        durationMax: _durationMax,
        excludeInstrumentals: _excludeInstrumentals,
      );

      // Notify parent that conversion completed (pass result so dialog can be shown at home screen level)
      // Call this before setState in case widget is disposed
      widget.onConversionComplete?.call(conversionResult);
      
      if (mounted) {
        setState(() {
          _conversionResult = conversionResult;
          _isConverting = false;
          _conversionComplete = true;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              conversionResult.playlistCreated
                  ? 'Playlist created! ${conversionResult.successCount}/${conversionResult.total} songs found. You can download them from the playlist page.'
                  : 'Search complete! ${conversionResult.successCount}/${conversionResult.total} songs found.',
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConverting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CSV Playlist Converter',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Upload a CSV file to convert it to M4A audio files',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              // Upload button
              ElevatedButton.icon(
                onPressed: _isConverting ? null : _pickFile,
                icon: const Icon(Icons.upload_file),
                label: const Text('Select CSV File'),
              ),
              if (_uploadedFilename != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.description, color: primaryColor),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Selected: $_uploadedFilename',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              // Options
              ExpansionTile(
                title: const Text('Conversion Options'),
                children: [
                  SwitchListTile(
                    title: const Text('Exclude Instrumentals'),
                    subtitle: const Text('Skip instrumental versions'),
                    value: _excludeInstrumentals,
                    onChanged: _isConverting
                        ? null
                        : (value) {
                            if (mounted) {
                              setState(() {
                                _excludeInstrumentals = value;
                              });
                            }
                          },
                  ),
                  ListTile(
                    title: const Text('Min Duration (seconds)'),
                    trailing: SizedBox(
                      width: 100,
                      child: TextField(
                        enabled: !_isConverting,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        controller: _durationMinController,
                      ),
                    ),
                  ),
                  ListTile(
                    title: const Text('Max Duration (seconds)'),
                    trailing: SizedBox(
                      width: 100,
                      child: TextField(
                        enabled: !_isConverting,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        controller: _durationMaxController,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Progress indicator
        if (_isConverting)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    'Converting CSV to M4A files...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This may take a while depending on the playlist size',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        // Results
        if (_conversionComplete && _conversionResult != null)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _conversionResult!.playlistCreated
                                ? Icons.check_circle
                                : Icons.info_outline,
                            color: primaryColor,
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _conversionResult!.playlistCreated
                                  ? 'Playlist Created Successfully!'
                                  : 'Search Complete',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_conversionResult!.playlistName != null) ...[
                              Row(
                                children: [
                                  Icon(Icons.playlist_play, color: primaryColor, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Playlist: ${_conversionResult!.playlistName}',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                            ],
                            Row(
                              children: [
                                Icon(Icons.music_note, color: primaryColor, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  '${_conversionResult!.successCount}/${_conversionResult!.total} songs found',
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ],
                            ),
                            if (_conversionResult!.notFound.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${_conversionResult!.notFound.length} songs not found',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          color: Colors.orange,
                                        ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 16),
                            Text(
                              'You can now download the songs from the playlist page by clicking the download button.',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Colors.grey[400],
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else if (_conversionComplete && _conversionResult != null && _conversionResult!.tracks.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No files were converted',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  if (_conversionResult != null && _conversionResult!.notFound.isNotEmpty)
                    Text(
                      '${_conversionResult!.notFound.length} songs could not be found',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
            ),
          )
        else if (!_isConverting && _uploadedFilename == null)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.upload_file_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Select a CSV file to begin',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The CSV should contain columns: Track Name, Artist Name(s), Album Name',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
