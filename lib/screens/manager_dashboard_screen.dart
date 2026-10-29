import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_core/amplify_core.dart' as amplify_core;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import 'login_screen.dart';
import 'service_management_screen.dart';
import 'staff_management_screen.dart';
import '../screens/property_management_screen.dart';
import '../screens/file_acknowledgement_screen.dart';
import '../screens/sop_screen.dart';
import 'staff_chat_list_screen.dart';
import 'task_management_screen.dart';
import 'hr_performance_screen.dart';
import 'billing_screen.dart';
import 'client_management_screen.dart';
import 'license_dashboard_screen.dart';
import 'dsc_management_screen.dart';
import 'work_management_screen.dart';
import 'company_bill_management_screen.dart';
import 'contact_book_screen.dart';
import '../services/notification_service.dart';
import '../widgets/notification_bell.dart';
import 'package:intl/intl.dart';
import '../services/billing_service.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart' as amplify_models;
import 'dart:convert';
import '../widgets/premium_app_bar.dart';
import '../services/meta_service.dart';
import '../services/auth_service.dart';
import '../models/billing.dart';
import '../utils/number_to_words.dart';
import 'package:url_launcher/url_launcher.dart';
import 'checklist_screen.dart';
import 'help_and_queries_management_screen.dart';
import 'uploaded_files_screen.dart';
import 'reminder_calendar_screen.dart';
import 'client_files_screen.dart';
import 'inward_post_screen.dart';
import '../services/checklist_service.dart';
import 'office_details_screen.dart';

import 'travel_log_screen.dart';
import '../widgets/upcoming_reminders_widget.dart';
import '../widgets/upcoming_deadlines_widget.dart';
import '../widgets/premium_stat_card.dart';
import '../widgets/dashboard_menu_grid.dart';
import 'dart:async';
import 'document_list_screen.dart';
import 'verification_history_view.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import '../services/attendance_service.dart';
import 'package:cuc_app/services/birthday_service.dart';
import '../widgets/startup_task_popup.dart';
import '../services/auto_backup_service.dart';
import 'formats_screen.dart';
import 'attendance_screen.dart';
import 'crm_screen.dart';

class ManagerDashboardScreen extends StatefulWidget {
  const ManagerDashboardScreen({super.key});

  @override
  State<ManagerDashboardScreen> createState() => _ManagerDashboardScreenState();
}

class _ManagerDashboardScreenState extends State<ManagerDashboardScreen> {
  int _selectedIndex = -1;
  String? _selectedCategory;
  final _searchController = TextEditingController();
  bool _isLoading = true;
  Map<String, dynamic> _adminStats = {
    'totalClients': '0',
    'activeLicenses': '0',
    'monthlyRevenue': '₹0',
    'totalExpenses': '₹0',
    'pendingTasks': '0',
    'pendingWorks': '0',
  };
  List<Map<String, dynamic>> _recentActivity = [];
  List<Map<String, dynamic>> _globalBillings = [];
  List<Map<String, dynamic>> _staffActivity = [];
  DateTime? _lastPressedAt;
  String? _errorMessage;
  bool _showStaffLogs = false;
  List<Map<String, dynamic>> _staffLogs = [];
  List<Map<String, dynamic>> _peakActivity = [];
  StreamSubscription? _notifSubscription;
  bool _isCheckedIn = false;
  String? _attendanceId;
  String? _checkInTimeStr;
  int _dailyTotalMinutes = 0;
  bool _isAttendanceLoading = true;

  @override
  void dispose() {
    _notifSubscription?.cancel();
    super.dispose();
  }


