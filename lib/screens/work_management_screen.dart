import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../services/supabase_backup_service.dart';
import '../services/backup_aware_api.dart';
import '../services/logging_service.dart';
import '../theme.dart';
import '../models/deal.dart';
import '../models/deal_activity.dart';
import '../services/deal_service.dart';
import 'deal_detail_screen.dart';
import 'workfile_management_screen.dart';
import 'google_docs_webview_screen.dart';

class WorkManagementScreen extends StatefulWidget {
  final bool showOnlyVerification;
  const WorkManagementScreen({super.key, this.showOnlyVerification = false});

  @override
  State<WorkManagementScreen> createState() => _WorkManagementScreenState();
}

class _WorkManagementScreenState extends State<WorkManagementScreen> {
  final _dealService = DealService();
  List<Deal> _allDeals = [];
  List<amplify_models.Users> _allStaffList = [];
  final Map<String, int> _staffIdMap = {};
  bool _isLoading = true;

  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _showOnlyMyWorks = false;
  int? _currentUserId;
  StreamSubscription? _dealsSubscription;

  static final DateTime nov1Cutoff = DateTime(2026, 11, 1);
  String _selectedPeriod = '2026-2027'; // '2026-2027', '2025-2026', 'All'
  String? _selectedStaffFilter;
  String _sortOption = 'Newest First';

  DateTime _getDealDate(Deal d) {
    if (d.createdAt != null) return d.createdAt!;
    return DateTime(2000);
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentUserId();
    _fetchStaff();
    _subscribeToDeals();
  }

  void _subscribeToDeals() {
    setState(() => _isLoading = true);
    _dealsSubscription = _dealService.getDealsStream().listen((deals) {
      if (mounted) {
        setState(() {
          _allDeals = deals;
          _isLoading = false;
        });
      }
    }, onError: (e) {
      debugPrint('Error loading deals: $e');
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  void dispose() {
    _dealsSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _currentUserId = prefs.getInt('current_user_id');
      });
    }
  }

