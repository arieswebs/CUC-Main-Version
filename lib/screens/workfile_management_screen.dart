import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_api/amplify_api.dart';

import '../models/ModelProvider.dart' as amplify_models;
import '../models/deal.dart';
import '../models/client.dart';
import '../services/deal_service.dart';
import '../services/client_service.dart';
import '../services/logging_service.dart';
import '../theme.dart';

import 'billing_screen.dart';
import 'client_files_dialog.dart';
import 'task_management_screen.dart';
import 'verification_history_view.dart';
import 'company_bill_management_screen.dart';

class WorkfileManagementScreen extends StatefulWidget {
  final Deal? existingDeal;
  final Map<String, dynamic>? existingCase;

  const WorkfileManagementScreen({
    super.key,
    this.existingDeal,
    this.existingCase,
  });

  @override
  State<WorkfileManagementScreen> createState() => _WorkfileManagementScreenState();
}

class _WorkfileManagementScreenState extends State<WorkfileManagementScreen> {
  final _dealService = DealService();
  final _clientService = ClientService();

  // Primary Status: 'Pending', 'In Progress', 'Under Verification', 'Completed', 'On Hold'
  String _primaryStatus = 'Pending';

  // Basic Info Controllers
  final _fileNumberController = TextEditingController();
  final _workTitleController = TextEditingController();
  final _clientController = TextEditingController();
  final _companyController = TextEditingController();
  final _contactInfoController = TextEditingController();
  final _categoryController = TextEditingController();
  final _feeController = TextEditingController();
  final _paymentReceivedController = TextEditingController();
  final _priorityController = TextEditingController(text: 'Normal');
  final _referredByController = TextEditingController();
  final _regNumberController = TextEditingController();
  final _driveLinkController = TextEditingController();
  final _handlingController = TextEditingController();

  // Update Log Form State
  final _stageInputController = TextEditingController(text: 'Document Collection');
  final _notesInputController = TextEditingController();

  List<String> _selectedHandlingStaffList = [];
  List<amplify_models.Users> _allStaff = [];

  DateTime? _selectedNextFollowupDate;
  final List<PlatformFile> _pendingAttachedFiles = [];

  // Completed / Final Delivery State
  DateTime? _completionDate;
  String _completionReason = 'Successfully Delivered & Completed';
  final _completionNotesController = TextEditingController();
  final List<PlatformFile> _completionAttachedFiles = [];

  // Timeline Flow History
  List<Map<String, dynamic>> _flowHistory = [];

  // Metadata & User State
  bool _isBasicInfoExpanded = false;
  String _currentUserName = 'Staff User';
  String _currentUserEmail = '';
  String? _dealId;
  Deal? _deal;

  static const List<String> _cucStandardStages = [
    'Registration',
    'Document Collection',
    'Document Verification',
    'Work Started',
    'In Progress',
    'Drafting / Preparation',
    'Government / Portal Filing',
    'Department Follow-up',
    'Peer Verification / Review',
    'Invoice & Billing',
    'Completed & Delivered',
  ];

  static const List<String> _completionReasons = [
    'Successfully Delivered & Completed',
    'Registration Certificate Issued',
    'Filing Approved by Department',
    'Document Handed Over to Client',
    'Mutual Settlement / Completed',
    'Client Withdrawn / Cancelled',
    'Service Upgraded / Replaced',
  ];

  @override
  void initState() {
    super.initState();
    _initUser();
    _populateInitialData();
  }

  @override
  void dispose() {
    _fileNumberController.dispose();
    _workTitleController.dispose();
    _clientController.dispose();
    _companyController.dispose();
    _contactInfoController.dispose();
    _categoryController.dispose();
    _feeController.dispose();
    _paymentReceivedController.dispose();
    _priorityController.dispose();
    _referredByController.dispose();
    _regNumberController.dispose();
    _driveLinkController.dispose();
    _handlingController.dispose();
    _stageInputController.dispose();
    _notesInputController.dispose();
    _completionNotesController.dispose();
    super.dispose();
  }