  @override
  void initState() {
    super.initState();
    // Delay to ensure connection is stable on mobile
    Future.delayed(const Duration(milliseconds: 500), () => _fetchAdminStats());
    _fetchAttendanceStatus();
    
    // Start realtime notifications
    AuthService().getUserId().then((id) {
      if (id != null) {
        NotificationService().startRealtimeListener(id);
        _notifSubscription = NotificationService().notificationStream.listen((notif) {
          if (notif.type == 'checklist' && mounted) {
            _checkTodayChecklists();
          }
        });
      }
    });
    
    NotificationService().checkAndSendFrequentReminders();
    _checkTodayChecklists();

    // Silent auto-backup (runs once per 24 hours)
    AutoBackupService().runIfNeeded();
    // Check and show staff birthdays after a short delay so the dashboard can load first
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        BirthdayService.checkAndShowBirthdays(context);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      StartupTaskPopup.checkAndShow(context);
    });
  }
  Future<void> _checkTodayChecklists() async {
    final id = await AuthService().getUserId();
    if (id != null) {
      final count = await ChecklistService().getPendingCountForUser(id);
      if (mounted && count > 0) {
        _showChecklistDialog(count);
      }
    }
  }

  void _showChecklistDialog(int count) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.playlist_add_check_circle_rounded, color: AppTheme.primaryColor),
            const SizedBox(width: 8),
            const Text("Today's Task"),
          ],
        ),
        content: Text("You have $count pending tasks for today. Would you like to view them now?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Later")),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() => _selectedIndex = 12); // Index for ChecklistScreen
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white),
            child: const Text("View Now"),
          ),
        ],
      ),
    );
  }
  
  Future<void> _fetchAttendanceStatus() async {
    final userId = await AuthService().getUserId();
    if (userId == null) {
      if (mounted) setState(() => _isAttendanceLoading = false);
      return;
    }

    try {
      final res = await AttendanceService().getCheckInStatus(userId);
      final todayStr = DateTime.now().toIso8601String().split('T')[0];
      final totalMins = await AttendanceService().getDailyTotalTime(userId, todayStr);
      
      if (mounted) {
        setState(() {
          _dailyTotalMinutes = totalMins;
          if (res != null) {
            _isCheckedIn = true;
            _attendanceId = res['id'];
            final checkInTime = DateTime.parse(res['check_in_time']).toLocal();
            _checkInTimeStr = DateFormat('hh:mm a').format(checkInTime);
          } else {
            _isCheckedIn = false;
            _attendanceId = null;
            _checkInTimeStr = null;
          }
          _isAttendanceLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching attendance status: $e');
      if (mounted) setState(() => _isAttendanceLoading = false);
    }
  }

  Future<void> _toggleAttendance() async {
    final userId = await AuthService().getUserId();
    if (userId == null) {
      setState(() => _isAttendanceLoading = false);
      return;
    }

    setState(() => _isAttendanceLoading = true);
    try {
      if (_isCheckedIn && _attendanceId != null) {
        final success = await AttendanceService().checkOut(_attendanceId!);
        if (success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Checked Out Successfully')));
        }
      } else {
        final success = await AttendanceService().checkIn(userId);
        if (success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Checked In Successfully')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
    await _fetchAttendanceStatus();
  }

  Future<void> _fetchAdminStats({int retryCount = 0}) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      
      // 1. Basic Stats
      final clientsRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.Clients.classType, limit: 10000, authorizationMode: APIAuthorizationType.userPools)).response;
      debugPrint('DEBUG: clientsRes errors: ${clientsRes.errors}');
      debugPrint('DEBUG: clientsRes data length: ${(clientsRes.data?.items ?? []).length}');
      final clientsCount = (clientsRes.data?.items ?? []).length;
      
      final licensesRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.ClientLicenses.classType, limit: 10000, where: amplify_models.ClientLicenses.STATUS.eq('Active'), authorizationMode: APIAuthorizationType.userPools)).response;
      debugPrint('DEBUG: licensesRes fetched');
      final licensesCount = (licensesRes.data?.items ?? []).length;
      
      final tasksRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.Tasks.classType, limit: 10000, where: amplify_models.Tasks.STATUS.ne('Completed'), authorizationMode: APIAuthorizationType.userPools)).response;
      debugPrint('DEBUG: tasksRes fetched');
      final pendingTasksCount = (tasksRes.data?.items ?? []).length;
      
      final worksRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.Deals.classType, limit: 10000, where: amplify_models.Deals.STAGE.ne('Completed'), authorizationMode: APIAuthorizationType.userPools)).response;
      debugPrint('DEBUG: worksRes fetched');
      final rawWorks = (worksRes.data?.items ?? []).whereType<amplify_models.Deals>().toList();
      final pendingWorksCount = rawWorks.where((d) {
        final isCrm = (d.pipeline ?? '').toLowerCase() == 'crm' || (d.pipeline ?? '').toLowerCase() == 'lead';
        if (isCrm && d.is_won != true) return false;
        return true;
      }).length;
      
      final companyBillsRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.CompanyBills.classType, limit: 10000, authorizationMode: APIAuthorizationType.userPools)).response;
      debugPrint('DEBUG: companyBillsRes fetched');

      final now = DateTime.now();

      // Calculate Revenue and Expenses from CompanyBills
      double totalRevenue = 0;
      double totalExpenses = 0;
      
      for (var row in companyBillsRes.data?.items ?? []) {
        if (row != null) {
          DateTime? billDate;
          try {
            if (row.bill_date != null) billDate = DateTime.parse(row.bill_date!);
          } catch (_) {}
          billDate ??= row.createdAt?.getDateTimeInUtc();
          
          if (billDate != null && billDate.month == now.month && billDate.year == now.year) {
            double amount = row.amount ?? 0.0;
            if (amount > 0) {
              totalExpenses += amount;
            } else if (amount < 0) {
              totalRevenue += amount.abs();
            }
          }
        }
      }

      // 2. Recent Activity & Billings
      final allBillingsRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.Billings.classType, limit: 10000, authorizationMode: APIAuthorizationType.userPools)).response;
      final allBillings = ((allBillingsRes.data?.items ?? []).whereType<amplify_models.Billings>().toList() ?? []);
      allBillings.sort((a, b) => (b.createdAt?.getDateTimeInUtc() ?? DateTime.now()).compareTo(a.createdAt?.getDateTimeInUtc() ?? DateTime.now()));
      
      final activityRes = allBillings.take(5).map((e) => {
        'id': e.id,
        'invoice_no': e.invoice_no,
        'client_name': e.client_name,
        'created_at': e.createdAt?.getDateTimeInUtc().toIso8601String(),
        'type': e.type,
      }).toList();
      
      final billingRes = allBillings.take(50).map((e) => {
        'id': e.id,
        'invoice_no': e.invoice_no,
        'client_name': e.client_name,
        'date': e.date,
        'amount': e.amount,
        'type': e.type,
        'category': e.category,
        'authorities': e.authorities,
        'status': e.status,
        'data': e.data,
      }).toList();

      // 3. Staff Activity (Handle potential empty staff list)
      List<Map<String, dynamic>> combinedStaffActivity = [];
      try {
        final staffUsersRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.Users.classType, limit: 10000, authorizationMode: APIAuthorizationType.userPools)).response;
        final staffUsers = (staffUsersRes.data?.items ?? []).where((u) => u != null && ['staff', 'delivery', 'accountant'].contains(u.role)).take(20).toList();
        final staffIds = staffUsers.map((u) => u!.id).toList();
        
        if (staffIds.isNotEmpty) {
          final sessionsRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.UserSessions.classType, limit: 10000, authorizationMode: APIAuthorizationType.userPools)).response;
          final sessions = (sessionsRes.data?.items ?? []).where((s) => s != null && staffIds.contains(s.user_id?.toString())).toList();
          
          final tasksQueryRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.Tasks.classType, limit: 10000, where: amplify_models.Tasks.STATUS.eq('In Progress'), authorizationMode: APIAuthorizationType.userPools)).response;
          final tasks = (tasksQueryRes.data?.items ?? []).where((t) => t != null && staffIds.contains(t.assigned_to?.toString())).toList();

          for (var u in staffUsers) {
            final userId = u!.id;
            final userSessions = sessions.where((s) => s!.user_id?.toString() == userId).toList();
            userSessions.sort((a, b) => (b!.login_time ?? '').compareTo(a!.login_time ?? ''));
            final latestSession = userSessions.isNotEmpty ? userSessions.first : null;
            
            final userTasks = tasks.where((t) => t!.assigned_to?.toString() == userId).toList();
            final currentTask = userTasks.isNotEmpty ? userTasks.first : null;
            
            combinedStaffActivity.add({
              'id': userId,
              'name': u.name,
              'username': u.username,
              'last_login': latestSession?.login_time,
              'is_active': latestSession?.is_active == true,
              'current_task': currentTask?.title,
            });
          }
        }
      } catch (e) {
        debugPrint('Staff activity fetch failed: $e');
      }

      // 4. Logs & Peak Activity
      List<Map<String, dynamic>> staffLogs = [];
      List<Map<String, dynamic>> peakActivity = [];
      try {
        final staffLogsRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.ActivityLogs.classType, limit: 10000)).response;
        final allLogs = ((staffLogsRes.data?.items ?? []).whereType<amplify_models.ActivityLogs>().toList() ?? []);
        allLogs.sort((a, b) => (b.createdAt?.getDateTimeInUtc() ?? DateTime.now()).compareTo(a.createdAt?.getDateTimeInUtc() ?? DateTime.now()));
        
        final latestLogs = allLogs.take(5).toList();
        
        // Fetch user names for logs
        final allUsersRes = await Amplify.API.query(request: ModelQueries.list(amplify_models.Users.classType, limit: 10000)).response;
        final allUsers = (allUsersRes.data?.items ?? []).whereType<amplify_models.Users>().toList() ?? [];
        final userMap = {for (var u in allUsers) u.id: u.name};
        
        staffLogs = latestLogs.map((m) {
          return {
            'action': m.action,
            'details': m.details,
            'target_type': m.target_type,
            'target_id': m.target_id,
            'created_at': m.createdAt?.getDateTimeInUtc().toIso8601String(),
            'user_name': userMap[m.user_id?.toString()] ?? 'Unknown',
          };
        }).toList();

        final yesterday = DateTime.now().subtract(const Duration(hours: 24));
        final recentLogs = allLogs.where((l) => (l.createdAt?.getDateTimeInUtc() ?? DateTime.now()).isAfter(yesterday)).toList();
        
        final Map<int, int> hourCounts = {};
        for (var log in recentLogs) {
          final createdAt = log.createdAt?.getDateTimeInUtc();
          if (createdAt != null) {
            final hour = createdAt.toLocal().hour;
            hourCounts[hour] = (hourCounts[hour] ?? 0) + 1;
          }
        }
        peakActivity = hourCounts.entries.map((e) => <String, dynamic>{'hour': e.key, 'count': e.value}).toList();
        peakActivity.sort((a, b) {
          int hA = a['hour'] is int ? a['hour'] as int : int.parse(a['hour'].toString());
          int hB = b['hour'] is int ? b['hour'] as int : int.parse(b['hour'].toString());
          return hA.compareTo(hB);
        });
      } catch (e) {
        debugPrint('Logs fetch failed: $e');
      }

      if (!mounted) return;
      setState(() {
        _adminStats = {
          'totalClients': clientsCount.toString(),
          'activeLicenses': licensesCount.toString(),
          'pendingTasks': pendingTasksCount.toString(),
          'pendingWorks': pendingWorksCount.toString(),
          'monthlyRevenue': '₹${NumberFormat('#,##,###').format(totalRevenue)}',
          'totalExpenses': '₹${NumberFormat('#,##,###').format(totalExpenses)}',
        };
        _recentActivity = List<Map<String, dynamic>>.from(activityRes);
        _globalBillings = List<Map<String, dynamic>>.from(billingRes).map((m) => Billing.fromMap(m).toMap()).toList();
        _staffActivity = combinedStaffActivity;
        _staffLogs = staffLogs;
        _peakActivity = peakActivity;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      debugPrint('Manager dashboard error (attempt $retryCount): $e');
      if (retryCount < 2 && mounted) {
        await Future.delayed(const Duration(seconds: 2));
        return _fetchAdminStats(retryCount: retryCount + 1);
      }
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().contains('connection') 
              ? 'Connection error. Please check your internet.' 
              : 'Failed to load dashboard data: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isWide = constraints.maxWidth > 900;
        
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            
            // 1. If in a specific category list, go back to main dashboard
            if (_selectedCategory != null) {
              setState(() {
                _selectedCategory = null;
                _searchController.clear();
              });
              return;
            }

            // 2. If not in dashboard home, go back to index 0
            if (_selectedIndex != 0) {
              setState(() => _selectedIndex = 0);
              return;
            }

            final now = DateTime.now();
            if (_lastPressedAt == null || now.difference(_lastPressedAt!) > const Duration(seconds: 2)) {
              _lastPressedAt = now;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Press back again to exit'),
                  duration: Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                  width: 200,
                ),
              );
              return;
            }
            
            if (context.mounted) {
              SystemNavigator.pop();
            }
          },
          child: Scaffold(
            appBar: !isWide ? PremiumAppBar(
              title: Image.asset('assets/CUnitedGold.png', height: 30),
              centerTitle: true,
              actions: [
                IconButton(
                  icon: Icon(_selectedIndex == -1 ? Icons.home_rounded : Icons.apps_rounded, color: AppTheme.primaryColor),
                  onPressed: () => setState(() {
                    _selectedIndex = _selectedIndex == -1 ? 0 : -1;
                    _selectedCategory = null;
                  }),
                ),
                const SizedBox(width: 8),
              ],
            ) : null,
            body: SafeArea(
              child: Row(
                children: [
                Expanded(
                  child: Container(
                    padding: _selectedIndex == 31
                        ? EdgeInsets.zero
                        : EdgeInsets.fromLTRB(isWide ? 24 : 16, isWide ? 18 : 12, isWide ? 24 : 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_selectedIndex != 31) ...[
                          _buildHeader(isWide),
                          SizedBox(height: isWide ? 16 : 10),
                        ],
                        Expanded(
                        child: _isLoading 
                          ? const Center(child: CircularProgressIndicator())
                          : _errorMessage != null
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.error_outline, color: Colors.red, size: 48),
                                    const SizedBox(height: 16),
                                    Text('Error loading dashboard:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red.shade700)),
                                    const SizedBox(height: 8),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 32),
                                      child: Text(_errorMessage!, textAlign: TextAlign.center, style: TextStyle(color: Colors.red.shade400, fontSize: 12)),
                                    ),
                                    const SizedBox(height: 24),
                                    ElevatedButton(onPressed: () {
                                      setState(() => _errorMessage = null);
                                      _fetchAdminStats();
                                    }, child: const Text('Retry')),
                                  ],
                                ),
                              )
                            : AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                child: _selectedCategory != null 
                                  ? Column(
                                      key: ValueKey(_selectedCategory),
                                      children: [
                                        Row(
                                          children: [
                                            IconButton(
                                              icon: const Icon(Icons.arrow_back_rounded),
                                              onPressed: () => setState(() => _selectedCategory = null),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(_selectedCategory!, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                        const SizedBox(height: 16),
                                        Expanded(child: _buildDetailList()),
                                      ],
                                    )
                                  : _buildMainAdminContent(isWide),
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),),
          ),
        );
      },
    );
  }