  Future<void> _fetchStaff() async {
    try {
      final req = ModelQueries.list(amplify_models.Users.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      final fetched = (res.data?.items ?? []).whereType<amplify_models.Users>().toList();
      final sbUserMap = await SupabaseBackupService().getUsernameToIdMap();

      final Map<String, amplify_models.Users> byName = {};
      for (final u in fetched) {
        final displayName = (u.name?.isNotEmpty == true ? u.name! : (u.username ?? '')).trim();
        if (displayName.isEmpty) continue;
        final key = displayName.toLowerCase();
        if (!byName.containsKey(key)) {
          byName[key] = u;
        }
        if (sbUserMap.containsKey(key)) {
          _staffIdMap[key] = sbUserMap[key]!;
        }
      }

      final deduplicated = byName.values.toList()
        ..sort((a, b) {
          final na = (a.name?.isNotEmpty == true ? a.name! : (a.username ?? '')).toLowerCase();
          final nb = (b.name?.isNotEmpty == true ? b.name! : (b.username ?? '')).toLowerCase();
          return na.compareTo(nb);
        });

      if (mounted) setState(() => _allStaffList = deduplicated);
    } catch (e) {
      debugPrint('Error fetching staff in WorkManagementScreen: $e');
    }
  }

  Future<void> _refreshDeals() async {
    try {
      _fetchStaff();
      final deals = await _dealService.getAllDeals();
      if (mounted) {
        setState(() {
          _allDeals = deals;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error refreshing deals: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openDealDetail([Deal? deal]) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WorkfileManagementScreen(existingDeal: deal),
      ),
    ).then((_) => _refreshDeals());
  }

  Future<void> _deleteDeal(Deal deal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Work'),
        content: Text('Are you sure you want to delete "${deal.name}"? This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _dealService.deleteDeal(deal.id!);
        await LoggingService().logAction(
          action: 'DEAL_DELETED',
          targetType: 'Deal',
          targetId: deal.name,
          details: 'Deleted work "${deal.name}"',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Work deleted successfully'), backgroundColor: Colors.green),
          );
          _refreshDeals();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting work: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _handleVerification(Deal deal, bool isVerified) async {
    if (isVerified) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm Verification'),
          content: const Text('Are you sure you want to verify this work and move it to the next stage?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
            TextButton(
              onPressed: () => Navigator.pop(context, true), 
              style: TextButton.styleFrom(foregroundColor: Colors.green),
              child: const Text('VERIFY')
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      try {
        await _dealService.addActivity(DealActivity(
          dealId: deal.id!,
          type: 'note',
          title: 'Work Verified',
          description: 'Work verified by manager/admin.',
          createdBy: _currentUserId ?? 1,
        ));
        await _dealService.moveDealToStage(deal.id!, 'Verification', 'Invoice');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Work Verified! Moved to Invoice stage.'), backgroundColor: Colors.green));
          _refreshDeals();
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    } else {
      final remarkController = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Not Verified'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Please provide remarks for reverification:'),
              const SizedBox(height: 12),
              TextField(
                controller: remarkController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Enter remarks...',
                ),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
            TextButton(
              onPressed: () => Navigator.pop(context, true), 
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('SUBMIT')
            ),
          ],
        ),
      );

      if (confirmed == true && remarkController.text.trim().isNotEmpty) {
        try {
          await _dealService.addActivity(DealActivity(
            dealId: deal.id!,
            type: 'note',
            title: 'Reverification Needed',
            description: 'Returned for reverification. Remarks: ${remarkController.text.trim()}',
            createdBy: _currentUserId ?? 1,
          ));
          await _dealService.moveDealToStage(deal.id!, 'Verification', 'In Progress');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent for reverification'), backgroundColor: Colors.orange));
            _refreshDeals();
          }
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
        }
      } else if (confirmed == true && remarkController.text.trim().isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Remarks are required'), backgroundColor: Colors.red));
      }
    }
  }

  void _showQuickAssignStaffDialog(Deal deal) {
    final searchCtrl = TextEditingController();
    showDialog(
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
                  mainAxisSize: MainAxisSize.min,
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
                          child: const Icon(Icons.person_pin_rounded, color: Color(0xFF2563EB), size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Mark Who is Doing Work',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                              ),
                              Text(
                                deal.name,
                                style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                            ? const Color(0xFFEFF6FF)
                            : const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                              ? const Color(0xFFBFDBFE)
                              : const Color(0xFFFDE68A),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                ? Icons.check_circle_rounded
                                : Icons.warning_amber_rounded,
                            color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                ? const Color(0xFF2563EB)
                                : Colors.amber.shade800,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                  ? 'Currently Assigned to: ${deal.responsibleName}'
                                  : 'Status: Unassigned (Tap a staff member below to assign)',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                    ? const Color(0xFF1E40AF)
                                    : Colors.amber.shade900,
                              ),
                            ),
                          ),
                          if (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await _assignStaffToDeal(deal, null);
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.redAccent,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                              ),
                              child: const Text('Unassign', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
                        prefixIcon: const Icon(Icons.search, size: 20, color: Color(0xFF64748B)),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('Select Staff Member:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
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
                                final isCurrent = (deal.responsibleName ?? '').toLowerCase() == staffName.toLowerCase();
                                
                                final firstWord = staffName.split(' ').first.toLowerCase();
                                final staffWorksCount = _allDeals.where((d) {
                                  final rName = (d.responsibleName ?? '').toLowerCase().trim();
                                  return rName.isNotEmpty && (rName == staffName.toLowerCase() || rName.startsWith(firstWord));
                                }).length;

                                return Material(
                                  color: isCurrent ? const Color(0xFF2563EB).withValues(alpha: 0.08) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () async {
                                      Navigator.pop(ctx);
                                      await _assignStaffToDeal(deal, staff);
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
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF1F5F9),
                                              borderRadius: BorderRadius.circular(20),
                                            ),
                                            child: Text(
                                              '$staffWorksCount active works',
                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (isCurrent)
                                            const Icon(Icons.check_circle_rounded, color: Color(0xFF2563EB), size: 20)
                                          else
                                            const Icon(Icons.chevron_right_rounded, color: Color(0xFF94A3B8), size: 20),
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

  Future<void> _assignStaffToDeal(Deal deal, amplify_models.Users? staff) async {
    final staffName = staff == null 
        ? null 
        : (staff.name?.isNotEmpty == true ? staff.name! : (staff.username ?? 'Staff'));
    
    int? resolvedUserId;
    if (staff != null) {
      final key = staffName!.toLowerCase();
      resolvedUserId = _staffIdMap[key];
      if (resolvedUserId == null) {
        final match = RegExp(r'\d+').firstMatch(staff.id);
        if (match != null) resolvedUserId = int.tryParse(match.group(0)!);
      }
    }

    try {
      if (deal.id != null) {
        if (staff != null && resolvedUserId != null) {
          try {
            await _dealService.addAssignee(deal.id!, resolvedUserId, role: 'Lead');
          } catch (e) {
            debugPrint('Error adding assignee through DealService: $e');
          }
        }

        try {
          final req = ModelQueries.get(amplify_models.Deals.classType, amplify_models.DealsModelIdentifier(id: deal.id.toString()));
          final res = await Amplify.API.query(request: req).response;
          if (res.data != null) {
            final updatedAmplify = res.data!.copyWith(
              responsible_id: resolvedUserId,
              responsible_name: staffName,
            );
            await BackupAwareApi().update(updatedAmplify);
          }
        } catch (e) {
          debugPrint('Error updating deal directly on Amplify: $e');
        }

        await LoggingService().logAction(
          action: staff == null ? 'WORK_UNASSIGNED' : 'WORK_ASSIGNED',
          targetType: 'Deal',
          targetId: deal.name,
          details: staff == null
              ? 'Unassigned staff from work "${deal.name}"'
              : 'Assigned "$staffName" to work "${deal.name}"',
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                staff == null
                    ? 'Work marked as Unassigned'
                    : 'Assigned to $staffName. WhatsApp alert sent!',
              ),
              backgroundColor: const Color(0xFF10B981),
            ),
          );
          _refreshDeals();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error assigning staff: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _showStaffWorkloadTrackerDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.pie_chart_outline_rounded, color: Color(0xFF2563EB)),
            SizedBox(width: 10),
            Text('Staff Workload Tracker', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 480,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Live overview of works distributed across team members:', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    // Unassigned works summary
                    Builder(builder: (context) {
                      final unassignedWorks = _allDeals.where((d) => d.responsibleName == null || d.responsibleName!.trim().isEmpty).toList();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFBEB),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFDE68A)),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 18,
                              backgroundColor: Colors.amber.shade700,
                              child: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Unassigned Works', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF92400E))),
                                  Text('${unassignedWorks.length} works pending assignment', style: TextStyle(fontSize: 11, color: Colors.amber.shade800)),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                setState(() {
                                  _selectedStaffFilter = 'Unassigned';
                                  _showOnlyMyWorks = false;
                                });
                              },
                              child: const Text('View', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
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
                      final staffWorks = _allDeals.where((d) {
                        final rName = (d.responsibleName ?? '').toLowerCase().trim();
                        return rName.isNotEmpty && (rName == staffName.toLowerCase() || rName.startsWith(firstWord.toLowerCase()));
                      }).toList();

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
                                    staff.role ?? "Staff Member",
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: staffWorks.isNotEmpty ? const Color(0xFFEFF6FF) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${staffWorks.length} works',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: staffWorks.isNotEmpty ? const Color(0xFF2563EB) : const Color(0xFF64748B),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                final formattedFirstWord = firstWord[0].toUpperCase() + firstWord.substring(1).toLowerCase();
                                setState(() {
                                  _selectedStaffFilter = formattedFirstWord;
                                  _showOnlyMyWorks = false;
                                });
                              },
                              child: const Text('Filter', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isWide = MediaQuery.of(context).size.width > 900;
    
    var list = _allDeals.where((d) {
      final name = d.name.trim();
      return !name.startsWith('LEAD-') && !name.startsWith('CUC-');
    }).toList();

    if (_selectedPeriod == '2025-2026') {
      list = list.where((d) => _getDealDate(d).isBefore(nov1Cutoff)).toList();
    } else if (_selectedPeriod == '2026-2027') {
      list = list.where((d) => !_getDealDate(d).isBefore(nov1Cutoff)).toList();
    }

    if (widget.showOnlyVerification) {
      list = list.where((d) => d.stage.toLowerCase() == 'verification').toList();
    }

    if (_showOnlyMyWorks && _currentUserId != null) {
      if (widget.showOnlyVerification) {
        list = list.where((d) {
          final parsedVer = VerificationDetails.parse(d.description);
          return parsedVer.verifierId?.toString() == _currentUserId.toString();
        }).toList();
      } else {
        list = list.where((d) => d.responsibleId?.toString() == _currentUserId.toString()).toList();
      }
    }
    
    if (_selectedStaffFilter != null) {
      if (_selectedStaffFilter == 'Unassigned') {
        list = list.where((d) => d.responsibleName == null || d.responsibleName!.trim().isEmpty).toList();
      } else {
        list = list.where((d) {
          if (d.responsibleName == null || d.responsibleName!.trim().isEmpty) return false;
          final firstWord = d.responsibleName!.trim().split(' ').first;
          if (firstWord.isEmpty) return false;
          final formattedFirstWord = firstWord[0].toUpperCase() + firstWord.substring(1).toLowerCase();
          return formattedFirstWord == _selectedStaffFilter;
        }).toList();
      }
    }
    
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((d) => 
          d.name.toLowerCase().contains(q) || 
          (d.clientName?.toLowerCase().contains(q) ?? false) ||
          (d.registerNo?.toLowerCase().contains(q) ?? false) ||
          (d.workType?.toLowerCase().contains(q) ?? false)
      ).toList();
    }
    
    if (_sortOption == 'Newest First') {
      list.sort((a, b) => (b.createdAt ?? DateTime(2000)).compareTo(a.createdAt ?? DateTime(2000)));
    } else if (_sortOption == 'Oldest First') {
      list.sort((a, b) => (a.createdAt ?? DateTime(2000)).compareTo(b.createdAt ?? DateTime(2000)));
    } else if (_sortOption == 'A-Z') {
      list.sort((a, b) => a.name.compareTo(b.name));
    } else if (_sortOption == 'Z-A') {
      list.sort((a, b) => b.name.compareTo(a.name));
    } else if (_sortOption == 'Highest Amount') {
      list.sort((a, b) => (b.amount).compareTo(a.amount));
    } else if (_sortOption == 'Lowest Amount') {
      list.sort((a, b) => (a.amount).compareTo(b.amount));
    }

    final staffNames = <String>{
      ..._allDeals.map((d) => d.responsibleName).whereType<String>(),
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

    return Scaffold(
      backgroundColor: const Color(0xFFF4F5F7),
      appBar: Navigator.canPop(context)
          ? AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A)),
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      body: Container(
        color: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.all(isWide ? 24 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPremiumHeader(staffNames),
              const SizedBox(height: 24),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refreshDeals,
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : list.isEmpty
                          ? _buildEmptyState()
                          : _buildPremiumListView(list, MediaQuery.of(context).size.width > 1100),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPremiumHeader(List<String> staffNames) {
    final bool isWide = MediaQuery.of(context).size.width > 600;
    final isVerification = widget.showOnlyVerification;
    
    return Container(
      padding: EdgeInsets.all(isWide ? 32 : 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isVerification ? 'Verification Workspace' : 'Work Management',
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: -0.5, color: Color(0xFF0F172A)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isVerification ? 'Review and verify peer draft completions' : 'Manage project pipelines',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (isWide && !isVerification) _buildCreateButton(),
            ],
          ),
          if (!isWide && !isVerification) ...[
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: _buildCreateButton()),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildMyWorksToggle(),
              _buildPeriodSelector(),
              _buildStaffDropdown(staffNames),
              _buildStaffWorkloadButton(),
            ],
          ),
          const SizedBox(height: 16),
          _buildSearchAndFilter(isWide),
        ],
      ),
    );
  }

  Widget _buildCreateButton() {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFFF1D37E), // Light Gold
            Color(0xFFD4AF37), // Luxury Gold
            Color(0xFFB8860B), // Dark Gold
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD4AF37).withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: () => _openDealDetail(),
        icon: const Icon(Icons.add_rounded, color: Colors.white),
        label: const Text('CREATE NEW WORK', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5, color: Colors.white)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  Widget _buildMyWorksToggle() {
    return FilterChip(
      selected: _showOnlyMyWorks,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _showOnlyMyWorks ? Icons.person : Icons.person_outline,
            size: 16,
            color: _showOnlyMyWorks ? Colors.white : const Color(0xFF64748B),
          ),
          const SizedBox(width: 6),
          Text(
            'My Works Only',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: _showOnlyMyWorks ? Colors.white : const Color(0xFF64748B),
              fontSize: 13,
            ),
          ),
        ],
      ),
      selectedColor: const Color(0xFF0F172A),
      backgroundColor: Colors.white,
      side: BorderSide(color: _showOnlyMyWorks ? const Color(0xFF0F172A) : Colors.grey.shade300),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      showCheckmark: false,
      onSelected: (val) => setState(() => _showOnlyMyWorks = val),
    );
  }

  Widget _buildPeriodSelector() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _periodChip('2026-2027', '2026-2027 (Current)', isCurrent: true),
          _periodChip('2025-2026', '2025-2026'),
          _periodChip('All', 'All'),
        ],
      ),
    );
  }

  Widget _periodChip(String period, String label, {bool isCurrent = false}) {
    final isSelected = _selectedPeriod == period;
    return InkWell(
      onTap: () => setState(() => _selectedPeriod = period),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0F172A) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isCurrent) ...[
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF10B981),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStaffDropdown(List<String> staffNames) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _selectedStaffFilter != null ? AppTheme.primaryColor : const Color(0xFFE2E8F0),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _selectedStaffFilter,
          icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF64748B), size: 20),
          hint: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person, size: 14, color: Color(0xFF64748B)),
              SizedBox(width: 5),
              Text('All Staff', style: TextStyle(fontSize: 12, color: Color(0xFF475569), fontWeight: FontWeight.w500)),
            ],
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.people, size: 14, color: Color(0xFF64748B)),
                  SizedBox(width: 6),
                  Text('All Staff', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const DropdownMenuItem<String?>(
              value: 'Unassigned',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person_off_outlined, size: 14, color: Colors.amber),
                  SizedBox(width: 6),
                  Text('Unassigned Works', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.amber)),
                ],
              ),
            ),
            ...staffNames.map((name) => DropdownMenuItem<String?>(
              value: name,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 8,
                    backgroundColor: const Color(0xFFE0E7FF),
                    child: Text(name[0], style: const TextStyle(fontSize: 8, color: Color(0xFF3730A3), fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 6),
                  Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            )),
          ],
          onChanged: (val) {
            setState(() {
              _selectedStaffFilter = val;
              if (val != null) _showOnlyMyWorks = false;
            });
          },
        ),
      ),
    );
  }

  Widget _buildStaffWorkloadButton() {
    return Tooltip(
      message: 'Staff Workload Tracker',
      child: InkWell(
        onTap: _showStaffWorkloadTrackerDialog,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFBFDBFE)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.pie_chart_outline_rounded, size: 16, color: Color(0xFF2563EB)),
              SizedBox(width: 5),
              Text(
                'Workload',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2563EB)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchAndFilter(bool isWide) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search deals...',
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                prefixIcon: const Icon(Icons.search_rounded, color: Colors.grey, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _buildSortDropdown(),
        const SizedBox(width: 8),
        _buildRefreshButton(),
      ],
    );
  }

  Widget _buildSortDropdown() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _sortOption,
          icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: Color(0xFF64748B)),
          items: const [
            DropdownMenuItem(value: 'Newest First', child: Text('Newest First', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: 'Oldest First', child: Text('Oldest First', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: 'A-Z', child: Text('Name (A-Z)', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: 'Z-A', child: Text('Name (Z-A)', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: 'Highest Amount', child: Text('Highest Amount', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: 'Lowest Amount', child: Text('Lowest Amount', style: TextStyle(fontSize: 12))),
          ],
          onChanged: (val) {
            if (val != null) setState(() => _sortOption = val);
          },
        ),
      ),
    );
  }

  Widget _buildRefreshButton() {
    return Tooltip(
      message: 'Refresh Works',
      child: InkWell(
        onTap: _refreshDeals,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          width: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: const Icon(Icons.refresh, size: 20, color: Color(0xFF475569)),
        ),
      ),
    );
  }

  Widget _buildPremiumListView(List<Deal> filteredDeals, bool isWide) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isWide ? 32 : 16),
      child: Column(
        children: [
          if (isWide) _buildTableHeader(isWide),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              itemCount: filteredDeals.length,
              itemBuilder: (context, index) {
                return _buildDealRow(filteredDeals[index], index, isWide);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeader(bool isWide) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              widget.showOnlyVerification ? 'DOCUMENT' : 'DEAL NAME',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1),
            ),
          ),
          if (widget.showOnlyVerification) ...[
            const Expanded(
              flex: 2,
              child: Text(
                'ACTIONS',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1),
              ),
            ),
          ],
          if (!widget.showOnlyVerification) ...[
            Expanded(
              flex: 2,
              child: Text(
                isWide ? 'PIPELINE STAGE' : 'STAGE',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                isWide ? 'CLIENT' : 'INFO',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1),
              ),
            ),
            if (isWide) ...[
              const Expanded(
                flex: 1,
                child: Text('DAYS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1)),
              ),
              const Expanded(
                flex: 1,
                child: Text('AMOUNT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1)),
              ),
              const Expanded(
                flex: 1,
                child: Text('LEAD', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1)),
              ),
            ],
          ],
          const SizedBox(width: 44),
        ],
      ),
    );
  }

  Widget _buildDealRow(Deal deal, int index, bool isWide) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: InkWell(
        onTap: () => _openDealDetail(deal),
        child: isWide
            ? Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: widget.showOnlyVerification
                                  ? _buildVerificationDocInfo(deal)
                                  : Text(
                                      deal.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                        color: Color(0xFF0F172A),
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                            ),
                            if (deal.isAdjourned) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade50,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: Colors.amber.shade200),
                                ),
                                child: Text(
                                  'ADJOURNED',
                                  style: TextStyle(
                                    color: Colors.amber.shade900,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (!widget.showOnlyVerification) ...[
                          const SizedBox(height: 4),
                          Text(deal.workType ?? 'General Work', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                        ],
                      ],
                    ),
                  ),
                  if (widget.showOnlyVerification) ...[
                    Expanded(
                      flex: 2,
                      child: Row(
                        children: [
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () => _handleVerification(deal, true),
                            child: const Text('Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFDC2626),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () => _handleVerification(deal, false),
                            child: const Text('Not Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (!widget.showOnlyVerification) ...[
                    Expanded(
                      flex: 2,
                      child: _buildStageProgress(deal.stage),
                    ),
                    Expanded(
                      flex: 2,
                      child: Row(
                        children: [
                          const Icon(Icons.person_outline_rounded, size: 14, color: Colors.grey),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              deal.clientName ?? 'N/A',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF334155)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isWide) ...[
                      Expanded(
                        flex: 1,
                        child: _buildDaysColumn(deal),
                      ),
                      Expanded(
                        flex: 1,
                        child: Text(
                          '₹${NumberFormat('#,##,###').format(deal.amount)}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF059669)),
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Tooltip(
                          message: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                              ? 'Doing Work: ${deal.responsibleName} (Tap to change)'
                              : 'Unassigned (Tap to assign staff)',
                          child: InkWell(
                            onTap: () => _showQuickAssignStaffDialog(deal),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              decoration: BoxDecoration(
                                color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                    ? const Color(0xFFEFF6FF)
                                    : const Color(0xFFFFFBEB),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                      ? const Color(0xFFBFDBFE)
                                      : const Color(0xFFFDE68A),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 10,
                                    backgroundColor: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                        ? const Color(0xFF2563EB)
                                        : Colors.amber.shade700,
                                    child: Text(
                                      (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                          ? deal.responsibleName![0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      (deal.responsibleName?.isNotEmpty == true)
                                          ? deal.responsibleName!.split(' ')[0]
                                          : 'Unassigned',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                            ? const Color(0xFF1E40AF)
                                            : Colors.amber.shade900,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Icon(
                                    Icons.edit_outlined,
                                    size: 11,
                                    color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                        ? const Color(0xFF3B82F6)
                                        : Colors.amber.shade700,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(width: 16),
                  IconButton(
                    onPressed: () => _deleteDeal(deal),
                    icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Delete Work',
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          deal.name,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF0F172A)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        onPressed: () => _deleteDeal(deal),
                        icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Delete Work',
                      ),
                    ],
                  ),
                  if (deal.isAdjourned) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: Text(
                        'ADJOURNED',
                        style: TextStyle(color: Colors.amber.shade900, fontSize: 9, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                  if (!widget.showOnlyVerification) ...[
                    const SizedBox(height: 4),
                    Text(deal.workType ?? 'General Work', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.person_outline_rounded, size: 14, color: Colors.grey),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            deal.clientName ?? 'N/A',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF334155)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => _showQuickAssignStaffDialog(deal),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                  ? const Color(0xFFEFF6FF)
                                  : const Color(0xFFFFFBEB),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                    ? const Color(0xFFBFDBFE)
                                    : const Color(0xFFFDE68A),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 8,
                                  backgroundColor: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                      ? const Color(0xFF2563EB)
                                      : Colors.amber.shade700,
                                  child: Text(
                                    (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                        ? deal.responsibleName![0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.white),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                      ? deal.responsibleName!.split(' ').first
                                      : 'Unassigned',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                        ? const Color(0xFF1E40AF)
                                        : Colors.amber.shade900,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Icon(
                                  Icons.edit_outlined,
                                  size: 10,
                                  color: (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                                      ? const Color(0xFF3B82F6)
                                      : Colors.amber.shade700,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildStageProgress(deal.stage),
                  ] else ...[
                    const SizedBox(height: 12),
                    _buildVerificationDocInfo(deal),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () => _handleVerification(deal, true),
                            child: const Text('Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFDC2626),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () => _handleVerification(deal, false),
                            child: const Text('Not Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildDaysColumn(Deal deal) {
    if (deal.createdAt == null) {
      return Text('—', style: TextStyle(color: Colors.grey.shade400, fontSize: 13));
    }
    final days = DateTime.now().difference(deal.createdAt!).inDays;
    final Color bgColor;
    final Color textColor;
    if (days <= 7) {
      bgColor = const Color(0xFF10B981).withValues(alpha: 0.15);
      textColor = const Color(0xFF10B981);
    } else if (days <= 30) {
      bgColor = const Color(0xFFF59E0B).withValues(alpha: 0.15);
      textColor = const Color(0xFFD97706);
    } else {
      bgColor = const Color(0xFFEF4444).withValues(alpha: 0.15);
      textColor = const Color(0xFFDC2626);
    }
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            days == 0 ? 'Today' : days == 1 ? '1 day' : '$days days',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: textColor),
          ),
        ),
      ],
    );
  }

  Widget _buildStageProgress(String stage) {
    final idx = stage == 'Completed' ? Deal.stages.length : Deal.stages.indexOf(stage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(stage.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFD4AF37))),
        const SizedBox(height: 8),
        Row(
          children: List.generate(Deal.stages.length, (i) {
            final isPast = i < idx;
            final isCurrent = i == idx;
            return Expanded(
              child: Container(
                height: 4,
                margin: const EdgeInsets.only(right: 2),
                decoration: BoxDecoration(
                  color: isPast || isCurrent ? const Color(0xFFD4AF37) : const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildVerificationDocInfo(Deal deal) {
    List<Map<String, String>> docs = [];
    if (deal.driveLink != null && deal.driveLink!.isNotEmpty) {
      try {
        final parsed = jsonDecode(deal.driveLink!);
        if (parsed is List) {
          for (var item in parsed) {
            docs.add({"name": item["name"].toString(), "url": item["url"].toString()});
          }
        } else if (parsed is Map) {
          docs.add({"name": parsed["name"].toString(), "url": parsed["url"].toString()});
        }
      } catch (e) {
        docs.add({"name": "Connected Document", "url": deal.driveLink!});
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (docs.isEmpty)
          const Text('No Document Linked', style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold))
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: docs.map((doc) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => GoogleDocsWebviewScreen(url: doc['url']!, title: doc['name'] ?? 'Document')));
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.description_outlined, size: 16, color: Color(0xFFD4AF37)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        doc['name'] ?? 'Document',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFFD4AF37), decoration: TextDecoration.underline),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            )).toList(),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.person_pin_circle_rounded, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              'Assigned by: ${deal.responsibleName?.split(' ')[0] ?? 'Unknown'}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    final isVerification = widget.showOnlyVerification;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 40)],
              ),
              child: Icon(
                isVerification ? Icons.verified_user_rounded : Icons.work_history_outlined,
                size: 80,
                color: const Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              isVerification ? 'No drafts pending verification' : 'No projects found',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 12),
            Text(
              isVerification
                  ? 'All peer work drafts are verified and up to date!'
                  : 'Start your first deal to see it in the pipeline tracker',
              style: TextStyle(color: Colors.grey.shade500),
            ),
            if (!isVerification) ...[
              const SizedBox(height: 32),
              _buildCreateButton(),
            ],
          ],
        ).animate().fadeIn(duration: 600.ms).scale(begin: const Offset(0.9, 0.9)),
      ),
    );
  }
}
