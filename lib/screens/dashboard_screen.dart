import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_core/amplify_core.dart' as amplify_core;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter/services.dart';

import 'dart:async';
import 'dart:io' show Platform;
import '../theme.dart';
import 'login_screen.dart';

import 'client_management_screen.dart';
import 'dsc_management_screen.dart';
import 'billing_screen.dart';
import 'license_dashboard_screen.dart';
import 'services_screen.dart';
import 'admin_dashboard_screen.dart';
import 'work_management_screen.dart';
import 'staff_chat_list_screen.dart';
import 'task_management_screen.dart';
import 'reminder_calendar_screen.dart';
import '../widgets/upcoming_reminders_widget.dart';
import 'delivery_dashboard_screen.dart';
import 'accountant_dashboard_screen.dart';

import 'help_and_queries_management_screen.dart';
import 'company_bill_management_screen.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../widgets/notification_bell.dart';
import 'package:intl/intl.dart';
import '../services/billing_service.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'dart:convert';
import 'client_files_screen.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../widgets/premium_app_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/billing.dart';
import '../utils/number_to_words.dart';
import 'checklist_screen.dart';
import '../services/checklist_service.dart';
import 'office_details_screen.dart';
import 'property_management_screen.dart';
import 'contact_book_screen.dart';
import '../widgets/upcoming_deadlines_widget.dart';
import '../widgets/premium_stat_card.dart';
import '../services/attendance_service.dart';
import 'uploaded_files_screen.dart';
import 'inward_post_screen.dart';
import 'document_list_screen.dart';
import 'verification_history_view.dart';
import 'travel_log_screen.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import 'file_acknowledgement_screen.dart';
import 'package:cuc_app/services/birthday_service.dart';
import '../widgets/startup_task_popup.dart';
import '../services/auto_backup_service.dart';
import 'formats_screen.dart';
import 'crm_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;
  String? _selectedCategory;
  final _searchController = TextEditingController();
  bool _isLoadingStats = true;
  bool _isAdmin = false;
  String _userRole = 'user';
  String _userName = 'User';
  DateTime? _lastPressedAt;
  StreamSubscription? _notifSubscription;
  bool _isCheckedIn = false;
  String? _attendanceId;
  String? _checkInTimeStr;
  int _dailyTotalMinutes = 0;
  bool _isAttendanceLoading = true;

  
  Map<String, dynamic> _stats = {
    'expiringLicences': 0,
    'dscExpiry': 0,
    'birthdays': 0,
    'billsToReceive': 0,
    'expiringLicencesDetail': 'Checking...',
    'dscExpiryDetail': 'Checking...',
    'birthdaysDetail': 'Checking...',
    'billsDetail': 'Checking...',
    'tasksDetail': 'Checking...',
    'pendingChecklists': 0,
    'crmLeads': 0,
    'crmLeadsDetail': 'Active leads',
  };
  
  @override
  void dispose() {
    _notifSubscription?.cancel();

    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _checkRoleAndRedirect();
    // Add a small delay to ensure DB service is ready on mobile
    Future.delayed(const Duration(milliseconds: 500), () => _fetchStats());
    
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
    _fetchAttendanceStatus();

    // Silent auto-backup (runs once per 24 hours)
    AutoBackupService().runIfNeeded();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      StartupTaskPopup.checkAndShow(context);
    });
    
    // Check and show staff birthdays after a short delay so the dashboard can load first
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        BirthdayService.checkAndShowBirthdays(context);
      }
    });
  }

  Future<void> _forceCheckOut() async {
    if (!mounted || _attendanceId == null) return;
    setState(() => _isAttendanceLoading = true);
    try {
      await AttendanceService().checkOut(_attendanceId!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('GPS was turned off. You have been automatically checked out.'),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      debugPrint('Force checkout error: $e');
    }
    await _fetchAttendanceStatus();
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

  Future<void> _showTravelLogDialog() async {
    final TextEditingController destController = TextEditingController();
    bool isSubmitting = false;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Travel Log'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Where are you going?'),
              const SizedBox(height: 12),
              TextField(
                controller: destController,
                decoration: const InputDecoration(
                  hintText: 'e.g. Ernakulam North for Delivery',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final dest = destController.text.trim();
                      if (dest.isEmpty) return;

                      setState(() => isSubmitting = true);
                      try {
                        final userId = await AuthService().getUserId();
                        if (userId != null) {
                          final newLog = amplify_models.TravelLogs(
                            user_id: userId,
                            destination: dest,
                          );
                          await BackupAwareApi().create(newLog);
                          if (mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Travel log saved successfully'), backgroundColor: Colors.green),
                            );
                          }
                        }
                      } catch (e) {
                        setState(() => isSubmitting = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Failed to save log: $e'), backgroundColor: Colors.redAccent),
                          );
                        }
                      }
                    },
              child: isSubmitting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkTodayChecklists() async {
    final id = await AuthService().getUserId();
    if (id != null) {
      final count = await ChecklistService().getPendingCountForUser(id);
      if (mounted) {
        setState(() => _stats['pendingChecklists'] = count);
        if (count > 0) {
          _showChecklistDialog(count);
        }
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

  Future<void> _checkRoleAndRedirect() async {
    final role = await AuthService().getUserRole();
    if (role == 'delivery' && mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const DeliveryDashboardScreen()),
      );
      return;
    }
    _checkRole();
  }

  Future<void> _checkRole() async {
    final role = await AuthService().getUserRole();
    String? name = await AuthService().getUserName();
    
    // If name is missing or generic, try to fetch the real name from the DB
    if (name == null || name == 'admin' || name == 'user' || name == 'accountant') {
      try {
        final req = ModelQueries.list(
          amplify_models.Users.classType,
          where: amplify_models.Users.USERNAME.eq(name ?? (role == 'admin' ? 'admin' : 'accountant')),
          limit: 10000
        );
        final res = await Amplify.API.query(request: req).response;
        if (res.data?.items.isNotEmpty == true) {
          name = res.data!.items.first?.name;
        }
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
      _isAdmin = role == 'admin';
      _userRole = role ?? 'user';
      String displayName = name ?? 'User';
      if (displayName.isNotEmpty) {
        _userName = displayName[0].toUpperCase() + displayName.substring(1);
      } else {
        _userName = displayName;
      }
    });
    }
  }

  Future<void> _fetchStats({int retryCount = 0}) async {
    if (!mounted) return;
    setState(() => _isLoadingStats = true);
    
    try {
      // 1. Expiring Licences (next 30 days)
      final thirtyDaysStr = DateTime.now().add(const Duration(days: 30)).toIso8601String();
      final licReq = ModelQueries.list(
        amplify_models.ClientLicenses.classType,
        where: amplify_models.ClientLicenses.EXPIRY_DATE.le(thirtyDaysStr),
        limit: 10000
      );
      final licCountRes = await Amplify.API.query(request: licReq).response;
      final licCount = licCountRes.data?.items.length ?? 0;

      // 2. DSC Expiry (next 30 days)
      final dscReq = ModelQueries.list(
        amplify_models.DscRecords.classType,
        where: amplify_models.DscRecords.DSC_EXPIRY_DATE.le(thirtyDaysStr),
        limit: 10000
      );
      final dscCountRes = await Amplify.API.query(request: dscReq).response;
      final dscCount = dscCountRes.data?.items.length ?? 0;

      // 3. Active Deals
      final userId = await AuthService().getUserId();
      
      int dealsCount = 0;
      amplify_core.QueryPredicate dealsWhere = amplify_models.Deals.STAGE.ne('Completed');
      if (!_isAdmin && userId != null) {
        dealsWhere = amplify_models.Deals.STAGE.ne('Completed').and(amplify_models.Deals.RESPONSIBLE_ID.eq(userId));
      }
      final dealsReq = ModelQueries.list(amplify_models.Deals.classType, where: dealsWhere, limit: 10000);
      final dealsRes = await Amplify.API.query(request: dealsReq).response;
      final dealsRaw = (dealsRes.data?.items ?? []).whereType<amplify_models.Deals>().toList();
      dealsCount = dealsRaw.where((d) {
        final isCrm = (d.pipeline ?? '').toLowerCase() == 'crm' || (d.pipeline ?? '').toLowerCase() == 'lead';
        if (isCrm && d.is_won != true) return false;
        return true;
      }).length;

      // 4. Bills to Receive (Only pending INVOICES)
      final billsReq = ModelQueries.list(
        amplify_models.Billings.classType,
        where: amplify_models.Billings.TYPE.eq('INVOICE').and(amplify_models.Billings.STATUS.ne('Received')),
        limit: 10000
      );
      final billsResult = await Amplify.API.query(request: billsReq).response;
      final billsItems = billsResult.data?.items ?? [];
      
      double totalAmount = 0;
      for (var row in billsItems) {
        if (row != null) {
          final amtStr = row.amount?.toString() ?? '0';
          final cleanAmt = amtStr.replaceAll(RegExp(r'[^0-9.]'), '');
          totalAmount += double.tryParse(cleanAmt) ?? 0.0;
        }
      }

      // 5. Pending Tasks
      int pendingTasksCount = 0;
      amplify_core.QueryPredicate tasksWhere = amplify_models.Tasks.STATUS.ne('Completed');
      if (!_isAdmin && userId != null) {
        tasksWhere = amplify_models.Tasks.STATUS.ne('Completed').and(amplify_models.Tasks.ASSIGNED_TO.eq(userId));
      }
      final tasksReq = ModelQueries.list(amplify_models.Tasks.classType, where: tasksWhere, limit: 10000);
      final tasksRes = await Amplify.API.query(request: tasksReq).response;
      pendingTasksCount = tasksRes.data?.items.length ?? 0;

      // 6. Pending Checklists
      int pendingChecklistsCount = 0;
      if (userId != null) {
        pendingChecklistsCount = await ChecklistService().getPendingCountForUser(userId);
      }

      // 7. CRM Leads
      int crmCount = 0;
      try {
        final crmReq = ModelQueries.list(
          amplify_models.Deals.classType,
          where: amplify_models.Deals.PIPELINE.eq('CRM')
              .or(amplify_models.Deals.PIPELINE.eq('crm'))
              .or(amplify_models.Deals.PIPELINE.eq('lead'))
              .or(amplify_models.Deals.PIPELINE.eq('Lead')),
          limit: 10000,
        );
        final crmRes = await Amplify.API.query(request: crmReq).response;
        final crmItems = crmRes.data?.items ?? [];
        crmCount = crmItems.where((d) => d != null && d.stage != 'Passed to Work' && d.stage != 'Deal Lose' && d.stage != 'Won' && d.is_won != true).length;
      } catch (e) {
        debugPrint('CRM count error in dashboard: $e');
      }

      if (!mounted) return;
      setState(() {
        _stats = {
          'expiringLicences': licCount,
          'dscExpiry': dscCount,
          'activeDeals': dealsCount,
          'billsToReceive': totalAmount.toInt(),
          'pendingTasks': pendingTasksCount,
          'pendingChecklists': pendingChecklistsCount,
          'crmLeads': crmCount,
          'expiringLicencesDetail': '$licCount expiring soon',
          'dscExpiryDetail': '$dscCount renewal pending',
          'activeDealsDetail': '$dealsCount active deals',
          'billsDetail': '${billsItems.length} total invoices',
          'tasksDetail': '$pendingTasksCount tasks due',
          'crmLeadsDetail': '$crmCount active leads',
        };
        _isLoadingStats = false;
      });
    } catch (e) {
      debugPrint('Dashboard stats error (attempt $retryCount): $e');
      if (retryCount < 3 && mounted) {
        await Future.delayed(const Duration(seconds: 2));
        return _fetchStats(retryCount: retryCount + 1);
      }
      if (mounted) {
        setState(() => _isLoadingStats = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load dashboard data: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  @override
  Widget build(BuildContext context) {
    final bool isWide = MediaQuery.of(context).size.width > 900;
    
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
        
        // If pressed twice within 2 seconds, exit
        if (context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Row(
          children: [
            if (isWide && _selectedIndex != 31) _buildSidebar(),
            Expanded(
              child: Container(
                padding: _selectedIndex == 31 ? EdgeInsets.zero : EdgeInsets.all(isWide ? 32 : 16),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _buildMainBody(isWide),
                ),
              ),
            ),
          ],
        ),),
        drawer: (!isWide && _selectedIndex != 31) ? Drawer(
          backgroundColor: const Color(0xFF13131A),
          child: _buildSidebar(),
        ) : null,
        appBar: (!isWide && _selectedIndex != 31) ? PremiumAppBar(
          title: const Text('Cochin United', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
          actions: const [
            NotificationBell(),
            SizedBox(width: 8),
          ],
        ) : null,
      ),
    );
  }

  Widget _buildMainBody(bool isWide) {
    // Return different views based on sidebar selection
    switch (_selectedIndex) {
      case 0:

        if (_userRole == 'accountant') {
          return AccountantDashboardScreen(
            hideScaffold: true,
            onNavigate: (index) => setState(() {
              _selectedIndex = index;
              _selectedCategory = null;
            }),
          );
        }
        return Column(
          key: const ValueKey('dashboard'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 24),
            if (_selectedCategory == null) ...[
              _buildWelcomeBanner(),
              const SizedBox(height: 24),
            ],
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: _selectedCategory == null 
                  ? _buildGrid() 
                  : _buildDetailList(),
              ),
            ),
          ],
        );
      case 1: return const ServicesScreen();
      case 2: return const BillingScreen();
      case 3: return const ClientManagementScreen();
      case 4: return LicenseDashboardScreen(
        onBack: () => setState(() => _selectedIndex = 0),
      );
      case 5: return const DscManagementScreen();
      case 6: return const WorkManagementScreen();
      case 7: return _buildSettingsPage();
      case 8: return AdminDashboardScreen();
      case 9: return const StaffChatListScreen();
      case 10: return const TaskManagementScreen();
      case 11: return CompanyBillManagementScreen();
      case 12: return const ChecklistScreen();
      case 13: return const WorkManagementScreen(showOnlyVerification: true);
      case 14: return const ReminderCalendarScreen();
      case 15: return const UploadedFilesScreen();
      case 16: return InwardPostScreen(currentUserRole: _userRole, currentUserName: _userName);
      case 17: return const DocumentListScreen(userEmail: 'staff@cochinunited.com');
      case 18: return const VerificationHistoryView();
      case 19: return const TravelLogScreen();
      case 20: return FileAcknowledgementScreen(currentUserRole: _userRole, currentUserName: _userName);
      case 21: return const ClientFilesScreen();
      case 22: return const HelpAndQueriesManagementScreen();
      case 23: return const OfficeDetailsScreen();
      case 24: return const PropertyManagementScreen();
      case 25: return const ContactBookScreen();
      case 29: return const FormatsScreen();
      case 31: return CrmScreen(onBack: () => setState(() => _selectedIndex = 0));
      default: return const Center(child: Text('Page not found'));
    }
  }

  Widget _buildSidebar() {
    return Material(
      color: const Color(0xFF13131A), // Deep dark slate
      child: Container(
        width: 260,
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          ),
        ),
      child: Column(
        children: [
          const SizedBox(height: 40),
          // Logo
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Image.asset(
                  'assets/CUnitedGold.png',
                  height: 40,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Cochin United',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _sidebarItem(0, Icons.grid_view_rounded, 'Dashboard'),
                  _sidebarItem(12, Icons.playlist_add_check_rounded, 'Today\'s Task', badge: _stats['pendingChecklists'] > 0 ? _stats['pendingChecklists'].toString() : null),
                  _sidebarItem(11, Icons.account_balance_wallet_rounded, 'Accounting & Pay'),
                  _sidebarItem(2, Icons.receipt_long_rounded, 'Billing'),
                  _sidebarItem(3, Icons.people_alt_rounded, 'Client Data'),
                  _sidebarItem(31, Icons.hub_rounded, 'CRM', badge: (_stats['crmLeads'] != null && _stats['crmLeads'] > 0) ? _stats['crmLeads'].toString() : null),
                  _sidebarItem(21, Icons.folder_shared_rounded, 'Work File'),

                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Text('MANAGEMENT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white54, letterSpacing: 1.5)),
                  ),
                  _sidebarItem(6, Icons.work_rounded, 'Work Management'),
                  _sidebarItem(13, Icons.rate_review_rounded, 'Verification'),
                  _sidebarItem(10, Icons.task_alt_rounded, 'Deliveries and Pickup'),
                  _sidebarItem(14, Icons.calendar_month_rounded, 'Reminder Calendar'),
                  _sidebarItem(1, Icons.business_center_rounded, 'Our Services'),
                  _sidebarItem(4, Icons.verified_user_rounded, 'Licences'),
                  _sidebarItem(5, Icons.vpn_key_rounded, 'Digital Signature'),
                  
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    child: Divider(height: 1, color: Colors.white10),
                  ),
                  
                  if (_isAdmin)
                    _sidebarItem(8, Icons.admin_panel_settings_rounded, 'Admin Panel'),
                  
                  _sidebarItem(9, Icons.chat_bubble_outline_rounded, 'Internal Chat'),
                  _sidebarItem(15, Icons.table_view_rounded, 'Upload Table'),
                  _sidebarItem(16, Icons.mark_email_unread_rounded, 'Post Register'),
                  _sidebarItem(20, Icons.handshake_rounded, 'File Acknowledgement'),
                  _sidebarItem(22, Icons.help_center_rounded, 'Client Help & Queries'),
                  _sidebarItem(17, Icons.cloud_sync, 'Google Docs Vault'),
                  _sidebarItem(29, Icons.format_list_bulleted_rounded, 'Formats'),
                  _sidebarItem(18, Icons.history_rounded, 'Verification History'),
                  _sidebarItem(19, Icons.directions_car_filled_outlined, 'Travel Logs'),
                  _sidebarItem(23, Icons.business_rounded, 'Office Details'),
                  _sidebarItem(24, Icons.real_estate_agent_rounded, 'Property Management'),
                  _sidebarItem(25, Icons.contacts_rounded, 'Contact Book'),
                  _sidebarItem(7, Icons.settings_rounded, 'Settings'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListTile(
              onTap: () async {
                await AuthService().logout();
                if (mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (context) => const LoginScreen()),
                    (route) => false,
                  );
                }
              },
              leading: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 20),
              title: const Text('Logout', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              hoverColor: Colors.redAccent.withValues(alpha: 0.1),
              visualDensity: VisualDensity.compact,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        radius: 16,
                        backgroundColor: AppTheme.primaryColor,
                        child: Text('A', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_userName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                            const Text('Pro Plan', style: TextStyle(fontSize: 11, color: Colors.white54)),
                          ],
                        ),
                      ),
                      const Spacer(),
                      const Icon(Icons.more_vert, size: 18, color: Colors.white54),
                    ],
                  ),
            ),
          ),
        ],
      ),
    ));
  }

  Widget _sidebarItem(int index, IconData icon, String label, {String? badge}) {
    final isSelected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: () {
          if (index == 8) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => AdminDashboardScreen()),
            ).then((_) => setState(() => _selectedIndex = 0)); // Reset to dashboard when returning
            return;
          }
          setState(() {
            _selectedIndex = index;
            _selectedCategory = null;
          });
          if (MediaQuery.of(context).size.width <= 900) {
            Navigator.pop(context); // Close drawer on mobile
          }
        },
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primaryColor.withValues(alpha: 0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? AppTheme.primaryColor.withValues(alpha: 0.3) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? AppTheme.primaryColor : Colors.white60,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white60,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (badge != null)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final bool isNarrow = MediaQuery.of(context).size.width < 600;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              if (_selectedCategory != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => setState(() => _selectedCategory = null),
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                    foregroundColor: AppTheme.primaryColor,
                  ),
                ),
              if (_selectedCategory != null) const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selectedCategory ?? (isNarrow ? 'Operations' : 'Cochin United Operations'),
                      style: TextStyle(fontSize: isNarrow ? 20 : 28, fontWeight: FontWeight.bold, letterSpacing: -1),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ).animate().fadeIn(duration: 400.ms).slideX(begin: -0.1),
                    if (!isNarrow) Text(
                      _selectedCategory == null 
                        ? 'Daily overview of expiring services and pending actions.'
                        : 'Detailed list of all records for this category.',
                      style: const TextStyle(color: AppTheme.mutedTextColor, fontSize: 13),
                    ).animate().fadeIn(delay: 100.ms, duration: 400.ms),
                  ],
                ),
              ),
            ],
          ),
        ),
        const NotificationBell(),
        const SizedBox(width: 8),
        IconButton(
          onPressed: _fetchStats,
          icon: const Icon(Icons.refresh_rounded, size: 22),
          tooltip: 'Refresh Stats',
          style: IconButton.styleFrom(
            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
            foregroundColor: AppTheme.primaryColor,
            padding: const EdgeInsets.all(12),
          ),
        ),
      ],
    );
  }

  Widget _buildGrid() {
    if (_isLoadingStats) {
      return const Center(child: CircularProgressIndicator());
    }
    final bool isNarrow = MediaQuery.of(context).size.width < 900;
    final bool isMobile = MediaQuery.of(context).size.width < 600;
    
    final mainStats = [
      PremiumStatCard(
        title: 'Expiring Licences',
        value: _stats['expiringLicences'].toString(),
        trend: _stats['expiringLicencesDetail'],
        icon: Icons.verified_user_rounded,
        color: Colors.orange,
        isNarrow: isNarrow,
        onTap: () {
          setState(() {
            _selectedIndex = 4;
            _selectedCategory = null;
          });
        },
      ),
      PremiumStatCard(
        title: 'Signature Expiry',
        value: _stats['dscExpiry'].toString(),
        trend: _stats['dscExpiryDetail'],
        icon: Icons.vpn_key_rounded,
        color: Colors.blue,
        isNarrow: isNarrow,
        onTap: () => setState(() => _selectedCategory = 'Signature Expiry'),
      ),
      PremiumStatCard(
        title: 'Bills to Receive',
        value: '₹${NumberFormat("#,##,###").format(_stats["billsToReceive"])}',
        trend: _stats['billsDetail'],
        icon: Icons.account_balance_wallet_rounded,
        color: Colors.green,
        isNarrow: isNarrow,
        onTap: () => setState(() => _selectedCategory = 'Bills to Receive'),
      ),
    ];

    final actionableStats = [
      PremiumStatCard(
        title: _isAdmin ? 'Work Management' : 'My Works',
        value: _stats['activeDeals'].toString(),
        trend: _stats['activeDealsDetail'] ?? 'Active deals',
        icon: Icons.work_rounded,
        color: Colors.purple,
        isNarrow: isNarrow,
        onTap: () {
          setState(() {
            _selectedIndex = 6;
            _selectedCategory = null;
          });
        },
      ),
      PremiumStatCard(
        title: _isAdmin ? 'All Deliveries and Pickup' : 'My Deliveries and Pickup',
        value: _stats['pendingTasks'].toString(),
        trend: _stats['tasksDetail'] ?? '0 pending',
        icon: Icons.task_alt_rounded,
        color: Colors.teal,
        isNarrow: isNarrow,
        onTap: () {
          setState(() {
            _selectedIndex = 10;
            _selectedCategory = null;
          });
        },
      ),
      PremiumStatCard(
        title: 'Property Management',
        value: 'Manage',
        trend: 'View properties',
        icon: Icons.real_estate_agent_rounded,
        color: Colors.brown,
        isNarrow: isNarrow,
        onTap: () {
          setState(() {
            _selectedIndex = 24;
            _selectedCategory = null;
          });
        },
      ),
      PremiumStatCard(
        title: 'CRM Leads',
        value: (_stats['crmLeads'] != null && _stats['crmLeads'] > 0) ? _stats['crmLeads'].toString() : 'Pipeline',
        trend: _stats['crmLeadsDetail'] ?? 'Active leads & pipeline',
        icon: Icons.hub_rounded,
        color: const Color(0xFF0284C7),
        isNarrow: isNarrow,
        onTap: () {
          setState(() {
            _selectedIndex = 31;
            _selectedCategory = null;
          });
        },
      ),
      PremiumStatCard(
        title: 'Client Data',
        value: 'Manage',
        trend: 'View all clients',
        icon: Icons.people_alt_rounded,
        color: Colors.blueAccent,
        isNarrow: isNarrow,
        onTap: () {
          setState(() {
            _selectedIndex = 3;
            _selectedCategory = null;
          });
        },
      ),
      PremiumStatCard(
        title: 'Contact Book',
        value: 'Directory',
        trend: 'View contacts',
        icon: Icons.contacts_rounded,
        color: Colors.indigo,
        isNarrow: isNarrow,
        onTap: () {
          setState(() {
            _selectedIndex = 25;
            _selectedCategory = null;
          });
        },
      ),
    ];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: isMobile ? 1 : (isNarrow ? 2 : 3),
            mainAxisSpacing: isNarrow ? 12 : 24,
            crossAxisSpacing: isNarrow ? 12 : 24,
            childAspectRatio: isMobile ? 2.5 : (isNarrow ? 1.5 : 2.0),
            children: mainStats.animate(interval: 100.ms).fadeIn(duration: 500.ms).slideY(begin: 0.1),
          ),
          const SizedBox(height: 32),
          const Text('Your Action Items', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
          const SizedBox(height: 16),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: isMobile ? 1 : (isNarrow ? 2 : 2),
            mainAxisSpacing: isNarrow ? 12 : 24,
            crossAxisSpacing: isNarrow ? 12 : 24,
            childAspectRatio: isMobile ? 2.5 : (isNarrow ? 1.6 : 2.2),
            children: actionableStats.animate(interval: 100.ms).fadeIn(duration: 500.ms, delay: 200.ms).slideY(begin: 0.1),
          ),
          const SizedBox(height: 32),
          UpcomingDeadlinesWidget(
            isWide: !isNarrow,
            onItemTap: (item) => _showQuickActionMenu(context, item),
          ),
          const SizedBox(height: 24),
          UpcomingRemindersWidget(
            isWide: !isNarrow,
            onNavigateToCalendar: () => setState(() => _selectedIndex = 14),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // PremiumStatCard is now used instead of _buildStatCard

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
                  'statusColor': Colors.blue,
                  'trailing': map['dsc_expiry_date'] != null ? DateFormat('dd MMM yyyy').format(DateTime.parse(map['dsc_expiry_date'].toString())) : '-',
                };
              }).toList(),
            );
          case 'Client Birthdays':
            final today = DateTime.now();
            final todayStr = DateFormat('dd.MM').format(today);
            final bdays = data.where((map) {
              final dob = map['dob'] as String? ?? '';
              return dob.startsWith(todayStr);
            }).toList();

            return _buildGenericList(
              headers: ['Client Name', 'DOB', 'Contact'],
              items: bdays.map((map) {
                return {
                  'title': map['name'] ?? 'Unknown',
                  'sub': 'Born: ${map['dob']}',
                  'status': 'Today',
                  'statusColor': Colors.pink,
                  'trailing': map['phone'] ?? '-',
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
                return {
                  'title': map['client_name'] ?? 'Unknown',
                  'sub': 'Inv: ${map['invoice_no'] ?? '-'}',
                  'status': 'Unpaid',
                  'statusColor': Colors.green,
                  'trailing': map['amount'] ?? '-',
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
          'client_name': l.client_id, // We might not have client_name easily without relational fetch, but let's use client_id or check if model has client_name
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
        list.sort((a, b) => (b.updatedAt?.getDateTimeInUtc() ?? DateTime.now()).compareTo(a.updatedAt?.getDateTimeInUtc() ?? DateTime.now()));
        return list.take(20).map((l) => l.toJson()).toList();
        
      case 'Bills to Receive':
        final req = ModelQueries.list(
          amplify_models.Billings.classType,
          where: amplify_models.Billings.TYPE.eq('INVOICE').and(amplify_models.Billings.STATUS.ne('Received')),
         limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final list = (res.data?.items ?? []).whereType<amplify_models.Billings>().toList() ?? [];
        list.sort((a, b) => (b.id).compareTo(a.id));
        return list.take(20).map((l) => l.toJson()).toList();
        
      default:
        throw Exception('Invalid category');
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
    } else if (_selectedCategory == 'Signature Expiry') categoryIcon = Icons.vpn_key_rounded;
    else if (_selectedCategory == 'Bills to Receive') categoryIcon = Icons.account_balance_wallet_rounded;
    else if (_selectedCategory == 'Work Management') categoryIcon = Icons.work_rounded;

    return Column(
      children: [
        // Search Bar
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
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4)),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
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
                                    const SizedBox(height: 4),
                                    Text(item['trailing'], style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                                  ],
                                ),
                                onTap: () {
                                  // Quick action menu or detail navigation
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
        final billingMap = item['data'] ?? item;

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
              if (_selectedCategory == 'Bills to Receive') ...[
                _actionTile(Icons.check_circle_outline_rounded, 'Mark as Paid', 'Update payment status', Colors.green, onTap: () {
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
                      _fetchStats();
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
                _actionTile(Icons.phone_rounded, 'Call Client', 'Direct contact via phone', Colors.green),
                _actionTile(Icons.message_rounded, 'WhatsApp', 'Send message to client', Colors.green),
                _actionTile(Icons.history_rounded, 'View History', 'Previous renewals and logs', Colors.blue),
                _actionTile(Icons.cancel_outlined, 'Mark as Not Interested', 'Client declined renewal', Colors.red, onTap: () {
                  Navigator.pop(context);
                  _showReasonDialog(context);
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
                activeThumbColor: Colors.green,
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
                Text('Remaining Balance: ₹${NumberToWords.formatIndianCurrency(newBalance).replaceAll('/-', '')}', style: TextStyle(color: newBalance > 0 ? Colors.orange.shade700 : Colors.green.shade700, fontWeight: FontWeight.bold)),
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

        final reqBill = amplify_models.Billings(id: b.id.toString(), status: isPaid ? 'Received' : 'Pending', data: jsonEncode(d));
        await BackupAwareApi().update(reqBill);
        
        if (b.clientName != null && b.clientName!.isNotEmpty) {
           final q = ModelQueries.list(amplify_models.Clients.classType, where: amplify_models.Clients.NAME.eq(b.clientName!), limit: 10000);
           final r = await amplify_core.Amplify.API.query(request: q).response;
           if (r.data?.items.isNotEmpty == true) {
             final clientToUpdate = r.data!.items.first!.copyWith(balance_due: d['balance_due'].toString());
             await BackupAwareApi().update(clientToUpdate);
           }
        }

        _fetchStats();
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
        await BackupAwareApi().deleteById(amplify_models.Billings.classType, amplify_models.BillingsModelIdentifier(id: b.id.toString()));
        _fetchStats();
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
        _fetchStats();
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

  void _showReasonDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reason for Not Interested'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Please provide a reason why the client is not interested in renewing.',
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

  Widget _buildWelcomeBanner() {
    final hour = DateTime.now().hour;
    String greeting = 'Good Morning';
    if (hour >= 12 && hour < 17) {
      greeting = 'Good Afternoon';
    } else if (hour >= 17) greeting = 'Good Evening';

    final bool isNarrow = MediaQuery.of(context).size.width < 600;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isNarrow ? 24 : 40),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF13131A), Color(0xFF1E1E2F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Subtle glowing orb in background
          Positioned(
            right: -20,
            bottom: -20,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [AppTheme.primaryColor.withValues(alpha: 0.3), Colors.transparent],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$greeting, $_userName!',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'You have ${_stats['pendingTasks']} tasks due and ${_stats['expiringLicences']} licenses expiring soon.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.bolt_rounded, color: AppTheme.primaryColor, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          'System Health: Excellent',
                          style: TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (true) ...[
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ElevatedButton.icon(
                              onPressed: _isAttendanceLoading ? null : _toggleAttendance,
                              icon: _isAttendanceLoading
                                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                  : Icon(_isCheckedIn ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded, color: Colors.white, size: 20),
                              label: Text(_isCheckedIn ? 'Check Out (In since $_checkInTimeStr)' : 'Check In'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _isCheckedIn ? Colors.redAccent : Colors.green,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                                elevation: 4,
                                shadowColor: (_isCheckedIn ? Colors.redAccent : Colors.green).withValues(alpha: 0.5),
                              ),
                            ),
                            ElevatedButton.icon(
                              onPressed: _showTravelLogDialog,
                              icon: const Icon(Icons.directions_car_rounded, color: Colors.white, size: 20),
                              label: const Text('Travel Log'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2563EB),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                                elevation: 4,
                                shadowColor: const Color(0xFF2563EB).withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: Text(
                            'Total Time Today: ${_dailyTotalMinutes ~/ 60}h ${_dailyTotalMinutes % 60}m',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 600.ms).slideY(begin: 0.05, curve: Curves.easeOutCubic);
  }

  Widget _buildSettingsPage() {
    return Column(
      key: const ValueKey('settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Settings',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: -1),
        ),
        const SizedBox(height: 32),
        Expanded(
          child: ListView(
            children: [
              _buildSettingsSection('Account Profile', [
                _settingsTile(
                  Icons.person_outline_rounded, 
                  'Personal Information', 
                  'View your profile details',
                  onTap: () => _showProfileDialog(context),
                ),
                _settingsTile(
                  Icons.shield_outlined, 
                  'Security', 
                  'Update your password', 
                  onTap: () => _showChangePasswordDialog(context)
                ),
              ]),
              const SizedBox(height: 24),
              _buildSettingsSection('Branding & Assets', [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Column(
                        children: [
                          const Text('Logo', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                          const SizedBox(height: 8),
                          Image.asset('assets/CUnitedGold.png', height: 60),
                        ],
                      ),
                      const SizedBox(width: 32),
                      Column(
                        children: [
                          const Text('Signature', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                          const SizedBox(height: 8),
                          Image.asset('assets/sign.png', height: 60),
                        ],
                      ),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 24),
              _buildSettingsSection('Account Actions', [
                _settingsTile(
                  Icons.logout_rounded, 
                  'Sign Out', 
                  'Logout from your account',
                  onTap: () async {
                    await AuthService().logout();
                    if (mounted) {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (context) => const LoginScreen()),
                      );
                    }
                  },
                ),
              ]),
              const SizedBox(height: 32),
              const Center(
                child: Text(
                  'Cochin United v1.0.4 (Build 2024.1)',
                  style: TextStyle(color: AppTheme.mutedTextColor, fontSize: 12),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 12),
          child: Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
          ),
        ),
        Card(
          child: Column(
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _settingsTile(IconData icon, String title, String subtitle, {VoidCallback? onTap}) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppTheme.primaryColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: AppTheme.primaryColor, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: AppTheme.mutedTextColor)),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.mutedTextColor),
      onTap: onTap,
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
      final rObj = await amplify_core.Amplify.API.query(request: ModelQueries.get(amplify_models.Users.classType, amplify_models.UsersModelIdentifier(id: userId.toString()))).response;
      final res = rObj.data != null ? {'name': rObj.data!.name, 'email': rObj.data!.email, 'phone': ''} : null;
      
      if (!mounted) return;
      Navigator.pop(context); // Remove loader

      if (res == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to load profile')));
        return;
      }

      final user = res;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Personal Information', style: TextStyle(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _profileItem(Icons.person_rounded, 'Full Name', user['name'] ?? '-'),
              _profileItem(Icons.alternate_email_rounded, 'Username', user['username'] ?? '-'),
              _profileItem(Icons.badge_rounded, 'Role', user['role']?.toString().toUpperCase() ?? '-'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
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

  void _showChangePasswordDialog(BuildContext context) {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Change Password', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: currentController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Current Password', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: newController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New Password', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Confirm New Password', border: OutlineInputBorder()),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: isLoading ? null : () async {
                  if (newController.text.trim().isEmpty || currentController.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all fields')));
                    return;
                  }
                  if (newController.text != confirmController.text) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('New passwords do not match')));
                    return;
                  }
                  setState(() => isLoading = true);
                  try {
                    final prefs = await SharedPreferences.getInstance();
                    final myId = prefs.getInt('current_user_id');
                    
                    // Verify current password
                    final uReq = await amplify_core.Amplify.API.query(request: ModelQueries.get(amplify_models.Users.classType, amplify_models.UsersModelIdentifier(id: myId.toString()))).response;
                    final userData = uReq.data != null ? {'password': uReq.data!.password} : null;
                    if (userData == null || userData['password'].toString() != currentController.text) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Incorrect current password')));
                      setState(() => isLoading = false);
                      return;
                    }
                    
                    // Update password
                    await BackupAwareApi().update(amplify_models.Users(id: myId.toString(), password: newController.text));
                    
                    if (mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password updated successfully')));
                    }
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                  }
                  setState(() => isLoading = false);
                },
                child: isLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save Changes'),
              ),
            ],
          );
        }
      ),
    );
  }

  Widget _buildPlaceholderPage(String title, IconData icon) {
    return Column(
      key: ValueKey(title),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: -1),
        ),
        const SizedBox(height: 32),
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 80, color: AppTheme.primaryColor.withValues(alpha: 0.2)),
                const SizedBox(height: 24),
                Text(
                  '$title module is coming soon.',
                  style: const TextStyle(color: AppTheme.mutedTextColor, fontSize: 18),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
