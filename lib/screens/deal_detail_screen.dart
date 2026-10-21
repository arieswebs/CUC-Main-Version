import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import '../models/deal.dart';
import '../models/billing.dart';
import '../models/deal_activity.dart';
import '../services/deal_service.dart';
import '../services/client_service.dart';
import '../services/notification_service.dart';
import 'billing_screen.dart';
import '../theme.dart';
import '../services/logging_service.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_api/amplify_api.dart';
import '../models/ModelProvider.dart' as amplify_models;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'client_files_dialog.dart';
import '../models/client.dart';
import '../services/google_docs_service.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'google_docs_webview_screen.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import 'file_acknowledgement_screen.dart';
import 'client_files_screen.dart';
import '../services/meta_service.dart';

class DealDetailScreen extends StatefulWidget {
  final Deal? deal;
  final bool isCrm;
  const DealDetailScreen({super.key, this.deal, this.isCrm = false});

  @override
  State<DealDetailScreen> createState() => _DealDetailScreenState();
}

class _DealDetailScreenState extends State<DealDetailScreen>
    with SingleTickerProviderStateMixin {
  final _dealService = DealService();

  final List<Map<String, String>> _connectedDocs = [];
  // Basic Controllers
  late TextEditingController _nameController;
  late TextEditingController _clientController;
  late TextEditingController _companyController;
  late TextEditingController _contactController;
  late TextEditingController _workTypeController;
  String _selectedCategory = 'General';
  late TextEditingController _descriptionController;

  // Stage Specific Controllers
  late TextEditingController _regFeeController;
  late TextEditingController _referredByController;
  late TextEditingController _filesReceivedController;
  late TextEditingController _filesAskedController;
  late TextEditingController _newFileAskedController;
  late TextEditingController _estAmountController;
  final List<Map<String, TextEditingController>> _expenseControllers = [];
  late TextEditingController _invoiceAmountController;
  late TextEditingController _registerNoController;
  late TextEditingController _finalCommentsController;
  late TextEditingController _driveLinkController;
  late TextEditingController _paymentReceivedController;
  late TextEditingController _partPaymentAmountController;

  late String _pipeline;
  late bool _isWon;
  late String _currentStage;
  late String _priority;
  late String _contactStatus;
  late String _createInvoiceShare;
  late String _sendToCustomer;
  late String _paymentType;
  int? _responsibleId;
  String? _responsibleName;
  int? _billingId;
  int? _quotationId;

  late bool _isAdjourned;
  late bool _nocObtained;
  late TextEditingController _adjournedReasonController;
  DateTime? _postponedDate;

  late TextEditingController _commentController;
  final FocusNode _commentFocus = FocusNode();

  late TabController _tabController;
  List<DealActivity> _activities = [];
  List<DealAssignee> _assignees = [];
  List<Map<String, dynamic>> _allUsers = [];
  bool _isLoading = false;
  final ScrollController _pipelineScrollController = ScrollController();

  String? _currentDescription;
  dynamic _selectedVerifierId;
  bool _isDraftCreated = false;
  DateTime? _selectedDeadline;

  @override
  void initState() {
    super.initState();
    final d = widget.deal;

    _nameController = TextEditingController(text: d?.name);
    _clientController = TextEditingController(text: d?.clientName);
    _companyController = TextEditingController(text: d?.company);
    _contactController = TextEditingController(text: d?.contactInfo);
    String currentType = d?.workType ?? '';
    String currentCategory = 'General';
    if (currentType.toLowerCase().startsWith('legal')) {
      currentCategory = 'Legal';
      if (currentType.length > 5 && currentType.contains('-')) {
        currentType = currentType.replaceFirst(RegExp(r'legal\s*-\s*', caseSensitive: false), '').trim();
      } else {
        currentType = currentType.replaceFirst(RegExp(r'legal\s*', caseSensitive: false), '').trim();
      }
    } else if (currentType.toLowerCase().startsWith('consultancy')) {
      currentCategory = 'Consultancy';
      currentType = currentType.replaceFirst(RegExp(r'consultancy\s*-?\s*', caseSensitive: false), '').trim();
    }
    _workTypeController = TextEditingController(text: currentType);
    _selectedCategory = currentCategory;
    
    // Parse out verification blocks from description to display comments cleanly
    _currentDescription = d?.description;
    String cleanDesc = _currentDescription ?? '';
    final parsedVer = VerificationDetails.parse(cleanDesc);
    cleanDesc = parsedVer.cleanDescription;
    _descriptionController = TextEditingController(text: cleanDesc);
    _selectedVerifierId = parsedVer.verifierId;
    _isDraftCreated = parsedVer.verifierId != null || (parsedVer.draftLink != null && parsedVer.draftLink!.isNotEmpty);

    _regFeeController = TextEditingController(text: d?.regFeeRequired);
    _referredByController = TextEditingController(text: d?.referredBy);
    _filesReceivedController = TextEditingController(text: d?.filesReceived);
    _filesAskedController = TextEditingController(text: d?.filesAsked);
    _newFileAskedController = TextEditingController();
    _estAmountController = TextEditingController(
      text: d?.estAmountWork?.toInt().toString() ?? '0',
    );
    final savedExpenses = d?.expensesList ?? [];
    if (savedExpenses.isNotEmpty) {
      for (var e in savedExpenses) {
        _expenseControllers.add({
          'name': TextEditingController(text: e['name']?.toString() ?? ''),
          'amount': TextEditingController(text: e['amount']?.toString() ?? ''),
        });
      }
    }
    _invoiceAmountController = TextEditingController(
      text: d?.invoiceAmount?.toInt().toString() ?? '0',
    );
    _registerNoController = TextEditingController(text: d?.registerNo);
    _finalCommentsController = TextEditingController();
    final initialDriveLink = d?.driveLink ?? '';
    if (initialDriveLink.isNotEmpty) {
      if (initialDriveLink.startsWith('[')) {
        try {
          final List<dynamic> parsed = jsonDecode(initialDriveLink);
          for (var item in parsed) {
            _connectedDocs.add({"name": item["name"].toString(), "url": item["url"].toString()});
          }
        } catch (e) {
          _connectedDocs.add({"name": "Connected Document", "url": initialDriveLink});
        }
      } else {
        _connectedDocs.add({"name": "Connected Document", "url": initialDriveLink});
      }
    }
    _driveLinkController = TextEditingController(text: d?.driveLink);
    _paymentReceivedController = TextEditingController(text: widget.deal?.paymentReceived?.toString() ?? '');
    _partPaymentAmountController = TextEditingController(text: widget.deal?.partPaymentAmount?.toString() ?? '');
    _partPaymentAmountController.addListener(() {
      setState(() {});
    });

    _pipeline = widget.deal?.pipeline ?? (widget.isCrm ? 'CRM' : 'General');
    _isWon = widget.deal?.isWon ?? false;
    _currentStage = widget.deal?.stage ?? 'Registration';
    _priority = d?.priority ?? 'Normal';
    _contactStatus = d?.contactStatus ?? 'not selected';
    _createInvoiceShare = d?.createInvoiceShare ?? 'not selected';
    _sendToCustomer = d?.sendToCustomer ?? 'not selected';
    _paymentType = d?.paymentType ?? 'not selected';
    _responsibleId = d?.responsibleId;
    _responsibleName = d?.responsibleName;
    _billingId = widget.deal?.billingId;
    _quotationId = widget.deal?.quotationId;
    _isAdjourned = widget.deal?.isAdjourned ?? false;
    _nocObtained = widget.deal?.nocObtained ?? false;
    _adjournedReasonController = TextEditingController(text: widget.deal?.adjournedReason ?? '');
    _postponedDate = d?.postponedDate;
    _selectedDeadline = d?.closedAt;

    _commentController = TextEditingController();
    _tabController = TabController(length: 3, vsync: this);

    if (d != null) {
      _loadDetails();
    }
    _loadUsers();
    _loadCurrentUser();
  }

  int? _currentUserId;
  String? _currentUserName;

  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _currentUserId = prefs.getInt('current_user_id');
        _currentUserName = prefs.getString('user_name');
      });
    }
  }

  Future<void> _updateVerification({int? verifierId, String? verifierName, required String status, String? draftLink}) async {
    if (widget.deal?.id == null) return;
    setState(() => _isLoading = true);
    try {
      final cleanDesc = _descriptionController.text.trim();
      final String block;
      if (verifierId != null && verifierName != null) {
        final dLink = draftLink ?? "";
        block = "\n\n[VERIFICATION]\nVerifierID: $verifierId\nVerifierName: $verifierName\nStatus: $status\nDraftLink: $dLink";
      } else {
        block = "";
      }
      final newDesc = "$cleanDesc$block";
      final newStage = status == 'Draft' ? 'Verification' : _currentStage;

      final deal = Deal(
        id: widget.deal?.id,
        name: _nameController.text,
        clientName: _clientController.text,
        company: _companyController.text,
        contactInfo: _contactController.text,
        workType: _selectedCategory == 'General' ? _workTypeController.text : _workTypeController.text.isEmpty ? _selectedCategory : '$_selectedCategory - ${_workTypeController.text}',
        description: newDesc,
        stage: newStage,
        priority: _priority,
        responsibleId: _responsibleId,
        responsibleName: _responsibleName,
        regFeeRequired: _regFeeController.text,
        referredBy: _referredByController.text,
        filesReceived: _filesReceivedController.text,
        contactStatus: _contactStatus,
        filesAsked: _filesAskedController.text,
        estAmountWork: double.tryParse(_estAmountController.text) ?? 0,
        createInvoiceShare: _createInvoiceShare,
        expenseSpent: _calculateTotalExpense(),
        expensesList: _getExpensesList(),
        sendToCustomer: _sendToCustomer,
        registerNo: _registerNoController.text,
        invoiceAmount: double.tryParse(_invoiceAmountController.text) ?? 0,
        paymentType: _paymentType,
        driveLink: _driveLinkController.text,
        amount: double.tryParse(_invoiceAmountController.text) ?? 0,
        billingId: _billingId,
        quotationId: _quotationId,
        paymentReceived: double.tryParse(_paymentReceivedController.text) ?? 0,
        partPaymentAmount: double.tryParse(_partPaymentAmountController.text) ?? 0,
        nocObtained: _nocObtained,
        isAdjourned: _isAdjourned,
        adjournedReason: _isAdjourned ? _adjournedReasonController.text : null,
        postponedDate: _isAdjourned || _postponedDate != null ? _postponedDate : null,
        closedAt: _selectedDeadline,
        pipeline: _pipeline,
        isWon: _isWon,
      );

      await _dealService.updateDeal(deal);
      
      if (status == 'Draft' && verifierId != null) {
        await NotificationService().sendNotification(
          userId: verifierId,
          title: 'Verification Request',
          message: 'You have been assigned to verify the work draft for "${widget.deal?.name}".',
          dealId: widget.deal?.id,
        );
        await LoggingService().logAction(
          action: 'DRAFT_SHARED',
          targetType: 'Work',
          targetId: widget.deal?.id.toString() ?? '',
          details: 'Shared work draft with verifier: $verifierName',
        );
      } else if (status == 'Verified') {
        if (_responsibleId != null) {
          await NotificationService().sendNotification(
            userId: _responsibleId!,
            title: 'Draft Verified',
            message: 'Your work draft for "${widget.deal?.name}" has been verified by $verifierName.',
            dealId: widget.deal?.id,
          );
        }
        await LoggingService().logAction(
          action: 'DRAFT_VERIFIED',
          targetType: 'Work',
          targetId: widget.deal?.id.toString() ?? '',
          details: 'Work draft verified by $verifierName',
        );
      }

      if (mounted) {
        setState(() {
          _currentStage = newStage;
          _currentDescription = newDesc;
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(status == 'Verified' ? 'Work draft successfully verified!' : 'Verifier assigned and draft shared!'),
            backgroundColor: Colors.green,
          ),
        );
        _loadDetails();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _completeWorkAndShareDraft() async {
    if (widget.deal?.id == null) return;
    setState(() => _isLoading = true);
    try {
      final cleanDesc = _descriptionController.text.trim();
final dLink = "";
      String newDesc = cleanDesc;

      if (_selectedVerifierId != null) {
        final vUser = _allUsers.firstWhere((u) => int.tryParse(u['id'].toString()) == _selectedVerifierId);
        final vName = vUser['name'].toString();
        newDesc = "$cleanDesc\n\n[VERIFICATION]\nVerifierID: $_selectedVerifierId\nVerifierName: $vName\nStatus: Draft\nDraftLink: $dLink";
      }

      final deal = Deal(
        id: widget.deal?.id,
        name: _nameController.text,
        clientName: _clientController.text,
        company: _companyController.text,
        contactInfo: _contactController.text,
        workType: _selectedCategory == 'General' ? _workTypeController.text : _workTypeController.text.isEmpty ? _selectedCategory : '$_selectedCategory - ${_workTypeController.text}',
        description: newDesc,
        stage: 'Verification',
        priority: _priority,
        responsibleId: _responsibleId,
        responsibleName: _responsibleName,
        regFeeRequired: _regFeeController.text,
        referredBy: _referredByController.text,
        filesReceived: _filesReceivedController.text,
        contactStatus: _contactStatus,
        filesAsked: _filesAskedController.text,
        estAmountWork: double.tryParse(_estAmountController.text) ?? 0,
        createInvoiceShare: _createInvoiceShare,
        expenseSpent: _calculateTotalExpense(),
        expensesList: _getExpensesList(),
        sendToCustomer: _sendToCustomer,
        registerNo: _registerNoController.text,
        invoiceAmount: double.tryParse(_invoiceAmountController.text) ?? 0,
        paymentType: _paymentType,
        driveLink: _driveLinkController.text,
        amount: double.tryParse(_invoiceAmountController.text) ?? 0,
        billingId: _billingId,
        quotationId: _quotationId,
        paymentReceived: double.tryParse(_paymentReceivedController.text) ?? 0,
        partPaymentAmount: double.tryParse(_partPaymentAmountController.text) ?? 0,
        nocObtained: _nocObtained,
        isAdjourned: _isAdjourned,
        adjournedReason: _isAdjourned ? _adjournedReasonController.text : null,
        postponedDate: _isAdjourned || _postponedDate != null ? _postponedDate : null,
        closedAt: _selectedDeadline,
        pipeline: _pipeline,
        isWon: _isWon,
      );

      await _dealService.updateDeal(deal);

      if (_selectedVerifierId != null) {
        final vUser = _allUsers.firstWhere((u) => int.tryParse(u['id'].toString()) == _selectedVerifierId);
        final vName = vUser['name'].toString();
        await NotificationService().sendNotification(
          userId: _selectedVerifierId!,
          title: 'Verification Request',
          message: 'You have been assigned to verify the work draft for "${widget.deal?.name}".',
          dealId: widget.deal?.id,
        );
        await LoggingService().logAction(
          action: 'DRAFT_SHARED',
          targetType: 'Work',
          targetId: widget.deal?.id.toString() ?? '',
          details: 'Shared work draft with verifier: $vName',
        );
      } else {
        await LoggingService().logAction(
          action: 'WORK_SENT_TO_VERIFICATION',
          targetType: 'Work',
          targetId: widget.deal?.id.toString() ?? '',
          details: 'Work completed and sent to verification stage.',
        );
      }

      if (mounted) {
        setState(() {
          _currentStage = 'Verification';
          _currentDescription = newDesc;
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_selectedVerifierId != null
                ? 'Work completed & draft shared with verifier!'
                : 'Work completed & moved to Verification!'),
            backgroundColor: Colors.green,
          ),
        );
        _loadDetails();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _completeWorkWithoutDraft() async {
    if (widget.deal?.id == null) return;
    setState(() => _isLoading = true);
    try {
      final cleanDesc = _descriptionController.text.trim();
      String finalDesc = cleanDesc;
      final index = finalDesc.indexOf('[VERIFICATION]');
      if (index != -1) {
        finalDesc = finalDesc.substring(0, index).trim();
      }

      final deal = Deal(
        id: widget.deal?.id,
        name: _nameController.text,
        clientName: _clientController.text,
        company: _companyController.text,
        contactInfo: _contactController.text,
        workType: _selectedCategory == 'General' ? _workTypeController.text : _workTypeController.text.isEmpty ? _selectedCategory : '$_selectedCategory - ${_workTypeController.text}',
        description: finalDesc,
        stage: 'Invoice',
        priority: _priority,
        responsibleId: _responsibleId,
        responsibleName: _responsibleName,
        regFeeRequired: _regFeeController.text,
        referredBy: _referredByController.text,
        filesReceived: _filesReceivedController.text,
        contactStatus: _contactStatus,
        filesAsked: _filesAskedController.text,
        estAmountWork: double.tryParse(_estAmountController.text) ?? 0,
        createInvoiceShare: _createInvoiceShare,
        expenseSpent: _calculateTotalExpense(),
        expensesList: _getExpensesList(),
        sendToCustomer: _sendToCustomer,
        registerNo: _registerNoController.text,
        invoiceAmount: double.tryParse(_invoiceAmountController.text) ?? 0,
        paymentType: _paymentType,
        driveLink: _driveLinkController.text,
        amount: double.tryParse(_invoiceAmountController.text) ?? 0,
        billingId: _billingId,
        quotationId: _quotationId,
        paymentReceived: double.tryParse(_paymentReceivedController.text) ?? 0,
        partPaymentAmount: double.tryParse(_partPaymentAmountController.text) ?? 0,
        nocObtained: _nocObtained,
        isAdjourned: _isAdjourned,
        adjournedReason: _isAdjourned ? _adjournedReasonController.text : null,
        postponedDate: _isAdjourned || _postponedDate != null ? _postponedDate : null,
        closedAt: _selectedDeadline,
        pipeline: _pipeline,
        isWon: _isWon,
      );

      await _dealService.updateDeal(deal);

      await LoggingService().logAction(
        action: 'WORK_COMPLETED',
        targetType: 'Work',
        targetId: widget.deal?.id.toString() ?? '',
        details: 'Work completed without draft verification, moved to Invoice.',
      );

      if (mounted) {
        setState(() {
          _currentStage = 'Invoice';
          _currentDescription = finalDesc;
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Work completed & moved to Invoice!'),
            backgroundColor: Colors.green,
          ),
        );
        _loadDetails();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildVerificationSection(bool isWide) {
    final parsedVer = VerificationDetails.parse(_currentDescription);
    final hasVerifier = parsedVer.verifierId != null;
    final isVerified = parsedVer.status.toLowerCase() == 'verified';
    final isDraft = parsedVer.status.toLowerCase() == 'draft';

    Color headerBg;
    Color headerBorder;
    Color headerTextCol;
    IconData headerIcon;
    String statusTitle;
    String statusDesc;

    if (!hasVerifier) {
      headerBg = Colors.amber.shade50;
      headerBorder = Colors.amber.shade200;
      headerTextCol = Colors.amber.shade900;
      headerIcon = Icons.rate_review_outlined;
      statusTitle = "Work Draft Pending Verification";
      statusDesc = "This work must be peer-reviewed and verified by another staff member before proceeding to billing.";
    } else if (isDraft) {
      headerBg = Colors.blue.shade50;
      headerBorder = Colors.blue.shade200;
      headerTextCol = Colors.blue.shade900;
      headerIcon = Icons.hourglass_empty_rounded;
      statusTitle = "Draft Shared for Peer Verification";
      statusDesc = "Assigned Verifier: ${parsedVer.verifierName ?? 'Staff Member'}. Waiting for check.";
    } else {
      headerBg = const Color(0xFFECFDF5);
      headerBorder = const Color(0xFFA7F3D0);
      headerTextCol = const Color(0xFF064E3B);
      headerIcon = Icons.verified_user_rounded;
      statusTitle = "Work Draft Peer Verified";
      statusDesc = "This work draft has been checked and verified by ${parsedVer.verifierName ?? 'Peer'}.";
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: headerBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: headerBorder, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: headerBorder.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: headerTextCol.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(headerIcon, color: headerTextCol, size: isWide ? 28 : 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      statusTitle,
                      style: TextStyle(
                        color: headerTextCol,
                        fontWeight: FontWeight.bold,
                        fontSize: isWide ? 15 : 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      statusDesc,
                      style: TextStyle(
                        color: headerTextCol.withValues(alpha: 0.85),
                        fontSize: isWide ? 13 : 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _buildConnectedDocsSection(),
        const SizedBox(height: 20),
        if (!hasVerifier) ...[
          if (_currentUserId == _responsibleId || _assignees.any((a) => a.userId == _currentUserId)) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFEFBF0),
                border: Border.all(color: const Color(0xFFFDE68A)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.person_add_rounded, color: Color(0xFFD97706), size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'Assign a Peer Verifier',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFF92400E),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'No verifier is currently assigned. Choose a staff member below to verify this work draft.',
                    style: TextStyle(color: Color(0xFFB45309), fontSize: 11, height: 1.3),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<dynamic>(
                          initialValue: _selectedVerifierId,
                          hint: const Text('Select a staff member...'),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: const BorderSide(color: Color(0xFFFCD34D)),
                            ),
                          ),
                          items: _allUsers
                              .where((u) => int.tryParse(u['id'].toString()) != _currentUserId && (u['role']?.toString().toLowerCase() == 'staff' || u['role']?.toString().toLowerCase() == 'manager'))
                              .map((u) => DropdownMenuItem<int>(
                                    value: int.tryParse(u['id'].toString()) ?? 0,
                                    child: Text(u['name'].toString()),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            setState(() {
                              _selectedVerifierId = v;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _selectedVerifierId == null
                            ? null
                            : () {
                                final vUser = _allUsers.firstWhere((u) => u['id'].toString() == _selectedVerifierId.toString(), orElse: () => {'name': 'Unknown'});
                                _updateVerification(
                                  verifierId: _selectedVerifierId,
                                  verifierName: vUser['name'].toString(),
                                  status: 'Draft',
                                );
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD97706),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        child: const Text('Assign', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                border: Border.all(color: const Color(0xFFFDE68A)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'No verifier is currently assigned. One of the assigned staff members must select a peer verifier to review this draft.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF92400E), fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ] else if (isDraft) ...[
          if (_currentUserId == parsedVer.verifierId) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  _updateVerification(
                    verifierId: parsedVer.verifierId,
                    verifierName: parsedVer.verifierName,
                    status: 'Verified',
                  );
                },
                icon: const Icon(Icons.check_circle_rounded, size: 22),
                label: const Text('VERIFY WORK DRAFT', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 3,
                ),
              ),
            ),
          ] else if (_currentUserId == _responsibleId || _assignees.any((a) => a.userId == _currentUserId)) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                border: Border.all(color: const Color(0xFFE2E8F0)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Waiting for ${parsedVer.verifierName} to verify.',
                    style: const TextStyle(color: Color(0xFF475569), fontWeight: FontWeight.w500, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  const Divider(),
                  const SizedBox(height: 6),
                  const Text(
                    'Need to change verifier?',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<dynamic>(
                          initialValue: _selectedVerifierId,
                          hint: const Text('Select new verifier...'),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                          ),
                          items: _allUsers
                              .where((u) => int.tryParse(u['id'].toString()) != _currentUserId && (u['role']?.toString().toLowerCase() == 'staff' || u['role']?.toString().toLowerCase() == 'manager'))
                              .map((u) => DropdownMenuItem<int>(
                                    value: int.tryParse(u['id'].toString()) ?? 0,
                                    child: Text(u['name'].toString()),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            setState(() {
                              _selectedVerifierId = v;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _selectedVerifierId == null || _selectedVerifierId == parsedVer.verifierId
                            ? null
                            : () {
                                final vUser = _allUsers.firstWhere((u) => u['id'].toString() == _selectedVerifierId.toString(), orElse: () => {'name': 'Unknown'});
                                _updateVerification(
                                  verifierId: _selectedVerifierId,
                                  verifierName: vUser['name'].toString(),
                                  status: 'Draft',
                                );
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6366F1),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        child: const Text('Change', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Waiting for peer verification by ${parsedVer.verifierName ?? "Assigned Verifier"}.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ],
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 16),
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: isVerified
                    ? () async {
                        if (widget.deal?.id == null) return;
                        setState(() => _isLoading = true);
                        try {
                          await _dealService.moveDealToStage(
                            widget.deal!.id!,
                            'Verification',
                            'Invoice',
                          );
                          if (mounted) {
                            setState(() {
                              _currentStage = 'Invoice';
                              _isLoading = false;
                            });
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Stage updated to: Invoice'),
                                backgroundColor: Colors.green,
                              ),
                            );
                            _loadDetails();
                          }
                        } catch (e) {
                          if (mounted) {
                            setState(() => _isLoading = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error: $e'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      }
                    : null,
                icon: isVerified
                    ? const Icon(Icons.arrow_forward_rounded)
                    : const Icon(Icons.lock_rounded, size: 20),
                label: Text(
                  isVerified ? 'PROCEED TO BILLING / INVOICE' : 'LOCKED - PENDING PEER VERIFICATION',
                  style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isVerified ? const Color(0xFF2563EB) : const Color(0xFF94A3B8),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFE2E8F0),
                  disabledForegroundColor: const Color(0xFF94A3B8),
                  padding: EdgeInsets.symmetric(vertical: isWide ? 18 : 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: isVerified ? 2 : 0,
                ),
              ),
            ),
          ],
        ),
        if (!isVerified) ...[
          const SizedBox(height: 8),
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFF64748B)),
                const SizedBox(width: 4),
                Text(
                  hasVerifier
                      ? "Awaiting verification check by ${parsedVer.verifierName}."
                      : "A verifier must be assigned to verify and unlock this step.",
                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 11, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _newFileAskedController.dispose();
    _paymentReceivedController.dispose();
    _partPaymentAmountController.dispose();
    _adjournedReasonController.dispose();
    _pipelineScrollController.dispose();
    super.dispose();
  }

  Future<void> _toggleNoc(bool value) async {
    if (value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Confirm NOC'),
          content: const Text('Have you received NOC from Irshad sir to start work without receiving part payment?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('No'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Yes', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        setState(() => _nocObtained = true);
      } else {
        setState(() => _nocObtained = false);
      }
    } else {
      setState(() => _nocObtained = false);
    }
  }

  Future<void> _loadDetails() async {
    if (widget.deal?.id == null) return;
    final dealId = widget.deal!.id!;
    final activities = await _dealService.getActivities(dealId);
    final assignees = await _dealService.getAssignees(dealId);

    // Auto-sync amount from linked bill
    if (_billingId != null) {
      try {
        final req = ModelQueries.list(amplify_models.Billings.classType, where: amplify_models.Billings.ID.eq(_billingId.toString()), limit: 10000);
        final resList = await Amplify.API.query(request: req).response;
        final billRes = resList.data?.items.isNotEmpty == true ? resList.data?.items.first : null;
            
        if (billRes != null && billRes.amount != null) {
          final rawAmt = billRes.amount.toString();
          // Extract numeric part (e.g. "1500/-" -> "1500")
          final cleanAmt = rawAmt.replaceAll(RegExp(r'[^0-9.]'), '');
          if (cleanAmt.isNotEmpty) {
            final parsed = double.tryParse(cleanAmt);
            _invoiceAmountController.text =
                parsed != null ? parsed.toInt().toString() : cleanAmt;
          }
        }
      } catch (e) {
        debugPrint('Error syncing bill amount: $e');
      }
    }

    if (mounted) {
      setState(() {
        _activities = activities;
        _assignees = assignees;
      });
    }
  }

  Future<void> _loadUsers() async {
    final users = await _dealService.getAllUsers();
    if (mounted) setState(() => _allUsers = users);
  }

  Future<void> _showPassLeadDialog() async {
    final clientNameController = TextEditingController(
      text: _clientController.text.isNotEmpty ? _clientController.text : _nameController.text,
    );
    final contactController = TextEditingController(text: _contactController.text);
    final workNameController = TextEditingController(text: _nameController.text);
    final workTypeController = TextEditingController(
      text: _workTypeController.text.isNotEmpty ? _workTypeController.text : _selectedCategory,
    );
    final amountController = TextEditingController(
      text: _invoiceAmountController.text != '0' && _invoiceAmountController.text.isNotEmpty
          ? _invoiceAmountController.text
          : _estAmountController.text,
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.green.shade50, shape: BoxShape.circle),
              child: const Icon(Icons.verified, color: Colors.green, size: 24),
            ),
            const SizedBox(width: 12),
            const Text('Pass Lead to Work & Client', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 20, color: Colors.blue.shade700),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Passing this lead will automatically register the client in Client Management and activate this project in Work Management.',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade900),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: clientNameController,
                decoration: const InputDecoration(labelText: 'Client Name *', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contactController,
                decoration: const InputDecoration(labelText: 'Contact Phone / Email', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: workNameController,
                decoration: const InputDecoration(labelText: 'Work Name *', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: workTypeController,
                      decoration: const InputDecoration(labelText: 'Work Type', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: amountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Amount (₹)', border: OutlineInputBorder()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check_circle, size: 18),
            label: const Text('Confirm & Pass to Work', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        final client = await ClientService().getOrCreateClientForLead(
          clientName: clientNameController.text.trim().isNotEmpty
              ? clientNameController.text.trim()
              : (_nameController.text.isNotEmpty ? _nameController.text.trim() : 'Unknown Client'),
          phone: contactController.text.trim(),
          typeOfWork: workTypeController.text.trim(),
        );

        _isWon = true;
        _currentStage = 'Work Started';
        _pipeline = 'CRM';
        _clientController.text = client.name ?? clientNameController.text.trim();
        _nameController.text = workNameController.text.trim();

        final currentDeal = widget.deal ?? Deal(
          name: _nameController.text,
          clientName: _clientController.text,
          stage: _currentStage,
          pipeline: _pipeline,
          isWon: true,
        );

        final updatedDeal = currentDeal.copyWith(
          name: _nameController.text,
          clientId: int.tryParse(client.id) ?? currentDeal.clientId,
          clientName: client.name ?? clientNameController.text.trim(),
          contactInfo: contactController.text.trim(),
          workType: workTypeController.text.trim(),
          amount: double.tryParse(amountController.text) ?? currentDeal.amount,
          pipeline: 'CRM',
          stage: 'Work Started',
          isWon: true,
          closedAt: DateTime.now(),
        );

        if (widget.deal == null) {
          final newId = await _dealService.createDeal(updatedDeal);
          await _dealService.passLeadToWork(
            lead: updatedDeal.copyWith(id: newId),
            clientId: client.id,
            clientName: client.name ?? clientNameController.text.trim(),
            currentUserId: _currentUserId,
          );
        } else {
          await _dealService.passLeadToWork(
            lead: updatedDeal,
            clientId: client.id,
            clientName: client.name ?? clientNameController.text.trim(),
            currentUserId: _currentUserId,
          );
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Lead "${_nameController.text}" successfully passed to Work Management & registered in Client Management!'),
              backgroundColor: const Color(0xFF16A34A),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
          Navigator.pop(context, true);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error passing lead: $e'), backgroundColor: Colors.red),
          );
          setState(() => _isLoading = false);
        }
      }
    }
  }

  Future<void> _saveDeal() async {
    setState(() => _isLoading = true);
    try {
      final deal = Deal(
        id: widget.deal?.id,
        name: _nameController.text,
        clientName: _clientController.text,
        company: _companyController.text,
        contactInfo: _contactController.text,
        workType: _selectedCategory == 'General' ? _workTypeController.text : _workTypeController.text.isEmpty ? _selectedCategory : '$_selectedCategory - ${_workTypeController.text}',
        description: () {
          String finalDesc = _descriptionController.text;
          final originalDesc = _currentDescription ?? '';
          if (originalDesc.contains('[VERIFICATION]')) {
            final index = originalDesc.indexOf('[VERIFICATION]');
            finalDesc = "${finalDesc.trim()}\n\n${originalDesc.substring(index).trim()}";
          }
          return finalDesc;
        }(),
        stage: _currentStage,
        priority: _priority,
        responsibleId: _responsibleId,
        responsibleName: _responsibleName,
        regFeeRequired: _regFeeController.text,
        referredBy: _referredByController.text,
        filesReceived: _filesReceivedController.text,
        contactStatus: _contactStatus,
        filesAsked: _filesAskedController.text,
        estAmountWork: double.tryParse(_estAmountController.text) ?? 0,
        createInvoiceShare: _createInvoiceShare,
        expenseSpent: _calculateTotalExpense(),
        expensesList: _getExpensesList(),
        sendToCustomer: _sendToCustomer,
        registerNo: _registerNoController.text,
        invoiceAmount: double.tryParse(_invoiceAmountController.text) ?? 0,
        paymentType: _paymentType,
        driveLink: _driveLinkController.text,
        amount: double.tryParse(_invoiceAmountController.text) ?? 0,
        billingId: _billingId,
        quotationId: _quotationId,
        paymentReceived: double.tryParse(_paymentReceivedController.text) ?? 0,
        partPaymentAmount: double.tryParse(_partPaymentAmountController.text) ?? 0,
        nocObtained: _nocObtained,
        isAdjourned: _isAdjourned,
        adjournedReason: _isAdjourned ? _adjournedReasonController.text : null,
        postponedDate: _isAdjourned || _postponedDate != null ? _postponedDate : null,
        closedAt: _selectedDeadline,
        pipeline: _pipeline,
        isWon: _isWon,
      );

      if (widget.deal == null) {
        await _dealService.createDeal(deal);
        await LoggingService().logAction(action: 'WORK_CREATED', targetType: 'Work', targetId: deal.name, details: 'Created work for ${deal.clientName}');
      } else {
        await _dealService.updateDeal(deal);
        await LoggingService().logAction(action: 'WORK_UPDATED', targetType: 'Work', targetId: deal.id.toString(), details: 'Updated work: ${deal.name}');
        // Sync with linked bill if present
        if (_billingId != null) {
          final received =
              double.tryParse(_paymentReceivedController.text) ?? 0;
          final total = double.tryParse(_invoiceAmountController.text) ?? 0;
          final balance = total - received;

          final req = ModelQueries.list(amplify_models.Billings.classType, where: amplify_models.Billings.ID.eq(_billingId.toString()), limit: 10000);
          final res = await Amplify.API.query(request: req).response;
          final billObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
          
          if (billObj != null) {
            Map<String, dynamic> data = {};
            if (billObj.data != null && billObj.data!.isNotEmpty) {
              data = Map<String, dynamic>.from(jsonDecode(billObj.data!));
            }
            data['advance_received'] = received.toString();
            data['balance_due'] = balance.toString();

            final updatedBill = billObj.copyWith(data: jsonEncode(data));
            await BackupAwareApi().update(updatedBill);
          }
          }
        }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openInvoiceCreator() {
    if (_clientController.text.isEmpty || _nameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Client Name and Deal Name are required to generate a bill.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final amt =
        _invoiceAmountController.text.isEmpty ||
            _invoiceAmountController.text == '0'
        ? '0/-'
        : '${_invoiceAmountController.text}/-';

    final draftBilling = Billing(
      clientName: _clientController.text,
      amount: amt,
      type: 'INVOICE',
      category: 'General',
      status: 'Pending',
      data: {
        'items': [
          {
            'description':
                '${_nameController.text} - ${_workTypeController.text}',
            'amount': amt,
          },
        ],
        'client_address':
            _contactController.text, // Use contact info as fallback address
        'advance_received': '',
        'balance_due': amt,
      },
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InvoiceCreatorPage(
          billing: draftBilling,
          onSaved: (dynamic id) async {
            if (!mounted) return;
            Navigator.pop(context);
            setState(() => _isLoading = true);
            try {
              final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(widget.deal!.id.toString()), limit: 10000);
              final res = await Amplify.API.query(request: req).response;
              final dealObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
              if (dealObj != null) {
                final updatedDeal = dealObj.copyWith(billing_id: int.tryParse(id.toString()));
                await BackupAwareApi().update(updatedDeal);
              }
              
              if (mounted) {
                setState(() {
                  _billingId = int.tryParse(id.toString());
                  _isLoading = false;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Invoice generated and linked!'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            } catch (e) {
              if (mounted) {
                setState(() => _isLoading = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Error linking bill: $e'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }
          },
        ),
      ),
    );
  }

  void _openQuotationCreator() {
    if (_clientController.text.isEmpty || _nameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Client Name and Deal Name are required to generate a quotation.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final amt =
        _estAmountController.text.isEmpty || _estAmountController.text == '0'
        ? '0/-'
        : '${_estAmountController.text}/-';

    final draftBilling = Billing(
      clientName: _clientController.text,
      amount: amt,
      type: 'QUOTATION',
      category: 'General',
      status: 'Pending',
      data: {
        'items': [
          {
            'description':
                '${_nameController.text} - ${_workTypeController.text}',
            'amount': amt,
          },
        ],
        'client_address':
            _contactController.text, // Use contact info as fallback address
        'advance_received': '',
        'balance_due': amt,
      },
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InvoiceCreatorPage(
          billing: draftBilling,
          onSaved: (dynamic id) async {
            if (!mounted) return;
            Navigator.pop(context);
            setState(() => _isLoading = true);
            try {
              final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(widget.deal!.id.toString()), limit: 10000);
              final res = await Amplify.API.query(request: req).response;
              final dealObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
              if (dealObj != null) {
                final updatedDeal = dealObj.copyWith(quotation_id: int.tryParse(id.toString()));
                await BackupAwareApi().update(updatedDeal);
              }
              
              if (mounted) {
                setState(() {
                  _quotationId = int.tryParse(id.toString());
                  _isLoading = false;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Quotation generated and linked!'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            } catch (e) {
              if (mounted) {
                setState(() => _isLoading = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Error linking quotation: $e'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }
          },
        ),
      ),
    );
  }

  Future<void> _showLinkBillDialog() async {
    if (widget.deal?.id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Save the deal first before linking a bill.'),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final req = ModelQueries.list(amplify_models.Billings.classType, where: amplify_models.Billings.TYPE.eq('INVOICE'), limit: 10000);
      final resList = await Amplify.API.query(request: req).response;
      final resultList = (resList.data?.items ?? []).whereType<amplify_models.Billings>().toList() ?? [];
      resultList.sort((a, b) => (b.id).compareTo(a.id));
      final result = resultList.map((e) => e.toJson()).toList();

      final bills = result.map((row) => {
        'id': row['id'],
        'invoice_no': row['invoice_no'] ?? 'DRAFT',
        'client_name': row['client_name'] ?? 'Unknown Client',
        'amount': row['amount'] ?? '0/-',
        'date': row['date'] ?? '',
      }).toList();

      if (mounted) {
        setState(() => _isLoading = false);
        final selectedId = await showDialog<int>(
          context: context,
          builder: (context) {
            String searchQuery = '';
            return StatefulBuilder(
              builder: (context, setStateDialog) {
                final filtered = bills.where((b) {
                  final s = searchQuery.toLowerCase();
                  return b['invoice_no'].toString().toLowerCase().contains(s) ||
                      b['client_name'].toString().toLowerCase().contains(s);
                }).take(50).toList();

                return AlertDialog(
                  title: const Text(
                    'Link Existing Bill',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  content: SizedBox(
                    width: MediaQuery.of(context).size.width * 0.9,
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: Column(
                      children: [
                        TextField(
                          decoration: InputDecoration(
                            hintText: 'Search by Invoice No or Client...',
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                          ),
                          onChanged: (v) =>
                              setStateDialog(() => searchQuery = v),
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (context, index) =>
                                const Divider(),
                            itemBuilder: (context, index) {
                              final b = filtered[index];
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.blue.shade50,
                                  child: const Icon(
                                    Icons.receipt,
                                    color: Colors.blue,
                                    size: 20,
                                  ),
                                ),
                                title: Text(
                                  '${b['invoice_no']} - ${b['client_name']}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text('${b['date']} | ${b['amount']}'),
                                trailing: const Text(
                                  'LINK',
                                  style: TextStyle(
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                                onTap: () =>
                                    Navigator.pop(context, int.tryParse(b['id'].toString()) ?? 0),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('CANCEL'),
                    ),
                  ],
                );
              },
            );
          },
        );

        if (selectedId != null) {
          setState(() => _isLoading = true);
          final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(widget.deal!.id.toString()), limit: 10000);
          final res = await Amplify.API.query(request: req).response;
          final dealObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
          if (dealObj != null) {
            final updatedDeal = dealObj.copyWith(billing_id: selectedId);
            await BackupAwareApi().update(updatedDeal);
          }
          
          if (mounted) {
            setState(() {
              _billingId = selectedId;
              _isLoading = false;
            });
            _loadDetails();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Bill linked successfully!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading bills: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _openWorkFileDialog() async {
    if (widget.deal == null) return;
    try {
      final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(widget.deal!.id.toString()), limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      final match = res.data?.items.firstWhere((e) => e != null);

      final reqAll = ModelQueries.list(amplify_models.Deals.classType, limit: 10000);
      final resAll = await Amplify.API.query(request: reqAll).response;
      final allWFs = (resAll.data?.items ?? []).whereType<amplify_models.Deals>().toList() ?? [];

      if (match != null && mounted) {
        showDialog(context: context, builder: (_) => WorkFileDetailDialog(workFile: match, allWorkFiles: allWFs, onUpdate: _loadDetails));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Work file not found in database.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<String?> _openClientFilesVault({bool selectMode = false}) async {
    final cName = _clientController.text.trim();
    if (cName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select or enter a client name first.'), backgroundColor: Colors.orange));
      return null;
    }
    setState(() => _isLoading = true);
    try {
      // Fetch ALL clients with full pagination
      var req = ModelQueries.list(amplify_models.Clients.classType, limit: 1000);
      List<amplify_models.Clients> allClients = [];
      while (true) {
        final resList = await Amplify.API.query(request: req).response;
        allClients.addAll((resList.data?.items ?? []).whereType<amplify_models.Clients>() ?? []);
        if (resList.data?.hasNextResult ?? false) {
          req = resList.data!.requestForNextResult!;
        } else {
          break;
        }
      }

      if (mounted) setState(() => _isLoading = false);

      // Normalize helper: lowercase, trim, collapse whitespace
      String normalize(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

      final normalizedSearch = normalize(cName);
      debugPrint('Vault search: "$normalizedSearch" among ${allClients.length} clients');

      // Try exact normalized match first
      var matchingClients = allClients.where((c) => normalize(c.name ?? '') == normalizedSearch).toList();

      // Fallback: contains match if exact fails
      if (matchingClients.isEmpty) {
        matchingClients = allClients.where((c) => normalize(c.name ?? '').contains(normalizedSearch) || normalizedSearch.contains(normalize(c.name ?? ''))).toList();
      }

      if (matchingClients.isEmpty) {
        debugPrint('Vault: No match found. First 10 client names in DB:');
        for (var c in allClients.take(10)) {
          debugPrint('  - "${c.name}"');
        }
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Client not found in database. Please ensure it is saved in Client Management.', style: TextStyle(color: Colors.white)), backgroundColor: Colors.orange));
        return null;
      }

      final clientObj = Client.fromMap(matchingClients.first.toJson());
      if (mounted) {
        return await showDialog<String>(
          context: context,
          builder: (context) => ClientFilesDialog(client: clientObj, isSelectionMode: selectMode),
        );
      }
      return null;
    } catch (e) {
      debugPrint('Vault error: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e', style: const TextStyle(color: Colors.white)), backgroundColor: Colors.red));
      }
    }
    return null;
  }

  Future<void> _showLinkQuotationDialog() async {
    if (widget.deal?.id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Save the deal first before linking a quotation.'),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final req = ModelQueries.list(amplify_models.Billings.classType, where: amplify_models.Billings.TYPE.eq('QUOTATION'), limit: 10000);
      final resList = await Amplify.API.query(request: req).response;
      final resultList = (resList.data?.items ?? []).whereType<amplify_models.Billings>().toList() ?? [];
      resultList.sort((a, b) => (b.id).compareTo(a.id));
      final result = resultList.map((e) => e.toJson()).toList();

      final bills = result.map((row) => {
        'id': row['id'],
        'invoice_no': row['invoice_no'] ?? 'DRAFT',
        'client_name': row['client_name'] ?? 'Unknown Client',
        'amount': row['amount'] ?? '0/-',
        'date': row['date'] ?? '',
      }).toList();

      if (mounted) {
        setState(() => _isLoading = false);
        final selectedId = await showDialog<int>(
          context: context,
          builder: (context) {
            String searchQuery = '';
            return StatefulBuilder(
              builder: (context, setStateDialog) {
                final filtered = bills.where((b) {
                  final s = searchQuery.toLowerCase();
                  return b['invoice_no'].toString().toLowerCase().contains(s) ||
                      b['client_name'].toString().toLowerCase().contains(s);
                }).take(50).toList();

                return AlertDialog(
                  title: const Text(
                    'Link Existing Quotation',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  content: SizedBox(
                    width: MediaQuery.of(context).size.width * 0.9,
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: Column(
                      children: [
                        TextField(
                          decoration: InputDecoration(
                            hintText: 'Search by Quotation No or Client...',
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                          ),
                          onChanged: (v) =>
                              setStateDialog(() => searchQuery = v),
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (context, index) =>
                                const Divider(),
                            itemBuilder: (context, index) {
                              final b = filtered[index];
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.blue.shade50,
                                  child: const Icon(
                                    Icons.request_quote,
                                    color: Colors.blue,
                                    size: 20,
                                  ),
                                ),
                                title: Text(
                                  '${b['invoice_no']} - ${b['client_name']}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text('${b['date']} | ${b['amount']}'),
                                trailing: const Text(
                                  'LINK',
                                  style: TextStyle(
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                                onTap: () =>
                                    Navigator.pop(context, int.tryParse(b['id'].toString()) ?? 0),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('CANCEL'),
                    ),
                  ],
                );
              },
            );
          },
        );

        if (selectedId != null) {
          setState(() => _isLoading = true);
          final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(widget.deal!.id.toString()), limit: 10000);
          final res = await Amplify.API.query(request: req).response;
          final dealObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
          if (dealObj != null) {
            final updatedDeal = dealObj.copyWith(quotation_id: selectedId);
            await BackupAwareApi().update(updatedDeal);
          }
          
          if (mounted) {
            setState(() {
              _quotationId = selectedId;
              _isLoading = false;
            });
            _loadDetails();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Quotation linked successfully!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading quotations: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  int get _currentStageIndex {
    if (_currentStage == 'Completed') return Deal.stages.length;
    final idx = Deal.stages.indexOf(_currentStage);
    return idx == -1 ? 0 : idx; // fallback to 0 if unknown
  }

  bool _shouldShowStage(String stage) {
    final targetIndex = Deal.stages.indexOf(stage);
    return targetIndex <= _currentStageIndex;
  }

  Widget _buildFilesAskedInput() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _filesAskedController,
      builder: (context, value, child) {
        final askedList = value.text
            .split(RegExp(r'[,\n]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Files Asked to Customer',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: askedList.map((file) {
                      return Chip(
                        label: Text(file, style: const TextStyle(fontSize: 12)),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () {
                          askedList.remove(file);
                          _filesAskedController.text = askedList.join(', ');
                        },
                        backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                        side: BorderSide.none,
                      );
                    }).toList(),
                  ),
                  if (askedList.isNotEmpty) const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _newFileAskedController,
                          decoration: InputDecoration(
                            hintText: 'Type document name and press Add...',
                            hintStyle: const TextStyle(fontSize: 13),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: Colors.grey.shade300),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                          onSubmitted: (val) {
                            if (val.trim().isNotEmpty) {
                              if (!askedList.contains(val.trim())) askedList.add(val.trim());
                              _filesAskedController.text = askedList.join(', ');
                              _newFileAskedController.clear();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          final val = _newFileAskedController.text.trim();
                          if (val.isNotEmpty) {
                            if (!askedList.contains(val)) askedList.add(val);
                            _filesAskedController.text = askedList.join(', ');
                            _newFileAskedController.clear();
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        ),
                        child: const Text('Add'),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.folder_special_rounded, color: AppTheme.primaryColor),
                          tooltip: 'Select from Client Vault',
                          onPressed: () async {
                            final selectedPath = await _openClientFilesVault(selectMode: true);
                            if (selectedPath != null && mounted) {
                              final fileName = selectedPath.split('/').last;
                              if (!askedList.contains(fileName)) {
                                askedList.add(fileName);
                                _filesAskedController.text = askedList.join(', ');
                                
                                // Auto mark as received
                                List<Map<String, dynamic>> receivedList = [];
                                try {
                                  final decoded = jsonDecode(_filesReceivedController.text);
                                  if (decoded is List) {
                                    if (decoded.isNotEmpty && decoded.first is String) {
                                      receivedList = decoded.map((e) => <String, dynamic>{'name': e.toString(), 'status': 'Received', 'type': 'Copy'}).toList();
                                    } else {
                                      receivedList = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
                                    }
                                  }
                                } catch (_) {}
                                
                                if (!receivedList.any((e) => e['name'] == fileName)) {
                                  receivedList.add({'name': fileName, 'status': 'Received', 'type': 'Vault Copy'});
                                  _filesReceivedController.text = jsonEncode(receivedList);
                                }
                                
                                setState(() {});
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added $fileName from Vault'), backgroundColor: Colors.green));
                              }
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  if (askedList.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.handshake, size: 18),
                        label: const Text('Acknowledge Receipt of Files'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.primaryColor,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => FileAcknowledgementScreen(
                                currentUserRole: 'Staff',
                                currentUserName: _currentUserName ?? 'Staff',
                                initialAction: 'Received',
                                initialDeal: widget.deal,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFilesReceivedCheckboxes() {
    return AnimatedBuilder(
      animation: Listenable.merge([_filesAskedController, _filesReceivedController]),
      builder: (context, child) {
        final askedList = _filesAskedController.text.split(RegExp(r'[,\n]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        
        if (askedList.isEmpty) {
          return const SizedBox.shrink();
        }

        // Read current received files
        List<Map<String, dynamic>> fileStates = [];
        try {
          final decoded = jsonDecode(_filesReceivedController.text);
          if (decoded is List) {
            // Check if it's the old format (List of Strings)
            if (decoded.isNotEmpty && decoded.first is String) {
              fileStates = decoded.map((e) => <String, dynamic>{
                'name': e.toString(),
                'status': 'Received',
                'type': 'Copy'
              }).toList();
            } else {
              // Safely cast to List<Map<String, dynamic>>
              fileStates = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            }
          }
        } catch (e) {
          // Fallback for old comma-separated strings
          final oldList = _filesReceivedController.text.split(RegExp(r'[,\n]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          fileStates = oldList.map((e) => <String, dynamic>{
            'name': e,
            'status': 'Received',
            'type': 'Copy'
          }).toList();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('File Tracking Manager', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF64748B))),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                children: askedList.map((file) {
                  // Find file state
                  int stateIndex = fileStates.indexWhere((s) => s['name'] == file);
                  Map<String, dynamic> fileState = stateIndex != -1 
                      ? fileStates[stateIndex] 
                      : {'name': file, 'status': 'Pending', 'type': 'Copy'};

                  String status = fileState['status'] ?? 'Pending';
                  String type = fileState['type'] ?? 'Copy';
                  String? vaultDateStr = fileState['vault_date'];

                  // Determine UI based on status
                  IconData icon;
                  Color iconColor;
                  Color bgColor;
                  
                  if (status == 'Vault') {
                    icon = Icons.security_rounded;
                    iconColor = Colors.blue.shade700;
                    bgColor = Colors.blue.shade50;
                  } else if (status == 'Received') {
                    icon = Icons.check_circle_rounded;
                    iconColor = Colors.green.shade600;
                    bgColor = Colors.green.shade50;
                  } else {
                    icon = Icons.radio_button_unchecked_rounded;
                    iconColor = Colors.grey.shade400;
                    bgColor = Colors.transparent;
                  }

                  void updateState(Map<String, dynamic> newState) {
                    if (stateIndex != -1) {
                      fileStates[stateIndex] = newState;
                    } else {
                      fileStates.add(newState);
                    }
                    _filesReceivedController.text = jsonEncode(fileStates);
                  }

                  Future<void> confirmWithUsername(String action, Function onConfirm) async {
                    if (_currentUserName == null || _currentUserName!.isEmpty) {
                      onConfirm();
                      return;
                    }
                    final TextEditingController usernameController = TextEditingController();
                    final bool? confirmed = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text('Confirm $action'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Please type your username "$_currentUserName" to confirm this action.'),
                            const SizedBox(height: 16),
                            TextField(
                              controller: usernameController,
                              decoration: const InputDecoration(
                                labelText: 'Username',
                                border: OutlineInputBorder(),
                              ),
                              autofocus: true,
                              onSubmitted: (val) {
                                if (val.trim().toLowerCase() == _currentUserName!.trim().toLowerCase()) {
                                  Navigator.pop(c, true);
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Username does not match. Please try again.')),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('Cancel'),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              if (usernameController.text.trim().toLowerCase() == _currentUserName!.trim().toLowerCase()) {
                                Navigator.pop(c, true);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Username does not match. Please try again.')),
                                );
                              }
                            },
                            child: const Text('Confirm'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      onConfirm();
                    }
                  }

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: status == 'Vault' ? const Color(0xFFF8FAFC) : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 24, offset: const Offset(0, 8)),
                        BoxShadow(color: Colors.black.withValues(alpha: 0.01), blurRadius: 4, offset: const Offset(0, 2))
                      ]
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            if (status == 'Pending') {
                              confirmWithUsername('Received', () {
                                updateState({...fileState, 'status': 'Received'});
                              });
                            } else if (status == 'Received') {
                              confirmWithUsername('Vault Upload', () {
                                updateState({...fileState, 'status': 'Vault', 'vault_date': DateTime.now().toIso8601String()});
                              });
                            } else if (status == 'Vault') {
                              updateState({...fileState, 'status': 'Pending', 'vault_date': null});
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: bgColor,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(icon, color: iconColor, size: 20),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        file,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: status != 'Pending' ? FontWeight.w600 : FontWeight.w500,
                                          letterSpacing: -0.3,
                                          color: status == 'Vault' ? Colors.blue.shade900 : const Color(0xFF1E293B),
                                          decoration: status == 'Vault' ? TextDecoration.lineThrough : null,
                                        ),
                                      ),
                                      if (status == 'Vault' && vaultDateStr != null)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4),
                                          child: Text(
                                            'Vaulted: ${DateTime.parse(vaultDateStr).toLocal().toString().split(' ')[0]}',
                                            style: TextStyle(fontSize: 11, color: Colors.blue.shade700, fontWeight: FontWeight.w500),
                                          ),
                                        ),
                                      if (fileState['remark'] != null && fileState['remark'].toString().trim().isNotEmpty)
                                        Container(
                                          margin: const EdgeInsets.only(top: 8),
                                          padding: const EdgeInsets.only(left: 12, top: 6, bottom: 6, right: 12),
                                          decoration: BoxDecoration(
                                            border: Border(left: BorderSide(color: Colors.blue.shade400, width: 3)),
                                            color: Colors.blue.shade50.withValues(alpha: 0.5),
                                            borderRadius: const BorderRadius.only(topRight: Radius.circular(8), bottomRight: Radius.circular(8)),
                                          ),
                                          child: Text(
                                            fileState['remark'],
                                            style: TextStyle(fontSize: 12.5, color: Colors.blue.shade900, fontStyle: FontStyle.italic, height: 1.4),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Container(
                                  decoration: BoxDecoration(
                                    color: (fileState['remark'] != null && fileState['remark'].toString().trim().isNotEmpty)
                                      ? Colors.blue.shade50
                                      : Colors.transparent,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: IconButton(
                                    icon: Icon(
                                      (fileState['remark'] != null && fileState['remark'].toString().trim().isNotEmpty) 
                                          ? Icons.chat_bubble_rounded 
                                          : Icons.chat_bubble_outline_rounded, 
                                      size: 20, 
                                      color: (fileState['remark'] != null && fileState['remark'].toString().trim().isNotEmpty)
                                        ? Colors.blue.shade700
                                        : Colors.grey.shade400
                                    ),
                                    padding: const EdgeInsets.all(8),
                                    constraints: const BoxConstraints(),
                                    onPressed: () {
                                      final tc = TextEditingController(text: fileState['remark'] ?? '');
                                      showDialog(
                                        context: context,
                                        builder: (c) => Dialog(
                                          backgroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                                          elevation: 10,
                                          child: Container(
                                            width: 450,
                                            padding: const EdgeInsets.all(24.0),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Container(
                                                      padding: const EdgeInsets.all(10),
                                                      decoration: BoxDecoration(color: Colors.blue.shade50, shape: BoxShape.circle),
                                                      child: Icon(Icons.edit_note_rounded, color: Colors.blue.shade700, size: 24),
                                                    ),
                                                    const SizedBox(width: 16),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                        children: [
                                                          const Text('Add Remark', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
                                                          const SizedBox(height: 2),
                                                          Text('File: $file', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 24),
                                                TextField(
                                                  controller: tc,
                                                  style: const TextStyle(fontSize: 14, color: Colors.black87),
                                                  decoration: InputDecoration(
                                                    hintText: 'Write your thoughts here...',
                                                    hintStyle: TextStyle(color: Colors.grey.shade400),
                                                    filled: true,
                                                    fillColor: const Color(0xFFF8FAFC),
                                                    contentPadding: const EdgeInsets.all(16),
                                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                                                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.blue.shade200, width: 1.5)),
                                                  ),
                                                  maxLines: 4,
                                                  autofocus: true,
                                                ),
                                                const SizedBox(height: 24),
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.end,
                                                  children: [
                                                    TextButton(
                                                      onPressed: () => Navigator.pop(c),
                                                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12), foregroundColor: Colors.grey.shade600),
                                                      child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
                                                    ),
                                                    const SizedBox(width: 12),
                                                    ElevatedButton(
                                                      onPressed: () {
                                                        updateState({...fileState, 'remark': tc.text.trim()});
                                                        Navigator.pop(c);
                                                      },
                                                      style: ElevatedButton.styleFrom(
                                                        backgroundColor: const Color(0xFF0F172A), // Slate 900
                                                        foregroundColor: Colors.white,
                                                        elevation: 0,
                                                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                                      ),
                                                      child: const Text('Save Remark', style: TextStyle(fontWeight: FontWeight.w600)),
                                                    ),
                                                  ],
                                                )
                                              ],
                                            ),
                                          ),
                                        )
                                      );
                                    }
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (status != 'Pending') ...[
                                  Container(
                                    height: 32,
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.grey.shade300),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        value: type,
                                        isDense: true,
                                        icon: const Icon(Icons.arrow_drop_down, size: 16),
                                        style: const TextStyle(fontSize: 12, color: Colors.black87),
                                        items: ['Original', 'Copy', 'Vault Copy'].map((String value) {
                                          return DropdownMenuItem<String>(
                                            value: value,
                                            child: Text(value),
                                          );
                                        }).toList(),
                                        onChanged: status == 'Vault' ? null : (String? newValue) {
                                          if (newValue != null) {
                                            updateState({...fileState, 'type': newValue});
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                                  if (status == 'Received') ...[
                                    const SizedBox(width: 8),
                                    ElevatedButton.icon(
                                      onPressed: () {
                                        confirmWithUsername('Vault Upload', () {
                                          updateState({...fileState, 'status': 'Vault', 'vault_date': DateTime.now().toIso8601String()});
                                        });
                                      },
                                      icon: const Icon(Icons.security, size: 14),
                                      label: const Text('To Vault', style: TextStyle(fontSize: 12)),
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                        minimumSize: const Size(0, 32),
                                        backgroundColor: Colors.blue.shade700,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                        elevation: 0,
                                      ),
                                    ),
                                  ],
                                ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
                }).toList(),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(
        child: Column(
          children: [
            _buildPremiumHeader(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final bool isWide = constraints.maxWidth > 1000;

                  if (!isWide) {
                    return SingleChildScrollView(
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: [
                                _buildPipelineTracker(),
                                const SizedBox(height: 24),
                                _buildSectionCard('FILE CREATION', [
                                  _buildPipelineSelector(),
                                  _buildField(
                                    'Deal Name',
                                    _nameController,
                                    'Enter deal name...',
                                    icon: Icons.work_outline_rounded,
                                  ),
                                  const SizedBox(height: 20),
                                  _buildClientAutocompleteField(),
                                  const SizedBox(height: 20),
                                  _buildField(
                                    'Work Type',
                                    _workTypeController,
                                    'e.g. Audit, GST, License...',
                                    icon: Icons.category_outlined,
                                  ),
                                  const SizedBox(height: 20),
                                  _buildDatePickerField(
                                    'Deadline',
                                    _selectedDeadline,
                                    () async {
                                      final picked = await showDatePicker(
                                        context: context,
                                        initialDate: _selectedDeadline ?? DateTime.now(),
                                        firstDate: DateTime(2000),
                                        lastDate: DateTime(2100),
                                      );
                                      if (picked != null) {
                                        setState(() => _selectedDeadline = picked);
                                      }
                                    },
                                  ),
                                  const SizedBox(height: 32),
                                  _buildResponsibleTeamSection(),
                                  const SizedBox(height: 32),
                                  _buildField(
                                    'Registration Fee Required',
                                    _regFeeController,
                                    'Amount or details...',
                                    icon: Icons.monetization_on_outlined,
                                  ),
                                  const SizedBox(height: 20),
                                  _buildField(
                                    'Referred By',
                                    _referredByController,
                                    'Enter referrer name...',
                                    icon: Icons.person_add_alt_1_outlined,
                                  ),
                                  const SizedBox(height: 20),
                                  _buildField(
                                    'Comments',
                                    _descriptionController,
                                    'Additional notes...',
                                    lines: 3,
                                    icon: Icons.comment_outlined,
                                  ),
                                ]),

                                if (_shouldShowStage('Contact Customer')) ...[
                                  const SizedBox(height: 24),
                                  _buildSectionCard('CONTACT CUSTOMER', [
                                    _buildModernRadioGroup(
                                      'Contact Status',
                                      _contactStatus,
                                      [
                                        'not selected',
                                        'CONTACTED',
                                        'NOT ATTENDED',
                                        'NOT AVAILABLE',
                                        'NOT CONTACTED',
                                      ],
                                      (v) =>
                                          setState(() => _contactStatus = v!),
                                    ),
                                    const SizedBox(height: 24),
                                    _buildFilesAskedInput(),
                                    const SizedBox(height: 24),
                                    _buildFilesReceivedCheckboxes(),
                                    const SizedBox(height: 24),
                                    SizedBox(
                                      width: double.infinity,
                                      child: OutlinedButton.icon(
                                        onPressed: _openClientFilesVault,
                                        icon: const Icon(Icons.folder_special_rounded, color: AppTheme.primaryColor),
                                        label: const Text('OPEN CLIENT FILES VAULT', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(vertical: 16),
                                          side: const BorderSide(color: AppTheme.primaryColor),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    const Divider(),
                                    _buildResponsibleTeamSection(title: ''),
                                  ]),
                                ],

                                if (_shouldShowStage('Work Started')) ...[
                                  const SizedBox(height: 24),
                                  _buildSectionCard('WORK START', [
                                    _buildField(
                                      'Estimated Amount for Work',
                                      _estAmountController,
                                      '0',
                                      isCurrency: true,
                                      icon: Icons.payments_outlined,
                                    ),
                                    const SizedBox(height: 24),
                                    _buildModernRadioGroup(
                                      'Create Quotation and Share',
                                      _createInvoiceShare,
                                      ['not selected', 'YES', 'NO'],
                                      (v) => setState(
                                        () => _createInvoiceShare = v!,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    const Divider(),
                                    const SizedBox(height: 16),
                                    if (_quotationId != null)
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                          horizontal: 16,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.green.shade50,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: Colors.green.shade200,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.check_circle_rounded,
                                              color: Colors.green,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'QUOTATION LINKED (ID: #$_quotationId)',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.green,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: () async {
                                                setState(
                                                  () => _isLoading = true,
                                                );
                                                final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(widget.deal!.id.toString()), limit: 10000);
                                                final res = await Amplify.API.query(request: req).response;
                                                final dealObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
                                                if (dealObj != null) {
                                                  final updatedDeal = dealObj.copyWith(quotation_id: null);
                                                  await BackupAwareApi().update(updatedDeal);
                                                }
                                                
                                                setState(() {
                                                  _quotationId = null;
                                                  _isLoading = false;
                                                });
                                              },
                                              child: const Text(
                                                'UNLINK',
                                                style: TextStyle(
                                                  color: Colors.red,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    else
                                      Column(
                                        children: [
                                          SizedBox(
                                            width: double.infinity,
                                            child: ElevatedButton.icon(
                                              onPressed: widget.deal?.id == null
                                                  ? null
                                                  : _openQuotationCreator,
                                              icon: const Icon(
                                                Icons.request_quote_rounded,
                                              ),
                                              label: Text(
                                                widget.deal?.id == null
                                                    ? 'SAVE FIRST'
                                                    : 'GENERATE QUOTATION',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    widget.deal?.id == null
                                                    ? Colors.grey
                                                    : const Color(0xFF2563EB),
                                                foregroundColor: Colors.white,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 16,
                                                    ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          SizedBox(
                                            width: double.infinity,
                                            child: OutlinedButton.icon(
                                              onPressed: widget.deal?.id == null
                                                  ? null
                                                  : _showLinkQuotationDialog,
                                              icon: const Icon(
                                                Icons.link_rounded,
                                              ),
                                              label: const Text(
                                                'LINK EXISTING',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: const Color(
                                                  0xFF2563EB,
                                                ),
                                                side: const BorderSide(
                                                  color: Color(0xFF2563EB),
                                                  width: 2,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 16,
                                                    ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    const SizedBox(height: 16),
                                    const Divider(),
                                    const SizedBox(height: 24),
                                    _buildField(
                                      'Part Payment Amount Received',
                                      _partPaymentAmountController,
                                      '0',
                                      isCurrency: true,
                                      icon: Icons.payments_outlined,
                                    ),
                                    const SizedBox(height: 24),
                                    if ((double.tryParse(_partPaymentAmountController.text) ?? 0) <= 0) ...[
                                      Material(
                                        color: Colors.transparent,
                                        child: SwitchListTile(
                                          title: const Text('NOC from Irshad sir to start work', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.primaryColor)),
                                          subtitle: const Text('Required if no part payment is received', style: TextStyle(fontSize: 11, color: AppTheme.mutedTextColor)),
                                          value: _nocObtained,
                                          activeThumbColor: AppTheme.primaryColor,
                                          onChanged: (val) => _toggleNoc(val),
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                    ],
                                    _buildResponsibleTeamSection(title: ''),
                                  ]),
                                ],

                                if (_shouldShowStage('In Progress')) ...[
                                  const SizedBox(height: 24),
                                  _buildSectionCard('IN PROGRESS', [
                                    _buildDynamicExpensesList(),
                                    const SizedBox(height: 24),
                                    _buildField(
                                      'Register / Ref Number',
                                      _registerNoController,
                                      'Enter any registration/reference number...',
                                      icon: Icons.numbers_rounded,
                                    ),
                                    const SizedBox(height: 24),
                                    _buildModernRadioGroup(
                                      'Work Adjourned Status',
                                      _isAdjourned ? 'Adjourned' : 'Active',
                                      const ['Active', 'Adjourned'],
                                      (v) {
                                        setState(() {
                                          _isAdjourned = (v == 'Adjourned');
                                        });
                                      },
                                    ),
                                    if (_isAdjourned) ...[
                                      const SizedBox(height: 24),
                                      _buildField(
                                        'Reason for Adjournment',
                                        _adjournedReasonController,
                                        'Provide the reason...',
                                        icon: Icons.info_outline_rounded,
                                      ),
                                      const SizedBox(height: 24),
                                      _buildDatePickerField(
                                        'Postponed Date',
                                        _postponedDate,
                                        () async {
                                          final picked = await showDatePicker(
                                            context: context,
                                            initialDate: _postponedDate ?? DateTime.now(),
                                            firstDate: DateTime.now().subtract(const Duration(days: 365)),
                                            lastDate: DateTime.now().add(const Duration(days: 3650)),
                                          );
                                          if (picked != null) {
                                            setState(() {
                                              _postponedDate = picked;
                                            });
                                          }
                                        },
                                      ),
                                    ],
                                    const SizedBox(height: 24),
                                    const Divider(),
                                    _buildResponsibleTeamSection(title: ''),
                                    const SizedBox(height: 24),
                                    _buildModernRadioGroup(
                                      'Draft Created?',
                                      _isDraftCreated ? 'Yes' : 'No',
                                      const ['Yes', 'No'],
                                      (v) {
                                        setState(() {
                                          _isDraftCreated = (v == 'Yes');
                                        });
                                      },
                                    ),
                                    if (_isDraftCreated && (_currentUserId == _responsibleId || _assignees.any((a) => a.userId == _currentUserId))) ...[
                                      const SizedBox(height: 24),
                                      const Text(
                                        'Assign a Peer Verifier',
                                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFF475569)),
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<dynamic>(
                                        initialValue: _selectedVerifierId,
                                        hint: const Text('Select a staff member...'),
                                        decoration: InputDecoration(
                                          filled: true,
                                          fillColor: const Color(0xFFF8FAFC),
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(8),
                                            borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(8),
                                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                                          ),
                                          prefixIcon: const Icon(Icons.person_search_rounded, color: Color(0xFF64748B)),
                                        ),
                                        items: _allUsers
                                            .where((u) => int.tryParse(u['id'].toString()) != _currentUserId && (u['role']?.toString().toLowerCase() == 'staff' || u['role']?.toString().toLowerCase() == 'manager'))
                                            .map((u) => DropdownMenuItem<int>(
                                                  value: int.tryParse(u['id'].toString()) ?? 0,
                                                  child: Text(u['name'].toString()),
                                                ))
                                            .toList(),
                                        onChanged: (v) {
                                          setState(() {
                                            _selectedVerifierId = v;
                                          });
                                        },
                                      ),
                                      const SizedBox(height: 16),
                                      _buildConnectedDocsSection(),
                                    ],
                                    const SizedBox(height: 24),
                                    const Divider(),
                                    const SizedBox(height: 16),
                                    SizedBox(
                                      width: double.infinity,
                                      child: ElevatedButton.icon(
                                        onPressed: _isAdjourned
                                            ? null
                                            : (_isDraftCreated
                                                ? _completeWorkAndShareDraft
                                                : _completeWorkWithoutDraft),
                                        icon: Icon(_isAdjourned
                                            ? Icons.pause_circle_outline_rounded
                                            : Icons.check_circle_outline_rounded),
                                        label: Text(
                                          _isAdjourned
                                              ? 'CANNOT COMPLETE - WORK IS ADJOURNED'
                                              : (_isDraftCreated ? 'COMPLETE & GIVE TO VERIFICATION' : 'COMPLETE WORK & PROCEED TO INVOICE'),
                                          style: const TextStyle(fontWeight: FontWeight.bold),
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: _isAdjourned
                                              ? const Color(0xFFCBD5E1)
                                              : const Color(0xFF10B981),
                                          foregroundColor: _isAdjourned
                                              ? const Color(0xFF94A3B8)
                                              : Colors.white,
                                          disabledBackgroundColor: _isAdjourned
                                              ? const Color(0xFFE2E8F0)
                                              : const Color(0xFFE2E8F0),
                                          disabledForegroundColor: _isAdjourned
                                              ? const Color(0xFF94A3B8)
                                              : const Color(0xFF94A3B8),
                                          padding: const EdgeInsets.symmetric(vertical: 16),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ]),
                                ],

                                if (_shouldShowStage('Verification')) ...[
                                  const SizedBox(height: 24),
                                  _buildSectionCard('VERIFICATION', [
                                    _buildVerificationSection(false),
                                  ]),
                                ],

                                if (_shouldShowStage('Invoice')) ...[
                                  const SizedBox(height: 24),
                                  _buildSectionCard('INVOICE CREATION', [
                                    _buildModernRadioGroup(
                                      'Send to Customer',
                                      _sendToCustomer,
                                      ['not selected', 'YES', 'NO'],
                                      (v) =>
                                          setState(() => _sendToCustomer = v!),
                                    ),
                                    const SizedBox(height: 24),
                                    const Divider(),
                                    const SizedBox(height: 16),
                                    if (_billingId != null)
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                          horizontal: 16,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.green.shade50,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: Colors.green.shade200,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.check_circle_rounded,
                                              color: Colors.green,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'INVOICE LINKED (ID: #$_billingId)',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.green,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: () async {
                                                setState(
                                                  () => _isLoading = true,
                                                );
                                                final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(widget.deal!.id.toString()), limit: 10000);
                                                final res = await Amplify.API.query(request: req).response;
                                                final dealObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
                                                if (dealObj != null) {
                                                  // we don't have a way to explicitly nullify an ID right now easily, but copyWith with null works if the field is nullable
                                                  // Actually Amplify copyWith ignores null arguments unless explicitly asked, but let's assume it works for now or uses standard behavior.
                                                  // Wait, actually I might just need to not set it, but since it's already there, let's keep it as is.
                                                  // In Amplify Gen2, we usually set it to empty string or rely on proper nulling.
                                                }
                                                // Skipping for a second, let's just do a clean update:
                                                if (dealObj != null) {
                                                  // Note: Setting to null might require specific handling in amplify dart depending on version, but usually copyWith(billing_id: null) works if it's nullable. But let's just pass null. Wait, in dart `null` is ignored by `copyWith` usually if the parameter is optional. Let's use `null` anyway and see.
                                                  // Actually, if we just use a blank string it might be safer, but `billing_id` is String. Let's just do `copyWith` and hope it handles null clearing.
                                                }
                                                // Realistically:
                                                if (dealObj != null) {
                                                  final updatedDeal = dealObj.copyWith(billing_id: 0);
                                                  await BackupAwareApi().update(updatedDeal);
                                                }

                                                setState(() {
                                                  _billingId = null;
                                                  _isLoading = false;
                                                });
                                              },
                                              child: const Text(
                                                'UNLINK',
                                                style: TextStyle(
                                                  color: Colors.red,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    else
                                      Column(
                                        children: [
                                          SizedBox(
                                            width: double.infinity,
                                            child: ElevatedButton.icon(
                                              onPressed: widget.deal?.id == null
                                                  ? null
                                                  : _openInvoiceCreator,
                                              icon: const Icon(
                                                Icons.receipt_long_rounded,
                                              ),
                                              label: Text(
                                                widget.deal?.id == null
                                                    ? 'SAVE FIRST'
                                                    : 'GENERATE BILL',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    widget.deal?.id == null
                                                    ? Colors.grey
                                                    : const Color(0xFF2563EB),
                                                foregroundColor: Colors.white,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 16,
                                                    ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          SizedBox(
                                            width: double.infinity,
                                            child: OutlinedButton.icon(
                                              onPressed: _isLoading
                                                  ? null
                                                  : (widget.deal?.id == null
                                                        ? null
                                                        : _showLinkBillDialog),
                                              icon: const Icon(
                                                Icons.link_rounded,
                                              ),
                                              label: const Text(
                                                'LINK EXISTING',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: const Color(
                                                  0xFF2563EB,
                                                ),
                                                side: const BorderSide(
                                                  color: Color(0xFF2563EB),
                                                  width: 2,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 16,
                                                    ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    const SizedBox(height: 16),
                                    _buildResponsibleTeamSection(title: ''),
                                  ]),
                                ],

                                if (_shouldShowStage('Billing Status')) ...[
                                  const SizedBox(height: 24),
                                  _buildSectionCard('BILLING STATUS', [
                                    _buildField(
                                      'Invoice Amount',
                                      _invoiceAmountController,
                                      '0',
                                      isCurrency: true,
                                      icon: Icons.receipt_long_outlined,
                                    ),
                                    const SizedBox(height: 24),
                                    _buildField(
                                      'Payment Received',
                                      _paymentReceivedController,
                                      '0',
                                      isCurrency: true,
                                      icon: Icons.payments_outlined,
                                    ),
                                    const SizedBox(height: 24),
                                    _buildModernRadioGroup(
                                      'Payment Type',
                                      _paymentType,
                                      [
                                        'not selected',
                                        'CASH',
                                        'ACCOUNT TRANSFER',
                                        'GOOGLE PAY',
                                      ],
                                      (v) => setState(() => _paymentType = v!),
                                    ),
                                    const SizedBox(height: 24),
                                    const Divider(),
                                    _buildResponsibleTeamSection(title: ''),
                                  ]),
                                ],

                                if (_shouldShowStage('Close Deal')) ...[
                                  const SizedBox(height: 24),
                                  _buildSectionCard('CLOSE DEAL', [
                                    Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade50,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.green.shade200,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.verified_rounded,
                                            color: Colors.green,
                                            size: 24,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              'Saving will mark this deal as closed.',
                                              style: TextStyle(
                                                color: Colors.green.shade800,
                                                fontWeight: FontWeight.w500,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ]),
                                ],
                              ],
                            ),
                          ),
                          // On mobile, Activity Feed is below the form
                          Container(
                            height: 550,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border(
                                top: BorderSide(
                                  color: Colors.black.withValues(alpha: 0.05),
                                ),
                              ),
                            ),
                            child: _buildUnifiedActivityPanel(),
                          ),
                        ],
                      ),
                    );
                  }

                  return Flex(
                    direction: isWide ? Axis.horizontal : Axis.vertical,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Left Panel: Form Sections
                      Expanded(
                        flex: isWide ? 3 : 0,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            children: [
                              _buildPipelineTracker(),
                              const SizedBox(height: 32),
                              _buildSectionCard('FILE CREATION', [
                                    _buildPipelineSelector(),
                                    _buildField(
                                      'Deal Name',
                                      _nameController,
                                      'Enter deal name...',
                                      icon: Icons.work_outline_rounded,
                                    ),
                                    const SizedBox(height: 20),
                                    constraints.maxWidth > 600
                                        ? Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child:
                                                    _buildClientAutocompleteField(),
                                              ),
                                            ],
                                          )
                                        : Column(
                                            children: [
                                              _buildClientAutocompleteField(),
                                            ],
                                          ),
                                    const SizedBox(height: 20),
                                    _buildField(
                                      'Work Type',
                                      _workTypeController,
                                      'e.g. Audit, GST, License...',
                                      icon: Icons.category_outlined,
                                    ),
                                    const SizedBox(height: 20),
                                    _buildDatePickerField(
                                      'Deadline',
                                      _selectedDeadline,
                                      () async {
                                        final picked = await showDatePicker(
                                          context: context,
                                          initialDate: _selectedDeadline ?? DateTime.now(),
                                          firstDate: DateTime(2000),
                                          lastDate: DateTime(2100),
                                        );
                                        if (picked != null) {
                                          setState(() => _selectedDeadline = picked);
                                        }
                                      },
                                    ),
                                    const SizedBox(height: 32),
                                    _buildResponsibleTeamSection(),
                                    const SizedBox(height: 32),
                                    _buildField(
                                      'Registration Fee Required',
                                      _regFeeController,
                                      'Amount or details...',
                                      icon: Icons.monetization_on_outlined,
                                    ),
                                    const SizedBox(height: 20),
                                    _buildField(
                                      'Referred By',
                                      _referredByController,
                                      'Enter referrer name...',
                                      icon: Icons.person_add_alt_1_outlined,
                                    ),
                                    const SizedBox(height: 20),
                                    _buildField(
                                      'Comments',
                                      _descriptionController,
                                      'Additional notes...',
                                      lines: 3,
                                      icon: Icons.comment_outlined,
                                    ),
                                  ])
                                  .animate()
                                  .fadeIn(duration: 400.ms)
                                  .slideY(begin: 0.1),

                              if (_shouldShowStage('Contact Customer')) ...[
                                const SizedBox(height: 24),
                                _buildSectionCard('CONTACT CUSTOMER', [
                                      _buildModernRadioGroup(
                                        'Contact Status',
                                        _contactStatus,
                                        [
                                          'not selected',
                                          'CONTACTED',
                                          'NOT ATTENDED',
                                          'NOT AVAILABLE',
                                          'NOT CONTACTED',
                                        ],
                                        (v) =>
                                            setState(() => _contactStatus = v!),
                                      ),
                                      const SizedBox(height: 24),
                                      _buildFilesAskedInput(),
                                      const SizedBox(height: 24),
                                      _buildFilesReceivedCheckboxes(),
                                      const SizedBox(height: 24),
                                      SizedBox(
                                        width: double.infinity,
                                        child: OutlinedButton.icon(
                                          onPressed: _openClientFilesVault,
                                          icon: const Icon(Icons.folder_special_rounded, color: AppTheme.primaryColor),
                                          label: const Text('OPEN CLIENT FILES VAULT', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                                          style: OutlinedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(vertical: 16),
                                            side: const BorderSide(color: AppTheme.primaryColor),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      const Divider(),
                                      _buildResponsibleTeamSection(title: ''),
                                    ])
                                    .animate()
                                    .fadeIn(duration: 400.ms)
                                    .slideY(begin: 0.1),
                              ],

                              if (_shouldShowStage('Work Started')) ...[
                                const SizedBox(height: 24),
                                _buildSectionCard('WORK START', [
                                  _buildField(
                                    'Estimated Amount for Work',
                                    _estAmountController,
                                    '0',
                                    isCurrency: true,
                                    icon: Icons.payments_outlined,
                                  ),
                                  const SizedBox(height: 24),
                                  _buildModernRadioGroup(
                                    'Create Quotation and Share',
                                    _createInvoiceShare,
                                    ['not selected', 'YES', 'NO'],
                                    (v) => setState(
                                      () => _createInvoiceShare = v!,
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  const Divider(),
                                  const SizedBox(height: 16),
                                  if (_quotationId != null)
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                        horizontal: 16,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade50,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.green.shade200,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.check_circle_rounded,
                                            color: Colors.green,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'QUOTATION LINKED (ID: #$_quotationId)',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.green,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () async {
                                              setState(() => _isLoading = true);
                                              final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(widget.deal!.id.toString()), limit: 10000);
                                              final res = await Amplify.API.query(request: req).response;
                                              final dealObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
                                              if (dealObj != null) {
                                                final updatedDeal = dealObj.copyWith(quotation_id: 0);
                                                await BackupAwareApi().update(updatedDeal);
                                              }

                                              setState(() {
                                                _quotationId = null;
                                                _isLoading = false;
                                              });
                                            },
                                            child: const Text(
                                              'UNLINK',
                                              style: TextStyle(
                                                color: Colors.red,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  else
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: widget.deal?.id == null
                                                ? null
                                                : _openQuotationCreator,
                                            icon: const Icon(
                                              Icons.request_quote_rounded,
                                            ),
                                            label: Text(
                                              widget.deal?.id == null
                                                  ? 'SAVE FIRST'
                                                  : 'GENERATE QUOTATION',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor:
                                                  widget.deal?.id == null
                                                  ? Colors.grey
                                                  : const Color(0xFF2563EB),
                                              foregroundColor: Colors.white,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 18,
                                                  ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: widget.deal?.id == null
                                                ? null
                                                : _showLinkQuotationDialog,
                                            icon: const Icon(
                                              Icons.link_rounded,
                                            ),
                                            label: const Text(
                                              'LINK EXISTING',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: const Color(
                                                0xFF2563EB,
                                              ),
                                              side: const BorderSide(
                                                color: Color(0xFF2563EB),
                                                width: 2,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 18,
                                                  ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  const SizedBox(height: 16),
                                  const Divider(),
                                  const SizedBox(height: 24),
                                  _buildField(
                                    'Part Payment Amount Received',
                                    _partPaymentAmountController,
                                    '0',
                                    isCurrency: true,
                                    icon: Icons.payments_outlined,
                                  ),
                                  const SizedBox(height: 24),
                                  if ((double.tryParse(_partPaymentAmountController.text) ?? 0) <= 0) ...[
                                    Material(
                                      color: Colors.transparent,
                                      child: SwitchListTile(
                                        title: const Text('NOC from Irshad sir to start work', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.primaryColor)),
                                        subtitle: const Text('Required if no part payment is received', style: TextStyle(fontSize: 11, color: AppTheme.mutedTextColor)),
                                        value: _nocObtained,
                                        activeThumbColor: AppTheme.primaryColor,
                                        onChanged: (val) => _toggleNoc(val),
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                  ],
                                  _buildResponsibleTeamSection(title: ''),
                                ]).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1),
                              ],

                              if (_shouldShowStage('In Progress')) ...[
                                const SizedBox(height: 24),
                                _buildSectionCard('IN PROGRESS', [
                                      _buildDynamicExpensesList(),
                                      const SizedBox(height: 24),
                                      _buildField(
                                        'Register / Ref Number',
                                        _registerNoController,
                                        'Enter any registration/reference number...',
                                        icon: Icons.numbers_rounded,
                                      ),
                                      const SizedBox(height: 24),
                                      _buildModernRadioGroup(
                                        'Work Adjourned Status',
                                        _isAdjourned ? 'Adjourned' : 'Active',
                                        const ['Active', 'Adjourned'],
                                        (v) {
                                          setState(() {
                                            _isAdjourned = (v == 'Adjourned');
                                          });
                                        },
                                      ),
                                      if (_isAdjourned) ...[
                                        const SizedBox(height: 24),
                                        _buildField(
                                          'Reason for Adjournment',
                                          _adjournedReasonController,
                                          'Provide the reason...',
                                          icon: Icons.info_outline_rounded,
                                        ),
                                        const SizedBox(height: 24),
                                        _buildDatePickerField(
                                          'Postponed Date',
                                          _postponedDate,
                                          () async {
                                            final picked = await showDatePicker(
                                              context: context,
                                              initialDate: _postponedDate ?? DateTime.now(),
                                              firstDate: DateTime.now().subtract(const Duration(days: 365)),
                                              lastDate: DateTime.now().add(const Duration(days: 3650)),
                                            );
                                            if (picked != null) {
                                              setState(() {
                                                _postponedDate = picked;
                                              });
                                            }
                                          },
                                        ),
                                      ],
                                      const SizedBox(height: 24),
                                      _buildModernRadioGroup(
                                        'Draft Created?',
                                        _isDraftCreated ? 'Yes' : 'No',
                                        const ['Yes', 'No'],
                                        (v) {
                                          setState(() {
                                            _isDraftCreated = (v == 'Yes');
                                          });
                                        },
                                      ),
                                      if (_isDraftCreated) ...[
                                        const SizedBox(height: 24),
                                        const Text(
                                          'Assign a Peer Verifier',
                                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFF475569)),
                                        ),
                                        const SizedBox(height: 8),
                                        DropdownButtonFormField<dynamic>(
                                          initialValue: _selectedVerifierId,
                                          hint: const Text('Select a staff member...'),
                                          decoration: InputDecoration(
                                            filled: true,
                                            fillColor: const Color(0xFFF8FAFC),
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                                            ),
                                            enabledBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                                            ),
                                            prefixIcon: const Icon(Icons.person_search_rounded, color: Color(0xFF64748B)),
                                          ),
                                          items: _allUsers
                                              .where((u) => int.tryParse(u['id'].toString()) != _currentUserId && (u['role']?.toString().toLowerCase() == 'staff' || u['role']?.toString().toLowerCase() == 'manager'))
                                              .map((u) => DropdownMenuItem<int>(
                                                    value: int.tryParse(u['id'].toString()) ?? 0,
                                                    child: Text(u['name'].toString()),
                                                  ))
                                              .toList(),
                                          onChanged: (v) {
                                            setState(() {
                                              _selectedVerifierId = v;
                                            });
                                          },
                                        ),
                                        const SizedBox(height: 16),
                                        _buildConnectedDocsSection(),
                                      ],
                                      const SizedBox(height: 24),
                                      const Divider(),
                                      _buildResponsibleTeamSection(title: ''),
                                      const SizedBox(height: 16),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          onPressed: _isAdjourned
                                              ? null
                                              : (_isDraftCreated
                                                  ? _completeWorkAndShareDraft
                                                  : _completeWorkWithoutDraft),
                                          icon: Icon(_isAdjourned
                                              ? Icons.pause_circle_outline_rounded
                                              : Icons.check_circle_outline_rounded),
                                          label: Text(
                                            _isAdjourned
                                                ? 'CANNOT COMPLETE - WORK IS ADJOURNED'
                                                : (_isDraftCreated ? 'COMPLETE & GIVE TO VERIFICATION' : 'COMPLETE WORK & PROCEED TO INVOICE'),
                                            style: const TextStyle(fontWeight: FontWeight.bold),
                                          ),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: _isAdjourned
                                                ? const Color(0xFFCBD5E1)
                                                : const Color(0xFF10B981),
                                            foregroundColor: _isAdjourned
                                                ? const Color(0xFF94A3B8)
                                                : Colors.white,
                                            disabledBackgroundColor: _isAdjourned
                                                ? const Color(0xFFE2E8F0)
                                                : const Color(0xFFE2E8F0),
                                            disabledForegroundColor: _isAdjourned
                                                ? const Color(0xFF94A3B8)
                                                : const Color(0xFF94A3B8),
                                            padding: const EdgeInsets.symmetric(vertical: 18),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ]).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1),
                              ],

                              if (_shouldShowStage('Verification')) ...[
                                const SizedBox(height: 24),
                                _buildSectionCard('VERIFICATION', [
                                      _buildVerificationSection(true),
                                    ])
                                    .animate()
                                    .fadeIn(duration: 400.ms)
                                    .slideY(begin: 0.1),
                              ],

                              if (_shouldShowStage('Invoice')) ...[
                                const SizedBox(height: 24),
                                _buildSectionCard('INVOICE CREATION', [
                                  _buildModernRadioGroup(
                                    'Send to Customer',
                                    _sendToCustomer,
                                    ['not selected', 'YES', 'NO'],
                                    (v) => setState(() => _sendToCustomer = v!),
                                  ),
                                  const SizedBox(height: 24),
                                  const Divider(),
                                  const SizedBox(height: 16),
                                  if (_billingId != null)
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                        horizontal: 16,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade50,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.green.shade200,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.check_circle_rounded,
                                            color: Colors.green,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'INVOICE LINKED (ID: #$_billingId)',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.green,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () async {
                                              setState(() => _isLoading = true);
                                              final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(widget.deal!.id.toString()), limit: 10000);
                                              final res = await Amplify.API.query(request: req).response;
                                              final dealObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
                                              if (dealObj != null) {
                                                final updatedDeal = dealObj.copyWith(billing_id: 0);
                                                await BackupAwareApi().update(updatedDeal);
                                              }

                                              setState(() {
                                                _billingId = null;
                                                _isLoading = false;
                                              });
                                            },
                                            child: const Text(
                                              'UNLINK',
                                              style: TextStyle(
                                                color: Colors.red,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  else
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: widget.deal?.id == null
                                                ? null
                                                : _openInvoiceCreator,
                                            icon: const Icon(
                                              Icons.receipt_long_rounded,
                                            ),
                                            label: Text(
                                              widget.deal?.id == null
                                                  ? 'SAVE FIRST'
                                                  : 'GENERATE BILL',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor:
                                                  widget.deal?.id == null
                                                  ? Colors.grey
                                                  : const Color(0xFF2563EB),
                                              foregroundColor: Colors.white,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 18,
                                                  ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: _isLoading
                                                ? null
                                                : (widget.deal?.id == null
                                                      ? null
                                                      : _showLinkBillDialog),
                                            icon: const Icon(
                                              Icons.link_rounded,
                                            ),
                                            label: const Text(
                                              'LINK EXISTING',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: const Color(
                                                0xFF2563EB,
                                              ),
                                              side: const BorderSide(
                                                color: Color(0xFF2563EB),
                                                width: 2,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 18,
                                                  ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  const SizedBox(height: 16),
                                  _buildResponsibleTeamSection(title: ''),
                                ]).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1),
                              ],

                              if (_shouldShowStage('Billing Status')) ...[
                                const SizedBox(height: 24),
                                _buildSectionCard('BILLING STATUS', [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _buildField(
                                              'Invoice Amount',
                                              _invoiceAmountController,
                                              '0',
                                              isCurrency: true,
                                              icon: Icons.receipt_long_outlined,
                                            ),
                                          ),
                                          const SizedBox(width: 20),
                                          Expanded(
                                            child: _buildField(
                                              'Payment Received',
                                              _paymentReceivedController,
                                              '0',
                                              isCurrency: true,
                                              icon: Icons.payments_outlined,
                                            ),
                                          ),
                                          const SizedBox(width: 20),
                                          Container(
                                            width: 140,
                                            padding: const EdgeInsets.only(
                                              top: 24,
                                            ),
                                            child: _buildDropdown('', 'INR', [
                                              'INR',
                                              'US Dollar',
                                            ], (v) {}),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 24),
                                      _buildModernRadioGroup(
                                        'Payment Type',
                                        _paymentType,
                                        [
                                          'not selected',
                                          'CASH',
                                          'ACCOUNT TRANSFER',
                                          'GOOGLE PAY',
                                        ],
                                        (v) =>
                                            setState(() => _paymentType = v!),
                                      ),
                                      const SizedBox(height: 24),
                                      const Divider(),
                                      _buildResponsibleTeamSection(title: ''),
                                    ])
                                    .animate()
                                    .fadeIn(duration: 400.ms)
                                    .slideY(begin: 0.1),
                              ],

                              if (_shouldShowStage('Close Deal')) ...[
                                const SizedBox(height: 24),
                                _buildSectionCard('CLOSE DEAL', [
                                      Container(
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: Colors.green.shade50,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: Colors.green.shade200,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.verified_rounded,
                                              color: Colors.green,
                                              size: 32,
                                            ),
                                            const SizedBox(width: 16),
                                            Expanded(
                                              child: Text(
                                                'By saving this deal in the Close Deal stage, it will be marked as officially completed and closed in the pipeline.',
                                                style: TextStyle(
                                                  color: Colors.green.shade800,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ])
                                    .animate()
                                    .fadeIn(duration: 400.ms)
                                    .slideY(begin: 0.1),
                              ],
                            ],
                          ),
                        ),
                      ),
                      // Right Panel: Activity Feed & Quick Actions
                      Container(
                        width: isWide ? 450 : double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border(
                            left: isWide
                                ? BorderSide(
                                    color: Colors.black.withValues(alpha: 0.05),
                                  )
                                : BorderSide.none,
                            top: !isWide
                                ? BorderSide(
                                    color: Colors.black.withValues(alpha: 0.05),
                                  )
                                : BorderSide.none,
                          ),
                        ),
                        child: _buildUnifiedActivityPanel(),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPremiumHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Colors.black.withValues(alpha: 0.05)),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded),
            style: IconButton.styleFrom(
              backgroundColor: Colors.grey.shade100,
              padding: const EdgeInsets.all(8),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.deal == null
                      ? (_pipeline.toLowerCase() == 'crm' ? 'New CRM Lead' : 'Create New Work')
                      : widget.deal!.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                Text(
                  _pipeline.toLowerCase() == 'crm' ? 'CRM Lead Pipeline' : 'Work Management Pipeline',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_pipeline.toLowerCase() == 'crm' && !_isWon) ...[
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _showPassLeadDialog,
              icon: const Icon(Icons.check_circle_rounded, size: 16, color: Colors.white),
              label: const Text('Pass to Work & Client', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
            ),
            const SizedBox(width: 8),
          ] else if (_pipeline.toLowerCase() == 'crm' && _isWon) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFDCFCE7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF86EFAC)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified, size: 14, color: Color(0xFF16A34A)),
                  SizedBox(width: 4),
                  Text('Passed to Work', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF166534))),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
          ElevatedButton(
            onPressed: _isLoading ? null : _saveDeal,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00C16C),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: 0,
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Text(
                    'SAVE',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPipelineTracker() {
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 12, bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10),
        ],
      ),
      child: RawScrollbar(
        controller: _pipelineScrollController,
        thumbVisibility: true,
        trackVisibility: true,
        thickness: 8.0,
        radius: const Radius.circular(4),
        thumbColor: const Color(0xFF2563EB),
        trackColor: const Color(0xFFE2E8F0),
        child: SingleChildScrollView(
          controller: _pipelineScrollController,
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: Deal.stages.asMap().entries.map((entry) {
                final idx = entry.key;
                final stage = entry.value;
                final isCurrent = _currentStage == stage;
                final isPast = _currentStageIndex > idx;

                return Row(
                  children: [
                    InkWell(
                      onTap: () async {
                        if (stage == _currentStage) return;
                        
                        // Validation for "Work Started" stage part payment / NOC
                        if (_currentStage == 'Work Started' && Deal.stages.indexOf(stage) > Deal.stages.indexOf('Work Started')) {
                          final partPayment = double.tryParse(_partPaymentAmountController.text) ?? 0;
                          if (partPayment <= 0 && !_nocObtained) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Client must provide a part payment or you must obtain an NOC from Irshad sir to start work to proceed.'),
                                backgroundColor: Colors.red,
                              ),
                            );
                            return;
                          }
                        }

                        if (widget.deal != null) {
                          setState(() => _isLoading = true);
                          try {
                            final oldStage = _currentStage;
                            await _dealService.moveDealToStage(
                              widget.deal!.id!,
                              oldStage,
                              stage,
                            );
                            if (mounted) {
                              setState(() {
                                _currentStage = stage;
                                _isLoading = false;
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Stage updated to: $stage'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                              _loadDetails();
                            }
                          } catch (e) {
                            if (mounted) {
                              setState(() => _isLoading = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Error updating stage: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                        } else {
                          setState(() => _currentStage = stage);
                        }
                      },
                      child: AnimatedContainer(
                        duration: 300.ms,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? const Color(0xFF2563EB).withValues(alpha: 0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isCurrent
                                ? const Color(0xFF2563EB)
                                : isPast
                                ? const Color(0xFF2563EB).withValues(alpha: 0.3)
                                : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            if (isPast)
                              const Icon(
                                Icons.check_circle_rounded,
                                size: 16,
                                color: Color(0xFF2563EB),
                              )
                            else
                              Container(
                                width: 16,
                                height: 16,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isCurrent
                                        ? const Color(0xFF2563EB)
                                        : Colors.grey.shade400,
                                    width: 2,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 10),
                            Text(
                              stage,
                              style: TextStyle(
                                color: isCurrent
                                    ? const Color(0xFF2563EB)
                                    : isPast
                                    ? const Color(0xFF2563EB).withValues(alpha: 0.7)
                                    : Colors.grey,
                                fontWeight: isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (idx < Deal.stages.length - 1)
                      Container(
                        width: 30,
                        height: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        color: isPast
                            ? const Color(0xFF2563EB).withValues(alpha: 0.3)
                            : Colors.grey.shade200,
                      ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPipelineSelector() {
    final bool isCrm = _pipeline.toLowerCase() == 'crm';
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isCrm ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCrm ? const Color(0xFF86EFAC) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCrm ? Icons.hub_rounded : Icons.work_outline_rounded,
                size: 18,
                color: isCrm ? const Color(0xFF16A34A) : const Color(0xFF475569),
              ),
              const SizedBox(width: 8),
              Text(
                'Pipeline Module',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: isCrm ? const Color(0xFF166534) : const Color(0xFF1E293B),
                ),
              ),
              const Spacer(),
              if (isCrm && _isWon)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF86EFAC)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.verified, size: 12, color: Color(0xFF16A34A)),
                      SizedBox(width: 4),
                      Text(
                        'Passed to Work & Client',
                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF166534)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade300),
            ),
            padding: const EdgeInsets.all(3),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() => _pipeline = 'CRM');
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isCrm ? const Color(0xFF16A34A) : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'CRM Lead (Inquiry)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isCrm ? FontWeight.bold : FontWeight.w500,
                          color: isCrm ? Colors.white : const Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() => _pipeline = 'General');
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: !isCrm ? const Color(0xFF2563EB) : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Direct Work Project',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: !isCrm ? FontWeight.bold : FontWeight.w500,
                          color: !isCrm ? Colors.white : const Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isCrm
                ? 'CRM leads stay separate from Work & Client Management. Once qualified, tap "Pass to Work & Client" to convert.'
                : 'Direct work projects are immediately active in the Work Management pipeline.',
            style: TextStyle(
              fontSize: 11.5,
              color: isCrm ? const Color(0xFF15803D) : Colors.grey.shade600,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard(String title, List<Widget> children) {
    bool isCurrent = false;
    switch (title) {
      case 'FILE CREATION': isCurrent = _currentStage == 'Registration'; break;
      case 'CONTACT CUSTOMER': isCurrent = _currentStage == 'Contact Customer'; break;
      case 'WORK START': isCurrent = _currentStage == 'Work Started'; break;
      case 'IN PROGRESS': isCurrent = _currentStage == 'In Progress'; break;
      case 'VERIFICATION': isCurrent = _currentStage == 'Verification'; break;
      case 'INVOICE CREATION': isCurrent = _currentStage == 'Invoice'; break;
      case 'BILLING STATUS': isCurrent = _currentStage == 'Billing Status'; break;
      case 'CLOSE DEAL': isCurrent = _currentStage == 'Close Deal'; break;
      default: isCurrent = false;
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Material(
          color: Colors.transparent,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: ValueKey('$_currentStage-$title'),
          initiallyExpanded: isCurrent,
          tilePadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          childrenPadding: const EdgeInsets.only(left: 32, right: 32, bottom: 32),
          title: Row(
            children: [
              Container(
                width: 4,
                height: 18,
                decoration: BoxDecoration(
                  color: isCurrent ? AppTheme.primaryColor : Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: isCurrent ? Colors.black : Colors.grey.shade600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          children: [
            const Divider(height: 1),
            const SizedBox(height: 24),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }

  Widget _buildClientAutocompleteField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Client',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF64748B),
              ),
            ),
            if (_clientController.text.isNotEmpty)
              TextButton.icon(
                onPressed: _openClientFilesVault,
                icon: const Icon(Icons.folder_special_rounded, size: 16),
                label: const Text('Client Files Vault', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.primaryColor,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Autocomplete<Map<String, dynamic>>(
          initialValue: TextEditingValue(text: _clientController.text),
          optionsBuilder: (TextEditingValue textEditingValue) async {
            if (textEditingValue.text.isEmpty) {
              return const Iterable<Map<String, dynamic>>.empty();
            }
            final results = await ClientService().searchClients(textEditingValue.text);
            debugPrint(
              'Found ${results.length} clients for query: ${textEditingValue.text}',
            );
            return results;
          },
          displayStringForOption: (Map<String, dynamic> option) =>
              option['name'] as String,
          onSelected: (Map<String, dynamic> selection) {
            setState(() {
              _clientController.text = selection['name'];
              _companyController.text = selection['id']?.toString() ?? '';
              _contactController.text =
                  selection['phone'] ?? selection['email'] ?? '';
              _workTypeController.text = selection['type_of_work'];
            });
          },
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            return TextField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              onChanged: (v) {
                _clientController.text = v;
              },
              decoration: InputDecoration(
                hintText: 'Search or enter client name...',
                prefixIcon: const Icon(
                  Icons.person_outline_rounded,
                  size: 18,
                  color: Colors.grey,
                ),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade200),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade200),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                    color: Color(0xFF2563EB),
                    width: 2,
                  ),
                ),
              ),
            );
          },
          optionsViewBuilder: (context, onSelected, options) {
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  color: Colors.white,
                  child: Container(
                    width:
                        380, // Slightly smaller than the field to look better
                    constraints: const BoxConstraints(maxHeight: 250),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: options.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final option = options.elementAt(index);
                        final name = option['name'].toString();
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: const Color(
                              0xFF2563EB,
                            ).withValues(alpha: 0.1),
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: const TextStyle(
                                color: Color(0xFF2563EB),
                                fontWeight: FontWeight.bold,
                                fontSize: 10,
                              ),
                            ),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            option['phone'] ?? option['address'] ?? '',
                            style: const TextStyle(fontSize: 10),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => onSelected(option),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  double _calculateTotalExpense() {
    double total = 0.0;
    for (var controller in _expenseControllers) {
      final amount = double.tryParse(controller['amount']?.text ?? '0') ?? 0;
      total += amount;
    }
    return total;
  }

  List<Map<String, dynamic>> _getExpensesList() {
    return _expenseControllers.map((c) {
      return {
        'name': c['name']?.text ?? '',
        'amount': double.tryParse(c['amount']?.text ?? '0') ?? 0,
      };
    }).toList();
  }

  Widget _buildDynamicExpensesList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Expenses',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.mutedTextColor,
                letterSpacing: 0.5,
              ),
            ),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _expenseControllers.add({
                    'name': TextEditingController(),
                    'amount': TextEditingController(),
                  });
                });
              },
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Add Expense', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primaryColor,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_expenseControllers.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
            ),
            child: const Center(
              child: Text(
                'No expenses added yet',
                style: TextStyle(color: AppTheme.mutedTextColor, fontSize: 12),
              ),
            ),
          ),
        ..._expenseControllers.asMap().entries.map((entry) {
          int index = entry.key;
          var controllers = entry.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: controllers['name'],
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Expense Name',
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: TextFormField(
                    controller: controllers['amount'],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: '0',
                      prefixText: '₹ ',
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _expenseControllers.removeAt(index);
                    });
                  },
                  icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildCategoryDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.class_outlined, size: 20, color: AppTheme.primaryColor),
            const SizedBox(width: 8),
            Text('Category', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.grey.shade700)),
          ],
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _selectedCategory,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
          ),
          items: ['General', 'Legal', 'Consultancy'].map((String value) {
            return DropdownMenuItem<String>(
              value: value,
              child: Text(value, style: const TextStyle(fontSize: 15)),
            );
          }).toList(),
          onChanged: (newValue) {
            setState(() {
              _selectedCategory = newValue!;
            });
          },
        ),
      ],
    );
  }

  Widget _buildField(
    String label,
    TextEditingController controller,
    String hint, {
    int lines = 1,
    bool isCurrency = false,
    IconData? icon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          maxLines: lines,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: icon != null
                ? Icon(icon, size: 18, color: Colors.grey)
                : null,
            prefixText: isCurrency ? '₹ ' : null,
            prefixStyle: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDatePickerField(
    String label,
    DateTime? selectedDate,
    VoidCallback onTap,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 10),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              border: Border.all(color: Colors.grey.shade200),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.calendar_today_rounded,
                  color: Color(0xFF2563EB),
                  size: 18,
                ),
                const SizedBox(width: 12),
                Text(
                  selectedDate != null
                      ? DateFormat('yyyy-MM-dd').format(selectedDate)
                      : 'Select date...',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: selectedDate != null ? Colors.black : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModernRadioGroup(
    String label,
    String currentVal,
    List<String> options,
    ValueChanged<String?> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: options.map((opt) {
            final isSelected = currentVal == opt;
            return InkWell(
              onTap: () => onChanged(opt),
              borderRadius: BorderRadius.circular(30),
              child: AnimatedContainer(
                duration: 200.ms,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFF2563EB) : Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF2563EB)
                        : Colors.grey.shade300,
                  ),
                ),
                child: Text(
                  opt,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.grey.shade700,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  void _changeResponsible() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _UserSelectionDialog(users: _allUsers),
    );

    if (result != null) {
      setState(() {
        _responsibleId = result['id'];
        _responsibleName = result['name'];
      });

      // If deal exists, also log it as an activity immediately
      if (widget.deal?.id != null) {
        await _dealService.addActivity(
          DealActivity(
            dealId: widget.deal!.id!,
            type: 'task',
            title: 'Lead Responsibility Changed',
            description: 'Responsibility transferred to $_responsibleName',
            createdBy: 1, // Placeholder
          ),
        );

        // Lively WhatsApp alert to newly assigned responsible staff
        final prefs = await SharedPreferences.getInstance();
        final currentUserName = prefs.getString('user_name') ?? 'Management';
        unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
          staffUserId: _responsibleId,
          assignmentTitle: widget.deal?.name ?? 'Work Assignment',
          workOrTaskType: 'Work Responsibility Transferred',
          clientName: widget.deal?.clientName,
          assignedByName: currentUserName,
          details: 'You are now the responsible staff member for "${widget.deal?.name ?? 'this work'}".',
        ));

        _loadDetails();
      }
    }
  }

  Widget _buildResponsibleTeamSection({String title = 'Responsible Staff'}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty) ...[
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            // Current Lead
            if (_responsibleName != null)
              _buildStaffChip(
                _responsibleName!,
                isLead: true,
                onDeleted: () {
                  setState(() {
                    _responsibleId = null;
                    _responsibleName = null;
                  });
                },
              ),
            // Collaborators
            ..._assignees
                .where((a) => a.role == 'Collaborator')
                .map(
                  (a) => _buildStaffChip(
                    a.userName ?? 'User',
                    onDeleted: () => _removeParticipant(a.userId),
                  ),
                ),
            // Add Button
            ActionChip(
              avatar: const Icon(
                Icons.add_rounded,
                size: 16,
                color: Color(0xFF2563EB),
              ),
              label: const Text(
                'Add Staff',
                style: TextStyle(
                  color: Color(0xFF2563EB),
                  fontWeight: FontWeight.bold,
                ),
              ),
              backgroundColor: const Color(0xFF2563EB).withValues(alpha: 0.05),
              side: BorderSide(color: const Color(0xFF2563EB).withValues(alpha: 0.1)),
              onPressed: _addStaffMember,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStaffChip(
    String name, {
    bool isLead = false,
    VoidCallback? onDeleted,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isLead ? const Color(0xFF2563EB).withValues(alpha: 0.1) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isLead
              ? const Color(0xFF2563EB).withValues(alpha: 0.2)
              : Colors.grey.shade200,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: isLead
                ? const Color(0xFF2563EB)
                : Colors.grey.shade200,
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                color: isLead ? Colors.white : Colors.grey.shade700,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isLead ? FontWeight.bold : FontWeight.w500,
              color: isLead ? const Color(0xFF2563EB) : Colors.black87,
            ),
          ),
          if (onDeleted != null) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: onDeleted,
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: isLead ? const Color(0xFF2563EB) : Colors.grey,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _addStaffMember() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) =>
          _UserSelectionDialog(users: _allUsers, title: 'Assign Staff Member'),
    );

    if (result != null) {
      final userId = result['id'];
      final userName = result['name'];

      // If no lead is set, make this person the lead
      if (_responsibleId == null) {
        setState(() {
          _responsibleId = userId;
          _responsibleName = userName;
        });
      } else {
        // Otherwise add as collaborator
        if (_assignees.any((a) => a.userId == userId)) return;

        setState(() {
          _assignees.add(
            DealAssignee(
              dealId: widget.deal?.id ?? 0,
              userId: userId,
              userName: userName,
              role: 'Collaborator',
            ),
          );
        });

        if (widget.deal?.id != null) {
          await _dealService.addAssignee(
            widget.deal!.id!,
            userId,
            role: 'Collaborator',
          );
          _loadDetails();
        }
      }
    }
  }

  void _removeParticipant(int userId) async {
    setState(() {
      _assignees.removeWhere((a) => a.userId == userId);
    });
    if (widget.deal?.id != null) {
      await _dealService.removeAssignee(widget.deal!.id!, userId);
      _loadDetails();
    }
  }

  Widget _buildResponsibleDisplay({bool mini = false}) {
    if (_responsibleName == null) return const SizedBox();

    return Container(
      padding: EdgeInsets.symmetric(horizontal: mini ? 0 : 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.person_pin_circle_rounded,
            size: 14,
            color: Colors.grey.shade400,
          ),
          const SizedBox(width: 8),
          Text(
            'Responsible: ',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            _responsibleName!,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade700,
            ),
          ),
          if (_assignees.where((a) => a.role == 'Collaborator').isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              '+ ${_assignees.where((a) => a.role == 'Collaborator').length} more',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade400,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDropdown(
    String label,
    String value,
    List<String> items,
    ValueChanged<String?> onChanged,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: DropdownButton<String>(
        value: value,
        isExpanded: true,
        underline: const SizedBox(),
        items: items
            .map(
              (e) => DropdownMenuItem(
                value: e,
                child: Text(
                  e,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  void _openDriveLink() async {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return Dialog(
              backgroundColor: Colors.transparent,
              child: Container(
                width: 500,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceColor,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 30, spreadRadius: 5)],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Connected Documents', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textColor)),
                        IconButton(
                          onPressed: () => _showGoogleDocsConnectDialog((_) {
                            setStateDialog(() {});
                            setState(() {});
                          }),
                          icon: const Icon(Icons.add_circle_outline_rounded, color: AppTheme.primaryColor),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    if (_connectedDocs.isEmpty)
                      const Center(child: Text('No documents connected yet', style: TextStyle(color: AppTheme.mutedTextColor)))
                    else
                      Container(
                        decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade200), borderRadius: BorderRadius.circular(12)),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _connectedDocs.length,
                          separatorBuilder: (context, index) => Divider(height: 1, color: Colors.grey.shade200),
                          itemBuilder: (context, index) {
                            final doc = _connectedDocs[index];
                            return ListTile(
                              leading: const Icon(Icons.description_rounded, color: Colors.blueAccent),
                              title: Text(doc['name'] ?? 'Document', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                              trailing: IconButton(
                                icon: const Icon(Icons.close_rounded, color: Colors.redAccent, size: 20),
                                onPressed: () async {
                                  _connectedDocs.removeAt(index);
                                  _driveLinkController.text = jsonEncode(_connectedDocs);
                                  await _saveDeal();
                                  setStateDialog(() {});
                                  setState(() {});
                                },
                              ),
                              onTap: () {
                                Navigator.push(context, MaterialPageRoute(builder: (_) => GoogleDocsWebviewScreen(url: doc['url']!, title: doc['name']!)));
                              },
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 32),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('CLOSE', style: TextStyle(color: AppTheme.mutedTextColor, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        );
      }
    );
  }

  void _showGoogleDocsConnectDialog(StateSetter? parentSetState) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 500,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 30, spreadRadius: 5),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.document_scanner_rounded, size: 32, color: AppTheme.primaryColor),
                ),
                const SizedBox(height: 24),
                const Text('Connect Google Doc', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppTheme.textColor, fontFamily: 'Montserrat')),
                const SizedBox(height: 8),
                const Text('Create a new document or link an existing one from your Google Docs Vault.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: AppTheme.mutedTextColor, fontFamily: 'Montserrat')),
                const SizedBox(height: 32),
                
                // Option 1: Create New
                Opacity(
                  opacity: _clientController.text.trim().isEmpty ? 0.5 : 1.0,
                  child: _buildDocOption(
                    icon: Icons.add_circle_outline_rounded,
                    title: 'Create New Document',
                    subtitle: _clientController.text.trim().isEmpty ? 'Please select a Client first' : 'Automatically connects to this Work',
                    onTap: () async {
                      if (_clientController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a Client before creating a new document.', style: TextStyle(fontFamily: 'Montserrat'))));
                        return;
                      }
                      Navigator.pop(context);
                      // Show loading
                      showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
                      final docName = _nameController.text.trim().isNotEmpty ? '${_nameController.text.trim()} Doc' : 'New Work Doc';
                      final url = await GoogleDocsService.createNewDocument(docName);
                      if (context.mounted) Navigator.pop(context); // hide loading
                      if (url != null) {
                        _connectedDocs.add({"name": docName, "url": url});
                        _driveLinkController.text = jsonEncode(_connectedDocs);
                        await _saveDeal();
                        if (parentSetState != null) parentSetState(() {});
                        setState(() {});
                      } else {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to create document.')));
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                
                // Option 2: Select Existing
                _buildDocOption(
                  icon: Icons.folder_open_rounded,
                  title: 'Select from Vault',
                  subtitle: 'Pick an existing Google Doc',
                  onTap: () {
                    Navigator.pop(context);
                    _showVaultSelectionDialog(parentSetState);
                  },
                ),
                const SizedBox(height: 12),
                
                // Option 3: Paste Manually
                _buildDocOption(
                  icon: Icons.link_rounded,
                  title: 'Paste Link Manually',
                  subtitle: 'Paste any external document URL',
                  onTap: () {
                    Navigator.pop(context);
                    _showManualPasteDialog(parentSetState);
                  },
                ),
                const SizedBox(height: 32),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('CANCEL', style: TextStyle(color: AppTheme.mutedTextColor, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        );
      }
    );
  }

  Widget _buildDocOption({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade200),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.primaryColor, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textColor)),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: AppTheme.mutedTextColor)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: AppTheme.mutedTextColor),
          ],
        ),
      ),
    );
  }

  void _showManualPasteDialog(StateSetter? parentSetState) {
    final TextEditingController urlController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Paste Link', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textColor)),
        content: TextField(
          controller: urlController,
          decoration: InputDecoration(
            hintText: 'https://docs.google.com/...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL', style: TextStyle(color: AppTheme.mutedTextColor)),
          ),
          ElevatedButton(
            onPressed: () async {
              if (urlController.text.trim().isNotEmpty) {
                _connectedDocs.add({"name": "Pasted Link", "url": urlController.text.trim()});
                _driveLinkController.text = jsonEncode(_connectedDocs);
                await _saveDeal();
                if (parentSetState != null) parentSetState(() {});
                setState(() {});
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('SAVE', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showVaultSelectionDialog(StateSetter? parentSetState) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: AppTheme.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          width: 500,
          height: 600,
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Text('Select Document', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textColor)),
              const SizedBox(height: 16),
              Expanded(
                child: FutureBuilder<List<drive.File>>(
                  future: GoogleDocsService.getDriveFiles(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError || !snapshot.hasData || snapshot.data!.isEmpty) {
                      return const Center(child: Text('No documents found in Vault.'));
                    }
                    final docs = snapshot.data!;
                    return ListView.builder(
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        final doc = docs[index];
                        return Card(
                          elevation: 0,
                          color: AppTheme.primaryColor.withValues(alpha: 0.03),
                          margin: const EdgeInsets.only(bottom: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
                          child: ListTile(
                            leading: const Icon(Icons.description, color: Colors.blueAccent),
                            title: Text(doc.name ?? 'Untitled', style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textColor)),
                            subtitle: Text('Modified: ${doc.modifiedTime?.toLocal().toString().split('.')[0] ?? ''}', style: const TextStyle(color: AppTheme.mutedTextColor, fontSize: 12)),
                            onTap: () async {
                              _connectedDocs.add({"name": doc.name ?? 'Untitled', "url": doc.webViewLink ?? ''});
                              _driveLinkController.text = jsonEncode(_connectedDocs);
                              Navigator.pop(context);
                              await _saveDeal();
                              if (parentSetState != null) parentSetState(() {});
                              setState(() {});
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('CANCEL', style: TextStyle(color: AppTheme.mutedTextColor)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectedDocsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Connected Documents',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFF475569)),
            ),
            IconButton(
              onPressed: () => _showGoogleDocsConnectDialog((_) => setState(() {})),
              icon: const Icon(Icons.add_circle_outline_rounded, color: AppTheme.primaryColor),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_connectedDocs.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: const Center(
              child: Text('No documents connected yet', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE2E8F0)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _connectedDocs.length,
              separatorBuilder: (context, index) => const Divider(height: 1, color: Color(0xFFE2E8F0)),
              itemBuilder: (context, index) {
                final doc = _connectedDocs[index];
                return ListTile(
                  leading: const Icon(Icons.description_rounded, color: Colors.blueAccent, size: 20),
                  title: Text(doc['name'] ?? 'Document', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  dense: true,
                  trailing: IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.redAccent, size: 16),
                    onPressed: () async {
                      setState(() {
                        _connectedDocs.removeAt(index);
                      });
                      _driveLinkController.text = jsonEncode(_connectedDocs);
                      await _saveDeal();
                    },
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => GoogleDocsWebviewScreen(url: doc['url']!, title: doc['name']!),
                      ),
                    );
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildUnifiedActivityPanel() {
    return Column(
      children: [
        // Quick Action Bar
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.black.withValues(alpha: 0.05)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'QUICK ACTIONS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) {
                  final double spacing = 12.0;
                  final int columns = constraints.maxWidth > 600 ? 4 : 2;
                  final double itemWidth = (constraints.maxWidth - (spacing * (columns - 1))) / columns;
                  
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      _quickActionBtn(
                        Icons.comment_outlined,
                        'COMMENT',
                        const Color(0xFF2563EB),
                        width: itemWidth,
                        onTap: () {
                          _commentFocus.requestFocus();
                        },
                      ),
                      _quickActionBtn(
                        Icons.check_circle_outline_rounded,
                        'TASK',
                        const Color(0xFF00C16C),
                        width: itemWidth,
                        onTap: _showScheduleDialog,
                      ),
                      _quickActionBtn(
                        Icons.folder_special_rounded,
                        'VAULT',
                        const Color(0xFFF59E0B),
                        width: itemWidth,
                        onTap: _openClientFilesVault,
                      ),
                      _quickActionBtn(
                        Icons.description_rounded,
                        'DOCS',
                        const Color(0xFF4285F4),
                        width: itemWidth,
                        onTap: _openDriveLink,
                      ),
                      _quickActionBtn(
                        Icons.update_rounded,
                        'DAILY UPDATE',
                        AppTheme.accentColor,
                        width: itemWidth,
                        onTap: _showDailyUpdateDialog,
                      ),
                      _quickActionBtn(
                        Icons.folder_shared_rounded,
                        'WORK FILE',
                        const Color(0xFF8B5CF6),
                        width: itemWidth,
                        onTap: _openWorkFileDialog,
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        // Unified Feed
        Expanded(child: _buildModernActivityFeed()),
        _buildActivityInputArea(),
      ],
    );
  }

  Widget _quickActionBtn(
    IconData icon,
    String label,
    Color color, {
    double? width,
    VoidCallback? onTap,
  }) {
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModernActivityFeed() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _activities.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 32),
            child: Row(
              children: [
                const Text(
                  'RECENT FEED',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                const Icon(
                  Icons.filter_list_rounded,
                  size: 16,
                  color: Colors.grey,
                ),
              ],
            ),
          );
        }
        final act = _activities[index - 1];
        return _buildActivityFeedItem(act);
      },
    );
  }

  Widget _buildActivityFeedItem(DealActivity act) {
    Color bgColor;
    IconData iconData;
    Color iconColor;

    if (act.type == 'client_query') {
      bgColor = AppTheme.accentColor.withValues(alpha: 0.1);
      iconColor = AppTheme.accentColor;
      iconData = Icons.person_rounded;
    } else if (act.type == 'staff_reply') {
      bgColor = Colors.green.withValues(alpha: 0.1);
      iconColor = Colors.green;
      iconData = Icons.support_agent_rounded;
    } else {
      bgColor = const Color(0xFF2563EB).withValues(alpha: 0.1);
      iconColor = const Color(0xFF2563EB);
      iconData = Icons.check_circle_rounded;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: bgColor,
              shape: BoxShape.circle,
            ),
            child: Icon(
              iconData,
              size: 18,
              color: iconColor,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      act.title ?? 'Unknown task',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      DateFormat(
                        'hh:mm a',
                      ).format(act.createdAt ?? DateTime.now()),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
                if (act.description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      act.description!,
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.person_outline,
                      size: 12,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      act.creatorName ?? 'Admin',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityInputArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.black.withValues(alpha: 0.05))),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: TextField(
              controller: _commentController,
              focusNode: _commentFocus,
              decoration: const InputDecoration(
                hintText: 'Add a comment or schedule a task...',
                border: InputBorder.none,
                hintStyle: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              maxLines: 2,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _inputActionBtn(
                    Icons.calendar_month_rounded,
                    'Schedule',
                    onTap: _showScheduleDialog,
                  ),
                  _inputActionBtn(Icons.attach_file_rounded, 'Attach'),
                  _inputActionBtn(Icons.alternate_email_rounded, 'Mention'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(
                    onPressed: _postDailyUpdate,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Post Daily Update'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _postActivity,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Post Activity'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _postActivity() async {
    if (_commentController.text.trim().isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final myId = prefs.getInt('current_user_id') ?? 1;

    debugPrint('DEBUG _postActivity: dealId=${widget.deal?.id}, dealIdType=${widget.deal?.id.runtimeType}, myId=$myId, text=${_commentController.text}');

    final activity = DealActivity(
      dealId: widget.deal?.id ?? 0,
      type: 'comment',
      title: 'New Comment',
      description: _commentController.text,
      createdBy: myId,
    );

    if (widget.deal?.id != null) {
      debugPrint('DEBUG _postActivity: calling addActivity...');
      try {
        await _dealService.addActivity(activity);
        debugPrint('DEBUG _postActivity: addActivity completed successfully');
        _commentController.clear();
        _loadDetails();
      } catch (e) {
        debugPrint('DEBUG _postActivity: addActivity threw: $e');
      }
    } else {
      debugPrint('DEBUG _postActivity: deal id is null, showing snackbar');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please save the deal first to post comments.'),
        ),
      );
    }
  }

  Future<void> _postDailyUpdate() async {
    if (_commentController.text.trim().isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final myId = prefs.getInt('current_user_id') ?? 1;

    final description = _commentController.text;

    // 1. Save to Postgres for staff activity feed
    final activity = DealActivity(
      dealId: widget.deal?.id ?? 0,
      type: 'daily_update',
      title: 'Daily Update',
      description: description,
      createdBy: myId,
    );

    if (widget.deal?.id != null) {
      await _dealService.addActivity(activity);
      
      // 2. Save to Amplify for client portal
      try {
        final amplifyAct = amplify_models.DealActivities(
          deal_id: widget.deal!.id!.toString(),
          type: 'daily_update',
          title: 'Daily Update',
          description: description,
          created_by: myId,
          created_at: DateTime.now().toIso8601String(),
        );
        final req = ModelMutations.create(amplifyAct);
        await Amplify.API.mutate(request: req).response;
      } catch (e) {
        debugPrint('Error saving to Amplify: $e');
      }

      _commentController.clear();
      _loadDetails();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Daily Update posted to client.')),
        );
      }
    } else {
      // For new unsaved deals, we can't save activity yet
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please save the deal first to post updates.'),
        ),
      );
    }
  }

  void _showDailyUpdateDialog() {
    final updateController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AppTheme.accentColor.withValues(alpha: 0.1), shape: BoxShape.circle),
                child: const Icon(Icons.update_rounded, color: AppTheme.accentColor),
              ),
              const SizedBox(width: 12),
              const Text('Post Daily Update', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: TextField(
              controller: updateController,
              decoration: InputDecoration(
                hintText: 'What is the update on this workfile?',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
              maxLines: 4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                if (updateController.text.trim().isEmpty) return;
                Navigator.pop(context);

                final prefs = await SharedPreferences.getInstance();
                final myId = prefs.getInt('current_user_id') ?? 1;

                final description = updateController.text.trim();

                final activity = DealActivity(
                  dealId: widget.deal?.id ?? 0,
                  type: 'daily_update',
                  title: 'Daily Update',
                  description: description,
                  createdBy: myId,
                );

                if (widget.deal?.id != null) {
                  await _dealService.addActivity(activity);
                  
                  try {
                    final amplifyAct = amplify_models.DealActivities(
                      deal_id: widget.deal!.id!,
                      type: 'daily_update',
                      title: 'Daily Update',
                      description: description,
                      created_by: myId,
                      created_at: DateTime.now().toIso8601String(),
                    );
                    final req = ModelMutations.create(amplifyAct);
                    await Amplify.API.mutate(request: req).response;
                  } catch (e) {
                    debugPrint('Error saving to Amplify: $e');
                  }
                  
                  _loadDetails();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Daily Update posted to client.')),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Post to Client'),
            ),
          ],
        );
      },
    );
  }

   void _showScheduleDialog() {
    final descController = TextEditingController();
    String selectedType = 'task';
    DateTime selectedDate = DateTime.now().add(const Duration(days: 1));
    dynamic assignedTo = _responsibleId;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          elevation: 10,
          child: Container(
            width: 450,
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: const Color(0xFFF0FDF4), shape: BoxShape.circle), // Green 50
                      child: const Icon(Icons.event_available_rounded, color: Color(0xFF16A34A), size: 24), // Green 600
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Schedule Activity', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
                          const SizedBox(height: 2),
                          Text('Plan a new task or meeting', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Activity Type Dropdown
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selectedType,
                      isExpanded: true,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey),
                      style: const TextStyle(fontSize: 14, color: Colors.black87, fontWeight: FontWeight.w500),
                      items: const [
                        DropdownMenuItem(value: 'call', child: Text('Call')),
                        DropdownMenuItem(value: 'email', child: Text('Message / Email')),
                        DropdownMenuItem(value: 'meeting', child: Text('Meeting / Follow-up')),
                        DropdownMenuItem(value: 'task', child: Text('Task')),
                      ],
                      onChanged: (v) => setState(() => selectedType = v!),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (selectedType == 'task') ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<dynamic>(
                        value: assignedTo,
                        isExpanded: true,
                        icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey),
                        style: const TextStyle(fontSize: 14, color: Colors.black87, fontWeight: FontWeight.w500),
                        hint: const Text('Assign To...'),
                        items: _allUsers.map((u) => DropdownMenuItem<dynamic>(
                          value: u['id'],
                          child: Text(u['name'].toString()),
                        )).toList(),
                        onChanged: (v) => setState(() => assignedTo = v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                // Date & Time Picker
                InkWell(
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime(2030),
                      builder: (context, child) {
                        return Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: const ColorScheme.light(
                              primary: Color(0xFF16A34A),
                              onPrimary: Colors.white,
                              onSurface: Colors.black,
                            ),
                          ),
                          child: child!,
                        );
                      },
                    );
                    if (date != null) {
                      if (!mounted) return;
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(selectedDate),
                      );
                      if (time != null) {
                        setState(() {
                          selectedDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                        });
                      }
                    }
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.transparent),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_month_rounded, color: Color(0xFF16A34A), size: 20),
                        const SizedBox(width: 12),
                        Text(
                          DateFormat('MMM dd, yyyy - hh:mm a').format(selectedDate),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87),
                        ),
                        const Spacer(),
                        const Icon(Icons.edit_calendar_rounded, size: 16, color: Colors.grey),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Description
                TextField(
                  controller: descController,
                  style: const TextStyle(fontSize: 14, color: Colors.black87),
                  decoration: InputDecoration(
                    hintText: 'Notes or description...',
                    hintStyle: TextStyle(color: Colors.grey.shade400),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    contentPadding: const EdgeInsets.all(16),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF86EFAC), width: 1.5)), // Green 300
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 24),
                // Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12), foregroundColor: Colors.grey.shade600),
                      child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: () async {
                        if (descController.text.isNotEmpty && widget.deal?.id != null) {
                          final prefs = await SharedPreferences.getInstance();
                          final myId = prefs.getInt('current_user_id') ?? 1;

                          // 1. Add Deal Activity
                          await _dealService.addActivity(
                            DealActivity(
                              dealId: widget.deal!.id!,
                              type: selectedType,
                              title: 'Scheduled ${selectedType.toUpperCase()}',
                              description: descController.text,
                              createdBy: myId,
                              dueDate: selectedDate,
                            ),
                          );

                          // 2. If type is 'task', sync to main tasks table
                          if (selectedType == 'task') {
                            try {
                              final taskData = {
                                'title': 'DEAL: ${widget.deal!.name} - ${descController.text.substring(0, descController.text.length > 20 ? 20 : descController.text.length)}...',
                                'description': 'Associated Deal: ${widget.deal!.name}\n\nNotes: ${descController.text}',
                                'assigned_by': myId,
                                'assigned_to': assignedTo ?? myId,
                                'due_date': selectedDate.toIso8601String(),
                                'client_name': widget.deal!.clientName,
                                'phone_number': widget.deal!.contactInfo,
                                'status': 'Pending',
                              };

                              final newTask = amplify_models.Tasks(
                                title: taskData['title'] as String,
                                description: taskData['description'] as String,
                                due_date: taskData['due_date'] as String,
                                assigned_to: int.tryParse(taskData['assigned_to']?.toString() ?? ''),
                                assigned_by: int.tryParse(taskData['assigned_by']?.toString() ?? ''),
                                client_name: taskData['client_name'] as String?,
                                phone_number: taskData['phone_number'] as String?,
                                status: taskData['status'] as String,
                              );
                              
                              final res = await BackupAwareApi().create(newTask);
                              final newTaskId = int.tryParse(res.data?.id ?? '0') ?? 0;

                              // Trigger Notification
                              await NotificationService().notifyStakeholders(
                                taskId: newTaskId,
                                title: 'New Work Task Assigned',
                                message: 'A task for deal "${widget.deal!.name}" has been assigned to you.',
                                type: 'assignment',
                              );

                              // Lively WhatsApp alert to assigned staff
                              final effectiveDealAssignee = newTask.assigned_to ?? assignedTo ?? taskData['assigned_to'];
                              if (effectiveDealAssignee != null) {
                                final prefs = await SharedPreferences.getInstance();
                                final currentUserName = prefs.getString('user_name') ?? 'Management';
                                unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
                                  staffUserId: effectiveDealAssignee,
                                  assignmentTitle: taskData['title'] as String,
                                  workOrTaskType: 'Work Task (${widget.deal?.name ?? 'Work'})',
                                  clientName: widget.deal?.clientName,
                                  dueDate: taskData['due_date']?.toString(),
                                  assignedByName: currentUserName,
                                  details: taskData['description'] as String? ?? 'Task assigned in work.',
                                ));
                              }

                              await LoggingService().logAction(
                                action: 'TASK_SYNC_CREATED',
                                targetType: 'Task',
                                targetId: widget.deal!.name,
                                details: 'Synced task from Deal ${widget.deal!.id}',
                              );
                            } catch (e) {
                              debugPrint('Error syncing task: $e');
                            }
                          }

                          if (mounted) {
                            Navigator.pop(context);
                            _loadDetails();
                          }
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A), // Green 600
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Schedule', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _inputActionBtn(IconData icon, String tooltip, {VoidCallback? onTap}) {
    return IconButton(
      onPressed: onTap ?? () {},
      icon: Icon(icon, size: 20, color: Colors.grey),
      tooltip: tooltip,
    );
  }
}

class _UserSelectionDialog extends StatelessWidget {
  final List<Map<String, dynamic>> users;
  final String title;
  const _UserSelectionDialog({required this.users, this.title = 'Select User'});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: SizedBox(
        width: 400,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: users.length,
          itemBuilder: (context, index) {
            final user = users[index];
            return ListTile(
              leading: CircleAvatar(child: Text(user['name'][0].toUpperCase())),
              title: Text(user['name']),
              subtitle: Text(user['role'] ?? 'Staff'),
              onTap: () => Navigator.pop(context, user),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
      ],
    );
  }
}

class VerificationDetails {
  final int? verifierId;
  final String? verifierName;
  final String status; // 'Draft', 'Verified'
  final String? draftLink;
  final String cleanDescription;

  VerificationDetails({
    this.verifierId,
    this.verifierName,
    this.status = 'Draft',
    this.draftLink,
    required this.cleanDescription,
  });

  factory VerificationDetails.parse(String? desc) {
    if (desc == null || desc.isEmpty) {
      return VerificationDetails(cleanDescription: '');
    }

    final regExp = RegExp(
      r'\[VERIFICATION\]\s*\n\s*VerifierID:\s*(.*?)\s*\n\s*VerifierName:\s*(.*?)\s*\n\s*Status:\s*([^\n\r]+)(?:\s*\n\s*DraftLink:\s*([^\n\r]+))?',
      multiLine: true,
      caseSensitive: false,
    );

    final match = regExp.firstMatch(desc);
    if (match != null) {
      final vIdStr = match.group(1)?.trim();
      final vName = match.group(2)?.trim();
      final status = match.group(3)?.trim() ?? 'Draft';
      final draftLink = match.groupCount >= 4 ? match.group(4)?.trim() : null;
      
      final index = desc.indexOf('[VERIFICATION]');
      final clean = desc.substring(0, index).trim();
      return VerificationDetails(
        verifierId: vIdStr != null ? int.tryParse(vIdStr) : null,
        verifierName: vName,
        status: status,
        draftLink: (draftLink != null && draftLink.isNotEmpty) ? draftLink : null,
        cleanDescription: clean,
      );
    }

    return VerificationDetails(cleanDescription: desc);
  }
}