// Sidebar methods removed.

    Widget _buildHeader(bool isWide) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (_selectedIndex != 0) ...[
                        IconButton(
                          icon: const Icon(Icons.arrow_back_rounded, size: 20),
                          tooltip: 'Back to Dashboard',
                          onPressed: () => setState(() {
                            _selectedIndex = 0;
                            _selectedCategory = null;
                          }),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.grey.shade100,
                            padding: const EdgeInsets.all(8),
                            minimumSize: const Size(36, 36),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Text(
                        _selectedIndex == 6 ? 'Work Management' : 'Manager Master',
                        style: TextStyle(fontSize: isWide ? 26 : 20, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                      ).animate().fadeIn(duration: 400.ms).slideX(begin: -0.1),
                    ],
                  ),
                  if (isWide) Padding(
                    padding: EdgeInsets.only(left: _selectedIndex != 0 ? 46.0 : 0),
                    child: Text(
                      _selectedIndex == 6
                          ? 'Overseeing project pipelines, stages, and team assignments.'
                          : 'Overseeing operations, staff performance, and global metrics.',
                      style: const TextStyle(color: AppTheme.mutedTextColor, fontSize: 13),
                    ).animate().fadeIn(delay: 100.ms),
                  ),
                ],
              ),
            ),
            if (isWide) Row(
              children: [
                _headerBadge('System Health: Excellent', Colors.green),
                const SizedBox(width: 16),
                _buildAttendanceButton(),
                const SizedBox(width: 16),
                const NotificationBell(),
                const SizedBox(width: 16),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C24),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                  child: IconButton(
                    icon: Icon(_selectedIndex == -1 ? Icons.home_rounded : Icons.apps_rounded, color: AppTheme.primaryColor),
                    tooltip: _selectedIndex == -1 ? 'Home Dashboard' : 'Menu',
                    onPressed: () => setState(() {
                      _selectedIndex = _selectedIndex == -1 ? 0 : -1;
                      _selectedCategory = null;
                    }),
                  ),
                ),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: _fetchAdminStats,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Refresh'),
                ),
              ],
            ) else Row(
              children: [
                _buildAttendanceButton(),
                const SizedBox(width: 8),
                const NotificationBell(),
                IconButton(
                  onPressed: _fetchAdminStats,
                  icon: const Icon(Icons.refresh_rounded, color: AppTheme.primaryColor),
                  style: IconButton.styleFrom(backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1)),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAttendanceButton() {
    return ElevatedButton.icon(
      onPressed: _isAttendanceLoading ? null : _toggleAttendance,
      icon: _isAttendanceLoading
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
          : Icon(_isCheckedIn ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded, color: Colors.white, size: 18),
      label: Text(_isCheckedIn ? 'Check Out' + (_checkInTimeStr != null ? ' (In since $_checkInTimeStr)' : '') : 'Check In', style: const TextStyle(fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: _isCheckedIn ? Colors.redAccent : Colors.green,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  Widget _buildMainAdminContent(bool isWide) {
    switch (_selectedIndex) {
      case -1:
        return DashboardMenuGrid(
          selectedIndex: _selectedIndex,
          onBackPressed: () => setState(() => _selectedIndex = 0),
          onItemSelected: (idx) {
            if (idx == 99) {
              AuthService().logout().then((_) {
                if (mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (Route<dynamic> route) => false,
                  );
                }
              });
              return;
            }
            setState(() {
              _selectedIndex = idx;
              _selectedCategory = null;
            });
          },
        );
      case 0: return _buildAdminView(isWide);
      case 1: return const ServiceManagementScreen();
      case 2: return const StaffManagementScreen();
      case 3: return const ClientManagementScreen();
      case 25: return const ContactBookScreen();
      case 4: return const BillingScreen();
      case 11: return CompanyBillManagementScreen();
      case 5: return const LicenseDashboardScreen();
      case 9: return const DscManagementScreen();
      case 6: return const WorkManagementScreen();
      case 8: return const TaskManagementScreen();
      case 10: return const StaffChatListScreen();

      case 16: return const TravelLogScreen();
      case 12: return const ChecklistScreen();
      case 13: return const WorkManagementScreen(showOnlyVerification: true);
      case 14: return const UploadedFilesScreen();
      case 17: return const ReminderCalendarScreen();
      case 18: return const InwardPostScreen(currentUserRole: 'manager', currentUserName: 'Manager');
      case 19: return const DocumentListScreen(userEmail: 'manager@cochinunited.com');
      case 20: return const VerificationHistoryView();
      case 21: return const PropertyManagementScreen();
      case 22: return const FileAcknowledgementScreen(currentUserRole: 'manager', currentUserName: 'Manager');
      case 26: return const HelpAndQueriesManagementScreen();
      case 24: return const ClientFilesScreen();
      case 23: return const SopScreen();
      case 28: return const HrPerformanceScreen();
      case 27: return const OfficeDetailsScreen();
      case 7: return _buildSettingsPage();
      case 29: return const FormatsScreen();
      case 30: return const AttendanceScreen();
      case 31: return CrmScreen(onBack: () => setState(() => _selectedIndex = 0));
      default: return _buildPlaceholderView('Coming Soon');
    }
  }

  Widget _headerBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }




  Widget _buildPlaceholderView(String title) {
    return Center(
      child: Text(title, style: const TextStyle(color: AppTheme.mutedTextColor, fontSize: 18)),
    );
  }

  Widget _buildUserActivityView() {
    return Column(
      key: const ValueKey('user_activity'),
      children: [
        Row(
          children: [
            const Expanded(flex: 3, child: Text('Staff Member', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.mutedTextColor))),
            const Expanded(flex: 2, child: Text('Last Seen', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.mutedTextColor))),
            const Expanded(flex: 2, child: Text('Current Task', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.mutedTextColor))),
            const Expanded(flex: 1, child: Text('Status', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.mutedTextColor))),
          ],
        ),
        const Divider(height: 32),
        Expanded(
          child: _staffActivity.isEmpty 
            ? const Center(child: Text('No staff data found'))
            : ListView.separated(
                itemCount: _staffActivity.length,
                separatorBuilder: (context, index) => const Divider(),
                itemBuilder: (context, index) {
                  final staff = _staffActivity[index];
                  final isActive = staff['is_active'] == true;
                  final statusColor = isActive ? Colors.green : Colors.grey;
                  final statusText = isActive ? 'Active' : 'Offline';
                  final lastLogin = staff['last_login'] != null 
                      ? DateFormat('HH:mm, dd MMM').format(DateTime.parse(staff['last_login'].toString()).toLocal())
                      : 'Never';
                  
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                                child: Text(staff['name']?[0] ?? '?', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(staff['name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                                    Text(staff['username'] ?? '', style: const TextStyle(fontSize: 11, color: AppTheme.mutedTextColor)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(lastLogin, style: const TextStyle(fontSize: 12)),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(staff['current_task'] ?? 'None', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                        ),
                        Expanded(
                          flex: 1,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              statusText,
                              style: TextStyle(fontSize: 10, color: statusColor, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
        ),
      ],
    );
  }

  Widget _buildAdminView(bool isWide) {
    bool isMobile = MediaQuery.of(context).size.width < 600;
    
    return SingleChildScrollView(
      child: Column(
        children: [
          // System Banner with Integrated Quick Actions
          _buildSystemBanner(isWide),
          const SizedBox(height: 32),
          
          // Global Stats with Premium Palette
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: isWide ? 3 : (isMobile ? 1 : 2),
            mainAxisSpacing: isWide ? 24 : 12,
            crossAxisSpacing: isWide ? 24 : 12,
            childAspectRatio: isWide ? 2.0 : (isMobile ? 2.5 : 1.8),
            children: [
              PremiumStatCard(title: 'Total Revenue', value: _adminStats['monthlyRevenue'], trend: '+24%', icon: Icons.account_balance_wallet_rounded, color: AppTheme.primaryColor, isNarrow: !isWide, onTap: () => setState(() => _selectedCategory = 'Bills to Receive')),
              PremiumStatCard(title: 'Company Expenses', value: _adminStats['totalExpenses'], trend: 'Payables', icon: Icons.outbound_rounded, color: AppTheme.textColor, isNarrow: !isWide, onTap: () => setState(() => _selectedIndex = 11)),
              PremiumStatCard(title: 'Total Clients', value: _adminStats['totalClients'], trend: '+12%', icon: Icons.people_rounded, color: AppTheme.primaryColor, isNarrow: !isWide, onTap: () {}),
              PremiumStatCard(title: 'Active Licenses', value: _adminStats['activeLicenses'], trend: '+5%', icon: Icons.verified_user_rounded, color: AppTheme.textColor, isNarrow: !isWide, onTap: () => setState(() => _selectedCategory = 'Expiring Licences')),
              PremiumStatCard(title: 'Pending Deliveries/Pickup', value: _adminStats['pendingTasks'], trend: 'Needs Action', icon: Icons.task_alt_rounded, color: AppTheme.primaryColor, isNarrow: !isWide, onTap: () => setState(() => _selectedIndex = 8)),
              PremiumStatCard(title: 'Active Projects', value: _adminStats['pendingWorks'], trend: 'In Pipeline', icon: Icons.work_history_rounded, color: AppTheme.textColor, isNarrow: !isWide, onTap: () => setState(() => _selectedCategory = 'Work Management')),
            ].animate(interval: 100.ms).fadeIn().slideY(begin: 0.1),
          ),
          const SizedBox(height: 32),
          
          // Side-by-Side Lists on Desktop
          if (isWide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      UpcomingDeadlinesWidget(
                        isWide: isWide,
                        onItemTap: (item) => _showQuickActionMenu(context, item),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(color: Colors.grey.withValues(alpha: 0.05), blurRadius: 20, spreadRadius: 5),
                          ],
                        ),
                        child: UpcomingRemindersWidget(
                          isWide: isWide,
                          onNavigateToCalendar: () => setState(() => _selectedIndex = 17),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(child: _buildRecentActivityCard(isWide)),
              ],
            )
          else
            Column(
              children: [
                UpcomingDeadlinesWidget(
                  isWide: isWide,
                  onItemTap: (item) => _showQuickActionMenu(context, item),
                ),
                const SizedBox(height: 24),
                UpcomingRemindersWidget(
                  isWide: isWide,
                  onNavigateToCalendar: () => setState(() => _selectedIndex = 17),
                ),
                const SizedBox(height: 32),
                _buildRecentActivityCard(isWide),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildRecentActivityCard(bool isWide) {
    return Card(
      child: Padding(
              padding: EdgeInsets.all(isWide ? 24 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _showStaffLogs ? 'Live Staff Actions' : 'Recent System Activity', 
                          style: TextStyle(fontSize: isWide ? 18 : 16, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(() => _showStaffLogs = !_showStaffLogs),
                        icon: Icon(_showStaffLogs ? Icons.receipt_long_rounded : Icons.assignment_ind_rounded, size: 14),
                        label: Text(_showStaffLogs ? 'Billing' : 'Staff Logs', style: const TextStyle(fontSize: 11)),
                        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _showStaffLogs 
                    ? (_staffLogs.isEmpty 
                        ? const Center(child: Padding(padding: EdgeInsets.all(40), child: Text('No recent staff actions')))
                        : Column(
                            children: _staffLogs.map((log) {
                              String ts = log['created_at']?.toString() ?? '';
                              final dt = ts.isNotEmpty ? DateTime.parse(ts).toLocal() : null;
                              final date = dt != null ? DateFormat('hh:mm a • dd MMM').format(dt) : '-';
                              Color actionColor = Colors.blue;
                              if (log['action'].toString().contains('DELETE')) actionColor = Colors.red;
                              if (log['action'].toString().contains('CREATE')) actionColor = Colors.green;
                              
                              return Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.grey.shade100),
                                  boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 8, offset: const Offset(0, 2))],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    decoration: BoxDecoration(border: Border(left: BorderSide(color: actionColor, width: 4))),
                                    child: Material(
                                      color: Colors.transparent,
                                      child: ListTile(
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                        leading: Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(color: actionColor.withAlpha(25), borderRadius: BorderRadius.circular(8)),
                                          child: Icon(_getLogIcon(log['target_type']), color: actionColor, size: 20),
                                        ),
                                        title: Text('${log['user_name']}: ${log['action']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                        subtitle: Padding(
                                          padding: const EdgeInsets.only(top: 4.0),
                                          child: Text('${log['target_type']} • ${log['details']} \n$date', style: TextStyle(fontSize: 12, color: Colors.grey.shade600), maxLines: 2, overflow: TextOverflow.ellipsis),
                                        ),
                                        trailing: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(color: Colors.grey.shade50, shape: BoxShape.circle),
                                          child: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.grey, size: 12),
                                        ),
                                        onTap: () {
                                          showDialog(
                                            context: context,
                                            builder: (c) => AlertDialog(
                                              title: const Text('Staff Log Details'),
                                              content: Text('Action: ${log['action']}\nTarget: ${log['target_type']}\nDetails: ${log['details']}\nBy: ${log['user_name']}\nTime: $date'),
                                              actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
                                            )
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ).animate().fadeIn(duration: 400.ms).slideX(begin: 0.1);
                            }).toList(),
                          ))
                    : (_recentActivity.isEmpty 
                        ? const Center(child: Padding(padding: EdgeInsets.all(40), child: Text('No recent activity', style: TextStyle(color: AppTheme.mutedTextColor))))
                        : Column(
                            children: _recentActivity.map((act) {
                              String ts = act['created_at']?.toString() ?? '';
                              final dt = ts.isNotEmpty ? DateTime.parse(ts).toLocal() : null;
                              final date = dt != null ? DateFormat('hh:mm a • dd MMM').format(dt) : '-';
                              final isQuote = act['type'] == 'QUOTATION';
                              final accentColor = isQuote ? Colors.purple : AppTheme.primaryColor;
                              
                              return Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.grey.shade100),
                                  boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 8, offset: const Offset(0, 2))],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    decoration: BoxDecoration(border: Border(left: BorderSide(color: accentColor, width: 4))),
                                    child: Material(
                                      color: Colors.transparent,
                                      child: ListTile(
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                        leading: Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(color: accentColor.withAlpha(25), borderRadius: BorderRadius.circular(8)),
                                          child: Icon(isQuote ? Icons.request_quote_rounded : Icons.receipt_long_rounded, color: accentColor, size: 20),
                                        ),
                                        title: Text('New ${act['type']} for ${act['client_name']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                        subtitle: Padding(
                                          padding: const EdgeInsets.only(top: 4.0),
                                          child: Text('Inv: ${act['invoice_no']} \n$date', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                        ),
                                        trailing: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(color: Colors.grey.shade50, shape: BoxShape.circle),
                                          child: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.grey, size: 12),
                                        ),
                                        onTap: () {
                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Activity: New ${act['type']} for ${act['client_name']}')));
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ).animate().fadeIn(duration: 400.ms).slideX(begin: 0.1);
                            }).toList(),
                          )),
                ],
              ),
            ),
    );
  }

  Widget _buildGlobalBillingView(bool isWide) {
    return Column(
      key: const ValueKey('global_billing'),
      children: [
        Row(
          children: [
            Expanded(flex: 2, child: Text('Invoice', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.mutedTextColor))),
            Expanded(flex: 3, child: Text('Client', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.mutedTextColor))),
            if (isWide) const Expanded(flex: 2, child: Text('Type', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.mutedTextColor))),
            Expanded(flex: 2, child: Text('Amount', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.mutedTextColor))),
            if (isWide) const Expanded(flex: 2, child: Text('Status', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.mutedTextColor))),
          ],
        ),
        const Divider(height: 32),
        Expanded(
          child: _globalBillings.isEmpty
            ? const Center(child: Text('No billing records found'))
            : ListView.separated(
                itemCount: _globalBillings.length,
                separatorBuilder: (context, index) => const Divider(),
                itemBuilder: (context, index) {
                  final b = _globalBillings[index];
                  final isPaid = b['status'] == 'Received';
                  final dataMap = b['data'] as Map<String, dynamic>?;
                  final deadline = dataMap?['payment_deadline']?.toString() ?? '';
                  
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: isWide 
                      ? Row(
                          children: [
                            Expanded(flex: 2, child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(b['invoice_no'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13), overflow: TextOverflow.ellipsis),
                                if (deadline.isNotEmpty && !isPaid)
                                  Text('Due: $deadline', style: TextStyle(color: Colors.red.shade400, fontSize: 10, fontWeight: FontWeight.bold)),
                              ],
                            )),
                            Expanded(flex: 3, child: Text(b['client_name'] ?? '-', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                            Expanded(flex: 2, child: Text(b['type'] ?? 'INVOICE', style: const TextStyle(fontSize: 12))),
                            Expanded(flex: 2, child: Text(b['amount'] ?? '0/-', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: isPaid ? Colors.green : Colors.black))),
                            Expanded(
                              flex: 2,
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(color: (isPaid ? Colors.green : Colors.orange).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                                    child: Text(isPaid ? 'PAID' : 'PENDING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isPaid ? Colors.green : Colors.orange), textAlign: TextAlign.center),
                                  ),
                                  if (!isPaid)
                                    IconButton(
                                      icon: const Icon(Icons.calendar_month_rounded, size: 16, color: Colors.blue),
                                      onPressed: () => _setPaymentDeadlineDialog(context, Billing.fromMap(b)),
                                      tooltip: 'Set Deadline',
                                    ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(b['invoice_no'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                if (deadline.isNotEmpty && !isPaid)
                                  Text('Due: $deadline', style: TextStyle(color: Colors.red.shade400, fontSize: 11, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(b['client_name'] ?? '-', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Text(b['amount'] ?? '0/-', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: isPaid ? Colors.green : Colors.black)),
                                    if (!isPaid)
                                      IconButton(
                                        padding: const EdgeInsets.only(left: 4),
                                        constraints: const BoxConstraints(),
                                        icon: const Icon(Icons.calendar_month_rounded, size: 16, color: Colors.blue),
                                        onPressed: () => _setPaymentDeadlineDialog(context, Billing.fromMap(b)),
                                      ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(color: (isPaid ? Colors.green : Colors.orange).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                                  child: Text(isPaid ? 'PAID' : 'PENDING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isPaid ? Colors.green : Colors.orange)),
                                ),
                              ],
                            ),
                          ],
                        ),
                  );
                },
              ),
        ),
      ],
    );
  }

  Future<List<Map<String, dynamic>>> _fetchAuditLogs() async {
    final req = ModelQueries.list(amplify_models.ActivityLogs.classType, limit: 10000);
    final res = await Amplify.API.query(request: req).response;
    final allLogs = (res.data?.items ?? []).whereType<amplify_models.ActivityLogs>().toList() ?? [];
    allLogs.sort((a, b) => (b.createdAt?.getDateTimeInUtc() ?? DateTime.now()).compareTo(a.createdAt?.getDateTimeInUtc() ?? DateTime.now()));
    
    final usersReq = ModelQueries.list(amplify_models.Users.classType, limit: 10000);
    final usersRes = await Amplify.API.query(request: usersReq).response;
    final usersMap = {for (var u in usersRes.data?.items ?? []) if (u != null) u.id: u.name};
    
    return allLogs.map((m) => {
      ...m.toJson(),
      'users': {'name': usersMap[m.user_id] ?? 'Unknown'},
      'created_at': m.createdAt?.getDateTimeInUtc().toIso8601String(),
    }).toList();
  }

  Widget _buildAuditLogView(bool isWide) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _fetchAuditLogs(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final logsList = snapshot.data!;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  const Expanded(flex: 2, child: Text('Time', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.mutedTextColor))),
                  const Expanded(flex: 2, child: Text('Staff', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.mutedTextColor))),
                  if (isWide) const Expanded(flex: 2, child: Text('Action', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.mutedTextColor))),
                  const Expanded(flex: 4, child: Text('Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.mutedTextColor))),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                itemCount: logsList.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final log = logsList[index];
                  final userName = (log['users'] as Map<String, dynamic>?)?['name'] ?? 'Unknown';
                  final date = DateTime.parse(log['created_at'].toString()).toLocal();
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(flex: 2, child: Text(DateFormat('HH:mm, dd MMM').format(date), style: const TextStyle(fontSize: 11))),
                        Expanded(flex: 2, child: Text(userName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                        if (isWide) Expanded(
                          flex: 2, 
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: AppTheme.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                            child: Text(log['action'] ?? '-', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.primaryColor), textAlign: TextAlign.center),
                          ),
                        ),
                        Expanded(flex: 4, child: Text(log['details'] ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.mutedTextColor))),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSystemBanner(bool isWide) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isWide ? 40 : 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF13131A), Color(0xFF1E1E2F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 24, offset: const Offset(0, 12)),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: -20,
            bottom: -20,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [AppTheme.primaryColor.withValues(alpha: 0.2), Colors.transparent],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.stars_rounded, color: AppTheme.primaryColor, size: 14),
                    const SizedBox(width: 6),
                    const Text('OPERATIONAL LEADERSHIP', style: TextStyle(color: AppTheme.primaryColor, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Managerial Command Suite',
                style: TextStyle(color: Colors.white, fontSize: isWide ? 32 : 24, fontWeight: FontWeight.w900, letterSpacing: -0.5),
              ),
              const SizedBox(height: 12),
              Text(
                'Oversee full-cycle business operations, financial payables, and high-level staff productivity metrics.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: isWide ? 15 : 14, height: 1.5),
              ),
              const SizedBox(height: 32),
              // Integrated Quick Actions
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _buildBannerAction('Assign Delivery/Pickup/Visit', Icons.add_task_rounded, () => setState(() => _selectedIndex = 8)),
                  _buildBannerAction('Create Work', Icons.assignment_add, () => setState(() => _selectedIndex = 6)),
                  _buildBannerAction('Manage Staff', Icons.person_add_alt_1_rounded, () => setState(() => _selectedIndex = 2)),
                  _buildBannerAction('Broadcast', Icons.campaign_rounded, () => setState(() => _selectedIndex = 6)),
                ],
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 600.ms).slideY(begin: 0.05, curve: Curves.easeOutCubic);
  }

  Widget _buildBannerAction(String title, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppTheme.primaryColor, size: 18),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionCard(String title, IconData icon, Color color, VoidCallback onTap, bool isWide) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: isWide ? 120 : (MediaQuery.of(context).size.width - 64) / 2,
        padding: EdgeInsets.all(isWide ? 20 : 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.2)),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, 4)),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 12),
            Text(
              title, 
              style: TextStyle(color: AppTheme.textColor, fontWeight: FontWeight.bold, fontSize: isWide ? 12 : 11),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailList() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _getCategoryData(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        
        final data = snapshot.data!;
        
        switch (_selectedCategory) {
          case 'Expiring Licences':
            return _buildGenericList(
              headers: ['Client Name', 'License Type', 'Expiry Date'],
              items: data.map((map) {
                return {
                  'title': map['client_name'] ?? map['manual_client_name'] ?? 'Unknown',
                  'sub': 'File: ${map['file_no'] ?? '-'}',
                  'status': 'Expiring Soon',
                  'statusColor': Colors.orange,
                  'trailing': map['expiry_date'] != null ? DateFormat('dd MMM yyyy').format(DateTime.parse(map['expiry_date'].toString())) : '-',
                };
              }).toList(),
            );
          case 'Signature Expiry':
            return _buildGenericList(
              headers: ['Holder Name', 'Username', 'Expiry Date'],
              items: data.map((map) {
                return {
                  'title': map['client_name'] ?? 'Unknown',
                  'sub': 'User: ${map['username'] ?? '-'}',
                  'status': 'Renewal',
                  'statusColor': AppTheme.primaryColor,
                  'trailing': map['dsc_expiry_date'] != null ? DateFormat('dd MMM yyyy').format(DateTime.parse(map['dsc_expiry_date'].toString())) : '-',
                };
              }).toList(),
            );
          case 'Work Management':
            return _buildGenericList(
              headers: ['Deal Name', 'Stage', 'Amount'],
              items: data.map((map) {
                return {
                  'title': map['name'] ?? 'Unknown',
                  'sub': 'Client: ${map['client_name'] ?? '-'}',
                  'status': map['stage'] ?? 'New',
                  'statusColor': Colors.purple,
                  'trailing': '₹${map['amount'] ?? '0'}',
                };
              }).toList(),
            );
          case 'Bills to Receive':
            return _buildGenericList(
              headers: ['Client Name', 'Invoice No', 'Amount'],
              items: data.map((map) {
                Map<String, dynamic>? parsedData;
                if (map['data'] != null) {
                  if (map['data'] is Map) {
                    parsedData = map['data'];
                  } else if (map['data'] is String) {
                    try {
                      parsedData = jsonDecode(map['data']);
                    } catch (_) {}
                  }
                }
                
                return {
                  'title': map['client_name'] ?? 'Unknown',
                  'sub': 'Inv: ${map['invoice_no'] ?? '-'}${parsedData != null && parsedData['payment_deadline'] != null && parsedData['payment_deadline'].toString().isNotEmpty ? '  •  Due: ${parsedData['payment_deadline']}' : ''}',
                  'status': 'Unpaid',
                  'statusColor': AppTheme.primaryColor,
                  'trailing': map['amount'] ?? '-',
                  'data': map,
                };
              }).toList(),
            );
          case 'Clients':
            return _buildGenericList(
              headers: ['Client Name', 'Address', 'Balance'],
              items: data.map((map) {
                return {
                  'title': map['name'] ?? 'Unknown',
                  'sub': map['address'] ?? '-',
                  'status': 'Balance Due',
                  'statusColor': AppTheme.primaryColor,
                  'trailing': '₹${map['balance_due'] ?? '0'}',
                  'data': map,
                };
              }).toList(),
            );
          default:
            return const Center(child: Text('No data available'));
        }
      },
    );
  }

  Future<List<Map<String, dynamic>>> _getCategoryData() async {
    switch (_selectedCategory) {
      case 'Expiring Licences':
        final req = ModelQueries.list(
          amplify_models.ClientLicenses.classType,
          where: amplify_models.ClientLicenses.EXPIRY_DATE.le(DateTime.now().add(const Duration(days: 30)).toIso8601String()),
         limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final list = (res.data?.items ?? []).whereType<amplify_models.ClientLicenses>().toList() ?? [];
        list.sort((a, b) => (a.expiry_date ?? '').compareTo(b.expiry_date ?? ''));
        return list.map((l) => {
          'client_name': l.client_id, // Might need to resolve name
          'license_type_name': l.license_type_id,
          ...l.toJson(),
        }).toList();
        
      case 'Signature Expiry':
        final req = ModelQueries.list(
          amplify_models.DscRecords.classType,
          where: amplify_models.DscRecords.DSC_EXPIRY_DATE.le(DateTime.now().add(const Duration(days: 30)).toIso8601String()),
         limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final list = (res.data?.items ?? []).whereType<amplify_models.DscRecords>().toList() ?? [];
        list.sort((a, b) => (a.dsc_expiry_date ?? '').compareTo(b.dsc_expiry_date ?? ''));
        return list.map((l) => l.toJson()).toList();
        
      case 'Work Management':
        final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.STAGE.ne('Completed'), limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final list = (res.data?.items ?? []).whereType<amplify_models.Deals>().where((d) {
          final isCrm = (d.pipeline ?? '').toLowerCase() == 'crm' || (d.pipeline ?? '').toLowerCase() == 'lead';
          if (isCrm && d.is_won != true) return false;
          return true;
        }).toList();
        list.sort((a, b) => (b.id).compareTo(a.id));
        return list.map((l) => l.toJson()).toList();
        
      case 'Bills to Receive':
        final req = ModelQueries.list(
          amplify_models.Billings.classType,
          where: amplify_models.Billings.TYPE.eq('INVOICE').and(amplify_models.Billings.STATUS.ne('Received')),
         limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final list = (res.data?.items ?? []).whereType<amplify_models.Billings>().toList() ?? [];
        list.sort((a, b) => (b.id).compareTo(a.id));
        return list.map((l) => l.toJson()).toList();
        
      case 'Clients':
        final req = ModelQueries.list(amplify_models.Clients.classType, limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final list = (res.data?.items ?? []).whereType<amplify_models.Clients>().toList() ?? [];
        list.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
        return list.map((l) => l.toJson()).toList();
        
      default:
        final req = ModelQueries.list(amplify_models.Clients.classType, limit: 1);
        final res = await Amplify.API.query(request: req).response;
        return (res.data?.items ?? []).whereType<amplify_models.Clients>().map((e) => e.toJson()).toList() ?? [];
    }
  }

  Widget _buildGenericList({required List<String> headers, required List<Map<String, dynamic>> items}) {
    final filteredItems = items.where((item) {
      final search = _searchController.text.toLowerCase();
      return item['title'].toString().toLowerCase().contains(search) || 
             item['sub'].toString().toLowerCase().contains(search);
    }).toList();

    IconData categoryIcon = Icons.description_outlined;
    if (_selectedCategory == 'Expiring Licences') {
      categoryIcon = Icons.verified_user_rounded;
    } else if (_selectedCategory == 'Bills to Receive') categoryIcon = Icons.account_balance_wallet_rounded;
    else if (_selectedCategory == 'Work Management') categoryIcon = Icons.work_rounded;
    else if (_selectedCategory == 'Clients') categoryIcon = Icons.people_rounded;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search $_selectedCategory...',
              prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.primaryColor),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.05)),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              hintStyle: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ),
        ),
        
        Expanded(
          child: filteredItems.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search_off_rounded, size: 64, color: Colors.grey.shade300),
                    const SizedBox(height: 16),
                    Text('No items found in $_selectedCategory', style: const TextStyle(color: Colors.grey)),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: filteredItems.length,
                padding: const EdgeInsets.only(bottom: 40),
                itemBuilder: (context, index) {
                  final item = filteredItems[index];
                  final statusColor = item['statusColor'] as Color;
                  
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4)),
                      ],
                    ),
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: IntrinsicHeight(
                        child: Row(
                          children: [
                            Container(width: 4, color: statusColor),
                            Expanded(
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                leading: Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: statusColor.withValues(alpha: 0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(categoryIcon, color: statusColor, size: 20),
                                ),
                                title: Text(item['title'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(item['sub'], style: const TextStyle(fontSize: 12, color: AppTheme.mutedTextColor)),
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: statusColor.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(item['status'], style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 10)),
                                    ),
                                    if (item.containsKey('trailing')) ...[
                                      const SizedBox(height: 4),
                                      Text(item['trailing'], style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                                    ],
                                  ],
                                ),
                                onTap: () {
                                   _showQuickActionMenu(context, item);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ).animate().fadeIn(delay: (index * 50).ms).slideX(begin: 0.1);
                },
              ),
        ),
      ],
    );
  }

  void _showQuickActionMenu(BuildContext context, Map<String, dynamic> item) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        final statusColor = (item['statusColor'] as Color?) ?? AppTheme.primaryColor;
        final title = item['title'] ?? item['client_name'] ?? 'Quick Action';
        final sub = item['sub'] ?? 'Invoice: ${item['invoice_no'] ?? '-'}';
        final billingMap = item['data'] ?? item; // Handle both generic list and direct row

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: statusColor.withValues(alpha: 0.1),
                      child: Icon(Icons.bolt_rounded, color: statusColor),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                          Text(sub, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                if (_selectedCategory == 'Bills to Receive' || _selectedCategory == null) ...[
                  _actionTile(Icons.calendar_month_rounded, 'Set Deadline', 'Update payment deadline', Colors.orange, onTap: () {
                    Navigator.pop(context);
                    _setPaymentDeadlineDialog(context, Billing.fromMap(billingMap));
                  }),
                  _actionTile(Icons.check_circle_outline_rounded, 'Mark as Paid', 'Update payment status', AppTheme.primaryColor, onTap: () {
                    Navigator.pop(context);
                    _markPaidBilling(Billing.fromMap(billingMap));
                  }),
                  _actionTile(Icons.copy_rounded, 'Duplicate Invoice', 'Create copy with next bill number', Colors.blue, onTap: () {
                    Navigator.pop(context);
                    _duplicateBilling(Billing.fromMap(billingMap));
                  }),
                  _actionTile(Icons.edit_note_rounded, 'Edit Invoice', 'Modify billing details', Colors.blue, onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (c) => InvoiceCreatorPage(
                      billing: Billing.fromMap(billingMap),
                      onSaved: (id) {
                        _fetchAdminStats();
                        Navigator.pop(context);
                      },
                    )));
                  }),
                  _actionTile(Icons.delete_outline_rounded, 'Delete Invoice', 'Remove this record', Colors.red, onTap: () {
                    Navigator.pop(context);
                    _deleteBilling(Billing.fromMap(billingMap));
                  }),
                  _actionTile(Icons.cancel_outlined, 'Mark as Not Interested', 'Client declined payment', Colors.red, onTap: () {
                    Navigator.pop(context);
                    _showReasonDialog(context);
                  }),
              ] else ...[
                _actionTile(Icons.phone_rounded, 'Call Client', 'Direct contact via phone', AppTheme.primaryColor, onTap: () {
                  Navigator.pop(context);
                  final phone = item['data']?['phone'] ?? item['data']?['contact_info'] ?? '';
                  if (phone.isNotEmpty) {
                    launchUrl(Uri.parse('tel:$phone'));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Phone number not found')));
                  }
                }),
                _actionTile(Icons.message_rounded, 'WhatsApp', 'Send message to client', AppTheme.primaryColor, onTap: () {
                  Navigator.pop(context);
                  final phone = item['data']?['phone'] ?? item['data']?['contact_info'] ?? '';
                  if (phone.isNotEmpty) {
                    WhatsAppCloudService.launchWhatsAppApp(
                      phone: phone.toString(),
                      message: 'Hello, this is regarding your service with Cochin United Consultancy.',
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Phone number not found')));
                  }
                }),
                _actionTile(Icons.history_rounded, 'View History', 'Previous renewals and logs', Colors.blue, onTap: () {
                  Navigator.pop(context);
                  _showClientHistory(context, item);
                }),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _fetchClientHistory(String title) async {
    final req = ModelQueries.list(
      amplify_models.ActivityLogs.classType,
      where: amplify_models.ActivityLogs.DETAILS.contains(title),
     limit: 10000);
    final res = await amplify_core.Amplify.API.query(request: req).response;
    final logs = (res.data?.items ?? []).whereType<amplify_models.ActivityLogs>().toList() ?? [];
    logs.sort((a, b) => (b.createdAt?.getDateTimeInUtc() ?? DateTime.now()).compareTo(a.createdAt?.getDateTimeInUtc() ?? DateTime.now()));
    return logs.map((l) => l.toJson()).toList();
  }

  void _showClientHistory(BuildContext context, Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('History: ${item['title']}', style: const TextStyle(fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 500,
          height: 400,
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _fetchClientHistory(item['title'] ?? ''),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final logs = snapshot.data!;
              if (logs.isEmpty) return const Center(child: Text('No history found for this item'));
              
              return ListView.separated(
                itemCount: logs.length,
                separatorBuilder: (c, i) => const Divider(),
                itemBuilder: (c, i) {
                  final log = logs[i];
                  final date = DateFormat('dd MMM, HH:mm').format(DateTime.parse(log['created_at'].toString()).toLocal());
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(log['action'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: Text(log['details'] ?? '-', style: const TextStyle(fontSize: 12)),
                    trailing: Text(date, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _setPaymentDeadlineDialog(BuildContext context, Billing b) async {
    final currentDeadline = b.data?['payment_deadline']?.toString() ?? '';
    final controller = TextEditingController(text: currentDeadline);
    
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Set Payment Deadline', style: TextStyle(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Deadline Date (dd/mm/yyyy)',
            hintText: 'e.g. 15/06/2026',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      )
    );

    if (result == true) {
      try {
        final d = Map<String, dynamic>.from(b.data ?? {});
        d['payment_deadline'] = controller.text;
        final req = ModelQueries.list(amplify_models.Billings.classType, where: amplify_models.Billings.ID.eq(b.id), limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final billing = res.data?.items.first;
        if (billing != null) {
          final updatedBilling = billing.copyWith(data: jsonEncode(d));
          await BackupAwareApi().update(updatedBilling);
        }
        _fetchAdminStats();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deadline updated successfully')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _markPaidBilling(Billing b) async {
    double grandTotal = NumberToWords.parseCurrency(b.grandTotal.isNotEmpty ? b.grandTotal : (b.amount ?? '0'));
    double previouslyReceived = NumberToWords.parseCurrency(b.data?['advance_received']?.toString() ?? '0');
    double currentBalance = grandTotal - previouslyReceived;
    
    if (currentBalance <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This invoice is already fully paid.')));
      return;
    }

    bool isFullPayment = true;
    final receivedController = TextEditingController(text: currentBalance.toStringAsFixed(0));
    double newBalance = 0;

    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(
      builder: (context, setState) {
        double receivedAmount = double.tryParse(receivedController.text) ?? 0;
        newBalance = currentBalance - receivedAmount;
        if (newBalance < 0) newBalance = 0;

        return AlertDialog(
          title: const Text('Confirm Payment', style: TextStyle(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Outstanding Balance: ₹${NumberToWords.formatIndianCurrency(currentBalance).replaceAll('/-', '')}'),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Full Payment Received?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                value: isFullPayment,
                activeThumbColor: AppTheme.primaryColor,
                onChanged: (val) {
                  setState(() {
                    isFullPayment = val;
                    if (val) {
                      receivedController.text = currentBalance.toStringAsFixed(0);
                    } else {
                      receivedController.clear();
                    }
                  });
                },
                contentPadding: EdgeInsets.zero,
              ),
              if (!isFullPayment) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: receivedController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Amount Received (₹)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (val) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Text('Remaining Balance: ₹${NumberToWords.formatIndianCurrency(newBalance).replaceAll('/-', '')}', style: TextStyle(color: newBalance > 0 ? Colors.orange.shade700 : AppTheme.primaryColor, fontWeight: FontWeight.bold)),
              ]
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Confirm')),
          ],
        );
      }
    ));

    if (ok == true) {
      try {
        double newlyReceived = double.tryParse(receivedController.text) ?? 0;
        if (newlyReceived <= 0) return;

        double totalReceived = previouslyReceived + newlyReceived;
        double updatedBalance = grandTotal - totalReceived;
        if (updatedBalance < 0) updatedBalance = 0;

        bool isPaid = updatedBalance <= 0;

        final d = Map<String, dynamic>.from(b.data ?? {});
        d['payment_received'] = isPaid;
        d['advance_received'] = NumberToWords.formatIndianCurrency(totalReceived);
        d['balance_due'] = updatedBalance > 0 ? NumberToWords.formatIndianCurrency(updatedBalance) : '0/-';
        if (isPaid) d['payment_date'] = DateTime.now().toIso8601String();

        final req = ModelQueries.list(amplify_models.Billings.classType, where: amplify_models.Billings.ID.eq(b.id), limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final billing = res.data?.items.first;
        if (billing != null) {
          final updatedBilling = billing.copyWith(status: isPaid ? 'Received' : 'Pending', data: jsonEncode(d));
          await BackupAwareApi().update(updatedBilling);
        }
        
        if (b.clientName != null && b.clientName!.isNotEmpty) {
           final cReq = ModelQueries.list(amplify_models.Clients.classType, where: amplify_models.Clients.NAME.eq(b.clientName!), limit: 10000);
           final cRes = await Amplify.API.query(request: cReq).response;
           final client = cRes.data?.items.isNotEmpty == true ? cRes.data?.items.first : null;
           if (client != null) {
             final updatedClient = client.copyWith(balance_due: d['balance_due'].toString());
             await BackupAwareApi().update(updatedClient);
           }
        }

        _fetchAdminStats();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Payment recorded successfully')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _deleteBilling(Billing b) async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Confirm Delete', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
      content: Text('Are you sure you want to delete invoice ${b.invoiceNo}?\nThis action cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.pop(c, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
          child: const Text('Delete'),
        ),
      ],
    ));

    if (ok == true) {
      try {
        final req = ModelQueries.list(amplify_models.Billings.classType, where: amplify_models.Billings.ID.eq(b.id), limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final billing = res.data?.items.first;
        if (billing != null) {
          await BackupAwareApi().delete(billing);
        }
        _fetchAdminStats();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invoice deleted successfully')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
      }
    }
  }

  Future<void> _duplicateBilling(Billing b) async {
    final auth = b.authorities ?? '';
    String nextNo = '';
    final prefix = b.type == 'QUOTATION' ? 'CC-' : 'AA-';
    final next = await BillingService().getNextInvoiceNo(prefix);
    if (next != null) {
      nextNo = next;
    } else {
      nextNo = '${prefix}001';
    }

    final duplicated = Billing(
      clientName: b.clientName,
      invoiceNo: nextNo,
      date: DateFormat('dd/MM/yyyy').format(DateTime.now()),
      amount: b.amount,
      type: b.type,
      category: b.category,
      authorities: b.authorities,
      status: 'Pending',
      data: Map<String, dynamic>.from(b.data ?? {})
        ..remove('payment_received')
        ..remove('advance_received')
        ..remove('payment_date')
        ..remove('balance_due'),
    );

    Navigator.push(context, MaterialPageRoute(builder: (c) => InvoiceCreatorPage(
      billing: duplicated,
      onSaved: (id) {
        _fetchAdminStats();
        Navigator.pop(context);
      },
    )));
  }

  Widget _actionTile(IconData icon, String title, String sub, Color color, {VoidCallback? onTap}) {
    return ListTile(
      onTap: onTap ?? () => Navigator.pop(context),
      contentPadding: EdgeInsets.zero,
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      subtitle: Text(sub, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      trailing: const Icon(Icons.chevron_right_rounded, size: 18),
    );
  }

  Widget _buildSettingsPage() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Premium Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E1E24), Color(0xFF2D2D35)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.manage_accounts_rounded, color: AppTheme.primaryColor, size: 32),
                        ),
                        const SizedBox(width: 20),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Account Settings', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
                              SizedBox(height: 4),
                              Text('Manage your personal information and security preferences.', style: TextStyle(fontSize: 14, color: Colors.white70)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              
              _settingsSection('Account Profile', [
                _settingsTile(
                  Icons.person_outline_rounded, 
                  'Personal Information', 
                  'View your profile details',
                  onTap: () => _showProfileDialog(context),
                  isFirst: true,
                ),
                _settingsTile(
                  Icons.lock_outline_rounded, 
                  'Change Password', 
                  'Update your login credentials', 
                  onTap: () => _showChangePasswordDialog(context),
                  isLast: true,
                ),
              ]),
              
              const SizedBox(height: 24),
              
              _settingsSection('Account Actions', [
                _settingsTile(
                  Icons.logout_rounded, 
                  'Sign Out', 
                  'Logout from your account',
                  iconColor: Colors.red.shade400,
                  onTap: () async {
                    await AuthService().logout();
                    if (mounted) {
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(builder: (context) => const LoginScreen()),
                        (route) => false,
                      );
                    }
                  },
                  isFirst: true,
                  isLast: true,
                ),
              ]),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _settingsSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Text(
            title.toUpperCase(), 
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: AppTheme.mutedTextColor),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  void _showProfileDialog(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final userId = await AuthService().getUserId();
      final userIdStr = userId.toString();
      final req = ModelQueries.list(amplify_models.Users.classType, where: amplify_models.Users.ID.eq(userIdStr), limit: 10000);
      final resList = await Amplify.API.query(request: req).response;
      final res = resList.data?.items.isNotEmpty == true ? resList.data?.items.first : null;
      
      if (!mounted) return;
      Navigator.pop(context); // Remove loader

      if (res == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to load profile')));
        return;
      }

      final nameController = TextEditingController(text: res.name);
      final emailController = TextEditingController(text: res.email ?? '');
      
      final username = res.username ?? '-';
      final role = res.role?.toUpperCase() ?? '-';
      bool isSaving = false;

      showDialog(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) {
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              elevation: 20,
              backgroundColor: Colors.white,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 450),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Premium Dialog Header
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: const BoxDecoration(
                        color: Color(0xFF1E1E24), // Dark background matching sidebar
                        borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor.withValues(alpha: 0.2),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.person, color: AppTheme.primaryColor, size: 28),
                          ),
                          const SizedBox(width: 16),
                          const Text('Personal Information', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                        ],
                      ),
                    ),
                    
                    // Form Content
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Read-only Info Cards
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('USERNAME', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                                      const SizedBox(height: 4),
                                      Text(username, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('ROLE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                                      const SizedBox(height: 4),
                                      Text(role, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppTheme.primaryColor)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          
                          const SizedBox(height: 24),
                          const Text('EDIT PROFILE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.grey, letterSpacing: 1.2)),
                          const SizedBox(height: 12),
                          
                          TextField(
                            controller: nameController,
                            decoration: InputDecoration(
                              labelText: 'Full Name', 
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: emailController,
                            decoration: InputDecoration(
                              labelText: 'Email Address', 
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                            ),
                            keyboardType: TextInputType.emailAddress,
                          ),
                          const SizedBox(height: 32),
                          
                          // Actions
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: isSaving ? null : () => Navigator.pop(context), 
                                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
                                child: const Text('Cancel', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton(
                                onPressed: isSaving ? null : () async {
                                  setState(() => isSaving = true);
                                  try {
                                    final req = ModelQueries.list(amplify_models.Users.classType, where: amplify_models.Users.ID.eq(userId.toString()), limit: 10000);
                                    final resList = await Amplify.API.query(request: req).response;
                                    final userObj = resList.data?.items.isNotEmpty == true ? resList.data?.items.first : null;
                                    if (userObj != null) {
                                      final updatedUser = userObj.copyWith(
                                        name: nameController.text.trim(),
                                        email: emailController.text.trim(),
                                      );
                                      await BackupAwareApi().update(updatedUser);
                                    }
                                    
                                    if (context.mounted) {
                                      Navigator.pop(context);
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile updated successfully!')));
                                    }
                                  } catch (e) {
                                    setState(() => isSaving = false);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                                    }
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primaryColor, 
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: isSaving 
                                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        ),
      );
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Widget _profileItem(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.primaryColor),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
              Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _settingsTile(IconData icon, String title, String subtitle, {VoidCallback? onTap, bool isFirst = false, bool isLast = false, Color? iconColor}) {
    final effectiveIconColor = iconColor ?? AppTheme.primaryColor;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(isFirst ? 16 : 0),
          bottom: Radius.circular(isLast ? 16 : 0),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            border: isLast ? null : Border(bottom: BorderSide(color: Colors.grey.shade100)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: effectiveIconColor.withValues(alpha: 0.1), 
                  borderRadius: BorderRadius.circular(10)
                ),
                child: Icon(icon, color: effectiveIconColor, size: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 13, color: AppTheme.mutedTextColor)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.black26),
            ],
          ),
        ),
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context) {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    bool isLoading = false;
    String? errorMessage;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            elevation: 20,
            backgroundColor: Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 450),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Premium Dialog Header
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1E1E24), // Dark background matching sidebar
                      borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.lock_outline_rounded, color: AppTheme.primaryColor, size: 28),
                        ),
                        const SizedBox(width: 16),
                        const Text('Change Password', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                      ],
                    ),
                  ),
                  
                  // Form Content
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (errorMessage != null)
                          Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 24),
                            decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.red.shade200)),
                            child: Row(
                              children: [
                                Icon(Icons.error_outline_rounded, color: Colors.red.shade700, size: 20),
                                const SizedBox(width: 12),
                                Expanded(child: Text(errorMessage!, style: TextStyle(color: Colors.red.shade700, fontSize: 13, fontWeight: FontWeight.w600))),
                              ],
                            ),
                          ),
                          
                        TextField(
                          controller: currentController,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: 'Current Password', 
                            filled: true,
                            fillColor: Colors.white,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: newController,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: 'New Password', 
                            filled: true,
                            fillColor: Colors.white,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: confirmController,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: 'Confirm Password', 
                            filled: true,
                            fillColor: Colors.white,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                          ),
                        ),
                        const SizedBox(height: 32),
                        
                        // Actions
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: isLoading ? null : () => Navigator.pop(context), 
                              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
                              child: const Text('Cancel', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              onPressed: isLoading ? null : () async {
                                setState(() => errorMessage = null);
                                final current = currentController.text;
                                final newPass = newController.text;
                                final confirm = confirmController.text;
                                
                                if (current.isEmpty || newPass.isEmpty || confirm.isEmpty) {
                                  setState(() => errorMessage = 'All fields are required.');
                                  return;
                                }
                                
                                if (newPass != confirm) {
                                  setState(() => errorMessage = 'New passwords do not match.');
                                  return;
                                }
                                
                                setState(() => isLoading = true);
                                
                                try {
                                  final userId = await AuthService().getUserId();
                                  if (userId == null) throw Exception('Not logged in.');
                                  
                                  // Verify current password
                                  final req = ModelQueries.list(amplify_models.Users.classType, where: amplify_models.Users.ID.eq(userId.toString()), limit: 10000);
                                  final resList = await Amplify.API.query(request: req).response;
                                  final userObj = resList.data?.items.isNotEmpty == true ? resList.data?.items.first : null;
                                  
                                  if (userObj == null || userObj.password != current) {
                                    setState(() {
                                      errorMessage = 'Incorrect current password.';
                                      isLoading = false;
                                    });
                                    return;
                                  }
                                  
                                  // Update password
                                  final updatedUser = userObj.copyWith(password: newPass);
                                  await BackupAwareApi().update(updatedUser);
                                  
                                  if (context.mounted) {
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password updated successfully!')));
                                  }
                                } catch (e) {
                                  setState(() {
                                    errorMessage = 'Error updating password: $e';
                                    isLoading = false;
                                  });
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryColor, 
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: isLoading 
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Text('Update Password', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      ),
    );
  }

  void _showReasonDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reason for Not Interested'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Please provide a reason why the client is not interested.',
              style: TextStyle(fontSize: 13, color: AppTheme.mutedTextColor),
            ),
            const SizedBox(height: 16),
            TextField(
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Enter reason here...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Reason submitted successfully')),
              );
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );
  }

  IconData _getLogIcon(String? type) {
    switch (type) {
      case 'Invoice': return Icons.receipt_long_rounded;
      case 'Client': return Icons.person_rounded;
      case 'Work': return Icons.work_rounded;
      case 'Task': return Icons.task_alt_rounded;
      default: return Icons.info_outline_rounded;
    }
  }
}
