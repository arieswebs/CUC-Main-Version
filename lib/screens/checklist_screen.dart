import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import '../models/checklist.dart';
import '../services/checklist_service.dart';
import '../services/auth_service.dart';
import '../services/deal_service.dart';
import '../models/deal.dart';
import '../services/supabase_backup_service.dart';
import '../theme.dart';
import '../services/logging_service.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/meta_service.dart';
import '../widgets/premium_app_bar.dart';
import '../widgets/slide_to_action.dart';
import '../services/excel_service.dart';

class _TaskDraft {
  final TextEditingController titleController = TextEditingController();
  final TextEditingController descController = TextEditingController();
  String priority = 'Medium';
  DateTime date = DateTime.now();
  TimeOfDay time = TimeOfDay.now();

  void dispose() {
    titleController.dispose();
    descController.dispose();
  }
}

class ChecklistScreen extends StatefulWidget {
  const ChecklistScreen({super.key});

  @override
  State<ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends State<ChecklistScreen> with SingleTickerProviderStateMixin {
  final _checklistService = ChecklistService();
  final _authService = AuthService();
  
  bool _isLoading = true;
  bool _isManager = false;
  int? _userId;
  List<Checklist> _checklists = [];
  List<Checklist> _myTasks = [];
  List<Checklist> _delegatedTasks = [];
  List<Checklist> _allTasks = [];
  TabController? _tabController;
  List<Map<String, dynamic>> _users = [];
  List<Deal> _deals = [];
  
  // Create Checklist Form
  final _formKey = GlobalKey<FormState>();
  List<_TaskDraft> _taskDrafts = [_TaskDraft()];
  List<Map<String, dynamic>> _selectedStaff = [];
  int? _selectedDealId;
  TextEditingController? _staffTextController;
  Checklist? _editingChecklist;
  String? _selectedStaffSort;
  String? _selectedStatusSort;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    for (var draft in _taskDrafts) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _initData() async {
    setState(() => _isLoading = true);
    _userId = await _authService.getUserId();
    _isManager = await _authService.isManager() || await _authService.isAdmin();
    
    if (_tabController != null) _tabController!.dispose();
    _tabController = TabController(length: _isManager ? 3 : 2, vsync: this);
    
    final allUsers = await SupabaseBackupService().getAllUsersData();
    _users = allUsers.map((u) {
      return {
        ...u,
        'id': u['id'],
      };
    }).toList();
    _deals = await DealService().getAllDeals();
    
    final sariga = _users.firstWhere(
      (u) => (u['name'] ?? '').toString().toLowerCase().contains('sariga'), 
      orElse: () => {}
    );
    if (sariga.isNotEmpty && sariga['id'] is int) {
      await _checklistService.patchNullTasksToSariga(sariga['id']);
    }

    debugPrint('ChecklistScreen _initData: loaded ${_users.length} users.');
    for (var u in _users) {
      debugPrint('User: ${u['name']} Role: ${u['role']} ID: ${u['id']}');
    }

    await _fetchChecklists();
    setState(() => _isLoading = false);
  }

  Future<void> _fetchChecklists() async {
    if (_userId == null) return;
    
    final all = await _checklistService.getAllChecklists();
    
    if (mounted) {
      setState(() {
        _checklists = all;
        _myTasks = all.where((c) {
          debugPrint('Checking task: ${c.title}, resp: ${c.responsibleId}, user: $_userId');
          return c.responsibleId?.toString() == _userId?.toString();
        }).toList();
        _delegatedTasks = all.where((c) => c.managerId?.toString() == _userId?.toString()).toList();
        _allTasks = all;
      });
    }
  }

  Future<void> _handleRefresh() async {
    await _fetchChecklists();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _tabController == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: PremiumAppBar(
        title: const Text("Today's Task", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4)),
              ],
              border: Border.all(color: Colors.grey.shade100),
            ),
            child: TabBar(
              controller: _tabController!,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: AppTheme.primaryColor,
              unselectedLabelColor: Colors.grey.shade500,
              indicator: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              tabs: [
                const Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Icon(Icons.person_outline, size: 18), SizedBox(width: 8), Text('My Tasks')],
                  ),
                ),
                const Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Icon(Icons.forward_to_inbox_outlined, size: 18), SizedBox(width: 8), Text('Delegated Tasks')],
                  ),
                ),
                if (_isManager) 
                  const Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [Icon(Icons.list_alt_rounded, size: 18), SizedBox(width: 8), Text('All Tasks')],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController!,
              children: [
                _buildChecklistList(_myTasks),
                _buildChecklistList(_delegatedTasks, showSortToggle: true),
                if (_isManager) _buildChecklistList(_allTasks, showSortToggle: true),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          _editingChecklist = null;
          for (var draft in _taskDrafts) draft.dispose();
          _taskDrafts = [_TaskDraft()];
          _selectedStaff.clear();
          _selectedDealId = null;
          showDialog(
            context: context,
            builder: (context) => StatefulBuilder(
              builder: (context, setDialogState) => Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.all(24),
                child: _buildCreateForm(setDialogState),
              ),
            ),
          );
        },
        icon: const Icon(Icons.add_task_rounded),
        label: const Text('Create Task', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppTheme.primaryColor,
        foregroundColor: Colors.white,
      ),
    );
  }

  Widget _buildChecklistList(List<Checklist> tasks, {bool showSortToggle = false}) {
    int getPriorityWeight(String p) {
      if (p == 'High') return 3;
      if (p == 'Medium') return 2;
      if (p == 'Low') return 1;
      return 0;
    }
    
    int getTimeWeight(String title) {
      String cleanTitle = title;
      for (final cat in ['[Applications & Verification]', '[Cases & RTI]', '[Billing]', '[Follow-ups]', '[Other]']) {
        if (cleanTitle.startsWith(cat)) {
          cleanTitle = cleanTitle.substring(cat.length).trim();
          break;
        }
      }
      final timeMatch = RegExp(r'^\[(.*?)\]').firstMatch(cleanTitle);
      if (timeMatch != null) {
        try {
          final t = DateFormat('h:mm a').parse(timeMatch.group(1)!);
          return t.hour * 60 + t.minute;
        } catch(e) {}
      }
      return 9999;
    }
    
    // FILTER TASKS
    Iterable<Checklist> filteredTasks = tasks;
    if (showSortToggle && _selectedStaffSort != null) {
      filteredTasks = filteredTasks.where((t) {
        final respUser = _users.firstWhere((u) => u['id']?.toString() == t.responsibleId?.toString(), orElse: () => {});
        String staff = respUser.isNotEmpty ? respUser['name'].toString() : (t.responsibleName ?? 'Unknown');
        return staff == _selectedStaffSort;
      });
    }
    if (_selectedStatusSort != null && _selectedStatusSort != 'All Status') {
      filteredTasks = filteredTasks.where((t) => t.status == _selectedStatusSort);
    }

    final sortedTasks = List<Checklist>.from(filteredTasks)..sort((a, b) {
      // Primary sort: Completed at the bottom
      bool isCompletedA = a.status == 'Completed';
      bool isCompletedB = b.status == 'Completed';
      if (isCompletedA != isCompletedB) {
        return isCompletedA ? 1 : -1;
      }

      // Secondary sort: Priority
      int weightA = getPriorityWeight(a.priority);
      int weightB = getPriorityWeight(b.priority);
      if (weightA != weightB) return weightB.compareTo(weightA);
      
      // Tertiary sort: Time
      int timeA = getTimeWeight(a.title);
      int timeB = getTimeWeight(b.title);
      if (timeA != timeB) return timeA.compareTo(timeB);
      
      return (b.createdAt ?? '').compareTo(a.createdAt ?? '');
    });

    Widget listWidget = RefreshIndicator(
      onRefresh: _handleRefresh,
      child: sortedTasks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.assignment_turned_in_outlined, size: 80, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text("No tasks for today!", style: TextStyle(color: Colors.grey.shade500, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(24).copyWith(bottom: 100, top: showSortToggle ? 8 : 24),
              itemCount: sortedTasks.length,
              itemBuilder: (context, index) {
                return _buildChecklistCard(sortedTasks[index], isCompact: false);
              },
            ),
    );

    final staffNames = tasks.map((t) {
      final respUser = _users.firstWhere((u) => u['id']?.toString() == t.responsibleId?.toString(), orElse: () => {});
      return respUser.isNotEmpty ? respUser['name'].toString() : (t.responsibleName ?? 'Unknown');
    }).toSet().toList()..sort();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ElevatedButton.icon(
                onPressed: () async {
                  try {
                    final tabName = _tabController?.index == 0 ? "My Tasks" : _tabController?.index == 1 ? "Delegated Tasks" : "All Tasks";
                    final excelService = ExcelService();
                    final path = await excelService.exportTasks(sortedTasks, tabName, _users);
                    if (mounted && path != null) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported to $path', style: const TextStyle(color: Colors.white)), backgroundColor: Colors.green));
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e', style: const TextStyle(color: Colors.white)), backgroundColor: Colors.red));
                    }
                  }
                },
                icon: const Icon(Icons.download, size: 18),
                label: const Text("Export"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  minimumSize: const Size(0, 36),
                ),
              ),
              const SizedBox(width: 16),
              Text("Status:", style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedStatusSort,
                    hint: const Text("All Status", style: TextStyle(fontSize: 14)),
                    icon: const Icon(Icons.arrow_drop_down, size: 20),
                    style: const TextStyle(fontSize: 14, color: AppTheme.textColor, fontWeight: FontWeight.w500),
                    items: const [
                      DropdownMenuItem<String>(value: null, child: Text("All Status")),
                      DropdownMenuItem<String>(value: "Pending", child: Text("Pending")),
                      DropdownMenuItem<String>(value: "In Progress", child: Text("In Progress")),
                      DropdownMenuItem<String>(value: "Completed", child: Text("Completed")),
                      DropdownMenuItem<String>(value: "Postponed", child: Text("Postponed")),
                      DropdownMenuItem<String>(value: "Not Completed", child: Text("Not Completed")),
                    ],
                    onChanged: (val) {
                      setState(() {
                        _selectedStatusSort = val;
                      });
                    },
                  ),
                ),
              ),
              if (showSortToggle) ...[
                const SizedBox(width: 16),
                Text("Filter by Staff:", style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedStaffSort,
                      hint: const Text("All Staff", style: TextStyle(fontSize: 14)),
                      icon: const Icon(Icons.arrow_drop_down, size: 20),
                      style: const TextStyle(fontSize: 14, color: AppTheme.textColor, fontWeight: FontWeight.w500),
                      items: [
                        const DropdownMenuItem<String>(value: null, child: Text("All Staff")),
                        ...staffNames.map((name) => DropdownMenuItem(value: name, child: Text(name))),
                      ],
                      onChanged: (val) {
                        setState(() {
                          _selectedStaffSort = val;
                        });
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(child: listWidget),
      ],
    );
  }

  Widget _buildChecklistCard(Checklist checklist, {bool isCompact = false}) {
    Color statusColor = Colors.grey;
    switch (checklist.status) {
      case 'Completed': statusColor = Colors.green; break;
      case 'Not Completed': statusColor = Colors.red; break;
      case 'Postponed': statusColor = Colors.orange; break;
      case 'Pending': statusColor = Colors.blue; break;
    }

    String cleanTitle = checklist.title;
    for (final cat in ['[Applications & Verification]', '[Cases & RTI]', '[Billing]', '[Follow-ups]', '[Other]']) {
      if (cleanTitle.startsWith(cat)) {
        cleanTitle = cleanTitle.substring(cat.length).trim();
        break;
      }
    }

    String displayTitle = cleanTitle;
    String? displayTime;
    final timeMatch = RegExp(r'^\[(.*?)\]\s+(.*)$').firstMatch(cleanTitle);
    if (timeMatch != null) {
      displayTime = timeMatch.group(1);
      displayTitle = timeMatch.group(2)!;
    }

    Color bgColor = Colors.white;
    if (checklist.priority == 'High') bgColor = Colors.red.shade50;
    else if (checklist.priority == 'Medium') bgColor = Colors.orange.shade50;
    else if (checklist.priority == 'Low') bgColor = Colors.green.shade50;

    return Container(
      margin: isCompact ? const EdgeInsets.only(bottom: 12) : const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 16, offset: const Offset(0, 8)),
        ],
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _showChecklistDetails(checklist, statusColor),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: 5, color: statusColor),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayTitle,
                                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppTheme.textColor, height: 1.3),
                                    ),
                                    if (displayTime != null) ...[
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Icon(Icons.schedule, size: 14, color: AppTheme.primaryColor.withValues(alpha: 0.8)),
                                          const SizedBox(width: 6),
                                          Text(displayTime, style: TextStyle(color: AppTheme.primaryColor.withValues(alpha: 0.8), fontWeight: FontWeight.w600, fontSize: 13)),
                                        ],
                                      ),
                                    ],
                                    if (checklist.createdAt != null) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Icon(Icons.edit_calendar, size: 12, color: Colors.grey.shade600),
                                          const SizedBox(width: 6),
                                          Text(
                                            'Created: ${DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.parse(checklist.createdAt!).toLocal())}',
                                            style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.w500),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: statusColor.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: statusColor.withValues(alpha: 0.2)),
                                    ),
                                    child: Text(
                                      checklist.status,
                                      style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: (checklist.priority == 'High' ? Colors.red : (checklist.priority == 'Medium' ? Colors.orange : Colors.green)).withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.flag, size: 12, color: checklist.priority == 'High' ? Colors.red : (checklist.priority == 'Medium' ? Colors.orange : Colors.green)),
                                        const SizedBox(width: 4),
                                        Text(
                                          checklist.priority,
                                          style: TextStyle(
                                            color: checklist.priority == 'High' ? Colors.red : (checklist.priority == 'Medium' ? Colors.orange : Colors.green),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          if (checklist.description != null && checklist.description!.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(checklist.description!, style: TextStyle(color: Colors.grey.shade600, fontSize: 14, height: 1.4)),
                          ],
                          if (checklist.dealId != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(8)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.link, size: 14, color: Colors.blue.shade700),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      "Deal: ${checklist.dealName}",
                                      style: TextStyle(fontSize: 12, color: Colors.blue.shade700, fontWeight: FontWeight.w600),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Icon(Icons.person_outline, size: 16, color: Colors.grey.shade500),
                              const SizedBox(width: 6),
                              Builder(
                                builder: (context) {
                                  final respUser = _users.firstWhere((u) => u['id']?.toString() == checklist.responsibleId?.toString(), orElse: () => {});
                                  final mgrUser = _users.firstWhere((u) => u['id']?.toString() == checklist.managerId?.toString(), orElse: () => {});
                                  
                                  final rName = respUser.isNotEmpty ? respUser['name'] : (checklist.responsibleName ?? 'Unknown');
                                  final mName = mgrUser.isNotEmpty ? mgrUser['name'] : (checklist.managerName ?? 'Manager');
                                  
                                  return Text(
                                    (checklist.managerId == _userId || _isManager) ? "Assigned to $rName" : "From $mName",
                                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                                  );
                                }
                              ),
                            ],
                          ),
                          if (checklist.startTime != null || checklist.endTime != null) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              children: [
                                if (checklist.startTime != null)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.play_circle_outline, size: 14, color: Colors.blue.shade600),
                                      const SizedBox(width: 4),
                                      Text(
                                        "Started: ${DateFormat('MMM d, h:mm a').format(DateTime.parse(checklist.startTime!).toLocal())}",
                                        style: TextStyle(fontSize: 12, color: Colors.blue.shade700, fontWeight: FontWeight.w500),
                                      ),
                                    ],
                                  ),
                                if (checklist.endTime != null)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.check_circle_outline, size: 14, color: Colors.green.shade600),
                                      const SizedBox(width: 4),
                                      Text(
                                        "Ended: ${DateFormat('MMM d, h:mm a').format(DateTime.parse(checklist.endTime!).toLocal())}",
                                        style: TextStyle(fontSize: 12, color: Colors.green.shade700, fontWeight: FontWeight.w500),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ],
                          if ((checklist.remarks != null && checklist.remarks!.isNotEmpty) || (checklist.reason != null && checklist.reason!.isNotEmpty) || checklist.status != 'Pending') ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (checklist.remarks != null && checklist.remarks!.isNotEmpty)
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.info_outline, size: 14, color: Colors.grey.shade600),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text("Remarks: ${checklist.remarks}", style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: Colors.grey.shade700)),
                                        ),
                                      ],
                                    ),
                                  if (checklist.remarks != null && checklist.remarks!.isNotEmpty && checklist.reason != null && checklist.reason!.isNotEmpty)
                                    const SizedBox(height: 6),
                                  if (checklist.reason != null && checklist.reason!.isNotEmpty)
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.help_outline, size: 14, color: Colors.grey.shade600),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text("Reason: ${checklist.reason}", style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: Colors.grey.shade700)),
                                        ),
                                      ],
                                    ),
                                  if ((checklist.remarks == null || checklist.remarks!.isEmpty) && (checklist.reason == null || checklist.reason!.isEmpty) && checklist.status != 'Pending' && checklist.status != 'In Progress')
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.info_outline, size: 14, color: Colors.grey.shade600),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            checklist.status == 'Completed' ? "Remarks: N/A" : "Reason: N/A",
                                            style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: Colors.grey.shade700),
                                          ),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showChecklistDetails(Checklist checklist, Color statusColor) {
    String cleanTitle = checklist.title;
    for (final cat in ['[Applications & Verification]', '[Cases & RTI]', '[Billing]', '[Follow-ups]', '[Other]']) {
      if (cleanTitle.startsWith(cat)) {
        cleanTitle = cleanTitle.substring(cat.length).trim();
        break;
      }
    }

    String displayTitle = cleanTitle;
    String? displayTime;
    final timeMatch = RegExp(r'^\[(.*?)\]\s+(.*)$').firstMatch(cleanTitle);
    if (timeMatch != null) {
      displayTime = timeMatch.group(1);
      displayTitle = timeMatch.group(2)!;
    }

    final respUser = _users.firstWhere((u) => u['id']?.toString() == checklist.responsibleId?.toString(), orElse: () => {});
    final mgrUser = _users.firstWhere((u) => u['id']?.toString() == checklist.managerId?.toString(), orElse: () => {});
    final rName = respUser.isNotEmpty ? respUser['name'] : (checklist.responsibleName ?? 'Unknown');
    final mName = mgrUser.isNotEmpty ? mgrUser['name'] : (checklist.managerName ?? 'Manager');
    final isAssignedToMe = checklist.responsibleId?.toString() == _userId?.toString();
    final canEdit = _isManager;

    String currentStatus = checklist.status;
    Color currentStatusColor = statusColor;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.assignment, color: AppTheme.primaryColor),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text("Task Details", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    ),
                    if (canEdit) ...[
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blue, size: 20),
                        tooltip: 'Edit Task',
                        splashRadius: 20,
                        onPressed: () {
                          Navigator.pop(context);
                          _editingChecklist = checklist;
                          for (var draft in _taskDrafts) draft.dispose();
                          _taskDrafts = [_TaskDraft()];
                          _taskDrafts[0].titleController.text = checklist.title.replaceAll(RegExp(r'^\[.*?\]\s+'), '');
                          final descLines = (checklist.description ?? '').split('\n');
                          if (descLines.isNotEmpty && descLines.last.startsWith('[PRIORITY]')) {
                            _taskDrafts[0].priority = descLines.last.replaceFirst('[PRIORITY]', '').trim();
                            _taskDrafts[0].descController.text = descLines.sublist(0, descLines.length - 1).join('\n');
                          } else {
                            _taskDrafts[0].descController.text = checklist.description ?? '';
                            _taskDrafts[0].priority = checklist.priority;
                          }
                          
                          final timeMatch = RegExp(r'^\[(.*?)\]').firstMatch(checklist.title);
                          if (timeMatch != null) {
                            try {
                              final t = DateFormat('h:mm a').parse(timeMatch.group(1)!);
                              _taskDrafts[0].time = TimeOfDay.fromDateTime(t);
                            } catch(e) {}
                          }
                          
                          _selectedDealId = checklist.dealId;
                          if (checklist.dueDate != null) {
                            try {
                              _taskDrafts[0].date = DateTime.parse(checklist.dueDate!);
                            } catch(e) {}
                          }
                          
                          _selectedStaff.clear();
                          if (checklist.responsibleId != null) {
                            final u = _users.firstWhere((u) => u['id'] == checklist.responsibleId, orElse: () => {});
                            if (u.isNotEmpty) _selectedStaff.add(u);
                          }
                          
                          showDialog(
                            context: context,
                            builder: (context) => StatefulBuilder(
                              builder: (context, setDialogState) => Dialog(
                                backgroundColor: Colors.transparent,
                                insetPadding: const EdgeInsets.all(24),
                                child: _buildCreateForm(setDialogState),
                              ),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                        tooltip: 'Delete Task',
                        splashRadius: 20,
                        onPressed: () {
                          Navigator.pop(context);
                          _showDeleteConfirmation(checklist);
                        },
                      ),
                    ],
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(color: Colors.grey.shade200, shape: BoxShape.circle),
                        child: const Icon(Icons.close, size: 16, color: Colors.black54),
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
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(displayTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, height: 1.3)),
                          ),
                          const SizedBox(width: 16),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(color: currentStatusColor.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                            child: Text(currentStatus, style: TextStyle(color: currentStatusColor, fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                        ],
                      ),
                      if (displayTime != null) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(color: AppTheme.primaryColor.withOpacity(0.1), shape: BoxShape.circle),
                              child: const Icon(Icons.access_time, size: 14, color: AppTheme.primaryColor),
                            ),
                            const SizedBox(width: 8),
                            Text(displayTime, style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                          ],
                        ),
                      ],
                      if (checklist.startTime != null || checklist.endTime != null) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 16,
                          runSpacing: 8,
                          children: [
                            if (checklist.startTime != null)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), shape: BoxShape.circle),
                                    child: const Icon(Icons.play_circle_outline, size: 14, color: Colors.blue),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    "Started: ${DateFormat('MMM d, h:mm a').format(DateTime.parse(checklist.startTime!).toLocal())}",
                                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                                  ),
                                ],
                              ),
                            if (checklist.endTime != null)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), shape: BoxShape.circle),
                                    child: const Icon(Icons.check_circle_outline, size: 14, color: Colors.green),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    "Ended: ${DateFormat('MMM d, h:mm a').format(DateTime.parse(checklist.endTime!).toLocal())}",
                                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 24),
                      
                      // Details Grid
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade100),
                        ),
                        child: Column(
                          children: [
                            _buildDetailRow(Icons.person_outline, "Assigned To", rName),
                            const Divider(height: 24),
                            _buildDetailRow(Icons.account_circle_outlined, "Created By", mName),
                            if (checklist.dealName != null) ...[
                              const Divider(height: 24),
                              _buildDetailRow(Icons.link, "Connected Work", checklist.dealName!),
                            ],
                            if (checklist.dueDate != null) ...[
                              const Divider(height: 24),
                              _buildDetailRow(Icons.calendar_today_outlined, "Due Date", checklist.dueDate!),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      if (checklist.description != null && checklist.description!.isNotEmpty) ...[
                        const Text("Description", style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(checklist.description!, style: const TextStyle(height: 1.5)),
                        const SizedBox(height: 24),
                      ],
                      // Remarks
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.green.shade100)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.check_circle_outline, color: Colors.green.shade700, size: 20),
                                    const SizedBox(width: 8),
                                    Text("Remarks", style: TextStyle(color: Colors.green.shade900, fontWeight: FontWeight.bold, fontSize: 14)),
                                  ],
                                ),
                                TextButton.icon(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _showAddRemarkDialog(checklist);
                                  },
                                  icon: Icon(checklist.remarks?.isNotEmpty == true ? Icons.edit : Icons.add, size: 16),
                                  label: Text(checklist.remarks?.isNotEmpty == true ? "Edit" : "Add"),
                                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap, foregroundColor: Colors.green.shade800),
                                ),
                              ],
                            ),
                            if (checklist.remarks != null && checklist.remarks!.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(checklist.remarks!, style: TextStyle(color: Colors.green.shade800, height: 1.4)),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (checklist.reason != null && checklist.reason!.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.red.shade100)),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("Reason for Delay", style: TextStyle(color: Colors.red.shade900, fontWeight: FontWeight.bold, fontSize: 13)),
                                    const SizedBox(height: 4),
                                    Text(checklist.reason!, style: TextStyle(color: Colors.red.shade800, height: 1.4)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                      
                      // Actions
                      if (isAssignedToMe && (currentStatus == 'Pending' || currentStatus == 'In Progress' || currentStatus == 'Picked')) ...[
                        const Divider(height: 32),
                        const Text("Action Required", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: 16),
                        if (currentStatus == 'Pending')
                          SlideToAction(
                            key: const ValueKey('start'),
                            text: 'Slide to Start',
                            trackColor: Colors.blue,
                            onAction: () async {
                              setDialogState(() {
                                currentStatus = 'In Progress';
                                currentStatusColor = Colors.blue;
                              });
                              await _checklistService.updateChecklistStatus(checklist.id, 'In Progress');
                              _fetchChecklists();
                            },
                          )
                        else
                          SlideToAction(
                            key: const ValueKey('finish'),
                            text: 'Slide to Finish',
                            trackColor: Colors.green,
                            onAction: () {
                              Navigator.pop(context);
                              _showStatusDialog(checklist, 'Completed');
                            },
                          ),
                        
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  _showStatusDialog(checklist, 'Postponed');
                                },
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.orange,
                                  side: BorderSide(color: Colors.orange.shade200),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text("Postpone", style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  _showStatusDialog(checklist, 'Not Completed');
                                },
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red,
                                  side: BorderSide(color: Colors.red.shade200),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text("Not Done", style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      )).animate().fadeIn(duration: 300.ms).scale(begin: const Offset(0.95, 0.95)),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: Colors.grey.shade500),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            ],
          ),
        ),
      ],
    );
  }

  void _showAddRemarkDialog(Checklist checklist) {
    final controller = TextEditingController(text: checklist.remarks ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(checklist.remarks?.isNotEmpty == true ? "Edit Remarks" : "Add Remarks"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: "Remarks",
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _isLoading = true);
              try {
                // Ensure priority stays in description when saving old checklist
                String fullDesc = (checklist.description ?? '').trim();
                if (!fullDesc.contains('[PRIORITY]')) {
                  fullDesc += '\n[PRIORITY] ${checklist.priority}';
                }
                
                final updatedChecklist = Checklist(
                  id: checklist.id,
                  title: checklist.title,
                  description: fullDesc,
                  responsibleId: checklist.responsibleId,
                  managerId: checklist.managerId,
                  status: checklist.status,
                  dealId: checklist.dealId,
                  dealName: checklist.dealName,
                  dueDate: checklist.dueDate,
                  reason: checklist.reason,
                  priority: checklist.priority,
                  remarks: controller.text,
                );
                await _checklistService.updateChecklist(updatedChecklist);
                await _fetchChecklists();
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
              } finally {
                if (mounted) setState(() => _isLoading = false);
              }
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }
  
  void _showDeleteConfirmation(Checklist checklist) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Task"),
        content: const Text("Are you sure you want to completely delete this task? This cannot be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _isLoading = true);
              try {
                await _checklistService.deleteChecklist(checklist.id!);
                await LoggingService().logAction(
                  action: 'TASK_DELETED',
                  targetType: 'Checklist Task',
                  targetId: checklist.id,
                  details: 'Deleted task: ${checklist.title}',
                );
                await _fetchChecklists();
              } catch(e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
              }
              if (mounted) setState(() => _isLoading = false);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      )
    );
  }

  Widget _buildCreateForm(StateSetter setDialogState) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Card(
            elevation: 8,
            shadowColor: Colors.black12,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Form(
                key: _formKey,
                child: Column(
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
                          child: const Icon(Icons.assignment_add, color: AppTheme.primaryColor, size: 28),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_editingChecklist == null ? "Create New Task" : "Edit Task", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                              Text(_editingChecklist == null ? "Assign a daily task to a staff member" : "Update task details", style: const TextStyle(color: AppTheme.mutedTextColor)),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () => Navigator.pop(context),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          splashRadius: 24,
                        ),
                      ],
                    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1),
                    const SizedBox(height: 32),
                    
                    // Assign To (Staff)
                    LayoutBuilder(
                      builder: (context, constraints) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("Assign To", style: TextStyle(fontWeight: FontWeight.w600)),
                                if (_users.isNotEmpty)
                                  TextButton.icon(
                                    onPressed: () {
                                      setDialogState(() {
                                        if (_selectedStaff.length == _users.length) {
                                          _selectedStaff.clear();
                                        } else {
                                          _selectedStaff = List.from(_users);
                                        }
                                      });
                                    },
                                    icon: Icon(_selectedStaff.length == _users.length ? Icons.clear_all : Icons.done_all, size: 18),
                                    label: Text(_selectedStaff.length == _users.length ? "Clear All" : "Select All"),
                                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (_selectedStaff.isNotEmpty) ...[
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: _selectedStaff.map((u) => Chip(
                                  label: Text("${u['name']} (${u['role']})"),
                                  onDeleted: () => setDialogState(() => _selectedStaff.remove(u)),
                                  backgroundColor: AppTheme.primaryColor.withAlpha(25),
                                  deleteIconColor: AppTheme.primaryColor,
                                  side: BorderSide.none,
                                )).toList(),
                              ),
                              const SizedBox(height: 12),
                            ],
                            Autocomplete<Map<String, dynamic>>(
                              optionsBuilder: (TextEditingValue textEditingValue) {
                                if (textEditingValue.text.isEmpty) return const Iterable<Map<String, dynamic>>.empty();
                                return _users.where((u) => 
                                  "${u['name']} (${u['role']})".toLowerCase().contains(textEditingValue.text.toLowerCase()) && 
                                  !_selectedStaff.any((s) => s['id'] == u['id'])
                                );
                              },
                              displayStringForOption: (u) => "${u['name']} (${u['role']})",
                              onSelected: (u) {
                                setDialogState(() {
                                  if (!_selectedStaff.any((s) => s['id'] == u['id'])) {
                                    _selectedStaff.add(u);
                                  }
                                });
                                _staffTextController?.clear();
                              },
                              fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                                _staffTextController = textEditingController;
                                return TextFormField(
                                  controller: textEditingController,
                                  focusNode: focusNode,
                                  decoration: InputDecoration(
                                    labelText: "Search & Assign Staff",
                                    filled: true,
                                    fillColor: Colors.grey.shade50,
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
                                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                                    prefixIcon: const Icon(Icons.person, color: AppTheme.primaryColor),
                                    suffixIcon: const Icon(Icons.search, color: Colors.grey),
                                  ),
                                );
                              },
                              optionsViewBuilder: (context, onSelected, options) {
                                return Align(
                                  alignment: Alignment.topLeft,
                                  child: Material(
                                    elevation: 8,
                                    borderRadius: BorderRadius.circular(12),
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(maxHeight: 250, maxWidth: constraints.maxWidth),
                                      child: ListView.builder(
                                        padding: EdgeInsets.zero,
                                        shrinkWrap: true,
                                        itemCount: options.length,
                                        itemBuilder: (context, index) {
                                          final option = options.elementAt(index);
                                          return ListTile(
                                            title: Text("${option['name']} (${option['role']})", style: const TextStyle(fontWeight: FontWeight.w500)),
                                            onTap: () => onSelected(option),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                );
                              },
                            )
                          ],
                        );
                      }
                    ).animate().fadeIn(delay: 100.ms, duration: 400.ms).slideX(begin: 0.05),
                    const SizedBox(height: 20),
                    
                    // Deal
                    LayoutBuilder(
                      builder: (context, constraints) {
                        return Autocomplete<Deal>(
                          optionsBuilder: (TextEditingValue textEditingValue) {
                            if (textEditingValue.text.isEmpty) return const Iterable<Deal>.empty();
                            return _deals.where((d) => d.name.toLowerCase().contains(textEditingValue.text.toLowerCase()));
                          },
                          displayStringForOption: (d) => d.name,
                          onSelected: (d) => setDialogState(() => _selectedDealId = d.id),
                          fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                            return TextFormField(
                              controller: textEditingController,
                              focusNode: focusNode,
                              decoration: InputDecoration(
                                labelText: "Search & Connect Work (Optional)",
                                filled: true,
                                fillColor: Colors.grey.shade50,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                                prefixIcon: const Icon(Icons.link, color: AppTheme.primaryColor),
                                suffixIcon: const Icon(Icons.search, color: Colors.grey),
                              ),
                              onChanged: (val) {
                                if (val.isEmpty) setDialogState(() => _selectedDealId = null);
                              },
                            );
                          },
                          optionsViewBuilder: (context, onSelected, options) {
                            return Align(
                              alignment: Alignment.topLeft,
                              child: Material(
                                elevation: 8,
                                borderRadius: BorderRadius.circular(12),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(maxHeight: 250, maxWidth: constraints.maxWidth),
                                  child: ListView.builder(
                                    padding: EdgeInsets.zero,
                                    shrinkWrap: true,
                                    itemCount: options.length,
                                    itemBuilder: (context, index) {
                                      final option = options.elementAt(index);
                                      return ListTile(
                                        title: Text(option.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                                        onTap: () => onSelected(option),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      }
                    ).animate().fadeIn(delay: 150.ms, duration: 400.ms).slideX(begin: 0.05),
                    const SizedBox(height: 32),
                    
                    // Tasks
                    ..._taskDrafts.asMap().entries.map((entry) {
                      final index = entry.key;
                      final draft = entry.value;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 24),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text("Task ${index + 1}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                if (_taskDrafts.length > 1 && _editingChecklist == null)
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                                    onPressed: () {
                                      setDialogState(() {
                                        draft.dispose();
                                        _taskDrafts.removeAt(index);
                                      });
                                    },
                                    constraints: const BoxConstraints(),
                                    padding: EdgeInsets.zero,
                                    splashRadius: 20,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
                              value: draft.priority,
                              decoration: InputDecoration(
                                labelText: 'Priority',
                                prefixIcon: Icon(
                                  Icons.flag, 
                                  color: draft.priority == 'High' ? Colors.red : (draft.priority == 'Medium' ? Colors.orange : Colors.green),
                                ),
                                filled: true,
                                fillColor: Colors.white,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                              ),
                              items: ['High', 'Medium', 'Low'].map((t) => DropdownMenuItem(
                                value: t, 
                                child: Text(t, style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: t == 'High' ? Colors.red : (t == 'Medium' ? Colors.orange : Colors.green)
                                )),
                              )).toList(),
                              onChanged: (v) => setDialogState(() => draft.priority = v!),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: draft.titleController,
                              decoration: InputDecoration(
                                labelText: "Task Title",
                                filled: true,
                                fillColor: Colors.white,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                                prefixIcon: const Icon(Icons.title, color: AppTheme.primaryColor),
                              ),
                              validator: (v) => v == null || v.isEmpty ? "Please enter a title" : null,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: draft.descController,
                              decoration: InputDecoration(
                                labelText: "Description (Optional)",
                                alignLabelWithHint: true,
                                filled: true,
                                fillColor: Colors.white,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                                prefixIcon: const Padding(
                                  padding: EdgeInsets.only(bottom: 48),
                                  child: Icon(Icons.description, color: AppTheme.primaryColor),
                                ),
                              ),
                              maxLines: 3,
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: Material(
                                    color: Colors.transparent,
                                    child: ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text("Date", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                      subtitle: Text(DateFormat('dd MMM').format(draft.date), style: const TextStyle(fontSize: 14)),
                                      trailing: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                                        child: const Icon(Icons.calendar_month, color: AppTheme.primaryColor, size: 18),
                                      ),
                                      onTap: () async {
                                        final picked = await showDatePicker(
                                          context: context,
                                          initialDate: draft.date,
                                          firstDate: DateTime.now().subtract(const Duration(days: 30)),
                                          lastDate: DateTime.now().add(const Duration(days: 365)),
                                        );
                                        if (picked != null) {
                                          setDialogState(() => draft.date = picked);
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Material(
                                    color: Colors.transparent,
                                    child: ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: const Text("Time", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                      subtitle: Text(draft.time.format(context), style: const TextStyle(fontSize: 14)),
                                      trailing: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                                        child: const Icon(Icons.access_time, color: AppTheme.primaryColor, size: 18),
                                      ),
                                      onTap: () async {
                                        final picked = await showTimePicker(
                                          context: context,
                                          initialTime: draft.time,
                                        );
                                        if (picked != null) {
                                          setDialogState(() => draft.time = picked);
                                        }
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.05);
                    }).toList(),
                    
                    if (_editingChecklist == null)
                      TextButton.icon(
                        onPressed: () {
                          setDialogState(() {
                            _taskDrafts.add(_TaskDraft());
                          });
                        },
                        icon: const Icon(Icons.add_circle_outline, color: AppTheme.primaryColor),
                        label: const Text("Add Another Task", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
                          )
                        ),
                      ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.05),

                    const SizedBox(height: 40),
                    ElevatedButton(
                      onPressed: _submitForm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        elevation: 4,
                        shadowColor: AppTheme.primaryColor.withValues(alpha: 0.4),
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(_editingChecklist == null ? "Assign Task to Staff" : "Update Task", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ).animate().fadeIn(delay: 200.ms, duration: 400.ms).scale(begin: const Offset(0.95, 0.95)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _submitForm() async {
    if (!_formKey.currentState!.validate() || _selectedStaff.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill all required fields and assign to at least one staff member.")),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      String? dealName;
      if (_selectedDealId != null) {
        dealName = _deals.firstWhere((d) => d.id == _selectedDealId).name;
      }
      
      if (_editingChecklist != null && _taskDrafts.isNotEmpty) {
        // Update existing task
        final draft = _taskDrafts[0];
        final staff = _selectedStaff.first;
        int? respId;
        if (staff['id'] is int) {
          respId = staff['id'];
        } else if (staff['id'] != null) {
          respId = int.tryParse(staff['id'].toString());
        }

        final timeString = draft.time.format(context);
        final dateString = DateFormat('yyyy-MM-dd').format(draft.date);
        final updatedChecklist = Checklist(
          id: _editingChecklist!.id,
          title: '[$timeString] ${draft.titleController.text.trim()}',
          description: '${draft.descController.text}\n[PRIORITY] ${draft.priority}'.trim(),
          responsibleId: respId,
          managerId: _editingChecklist!.managerId,
          status: _editingChecklist!.status,
          dealId: _selectedDealId,
          dealName: dealName,
          dueDate: dateString,
        );

        await _checklistService.updateChecklist(updatedChecklist);
        final targetStaffId = respId ?? staff['id'] ?? staff['name'];
        if (targetStaffId != null) {
          final prefs = await SharedPreferences.getInstance();
          final currentUserName = prefs.getString('user_name') ?? 'Manager';
          unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
            staffUserId: targetStaffId,
            assignmentTitle: updatedChecklist.title,
            workOrTaskType: 'Daily Task (Manager Master)',
            clientName: dealName,
            dueDate: dateString,
            priority: draft.priority,
            assignedByName: currentUserName,
            details: draft.descController.text.trim().isNotEmpty
                ? draft.descController.text.trim()
                : 'Task updated in Manager Master.',
          ));
        }
        await LoggingService().logAction(
          action: 'TASK_UPDATED',
          targetType: 'Checklist Task',
          targetId: updatedChecklist.title,
          details: 'Updated task assigned to ID: $respId',
        );
      } else {
        // Create new tasks
        for (final draft in _taskDrafts) {
          if (draft.titleController.text.trim().isEmpty) continue;
          final timeString = draft.time.format(context);
          final dateString = DateFormat('yyyy-MM-dd').format(draft.date);

          for (final staff in _selectedStaff) {
            int? respId;
            if (staff['id'] is int) {
              respId = staff['id'];
            } else if (staff['id'] != null) {
              respId = int.tryParse(staff['id'].toString());
            }

            final checklist = Checklist(
              title: '[$timeString] ${draft.titleController.text.trim()}',
              description: '${draft.descController.text}\n[PRIORITY] ${draft.priority}'.trim(),
              responsibleId: respId,
              dealId: _selectedDealId,
              dealName: dealName,
              dueDate: dateString,
            );
            await _checklistService.createChecklist(checklist);
            if (checklist.responsibleId == null && (staff['id'] != null || staff['name'] != null)) {
              final prefs = await SharedPreferences.getInstance();
              final currentUserName = prefs.getString('user_name') ?? 'Manager';
              unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
                staffUserId: staff['id'] ?? staff['name'],
                assignmentTitle: checklist.title,
                workOrTaskType: 'Daily Task (Manager Master)',
                clientName: dealName,
                dueDate: dateString,
                priority: draft.priority,
                assignedByName: currentUserName,
                details: draft.descController.text.trim().isNotEmpty
                    ? draft.descController.text.trim()
                    : 'Task assigned to you in Manager Master.',
              ));
            }
            await LoggingService().logAction(
              action: 'TASK_CREATED',
              targetType: 'Checklist Task',
              targetId: checklist.title,
              details: 'Assigned task to ID: $respId',
            );
          }
        }
      }
      
      setState(() {
        for (var draft in _taskDrafts) {
          draft.dispose();
        }
        _taskDrafts = [_TaskDraft()];
        _selectedStaff.clear();
        _selectedDealId = null;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_editingChecklist == null ? "Tasks assigned successfully!" : "Task updated successfully!")),
        );
        Navigator.pop(context); // Close the dialog
      }
      await _fetchChecklists();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showStatusDialog(Checklist checklist, String status) {
    final isComplete = status == 'Completed';
    final isPostponed = status == 'Postponed';
    final controller = TextEditingController(text: isComplete ? (checklist.remarks ?? '') : (checklist.reason ?? ''));
    
    DateTime selectedDate = DateTime.now().add(const Duration(days: 1));
    bool giveToManager = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isComplete ? "Complete Task" : (isPostponed ? "Postpone Task" : "Report Issue")),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Are you sure you want to mark this as $status?"),
                const SizedBox(height: 16),
                if (isPostponed) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("New Due Date", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    subtitle: Text(DateFormat('dd MMM yyyy').format(selectedDate)),
                    trailing: const Icon(Icons.calendar_today, size: 20, color: AppTheme.primaryColor),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (picked != null) {
                        setDialogState(() => selectedDate = picked);
                      }
                    },
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Give back to manager", style: TextStyle(fontSize: 14)),
                    value: giveToManager,
                    onChanged: (val) => setDialogState(() => giveToManager = val ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: isComplete ? "Remarks" : "Reason",
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                setState(() => _isLoading = true);
                try {
                  await _checklistService.updateChecklistStatus(
                    checklist.id!,
                    status,
                    remarks: isComplete ? controller.text : null,
                    reason: !isComplete ? controller.text : null,
                    newDueDate: isPostponed ? DateFormat('yyyy-MM-dd').format(selectedDate) : null,
                    reassignToManager: isPostponed && giveToManager,
                  );
                  await LoggingService().logAction(
                    action: 'TASK_UPDATED',
                    targetType: 'Checklist Task',
                    targetId: checklist.id,
                    details: 'Task marked as $status: ${checklist.title}',
                  );
                  await _fetchChecklists();
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
                } finally {
                  setState(() => _isLoading = false);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: isComplete ? Colors.green : (isPostponed ? Colors.orange : Colors.red),
                foregroundColor: Colors.white,
              ),
              child: const Text("Submit"),
            ),
          ],
        ),
      ),
    );
  }
}