  Future<void> _initUser() async {
    final prefs = await SharedPreferences.getInstance();
    _currentUserEmail = prefs.getString('user_email') ?? '';
    _currentUserName = prefs.getString('user_name') ?? (_currentUserEmail.isNotEmpty ? _currentUserEmail : 'Staff User');

    try {
      final req = ModelQueries.list(amplify_models.Users.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      final fetched = (res.data?.items ?? []).whereType<amplify_models.Users>().toList();

      final Map<String, amplify_models.Users> uniqueByName = {};
      for (var u in fetched) {
        final dName = (u.name?.isNotEmpty == true ? u.name! : (u.username ?? '')).trim();
        if (dName.isNotEmpty && !uniqueByName.containsKey(dName.toLowerCase())) {
          uniqueByName[dName.toLowerCase()] = u;
        }
      }

      final staffList = uniqueByName.values.toList()
        ..sort((a, b) {
          final na = (a.name?.isNotEmpty == true ? a.name! : (a.username ?? '')).toLowerCase();
          final nb = (b.name?.isNotEmpty == true ? b.name! : (b.username ?? '')).toLowerCase();
          return na.compareTo(nb);
        });

      if (mounted) {
        setState(() => _allStaff = staffList);
      }
    } catch (e) {
      debugPrint('Error fetching staff in WorkfileManagementScreen: $e');
    }
  }

  void _populateInitialData() {
    if (widget.existingDeal != null) {
      _deal = widget.existingDeal;
      final d = _deal!;
      _dealId = d.id?.toString();
      _fileNumberController.text = d.registerNo?.isNotEmpty == true ? d.registerNo! : 'CU-WF-${d.id ?? DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
      _workTitleController.text = d.name;
      _clientController.text = d.clientName ?? '';
      _companyController.text = d.company ?? '';
      _contactInfoController.text = d.contactInfo ?? '';
      _categoryController.text = d.workType ?? 'General';
      _feeController.text = d.amount > 0 ? d.amount.toStringAsFixed(0) : (d.invoiceAmount != null && d.invoiceAmount! > 0 ? d.invoiceAmount!.toStringAsFixed(0) : '');
      _paymentReceivedController.text = (d.paymentReceived != null && d.paymentReceived! > 0) ? d.paymentReceived!.toStringAsFixed(0) : '';
      _priorityController.text = d.priority.isNotEmpty ? d.priority : 'Normal';
      _referredByController.text = d.referredBy ?? '';
      _regNumberController.text = d.registerNo ?? '';
      _driveLinkController.text = d.driveLink ?? '';
      _stageInputController.text = d.stage.isNotEmpty ? d.stage : 'Document Collection';

      if (d.responsibleName != null && d.responsibleName!.isNotEmpty) {
        _selectedHandlingStaffList = d.responsibleName!
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        _handlingController.text = _selectedHandlingStaffList.join(', ');
      }

      // Map primary status
      final stageLower = d.stage.toLowerCase();
      if (stageLower.contains('close') || stageLower.contains('completed') || stageLower.contains('won') || d.isWon) {
        _primaryStatus = 'Completed';
      } else if (stageLower.contains('verification')) {
        _primaryStatus = 'Under Verification';
      } else if (stageLower.contains('progress') || stageLower.contains('work started')) {
        _primaryStatus = 'In Progress';
      } else {
        _primaryStatus = 'Pending';
      }

      // Extract Flow History from description
      final desc = d.description ?? '';
      if (desc.contains('[FLOW_HISTORY]')) {
        try {
          final idx = desc.indexOf('[FLOW_HISTORY]');
          final jsonStr = desc.substring(idx + '[FLOW_HISTORY]'.length).trim();
          final decoded = jsonDecode(jsonStr);
          if (decoded is List) {
            _flowHistory = List<Map<String, dynamic>>.from(decoded);
          }
        } catch (_) {}
      }

      // If flow history is empty, populate initial record
      if (_flowHistory.isEmpty) {
        _flowHistory.add({
          'id': 'init_${DateTime.now().millisecondsSinceEpoch}',
          'status': _primaryStatus,
          'stage': d.stage.isNotEmpty ? d.stage : 'Registration',
          'notes': desc.contains('[FLOW_HISTORY]') ? desc.substring(0, desc.indexOf('[FLOW_HISTORY]')).trim() : (desc.isNotEmpty ? desc : 'Workfile registered in system.'),
          'target_date': d.closedAt?.toIso8601String(),
          'attachments': [],
          'timestamp': d.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
          'updated_by': d.responsibleName?.isNotEmpty == true ? d.responsibleName! : 'System',
        });
      }
    } else if (widget.existingCase != null) {
      final data = widget.existingCase!;
      _dealId = data['id']?.toString();
      _fileNumberController.text = (data['case_number'] ?? data['workfile_no'] ?? data['id'] ?? '').toString();
      _workTitleController.text = (data['case_title'] ?? data['title'] ?? data['name'] ?? '').toString();
      _clientController.text = (data['client_name'] ?? '').toString();
      _companyController.text = (data['company'] ?? '').toString();
      _contactInfoController.text = (data['contact_info'] ?? data['phone'] ?? '').toString();
      _categoryController.text = (data['case_type'] ?? data['work_type'] ?? 'General').toString();
      _feeController.text = (data['total_fees'] ?? data['amount'] ?? '').toString();
      _stageInputController.text = (data['current_stage'] ?? data['stage'] ?? 'Document Collection').toString();

      final rawStatus = (data['status'] ?? 'Pending').toString();
      if (rawStatus.toLowerCase().contains('dispose') || rawStatus.toLowerCase().contains('closed') || rawStatus.toLowerCase().contains('completed')) {
        _primaryStatus = 'Completed';
      } else {
        _primaryStatus = 'Pending';
      }

      try {
        final rawFlow = data['flow_history'] ?? data['data']?['flow_history'] ?? data['notes'];
        if (rawFlow != null) {
          if (rawFlow is String) {
            final decoded = jsonDecode(rawFlow);
            if (decoded is List) {
              _flowHistory = List<Map<String, dynamic>>.from(decoded);
            }
          } else if (rawFlow is List) {
            _flowHistory = List<Map<String, dynamic>>.from(rawFlow);
          }
        }
      } catch (_) {}

      if (_flowHistory.isEmpty) {
        _flowHistory.add({
          'id': 'init_${DateTime.now().millisecondsSinceEpoch}',
          'status': _primaryStatus,
          'stage': _stageInputController.text,
          'notes': 'Initial workfile created and registered.',
          'target_date': null,
          'attachments': [],
          'timestamp': DateTime.now().toIso8601String(),
          'updated_by': 'System',
        });
      }
    } else {
      // New Workfile
      _isBasicInfoExpanded = true;
      _fileNumberController.text = 'CU-WF-2026-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
      _priorityController.text = 'Normal';
    }
  }

  Future<void> _pickPendingFiles() async {
    try {
      final result = await FilePicker.pickFiles(allowMultiple: true);
      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _pendingAttachedFiles.addAll(result.files);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error selecting files: $e')));
      }
    }
  }

