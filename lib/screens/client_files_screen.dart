import 'package:flutter/material.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../theme.dart';
import '../widgets/premium_app_bar.dart';
import 'create_work_file_dialog.dart';
import '../models/client.dart';
import 'client_files_dialog.dart';
import '../services/logging_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/deal_service.dart';
import '../services/supabase_backup_service.dart';

class ClientFilesScreen extends StatefulWidget {
  const ClientFilesScreen({super.key});

  @override
  State<ClientFilesScreen> createState() => _ClientFilesScreenState();
}

class _ClientFilesScreenState extends State<ClientFilesScreen> {
  final _searchController = TextEditingController();
  static final DateTime nov1Cutoff = DateTime(2026, 11, 1);
  String _selectedPeriod = '2026-2027'; // Starts fresh from Nov 1, 2026
  String _sortOption = 'Newest First';
  String? _selectedStaffFilter;
  List<amplify_models.Users> _allStaffList = [];
  final Map<String, int> _staffIdMap = {};
  List<amplify_models.Deals> _workFiles = [];
  List<amplify_models.Deals> _filtered = [];
  bool _isLoading = true;

  DateTime _getWorkFileDate(amplify_models.Deals d) {
    if (d.created_at != null && d.created_at!.isNotEmpty) {
      final parsed = DateTime.tryParse(d.created_at!);
      if (parsed != null) return parsed.toLocal();
    }
    if (d.createdAt != null) {
      return d.createdAt!.getDateTimeInUtc().toLocal();
    }
    return DateTime(2000);
  }

  int get _count2025_2026 => _workFiles.where((w) => _getWorkFileDate(w).isBefore(nov1Cutoff)).length;
  int get _count2026_2027 => _workFiles.where((w) => !_getWorkFileDate(w).isBefore(nov1Cutoff)).length;
  int get _countAll => _workFiles.length;

