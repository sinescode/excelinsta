import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// Note: For heavy computation like excel decoding, it's best practice
// to use 'package:flutter/foundation.dart' and the 'compute' function
// to run in an Isolate, preventing UI jank/ANR on large files.
// For simplicity and since 'foundation.dart' wasn't included,
// the logic is made more asynchronous but remains on the main thread.
// Import 'package:flutter/foundation.dart' for compute if needed.

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
    "x-ig-app-id": "936619743392459", // This is brittle and might break if Instagram changes it.
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
    // Cancel processing if the widget is disposed while active
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
        // Clear previous data when a new file is picked
        _resetStats();
        _usernames.clear();
        _allExcelData.clear();
        
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
    
    // Safety check to prevent starting if already processing
    if (_isProcessing) {
      _showInfo('Processing is already running.');
      return;
    }

    try {
      // Set processing flag early to disable buttons
      setState(() {
        _isProcessing = true;
      });

      // Read file bytes
      Uint8List? bytes;
      if (_selectedFile!.bytes != null) {
        bytes = _selectedFile!.bytes!;
      } else if (_selectedFile!.path != null) {
        // Use File().readAsBytes() as a robust way to get bytes from path
        bytes = await File(_selectedFile!.path!).readAsBytes();
      } else {
        _showError('Cannot read file data');
        setState(() { _isProcessing = false; });
        return;
      }
      
      // Load and parse data (will happen on the main thread, but is async)
      await _loadDataFromExcel(bytes);

      // Only start checking if usernames were successfully loaded
      if (_usernames.isNotEmpty) {
        await _startProcessing();
      } else {
        _showError('No valid usernames to process.');
        setState(() { _isProcessing = false; });
      }

    } catch (e) {
      _showError('Error processing Excel file: $e');
      setState(() { _isProcessing = false; });
    }
  }

  // Large File/ANR Fix: This method is still on the main thread but is
  // asynchronous. For truly massive files (100k+ rows), this should be
  // run in a separate Isolate using compute() to prevent ANR.
  Future<void> _loadDataFromExcel(Uint8List bytes) async {
    _resetStats(); // Clear previous results before loading new data
    try {
      // Decode the Excel file bytes
      var excelFile = excel.Excel.decodeBytes(bytes);
      var sheet = excelFile.tables[excelFile.tables.keys.first];
      
      if (sheet == null || sheet.maxRows == 0) {
        throw Exception('No sheets or data found in Excel file');
      }

      // --- LOGIC FIX: Find the username column (Header check first) ---
      int usernameColumnIndex = -1;
      List<String> headers = [];
      
      // Get headers from first row (Row 0)
      var headerRow = sheet.rows[0];
      for (int j = 0; j < headerRow.length; j++) {
        var cell = headerRow[j];
        String headerText = cell != null ? cell.value.toString().trim().toLowerCase() : '';
        headers.add(headerText.toUpperCase()); // Store uppercase for consistent map keys
        if (headerText == 'username') {
          usernameColumnIndex = j;
        }
      }

      // Bug Fix/New Logic: If 'username' header not found, default to the first column (index 0)
      if (usernameColumnIndex == -1) {
        usernameColumnIndex = 0;
        _showInfo('No "username" column header found. Defaulting to the first column (index 0).');
      }

      _usernames.clear();
      _allExcelData.clear();

      // Process all data rows (starting from Row 1)
      for (int i = 1; i < sheet.rows.length; i++) {
        var row = sheet.rows[i];
        Map<String, dynamic> rowData = {};
        String username = '';

        // Extract all data from the row
        for (int j = 0; j < headers.length; j++) {
          String key = headers[j];
          if (j < row.length && row[j] != null) {
            rowData[key] = row[j]!.value.toString();
          } else {
            rowData[key] = '';
          }
        }
        
        // Get username from the identified column
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
      _showError('Error loading data from Excel: ${e.toString()}');
      rethrow;
    }
  }

  Future<void> _startProcessing() async {
    if (_usernames.isEmpty) {
      // Already checked, but good to have
      _showError('No valid usernames found');
      setState(() { _isProcessing = false; });
      return;
    }

    _resetStats(); // Reset stats again before starting the HTTP process
    
    // Note: _isProcessing is already set to true in _startProcessingFromExcel

    _canceller = Completer();
    _semaphore = Semaphore(concurrentLimit);
    final client = http.Client();

    try {
      final futures = <Future>[];
      for (int i = 0; i < _usernames.length; i++) {
        final username = _usernames[i];
        final rowData = _allExcelData[i];
        
        // Use Future.microtask to queue the semaphore acquisition for better scheduling
        futures.add(Future.microtask(() => _processWithSemaphore(() async {
          if (_canceller!.isCompleted) {
             // Increment cancelled count if processing stops before execution
             _updateResult('CANCELLED', 'Cancelled: $username', username);
             return;
          }
          await _checkUsername(client, username, rowData);
        })));
      }

      // Wait for all checks to complete or the process to be cancelled
      await Future.wait(futures);
      
      // Update UI state only if not explicitly cancelled
      if (!_canceller!.isCompleted) {
        setState(() {
          _isProcessing = false;
        });
        _showSuccess('Processing completed! Found $_activeCount active accounts.');
      }
    } catch (e) {
      // Catch-all for unexpected errors during Future.wait
      _showError('Processing error: $e');
      setState(() {
        _isProcessing = false;
      });
    } finally {
      client.close();
    }
  }

  Future<void> _processWithSemaphore(Future<void> Function() task) async {
    // Ensure semaphore is not null before acquiring
    if (_semaphore == null) return;

    await _semaphore!.acquire();
    try {
      await task();
    } finally {
      // Ensure release is always called
      await _semaphore!.release();
    }
  }

  Future<void> _checkUsername(http.Client client, String username, Map<String, dynamic> rowData) async {
    final url = Uri.parse('https://i.instagram.com/api/v1/users/web_profile_info/?username=$username');
    int retryCount = 0;
    double delayMs = initialDelay.toDouble();

    while (retryCount < maxRetries) {
      if (_canceller!.isCompleted) {
        // If cancelled, ensure the final result is recorded
        _updateResult('CANCELLED', 'Cancelled: $username', username);
        return;
      }

      try {
        final response = await client.get(url, headers: _headers).timeout(
          const Duration(seconds: 30),
        );
        
        final code = response.statusCode;

        if (code == 404) {
          // 404 Not Found typically means the account is available/not registered
          _updateResult('AVAILABLE', '$username - Available', username);
          return;
        } else if (code == 200) {
          // Success: Analyze the body
          try {
            final jsonBody = jsonDecode(response.body);
            // Check for the presence of the user object in the response data
            final hasUser = jsonBody['data']?['user'] != null;
            
            if (hasUser) {
              _updateResult('ACTIVE', '$username - Active', username);
              // Add the complete row data for active accounts
              _activeAccounts.add(rowData);
            } else {
              // Sometimes 200 might return no user data for other reasons (e.g., private API key issue, or another form of availability)
              _updateResult('AVAILABLE', '$username - Available (No User Data)', username);
            }
          } catch (e) {
            // JSON parsing error (e.g., malformed response body)
            _updateResult('ERROR', '$username - JSON Parse Error', username);
          }
          return;
        } else if (code == 429) {
          // Rate limited: increase backoff
          delayMs = min(maxDelay.toDouble(), delayMs * 2 + Random().nextInt(1000));
          retryCount++;
          _updateStatus('Rate limited for $username, waiting ${delayMs.toInt()}ms...', username);
        } else {
          // Other unexpected statuses (e.g., 500 server error): backoff + retry
          delayMs = min(maxDelay.toDouble(), delayMs * 2 + Random().nextInt(1000));
          retryCount++;
          _updateStatus('Retry $retryCount/$maxRetries for $username (Status: $code)', username);
        }
      } on TimeoutException {
        // Network timeout: backoff + retry
        delayMs = min(maxDelay.toDouble(), delayMs * 2 + Random().nextInt(1000));
        retryCount++;
        _updateStatus('Retry $retryCount/$maxRetries for $username (Timeout)', username);
      } catch (e) {
        // General network/IO error -> backoff + retry
        delayMs = min(maxDelay.toDouble(), delayMs * 2 + Random().nextInt(1000));
        retryCount++;
        final errorMsg = e.toString();
        final shortMsg = errorMsg.length > 50 ? '${errorMsg.substring(0, 47)}...' : errorMsg;
        _updateStatus('Retry $retryCount/$maxRetries for $username ($shortMsg)', username);
      }

      if (retryCount < maxRetries) {
        await Future.delayed(Duration(milliseconds: delayMs.toInt()));
      }
    }

    // If loop finishes without returning, max retries were exceeded
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
            // Only increment if it wasn't already processed (a potential bug fix)
            if (_usernames.length > _processedCount + _activeCount + _availableCount + _errorCount) {
                _cancelledCount++;
            }
            break;
        }
        _results.insert(0, ResultItem(status, message));
        
        // Keep only last 100 results to prevent memory issues in the UI log
        if (_results.length > 100) {
          _results.removeLast();
        }
      });
    }
  }

  void _updateStatus(String message, String username) {
    if (mounted) {
      // Use setState to update the log with INFO messages
      setState(() {
        _results.insert(0, ResultItem('INFO', message));
        // Keep a larger buffer for temporary status logs
        if (_results.length > 1000) {
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
    // Only call setState if we are actually mounted, though the caller should handle this
    if(mounted) {
      setState(() {});
    }
  }

  void _cancelProcessing() {
    // Complete the canceller to signal all running tasks to stop
    if (!(_canceller?.isCompleted ?? true)) {
      _canceller?.complete();
    }
    // Release all waiting tasks in the semaphore to unblock Future.wait
    _semaphore?.releaseAll(); // Add a releaseAll method to Semaphore for clean shutdown
    
    // Calculate the number of items that weren't processed before cancellation
    int unaccounted = _usernames.length - (_processedCount + _cancelledCount);
    _cancelledCount += unaccounted;

    setState(() {
      _isProcessing = false;
    });
    _showInfo('Processing cancelled. $_cancelledCount usernames were not checked.');
  }

  Future<void> _downloadResults() async {
    if (_activeAccounts.isEmpty) {
      _showError('No active accounts to download');
      return;
    }

    try {
      final timestamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '');
      final fileName = 'active_accounts_${_originalFileName}_$timestamp.xlsx';
      
      // FIX: Use path_provider for robust, cross-platform saving location
      // Get the external storage directory (usually Download on Android)
      final Directory? externalDir = await getExternalStorageDirectory();
      // Use the root of external storage or getApplicationDocumentsDirectory as fallback
      final Directory baseDir = externalDir?.parent.parent.parent.parent ?? await getApplicationDocumentsDirectory(); 
      final Directory saveDir = Directory(path.join(baseDir.path, 'insta_saver'));
      
      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }
      
      final filePath = path.join(saveDir.path, fileName);
      
      // Create Excel workbook
      var excelFile = excel.Excel.createExcel();
      // Remove default sheet
      excelFile.getDefaultSheet() != null ? excelFile.delete('Sheet1') : null;
      excel.Sheet sheet = excelFile.sheets['Active Accounts'] ?? excelFile['Active Accounts'];

      // Add headers
      if (_activeAccounts.isNotEmpty) {
        // Use the keys of the first row to determine the headers
        sheet.appendRow(_activeAccounts[0].keys.map((key) => excel.TextCellValue(key)).toList());
      }

      // Add data rows
      for (var row in _activeAccounts) {
        // Ensure all data is written as TextCellValue for consistency
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
      _showError('Error saving results: ${e.toString()}');
    }
  }

  // Utility Methods (No changes here, they are fine)
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
    // ... (UI code remains the same as it was functional)
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
    // Show results section only if a file is selected or there are results to show
    if (_selectedFile == null && _usernames.isEmpty) {
        return [const SizedBox.shrink()];
    }

    final totalUsernames = _usernames.length;
    final processedTotal = _processedCount + _cancelledCount;
    final percentage = totalUsernames > 0 ? (processedTotal * 100 / totalUsernames) : 0.0;
    
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
        'Processed: $processedTotal/$totalUsernames (${percentage.toStringAsFixed(1)}%)',
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
          Expanded(child: _buildStatCard('Error/Cancelled', (_errorCount + _cancelledCount).toString(), Colors.orange[50]!, Colors.orange[700]!)),
          const SizedBox(width: 12),
          Expanded(child: _buildStatCard('Total Loaded', totalUsernames.toString(), Colors.blue[50]!, Colors.blue[700]!)),
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
          label: Text('Download Active Accounts (${_activeAccounts.length})'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green[600],
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
      const SizedBox(height: 16),
      const Text(
        'Results Log',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Color(0xFF4F46E5),
        ),
      ),
      const SizedBox(height: 8),
      Container(
        constraints: const BoxConstraints(maxHeight: 300),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _results.length,
          itemBuilder: (context, index) {
            final item = _results[index];
            return Container(
              margin: const EdgeInsets.only(bottom: 1), // Minimal margin for log look
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _getBackgroundColor(item.status),
                // Only show border on status change or for visual effect
                border: Border(bottom: BorderSide(color: Colors.grey[200]!)), 
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

  // ... (Helper methods for UI coloring/icons remain the same)
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

// FIX: Added releaseAll to the custom Semaphore for clean cancellation
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
        c.complete();
      } else {
        _permits++;
      }
    });
  }
  
  /// FIX: Release all waiting futures for clean cancellation.
  Future<void> releaseAll() async {
    await _lock.synchronized(() {
      while (_waiters.isNotEmpty) {
        final c = _waiters.removeFirst();
        // Complete with an error or just complete. Completing is simpler.
        c.complete();
      }
      // Reset permits to the initial limit
      _permits = concurrentLimit;
    });
  }
  
  // Need the concurrent limit in Semaphore as well
  static const int concurrentLimit = 5;
}