  Future<void> _pickCompletionFiles() async {
    try {
      final result = await FilePicker.pickFiles(allowMultiple: true);
      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _completionAttachedFiles.addAll(result.files);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error selecting files: $e')));
      }
    }
  }

  Future<void> _logStatusUpdate() async {
    final title = _workTitleController.text.trim();
    final client = _clientController.text.trim();
    if (title.isEmpty || client.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please provide Workfile Title and Client Name in Details.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      setState(() => _isBasicInfoExpanded = true);
      return;
    }

    final stageName = _stageInputController.text.trim().isNotEmpty
        ? _stageInputController.text.trim()
        : 'Document Collection';

    final notesText = _notesInputController.text.trim();
    if (notesText.isEmpty && _selectedNextFollowupDate == null && _pendingAttachedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter progress notes, next follow-up date, or attach files.')),
      );
      return;
    }

    final attachmentsList = _pendingAttachedFiles.map((file) => {
      'name': file.name,
      'size': '${(file.size / 1024).toStringAsFixed(1)} KB',
      'path': file.path ?? '',
    }).toList();

    final newEntry = {
      'id': 'flow_${DateTime.now().millisecondsSinceEpoch}',
      'status': _primaryStatus,
      'stage': stageName,
      'notes': notesText.isNotEmpty ? notesText : 'Stage updated to $stageName.',
      'target_date': _selectedNextFollowupDate?.toIso8601String(),
      'attachments': attachmentsList,
      'timestamp': DateTime.now().toIso8601String(),
      'updated_by': _currentUserName,
    };

    _handlingController.text = _selectedHandlingStaffList.join(', ');

    setState(() {
      _flowHistory.insert(0, newEntry);
      _notesInputController.clear();
      _pendingAttachedFiles.clear();
    });

    final success = await _saveWorkfileToBackend();
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: const [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
              SizedBox(width: 10),
              Text('Progress update logged to workfile timeline!'),
            ],
          ),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _logCompletionAndClose() async {
    final title = _workTitleController.text.trim();
    final client = _clientController.text.trim();
    if (title.isEmpty || client.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please provide Workfile Title and Client Name in Details.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      setState(() => _isBasicInfoExpanded = true);
      return;
    }

    final notesText = _completionNotesController.text.trim();
    final attachmentsList = _completionAttachedFiles.map((file) => {
      'name': file.name,
      'size': '${(file.size / 1024).toStringAsFixed(1)} KB',
      'path': file.path ?? '',
    }).toList();

    final completionDateFormatted = _completionDate != null
        ? DateFormat('dd MMMM yyyy').format(_completionDate!)
        : DateFormat('dd MMMM yyyy').format(DateTime.now());

    final finalNotes = notesText.isNotEmpty
        ? 'WORKFILE COMPLETED & CLOSED\nOutcome: $_completionReason\nCompletion Date: $completionDateFormatted\nNotes: $notesText'
        : 'WORKFILE COMPLETED & CLOSED\nOutcome: $_completionReason\nCompletion Date: $completionDateFormatted';

    final disposalEntry = {
      'id': 'flow_${DateTime.now().millisecondsSinceEpoch}',
      'status': 'Completed',
      'stage': 'Completed & Delivered',
      'notes': finalNotes,
      'target_date': _completionDate?.toIso8601String() ?? DateTime.now().toIso8601String(),
      'attachments': attachmentsList,
      'timestamp': DateTime.now().toIso8601String(),
      'updated_by': _currentUserName,
    };

    setState(() {
      _primaryStatus = 'Completed';
      _stageInputController.text = 'Completed & Delivered';
      _flowHistory.insert(0, disposalEntry);
    });

    final success = await _saveWorkfileToBackend();
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: const [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
              SizedBox(width: 10),
              Text('Workfile marked as COMPLETED & DELIVERED!'),
            ],
          ),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<bool> _saveWorkfileToBackend() async {
    final title = _workTitleController.text.trim();
    final client = _clientController.text.trim();
    if (title.isEmpty || client.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill Workfile Title and Client Name before saving.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      setState(() => _isBasicInfoExpanded = true);
      return false;
    }

    try {
      final currentStage = _flowHistory.isNotEmpty
          ? (_flowHistory.first['stage']?.toString() ?? _stageInputController.text.trim())
          : _stageInputController.text.trim();

      final feeAmount = double.tryParse(_feeController.text.replaceAll(',', '').trim()) ?? 0.0;
      final receivedAmount = double.tryParse(_paymentReceivedController.text.replaceAll(',', '').trim()) ?? 0.0;

      // Pack clean description + embedded flow history
      String baseDescription = '';
      if (_deal?.description != null) {
        final dDesc = _deal!.description!;
        final idx = dDesc.indexOf('[FLOW_HISTORY]');
        baseDescription = idx != -1 ? dDesc.substring(0, idx).trim() : dDesc.trim();
      }
      final packedDescription = "$baseDescription\n\n[FLOW_HISTORY]\n${jsonEncode(_flowHistory)}".trim();

      final handledByStr = _selectedHandlingStaffList.isNotEmpty
          ? _selectedHandlingStaffList.join(', ')
          : (_handlingController.text.isNotEmpty ? _handlingController.text : _currentUserName);

      final isWon = _primaryStatus == 'Completed';

      final dealToSave = Deal(
        id: _dealId ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
        name: title,
        clientName: client,
        company: _companyController.text.trim(),
        contactInfo: _contactInfoController.text.trim(),
        workType: _categoryController.text.trim().isNotEmpty ? _categoryController.text.trim() : 'General',
        stage: currentStage.isNotEmpty ? currentStage : 'Document Collection',
        priority: _priorityController.text.trim().isNotEmpty ? _priorityController.text.trim() : 'Normal',
        responsibleName: handledByStr,
        amount: feeAmount,
        invoiceAmount: feeAmount,
        paymentReceived: receivedAmount,
        registerNo: _fileNumberController.text.trim(),
        referredBy: _referredByController.text.trim(),
        driveLink: _driveLinkController.text.trim(),
        description: packedDescription,
        closedAt: _selectedNextFollowupDate ?? _deal?.closedAt,
        createdAt: _deal?.createdAt ?? DateTime.now(),
        updatedAt: DateTime.now(),
        isWon: isWon,
      );

      if (_dealId != null && _deal != null) {
        await _dealService.updateDeal(dealToSave);
        await LoggingService().logAction(
          action: 'WORK_UPDATED',
          targetType: 'Work',
          targetId: dealToSave.id.toString(),
          details: 'Updated workfile: ${dealToSave.name}',
        );
      } else {
        final created = await _dealService.createDeal(dealToSave);
        if (created != null && created.id != null) {
          _dealId = created.id.toString();
        }
        await LoggingService().logAction(
          action: 'WORK_CREATED',
          targetType: 'Work',
          targetId: dealToSave.name,
          details: 'Created workfile for ${dealToSave.clientName}',
        );
      }

      setState(() => _deal = dealToSave);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving workfile: $e')));
      }
      return false;
    }
  }

  Future<void> _onDeleteWorkfile() async {
    if (_dealId == null) return;
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Delete Workfile Record',
          style: GoogleFonts.cinzel(color: const Color(0xFF0F172A), fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Are you sure you want to permanently delete this workfile and its entire progress history?',
          style: GoogleFonts.montserrat(color: const Color(0xFF475569)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('CANCEL', style: TextStyle(color: Color(0xFF64748B))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('DELETE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _dealService.deleteDeal(_dealId!);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Workfile deleted successfully')));
          Navigator.of(context).pop();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete workfile: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 1000;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF334155), size: 18),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _dealId != null ? 'WORKFILE MANAGEMENT' : 'REGISTER NEW WORKFILE',
              style: GoogleFonts.cinzel(
                fontWeight: FontWeight.w800,
                fontSize: 19,
                color: const Color(0xFF0F172A),
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(width: 10),
            _buildStatusPillBadge(),
          ],
        ),
        centerTitle: true,
        actions: [
          if (_dealId != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFEF4444), size: 20),
              onPressed: _onDeleteWorkfile,
              tooltip: 'Delete Workfile',
            ),
          Padding(
            padding: const EdgeInsets.only(right: 20.0, top: 8, bottom: 8),
            child: ElevatedButton.icon(
              onPressed: () async {
                final success = await _saveWorkfileToBackend();
                if (success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Row(
                        children: const [
                          Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                          SizedBox(width: 10),
                          Text('Workfile record saved successfully!'),
                        ],
                      ),
                      backgroundColor: const Color(0xFF10B981),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              icon: const Icon(Icons.save_rounded, size: 16),
              label: const Text('SAVE RECORD'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F172A),
                foregroundColor: AppTheme.accentColor,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_dealId != null) ...[
                _buildTopActionMenu(),
                const SizedBox(height: 16),
              ],
              // 1. Basic Info Collapsible Header Card
              _buildBasicInfoCard(),
              const SizedBox(height: 20),

              // 2. Main Workspace (Form + Timeline Flow)
              Expanded(
                child: isWide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 5,
                            child: _primaryStatus == 'Completed'
                                ? _buildCompletionFormCard()
                                : _buildLogUpdateFormCard(),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            flex: 6,
                            child: SingleChildScrollView(
                              child: _buildTimelineFlowCard(),
                            ),
                          ),
                        ],
                      )
                    : SingleChildScrollView(
                        child: Column(
                          children: [
                            _primaryStatus == 'Completed'
                                ? _buildCompletionFormCard()
                                : _buildLogUpdateFormCard(),
                            const SizedBox(height: 24),
                            _buildTimelineFlowCard(),
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

  Widget _buildStatusPillBadge() {
    Color bg;
    Color border;
    Color text;

    switch (_primaryStatus) {
      case 'Completed':
        bg = const Color(0xFFD1FAE5);
        border = const Color(0xFF10B981);
        text = const Color(0xFF047857);
        break;
      case 'In Progress':
        bg = const Color(0xFFE0F2FE);
        border = const Color(0xFF0EA5E9);
        text = const Color(0xFF0369A1);
        break;
      case 'Under Verification':
        bg = const Color(0xFFEDE9FE);
        border = const Color(0xFF8B5CF6);
        text = const Color(0xFF6D28D9);
        break;
      case 'On Hold':
        bg = const Color(0xFFF1F5F9);
        border = const Color(0xFF94A3B8);
        text = const Color(0xFF475569);
        break;
      case 'Pending':
      default:
        bg = const Color(0xFFFEF3C7);
        border = const Color(0xFFF59E0B);
        text = const Color(0xFFB45309);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Text(
        _primaryStatus.toUpperCase(),
        style: GoogleFonts.montserrat(
          color: text,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  // --- WIDGET: TOP ACTION MENU ---
  Widget _buildTopActionMenu() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildPremiumActionButton(Icons.info_outline_rounded, 'Workfile Details', 'View full info', () {
              _showWorkfileDetailsDialog();
            }),
            _buildPremiumDivider(),
            _buildPremiumActionButton(Icons.person_search_rounded, 'Client Profile', 'View & edit details', () {
              _showClientDetailsDialog();
            }),
            _buildPremiumDivider(),
            _buildPremiumActionButton(Icons.account_balance_wallet_rounded, 'Accounts', 'Expenses & ledgers', () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const CompanyBillManagementScreen()));
            }),
            _buildPremiumDivider(),
            _buildPremiumActionButton(Icons.receipt_long_rounded, 'Billing', 'Invoices', () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const BillingScreen()));
            }),
            _buildPremiumDivider(),
            _buildPremiumActionButton(Icons.folder_open_rounded, 'Client Documents', 'Manage case files', () async {
              final cName = _clientController.text.trim().toLowerCase();
              if (cName.isEmpty) return;

              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => const Center(child: CircularProgressIndicator()),
              );

              final clientsData = await _clientService.getAllClients();
              Map<String, dynamic>? matchedMap;
              for (var c in clientsData) {
                if ((c['name'] ?? '').toString().toLowerCase().trim() == cName) {
                  matchedMap = c;
                  break;
                }
              }

              if (mounted) Navigator.pop(context);

              if (matchedMap != null && mounted) {
                showDialog(
                  context: context,
                  barrierColor: Colors.black.withValues(alpha: 0.75),
                  builder: (context) => ClientFilesDialog(client: Client.fromMap(matchedMap!)),
                );
              } else if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Client not found in Client records. Please verify client name.')),
                );
              }
            }),
            _buildPremiumDivider(),
            _buildPremiumActionButton(Icons.checklist_rtl_rounded, 'Workfile Tasks', 'Deadlines & todos', () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const TaskManagementScreen()));
            }),
            _buildPremiumDivider(),
            _buildPremiumActionButton(Icons.history_rounded, 'Activity Log', 'Audit & history', () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const VerificationHistoryView()));
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildPremiumDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        width: 1.5,
        height: 36,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFFE2E8F0).withValues(alpha: 0.1),
              const Color(0xFFE2E8F0),
              const Color(0xFFE2E8F0).withValues(alpha: 0.1),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPremiumActionButton(IconData icon, String title, String subtitle, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      splashColor: AppTheme.accentColor.withValues(alpha: 0.1),
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFF1F5F9)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 4, offset: const Offset(0, 2)),
                ],
              ),
              child: Icon(icon, size: 18, color: AppTheme.accentColor),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title.toUpperCase(),
                  style: GoogleFonts.montserrat(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.montserrat(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- DIALOG: CLIENT DETAILS ---
  Future<void> _showClientDetailsDialog() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    final clients = await _clientService.getAllClients();
    final clientName = _clientController.text.trim().toLowerCase();
    final clientData = clients.firstWhere(
      (c) => (c['name'] ?? '').toString().toLowerCase().trim() == clientName,
      orElse: () => <String, dynamic>{},
    );

    if (mounted) Navigator.pop(context);

    if (clientData.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Client details not found.')));
      return;
    }

    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            width: 600,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(color: const Color(0xFF0F172A).withValues(alpha: 0.15), blurRadius: 32, offset: const Offset(0, 16)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0F172A),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.accentColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.person_rounded, color: AppTheme.accentColor, size: 24),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Client Details',
                              style: GoogleFonts.cormorantGaramond(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            Text(
                              clientData['name']?.toString() ?? 'Overview',
                              style: GoogleFonts.montserrat(fontSize: 12, color: const Color(0xFF94A3B8), fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, color: Colors.white70),
                        splashRadius: 24,
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildPremiumSectionTitle('1. Contact Info'),
                        _buildPremiumDetailGrid([
                          {'icon': Icons.person_rounded, 'label': 'Name', 'value': clientData['name']?.toString() ?? 'N/A'},
                          {'icon': Icons.email_rounded, 'label': 'Email', 'value': clientData['email']?.toString() ?? 'N/A'},
                          {'icon': Icons.phone_rounded, 'label': 'Phone', 'value': clientData['phone']?.toString() ?? 'N/A'},
                          {'icon': Icons.location_on_rounded, 'label': 'Address', 'value': clientData['address']?.toString() ?? 'N/A'},
                        ]),
                        if ((clientData['companies'] != null && clientData['companies'].toString().trim().isNotEmpty) ||
                            (clientData['gst'] != null && clientData['gst'].toString().trim().isNotEmpty)) ...[
                          const SizedBox(height: 24),
                          _buildPremiumSectionTitle('2. Business Info'),
                          _buildPremiumDetailGrid([
                            if (clientData['companies'] != null && clientData['companies'].toString().trim().isNotEmpty)
                              {'icon': Icons.business_rounded, 'label': 'Company', 'value': clientData['companies'].toString()},
                            if (clientData['gst'] != null && clientData['gst'].toString().trim().isNotEmpty)
                              {'icon': Icons.receipt_long_rounded, 'label': 'GST Number', 'value': clientData['gst'].toString()},
                          ]),
                        ],
                        if ((clientData['type_of_work'] != null && clientData['type_of_work'].toString().trim().isNotEmpty) ||
                            (clientData['balance_due'] != null && clientData['balance_due'].toString().trim().isNotEmpty)) ...[
                          const SizedBox(height: 24),
                          _buildPremiumSectionTitle('3. Service & Ledger'),
                          _buildPremiumDetailGrid([
                            if (clientData['type_of_work'] != null && clientData['type_of_work'].toString().trim().isNotEmpty)
                              {'icon': Icons.work_rounded, 'label': 'Type of Work', 'value': clientData['type_of_work'].toString()},
                            if (clientData['balance_due'] != null && clientData['balance_due'].toString().trim().isNotEmpty)
                              {'icon': Icons.account_balance_wallet_rounded, 'label': 'Balance Due', 'value': '₹${clientData['balance_due']}'},
                          ], crossAxisCount: 1),
                        ],
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
  }

  // --- DIALOG: WORKFILE DETAILS OVERVIEW ---
  void _showWorkfileDetailsDialog() {
    final handledByStr = _selectedHandlingStaffList.isNotEmpty
        ? _selectedHandlingStaffList.join(', ')
        : (_handlingController.text.isNotEmpty ? _handlingController.text : 'N/A');

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Container(
          width: 600,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(color: const Color(0xFF0F172A).withValues(alpha: 0.15), blurRadius: 32, offset: const Offset(0, 16)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                decoration: const BoxDecoration(
                  color: Color(0xFF0F172A),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.accentColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.description_rounded, color: AppTheme.accentColor, size: 24),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Workfile Details',
                            style: GoogleFonts.cormorantGaramond(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          Text(
                            _fileNumberController.text.trim().isNotEmpty ? _fileNumberController.text : 'Complete Overview',
                            style: GoogleFonts.montserrat(fontSize: 12, color: const Color(0xFF94A3B8), fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded, color: Colors.white70),
                      splashRadius: 24,
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPremiumSectionTitle('1. Workfile Overview'),
                      _buildPremiumDetailGrid([
                        {'icon': Icons.title_rounded, 'label': 'Workfile Title', 'value': _workTitleController.text.trim().isNotEmpty ? _workTitleController.text : 'N/A'},
                        {'icon': Icons.folder_open_rounded, 'label': 'File No', 'value': _fileNumberController.text.trim().isNotEmpty ? _fileNumberController.text : 'N/A'},
                        {'icon': Icons.category_rounded, 'label': 'Category', 'value': _categoryController.text.trim().isNotEmpty ? _categoryController.text : 'General'},
                        {'icon': Icons.flag_rounded, 'label': 'Priority', 'value': _priorityController.text.trim().isNotEmpty ? _priorityController.text : 'Normal'},
                      ]),
                      const SizedBox(height: 24),
                      _buildPremiumSectionTitle('2. Client & Entity'),
                      _buildPremiumDetailGrid([
                        {'icon': Icons.person_rounded, 'label': 'Client Name', 'value': _clientController.text.trim().isNotEmpty ? _clientController.text : 'N/A'},
                        {'icon': Icons.business_rounded, 'label': 'Company / Entity', 'value': _companyController.text.trim().isNotEmpty ? _companyController.text : 'N/A'},
                        {'icon': Icons.phone_rounded, 'label': 'Contact Phone', 'value': _contactInfoController.text.trim().isNotEmpty ? _contactInfoController.text : 'N/A'},
                        {'icon': Icons.group_work_rounded, 'label': 'Handled By', 'value': handledByStr},
                      ], crossAxisCount: 1),
                      const SizedBox(height: 24),
                      _buildPremiumSectionTitle('3. Financials & Status'),
                      _buildPremiumDetailGrid([
                        {'icon': Icons.currency_rupee_rounded, 'label': 'Agreed Fee', 'value': _feeController.text.trim().isNotEmpty ? '₹${_feeController.text}' : 'N/A'},
                        {'icon': Icons.payments_rounded, 'label': 'Received / Advance', 'value': _paymentReceivedController.text.trim().isNotEmpty ? '₹${_paymentReceivedController.text}' : '₹0'},
                        {'icon': Icons.stairs_rounded, 'label': 'Current Stage', 'value': _stageInputController.text.trim()},
                        {'icon': Icons.donut_large_rounded, 'label': 'Status', 'value': _primaryStatus},
                      ]),
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

  Widget _buildPremiumSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title.toUpperCase(),
        style: GoogleFonts.montserrat(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF64748B),
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildPremiumDetailGrid(List<Map<String, dynamic>> items, {int crossAxisCount = 2}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 400;
        final actualCrossAxisCount = isMobile ? 1 : crossAxisCount;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: actualCrossAxisCount,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            mainAxisExtent: 72,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0F172A).withValues(alpha: 0.05),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(item['icon'] as IconData, size: 18, color: AppTheme.accentColor),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item['label'] as String,
                          style: GoogleFonts.montserrat(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF94A3B8),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item['value'] as String,
                          style: GoogleFonts.montserrat(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF0F172A),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --- WIDGET 1: BASIC WORKFILE INFO COLLAPSIBLE CARD ---
  Widget _buildBasicInfoCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _isBasicInfoExpanded = !_isBasicInfoExpanded),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.business_center_rounded, color: Color(0xFFB8860B), size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _workTitleController.text.isNotEmpty
                              ? _workTitleController.text
                              : 'Untitled Workfile (Click to fill metadata)',
                          style: GoogleFonts.montserrat(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Client: ${_clientController.text.isNotEmpty ? _clientController.text : "N/A"} • File #: ${_fileNumberController.text} • Category: ${_categoryController.text.isNotEmpty ? _categoryController.text : "General"} • Fee: ₹${_feeController.text.isNotEmpty ? _feeController.text : "0"}',
                          style: GoogleFonts.montserrat(
                            fontSize: 12,
                            color: const Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _isBasicInfoExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: const Color(0xFF64748B),
                  ),
                ],
              ),
            ),
          ),
          if (_isBasicInfoExpanded) ...[
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _buildCompactInput(_workTitleController, 'Workfile Title (e.g. GST Registration)', Icons.title_rounded)),
                      const SizedBox(width: 14),
                      Expanded(child: _buildCompactInput(_clientController, 'Client Name', Icons.person_rounded)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _buildCompactInput(_categoryController, 'Service Category / Work Type', Icons.category_rounded)),
                      const SizedBox(width: 14),
                      Expanded(child: _buildCompactInput(_fileNumberController, 'Workfile / File Number', Icons.numbers_rounded)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _buildCompactInput(_companyController, 'Company / Business Entity', Icons.business_rounded)),
                      const SizedBox(width: 14),
                      Expanded(child: _buildCompactInput(_contactInfoController, 'Client Phone / Contact', Icons.phone_rounded)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _buildCompactInput(_feeController, 'Total Agreed Fee (₹)', Icons.currency_rupee_rounded)),
                      const SizedBox(width: 14),
                      Expanded(child: _buildCompactInput(_paymentReceivedController, 'Advance / Payment Received (₹)', Icons.payments_rounded)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _buildCompactInput(_priorityController, 'Priority (Low / Normal / High / Urgent)', Icons.flag_rounded)),
                      const SizedBox(width: 14),
                      Expanded(child: _buildCompactInput(_referredByController, 'Referred By / Source', Icons.share_rounded)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _buildCompactInput(_regNumberController, 'Government / Dept Filing Ack #', Icons.receipt_long_rounded)),
                      const SizedBox(width: 14),
                      Expanded(child: _buildCompactInput(_driveLinkController, 'Drive / Cloud Folder Link', Icons.cloud_circle_rounded)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompactInput(TextEditingController controller, String label, IconData icon) {
    return TextField(
      controller: controller,
      style: GoogleFonts.montserrat(fontSize: 13.5, color: const Color(0xFF0F172A), fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.montserrat(fontSize: 12.5, color: const Color(0xFF64748B)),
        prefixIcon: Icon(icon, color: AppTheme.accentColor, size: 18),
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTheme.accentColor, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  // --- WIDGET 2: LOG UPDATE FORM CARD (PENDING / IN PROGRESS) ---
  Widget _buildLogUpdateFormCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.accentColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.edit_note_rounded, color: Color(0xFFB8860B), size: 20),
                ),
                const SizedBox(width: 10),
                Text(
                  'LOG WORK STATUS & PROGRESS',
                  style: GoogleFonts.montserrat(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F172A),
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // 1. Workfile Status Input
            _buildFieldHeader('1. WORKFILE STATUS'),
            const SizedBox(height: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFCBD5E1)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _primaryStatus,
                  isExpanded: true,
                  style: GoogleFonts.montserrat(color: const Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 13.5),
                  items: const [
                    DropdownMenuItem(
                      value: 'Pending',
                      child: Row(
                        children: [
                          Icon(Icons.hourglass_top_rounded, color: Color(0xFFB45309), size: 18),
                          SizedBox(width: 10),
                          Text('Pending Work'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'In Progress',
                      child: Row(
                        children: [
                          Icon(Icons.play_circle_filled_rounded, color: Color(0xFF0284C7), size: 18),
                          SizedBox(width: 10),
                          Text('In Progress'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'Under Verification',
                      child: Row(
                        children: [
                          Icon(Icons.verified_user_rounded, color: Color(0xFF7C3AED), size: 18),
                          SizedBox(width: 10),
                          Text('Under Peer Verification'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'Completed',
                      child: Row(
                        children: [
                          Icon(Icons.task_alt_rounded, color: Color(0xFF10B981), size: 18),
                          SizedBox(width: 10),
                          Text('Completed & Delivered'),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'On Hold',
                      child: Row(
                        children: [
                          Icon(Icons.pause_circle_filled_rounded, color: Color(0xFFF59E0B), size: 18),
                          SizedBox(width: 10),
                          Text('On Hold / Waiting for Client'),
                        ],
                      ),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _primaryStatus = val);
                    }
                  },
                ),
              ),
            ),

            const SizedBox(height: 14),

            // 2. Stage of Workfile
            _buildFieldHeader('2. STAGE OF WORKFILE'),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _stageInputController,
                    style: GoogleFonts.montserrat(fontSize: 13.5, color: const Color(0xFF0F172A), fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      hintText: 'Enter or select stage...',
                      hintStyle: GoogleFonts.montserrat(fontSize: 13, color: const Color(0xFF94A3B8)),
                      prefixIcon: const Icon(Icons.bookmark_outline_rounded, color: AppTheme.accentColor, size: 18),
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppTheme.accentColor, width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  icon: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFCBD5E1)),
                    ),
                    child: const Icon(Icons.arrow_drop_down_rounded, color: Color(0xFF475569)),
                  ),
                  tooltip: 'Quick select common stages',
                  onSelected: (val) {
                    setState(() => _stageInputController.text = val);
                  },
                  itemBuilder: (context) => _cucStandardStages.map((s) {
                    return PopupMenuItem(
                      value: s,
                      child: Text(s, style: GoogleFonts.montserrat(fontSize: 13, fontWeight: FontWeight.w600)),
                    );
                  }).toList(),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // 3. Progress Notes
            _buildFieldHeader('3. WORK PROGRESS NOTES / DAILY UPDATES'),
            const SizedBox(height: 5),
            TextField(
              controller: _notesInputController,
              maxLines: 3,
              style: GoogleFonts.montserrat(fontSize: 13.5, color: const Color(0xFF0F172A), fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: 'Enter daily work notes, client instructions, filing ack details, or updates...',
                hintStyle: GoogleFonts.montserrat(fontSize: 13, color: const Color(0xFF94A3B8)),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppTheme.accentColor, width: 1.5),
                ),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),

            const SizedBox(height: 14),

            // 4. Assign Staff Fields
            _buildFieldHeader('4. UPDATE STAFF (OPTIONAL)'),
            const SizedBox(height: 5),
            if (_selectedHandlingStaffList.isNotEmpty) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _selectedHandlingStaffList.map((staffName) {
                  return Chip(
                    label: Text(staffName, style: GoogleFonts.montserrat(fontSize: 12, fontWeight: FontWeight.w600)),
                    backgroundColor: const Color(0xFFEDE9FE),
                    deleteIcon: const Icon(Icons.close, size: 14, color: Color(0xFF6D28D9)),
                    onDeleted: () {
                      setState(() {
                        _selectedHandlingStaffList.remove(staffName);
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),
            ],
            DropdownButtonFormField<String>(
              value: null,
              decoration: InputDecoration(
                hintText: 'Add Handled By (Multiple allowed)',
                hintStyle: GoogleFonts.montserrat(fontSize: 13, color: const Color(0xFF94A3B8)),
                prefixIcon: const Icon(Icons.assignment_ind_rounded, color: AppTheme.accentColor, size: 18),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppTheme.accentColor, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              items: _allStaff.where((s) {
                final dName = (s.name?.isNotEmpty == true ? s.name! : (s.username ?? '')).trim();
                return !_selectedHandlingStaffList.contains(dName);
              }).map((staff) {
                final dName = (staff.name?.isNotEmpty == true ? staff.name! : (staff.username ?? '')).trim();
                return DropdownMenuItem<String>(
                  value: dName,
                  child: Text(dName, style: GoogleFonts.montserrat(fontSize: 13.5, color: const Color(0xFF0F172A), fontWeight: FontWeight.w600)),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _selectedHandlingStaffList.add(val);
                  });
                }
              },
            ),

            const SizedBox(height: 14),

            // 5. Target Delivery Date
            _buildFieldHeader('5. TARGET DELIVERY / NEXT FOLLOW-UP DATE'),
            const SizedBox(height: 5),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _selectedNextFollowupDate ?? DateTime.now().add(const Duration(days: 7)),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2035),
                );
                if (picked != null) {
                  setState(() => _selectedNextFollowupDate = picked);
                }
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _selectedNextFollowupDate != null ? AppTheme.accentColor : const Color(0xFFCBD5E1),
                    width: _selectedNextFollowupDate != null ? 1.5 : 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.event_rounded,
                      color: _selectedNextFollowupDate != null ? const Color(0xFFB8860B) : const Color(0xFF64748B),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _selectedNextFollowupDate != null
                          ? DateFormat('EEEE, dd MMMM yyyy').format(_selectedNextFollowupDate!)
                          : 'Select Target / Next Follow-up Date',
                      style: GoogleFonts.montserrat(
                        color: _selectedNextFollowupDate != null ? const Color(0xFF0F172A) : const Color(0xFF64748B),
                        fontWeight: _selectedNextFollowupDate != null ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 13.5,
                      ),
                    ),
                    const Spacer(),
                    if (_selectedNextFollowupDate != null)
                      IconButton(
                        icon: const Icon(Icons.close, size: 16, color: Color(0xFF94A3B8)),
                        onPressed: () => setState(() => _selectedNextFollowupDate = null),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 14),

            // 6. File Upload Section
            _buildFieldHeader('6. ATTACH WORK FILES / DOCUMENTS'),
            const SizedBox(height: 5),
            OutlinedButton.icon(
              onPressed: _pickPendingFiles,
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              label: const Text('ATTACH FILES FROM COMPUTER'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF0F172A),
                side: const BorderSide(color: Color(0xFFCBD5E1)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                minimumSize: const Size(double.infinity, 44),
              ),
            ),

            if (_pendingAttachedFiles.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _pendingAttachedFiles.map((file) {
                  return Chip(
                    avatar: const Icon(Icons.insert_drive_file_rounded, size: 14, color: AppTheme.accentColor),
                    label: Text(file.name, style: GoogleFonts.montserrat(fontSize: 11.5, color: const Color(0xFF0F172A))),
                    backgroundColor: const Color(0xFFFEF3C7),
                    deleteIcon: const Icon(Icons.close, size: 14, color: Color(0xFF94A3B8)),
                    onDeleted: () {
                      setState(() => _pendingAttachedFiles.remove(file));
                    },
                  );
                }).toList(),
              ),
            ],

            const SizedBox(height: 18),

            // Submit Log Button
            ElevatedButton.icon(
              onPressed: _logStatusUpdate,
              icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
              label: const Text('LOG UPDATE & SAVE PROGRESS'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F172A),
                foregroundColor: AppTheme.accentColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                minimumSize: const Size(double.infinity, 48),
                elevation: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- WIDGET 3: COMPLETION / FINAL DELIVERY FORM CARD ---
  Widget _buildCompletionFormCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFD1FAE5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.task_alt_rounded, color: Color(0xFF059669), size: 22),
              ),
              const SizedBox(width: 12),
              Text(
                'WORKFILE COMPLETION & FINAL DELIVERY DETAILS',
                style: GoogleFonts.montserrat(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF0F172A),
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          _buildFieldHeader('1. WORKFILE STATUS'),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFCBD5E1)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _primaryStatus,
                isExpanded: true,
                style: GoogleFonts.montserrat(color: const Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 13.5),
                items: const [
                  DropdownMenuItem(
                    value: 'Pending',
                    child: Row(
                      children: [
                        Icon(Icons.hourglass_top_rounded, color: Color(0xFFB45309), size: 18),
                        SizedBox(width: 10),
                        Text('Pending Work'),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'In Progress',
                    child: Row(
                      children: [
                        Icon(Icons.play_circle_filled_rounded, color: Color(0xFF0284C7), size: 18),
                        SizedBox(width: 10),
                        Text('In Progress'),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'Completed',
                    child: Row(
                      children: [
                        Icon(Icons.task_alt_rounded, color: Color(0xFF10B981), size: 18),
                        SizedBox(width: 10),
                        Text('Completed & Delivered'),
                      ],
                    ),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _primaryStatus = val);
                  }
                },
              ),
            ),
          ),

          const SizedBox(height: 18),

          _buildFieldHeader('2. COMPLETION REASON / OUTCOME'),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFCBD5E1)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _completionReasons.contains(_completionReason) ? _completionReason : _completionReasons.first,
                isExpanded: true,
                style: GoogleFonts.montserrat(color: const Color(0xFF0F172A), fontWeight: FontWeight.w600, fontSize: 14),
                items: _completionReasons.map((r) {
                  return DropdownMenuItem(value: r, child: Text(r));
                }).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _completionReason = val);
                },
              ),
            ),
          ),

          const SizedBox(height: 18),

          _buildFieldHeader('3. COMPLETION / DELIVERY DATE'),
          const SizedBox(height: 6),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _completionDate ?? DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime(2035),
              );
              if (picked != null) {
                setState(() => _completionDate = picked);
              }
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFCBD5E1)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.event_available_rounded, color: Color(0xFF059669), size: 20),
                  const SizedBox(width: 12),
                  Text(
                    _completionDate != null
                        ? DateFormat('EEEE, dd MMMM yyyy').format(_completionDate!)
                        : DateFormat('EEEE, dd MMMM yyyy (Today)').format(DateTime.now()),
                    style: GoogleFonts.montserrat(color: const Color(0xFF0F172A), fontWeight: FontWeight.w600, fontSize: 13.5),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 18),

          _buildFieldHeader('4. FINAL DELIVERY & CLOSURE NOTES'),
          const SizedBox(height: 6),
          TextField(
            controller: _completionNotesController,
            maxLines: 3,
            style: GoogleFonts.montserrat(fontSize: 13.5, color: const Color(0xFF0F172A), fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: 'Enter final handover notes, certificate delivery details, or client signoff...',
              hintStyle: GoogleFonts.montserrat(fontSize: 13, color: const Color(0xFF94A3B8)),
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF059669), width: 1.5),
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),

          const SizedBox(height: 18),

          _buildFieldHeader('5. ATTACH FINAL CERTIFICATE / DELIVERY FILES'),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: _pickCompletionFiles,
            icon: const Icon(Icons.upload_file_rounded, size: 18),
            label: const Text('ATTACH FINAL DOCUMENTS / DELIVERABLES'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF0F172A),
              side: const BorderSide(color: Color(0xFFCBD5E1)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(double.infinity, 44),
            ),
          ),

          if (_completionAttachedFiles.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _completionAttachedFiles.map((file) {
                return Chip(
                  avatar: const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF059669)),
                  label: Text(file.name, style: GoogleFonts.montserrat(fontSize: 11.5, color: const Color(0xFF0F172A))),
                  backgroundColor: const Color(0xFFD1FAE5),
                  deleteIcon: const Icon(Icons.close, size: 14, color: Color(0xFF94A3B8)),
                  onDeleted: () {
                    setState(() => _completionAttachedFiles.remove(file));
                  },
                );
              }).toList(),
            ),
          ],

          const SizedBox(height: 24),

          ElevatedButton.icon(
            onPressed: _logCompletionAndClose,
            icon: const Icon(Icons.verified_rounded, size: 18),
            label: const Text('LOG FINAL DELIVERY & CLOSE WORKFILE'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF059669),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              minimumSize: const Size(double.infinity, 48),
              elevation: 2,
            ),
          ),
        ],
      ),
    );
  }

  // --- WIDGET 4: TIMELINE FLOW CARD ---
  Widget _buildTimelineFlowCard() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.timeline_rounded, color: Color(0xFF059669), size: 20),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'WORKFILE PROCEEDINGS TIMELINE FLOW',
                    style: GoogleFonts.montserrat(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF0F172A),
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_flowHistory.length} UPDATES',
                  style: GoogleFonts.montserrat(fontSize: 11, fontWeight: FontWeight.bold, color: const Color(0xFF475569)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          if (_flowHistory.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Column(
                  children: [
                    const Icon(Icons.history_toggle_off_rounded, color: Color(0xFF94A3B8), size: 48),
                    const SizedBox(height: 12),
                    Text(
                      'No proceedings logged yet.',
                      style: GoogleFonts.montserrat(fontSize: 14, color: const Color(0xFF64748B), fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Use the form to log your first work update.',
                      style: GoogleFonts.montserrat(fontSize: 12, color: const Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _flowHistory.length,
              separatorBuilder: (context, _) => const SizedBox(height: 16),
              itemBuilder: (context, index) {
                final entry = _flowHistory[index];
                return _buildTimelineItemCard(entry, isLatest: index == 0);
              },
            ),
        ],
      ),
    );
  }

  // Individual Timeline Item Entry
  Widget _buildTimelineItemCard(Map<String, dynamic> entry, {required bool isLatest}) {
    final stage = entry['stage']?.toString() ?? 'Update';
    final notes = entry['notes']?.toString() ?? entry['proceedings']?.toString() ?? '';
    final targetDateStr = entry['target_date']?.toString() ?? entry['next_hearing_date']?.toString();
    final timestamp = entry['timestamp']?.toString();
    final updatedBy = entry['updated_by']?.toString() ?? 'Staff';
    final attachments = entry['attachments'] as List?;

    DateTime? targetDate;
    if (targetDateStr != null) {
      try {
        targetDate = DateTime.tryParse(targetDateStr);
      } catch (_) {}
    }

    DateTime? entryDate;
    if (timestamp != null) {
      try {
        entryDate = DateTime.tryParse(timestamp);
      } catch (_) {}
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isLatest ? const Color(0xFFFFFBEB) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isLatest ? const Color(0xFFFDE68A) : const Color(0xFFE2E8F0),
          width: isLatest ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isLatest ? const Color(0xFF0F172A) : const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  stage.toUpperCase(),
                  style: GoogleFonts.montserrat(
                    color: isLatest ? AppTheme.accentColor : const Color(0xFF334155),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (entryDate != null)
                Text(
                  DateFormat('dd MMM yyyy • hh:mm a').format(entryDate),
                  style: GoogleFonts.montserrat(fontSize: 11, color: const Color(0xFF64748B), fontWeight: FontWeight.w500),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Body Text
          Text(
            notes,
            style: GoogleFonts.montserrat(
              fontSize: 13.5,
              color: const Color(0xFF0F172A),
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),

          if (targetDate != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.event_available_rounded, size: 15, color: Color(0xFFB45309)),
                  const SizedBox(width: 6),
                  Text(
                    'Next Follow-up / Target: ${DateFormat('dd MMMM yyyy').format(targetDate)}',
                    style: GoogleFonts.montserrat(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF92400E),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (attachments != null && attachments.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: attachments.map((att) {
                final name = att['name'] ?? 'Attachment';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFCBD5E1)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.attach_file_rounded, size: 14, color: AppTheme.accentColor),
                      const SizedBox(width: 6),
                      Text(
                        name,
                        style: GoogleFonts.montserrat(fontSize: 11.5, color: const Color(0xFF334155), fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],

          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Logged by $updatedBy',
              style: GoogleFonts.montserrat(fontSize: 10.5, color: const Color(0xFF94A3B8), fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldHeader(String title) {
    return Text(
      title,
      style: GoogleFonts.montserrat(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: const Color(0xFF475569),
        letterSpacing: 0.5,
      ),
    );
  }
}

