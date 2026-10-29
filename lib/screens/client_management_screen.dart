import 'package:amplify_api/amplify_api.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../theme.dart';
import '../models/client.dart';
import '../services/excel_service.dart';
import '../services/logging_service.dart';
import '../services/billing_service.dart';
import '../models/billing.dart';
import 'client_files_dialog.dart';
import 'client_merge_dialog.dart';
import 'global_merge_dialog.dart';
import '../models/deal.dart';
import 'deal_detail_screen.dart';
import '../services/auth_service.dart';
import '../services/supabase_backup_service.dart';

class ClientManagementScreen extends StatefulWidget {
  const ClientManagementScreen({super.key});

  @override
  State<ClientManagementScreen> createState() => _ClientManagementScreenState();
}

class _ClientManagementScreenState extends State<ClientManagementScreen> {
  final _excel = ExcelService();
  final _auth = AuthService();
  static final DateTime nov1Cutoff = DateTime(2026, 11, 1);
  String _selectedPeriod = '2026-2027'; // Starts fresh from Nov 1, 2026
  List<Client> _clients = [];
  List<amplify_models.Clients> _rawClients = [];
  bool _isLoading = true;
  bool _isAdmin = false;
  String _searchTerm = '';
  String _currentSort = 'Name (A-Z)';

  DateTime _getClientDate(Client c) {
    if (c.createdAt != null && c.createdAt!.isNotEmpty) {
      final parsed = DateTime.tryParse(c.createdAt!);
      if (parsed != null) return parsed.toLocal();
    }
    return DateTime(2000);
  }

  bool _phoneNumbersMatch(String? p1, String? p2) {
    if (p1 == null || p2 == null) return false;
    final list1 = p1
        .split(RegExp(r'[,/|]'))
        .map((p) => p.replaceAll(RegExp(r'\D'), ''))
        .where((p) => p.length >= 7)
        .toList();
    final list2 = p2
        .split(RegExp(r'[,/|]'))
        .map((p) => p.replaceAll(RegExp(r'\D'), ''))
        .where((p) => p.length >= 7)
        .toList();

    for (var n1 in list1) {
      for (var n2 in list2) {
        if (n1 == n2) return true;
        final s1 = n1.length >= 10 ? n1.substring(n1.length - 10) : n1;
        final s2 = n2.length >= 10 ? n2.substring(n2.length - 10) : n2;
        if (s1 == s2) return true;
      }
    }
    return false;
  }

  int get _count2025_2026 => _clients.where((c) => _getClientDate(c).isBefore(nov1Cutoff)).length;
  int get _count2026_2027 => _clients.where((c) => !_getClientDate(c).isBefore(nov1Cutoff)).length;
  int get _countAll => _clients.length;

  void _applySort() {
    switch (_currentSort) {
      case 'Name (A-Z)':
        _clients.sort((a, b) => a.name.trim().toLowerCase().compareTo(b.name.trim().toLowerCase()));
        break;
      case 'Name (Z-A)':
        _clients.sort((a, b) => b.name.trim().toLowerCase().compareTo(a.name.trim().toLowerCase()));
        break;
      case 'Due (High-Low)':
        _clients.sort((a, b) => _parseDue(b.balanceDue).compareTo(_parseDue(a.balanceDue)));
        break;
    }
  }

  double _parseDue(String? due) {
    if (due == null || due.isEmpty) return 0.0;
    final clean = due.replaceAll(RegExp(r'[^\d.]'), '');
    return double.tryParse(clean) ?? 0.0;
  }

  @override
  void initState() {
    super.initState();
    _fetchClients();
  }

  Future<void> _fetchClients() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    _isAdmin = await _auth.isAdmin();
    
    try {
      final req = ModelQueries.list(amplify_models.Clients.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      var clientsList = (res.data?.items ?? []).whereType<amplify_models.Clients>().toList();
      
      int maxRegNo = 0;
      for (var c in clientsList) {
        if (c.case_number != null && c.case_number!.startsWith('CUC-')) {
          final match = RegExp(r'\d+').firstMatch(c.case_number!);
          if (match != null) {
            final num = int.tryParse(match.group(0)!) ?? 0;
            if (num > maxRegNo) maxRegNo = num;
          }
        }
      }

      var unassignedClients = clientsList.where((c) => c.case_number == null || !c.case_number!.startsWith('CUC-')).toList();
      if (unassignedClients.isNotEmpty) {
        unassignedClients.sort((a, b) => (a.createdAt?.toString() ?? '').compareTo(b.createdAt?.toString() ?? ''));
        for (var c in unassignedClients) {
          maxRegNo++;
          final newRegNo = 'CUC-${maxRegNo.toString().padLeft(4, '0')}';
          final updated = c.copyWith(case_number: newRegNo);
          await BackupAwareApi().update(updated);
          final index = clientsList.indexWhere((element) => element.id == c.id);
          if (index != -1) clientsList[index] = updated;
        }
      }

      final reqLogs = ModelQueries.list(amplify_models.ActivityLogs.classType, where: amplify_models.ActivityLogs.ACTION.eq('CLIENT_CREATED'), limit: 10000);
      final resLogs = await Amplify.API.query(request: reqLogs).response;
      final logsList = resLogs.data?.items.whereType<amplify_models.ActivityLogs>().toList() ?? [];

      final reqUsers = ModelQueries.list(amplify_models.Users.classType, limit: 10000);
      final resUsers = await Amplify.API.query(request: reqUsers).response;
      final usersList = resUsers.data?.items.whereType<amplify_models.Users>().toList() ?? [];

      final Map<int, String> userNames = {};
      try {
        final sbMap = await SupabaseBackupService().getUsernameToIdMap();
        for (var u in usersList) {
          final uName = u.username?.toLowerCase() ?? '';
          if (sbMap.containsKey(uName)) {
            userNames[sbMap[uName]!] = u.name ?? uName;
          }
        }
      } catch (e) {
        debugPrint('Failed to get Supabase ID map: $e');
      }

      final Map<String, String> clientCreators = {};
      for (var log in logsList) {
        if (log.target_id != null && log.user_id != null) {
          clientCreators[log.target_id!] = userNames[log.user_id!] ?? 'Unknown';
        }
      }

      clientsList.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      print('DEBUG: ActivityLogs CLIENT_CREATED count: ${logsList.length}');
      print('DEBUG: userNames mapping: $userNames');
      print('DEBUG: clientCreators mapping: $clientCreators');
      if (!mounted) return;
      setState(() {
        _rawClients = clientsList;
        _clients = clientsList.map((m) {
          final mappedCreator = clientCreators[m.id] ?? clientCreators[m.name ?? ''] ?? 'System/Legacy';
          print('DEBUG: Client ${m.name} (${m.id}) mapped to creator: $mappedCreator');
          return Client(
            id: m.id,
            name: m.name ?? '',
            email: m.email,
            phone: m.phone,
            address: (m.address?.trim().toLowerCase() == 'false') ? '' : m.address,
            typeOfWork: m.type_of_work,
            caseNumber: m.case_number,
            dob: m.dob,
            fileNo: m.file_no,
            fileDate: m.file_date,
            isContacted: m.is_contacted ?? false,
            balanceDue: m.balance_due,
            registrationNumber: m.case_number,
            createdBy: mappedCreator,
            createdAt: (m.created_at != null && m.created_at!.isNotEmpty) ? m.created_at : m.createdAt?.format(),
          );
        }).toList();
        _applySort();
      });
    } catch (e) {
      _showError('Failed to fetch clients: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showMergeDialog(Client client) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) => ClientMergeDialog(
        primaryClient: client,
        allClients: _clients,
        onMerged: () {
          _fetchClients();
        },
      ),
    );
  }

