import 'package:amplify_api/amplify_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:collection/collection.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../services/logging_service.dart';
import '../theme.dart';
import '../models/task.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'task_detail_screen.dart';
import 'dart:async';
import 'package:cuc_app/services/backup_aware_api.dart';
import '../services/meta_service.dart';
import '../services/supabase_backup_service.dart';

class TaskManagementScreen extends StatefulWidget {
  final String? initialStatus;
  const TaskManagementScreen({super.key, this.initialStatus});

  @override
  State<TaskManagementScreen> createState() => _TaskManagementScreenState();
}

class _TaskManagementScreenState extends State<TaskManagementScreen> with SingleTickerProviderStateMixin {
  final _auth = AuthService();
  static final DateTime nov1Cutoff = DateTime(2026, 11, 1);
  String _selectedPeriod = '2026-2027'; // Starts fresh from Nov 1, 2026
  
  late TabController _tabController;
  
  bool _isLoading = true;
  bool _isAdmin = false;
  dynamic _currentUserId;
  
  List<Task> _myTasks = [];
  List<Task> _delegatedTasks = [];
  List<Task> _allTasks = []; // For Admins
  List<amplify_models.Tasks> _rawTasks = [];

  DateTime _getTaskDate(Task t) {
    if (t.createdAt != null && t.createdAt!.isNotEmpty) {
      final parsed = DateTime.tryParse(t.createdAt!);
      if (parsed != null) return parsed.toLocal();
    }
    if (t.dueDate != null && t.dueDate!.isNotEmpty) {
      final parsed = DateTime.tryParse(t.dueDate!);
      if (parsed != null) return parsed.toLocal();
    }
    return DateTime(2000);
  }

  int get _count2025_2026 => _allTasks.where((t) => _getTaskDate(t).isBefore(nov1Cutoff)).length;
  int get _count2026_2027 => _allTasks.where((t) => !_getTaskDate(t).isBefore(nov1Cutoff)).length;
  int get _countAll => _allTasks.length;

  List<Map<String, dynamic>> _allUsers = [];
  List<amplify_models.Clients> _allClients = [];
  final _searchController = TextEditingController();
  String _statusFilter = 'All';
  StreamSubscription? _createSub;
  StreamSubscription? _updateSub;
  StreamSubscription? _deleteSub;

  @override
  void initState() {
    super.initState();
    if (widget.initialStatus != null) {
      _statusFilter = widget.initialStatus!;
    }
    _initData();
  }

