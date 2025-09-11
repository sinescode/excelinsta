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

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InstaCheck',
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
          ),
        ),
        colorScheme: ColorScheme.fromSwatch(primarySwatch: Colors.indigo).copyWith(
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
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0 Safari/537.36",
    "x-ig-app-id": "936619743392459",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://www.instagram.com/",
    "Origin": "https://www.instagram.com",
    "Sec-Fetch-Site": "same-origin",
  };

  // Processing Configuration
  final int maxRetries = 10;
  final int initialDelay = 1000; // milliseconds
  final int maxDelay = 60000; // milliseconds
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
    super.dispose();
  }

  Future<void> _pickExcelFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
      );
      if (result != null) {
        setState(() {
          _selectedFile = result.files.first;
          _originalFileName = path.basenameWithoutExtension(_selectedFile!.name);
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

    try {
      // Read file bytes
      Uint8List? bytes;
      if (_selectedFile!.bytes != null) {
        bytes = _selectedFile!.bytes!;
      } else if (_selectedFile!.path != null) {
        bytes = await File(_selectedFile!.path!).readAsBytes();
      } else {
        _showError('Cannot read file data');
        return;
      }

      await _loadDataFromExcel(bytes);
      await _startProcessing();
    } catch (e) {
      _showError('Error processing Excel file: $e');
    }
  }

  Future<void> _loadDataFromExcel(Uint8List bytes) async {
    try {
      var excelFile = excel.Excel.decodeBytes(bytes);
      var sheet = excelFile.tables[excelFile.tables.keys.first];
      
      if (sheet == null) {
        throw Exception('No sheets found in Excel file');
      }

      // Find the username column
      int usernameColumnIndex = -1;
      List<String> headers = [];
      
      // Get headers from first row
      for (var cell in sheet.rows[0]) {
        if (cell != null) {
          headers.add(cell.value.toString());
          if (cell.value.toString().toLowerCase() == 'username') {
            usernameColumnIndex = cell.columnIndex;
          }
        }
      }

      if (usernameColumnIndex == -1) {
        throw Exception('No "username" column found in Excel file');
      }

      _usernames.clear();
      _allExcelData.clear();

      // Process all rows (skip the header row)
      for (int i = 1; i < sheet.rows.length; i++) {
        var row = sheet.rows[i];
        Map<String, dynamic> rowData = {};
        
        // Extract all data from the row
        for (int j = 0; j < headers.length; j++) {
          if (j < row.length && row[j] != null) {
            rowData[headers[j]] = row[j]!.value.toString();
          } else {
            rowData[headers[j]] = '';
          }
        }
        
        // Get username from the identified column
        String username = '';
        if (row.length > usernameColumnIndex && row[usernameColumnIndex] != null) {
          username = row[usernameColumnIndex]!.value.toString().trim();
        }
        
        if (username.isNotEmpty) {
          _usernames.add(username);
          _allExcelData.add(rowData);
        }
      }

      if (_usernames.isEmpty) {
        throw Exception('No valid usernames found in Excel file');
      }

      _showInfo('Loaded ${_usernames.length} rows from Excel');
    } catch (e) {
      _showError('Error loading data from Excel: $e');
      rethrow;
    }
  }

  Future<void> _startProcessing() async {
    if (_usernames.isEmpty) {
      _showError('No valid usernames found');
      return;
    }

    _resetStats();
    setState(() {
      _isProcessing = true;
    });

    _canceller = Completer();
    _semaphore = Semaphore(concurrentLimit);
    final client = http.Client();

    try {
      final futures = <Future>[];
      for (int i = 0; i < _usernames.length; i++) {
        final username = _usernames[i];
        final rowData = _allExcelData[i];
        
        futures.add(_processWithSemaphore(() async {
          if (_canceller!.isCompleted) return;
          await _checkUsername(client, username, rowData);
        }));
      }

      await Future.wait(futures);
      
      if (!_canceller!.isCompleted) {
        setState(() {
          _isProcessing = false;
        });
        _showSuccess('Processing completed! Found $_activeCount active accounts.');
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
    await _semaphore!.acquire();
    try {
      await task();
    } finally {
      await _semaphore!.release();
    }
  }

  Future<void> _checkUsername(http.Client client, String username, Map<String, dynamic> rowData) async {
    final url = Uri.parse('https://i.instagram.com/api/v1/users/web_profile_info/?username=$username');
    int retryCount = 0;
    double delayMs = initialDelay.toDouble();

    while (retryCount < maxRetries) {
      if (_canceller!.isCompleted) {
        _updateResult('CANCELLED', 'Cancelled: $username', username);
        return;
      }

      try {
        final response = await client.get(url, headers: _headers).timeout(
          const Duration(seconds: 30),
        );
        
        final code = response.statusCode;

        if (code == 404) {
          _updateResult('AVAILABLE', '$username - Available', username);
          return;
        } else if (code == 200) {
          try {
            final jsonBody = jsonDecode(response.body);
            final hasUser = jsonBody['data']?['user'] != null;
            
            if (hasUser) {
              _updateResult('ACTIVE', '$username - Active', username);
              // Add the complete row data for active accounts
              _activeAccounts.add(rowData);
            } else {
              _updateResult('AVAILABLE', '$username - Available', username);
            }
          } catch (e) {
            _updateResult('ERROR', '$username - JSON Parse Error', username);
          }
          return;
        } else if (code == 429) {
          // Rate limited: increase backoff
          delayMs = min(maxDelay.toDouble(), delayMs * 2 + Random().nextInt(1000));
          retryCount++;
          _updateStatus('Rate limited for $username, waiting ${delayMs.toInt()}ms...', username);
        } else {
          // Other unexpected statuses: backoff + retry
          delayMs = min(maxDelay.toDouble(), delayMs * 2 + Random().nextInt(1000));
          retryCount++;
          _updateStatus('Retry $retryCount/$maxRetries for $username (Status: $code)', username);
        }
      } catch (e) {
        // network/timeout/etc -> backoff + retry
        delayMs = min(maxDelay.toDouble(), delayMs * 2 + Random().nextInt(1000));
        retryCount++;
        final errorMsg = e.toString();
        final shortMsg = errorMsg.length > 30 ? '${errorMsg.substring(0, 30)}...' : errorMsg;
        _updateStatus('Retry $retryCount/$maxRetries for $username ($shortMsg)', username);
      }

      if (retryCount < maxRetries) {
        await Future.delayed(Duration(milliseconds: delayMs.toInt()));
      }
    }

    _updateResult('ERROR', '$username - Max retries exceeded', username);
  }

  void _updateResult(String status, String message, String username) {
    if (mounted) {
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
            _cancelledCount++;
            break;
        }
        _results.insert(0, ResultItem(status, message));
        
        // Keep only last 100 results to prevent memory issues
        if (_results.length > 100) {
          _results.removeLast();
        }
      });
    }
  }

  void _updateStatus(String message, String username) {
    if (mounted) {
      setState(() {
        _results.insert(0, ResultItem('INFO', message));
        if (_results.length > 10000) {
          _results.removeLast();
        }
      });
    }
  }

  void _resetStats() {
    _processedCount = 0;
    _activeCount = 0;
    _availableCount = 0;
    _errorCount = 0;
    _cancelledCount = 0;
    _activeAccounts.clear();
    _results.clear();
    setState(() {});
  }

  void _cancelProcessing() {
    if (!(_canceller?.isCompleted ?? true)) {
      _canceller?.complete();
    }
    setState(() {
      _isProcessing = false;
    });
    _showInfo('Processing cancelled');
  }

  Future<void> _downloadResults() async {
    if (_activeAccounts.isEmpty) {
      _showError('No active accounts to download');
      return;
    }

    try {
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
      final fileName = 'active_accounts_${_originalFileName}_$timestamp.xlsx';
      
      // Get the downloads directory and create insta_saver folder
      final Directory downloadsDir = Directory('/storage/emulated/0/Download');
      final Directory saveDir = Directory('${downloadsDir.path}/insta_saver');
      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }
      
      final filePath = path.join(saveDir.path, fileName);
      
      // Create Excel workbook
      var excelFile = excel.Excel.createExcel();
      excel.Sheet sheet = excelFile['Sheet1'];

      // Add headers
      if (_activeAccounts.isNotEmpty) {
        sheet.appendRow(_activeAccounts[0].keys.map((key) => excel.TextCellValue(key)).toList());
      }

      // Add data rows
      for (var row in _activeAccounts) {
        sheet.appendRow(row.values.map((value) => excel.TextCellValue(value.toString())).toList());
      }

      // Save Excel file
      final excelBytes = excelFile.encode();
      if (excelBytes != null) {
        await File(filePath).writeAsBytes(excelBytes);
        _showSuccess('Results saved to ${saveDir.path}/$fileName (${_activeAccounts.length} active accounts)');
      } else {
        _showError('Failed to encode Excel file');
      }
    } catch (e) {
      _showError('Error saving results: $e');
    }
  }

  // Utility Methods
  void _showSuccess(String message) {
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
      backgroundColor: Colors.green,
      textColor: Colors.white,
    );
  }

  void _showError(String message) {
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
      backgroundColor: Colors.red,
      textColor: Colors.white,
    );
  }

  void _showInfo(String message) {
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      backgroundColor: Colors.blue,
      textColor: Colors.white,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.camera_alt, color: Colors.pink[400]),
            const SizedBox(width: 8),
            const Text(
              'Instagram Username Checker',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFF4F46E5),
              ),
            ),
          ],
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.1),
                spreadRadius: 1,
                blurRadius: 10,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildExcelImportUI(),
                      if (_usernames.isNotEmpty) ..._buildResultsUI(),
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
        const Text(
          'Import Excel File',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFF4F46E5),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Upload an Excel file with a "username" column to check Instagram accounts. All data will be preserved for active accounts.',
          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _isProcessing ? null : _pickExcelFile,
          icon: _selectedFile != null
              ? const Icon(Icons.check_circle, color: Colors.green)
              : const Icon(Icons.attach_file),
          label: Text(_selectedFile?.name ?? 'Pick Excel File'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _selectedFile != null ? Colors.green[50] : const Color(0xFF4F46E5),
            foregroundColor: _selectedFile != null ? Colors.green[700] : Colors.white,
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _isProcessing ? null : _startProcessingFromExcel,
          icon: const Icon(Icons.search),
          label: const Text('Start Checking'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red[600],
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildResultsUI() {
    final percentage = _usernames.isNotEmpty ? (_processedCount * 100 / _usernames.length) : 0.0;
    
    return [
      const SizedBox(height: 24),
      const Text(
        'Progress',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Color(0xFF4F46E5),
        ),
      ),
      const SizedBox(height: 12),
      Container(
        height: 8,
        decoration: BoxDecoration(
          color: Colors.grey[200],
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: percentage / 100,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.green[600],
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Processed: $_processedCount/${_usernames.length} (${percentage.toStringAsFixed(1)}%)',
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(child: _buildStatCard('Active', _activeCount.toString(), Colors.red[50]!, Colors.red[600]!)),
          const SizedBox(width: 12),
          Expanded(child: _buildStatCard('Available', _availableCount.toString(), Colors.green[50]!, Colors.green[700]!)),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(child: _buildStatCard('Error', _errorCount.toString(), Colors.orange[50]!, Colors.orange[700]!)),
          const SizedBox(width: 12),
          Expanded(child: _buildStatCard('Total', _usernames.length.toString(), Colors.blue[50]!, Colors.blue[700]!)),
        ],
      ),
      const SizedBox(height: 16),
      if (_isProcessing)
        ElevatedButton.icon(
          onPressed: _cancelProcessing,
          icon: const Icon(Icons.close),
          label: const Text('Cancel'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red[600],
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
      if (!_isProcessing && _activeAccounts.isNotEmpty)
        ElevatedButton.icon(
          onPressed: _downloadResults,
          icon: const Icon(Icons.download),
          label: const Text('Download Active Accounts'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green[600],
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
      const SizedBox(height: 16),
      const Text(
        'Results',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Color(0xFF4F46E5),
        ),
      ),
      const SizedBox(height: 8),
      Container(
        constraints: const BoxConstraints(maxHeight: 300),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _results.length,
          itemBuilder: (context, index) {
            final item = _results[index];
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _getBackgroundColor(item.status),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _getBorderColor(item.status)),
              ),
              child: Row(
                children: [
                  Icon(
                    _getIcon(item.status),
                    color: _getTextColor(item.status),
                    size: 16,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.message,
                      style: TextStyle(
                        color: _getTextColor(item.status),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ];
  }

  Widget _buildStatCard(String label, String value, Color backgroundColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: textColor.withOpacity(0.2)),
      ),
      child: Column(
        children: [
      Text(
        value,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: textColor,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: textColor.withOpacity(0.8),
        ),
      ),
        ],
      ),
    );
  }

  IconData _getIcon(String status) {
    switch (status) {
      case 'ACTIVE':
        return Icons.verified_user;
      case 'AVAILABLE':
        return Icons.person_add;
      case 'ERROR':
        return Icons.error;
      case 'CANCELLED':
        return Icons.cancel;
      case 'INFO':
        return Icons.info;
      default:
        return Icons.help;
    }
  }

  Color _getBackgroundColor(String status) {
    switch (status) {
      case 'ACTIVE':
        return Colors.red[50]!;
      case 'AVAILABLE':
        return Colors.green[50]!;
      case 'ERROR':
        return Colors.orange[50]!;
      case 'CANCELLED':
        return Colors.grey[50]!;
      case 'INFO':
        return Colors.blue[50]!;
      default:
        return Colors.grey[50]!;
    }
  }

  Color _getBorderColor(String status) {
    switch (status) {
      case 'ACTIVE':
        return Colors.red[100]!;
      case 'AVAILABLE':
        return Colors.green[100]!;
      case 'ERROR':
        return Colors.orange[100]!;
      case 'CANCELLED':
        return Colors.grey[100]!;
      case 'INFO':
        return Colors.blue[100]!;
      default:
        return Colors.grey[100]!;
    }
  }

  Color _getTextColor(String status) {
    switch (status) {
      case 'ACTIVE':
        return Colors.red[700]!;
      case 'AVAILABLE':
        return Colors.green[700]!;
      case 'ERROR':
        return Colors.orange[700]!;
      case 'CANCELLED':
        return Colors.grey[700]!;
      case 'INFO':
        return Colors.blue[700]!;
      default:
        return Colors.grey[700]!;
    }
  }
}

class ResultItem {
  final String status;
  final String message;

  ResultItem(this.status, this.message);
}

/// Fixed Semaphore:
/// - Does NOT await inside the lock (avoids deadlock)
/// - `acquire()` returns when a permit is available
/// - `release()` completes a waiter or returns a permit
class Semaphore {
  int _permits;
  final Queue<Completer<void>> _waiters = Queue();
  final Lock _lock = Lock();

  Semaphore(this._permits);

  /// Acquire a permit. If none available, wait until released.
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

  /// Release a permit; if waiters exist, wake the first.
  Future<void> release() async {
    await _lock.synchronized(() {
      if (_waiters.isNotEmpty) {
        final c = _waiters.removeFirst();
        // complete outside the lock is not necessary but allowed; completer.complete() is quick.
        c.complete();
      } else {
        _permits++;
      }
    });
  }
}