  void _showGlobalMergeDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) => GlobalMergeDialog(
        allClients: _clients,
        onMerged: () {
          _fetchClients();
        },
      ),
    );
  }

  Future<void> _importSingleClientToCurrent(Client client, {bool skipConfirmation = false}) async {
    if (!skipConfirmation) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.drive_file_move_rounded, color: Color(0xFF10B981)),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Import Client to Current?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          content: Text(
            'Do you want to import client "${client.name}" into the current period (2026-2027)?\n\nThe client record will be carried forward to start from the current period.',
            style: const TextStyle(fontSize: 14, color: Color(0xFF334155)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.drive_file_move_rounded, size: 16),
              label: const Text('Import to 2026-2027'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      );

      if (confirm != true) return;
    }

    setState(() => _isLoading = true);
    try {
      final targetDate = DateTime.now().isBefore(nov1Cutoff)
          ? DateTime(2026, 11, 1, 0, 0, 1)
          : DateTime.now();
      final targetDateStr = targetDate.toIso8601String();

      final raw = _rawClients.where((m) => m.id == client.id).firstOrNull;
      if (raw != null) {
        final updated = raw.copyWith(created_at: targetDateStr);
        await BackupAwareApi().update(updated);
      } else {
        final model = amplify_models.Clients(
          id: client.id,
          name: client.name,
          email: client.email,
          phone: client.phone,
          address: client.address,
          type_of_work: client.typeOfWork,
          file_no: client.fileNo,
          file_date: client.fileDate,
          is_contacted: client.isContacted,
          dob: client.dob,
          managed_by: client.managedBy,
          case_number: client.registrationNumber,
          companies: client.companies,
          custom_fields: client.customFields,
          created_at: targetDateStr,
        );
        await BackupAwareApi().update(model);
      }

      await LoggingService().logAction(
        action: 'CLIENT_IMPORTED',
        targetType: 'Client',
        targetId: client.name,
        details: 'Imported client "${client.name}" to 2026-2027 period',
      );

      if (mounted) {
        _showSuccess('Successfully imported "${client.name}" to 2026-2027!');
        setState(() {
          _selectedPeriod = '2026-2027';
        });
        await _fetchClients();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showError('Error importing client: $e');
      }
    }
  }

  Future<void> _showImportToCurrentDialog() async {
    final candidates = _clients.where((c) => _getClientDate(c).isBefore(nov1Cutoff)).toList();
    if (candidates.isEmpty) {
      _showError('No 2025-2026 clients available to import.');
      return;
    }

    final searchCtrl = TextEditingController();
    final selectedIds = <dynamic>{};
    bool isImporting = false;
    int importedCount = 0;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final query = searchCtrl.text.toLowerCase().trim();
          final displayed = query.isEmpty
              ? candidates
              : candidates.where((c) =>
                  c.name.toLowerCase().contains(query) ||
                  (c.phone?.toLowerCase().contains(query) ?? false) ||
                  (c.fileNo?.toLowerCase().contains(query) ?? false) ||
                  (c.registrationNumber?.toLowerCase().contains(query) ?? false)
                ).toList();

          final allDisplayedSelected = displayed.isNotEmpty && displayed.every((c) => selectedIds.contains(c.id));

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            backgroundColor: Colors.white,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.drive_file_move_rounded, color: Color(0xFF10B981), size: 24),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Import Clients to Current',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Select clients from 2025-2026 to carry forward into 2026-2027',
                                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: isImporting ? null : () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: searchCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Search by client name, phone, or file no...',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF10B981))),
                        fillColor: const Color(0xFFF8FAFC),
                        filled: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          '${selectedIds.length} selected of ${candidates.length} clients',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: isImporting
                              ? null
                              : () {
                                  setDialogState(() {
                                    if (allDisplayedSelected) {
                                      for (var c in displayed) {
                                        selectedIds.remove(c.id);
                                      }
                                    } else {
                                      for (var c in displayed) {
                                        if (c.id != null) selectedIds.add(c.id);
                                      }
                                    }
                                  });
                                },
                          child: Text(
                            allDisplayedSelected ? 'Deselect All' : 'Select All',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    Expanded(
                      child: displayed.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.person_off_rounded, size: 40, color: Colors.grey.shade300),
                                  const SizedBox(height: 8),
                                  Text('No matching clients found', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                                ],
                              ),
                            )
                          : ListView.separated(
                              itemCount: displayed.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 6),
                              itemBuilder: (context, i) {
                                final c = displayed[i];
                                final isChecked = selectedIds.contains(c.id);
                                final date = _getClientDate(c);
                                final dateStr = '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
                                return Material(
                                  color: isChecked ? const Color(0xFF10B981).withValues(alpha: 0.08) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    onTap: isImporting
                                        ? null
                                        : () {
                                            setDialogState(() {
                                              if (isChecked) {
                                                selectedIds.remove(c.id);
                                              } else {
                                                if (c.id != null) selectedIds.add(c.id);
                                              }
                                            });
                                          },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      child: Row(
                                        children: [
                                          Checkbox(
                                            value: isChecked,
                                            activeColor: const Color(0xFF10B981),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                            onChanged: isImporting
                                                ? null
                                                : (val) {
                                                    setDialogState(() {
                                                      if (val == true) {
                                                        if (c.id != null) selectedIds.add(c.id);
                                                      } else {
                                                        selectedIds.remove(c.id);
                                                      }
                                                    });
                                                  },
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  c.name,
                                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B)),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  '${c.phone?.isNotEmpty == true ? c.phone! : "No Phone"}${c.fileNo?.isNotEmpty == true ? " • File: ${c.fileNo}" : ""}${c.registrationNumber?.isNotEmpty == true ? " • Reg: ${c.registrationNumber}" : ""} • Date: $dateStr',
                                                  style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 16),
                    if (isImporting)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF10B981))),
                            const SizedBox(width: 12),
                            Text('Importing $importedCount of ${selectedIds.length}...', style: const TextStyle(fontSize: 13, color: Color(0xFF475569))),
                          ],
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: isImporting ? null : () => Navigator.pop(ctx),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: (selectedIds.isEmpty || isImporting)
                              ? null
                              : () async {
                                  setDialogState(() {
                                    isImporting = true;
                                    importedCount = 0;
                                  });

                                  final targetDate = DateTime.now().isBefore(nov1Cutoff)
                                      ? DateTime(2026, 11, 1, 0, 0, 1)
                                      : DateTime.now();
                                  final targetDateStr = targetDate.toIso8601String();

                                  for (final id in selectedIds) {
                                    final match = candidates.firstWhereOrNull((c) => c.id == id);
                                    if (match != null) {
                                      try {
                                        final raw = _rawClients.where((m) => m.id == match.id).firstOrNull;
                                        if (raw != null) {
                                          final updated = raw.copyWith(created_at: targetDateStr);
                                          await BackupAwareApi().update(updated);
                                        } else {
                                          final model = amplify_models.Clients(
                                            id: match.id,
                                            name: match.name,
                                            email: match.email,
                                            phone: match.phone,
                                            address: match.address,
                                            type_of_work: match.typeOfWork,
                                            file_no: match.fileNo,
                                            file_date: match.fileDate,
                                            is_contacted: match.isContacted,
                                            dob: match.dob,
                                            managed_by: match.managedBy,
                                            case_number: match.registrationNumber,
                                            companies: match.companies,
                                            custom_fields: match.customFields,
                                            created_at: targetDateStr,
                                          );
                                          await BackupAwareApi().update(model);
                                        }
                                        await LoggingService().logAction(
                                          action: 'CLIENT_IMPORTED',
                                          targetType: 'Client',
                                          targetId: match.name,
                                          details: 'Imported client "${match.name}" to 2026-2027 period',
                                        );
                                      } catch (e) {
                                        debugPrint('Error importing client ${match.name}: $e');
                                      }
                                    }
                                    setDialogState(() {
                                      importedCount++;
                                    });
                                  }

                                  if (ctx.mounted) Navigator.pop(ctx);

                                  if (mounted) {
                                    setState(() {
                                      _selectedPeriod = '2026-2027';
                                    });
                                    await _fetchClients();
                                    if (!mounted) return;
                                    _showSuccess('Successfully imported ${selectedIds.length} client(s) into 2026-2027!');
                                  }
                                },
                          icon: const Icon(Icons.drive_file_move_rounded, size: 18),
                          label: Text(
                            selectedIds.isEmpty ? 'Select Clients to Import' : 'Import (${selectedIds.length})',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showClientWorksDialog(Client c) async {
    try {
      // Fetch all deals with a high limit to avoid pagination missing the client's works
      final req = ModelQueries.list(amplify_models.Deals.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      var deals = res.data?.items.whereType<amplify_models.Deals>().toList() ?? [];

      // Filter out unpassed CRM leads so only passed ones come in client works
      deals = deals.where((d) {
        final isCrm = (d.pipeline ?? '').toLowerCase() == 'crm' || (d.pipeline ?? '').toLowerCase() == 'lead';
        if (isCrm && d.is_won != true) return false;
        return true;
      }).toList();

      final cNameLower = c.name.toLowerCase().trim();
      final cIdStr = c.id?.toString();
      
      deals = deals.where((d) {
        final dNameLower = (d.client_name ?? '').toLowerCase().trim();
        final dIdStr = d.client_id?.toString();
        
        // Match by ID first, then fallback to flexible Name matching
        if (cIdStr != null && dIdStr != null && cIdStr == dIdStr) return true;
        if (cNameLower.isEmpty) return false;
        
        return dNameLower == cNameLower || 
               dNameLower.startsWith(cNameLower) || 
               cNameLower.startsWith(dNameLower);
      }).toList();

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: Colors.transparent,
          child: Container(
            width: 650,
            constraints: const BoxConstraints(maxHeight: 700),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 30, offset: const Offset(0, 15)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [AppTheme.primaryColor, AppTheme.primaryColor.withValues(alpha: 0.8)]),
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                        child: const Icon(Icons.work_history_rounded, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Works for ${c.name}',
                              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Manage deals and tasks for this client',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4, offset: const Offset(0, 2))],
                        ),
                        child: Text('${deals.length} Total', style: TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                // Content
                Flexible(
                  child: deals.isEmpty 
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
                              child: Icon(Icons.inbox_rounded, size: 64, color: Colors.grey.shade400),
                            ),
                            const SizedBox(height: 20),
                            Text('No Works Found', style: TextStyle(fontSize: 20, color: Colors.grey.shade800, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Text('Get started by adding a new work for this client.', style: TextStyle(color: Colors.grey.shade600)),
                          ].animate(interval: 50.ms).fadeIn(duration: 400.ms).slideY(begin: 0.2),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(24),
                        itemCount: deals.length,
                        itemBuilder: (context, index) {
                          final d = deals[index];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.grey.shade200),
                              boxShadow: [
                                BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))
                              ]
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () {
                                  Navigator.pop(context);
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (context) => DealDetailScreen(deal: Deal.fromMap(d.toJson()))),
                                  ).then((_) => _showClientWorksDialog(c));
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(20.0),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                                        child: Icon(Icons.assignment_turned_in_rounded, color: AppTheme.primaryColor),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(d.name ?? 'Unnamed Work', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: Colors.black87)),
                                            const SizedBox(height: 12),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                  decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                                                  child: Text('Stage: ${d.stage ?? "N/A"}', style: const TextStyle(color: Colors.blue, fontSize: 12, fontWeight: FontWeight.w600)),
                                                ),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                  decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                                                  child: Text('Type: ${d.work_type ?? "N/A"}', style: const TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.w600)),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          const Text('Amount', style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w600)),
                                          const SizedBox(height: 4),
                                          Text('₹${d.amount ?? 0}', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w900, fontSize: 18)),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ).animate().fadeIn(delay: (index * 40).ms, duration: 400.ms).slideX(begin: 0.1, curve: Curves.easeOut);
                        }
                      ),
                ),
                // Footer
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(24), bottomRight: Radius.circular(24)),
                    border: Border(top: BorderSide(color: Colors.grey.shade200)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context), 
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text('Close', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey.shade700, fontSize: 15)),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => DealDetailScreen(
                                deal: Deal(
                                  name: 'New Work for ${c.name}',
                                  clientName: c.name,
                                  clientId: c.id,
                                  contactInfo: c.phone,
                                  company: c.companies != null && c.companies!.isNotEmpty ? c.companies!.first : null,
                                  workType: c.typeOfWork,
                                  stage: 'Lead',
                                ),
                              ),
                            ),
                          ).then((_) => _showClientWorksDialog(c));
                        },
                        icon: const Icon(Icons.add_rounded, size: 22, color: Colors.white),
                        label: const Text('Add Work', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor, 
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      _showError('Failed to load works: $e');
    }
  }

  Future<void> _deleteClient(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: const Text('Are you sure you want to delete this client?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await BackupAwareApi().deleteById(amplify_models.Clients.classType, amplify_models.ClientsModelIdentifier(id: id));
        _fetchClients();
      } catch (e) {
        _showError('Delete failed: $e');
      }
    }
  }

  Future<void> _exportToExcel() async {
    try {
      final clientMaps = _clients.map((c) => c.toMap()).toList();
      final path = await _excel.exportClients(clientMaps);
      if (path != null) {
        _showSuccess('Exported successfully to $path');
      }
    } catch (e) {
      _showError('Export failed: $e');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.redAccent));
  }

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.green));
  }

  void _showClientFilesDialog(Client client) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) => ClientFilesDialog(client: client),
    );
  }

  void _showClientBillsDialog(Client client) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) => _ClientBillsDialog(client: client),
    );
  }

  void _showClientForm([Client? client]) {
    final nameController = TextEditingController(text: client?.name);
    final emailController = TextEditingController(text: client?.email);
    List<TextEditingController> phoneControllers = (client?.phone ?? '').split(',').map((p) => TextEditingController(text: p.trim())).toList();
    if (phoneControllers.isEmpty || (phoneControllers.length == 1 && phoneControllers[0].text.isEmpty)) {
      phoneControllers = [TextEditingController()];
    }
    final workController = TextEditingController(text: client?.typeOfWork);
    final fileNoController = TextEditingController(text: client?.fileNo);
    final fileDateController = TextEditingController(text: client?.fileDate ?? DateFormat('dd/MM/yyyy').format(DateTime.now()));
    final dobController = TextEditingController(text: client?.dob);
    final careOfController = TextEditingController(text: client?.managedBy);

    Future<void> pickDate(BuildContext ctx, TextEditingController controller) async {
      final date = await showDatePicker(
        context: ctx,
        initialDate: DateTime.now(),
        firstDate: DateTime(1900),
        lastDate: DateTime(2100),
      );
      if (date != null) {
        controller.text = DateFormat('dd/MM/yyyy').format(date);
      }
    }
    final addressController = TextEditingController(text: client?.address);
    bool isContacted = client?.isContacted ?? false;
    List<Map<String, TextEditingController>> companyControllers = (client?.companies ?? []).map((c) {
      String name = c;
      String address = '';
      String phone = '';
      if (c.contains('|||')) {
        final parts = c.split('|||');
        name = parts[0];
        if (parts.length > 1) address = parts[1];
        if (parts.length > 2) phone = parts[2];
      }
      return {'name': TextEditingController(text: name), 'address': TextEditingController(text: address), 'phone': TextEditingController(text: phone)};
    }).toList();

    List<Map<String, TextEditingController>> customFieldControllers = (client?.customFields ?? []).map((c) {
      String name = '';
      String value = '';
      if (c.contains(':')) {
        final parts = c.split(':');
        name = parts.first.trim();
        if (parts.length > 1) value = parts.sublist(1).join(':').trim();
      } else {
        name = c;
      }
      return {'name': TextEditingController(text: name), 'value': TextEditingController(text: value)};
    }).toList();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
        final current2025Match = client == null ? () {
          final enteredPhones = phoneControllers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).join(', ');
          if (enteredPhones.isEmpty) return null;
          for (var c in _clients) {
            if (_getClientDate(c).isBefore(nov1Cutoff)) {
              if (_phoneNumbersMatch(enteredPhones, c.phone)) {
                return c;
              }
            }
          }
          return null;
        }() : null;

        Widget build2025MatchBanner(Client match) {
          return Container(
            margin: const EdgeInsets.only(top: 8, bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF6EE7B7)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFF059669)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Client already exists in 2025-2026',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF065F46)),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('2025-2026', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '"${match.name}" (Phone: ${match.phone ?? "N/A"}${match.fileNo != null && match.fileNo!.isNotEmpty ? ", File: ${match.fileNo}" : ""}) is registered in 2025-2026.',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF047857)),
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(context); // close modal
                    await _importSingleClientToCurrent(match, skipConfirmation: true);
                    _showClientForm(match);
                  },
                  icon: const Icon(Icons.drive_file_move_rounded, size: 15),
                  label: const Text('Import to Current (2026-2027)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                ),
              ],
            ),
          );
        }

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 600;
              return Container(
                constraints: const BoxConstraints(maxWidth: 700),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 24, offset: Offset(0, 12))],
                ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(40),
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(client == null ? Icons.person_add : Icons.edit, color: AppTheme.primaryColor, size: 28),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(client == null ? 'Add New Client' : 'Edit Client Profile', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                              const Text("Enter client details and work information", style: TextStyle(color: AppTheme.mutedTextColor)),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () => Navigator.pop(context),
                          splashRadius: 24,
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    _buildFormField(nameController, 'Full Name', Icons.person, true),
                    const SizedBox(height: 20),
                    isWide ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildFormField(emailController, 'Email Address', Icons.email, false)),
                        const SizedBox(width: 20),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...phoneControllers.asMap().entries.map((e) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  Expanded(child: _buildFormField(
                                    e.value,
                                    'Phone Number',
                                    Icons.phone,
                                    e.key == 0,
                                    onChanged: (_) => setModalState(() {}),
                                  )),
                                  if (e.key > 0)
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                                      onPressed: () => setModalState(() => phoneControllers.removeAt(e.key))
                                    )
                                ]
                              )
                            )),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => setModalState(() => phoneControllers.add(TextEditingController())),
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text('Add Phone Number'),
                              ),
                            ),
                            if (current2025Match != null) build2025MatchBanner(current2025Match),
                          ]
                        )),
                      ],
                    ) : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildFormField(emailController, 'Email Address', Icons.email, false),
                        const SizedBox(height: 20),
                        ...phoneControllers.asMap().entries.map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(child: _buildFormField(
                                e.value,
                                'Phone Number',
                                Icons.phone,
                                e.key == 0,
                                onChanged: (_) => setModalState(() {}),
                              )),
                              if (e.key > 0)
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                                  onPressed: () => setModalState(() => phoneControllers.removeAt(e.key))
                                )
                            ]
                          )
                        )),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => setModalState(() => phoneControllers.add(TextEditingController())),
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add Phone Number'),
                          ),
                        ),
                        if (current2025Match != null) build2025MatchBanner(current2025Match),
                      ],
                    ),
                    const SizedBox(height: 20),
                    isWide ? Row(
                      children: [
                        Expanded(child: _buildFormField(workController, 'Type of Work', Icons.work, false)),
                        const SizedBox(width: 20),
                        Expanded(child: _buildFormField(fileNoController, 'File Number', Icons.folder, false)),
                      ],
                    ) : Column(
                      children: [
                        _buildFormField(workController, 'Type of Work', Icons.work, false),
                        const SizedBox(height: 20),
                        _buildFormField(fileNoController, 'File Number', Icons.folder, false),
                      ],
                    ),
                    const SizedBox(height: 20),
                    isWide ? Row(
                      children: [
                        Expanded(child: _buildFormField(fileDateController, 'File Date', Icons.calendar_today, false, onTap: () => pickDate(context, fileDateController))),
                        const SizedBox(width: 20),
                        Expanded(child: _buildFormField(dobController, 'Date of Birth', Icons.cake, false, onTap: () => pickDate(context, dobController))),
                      ],
                    ) : Column(
                      children: [
                        _buildFormField(fileDateController, 'File Date', Icons.calendar_today, false, onTap: () => pickDate(context, fileDateController)),
                        const SizedBox(height: 20),
                        _buildFormField(dobController, 'Date of Birth', Icons.cake, false, onTap: () => pickDate(context, dobController)),
                      ],
                    ),
                    const SizedBox(height: 20),
                    isWide ? Row(
                      children: [
                        Expanded(child: _buildFormField(careOfController, 'Care Of', Icons.supervised_user_circle, false)),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: CheckboxListTile(
                                title: const Text('Contacted?', style: TextStyle(fontWeight: FontWeight.w500)),
                                value: isContacted,
                                activeColor: AppTheme.primaryColor,
                                onChanged: (val) => setModalState(() => isContacted = val ?? false),
                                controlAffinity: ListTileControlAffinity.leading,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        const Spacer(), // Balance layout if needed
                      ],
                    ) : Column(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: CheckboxListTile(
                              title: const Text('Contacted?', style: TextStyle(fontWeight: FontWeight.w500)),
                              value: isContacted,
                              activeColor: AppTheme.primaryColor,
                              onChanged: (val) => setModalState(() => isContacted = val ?? false),
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _buildFormField(addressController, 'Full Address', Icons.location_on, false, maxLines: 2),
                    const SizedBox(height: 20),
                    const Text('Companies', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
                    const SizedBox(height: 12),
                    ...companyControllers.asMap().entries.map((e) {
                      int idx = e.key;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  _buildFormField(e.value['name']!, 'Company Name', Icons.business, false),
                                  const SizedBox(height: 8),
                                  _buildFormField(e.value['address']!, 'Company Address', Icons.location_on, false, maxLines: 2),
                                  const SizedBox(height: 8),
                                  _buildFormField(e.value['phone']!, 'Company Phone Number', Icons.phone, false),
                                ]
                              )
                            ),
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                              onPressed: () {
                                setModalState(() {
                                  companyControllers.removeAt(idx);
                                });
                              }
                            )
                          ]
                        )
                      );
                    }),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () {
                          setModalState(() {
                            companyControllers.add({'name': TextEditingController(), 'address': TextEditingController(), 'phone': TextEditingController()});
                          });
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Add Company'),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('Custom Fields', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
                    const SizedBox(height: 12),
                    ...customFieldControllers.asMap().entries.map((e) {
                      int idx = e.key;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  _buildFormField(e.value['name']!, 'Field Name (e.g. GSTIN)', Icons.label_outline, false),
                                  const SizedBox(height: 8),
                                  _buildFormField(e.value['value']!, 'Field Value', Icons.text_fields, false),
                                ]
                              )
                            ),
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                              onPressed: () {
                                setModalState(() {
                                  customFieldControllers.removeAt(idx);
                                });
                              }
                            )
                          ]
                        )
                      );
                    }),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () {
                          setModalState(() {
                            customFieldControllers.add({'name': TextEditingController(), 'value': TextEditingController()});
                          });
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Add Custom Field'),
                      ),
                    ),
                    const SizedBox(height: 40),
                    ElevatedButton(
                      onPressed: () async {
                        if (!formKey.currentState!.validate()) return;

                        if (client == null) {
                          final newName = nameController.text.trim().toLowerCase();
                          final newPhoneStr = phoneControllers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).join(', ');
                          
                          // 1. Check if client with this phone number already exists in 2025-2026
                          Client? existing2025Client;
                          if (newPhoneStr.isNotEmpty) {
                            for (var c in _clients) {
                              if (_getClientDate(c).isBefore(nov1Cutoff)) {
                                if (_phoneNumbersMatch(newPhoneStr, c.phone)) {
                                  existing2025Client = c;
                                  break;
                                }
                              }
                            }
                          }

                          if (existing2025Client != null) {
                            final action = await showDialog<String>(
                              context: context,
                              barrierDismissible: false,
                              builder: (ctx) => AlertDialog(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                title: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF10B981).withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Icon(Icons.drive_file_move_rounded, color: Color(0xFF10B981), size: 24),
                                    ),
                                    const SizedBox(width: 12),
                                    const Expanded(
                                      child: Text(
                                        'Client Already Exists in 2025-2026',
                                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF8FAFC),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: const Color(0xFFE2E8F0)),
                                      ),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 18,
                                            backgroundColor: const Color(0xFF10B981),
                                            child: Text(
                                              existing2025Client!.name.isNotEmpty ? existing2025Client.name[0].toUpperCase() : '?',
                                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  existing2025Client.name,
                                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                                ),
                                                Text(
                                                  '📞 ${existing2025Client.phone ?? "No Phone"}',
                                                  style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                                                ),
                                                if (existing2025Client.fileNo != null && existing2025Client.fileNo!.isNotEmpty)
                                                  Text(
                                                    '📁 File No: ${existing2025Client.fileNo}',
                                                    style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.amber.shade100,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: const Text('2025-2026', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    const Text(
                                      'A client with this phone number already exists in 2025-2026.\n\nPlease import this client into the current period (2026-2027) instead of creating a duplicate record.',
                                      style: TextStyle(fontSize: 13, color: Color(0xFF334155), height: 1.4),
                                    ),
                                  ],
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, 'cancel'),
                                    child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, 'create_anyway'),
                                    child: const Text('Create New Anyway', style: TextStyle(color: Colors.orange)),
                                  ),
                                  ElevatedButton.icon(
                                    onPressed: () => Navigator.pop(ctx, 'import'),
                                    icon: const Icon(Icons.drive_file_move_rounded, size: 16),
                                    label: const Text('Import Client to Current'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF10B981),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ],
                              ),
                            );

                            if (action == 'cancel' || action == null) return;

                            if (action == 'import') {
                              if (context.mounted) Navigator.pop(context); // close new client form
                              await _importSingleClientToCurrent(existing2025Client, skipConfirmation: true);
                              _showClientForm(existing2025Client);
                              return;
                            }
                          } else {
                            // 2. Check if client already exists in current period (2026-2027)
                            Client? existingCurrentClient;
                            for (var c in _clients) {
                              if (!_getClientDate(c).isBefore(nov1Cutoff)) {
                                if ((newName.isNotEmpty && c.name.trim().toLowerCase() == newName) || 
                                    (newPhoneStr.isNotEmpty && _phoneNumbersMatch(newPhoneStr, c.phone))) {
                                  existingCurrentClient = c;
                                  break;
                                }
                              }
                            }
                            
                            if (existingCurrentClient != null) {
                              final action = await showDialog<String>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Client Already Exists in Current Period'),
                                  content: Text('A client with the name "${existingCurrentClient!.name}" or phone "${existingCurrentClient.phone}" already exists in 2026-2027.\n\nDo you want to create a new client anyway or open the existing one?'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
                                    TextButton(onPressed: () => Navigator.pop(ctx, 'create'), child: const Text('Create New')),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(ctx, 'open'),
                                      style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white),
                                      child: const Text('Open Existing'),
                                    ),
                                  ],
                                ),
                              );
                              
                              if (action == 'cancel' || action == null) return;
                              
                              if (action == 'open') {
                                if (context.mounted) Navigator.pop(context); // close new client form
                                _showClientForm(existingCurrentClient); // open existing client form
                                return;
                              }
                            }
                          }
                        }

                        final newClient = Client(
                          id: client?.id,
                          name: nameController.text,
                          email: emailController.text,
                          phone: phoneControllers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).join(', '),
                          address: addressController.text,
                          typeOfWork: workController.text,
                          fileDate: fileDateController.text,
                          fileNo: fileNoController.text,
                          isContacted: isContacted,
                          dob: dobController.text,
                          managedBy: careOfController.text,
                          balanceDue: client?.balanceDue,
                          registrationNumber: client?.registrationNumber,
                          companies: companyControllers.map((c) {
                            final name = c['name']!.text.trim();
                            final addr = c['address']!.text.trim();
                            final phone = c['phone']!.text.trim();
                            return '$name|||$addr|||$phone';
                          }).where((c) => !c.startsWith('|||')).toList(),
                          customFields: customFieldControllers.map((c) {
                            final name = c['name']!.text.trim();
                            final val = c['value']!.text.trim();
                            if (name.isEmpty && val.isEmpty) return '';
                            return '$name: $val';
                          }).where((c) => c.isNotEmpty && c != ': ').toList(),
                        );
                        try {
                          if (client == null) {
                            int maxRegNo = 0;
                            for (var c in _clients) {
                              if (c.registrationNumber != null) {
                                final match = RegExp(r'\d+').firstMatch(c.registrationNumber!);
                                if (match != null) {
                                  final num = int.tryParse(match.group(0)!) ?? 0;
                                  if (num > maxRegNo) maxRegNo = num;
                                }
                              }
                            }
                            final newRegNo = 'CUC-${(maxRegNo + 1).toString().padLeft(4, '0')}';
                            
                            final model = amplify_models.Clients(
                              name: newClient.name,
                              email: newClient.email,
                              phone: newClient.phone,
                              address: newClient.address,
                              type_of_work: newClient.typeOfWork,
                              file_no: newClient.fileNo,
                              file_date: newClient.fileDate,
                              is_contacted: newClient.isContacted,
                              dob: newClient.dob,
                              managed_by: newClient.managedBy,
                              case_number: newRegNo,
                              companies: newClient.companies,
                              custom_fields: newClient.customFields,
                            );
                            await BackupAwareApi().create(model);
                          } else {
                            final model = amplify_models.Clients(
                              id: newClient.id,
                              name: newClient.name,
                              email: newClient.email,
                              phone: newClient.phone,
                              address: newClient.address,
                              type_of_work: newClient.typeOfWork,
                              file_no: newClient.fileNo,
                              file_date: newClient.fileDate,
                              is_contacted: newClient.isContacted,
                              dob: newClient.dob,
                              managed_by: newClient.managedBy,
                              case_number: newClient.registrationNumber,
                              companies: newClient.companies,
                              custom_fields: newClient.customFields,
                            );
                            await BackupAwareApi().update(model);
                          }
                          
                          if (context.mounted) Navigator.pop(context);
                          _fetchClients();
                          
                          await LoggingService().logAction(
                            action: client == null ? 'CLIENT_CREATED' : 'CLIENT_UPDATED',
                            targetType: 'Client',
                            targetId: nameController.text,
                            details: 'Client: ${nameController.text}',
                          );

                          _showSuccess('Client saved successfully');
                        } catch (e) {
                          _showError('Save failed: $e');
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: const Text('Save Client', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ).animate().fadeIn(duration: 300.ms).scaleXY(begin: 0.95, end: 1.0, curve: Curves.easeOutBack);
  },
),
);
}

  Widget _buildFormField(TextEditingController controller, String label, IconData icon, bool required, {int maxLines = 1, VoidCallback? onTap, ValueChanged<String>? onChanged}) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      readOnly: onTap != null,
      onTap: onTap,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.grey.shade50,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
        prefixIcon: Icon(icon, color: AppTheme.primaryColor),
      ),
      validator: required ? (v) => v == null || v.isEmpty ? "Required" : null : null,
    );
  }

  Widget _buildPeriodSelector() {
    return Container(
      margin: const EdgeInsets.only(top: 16, bottom: 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _buildPeriodChip(
            id: '2026-2027',
            title: '2026-2027 (Current)',
            subtitle: 'From Nov 1, 2026',
            icon: Icons.fiber_new_rounded,
            count: _count2026_2027,
            activeColor: const Color(0xFF10B981),
          ),
          _buildPeriodChip(
            id: '2025-2026',
            title: '2025-2026',
            subtitle: 'Till Nov 1, 2026',
            icon: Icons.history_rounded,
            count: _count2025_2026,
            activeColor: const Color(0xFF6366F1),
          ),
          _buildPeriodChip(
            id: 'All',
            title: 'All Clients',
            subtitle: 'Complete Archive',
            icon: Icons.people_alt_rounded,
            count: _countAll,
            activeColor: AppTheme.primaryColor,
          ),
          if (_count2025_2026 > 0)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ElevatedButton.icon(
                onPressed: _showImportToCurrentDialog,
                icon: const Icon(Icons.drive_file_move_outlined, size: 16),
                label: const Text('Import to Current', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPeriodChip({
    required String id,
    required String title,
    required String subtitle,
    required IconData icon,
    required int count,
    required Color activeColor,
  }) {
    final isSelected = _selectedPeriod == id;
    return InkWell(
      onTap: () {
        setState(() {
          _selectedPeriod = id;
        });
      },
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? activeColor : const Color(0xFFE2E8F0),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.white : const Color(0xFF64748B),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: isSelected ? Colors.white : const Color(0xFF1E293B),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: isSelected ? Colors.white.withValues(alpha: 0.8) : const Color(0xFF94A3B8),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white.withValues(alpha: 0.25) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  color: isSelected ? Colors.white : const Color(0xFF475569),
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isWide = constraints.maxWidth > 900;
        var periodFiltered = _clients;
        if (_selectedPeriod == '2025-2026') {
          periodFiltered = _clients.where((c) => _getClientDate(c).isBefore(nov1Cutoff)).toList();
        } else if (_selectedPeriod == '2026-2027') {
          periodFiltered = _clients.where((c) => !_getClientDate(c).isBefore(nov1Cutoff)).toList();
        }

        final filtered = periodFiltered.where((c) => 
          c.name.toLowerCase().contains(_searchTerm.toLowerCase()) ||
          (c.phone?.contains(_searchTerm) ?? false) ||
          (c.fileNo?.toLowerCase().contains(_searchTerm.toLowerCase()) ?? false) ||
          (c.registrationNumber?.toLowerCase().contains(_searchTerm.toLowerCase()) ?? false)
        ).toList();

        return Padding(
          padding: EdgeInsets.all(isWide ? 24 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // Premium Responsive Header
            if (isWide)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      if (Navigator.canPop(context))
                        Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back_rounded),
                            onPressed: () => Navigator.pop(context),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                              elevation: 2,
                              shadowColor: Colors.black.withValues(alpha: 0.1),
                            ),
                          ),
                        ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Client Management', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
                          Text('Manage client profiles, files, and contact details', style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      SizedBox(
                        width: 300,
                        child: TextField(
                          onChanged: (val) => setState(() => _searchTerm = val),
                          decoration: InputDecoration(
                            hintText: 'Search clients, reg no, files, phone...',
                            prefixIcon: const Icon(Icons.search, color: AppTheme.primaryColor),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide(color: Colors.grey.shade200)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      _buildSortDropdown(),
                      const SizedBox(width: 12),
                      _headerAction(Icons.refresh_rounded, 'Refresh', AppTheme.primaryColor, _fetchClients),
                      const SizedBox(width: 12),
                      _headerAction(Icons.download_rounded, 'Export to Excel', Colors.green, _exportToExcel),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        onPressed: () => _showGlobalMergeDialog(),
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('Merge All'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purple,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          elevation: 0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        onPressed: () => _showClientForm(),
                        icon: const Icon(Icons.add),
                        label: const Text('Add Client'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          elevation: 0,
                        ),
                      ),
                    ],
                  ),
                ],
              ).animate().fadeIn().slideY(begin: -0.1)
            else ...[
              // Narrow layout for Mobile/Tablet
              Row(
                children: [
                  if (Navigator.canPop(context))
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: () => Navigator.pop(context),
                        style: IconButton.styleFrom(backgroundColor: Colors.white, elevation: 2),
                      ),
                    ),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Client Management', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
                        Text('Manage client profiles and files', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ).animate().fadeIn(),
              const SizedBox(height: 20),
              TextField(
                onChanged: (val) => setState(() => _searchTerm = val),
                decoration: InputDecoration(
                  hintText: 'Search clients, reg no...',
                  prefixIcon: const Icon(Icons.search, color: AppTheme.primaryColor),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                ),
              ).animate().fadeIn().slideX(begin: 0.1),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => _showClientForm(),
                    icon: const Icon(Icons.add),
                    label: const Text('Add Client'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      elevation: 0,
                    ),
                  ),
                  _buildSortDropdown(),
                  _headerAction(Icons.refresh_rounded, 'Refresh', AppTheme.primaryColor, _fetchClients),
                  _headerAction(Icons.download_rounded, 'Export', Colors.green, _exportToExcel),
                ],
              ).animate().fadeIn().slideY(begin: 0.1),
            ],
            _buildPeriodSelector(),
            const SizedBox(height: 16),
            Expanded(
              child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? Center(
                        child: _selectedPeriod == '2026-2027'
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF10B981).withValues(alpha: 0.1),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.auto_awesome_rounded, size: 48, color: Color(0xFF10B981)),
                                  ),
                                  const SizedBox(height: 16),
                                  const Text(
                                    'Fresh Start: 2026-2027',
                                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Starting fresh from Nov 1, 2026! No new clients registered yet.\nPrevious clients are safely archived in the "2025-2026" button ($_count2025_2026 clients).',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
                                  ),
                                  const SizedBox(height: 20),
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 12,
                                    alignment: WrapAlignment.center,
                                    children: [
                                      ElevatedButton.icon(
                                        onPressed: () {
                                          setState(() {
                                            _selectedPeriod = '2025-2026';
                                          });
                                        },
                                        icon: const Icon(Icons.history_rounded, size: 18),
                                        label: Text('Open 2025-2026 Clients ($_count2025_2026)'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF6366F1),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                          elevation: 2,
                                        ),
                                      ),
                                      if (_count2025_2026 > 0)
                                        ElevatedButton.icon(
                                          onPressed: _showImportToCurrentDialog,
                                          icon: const Icon(Icons.drive_file_move_rounded, size: 18),
                                          label: const Text('Import from 2025-2026'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(0xFF10B981),
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                            elevation: 2,
                                          ),
                                        ),
                                      OutlinedButton.icon(
                                        onPressed: () => _showClientForm(),
                                        icon: const Icon(Icons.add, size: 18),
                                        label: const Text('Add Client'),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppTheme.primaryColor,
                                          side: const BorderSide(color: AppTheme.primaryColor),
                                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.person_off_rounded, size: 64, color: Colors.grey.shade300),
                                  const SizedBox(height: 16),
                                  Text('No clients found for this period', style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                                ],
                              ),
                      )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24, right: 16), // Padding for scrollbar
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final client = filtered[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _buildClientCard(client, isWide)
                          .animate()
                          .fadeIn(delay: (50 * index).ms, duration: 400.ms)
                          .slideY(begin: 0.1),
                      );
                    },
                  ),
            ),
          ],
        ).animate().fadeIn(),
      );
    },
  );
}

  Widget _buildSortDropdown() {
    return PopupMenuButton<String>(
      tooltip: 'Sort Clients',
      initialValue: _currentSort,
      onSelected: (val) {
        setState(() {
          _currentSort = val;
          _applySort();
        });
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.primaryColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.sort_rounded, color: AppTheme.primaryColor, size: 20),
      ),
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'Name (A-Z)', child: Text('Name (A-Z)')),
        const PopupMenuItem(value: 'Name (Z-A)', child: Text('Name (Z-A)')),
        const PopupMenuItem(value: 'Due (High-Low)', child: Text('Due (High-Low)')),
      ],
    );
  }

  Widget _headerAction(IconData icon, String tooltip, Color color, VoidCallback onTap) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, color: color, size: 20),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.1),
        padding: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  String _formatDate(String? isoString, String? createdBy) {
    if (createdBy == 'System/Legacy') return 'Not Saved';
    if (isoString == null || isoString.isEmpty) return 'Not Saved';
    try {
      final dt = DateTime.parse(isoString).toLocal();
      return DateFormat('dd MMM yyyy, hh:mm a').format(dt);
    } catch (e) {
      return isoString;
    }
  }

  Widget _buildClientCard(Client c, bool isWide) {
    return Card(
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.grey.shade100)),
      child: Padding(
        padding: EdgeInsets.all(isWide ? 24 : 16),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                  child: Text(c.name.isNotEmpty ? c.name[0].toUpperCase() : '?', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: AppTheme.primaryColor)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(c.name, style: TextStyle(fontWeight: FontWeight.bold, fontSize: isWide ? 18 : 16), maxLines: 2, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (c.isContacted)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.green.shade200)),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.check_circle, size: 14, color: Colors.green),
                                  SizedBox(width: 4),
                                  Text("Contacted", style: TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          GestureDetector(
                            onTap: () => _showClientBillsDialog(c),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: c.balanceDue != null && c.balanceDue != "0/-" && c.balanceDue != "0" ? Colors.orange.shade50 : Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: c.balanceDue != null && c.balanceDue != "0/-" && c.balanceDue != "0" ? Colors.orange.shade200 : Colors.grey.shade200),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.account_balance_wallet_outlined, size: 14, color: c.balanceDue != null && c.balanceDue != "0/-" && c.balanceDue != "0" ? Colors.orange.shade800 : Colors.grey.shade600),
                                  const SizedBox(width: 4),
                                  Text(
                                    "Due: ${c.balanceDue ?? '0/-'}",
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: c.balanceDue != null && c.balanceDue != "0/-" && c.balanceDue != "0" ? Colors.orange.shade800 : Colors.grey.shade600),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('${c.typeOfWork ?? "No Type of Work"} • File: ${c.fileNo ?? "N/A"} • Reg No: ${c.registrationNumber ?? "N/A"}', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),

                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Wrap(
              spacing: 24,
              runSpacing: 16,
              children: [
                _buildInfoPill(Icons.email_outlined, c.email?.isNotEmpty == true ? c.email! : 'No Email', isWide),
                _buildInfoPill(Icons.phone_outlined, c.phone?.isNotEmpty == true ? c.phone! : 'No Phone', isWide),
                _buildInfoPill(Icons.calendar_today_outlined, 'File Date: ${c.fileDate?.isNotEmpty == true ? c.fileDate! : 'N/A'}', isWide),
                _buildInfoPill(Icons.cake_outlined, 'DOB: ${c.dob?.isNotEmpty == true ? c.dob! : 'N/A'}', isWide),
                _buildInfoPill(Icons.location_on_outlined, c.address?.isNotEmpty == true ? c.address! : 'No Address', isWide),
                _buildInfoPill(Icons.supervised_user_circle_outlined, 'Care Of: ${c.managedBy?.isNotEmpty == true ? c.managedBy! : 'N/A'}', isWide),
                _buildInfoPill(Icons.person_add_outlined, 'Created By: ${c.createdBy ?? 'System/Legacy'}', isWide),
                _buildInfoPill(Icons.access_time_outlined, 'Created: ${_formatDate(c.createdAt, c.createdBy)}', isWide),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _showClientFilesDialog(c),
                  icon: const Icon(Icons.folder_shared, size: 16),
                  label: const Text('Files Vault'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blueAccent,
                    side: BorderSide(color: Colors.blue.shade200),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showClientBillsDialog(c),
                  icon: const Icon(Icons.receipt_long_outlined, size: 16),
                  label: const Text('Bills'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.teal,
                    side: BorderSide(color: Colors.teal.shade200),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showClientWorksDialog(c),
                  icon: const Icon(Icons.work_outline, size: 16),
                  label: const Text('Works'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.indigo,
                    side: BorderSide(color: Colors.indigo.shade200),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showMergeDialog(c),
                  icon: const Icon(Icons.merge_type, size: 16),
                  label: const Text('Merge'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.purple,
                    side: BorderSide(color: Colors.purple.shade200),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showClientForm(c),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit Profile'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primaryColor,
                    side: const BorderSide(color: AppTheme.primaryColor),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                if (_getClientDate(c).isBefore(nov1Cutoff))
                  OutlinedButton.icon(
                    onPressed: () => _importSingleClientToCurrent(c),
                    icon: const Icon(Icons.drive_file_move_outlined, size: 16),
                    label: const Text('Import to Current'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF10B981),
                      side: const BorderSide(color: Color(0xFF10B981)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                if (_isAdmin)
                  OutlinedButton.icon(
                    onPressed: () => _deleteClient(c.id.toString()),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Delete'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: BorderSide(color: Colors.red.shade200),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoPill(IconData icon, String text, bool isWide) {
    return SizedBox(
      width: isWide ? 260 : double.infinity,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppTheme.mutedTextColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13, color: AppTheme.textColor), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _ClientBillsDialog extends StatefulWidget {
  final Client client;
  const _ClientBillsDialog({required this.client});

  @override
  State<_ClientBillsDialog> createState() => _ClientBillsDialogState();
}

class _ClientBillsDialogState extends State<_ClientBillsDialog> {
  final _billingService = BillingService();
  bool _isLoading = true;
  List<Billing> _bills = [];

  @override
  void initState() {
    super.initState();
    _loadBills();
  }

  Future<void> _loadBills() async {
    final ledger = await _billingService.getClientLedger(widget.client.name);
    if (!mounted) return;
    setState(() {
      _bills = ledger;
      _isLoading = false;
    });
  }

    @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text('${widget.client.name} - Ledger', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
            else if (_bills.isEmpty)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No bills found for this client.', style: TextStyle(color: Colors.grey))))
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _bills.length,
                  itemBuilder: (context, index) {
                    final b = _bills[index];
                    final isPaid = b.status == 'Received';
                    return Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                          child: const Icon(Icons.receipt_long_rounded, color: AppTheme.primaryColor, size: 20),
                        ),
                        title: Text('Invoice: ${b.invoiceNo ?? 'N/A'} - ₹${b.amount ?? '0'}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('${b.type ?? 'N/A'} • ${b.date ?? 'N/A'}'),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: isPaid ? Colors.green.shade50 : Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: isPaid ? Colors.green.shade200 : Colors.orange.shade200),
                          ),
                          child: Text(isPaid ? 'Paid' : 'Pending', style: TextStyle(color: isPaid ? Colors.green : Colors.orange.shade800, fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