  Future<void> _initData() async {
    dynamic userId;
    bool isAdmin = false;
    
    try {
      final role = await _auth.getUserRole();
      final name = await _auth.getUserName();
      isAdmin = role == 'admin' || role == 'manager';
      
      final prefs = await SharedPreferences.getInstance();
      final idInt = prefs.getInt('current_user_id');
      final idStr = prefs.getString('current_user_id_str');
      userId = idInt ?? idStr;
      
      if (userId == null && name != null) {
        final req = ModelQueries.list(amplify_models.Users.classType, where: amplify_models.Users.USERNAME.eq(name), limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        if (res.data?.items.isNotEmpty == true) {
          userId = res.data!.items.first!.id;
        }
      }
    } catch (e) {
      debugPrint('Error in _initData: $e');
    }
    
    if (mounted) {
      setState(() {
        _isAdmin = isAdmin;
        _currentUserId = userId ?? '0';
        _tabController = TabController(length: _isAdmin ? 3 : 1, vsync: this);
      });
    }

    await Future.wait([
      _fetchTasks(),
      _fetchUsers(),
      _fetchClients(),
    ]);
    
    _subscribeToTasks();
  }

  void _subscribeToTasks() {
    _createSub = Amplify.API.subscribe(
      ModelSubscriptions.onCreate(amplify_models.Tasks.classType),
    ).listen((event) => _fetchTasks(), onError: (e) => debugPrint('Task create sub error: $e'));

    _updateSub = Amplify.API.subscribe(
      ModelSubscriptions.onUpdate(amplify_models.Tasks.classType),
    ).listen((event) => _fetchTasks(), onError: (e) => debugPrint('Task update sub error: $e'));

    _deleteSub = Amplify.API.subscribe(
      ModelSubscriptions.onDelete(amplify_models.Tasks.classType),
    ).listen((event) => _fetchTasks(), onError: (e) => debugPrint('Task delete sub error: $e'));
  }

  @override
  void dispose() {
    _createSub?.cancel();
    _updateSub?.cancel();
    _deleteSub?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchClients() async {
    try {
      final req = ModelQueries.list(amplify_models.Clients.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      final clients = (res.data?.items ?? []).whereType<amplify_models.Clients>().toList();
      clients.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      if (mounted) setState(() => _allClients = clients);
    } catch (_) {}
  }

  Future<void> _fetchUsers() async {
    try {
      final req = ModelQueries.list(amplify_models.Users.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      var items = (res.data?.items ?? []).whereType<amplify_models.Users>().toList();
      final Map<String, amplify_models.Users> uniqueUsers = {};
      for (var user in items) {
        final name = (user.name ?? '').trim();
        if (name.isEmpty) continue;
        final firstWord = name.split(' ').first.toLowerCase();
        if (!uniqueUsers.containsKey(firstWord)) {
          uniqueUsers[firstWord] = user;
        } else {
          if (name.length > (uniqueUsers[firstWord]!.name ?? '').length) {
            uniqueUsers[firstWord] = user;
          }
        }
      }
      var users = uniqueUsers.values.toList();
      
      final sbUserMap = await SupabaseBackupService().getUsernameToIdMap();

      users.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      if (mounted) {
        setState(() {
          _allUsers = users.map((u) {
            final intId = sbUserMap[u.username] ?? sbUserMap[u.email];
            return {
              'id': intId?.toString() ?? u.id,
              'name': u.name,
            };
          }).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchTasks() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final req = ModelQueries.list(amplify_models.Tasks.classType, limit: 10000, authorizationMode: APIAuthorizationType.userPools);
      final res = await Amplify.API.query(request: req).response;
      var tasks = (res.data?.items ?? []).whereType<amplify_models.Tasks>().toList();
      tasks = tasks.where((t) {
        final title = (t.title ?? '').toLowerCase();
        return title.startsWith('[delivery]') || title.startsWith('[pickup]') || title.startsWith('[visit]');
      }).toList();
      
      tasks.sort((a, b) {
        final dateA = (a.created_at != null && a.created_at!.isNotEmpty ? DateTime.tryParse(a.created_at!) : null) ?? a.createdAt?.getDateTimeInUtc() ?? DateTime(2000);
        final dateB = (b.created_at != null && b.created_at!.isNotEmpty ? DateTime.tryParse(b.created_at!) : null) ?? b.createdAt?.getDateTimeInUtc() ?? DateTime(2000);
        return dateB.compareTo(dateA);
      });
      
      final sbUsers = await SupabaseBackupService().getAllUsersData();
      
      final userMap = {
        for (var u in sbUsers) 
          u['id'].toString(): u
      };

      final List<Task> parsedTasks = tasks.map((m) {
        final assignedByMap = userMap[m.assigned_by?.toString()];
        final assignedToMap = userMap[m.assigned_to?.toString()];
        return Task.fromMap({
          'id': m.id,
          'title': m.title,
          'description': m.description,
          'assigned_by': m.assigned_by,
          'assigned_to': m.assigned_to,
          'status': m.status,
          'due_date': m.due_date,
          'created_at': (m.created_at != null && m.created_at!.isNotEmpty) ? m.created_at : m.createdAt?.getDateTimeInUtc().toIso8601String(),
          'location': m.location,
          'client_name': m.client_name,
          'phone_number': m.phone_number,
          'updated_at': m.updatedAt?.getDateTimeInUtc().toIso8601String(),
          'assigned_by_name': assignedByMap?['name'],
          'assigned_to_name': assignedToMap?['name'],
        });
      }).toList();

      if (mounted) {
        setState(() {
          _rawTasks = tasks;
          _allTasks = parsedTasks;
          if (_currentUserId != null) {
            _myTasks = parsedTasks.where((t) => t.assignedTo?.toString() == _currentUserId?.toString()).toList();
            _delegatedTasks = parsedTasks.where((t) => t.assignedBy?.toString() == _currentUserId?.toString()).toList();
          } else {
            _myTasks = [];
            _delegatedTasks = [];
          }
        });
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading tasks: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _importSingleTaskToCurrent(Task task) async {
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
          'Do you want to import "${task.title}" into the current period (2026-2027)?\n\nIts record will be updated to start from the current period.',
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

      final raw = _rawTasks.firstWhereOrNull((m) => m.id == task.id.toString());
      if (raw != null) {
        final updated = raw.copyWith(created_at: targetDateStr);
        await BackupAwareApi().update(updated);
      } else {
        final req = ModelQueries.list(amplify_models.Tasks.classType, where: amplify_models.Tasks.ID.eq(task.id.toString()), limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        if (res.data?.items.isNotEmpty == true) {
          final updated = res.data!.items.first!.copyWith(created_at: targetDateStr);
          await BackupAwareApi().update(updated);
        }
      }

      await LoggingService().logAction(
        action: 'TASK_IMPORTED',
        targetType: 'Task',
        targetId: task.title,
        details: 'Imported delivery/task "${task.title}" to 2026-2027 period',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully imported "${task.title}" to 2026-2027!'),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {
          _selectedPeriod = '2026-2027';
        });
        await _fetchTasks();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error importing task: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showImportToCurrentDialog() async {
    final candidates = _allTasks.where((t) => _getTaskDate(t).isBefore(nov1Cutoff)).toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No 2025-2026 deliveries/tasks available to import.'),
          backgroundColor: Colors.orange,
        ),
      );
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
              : candidates.where((t) =>
                  t.title.toLowerCase().contains(query) ||
                  (t.clientName?.toLowerCase().contains(query) ?? false) ||
                  (t.location?.toLowerCase().contains(query) ?? false) ||
                  (t.assignedToName?.toLowerCase().contains(query) ?? false)
                ).toList();

          final allDisplayedSelected = displayed.isNotEmpty && displayed.every((t) => selectedIds.contains(t.id));

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
                                'Import Deliveries to Current',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Select deliveries/tasks from 2025-2026 to carry forward into 2026-2027',
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
                        hintText: 'Search deliveries, pickups, client, location...',
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
                          '${selectedIds.length} selected of ${candidates.length} deliveries',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: isImporting
                              ? null
                              : () {
                                  setDialogState(() {
                                    if (allDisplayedSelected) {
                                      for (var t in displayed) {
                                        selectedIds.remove(t.id);
                                      }
                                    } else {
                                      for (var t in displayed) {
                                        if (t.id != null) selectedIds.add(t.id);
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
                                  Icon(Icons.inventory_2_outlined, size: 40, color: Colors.grey.shade300),
                                  const SizedBox(height: 8),
                                  Text('No matching deliveries found', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                                ],
                              ),
                            )
                          : ListView.separated(
                              itemCount: displayed.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 6),
                              itemBuilder: (context, i) {
                                final t = displayed[i];
                                final isChecked = selectedIds.contains(t.id);
                                final date = _getTaskDate(t);
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
                                                selectedIds.remove(t.id);
                                              } else {
                                                if (t.id != null) selectedIds.add(t.id);
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
                                                        if (t.id != null) selectedIds.add(t.id);
                                                      } else {
                                                        selectedIds.remove(t.id);
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
                                                  t.title,
                                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B)),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  '${t.clientName?.isNotEmpty == true ? "Client: ${t.clientName} • " : ""}${t.assignedToName?.isNotEmpty == true ? "Assigned: ${t.assignedToName} • " : ""}Status: ${t.status} • Date: $dateStr',
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
                                    final match = candidates.firstWhereOrNull((t) => t.id == id);
                                    if (match != null) {
                                      try {
                                        final raw = _rawTasks.firstWhereOrNull((m) => m.id == match.id.toString());
                                        if (raw != null) {
                                          final updated = raw.copyWith(created_at: targetDateStr);
                                          await BackupAwareApi().update(updated);
                                        } else {
                                          final req = ModelQueries.list(amplify_models.Tasks.classType, where: amplify_models.Tasks.ID.eq(match.id.toString()), limit: 10000);
                                          final res = await Amplify.API.query(request: req).response;
                                          if (res.data?.items.isNotEmpty == true) {
                                            final updated = res.data!.items.first!.copyWith(created_at: targetDateStr);
                                            await BackupAwareApi().update(updated);
                                          }
                                        }
                                        await LoggingService().logAction(
                                          action: 'TASK_IMPORTED',
                                          targetType: 'Task',
                                          targetId: match.title,
                                          details: 'Imported delivery/task "${match.title}" to 2026-2027 period',
                                        );
                                      } catch (e) {
                                        debugPrint('Error importing task ${match.title}: $e');
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
                                    await _fetchTasks();
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Successfully imported ${selectedIds.length} delivery/task(s) into 2026-2027!'),
                                        backgroundColor: Colors.green,
                                      ),
                                    );
                                  }
                                },
                          icon: const Icon(Icons.drive_file_move_rounded, size: 18),
                          label: Text(
                            selectedIds.isEmpty ? 'Select Deliveries to Import' : 'Import (${selectedIds.length})',
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

  Widget _buildPeriodSelector() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
            title: 'All Deliveries',
            subtitle: 'Complete Archive',
            icon: Icons.inventory_2_rounded,
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

  Future<void> _updateTaskStatus(Task task, String newStatus) async {
    try {
      final req = ModelQueries.list(amplify_models.Tasks.classType, where: amplify_models.Tasks.ID.eq(task.id.toString()), limit: 10000, authorizationMode: APIAuthorizationType.userPools);
      final res = await Amplify.API.query(request: req).response;
      if (res.data?.items.isNotEmpty == true) {
        final existingTask = res.data!.items.first!;
        final updated = existingTask.copyWith(status: newStatus);
        await BackupAwareApi().update(updated);
      }
      _fetchTasks();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _deleteTask(dynamic id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete Task'),
        content: const Text('Are you sure you want to delete this task?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), style: TextButton.styleFrom(foregroundColor: Colors.red), child: const Text('Delete')),
        ],
      )
    );
    if (ok == true) {
      try {
        final req = ModelQueries.list(amplify_models.Tasks.classType, where: amplify_models.Tasks.ID.eq(id.toString()), limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        if (res.data?.items.isNotEmpty == true) {
          await BackupAwareApi().delete(res.data!.items.first!);
        }
        _fetchTasks();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  void _showTaskDialog([Task? task]) {
    String selectedTaskType = 'Delivery';
    bool needsReturn = false;
    String cleanTitle = task?.title ?? '';

    if (cleanTitle.contains('[Delivery]')) { selectedTaskType = 'Delivery'; cleanTitle = cleanTitle.replaceAll('[Delivery]', ''); }
    else if (cleanTitle.contains('[Pickup]')) { selectedTaskType = 'Pickup'; cleanTitle = cleanTitle.replaceAll('[Pickup]', ''); }
    else if (cleanTitle.contains('[Visit]')) { selectedTaskType = 'Visit'; cleanTitle = cleanTitle.replaceAll('[Visit]', ''); }
    
    if (cleanTitle.contains('[Requires Return]')) { needsReturn = true; cleanTitle = cleanTitle.replaceAll('[Requires Return]', ''); }
    cleanTitle = cleanTitle.trim();

    final titleCtrl = TextEditingController(text: cleanTitle);
    final descCtrl = TextEditingController(text: task?.description);
    final locCtrl = TextEditingController(text: task?.location);
    final clientCtrl = TextEditingController(text: task?.clientName);
    final phoneCtrl = TextEditingController(text: task?.phoneNumber);
    dynamic assignedTo = task?.assignedTo;
    DateTime? dueDate = task?.dueDate != null ? DateTime.tryParse(task!.dueDate!) : null;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            elevation: 8,
            backgroundColor: Colors.transparent,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.9,
              constraints: const BoxConstraints(maxWidth: 600),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 20, offset: const Offset(0, 10)),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.08),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(task == null ? Icons.add_task_rounded : Icons.edit_note_rounded, color: AppTheme.primaryColor, size: 24),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            task == null ? 'Assign Delivery/Pickup/Visit' : 'Edit Delivery/Pickup/Visit',
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: Colors.black54),
                          onPressed: () => Navigator.pop(context),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Content
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: selectedTaskType,
                                  decoration: InputDecoration(
                                    labelText: 'Type',
                                    prefixIcon: const Icon(Icons.category_outlined, color: Colors.black54),
                                    filled: true,
                                    fillColor: Colors.grey.shade50,
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
                                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                                  ),
                                  items: ['Delivery', 'Pickup', 'Visit'].map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontWeight: FontWeight.w500)))).toList(),
                                  onChanged: (v) => setModalState(() => selectedTaskType = v!),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: CheckboxListTile(
                                  title: const Text('File Needs to Return', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                  value: needsReturn,
                                  onChanged: (v) => setModalState(() => needsReturn = v ?? false),
                                  controlAffinity: ListTileControlAffinity.leading,
                                  contentPadding: EdgeInsets.zero,
                                  activeColor: AppTheme.primaryColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildPremiumTextField(
                            titleCtrl, 
                            task == null ? 'Subjects / References (One per line)' : 'Subject / Reference (e.g. Doc Pickup)', 
                            Icons.title_rounded,
                            maxLines: task == null ? 3 : 1
                          ),
                          const SizedBox(height: 16),
                          _buildPremiumTextField(descCtrl, 'Instructions / Remarks', Icons.description_outlined, maxLines: 3),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(child: _buildPremiumTextField(locCtrl, 'Complete Address / Location', Icons.location_on_outlined)),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Autocomplete<amplify_models.Clients>(
                                  initialValue: TextEditingValue(text: clientCtrl.text),
                                  displayStringForOption: (c) => c.name ?? '',
                                  optionsBuilder: (TextEditingValue textEditingValue) {
                                    if (textEditingValue.text.isEmpty) {
                                      return const Iterable<amplify_models.Clients>.empty();
                                    }
                                    return _allClients.where((c) {
                                      return (c.name ?? '').toLowerCase().contains(textEditingValue.text.toLowerCase());
                                    });
                                  },
                                  onSelected: (amplify_models.Clients selection) {
                                    clientCtrl.text = selection.name ?? '';
                                    if (locCtrl.text.isEmpty && selection.address != null) locCtrl.text = selection.address!;
                                    if (phoneCtrl.text.isEmpty && selection.phone != null) phoneCtrl.text = selection.phone!;
                                  },
                                  fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                                    controller.addListener(() {
                                      if (clientCtrl.text != controller.text) clientCtrl.text = controller.text;
                                    });
                                    return _buildPremiumTextField(controller, 'Client / Contact Person', Icons.person_outline_rounded, focusNode: focusNode);
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(child: _buildPremiumTextField(phoneCtrl, 'Contact Number', Icons.phone_outlined)),
                              const SizedBox(width: 16),
                              Expanded(
                                child: DropdownButtonFormField<dynamic>(
                                  initialValue: assignedTo,
                                  decoration: InputDecoration(
                                    labelText: 'Assign To',
                                    prefixIcon: const Icon(Icons.badge_outlined, color: Colors.black54),
                                    filled: true,
                                    fillColor: Colors.grey.shade50,
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
                                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                                  ),
                                  items: _allUsers.map((u) => DropdownMenuItem<dynamic>(
                                    value: u['id'],
                                    child: Text(u['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w500)),
                                  )).toList(),
                                  onChanged: (v) => setModalState(() => assignedTo = v),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          InkWell(
                            onTap: () async {
                              final d = await showDatePicker(
                                context: context,
                                initialDate: dueDate ?? DateTime.now().add(const Duration(days: 1)),
                                firstDate: DateTime.now().subtract(const Duration(days: 1)),
                                lastDate: DateTime.now().add(const Duration(days: 365)),
                                builder: (context, child) {
                                  return Theme(
                                    data: Theme.of(context).copyWith(
                                      colorScheme: const ColorScheme.light(primary: AppTheme.primaryColor),
                                    ),
                                    child: child!,
                                  );
                                },
                              );
                              if (d != null) {
                                if (!context.mounted) return;
                                final t = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay.fromDateTime(dueDate ?? DateTime.now()),
                                  builder: (context, child) {
                                    return Theme(
                                      data: Theme.of(context).copyWith(
                                        colorScheme: const ColorScheme.light(primary: AppTheme.primaryColor),
                                      ),
                                      child: child!,
                                    );
                                  },
                                );
                                if (t != null) {
                                  setModalState(() => dueDate = DateTime(d.year, d.month, d.day, t.hour, t.minute));
                                } else {
                                  setModalState(() => dueDate = d);
                                }
                              }
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                              decoration: BoxDecoration(
                                color: dueDate == null ? Colors.grey.shade50 : AppTheme.primaryColor.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: dueDate == null ? Colors.grey.shade200 : AppTheme.primaryColor.withValues(alpha: 0.3)),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.calendar_month_rounded, color: dueDate == null ? Colors.black54 : AppTheme.primaryColor),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      dueDate == null ? 'Select Due Date & Time' : 'Due: ${DateFormat('MMM dd, yyyy - hh:mm a').format(dueDate!)}',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: dueDate == null ? Colors.black54 : AppTheme.primaryColor,
                                        fontWeight: dueDate == null ? FontWeight.normal : FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Icon(Icons.chevron_right_rounded, color: dueDate == null ? Colors.black54 : AppTheme.primaryColor),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Footer Actions
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
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
                          child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.black54)),
                        ),
                        const SizedBox(width: 16),
                        ElevatedButton(
                          onPressed: () async {
                            if (titleCtrl.text.isEmpty || assignedTo == null) {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill title and assignee')));
                              return;
                            }
                            try {
                              if (task == null) {
                                final lines = titleCtrl.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                                for (final line in lines) {
                                  final finalTitle = '[$selectedTaskType]${needsReturn ? ' [Requires Return]' : ''} $line'.trim();
                                  
                                  final newTask = amplify_models.Tasks(
                                    title: finalTitle,
                                    description: descCtrl.text,
                                    assigned_to: int.tryParse(assignedTo.toString()),
                                    assigned_by: int.tryParse(_currentUserId.toString()),
                                    due_date: dueDate?.toIso8601String(),
                                    location: locCtrl.text.isEmpty ? null : locCtrl.text,
                                    client_name: clientCtrl.text.isEmpty ? null : clientCtrl.text,
                                    phone_number: phoneCtrl.text.isEmpty ? null : phoneCtrl.text,
                                    status: 'Pending',
                                  );
                                  final res = await BackupAwareApi().create(newTask);
                                  final newId = res.data?.id;
                                  
                                  if (newId != null) {
                                    await NotificationService().notifyStakeholders(
                                      taskId: newId,
                                      title: 'New Delivery/Pickup/Visit Assigned',
                                      message: '"$finalTitle" has been created and assigned.',
                                      type: 'assignment',
                                    );

                                    // Lively WhatsApp alert to assigned staff
                                     final effectiveAssignee = newTask.assigned_to ?? assignedTo;
                                     if (effectiveAssignee != null) {
                                      final prefs = await SharedPreferences.getInstance();
                                      final currentUserName = prefs.getString('user_name') ?? 'Management';
                                      unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
                                         staffUserId: effectiveAssignee,
                                        assignmentTitle: finalTitle,
                                        workOrTaskType: 'Task / Field Visit',
                                        clientName: clientCtrl.text.isNotEmpty ? clientCtrl.text : null,
                                        dueDate: dueDate != null ? DateFormat('dd-MMM-yyyy hh:mm a').format(dueDate!) : null,
                                        assignedByName: currentUserName,
                                        details: descCtrl.text.isNotEmpty ? descCtrl.text : 'New task assigned to you in CUC System.',
                                      ));
                                    }
                                  }
                                  await LoggingService().logAction(action: 'TASK_CREATED', targetType: 'Task', targetId: finalTitle, details: 'Assigned to ID: $assignedTo');
                                }
                              } else {
                                final finalTitle = '[$selectedTaskType]${needsReturn ? ' [Requires Return]' : ''} ${titleCtrl.text}'.trim();
                                final req = ModelQueries.list(amplify_models.Tasks.classType, where: amplify_models.Tasks.ID.eq(task.id.toString()), limit: 10000);
                                final res = await Amplify.API.query(request: req).response;
                                if (res.data?.items.isNotEmpty == true) {
                                  final existingTask = res.data!.items.first!;
                                  final oldAssignee = existingTask.assigned_to;
                                  final newAssignee = int.tryParse(assignedTo.toString());
                                  final updatedTask = existingTask.copyWith(
                                    title: finalTitle,
                                    description: descCtrl.text,
                                    assigned_to: newAssignee,
                                    due_date: dueDate?.toIso8601String(),
                                    location: locCtrl.text.isEmpty ? null : locCtrl.text,
                                    client_name: clientCtrl.text.isEmpty ? null : clientCtrl.text,
                                    phone_number: phoneCtrl.text.isEmpty ? null : phoneCtrl.text,
                                  );
                                  await BackupAwareApi().update(updatedTask);

                                  // If assignee changed, alert the newly assigned staff
                                   final effectiveNewAssignee = newAssignee ?? assignedTo;
                                   if (effectiveNewAssignee != null && (newAssignee != oldAssignee || effectiveNewAssignee.toString() != oldAssignee?.toString())) {
                                    final prefs = await SharedPreferences.getInstance();
                                    final currentUserName = prefs.getString('user_name') ?? 'Management';
                                    unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
                                       staffUserId: effectiveNewAssignee,
                                      assignmentTitle: finalTitle,
                                      workOrTaskType: 'Task Reassigned',
                                      clientName: clientCtrl.text.isNotEmpty ? clientCtrl.text : null,
                                      dueDate: dueDate != null ? DateFormat('dd-MMM-yyyy hh:mm a').format(dueDate!) : null,
                                      assignedByName: currentUserName,
                                      details: descCtrl.text.isNotEmpty ? descCtrl.text : 'Task reassigned to you in CUC System.',
                                    ));
                                  }
                                }
                                
                                await LoggingService().logAction(action: 'TASK_UPDATED', targetType: 'Task', targetId: task.id.toString(), details: 'Updated task: $finalTitle');
                                await NotificationService().notifyStakeholders(
                                  taskId: task.id,
                                  title: 'Delivery/Pickup/Visit Updated',
                                  message: '"$finalTitle" has been updated.',
                                  type: 'info',
                                );
                              }
                              if (mounted) Navigator.pop(context);
                              _fetchTasks();
                            } catch (e) {
                              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryColor,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: Text(task == null ? 'Assign Now' : 'Save Changes', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              ),
            ),
          );
        }
      )
    );
  }

  Widget _buildPremiumTextField(TextEditingController controller, String label, IconData icon, {int maxLines = 1, FocusNode? focusNode}) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: Colors.black54),
        filled: true,
        fillColor: Colors.grey.shade50,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 900;

    if (_currentUserId == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: EdgeInsets.all(isWide ? 24 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isWide)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('Deliveries and Pickups', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -1.2, color: const Color(0xFF1E293B))),
                Row(
                  children: [
                    IconButton(
                      onPressed: _fetchTasks,
                      icon: const Icon(Icons.refresh, color: AppTheme.primaryColor),
                      style: IconButton.styleFrom(backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1)),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () => _showTaskDialog(),
                      icon: const Icon(Icons.add_task),
                      label: const FittedBox(fit: BoxFit.scaleDown, child: Text('Assign Delivery/Pickup')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ),
              ],
            )
          else ...[
            Text('Deliveries and Pickups', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -1.2, color: const Color(0xFF1E293B))),
            const SizedBox(height: 16),
            Row(
              children: [
                IconButton(
                  onPressed: _fetchTasks,
                  icon: const Icon(Icons.refresh, color: AppTheme.primaryColor),
                  style: IconButton.styleFrom(backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _showTaskDialog(),
                    icon: const Icon(Icons.add_task),
                    label: const FittedBox(fit: BoxFit.scaleDown, child: Text('Assign Delivery/Pickup')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          _buildPeriodSelector(),
          const SizedBox(height: 8),
          if (_isAdmin)
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: AppTheme.primaryColor,
              unselectedLabelColor: Colors.grey,
              indicatorColor: AppTheme.primaryColor,
              indicatorSize: TabBarIndicatorSize.label,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              tabs: const [
                Tab(text: 'My Deliveries/Pickups'),
                Tab(text: 'Delegated Deliveries/Pickups'),
                Tab(text: 'All Deliveries/Pickups'),
              ],
            ),
          const SizedBox(height: 16),
          Flex(
            direction: isWide ? Axis.horizontal : Axis.vertical,
            children: [
              isWide 
                ? Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search deliveries, pickups, clients...',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  )
                : TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search deliveries, pickups, clients...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
              if (isWide) const SizedBox(width: 12) else const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _statusFilter,
                    style: const TextStyle(fontSize: 14, color: Colors.black, fontWeight: FontWeight.w600),
                    items: ['All', 'Pending', 'In Progress', 'Picked Up', 'Adjourned', 'Completed']
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _statusFilter = v);
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _isLoading 
              ? const Center(child: CircularProgressIndicator())
              : (_isAdmin 
                  ? TabBarView(
                      controller: _tabController,
                      children: [
                        _buildTaskList(_myTasks, isWide, isMyTask: true),
                        _buildTaskList(_delegatedTasks, isWide, isMyTask: false),
                        _buildTaskList(_allTasks, isWide, isMyTask: false),
                      ],
                    )
                  : _buildTaskList(_myTasks, isWide, isMyTask: true)),
          ),
        ],
      ).animate().fadeIn(),
    );
  }

  Widget _buildTaskList(List<Task> tasks, bool isWide, {required bool isMyTask}) {
    List<Task> periodFiltered = tasks;
    if (_selectedPeriod == '2025-2026') {
      periodFiltered = periodFiltered.where((t) => _getTaskDate(t).isBefore(nov1Cutoff)).toList();
    } else if (_selectedPeriod == '2026-2027') {
      periodFiltered = periodFiltered.where((t) => !_getTaskDate(t).isBefore(nov1Cutoff)).toList();
    }

    final searchTerm = _searchController.text.toLowerCase();
    final filteredTasks = periodFiltered.where((t) {
      final matchesSearch = t.title.toLowerCase().contains(searchTerm) || 
                            (t.description?.toLowerCase().contains(searchTerm) ?? false) ||
                            (t.clientName?.toLowerCase().contains(searchTerm) ?? false) ||
                            (t.location?.toLowerCase().contains(searchTerm) ?? false);
      final matchesStatus = _statusFilter == 'All' || t.status == _statusFilter;
      return matchesSearch && matchesStatus;
    }).toList();

    if (filteredTasks.isEmpty) {
      if (_selectedPeriod == '2026-2027') {
        return Center(
          child: Column(
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
                'Starting fresh from Nov 1, 2026! No deliveries or tasks created yet.\nPrevious deliveries are safely archived in the "2025-2026" button ($_count2025_2026 deliveries).',
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
                    label: Text('Open 2025-2026 Deliveries ($_count2025_2026)'),
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
                    onPressed: () => _showTaskDialog(),
                    icon: const Icon(Icons.add_task, size: 18),
                    label: const Text('Assign Delivery/Pickup'),
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
          ),
        );
      }

      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.assignment_turned_in_outlined, size: 80, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(_searchController.text.isEmpty && _statusFilter == 'All' ? 'No deliveries or pickups found for this period!' : 'No matching deliveries/pickups!', style: TextStyle(color: Colors.grey.shade500, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: filteredTasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final t = filteredTasks[index];
        final isCompleted = t.status == 'Completed';
        final isOverdue = t.dueDate != null && DateTime.parse(t.dueDate!).isBefore(DateTime.now()) && !isCompleted;

        return InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => TaskDetailScreen(
                task: t, 
                isMyTask: isMyTask, 
                onStatusUpdate: _fetchTasks,
                currentUserId: _currentUserId,
              ),
            ),
          ),
          child: Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isCompleted ? Colors.green.withValues(alpha: 0.1) : AppTheme.primaryColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          isCompleted ? Icons.check_circle : Icons.assignment,
                          color: isCompleted ? Colors.green : AppTheme.primaryColor,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, decoration: isCompleted ? TextDecoration.lineThrough : null)),
                            const SizedBox(height: 4),
                            Text(
                              t.description ?? 'No description',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _infoChip(Icons.person, isMyTask ? 'From: ${t.assignedByName ?? "System"}' : 'To: ${t.assignedToName ?? "Unknown"}', Colors.blue.shade700),
                                if (t.dueDate != null)
                                  _infoChip(Icons.calendar_today, 'Due: ${DateFormat('MMM dd').format(DateTime.parse(t.dueDate!))}', isOverdue ? Colors.red : Colors.orange.shade800),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: (isCompleted 
                                        ? Colors.green 
                                        : (t.status == 'Picked Up' ? Colors.teal : (t.status == 'In Progress' 
                                            ? Colors.blue 
                                            : (t.status == 'Adjourned' 
                                                ? Colors.amber 
                                                : Colors.grey)))).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    t.status, 
                                    style: TextStyle(
                                      color: isCompleted 
                                          ? Colors.green 
                                          : (t.status == 'Picked Up' ? Colors.teal : (t.status == 'In Progress' 
                                              ? Colors.blue 
                                              : (t.status == 'Adjourned' 
                                                  ? Colors.amber.shade900 
                                                  : Colors.grey.shade700))), 
                                      fontSize: 12, 
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (isWide) ...[
                        const SizedBox(width: 16),
                        _buildActionButtons(t, isMyTask),
                      ]
                    ],
                  ),
                  if (!isWide && (_isAdmin || !isMyTask)) ...[
                    const Divider(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _buildActionButtons(t, isMyTask),
                      ],
                    ),
                  ]
                ],
              ),
            ),
          ),
        ).animate().fadeIn(delay: (30 * index).ms).slideX(begin: 0.02, end: 0);
      },
    );
  }

  Widget _infoChip(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildActionButtons(Task t, bool isMyTask) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_getTaskDate(t).isBefore(nov1Cutoff))
          IconButton(
            onPressed: () => _importSingleTaskToCurrent(t),
            icon: const Icon(Icons.drive_file_move_outlined, color: Color(0xFF10B981)),
            tooltip: 'Import to Current (2026-2027)',
          ),
        if (!isMyTask || _isAdmin) ...[
          IconButton(onPressed: () => _showTaskDialog(t), icon: const Icon(Icons.edit, color: Colors.grey)),
          IconButton(onPressed: () => _deleteTask(t.id!), icon: const Icon(Icons.delete, color: Colors.redAccent)),
        ],
      ],
    );
  }
}