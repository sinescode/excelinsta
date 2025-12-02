import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:excel/excel.dart' as excel;
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart'; // REQUIRED

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InstaCheck',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        primaryColor: Colors.indigo,
        scaffoldBackgroundColor: const Color(0xFFF9FAFB),
        cardColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
          ),
        ),
        colorScheme: ColorScheme.fromSwatch(primarySwatch: Colors.indigo)
            .copyWith(
          secondary: Colors.green,
          error: Colors.red,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // API Headers
  final Map<String, String> _headers = {
    "User-Agent":
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36",
    "x-ig-app-id": "936619743392459",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://www.instagram.com/",
    "Origin": "https://www.instagram.com",
    "Sec-Fetch-Site": "same-origin",
  };

  // Processing Configuration
  final int maxRetries = 5;
  final int initialDelay = 1000; // milliseconds
  final int maxDelay = 30000; // milliseconds
  final int concurrentLimit = 5; // Number of concurrent requests

  // State Variables
  PlatformFile? _selectedFile;
  String _originalFileName = '';
  List<String> _usernames = [];
  List<Map<String, dynamic>> _allExcelData = [];
  List<Map<String, dynamic>> _activeAccounts = [];

  // Counters
  int _processedCount = 0;
  int _activeCount = 0;
  int _availableCount = 0;
  int _errorCount = 0;
  int _cancelledCount = 0;

  // Processing State
  bool _isProcessing = false;
  Completer<void>? _canceller;
  Semaphore? _semaphore;
  final List<ResultItem> _results = [];

  @override
  void dispose() {
    if (_isProcessing) {
      _cancelProcessing();
    }
    super.dispose();
  }

  Future<void> _pickExcelFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
      );
      if (result != null) {
        _resetStats();
        _usernames.clear();
        _allExcelData.clear();

        setState(() {
          _selectedFile = result.files.first;
          _originalFileName =
              path.basenameWithoutExtension(_selectedFile!.name);
        });
        _showInfo('Excel file selected: ${_selectedFile!.name}');
      }
    } catch (e) {
      _showError('Error picking file: $e');
    }
  }

  Future<void> _startProcessingFromExcel() async {
    if (_selectedFile == null) {
      _showError('Please select an Excel file first');
      return;
    }

    if (_isProcessing) {
      _showInfo('Processing is already running.');
      return;
    }

    try {
      setState(() {
        _isProcessing = true;
      });

      Uint8List? bytes;
      if (_selectedFile!.bytes != null) {
        bytes = _selectedFile!.bytes!;
      } else if (_selectedFile!.path != null) {
        bytes = await File(_selectedFile!.path!).readAsBytes();
      } else {
        _showError('Cannot read file data');
        setState(() {
          _isProcessing = false;
        });
        return;
      }

      // Load data
      await _loadDataFromExcel(bytes);

      if (_usernames.isNotEmpty) {
        await _startProcessing();
      } else {
        _showError('No valid usernames to process.');
        setState(() {
          _isProcessing = false;
        });
      }
    } catch (e) {
      _showError('Error processing Excel file: $e');
      setState(() {
        _isProcessing = false;
      });
    }
  }

  /// FIXED: Robust Excel Loader (Prevents Null Check Crash)
  Future<void> _loadDataFromExcel(Uint8List bytes) async {
    _resetStats();
    try {
      var excelFile = excel.Excel.decodeBytes(bytes);

      if (excelFile.tables.isEmpty) {
        throw Exception('No sheets found in Excel file');
      }

      // Safe access to the first table
      var table = excelFile.tables[excelFile.tables.keys.first];
      if (table == null || table.maxRows == 0) {
        throw Exception('Sheet is empty');
      }

      int usernameColumnIndex = -1;
      List<String> headers = [];

      // Safe Header Processing
      var headerRow = table.rows.isNotEmpty ? table.rows[0] : [];
      for (int j = 0; j < headerRow.length; j++) {
        var cell = headerRow[j];
        // FIX: Check for null cell and null value
        String headerText = (cell?.value ?? '').toString().trim();
        headers.add(headerText.toUpperCase());
        if (headerText.toLowerCase().contains('username') || 
            headerText.toLowerCase() == 'user') {
          usernameColumnIndex = j;
        }
      }

      if (usernameColumnIndex == -1) {
        usernameColumnIndex = 0;
        _showInfo('No "username" header found. Using first column.');
      }

      _usernames.clear();
      _allExcelData.clear();

      // Process Rows safely
      for (int i = 1; i < table.rows.length; i++) {
        var row = table.rows[i];
        if (row.isEmpty) continue;

        Map<String, dynamic> rowData = {};
        String username = '';

        for (int j = 0; j < headers.length; j++) {
          String key = headers[j];
          // FIX: Check bounds (row might be shorter than headers)
          var cell = (j < row.length) ? row[j] : null;
          rowData[key] = (cell?.value ?? '').toString();
        }

        // Get Username safely
        var usernameCell = (usernameColumnIndex < row.length) ? row[usernameColumnIndex] : null;
        username = (usernameCell?.value ?? '').toString().trim();

        if (username.isNotEmpty && username.toLowerCase() != 'null') {
          _usernames.add(username);
          _allExcelData.add(rowData);
        }
      }

      if (_usernames.isEmpty) {
        throw Exception('No valid usernames found (checked ${_allExcelData.length} rows)');
      }

      _showInfo('Loaded ${_usernames.length} rows');
    } catch (e) {
      // Re-throw to be caught by caller
      throw Exception('Excel Load Error: $e');
    }
  }

  Future<void> _startProcessing() async {
    if (_usernames.isEmpty) return;

    _resetStats();
    _canceller = Completer();
    _semaphore = Semaphore(concurrentLimit);
    final client = http.Client();

    try {
      final futures = <Future>[];
      for (int i = 0; i < _usernames.length; i++) {
        final username = _usernames[i];
        final rowData = _allExcelData[i];

        futures.add(Future.microtask(() => _processWithSemaphore(() async {
              if (_canceller!.isCompleted) {
                _updateResult('CANCELLED', 'Cancelled: $username', username);
                return;
              }
              await _checkUsername(client, username, rowData);
            })));
      }

      await Future.wait(futures);

      if (!_canceller!.isCompleted) {
        setState(() {
          _isProcessing = false;
        });
        _showSuccess(
            'Processing completed! Found $_activeCount active accounts.');
      }
    } catch (e) {
      _showError('Processing error: $e');
      setState(() {
        _isProcessing = false;
      });
    } finally {
      client.close();
    }
  }

  Future<void> _processWithSemaphore(Future<void> Function() task) async {
    if (_semaphore == null) return;
    await _semaphore!.acquire();
    try {
      await task();
    } finally {
      await _semaphore!.release();
    }
  }

  Future<void> _checkUsername(http.Client client, String username,
      Map<String, dynamic> rowData) async {
    final url = Uri.parse(
        'https://i.instagram.com/api/v1/users/web_profile_info/?username=$username');
    int retryCount = 0;
    double delayMs = initialDelay.toDouble();

    while (retryCount < maxRetries) {
      if (_canceller!.isCompleted) return;

      try {
        final response = await client.get(url, headers: _headers).timeout(
              const Duration(seconds: 15),
            );

        final code = response.statusCode;

        if (code == 404) {
          _updateResult('AVAILABLE', '$username - Not Found', username);
          return;
        } else if (code == 200) {
          try {
            final jsonBody = jsonDecode(response.body);
            final hasUser = jsonBody['data']?['user'] != null;

            if (hasUser) {
              _updateResult('ACTIVE', '$username - Active', username);
              _activeAccounts.add(rowData);
            } else {
              _updateResult('AVAILABLE', '$username - No Data', username);
            }
          } catch (e) {
             // Sometimes 200 OK returns HTML if blocked, treat as error or retry
             _updateResult('ERROR', '$username - Parse Error', username);
          }
          return;
        } else if (code == 429) {
          // Rate Limit
          delayMs = min(maxDelay.toDouble(), delayMs * 2);
          retryCount++;
          _updateStatus('Rate Limit $username. Waiting...', username);
        } else {
          delayMs = min(maxDelay.toDouble(), delayMs * 1.5);
          retryCount++;
        }
      } catch (e) {
        retryCount++;
      }

      if (retryCount < maxRetries) {
        await Future.delayed(Duration(milliseconds: delayMs.toInt()));
      }
    }

    _updateResult('ERROR', '$username - Failed', username);
  }

  void _updateResult(String status, String message, String username) {
    if (!mounted) return;
    setState(() {
      _processedCount++;
      switch (status) {
        case 'ACTIVE':
          _activeCount++;
          break;
        case 'AVAILABLE':
          _availableCount++;
          break;
        case 'ERROR':
          _errorCount++;
          break;
        case 'CANCELLED':
           // Handled in batch usually
          break;
      }
      _results.insert(0, ResultItem(status, message));
      if (_results.length > 200) _results.removeLast();
    });
  }

  void _updateStatus(String message, String username) {
    if (!mounted) return;
    setState(() {
      _results.insert(0, ResultItem('INFO', message));
      if (_results.length > 200) _results.removeLast();
    });
  }

  void _resetStats() {
    _processedCount = 0;
    _activeCount = 0;
    _availableCount = 0;
    _errorCount = 0;
    _cancelledCount = 0;
    _activeAccounts.clear();
    _results.clear();
    if (mounted) setState(() {});
  }

  void _cancelProcessing() {
    if (!(_canceller?.isCompleted ?? true)) {
      _canceller?.complete();
    }
    _semaphore?.releaseAll();
    setState(() {
      _isProcessing = false;
    });
    _showInfo('Processing cancelled.');
  }

  /// FIXED: Permission Handling and Path Creation
  Future<bool> _requestStoragePermission() async {
    // Android 11+ (API 30+) needs minimal permissions for public folders like Downloads
    // Android 10 and below needs strict Storage permission
    if (Platform.isAndroid) {
        // Try requesting storage permission first
        var status = await Permission.storage.request();
        if (status.isGranted) return true;
        
        // If Android 13+, Manage External Storage might be needed for root, 
        // but we will use public Downloads folder to avoid rejection.
        // Checking for manageExternalStorage is dangerous for Play Store apps unless valid use case.
        if (await Permission.storage.isPermanentlyDenied) {
           openAppSettings();
           return false;
        }
    }
    return true;
  }

  Future<void> _downloadResults() async {
    if (_activeAccounts.isEmpty) {
      _showError('No active accounts to download');
      return;
    }

    // 1. Request Permission
    // On Android 13+, explicit storage permission might not be needed for getExternalStoragePublicDirectory(Downloads)
    // but good to check basic permissions.
    await _requestStoragePermission();

    try {
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '');
      final fileName = 'active_${_originalFileName}_$timestamp.xlsx';

      // 2. FIXED: Determine Safe Save Path
      String? savePath;
      
      if (Platform.isAndroid) {
        // Try to get the public Download directory
        final directory = await getExternalStorageDirectory(); // App specific
        // OR Use this for public downloads (may require permissions on older android)
        // Directory('/storage/emulated/0/Download'); 
        
        // Strategy: Save to App Documents (guaranteed success) or Downloads
        Directory? downloadDir;
        try {
           downloadDir = Directory('/storage/emulated/0/Download');
           if (!await downloadDir.exists()) {
             downloadDir = await getExternalStorageDirectory();
           }
        } catch (e) {
           downloadDir = await getApplicationDocumentsDirectory();
        }
        
        savePath = path.join(downloadDir!.path, 'InstaCheck_Results');
      } else {
        final directory = await getApplicationDocumentsDirectory();
        savePath = directory.path;
      }

      final saveDir = Directory(savePath);
      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }

      final filePath = path.join(saveDir.path, fileName);

      // 3. Create Excel
      var excelFile = excel.Excel.createExcel();
      // Remove default sheet safely
      if(excelFile.sheets.containsKey('Sheet1')) {
         excelFile.delete('Sheet1');
      }
      
      excel.Sheet sheet = excelFile['Active Accounts'];
      
      if (_activeAccounts.isNotEmpty) {
        sheet.appendRow(_activeAccounts[0]
            .keys
            .map((key) => excel.TextCellValue(key.toUpperCase()))
            .toList());
      }
      for (var row in _activeAccounts) {
        sheet.appendRow(row.values
            .map((value) => excel.TextCellValue(value.toString()))
            .toList());
      }

      final excelBytes = excelFile.encode();
      if (excelBytes != null) {
        File(filePath)
          ..createSync(recursive: true)
          ..writeAsBytesSync(excelBytes);
        _showSuccess('Saved to: $filePath');
      } else {
        _showError('Failed to encode Excel file');
      }
    } catch (e) {
      _showError('Error saving: $e');
    }
  }

  void _showSuccess(String message) {
    Fluttertoast.showToast(
      msg: message,
      backgroundColor: Colors.green,
      textColor: Colors.white,
      toastLength: Toast.LENGTH_LONG,
    );
  }

  void _showError(String message) {
    Fluttertoast.showToast(
      msg: message,
      backgroundColor: Colors.red,
      textColor: Colors.white,
      toastLength: Toast.LENGTH_LONG,
    );
  }

  void _showInfo(String message) {
    Fluttertoast.showToast(
      msg: message,
      backgroundColor: Colors.blue,
      textColor: Colors.white,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Insta Checker Fixed',
          style: TextStyle(color: Color(0xFF4F46E5), fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 5))
            ],
          ),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildExcelImportUI(),
                      if (_selectedFile != null) ..._buildResultsUI(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExcelImportUI() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Import Excel',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Select an Excel file with a "username" column.',
            style: TextStyle(color: Colors.grey[600])),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _isProcessing ? null : _pickExcelFile,
          icon: Icon(_selectedFile != null ? Icons.check : Icons.upload_file),
          label: Text(_selectedFile?.name ?? 'Select File'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _selectedFile != null
                ? Colors.green[100]
                : const Color(0xFF4F46E5),
            foregroundColor:
                _selectedFile != null ? Colors.green[800] : Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        if (_selectedFile != null)
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _startProcessingFromExcel,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start Checking'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
          ),
      ],
    );
  }

  List<Widget> _buildResultsUI() {
    int total = _usernames.length;
    double percent = total == 0 ? 0 : (_processedCount / total);

    return [
      const SizedBox(height: 20),
      LinearProgressIndicator(value: percent, minHeight: 10, backgroundColor: Colors.grey[200]),
      const SizedBox(height: 10),
      Text('Processed: $_processedCount / $total', textAlign: TextAlign.center),
      const SizedBox(height: 20),
      Row(
        children: [
          Expanded(child: _statCard('Active', '$_activeCount', Colors.green[100]!)),
          const SizedBox(width: 8),
          Expanded(child: _statCard('Invalid', '$_availableCount', Colors.orange[100]!)),
        ],
      ),
      const SizedBox(height: 20),
      if (!_isProcessing && _activeCount > 0)
        ElevatedButton.icon(
          onPressed: _downloadResults,
          icon: const Icon(Icons.download),
          label: const Text('Download Active Accounts'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
        ),
      if (_isProcessing)
        ElevatedButton.icon(
           onPressed: _cancelProcessing,
           icon: const Icon(Icons.stop),
           label: const Text('Stop Processing'),
           style: ElevatedButton.styleFrom(backgroundColor: Colors.grey),
        ),
        
      const SizedBox(height: 10),
      Container(
        height: 200,
        decoration: BoxDecoration(border: Border.all(color: Colors.grey[300]!)),
        child: ListView.builder(
          itemCount: _results.length,
          itemBuilder: (c, i) => Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            color: _results[i].status == 'ACTIVE' ? Colors.green[50] : Colors.white,
            child: Text(_results[i].message, style: const TextStyle(fontSize: 12)),
          ),
        ),
      )
    ];
  }

  Widget _statCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class ResultItem {
  final String status;
  final String message;
  ResultItem(this.status, this.message);
}

// Fixed Semaphore Implementation
class Semaphore {
  int _permits;
  final Queue<Completer<void>> _waiters = Queue();
  final Lock _lock = Lock();
  final int _concurrentLimit;

  Semaphore(int permits)
      : _permits = permits,
        _concurrentLimit = permits;

  Future<void> acquire() async {
    Completer<void>? myWaiter;
    await _lock.synchronized(() {
      if (_permits > 0) {
        _permits--;
        myWaiter = null;
      } else {
        myWaiter = Completer<void>();
        _waiters.add(myWaiter!);
      }
    });
    if (myWaiter != null) {
      await myWaiter!.future;
    }
  }

  Future<void> release() async {
    await _lock.synchronized(() {
      if (_waiters.isNotEmpty) {
        final c = _waiters.removeFirst();
        c.complete();
      } else {
        _permits++;
      }
    });
  }

  Future<void> releaseAll() async {
    await _lock.synchronized(() {
      while (_waiters.isNotEmpty) {
        final c = _waiters.removeFirst();
        c.complete();
      }
      _permits = _concurrentLimit;
    });
  }
}