  List<String> get _activeStaffNames {
    return <String>{
      ..._workFiles.map((w) => w.responsible_name).whereType<String>(),
      ..._allStaffList.map((s) => (s.name?.isNotEmpty == true ? s.name! : (s.username ?? ''))).where((s) => s.isNotEmpty),
    }
        .where((name) => name.trim().isNotEmpty)
        .map((name) {
          final trimmed = name.trim();
          final firstWord = trimmed.split(' ').first;
          if (firstWord.isEmpty) return '';
          return firstWord[0].toUpperCase() + firstWord.substring(1).toLowerCase();
        })
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  Future<void> _fetchStaff() async {
    try {
      final req = ModelQueries.list(amplify_models.Users.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      final fetched = (res.data?.items ?? []).whereType<amplify_models.Users>().toList();
      final sbUserMap = await SupabaseBackupService().getUsernameToIdMap();
      
      for (var staff in fetched) {
        final intId = sbUserMap[staff.username] ?? sbUserMap[staff.email];
        if (intId != null) {
          _staffIdMap[staff.id] = intId;
        }
      }
      
      final deduplicated = <amplify_models.Users>[];
      for (var staff in fetched) {
        final name = (staff.name ?? staff.username ?? 'Unknown').trim();
        final idx = deduplicated.indexWhere((s) => (s.name ?? s.username ?? '').trim().toLowerCase() == name.toLowerCase());
        if (idx != -1) {
          if ((staff.role ?? '').toLowerCase() == 'admin' || (staff.role ?? '').toLowerCase() == 'manager') {
            deduplicated[idx] = staff;
          }
        } else {
          deduplicated.add(staff);
        }
      }
      deduplicated.sort((a, b) => (a.name ?? a.username ?? '').compareTo(b.name ?? b.username ?? ''));
      if (mounted) setState(() => _allStaffList = deduplicated);
    } catch (e) {
      debugPrint('Error fetching staff in client_files_screen: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _fetchStaff();
    _fetchWorkFiles();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchWorkFiles() async {
    setState(() => _isLoading = true);
    try {
      final req = ModelQueries.list(amplify_models.Deals.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      
      if (res.data != null) {
        final List<amplify_models.Deals> allDeals = res.data!.items.whereType<amplify_models.Deals>().toList();
        // Only show actual Work Files: exclude CRM leads that haven't been passed to work yet
        final List<amplify_models.Deals> fetched = allDeals.where((d) {
          final isCrm = (d.pipeline ?? '').toLowerCase() == 'crm' || (d.pipeline ?? '').toLowerCase() == 'lead';
          if (isCrm && d.is_won != true) return false;
          return true;
        }).toList();
        fetched.sort((a, b) => (_getWorkFileDate(b)).compareTo(_getWorkFileDate(a)));
        
        if (mounted) {
          setState(() {
            _workFiles = fetched;
            _isLoading = false;
          });
          _applyFilterAndSort();
        }
      }
    } catch (e) {
      debugPrint('Error fetching work files: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteWorkFile(amplify_models.Deals workFile) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Work File'),
        content: Text('Are you sure you want to delete the work file "${workFile.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await BackupAwareApi().delete(workFile);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Work file deleted successfully', style: TextStyle(color: Colors.white)), backgroundColor: Colors.green));
        }
        
        setState(() {
          _workFiles.removeWhere((w) => w.id == workFile.id);
        });
        _filterWorkFiles(_searchController.text);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting: $e', style: const TextStyle(color: Colors.white)), backgroundColor: Colors.red));
        }
      }
    }
  }

  Future<void> _editWorkFile(amplify_models.Deals workFile) async {
    final nameController = TextEditingController(text: workFile.name);
    final fileNoController = TextEditingController(text: workFile.register_no);
    
    String currentType = workFile.work_type ?? '';
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
    
    final typeController = TextEditingController(text: currentType);
    String selectedCategory = currentCategory;

    final updated = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.edit_document, color: AppTheme.primaryColor, size: 24),
              ),
              const SizedBox(width: 16),
              const Expanded(child: Text('Edit Work File', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: -0.5))),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: 'Work Name',
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: fileNoController,
                    decoration: InputDecoration(
                      labelText: 'File No',
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: selectedCategory,
                    decoration: InputDecoration(
                      labelText: 'Category',
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                    ),
                    items: ['General', 'Legal', 'Consultancy'].map((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (newValue) {
                      setStateDialog(() {
                        selectedCategory = newValue!;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: typeController,
                    decoration: InputDecoration(
                      labelText: 'Type of Work',
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false), 
              child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey))
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save Changes', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    if (updated == true) {
      setState(() => _isLoading = true);
      try {
        String finalType = typeController.text.trim();
        if (selectedCategory != 'General') {
            finalType = finalType.isEmpty ? selectedCategory : '$selectedCategory - $finalType';
        }
        final newDeal = workFile.copyWith(
          name: nameController.text.trim(),
          register_no: fileNoController.text.trim(),
          work_type: finalType,
        );
        await BackupAwareApi().update(newDeal);
        
        await LoggingService().logAction(
          action: 'WORK_FILE_UPDATED',
          targetType: 'WorkFile',
          targetId: newDeal.name,
          details: 'Updated Work File details for ${newDeal.name}',
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Work file updated successfully', style: TextStyle(color: Colors.white)), backgroundColor: Colors.green));
          
          // Update local state directly to avoid eventual consistency lag
          setState(() {
            final index = _workFiles.indexWhere((w) => w.id == newDeal.id);
            if (index != -1) {
              _workFiles[index] = newDeal;
            }
            _isLoading = false;
          });
          _filterWorkFiles(_searchController.text);
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating: $e')));
        }
      }
    }
  }

  void _applyFilterAndSort() {
    List<amplify_models.Deals> list = List.from(_workFiles);

    // Period Filter: "2025-2026" (till Nov 1, 2026) vs "2026-2027" (from Nov 1, 2026)
    if (_selectedPeriod == '2025-2026') {
      list = list.where((w) => _getWorkFileDate(w).isBefore(nov1Cutoff)).toList();
    } else if (_selectedPeriod == '2026-2027') {
      list = list.where((w) => !_getWorkFileDate(w).isBefore(nov1Cutoff)).toList();
    }

    // Staff Filter: track who is doing works
    if (_selectedStaffFilter != null) {
      if (_selectedStaffFilter == 'Unassigned') {
        list = list.where((w) => w.responsible_name == null || w.responsible_name!.trim().isEmpty).toList();
      } else {
        list = list.where((w) {
          if (w.responsible_name == null || w.responsible_name!.trim().isEmpty) return false;
          final firstWord = w.responsible_name!.trim().split(' ').first;
          if (firstWord.isEmpty) return false;
          final formattedFirstWord = firstWord[0].toUpperCase() + firstWord.substring(1).toLowerCase();
          return formattedFirstWord == _selectedStaffFilter;
        }).toList();
      }
    }

    if (_sortOption == 'Legal Only') {
      list = list.where((w) => (w.work_type ?? '').toLowerCase().contains('legal')).toList();
    } else if (_sortOption == 'Consultancy Only') {
      list = list.where((w) => (w.work_type ?? '').toLowerCase().contains('consultancy')).toList();
    }

    final lower = _searchController.text.toLowerCase();
    if (lower.isNotEmpty) {
      list = list.where((w) => 
        (w.name?.toLowerCase().contains(lower) ?? false) || 
        (w.client_name?.toLowerCase().contains(lower) ?? false)
      ).toList();
    }

    if (_sortOption == 'Newest First' || _sortOption == 'Legal Only' || _sortOption == 'Consultancy Only') {
      list.sort((a, b) => _getWorkFileDate(b).compareTo(_getWorkFileDate(a)));
    } else if (_sortOption == 'Oldest First') {
      list.sort((a, b) => _getWorkFileDate(a).compareTo(_getWorkFileDate(b)));
    } else if (_sortOption == 'A-Z') {
      list.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
    } else if (_sortOption == 'Z-A') {
      list.sort((a, b) => (b.name ?? '').compareTo(a.name ?? ''));
    } else if (_sortOption == 'Highest Amount') {
      list.sort((a, b) => (b.amount ?? 0.0).compareTo(a.amount ?? 0.0));
    } else if (_sortOption == 'Lowest Amount') {
      list.sort((a, b) => (a.amount ?? 0.0).compareTo(b.amount ?? 0.0));
    } else if (_sortOption == 'Invoice No (A-Z)') {
      list.sort((a, b) => (a.register_no ?? '').compareTo(b.register_no ?? ''));
    } else if (_sortOption == 'Invoice No (Z-A)') {
      list.sort((a, b) => (b.register_no ?? '').compareTo(a.register_no ?? ''));
    }

    setState(() {
      _filtered = list;
    });
  }

  void _filterWorkFiles(String query) {
    _applyFilterAndSort();
  }

  void _showCreateDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => CreateWorkFileDialog(
        onSaved: () {
          _fetchWorkFiles();
        },
      ),
    );
  }

  Future<void> _showQuickAssignStaffDialog(amplify_models.Deals workFile) async {
    final searchCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final query = searchCtrl.text.toLowerCase().trim();
          final filteredStaff = query.isEmpty
              ? _allStaffList
              : _allStaffList.where((s) =>
                  (s.name?.toLowerCase().contains(query) ?? false) ||
                  (s.username?.toLowerCase().contains(query) ?? false) ||
                  (s.role?.toLowerCase().contains(query) ?? false)
                ).toList();

          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            backgroundColor: Colors.white,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
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
                            color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.assignment_ind_rounded, color: Color(0xFF2563EB), size: 24),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Mark Staff Doing Work',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Assign or reassign: "${workFile.name ?? 'Work File'}"',
                                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 16, color: Color(0xFF64748B)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              (workFile.responsible_name != null && workFile.responsible_name!.trim().isNotEmpty)
                                  ? 'Currently Assigned to: ${workFile.responsible_name}'
                                  : 'Currently: Unassigned',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: (workFile.responsible_name != null && workFile.responsible_name!.trim().isNotEmpty)
                                    ? const Color(0xFF1E293B)
                                    : Colors.amber.shade800,
                              ),
                            ),
                          ),
                          if (workFile.responsible_name != null && workFile.responsible_name!.trim().isNotEmpty)
                            TextButton.icon(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await _assignStaffToWorkFile(workFile, null);
                              },
                              icon: const Icon(Icons.person_remove_rounded, size: 14, color: Colors.red),
                              label: const Text('Unassign', style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: searchCtrl,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Search staff by name or role...',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2563EB))),
                        fillColor: const Color(0xFFF8FAFC),
                        filled: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('Select Staff Member Doing Work:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                    const SizedBox(height: 8),
                    Expanded(
                      child: filteredStaff.isEmpty
                          ? Center(
                              child: Text('No staff members found', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                            )
                          : ListView.separated(
                              itemCount: filteredStaff.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 6),
                              itemBuilder: (context, i) {
                                final staff = filteredStaff[i];
                                final staffName = (staff.name?.isNotEmpty == true
                                    ? staff.name!
                                    : (staff.username?.isNotEmpty == true ? staff.username! : 'Staff Member'));
                                final isCurrent = (workFile.responsible_name ?? '').toLowerCase() == staffName.toLowerCase();
                                
                                final firstWord = staffName.split(' ').first.toLowerCase();
                                final staffWorksCount = _workFiles.where((w) {
                                  final rName = (w.responsible_name ?? '').toLowerCase().trim();
                                  return rName.isNotEmpty && (rName == staffName.toLowerCase() || rName.startsWith(firstWord));
                                }).length;

                                return Material(
                                  color: isCurrent ? const Color(0xFF2563EB).withValues(alpha: 0.08) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () async {
                                      Navigator.pop(ctx);
                                      await _assignStaffToWorkFile(workFile, staff);
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 18,
                                            backgroundColor: const Color(0xFF2563EB).withValues(alpha: 0.15),
                                            child: Text(
                                              staffName.isNotEmpty ? staffName[0].toUpperCase() : '?',
                                              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2563EB), fontSize: 14),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  staffName,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                    color: isCurrent ? const Color(0xFF2563EB) : const Color(0xFF1E293B),
                                                  ),
                                                ),
                                                Text(
                                                  staff.role ?? 'Staff Member',
                                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF1F5F9),
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(color: Colors.grey.shade300),
                                            ),
                                            child: Text(
                                              '$staffWorksCount works',
                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (isCurrent)
                                            const Icon(Icons.check_circle_rounded, color: Color(0xFF2563EB), size: 20)
                                          else
                                            const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFFCBD5E1), size: 14),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
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

  Future<void> _assignStaffToWorkFile(amplify_models.Deals workFile, amplify_models.Users? staff) async {
    setState(() => _isLoading = true);
    try {
      final int? staffIntId = staff != null ? (_staffIdMap[staff.id] ?? int.tryParse(staff.id)) : null;
      final String? staffName = staff?.name ?? staff?.username;

      final updatedDeal = workFile.copyWith(
        responsible_id: staffIntId,
        responsible_name: staffName,
      );
      await BackupAwareApi().update(updatedDeal);

      if (staffIntId != null) {
        try {
          await DealService().addAssignee(workFile.id, staffIntId, role: 'Lead');
        } catch (_) {}
      }

      await LoggingService().logAction(
        action: 'WORK_STAFF_ASSIGNED',
        targetType: 'WorkFile',
        targetId: workFile.name,
        details: staffName != null
            ? 'Marked $staffName as doing work for "${workFile.name}"'
            : 'Unassigned staff from "${workFile.name}"',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(staffName != null
                ? 'Marked $staffName as doing work for "${workFile.name}"!'
                : 'Work file "${workFile.name}" is now unassigned.'),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {
          final index = _workFiles.indexWhere((w) => w.id == workFile.id);
          if (index != -1) {
            _workFiles[index] = updatedDeal;
          }
          _isLoading = false;
        });
        _applyFilterAndSort();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error assigning staff: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showStaffWorkloadTrackerDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580, maxHeight: 650),
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
                        color: const Color(0xFF6366F1).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.people_alt_rounded, color: Color(0xFF6366F1), size: 24),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Staff Workload Tracker',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Track who all are doing works across the firm',
                            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: [
                      // Unassigned row
                      Builder(builder: (context) {
                        final unassignedWorks = _workFiles.where((w) => w.responsible_name == null || w.responsible_name!.trim().isEmpty).toList();
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.amber.shade200),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: Colors.amber.shade200,
                                child: const Icon(Icons.person_off_rounded, color: Colors.black87, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Unassigned Works', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF92400E))),
                                    Text('Works requiring an assignee to be marked', style: TextStyle(fontSize: 11, color: Colors.amber.shade900)),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade200,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${unassignedWorks.length} works',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.amber.shade900),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  setState(() {
                                    _selectedStaffFilter = 'Unassigned';
                                  });
                                  _applyFilterAndSort();
                                },
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: Colors.amber.shade700),
                                  foregroundColor: Colors.amber.shade900,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  minimumSize: Size.zero,
                                ),
                                child: const Text('View', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        );
                      }),
                      // Staff rows
                      ..._allStaffList.map((staff) {
                        final staffName = (staff.name?.isNotEmpty == true
                            ? staff.name!
                            : (staff.username?.isNotEmpty == true ? staff.username! : 'Staff Member'));
                        final firstWord = staffName.split(' ').first;
                        final staffWorks = _workFiles.where((w) {
                          final rName = (w.responsible_name ?? '').toLowerCase().trim();
                          return rName.isNotEmpty && (rName == staffName.toLowerCase() || rName.startsWith(firstWord.toLowerCase()));
                        }).toList();
                        
                        final legalCount = staffWorks.where((w) => (w.work_type ?? '').toLowerCase().contains('legal')).length;
                        final consultancyCount = staffWorks.where((w) => (w.work_type ?? '').toLowerCase().contains('consultancy')).length;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: const Color(0xFF2563EB).withValues(alpha: 0.1),
                                child: Text(
                                  staffName.isNotEmpty ? staffName[0].toUpperCase() : '?',
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2563EB), fontSize: 14),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(staffName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B))),
                                    Text(
                                      '${staff.role ?? "Staff"} • Legal: $legalCount • Consultancy: $consultancyCount',
                                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.grey.shade300),
                                ),
                                child: Text(
                                  '${staffWorks.length} works',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF1E293B)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  final formattedFirstWord = firstWord[0].toUpperCase() + firstWord.substring(1).toLowerCase();
                                  setState(() {
                                    _selectedStaffFilter = formattedFirstWord;
                                  });
                                  _applyFilterAndSort();
                                },
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Color(0xFF2563EB)),
                                  foregroundColor: const Color(0xFF2563EB),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  minimumSize: Size.zero,
                                ),
                                child: const Text('View', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _importSingleWorkFileToCurrent(amplify_models.Deals workFile) async {
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
              child: Text('Import to Current Period?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        content: Text(
          'Do you want to import "${workFile.name ?? 'this work file'}" into the current period (2026-2027)?\n\nIts record will be updated to start from the current period.',
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

    setState(() => _isLoading = true);
    try {
      final targetDate = DateTime.now().isBefore(nov1Cutoff)
          ? DateTime(2026, 11, 1, 0, 0, 1)
          : DateTime.now();
      final targetDateStr = targetDate.toIso8601String();

      final updated = workFile.copyWith(created_at: targetDateStr);
      await BackupAwareApi().update(updated);

      await LoggingService().logAction(
        action: 'WORK_FILE_IMPORTED',
        targetType: 'WorkFile',
        targetId: workFile.name,
        details: 'Imported Work File "${workFile.name}" to 2026-2027 period',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully imported "${workFile.name}" to 2026-2027!'),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {
          _selectedPeriod = '2026-2027';
        });
        await _fetchWorkFiles();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error importing work file: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showImportToCurrentDialog() async {
    final candidates = _workFiles.where((w) => _getWorkFileDate(w).isBefore(nov1Cutoff)).toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No 2025-2026 work files available to import.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final searchCtrl = TextEditingController();
    final selectedIds = <String>{};
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
              : candidates.where((w) =>
                  (w.name?.toLowerCase().contains(query) ?? false) ||
                  (w.client_name?.toLowerCase().contains(query) ?? false) ||
                  (w.register_no?.toLowerCase().contains(query) ?? false)
                ).toList();

          final allDisplayedSelected = displayed.isNotEmpty && displayed.every((w) => selectedIds.contains(w.id));

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
                                'Import Work Files to Current',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Select files from 2025-2026 to carry forward into 2026-2027',
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
                        hintText: 'Search by work file name, client, or file no...',
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
                          '${selectedIds.length} selected of ${candidates.length} files',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: isImporting
                              ? null
                              : () {
                                  setDialogState(() {
                                    if (allDisplayedSelected) {
                                      for (var w in displayed) {
                                        selectedIds.remove(w.id);
                                      }
                                    } else {
                                      for (var w in displayed) {
                                        selectedIds.add(w.id);
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
                                  Icon(Icons.search_off_rounded, size: 40, color: Colors.grey.shade300),
                                  const SizedBox(height: 8),
                                  Text('No matching files found', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                                ],
                              ),
                            )
                          : ListView.separated(
                              itemCount: displayed.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 6),
                              itemBuilder: (context, i) {
                                final w = displayed[i];
                                final isChecked = selectedIds.contains(w.id);
                                final date = _getWorkFileDate(w);
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
                                                selectedIds.remove(w.id);
                                              } else {
                                                selectedIds.add(w.id);
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
                                                        selectedIds.add(w.id);
                                                      } else {
                                                        selectedIds.remove(w.id);
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
                                                  w.name ?? 'Untitled Work',
                                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B)),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  'Client: ${w.client_name ?? "Unknown"}${w.register_no != null && w.register_no!.isNotEmpty ? " • File No: ${w.register_no}" : ""} • Date: $dateStr',
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
                                    final match = candidates.firstWhere((w) => w.id == id);
                                    try {
                                      final updated = match.copyWith(created_at: targetDateStr);
                                      await BackupAwareApi().update(updated);
                                      await LoggingService().logAction(
                                        action: 'WORK_FILE_IMPORTED',
                                        targetType: 'WorkFile',
                                        targetId: match.name,
                                        details: 'Imported work file "${match.name}" to 2026-2027 period',
                                      );
                                    } catch (e) {
                                      debugPrint('Error importing work file ${match.name}: $e');
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
                                    await _fetchWorkFiles();
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Successfully imported ${selectedIds.length} work file(s) into 2026-2027!'),
                                        backgroundColor: Colors.green,
                                      ),
                                    );
                                  }
                                },
                          icon: const Icon(Icons.drive_file_move_rounded, size: 18),
                          label: Text(
                            selectedIds.isEmpty ? 'Select Files to Import' : 'Import (${selectedIds.length})',
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

  void _viewWorkFile(amplify_models.Deals workFile) {
    showDialog(
      context: context,
      builder: (context) => WorkFileDetailDialog(
        workFile: workFile,
        allWorkFiles: _workFiles,
        onUpdate: _fetchWorkFiles,
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
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
            title: 'All Files',
            subtitle: 'Complete Archive',
            icon: Icons.folder_copy_rounded,
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
        _applyFilterAndSort();
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
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: PremiumAppBar(
        title: const Text('Work File', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 24)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateDialog,
        icon: const Icon(Icons.add),
        label: const Text('New Work File'),
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPeriodSelector(),
            Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10)],
                    ),
                    child: TextField(
                      controller: _searchController,
                      onChanged: _filterWorkFiles,
                      decoration: const InputDecoration(
                        hintText: 'Search work files by name or client...',
                        prefixIcon: Icon(Icons.search_rounded),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10)],
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _sortOption,
                      icon: const Icon(Icons.sort_rounded, color: AppTheme.primaryColor),
                      style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
                      onChanged: (String? newValue) {
                        if (newValue != null) {
                          setState(() {
                            _sortOption = newValue;
                          });
                          _applyFilterAndSort();
                        }
                      },
                      items: <String>[
                        'Newest First', 'Oldest First', 'A-Z', 'Z-A', 
                        'Highest Amount', 'Lowest Amount', 
                        'Invoice No (A-Z)', 'Invoice No (Z-A)',
                        'Legal Only', 'Consultancy Only'
                      ].map<DropdownMenuItem<String>>((String value) {
                        return DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _selectedStaffFilter != null ? const Color(0xFF2563EB) : Colors.transparent,
                    ),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10)],
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value: _selectedStaffFilter,
                      icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF2563EB)),
                      hint: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person, size: 16, color: Color(0xFF64748B)),
                          SizedBox(width: 6),
                          Text('All Staff', style: TextStyle(color: Color(0xFF1E293B), fontWeight: FontWeight.bold, fontSize: 13)),
                        ],
                      ),
                      onChanged: (val) {
                        setState(() {
                          _selectedStaffFilter = val;
                        });
                        _applyFilterAndSort();
                      },
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.people_alt_rounded, size: 16, color: Color(0xFF64748B)),
                              SizedBox(width: 6),
                              Text('All Staff (Everyone)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                        DropdownMenuItem<String?>(
                          value: 'Unassigned',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.person_off_rounded, size: 16, color: Colors.amber),
                              const SizedBox(width: 6),
                              Text(
                                'Unassigned (${_workFiles.where((w) => w.responsible_name == null || w.responsible_name!.trim().isEmpty).length})',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.amber),
                              ),
                            ],
                          ),
                        ),
                        ..._activeStaffNames.map((name) {
                          final count = _workFiles.where((w) {
                            final rName = (w.responsible_name ?? '').toLowerCase().trim();
                            return rName.isNotEmpty && (rName == name.toLowerCase() || rName.startsWith(name.toLowerCase()));
                          }).length;
                          return DropdownMenuItem<String?>(
                            value: name,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 9,
                                  backgroundColor: const Color(0xFFE0E7FF),
                                  child: Text(name[0], style: const TextStyle(fontSize: 9, color: Color(0xFF3730A3), fontWeight: FontWeight.bold)),
                                ),
                                const SizedBox(width: 6),
                                Text('$name ($count)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: _showStaffWorkloadTrackerDialog,
                  icon: const Icon(Icons.pie_chart_outline_rounded, color: Color(0xFF6366F1)),
                  tooltip: 'Staff Workload Tracker (Track Who is Doing Works)',
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.1),
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: _fetchWorkFiles,
                  icon: const Icon(Icons.refresh_rounded, color: AppTheme.primaryColor),
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                    padding: const EdgeInsets.all(12),
                  ),
                ),
              ],
            ).animate().fadeIn().slideY(begin: -0.1),
            const SizedBox(height: 24),
            Expanded(
              child: _isLoading 
                  ? const Center(child: CircularProgressIndicator())
                  : _filtered.isEmpty
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
                                      'Starting fresh from Nov 1, 2026! No new work files created yet.\nPrevious files are safely archived in the "2025-2026" button ($_count2025_2026 files).',
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
                                            _applyFilterAndSort();
                                          },
                                          icon: const Icon(Icons.history_rounded, size: 18),
                                          label: Text('Open 2025-2026 Files ($_count2025_2026)'),
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
                                          onPressed: _showCreateDialog,
                                          icon: const Icon(Icons.add, size: 18),
                                          label: const Text('Create New Work File'),
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
                                    Icon(Icons.folder_off_rounded, size: 64, color: Colors.grey.shade300),
                                    const SizedBox(height: 16),
                                    Text('No work files found for this period', style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                                  ],
                                ),
                        )
                      : GridView.builder(
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 400,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                            mainAxisExtent: 255,
                          ),
                          itemCount: _filtered.length,
                          itemBuilder: (context, index) {
                            final workFile = _filtered[index];
                            final bool isSubWork = workFile.pipeline == 'Sub Work';
                            return Card(
                              elevation: 2,
                              color: isSubWork ? Colors.deepPurple.shade50 : null,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () => _viewWorkFile(workFile),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Row(
                                        children: [
                                          CircleAvatar(
                                            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                                            child: const Icon(Icons.work_history_rounded, color: AppTheme.primaryColor),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              workFile.name ?? 'Untitled', 
                                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.edit_outlined, color: Colors.blue, size: 20),
                                            tooltip: 'Edit Work File',
                                            onPressed: () => _editWorkFile(workFile),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.visibility_outlined, color: Colors.green, size: 20),
                                            tooltip: 'View Work File',
                                            onPressed: () => _viewWorkFile(workFile),
                                          ),
                                          if (_getWorkFileDate(workFile).isBefore(nov1Cutoff))
                                            IconButton(
                                              icon: const Icon(Icons.drive_file_move_outlined, color: Color(0xFF10B981), size: 20),
                                              tooltip: 'Import to Current (2026-2027)',
                                              onPressed: () => _importSingleWorkFileToCurrent(workFile),
                                            ),
                                          IconButton(
                                            icon: const Icon(Icons.download_rounded, color: Colors.purple, size: 20),
                                            tooltip: 'Download Documents',
                                            onPressed: () {
                                              if (workFile.drive_link != null && workFile.drive_link!.isNotEmpty) {
                                                try {
                                                  final parsed = jsonDecode(workFile.drive_link!);
                                                  if (parsed is List && parsed.isNotEmpty) {
                                                    launchUrl(Uri.parse(parsed.first['url'] ?? parsed.first['link'] ?? workFile.drive_link!));
                                                  } else {
                                                    launchUrl(Uri.parse(workFile.drive_link!));
                                                  }
                                                } catch (e) {
                                                  launchUrl(Uri.parse(workFile.drive_link!));
                                                }
                                              } else {
                                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No documents attached')));
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                      if (true) ...[
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 4,
                                          children: [
                                            if (isSubWork)
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: Colors.deepPurple.shade100,
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  'Sub Work',
                                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.deepPurple.shade900),
                                                ),
                                              ),
                                            if (workFile.register_no != null && workFile.register_no!.isNotEmpty)
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: Colors.amber.shade100,
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  'File No: ${workFile.register_no}',
                                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber.shade900),
                                                ),
                                              ),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: Colors.blue.shade100,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                (workFile.work_type != null && workFile.work_type!.trim().isNotEmpty) ? '${workFile.work_type}' : 'Type: N/A',
                                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue.shade900),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      const Spacer(),
                                      Text(
                                        'Client: ${workFile.client_name ?? "Unknown"}',
                                        style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 6),
                                      // Staff Doing Work Badge (Tap to Mark / Assign Staff)
                                      Row(
                                        children: [
                                          Expanded(
                                            child: InkWell(
                                              onTap: () => _showQuickAssignStaffDialog(workFile),
                                              borderRadius: BorderRadius.circular(16),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: (workFile.responsible_name != null && workFile.responsible_name!.trim().isNotEmpty)
                                                      ? const Color(0xFF2563EB).withValues(alpha: 0.08)
                                                      : Colors.amber.shade50,
                                                  borderRadius: BorderRadius.circular(16),
                                                  border: Border.all(
                                                    color: (workFile.responsible_name != null && workFile.responsible_name!.trim().isNotEmpty)
                                                        ? const Color(0xFF2563EB).withValues(alpha: 0.25)
                                                        : Colors.amber.shade300,
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    if (workFile.responsible_name != null && workFile.responsible_name!.trim().isNotEmpty) ...[
                                                      CircleAvatar(
                                                        radius: 8,
                                                        backgroundColor: const Color(0xFF2563EB),
                                                        child: Text(
                                                          workFile.responsible_name![0].toUpperCase(),
                                                          style: const TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 5),
                                                      Expanded(
                                                        child: Text(
                                                          'Doing: ${workFile.responsible_name!}',
                                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF1D4ED8)),
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                      ),
                                                      const Icon(Icons.edit_outlined, size: 11, color: Color(0xFF2563EB)),
                                                    ] else ...[
                                                      Icon(Icons.person_add_alt_1_rounded, size: 12, color: Colors.amber.shade900),
                                                      const SizedBox(width: 4),
                                                      Expanded(
                                                        child: Text(
                                                          'Unassigned • Mark Staff',
                                                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amber.shade900),
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.calendar_today, size: 11, color: Colors.grey.shade500),
                                              const SizedBox(width: 3),
                                              Text(
                                                workFile.createdAt?.getDateTimeInUtc().toString().split(' ')[0] ?? '',
                                                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ).animate().fadeIn(delay: (50 * index).ms).slideX(begin: 0.05);
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class WorkFileDetailDialog extends StatefulWidget {
  final amplify_models.Deals workFile;
  final List<amplify_models.Deals> allWorkFiles;
  final VoidCallback onUpdate;
  
  const WorkFileDetailDialog({super.key, required this.workFile, required this.allWorkFiles, required this.onUpdate});

  @override
  State<WorkFileDetailDialog> createState() => _WorkFileDetailDialogState();
}

class _WorkFileDetailDialogState extends State<WorkFileDetailDialog> {
  late amplify_models.Deals _currentWorkFile;
  bool _isUploading = false;
  List<amplify_models.ActivityLogs> _logs = [];
  bool _isLoadingLogs = true;
  List<amplify_models.Deals> _subWorks = [];

  @override
  void initState() {
    super.initState();
    _currentWorkFile = widget.workFile;
    _subWorks = widget.allWorkFiles.where((w) => w.contact_status == _currentWorkFile.id).toList();
    _fetchLogs();
  }

  Future<void> _fetchLogs() async {
    setState(() => _isLoadingLogs = true);
    try {
      final req = ModelQueries.list(
        amplify_models.ActivityLogs.classType,
        where: amplify_models.ActivityLogs.TARGET_ID.eq(_currentWorkFile.name),
        limit: 1000,
      );
      final res = await Amplify.API.query(request: req).response;
      if (res.data != null) {
        final fetchedLogs = res.data!.items.whereType<amplify_models.ActivityLogs>().toList();
        fetchedLogs.sort((a, b) => (b.createdAt?.getDateTimeInUtc() ?? DateTime.now())
            .compareTo(a.createdAt?.getDateTimeInUtc() ?? DateTime.now()));
        if (mounted) setState(() => _logs = fetchedLogs);
      }
    } catch (e) {
      debugPrint('Error fetching logs: $e');
    } finally {
      if (mounted) setState(() => _isLoadingLogs = false);
    }
  }

  Future<void> _launchUrl(String urlString) async {
    final Uri url = Uri.parse(urlString);
    if (!await launchUrl(url)) {
      debugPrint('Could not launch $urlString');
    }
  }

  Future<void> _downloadFile(BuildContext context, String path) async {
    try {
      final result = await Amplify.Storage.getUrl(path: StoragePath.fromString(path)).result;
      _launchUrl(result.url.toString());
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open file: $e')));
      }
    }
  }

  Future<void> _selectFromVault() async {
    final clientId = _currentWorkFile.company ?? '';
    if (clientId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Client ID not found on this Work File.')));
      return;
    }
    
    Client? client;
    try {
      final req = ModelQueries.get(amplify_models.Clients.classType, amplify_models.ClientsModelIdentifier(id: clientId));
      final res = await Amplify.API.query(request: req).response;
      if (res.data != null) {
        final dbClient = res.data!;
        client = Client(
          id: dbClient.id,
          name: dbClient.name ?? 'Unknown',
          email: dbClient.email,
          phone: dbClient.phone,
          address: dbClient.address,
        );
      }
    } catch (e) {
      debugPrint('Error fetching client: $e');
    }

    if (client == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not load Client details.')));
      return;
    }

    if (!mounted) return;
    
    final selectedPath = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => ClientFilesDialog(client: client!, isSelectionMode: true),
    );

    if (selectedPath != null && mounted) {
      _attachFileToWork(selectedPath);
    }
  }

  Future<void> _removeFileItem(int index) async {
    setState(() => _isUploading = true);
    try {
      List<dynamic> currentFiles = [];
      if (_currentWorkFile.files_received != null && _currentWorkFile.files_received!.isNotEmpty) {
        currentFiles = jsonDecode(_currentWorkFile.files_received!);
      }
      currentFiles.removeAt(index);
      
      final updatedDeal = _currentWorkFile.copyWith(files_received: jsonEncode(currentFiles));
      await BackupAwareApi().update(updatedDeal);
      
      setState(() {
        _currentWorkFile = updatedDeal;
      });
      widget.onUpdate();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _attachFileToWork(String path) async {
    setState(() => _isUploading = true);
    try {
      List<dynamic> files = [];
      if (_currentWorkFile.files_received != null && _currentWorkFile.files_received!.isNotEmpty) {
        try {
          final decoded = jsonDecode(_currentWorkFile.files_received!);
          if (decoded is List) {
            files = decoded.toList();
          }
        } catch (e) {
          debugPrint("Parse error in attach: $e");
        }
      }
      
      if (!files.contains(path)) {
        files.add(path);
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File is already attached.')));
        setState(() => _isUploading = false);
        return;
      }
      
      final updatedDeal = _currentWorkFile.copyWith(files_received: jsonEncode(files));
      final req = ModelMutations.update(updatedDeal);
      await BackupAwareApi().update(updatedDeal);

      if (mounted) {
        setState(() {
          _currentWorkFile = updatedDeal;
        });
        widget.onUpdate();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File attached successfully!')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _handoverWorkFile() async {
    List<amplify_models.Users> staffList = [];
    try {
      final req = ModelQueries.list(amplify_models.Users.classType, limit: 1000);
      final res = await Amplify.API.query(request: req).response;
      if (res.data != null) {
        final List<amplify_models.Users> fetched = res.data!.items.whereType<amplify_models.Users>().toList();
        final List<amplify_models.Users> deduplicated = [];
        for (var staff in fetched) {
          final name = (staff.name ?? staff.username ?? 'Unknown').trim();
          if (name == 'Unknown' || name.isEmpty) continue;
          
          bool isDuplicate = false;
          for (int i = 0; i < deduplicated.length; i++) {
            final existingName = (deduplicated[i].name ?? deduplicated[i].username ?? '').trim();
            final n1 = name.toLowerCase();
            final n2 = existingName.toLowerCase();
            
            if (n1.startsWith(n2) || n2.startsWith(n1)) {
              isDuplicate = true;
              if (name.length > existingName.length) {
                deduplicated[i] = staff;
              }
              break;
            }
          }
          
          if (!isDuplicate) {
            deduplicated.add(staff);
          }
        }
        staffList = deduplicated;
        staffList.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      }
    } catch (e) {
      debugPrint('Error fetching staff: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error loading staff.')));
      return;
    }

    if (!mounted) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Handover Work File'),
          content: SizedBox(
            width: 300,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: staffList.length,
              itemBuilder: (context, index) {
                final staff = staffList[index];
                return ListTile(
                  leading: const Icon(Icons.person, color: AppTheme.primaryColor),
                  title: Text(staff.name ?? staff.username ?? 'Unknown'),
                  onTap: () {
                    showDialog<Map<String, String>>(
                      context: context,
                      builder: (ctx) {
                        final reasonController = TextEditingController();
                        final remarksController = TextEditingController();
                        return AlertDialog(
                          title: Text('Handover to ${staff.name}'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(
                                controller: reasonController,
                                decoration: const InputDecoration(
                                  labelText: 'Reason (Optional)',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: remarksController,
                                decoration: const InputDecoration(
                                  labelText: 'Remarks (Optional)',
                                  border: OutlineInputBorder(),
                                ),
                                maxLines: 3,
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(ctx, {'reason': reasonController.text.trim(), 'remarks': remarksController.text.trim()}),
                              child: const Text('Confirm'),
                            ),
                          ],
                        );
                      }
                    ).then((data) {
                      if (data != null) {
                        Navigator.pop(context, {'staff': staff, 'reason': data['reason'], 'remarks': data['remarks']});
                      }
                    });
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ],
        );
      },
    );

    if (result != null && mounted) {
      final selectedStaff = result['staff'] as amplify_models.Users;
      final reason = result['reason'] as String?;
      final remarks = result['remarks'] as String?;

      setState(() => _isUploading = true);
      try {
        final updatedDeal = _currentWorkFile.copyWith(
          responsible_id: int.tryParse(selectedStaff.id),
          responsible_name: selectedStaff.name,
        );
        final req = ModelMutations.update(updatedDeal);
        await BackupAwareApi().update(updatedDeal);
        
        String detailsText = 'Handed over Work File to ${selectedStaff.name}';
        if (reason != null && reason.isNotEmpty) detailsText += ' - Reason: $reason';
        if (remarks != null && remarks.isNotEmpty) detailsText += ' - Remarks: $remarks';

        await LoggingService().logAction(
          action: 'WORK_FILE_HANDOVER',
          targetType: 'WorkFile',
          targetId: updatedDeal.name,
          details: detailsText,
        );

        setState(() => _currentWorkFile = updatedDeal);
        _fetchLogs();
        widget.onUpdate();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Work File Handed Over successfully!')));
      } catch (e) {
        debugPrint('Error handing over: $e');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error handing over: $e')));
      } finally {
        if (mounted) setState(() => _isUploading = false);
      }
    }
  }

  void _showHistoryDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Work File History'),
          content: SizedBox(
            width: 400,
            height: 300,
            child: _isLoadingLogs 
              ? const Center(child: CircularProgressIndicator())
              : _logs.isEmpty 
                  ? const Center(child: Text('No history found.'))
                  : ListView.builder(
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final log = _logs[index];
                        return ListTile(
                          leading: const Icon(Icons.history, color: Colors.blue),
                          title: Text(log.details ?? log.action ?? 'Unknown Action'),
                          subtitle: Text(log.createdAt?.getDateTimeInUtc().toLocal().toString().split('.')[0] ?? ''),
                        );
                      },
                    ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        );
      },
    );
  }

  Future<void> _addSubWork() async {
    List<amplify_models.Users> staffList = [];
    try {
      final req = ModelQueries.list(amplify_models.Users.classType, limit: 1000);
      final res = await Amplify.API.query(request: req).response;
      if (res.data != null) {
        final List<amplify_models.Users> fetched = res.data!.items.whereType<amplify_models.Users>().toList();
        final List<amplify_models.Users> deduplicated = [];
        for (var staff in fetched) {
          final name = (staff.name ?? staff.username ?? 'Unknown').trim();
          if (name == 'Unknown' || name.isEmpty) continue;
          
          bool isDuplicate = false;
          for (int i = 0; i < deduplicated.length; i++) {
            final existingName = (deduplicated[i].name ?? deduplicated[i].username ?? '').trim();
            final n1 = name.toLowerCase();
            final n2 = existingName.toLowerCase();
            
            if (n1.startsWith(n2) || n2.startsWith(n1)) {
              isDuplicate = true;
              if (name.length > existingName.length) {
                deduplicated[i] = staff;
              }
              break;
            }
          }
          if (!isDuplicate) deduplicated.add(staff);
        }
        staffList = deduplicated;
        staffList.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      }
    } catch (e) {
      debugPrint('Error fetching staff: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error loading staff.')));
      return;
    }

    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final currentUserName = prefs.getString('current_user_name') ?? 'Unknown';

    showDialog(
      context: context,
      builder: (context) {
        final nameCtrl = TextEditingController();
        final typeCtrl = TextEditingController();
        amplify_models.Users? selectedStaff;
        DateTime? selectedDeadline;
        bool isSaving = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Create Sub Work'),
              content: SizedBox(
                width: 400,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(labelText: 'Work Name', border: OutlineInputBorder()),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: typeCtrl,
                        decoration: const InputDecoration(labelText: 'Work Type', border: OutlineInputBorder()),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<amplify_models.Users>(
                        decoration: const InputDecoration(labelText: 'Assign To', border: OutlineInputBorder()),
                        value: selectedStaff,
                        items: staffList.map((s) => DropdownMenuItem(value: s, child: Text(s.name ?? s.username ?? 'Unknown'))).toList(),
                        onChanged: (val) => setDialogState(() => selectedStaff = val),
                      ),
                      const SizedBox(height: 16),
                      ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                          side: BorderSide(color: Colors.grey.shade400),
                        ),
                        title: Text(selectedDeadline == null ? 'Select Deadline' : 'Deadline: ${selectedDeadline!.toLocal().toString().split(' ')[0]}'),
                        trailing: const Icon(Icons.calendar_today),
                        onTap: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 3650)),
                          );
                          if (date != null) setDialogState(() => selectedDeadline = date);
                        },
                      ),
                      if (isSaving) const Padding(padding: EdgeInsets.only(top: 16), child: Center(child: CircularProgressIndicator())),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                ElevatedButton(
                  onPressed: isSaving ? null : () async {
                    if (nameCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Work name is required')));
                      return;
                    }
                    setDialogState(() => isSaving = true);
                    try {
                      final newSubWork = amplify_models.Deals(
                        name: nameCtrl.text.trim(),
                        client_name: _currentWorkFile.client_name,
                        company: _currentWorkFile.company,
                        pipeline: 'Sub Work',
                        contact_status: _currentWorkFile.id,
                        stage: 'Active',
                        work_type: typeCtrl.text.trim(),
                        responsible_id: selectedStaff != null ? int.tryParse(selectedStaff!.id) : null,
                        responsible_name: selectedStaff?.name ?? selectedStaff?.username,
                        closed_at: selectedDeadline?.toIso8601String(),
                        referred_by: currentUserName,
                        created_at: DateTime.now().toIso8601String(),
                        updated_at: DateTime.now().toIso8601String(),
                      );
                      
                      await BackupAwareApi().create(newSubWork);
                      
                      await LoggingService().logAction(
                        action: 'SUB_WORK_CREATED',
                        targetType: 'WorkFile',
                        targetId: newSubWork.name,
                        details: 'Created Sub Work "${newSubWork.name}" for parent "${_currentWorkFile.name}"',
                      );

                      if (mounted) {
                        setState(() {
                          _subWorks.add(newSubWork);
                        });
                        widget.onUpdate();
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sub work created successfully!')));
                      }
                    } catch (e) {
                      debugPrint('Error creating sub work: $e');
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                    } finally {
                      setDialogState(() => isSaving = false);
                    }
                  },
                  child: const Text('Create'),
                ),
              ],
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    List<dynamic> files = [];
    if (_currentWorkFile.files_received != null && _currentWorkFile.files_received!.isNotEmpty) {
      try {
        final decoded = jsonDecode(_currentWorkFile.files_received!);
        if (decoded is List) {
          // Check for corrupted strings like "{name: Sale deed, status: Returned, type: Copy}"
          files = decoded.map((e) {
            if (e is String && e.startsWith('{name:') && e.endsWith('}')) {
              try {
                final inner = e.substring(1, e.length - 1);
                final parts = inner.split(', ');
                Map<String, dynamic> result = {};
                for (var p in parts) {
                  final kv = p.split(': ');
                  if (kv.length == 2) result[kv[0].trim()] = kv[1].trim();
                }
                return result;
              } catch (_) {
                return e;
              }
            }
            return e;
          }).toList();
        }
      } catch (e) {
        debugPrint("Error parsing files JSON: $e");
      }
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 500,
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _currentWorkFile.name ?? 'Work File Details', 
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      if (_currentWorkFile.register_no != null && _currentWorkFile.register_no!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text('File No: ${_currentWorkFile.register_no}', style: TextStyle(color: Colors.amber.shade700, fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          Text('Type: ${_currentWorkFile.work_type != null && _currentWorkFile.work_type!.trim().isNotEmpty ? _currentWorkFile.work_type : "N/A"}', style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.w600, fontSize: 13)),
                          Text('Status: ${_currentWorkFile.stage ?? "Unknown"}', style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600, fontSize: 13)),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const SizedBox(height: 8),
            Text('Client: ${_currentWorkFile.client_name ?? "Unknown"}', style: TextStyle(color: Colors.grey.shade600, fontSize: 16)),
            const SizedBox(height: 4),
            Text('Created By: ${_currentWorkFile.referred_by ?? "Unknown"}', style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
            
            Builder(
              builder: (context) {
                amplify_models.Deals? parentWorkFile;
                if (_currentWorkFile.contact_status != null && _currentWorkFile.contact_status!.isNotEmpty) {
                  try {
                    parentWorkFile = widget.allWorkFiles.firstWhere((w) => w.id == _currentWorkFile.contact_status);
                  } catch (_) {}
                }
                
                if (parentWorkFile != null) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Text('Main File: ', style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
                        InkWell(
                          onTap: () {
                            Navigator.pop(context);
                            showDialog(
                              context: context,
                              builder: (context) => WorkFileDetailDialog(
                                workFile: parentWorkFile!,
                                allWorkFiles: widget.allWorkFiles,
                                onUpdate: widget.onUpdate,
                              ),
                            );
                          },
                          child: Text(
                            parentWorkFile.name ?? 'Unknown',
                            style: const TextStyle(color: Colors.blue, fontSize: 14, decoration: TextDecoration.underline),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Handled By: ${_currentWorkFile.responsible_name ?? "Unassigned"}', style: TextStyle(color: Colors.grey.shade800, fontSize: 15, fontWeight: FontWeight.w500)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: _showHistoryDialog,
                      icon: const Icon(Icons.history, size: 18),
                      label: const Text('History'),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _handoverWorkFile,
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('Handover'),
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.orange.shade50,
                        foregroundColor: Colors.orange.shade800,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 24),
            
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Sub Works', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                TextButton.icon(
                  onPressed: _addSubWork,
                  icon: const Icon(Icons.add_link, size: 18),
                  label: const Text('Add Sub Work'),
                ),
              ],
            ),
            if (_subWorks.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 8),
                constraints: const BoxConstraints(maxHeight: 150),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _subWorks.length,
                  itemBuilder: (context, index) {
                    final sw = _subWorks[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.subdirectory_arrow_right, color: Colors.blue),
                      title: Text(sw.name ?? 'Untitled'),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                border: Border.all(color: Colors.green.shade200),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                sw.stage ?? 'Unknown',
                                style: TextStyle(color: Colors.green.shade700, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('Handled By: ${sw.responsible_name ?? "Unassigned"}', style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20),
                        onPressed: () async {
                          setState(() => _isUploading = true);
                          try {
                            final updatedWF = sw.copyWith(contact_status: '');
                            await BackupAwareApi().update(updatedWF);
                            setState(() {
                              _subWorks.removeWhere((w) => w.id == sw.id);
                            });
                            widget.onUpdate();
                          } catch (e) {
                            debugPrint('Error removing sub work: $e');
                          } finally {
                            if (mounted) setState(() => _isUploading = false);
                          }
                        },
                        tooltip: 'Remove Sub Work',
                      ),
                    );
                  },
                ),
              ),
              
            const Divider(height: 24),

            if (_currentWorkFile.drive_link != null && _currentWorkFile.drive_link!.isNotEmpty) ...[
              const Text('Google Docs', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.description, color: Colors.blue),
                title: const Text('Open connected Google Doc'),
                subtitle: Text(_currentWorkFile.drive_link!, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => _launchUrl(_currentWorkFile.drive_link!),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade300)),
              ),
              const SizedBox(height: 24),
            ],

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Connected Files', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                if (_isUploading)
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  TextButton.icon(
                    onPressed: _selectFromVault,
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: const Text('Add File'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            
            if (files.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(child: Text('No files attached to this work.', style: TextStyle(color: Colors.grey.shade500))),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    final item = files[index];
                    
                    if (item is Map) {
                      // Physical Document Record
                      final name = item['name'] ?? 'Unknown Document';
                      final type = item['type'] ?? 'Unknown Type';
                      final status = item['status'] ?? 'Unknown Status';
                      
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.file_present_rounded, color: Colors.amber),
                          ),
                          title: Text(name.toString(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                                  child: Text(type.toString(), style: TextStyle(color: Colors.blue.shade700, fontSize: 10, fontWeight: FontWeight.bold)),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: status == 'Returned' ? Colors.green.withValues(alpha: 0.1) : Colors.orange.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                                  child: Text(status.toString(), style: TextStyle(color: status == 'Returned' ? Colors.green.shade700 : Colors.orange.shade700, fontSize: 10, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    } else {
                      // Digital File Path
                      final path = item.toString();
                      final fileName = path.split('/').last;
                      final isPersonal = path.contains('/personal/');
                      final category = isPersonal ? 'Personal' : 'Work';
                      
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                            child: Icon(isPersonal ? Icons.person : Icons.cloud_done, color: AppTheme.primaryColor),
                          ),
                          title: Text(fileName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(category, style: TextStyle(fontSize: 12, color: isPersonal ? Colors.purple.shade700 : Colors.blue.shade700)),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.download_rounded, color: Colors.blue),
                            onPressed: () => _downloadFile(context, path),
                            tooltip: 'Open / Download',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

