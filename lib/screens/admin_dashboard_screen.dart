import 'package:amplify_api/amplify_api.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme.dart';
import 'login_screen.dart';
import 'client_files_screen.dart';
import 'service_management_screen.dart';
import 'staff_management_screen.dart';
import 'monitor_screen.dart';
import '../services/notification_service.dart';
import '../services/supabase_backup_service.dart';
import '../widgets/notification_bell.dart';
import '../widgets/premium_app_bar.dart';
import 'file_acknowledgement_screen.dart';
import 'package:intl/intl.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart';
import '../services/auth_service.dart';
import 'checklist_screen.dart';
import 'help_and_queries_management_screen.dart';
import 'reminder_calendar_screen.dart';
import 'sop_screen.dart';
import 'contact_book_screen.dart';
import '../widgets/upcoming_reminders_widget.dart';
import 'billing_screen.dart';
import '../services/checklist_service.dart';

import 'travel_log_screen.dart';
import 'document_list_screen.dart';
import 'verification_history_view.dart';
import 'property_management_screen.dart';
import 'company_bill_management_screen.dart';
import 'office_details_screen.dart';
import '../utils/number_to_words.dart';
import '../services/checklist_service.dart';
import '../widgets/startup_task_popup.dart';
import '../services/auto_backup_service.dart';
import 'formats_screen.dart';
import 'attendance_screen.dart';
import 'crm_screen.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _selectedIndex = 0;
  bool _isLoading = true;
  Map<String, dynamic> _adminStats = {
    'totalClients': '0',
    'activeLicenses': '0',
    'monthlyRevenue': '₹0',
  };
  String? _errorMessage;
  List<Map<String, dynamic>> _recentActivity = [];
  List<Map<String, dynamic>> _globalBillings = [];
  @override
  void initState() {
    super.initState();
    _fetchAdminStats();
    
    // Start realtime notifications
    AuthService().getUserId().then((id) {
      if (id != null) {
        NotificationService().startRealtimeListener(id);
      }
    });
    
    NotificationService().checkAndSendFrequentReminders();
    _checkTodayChecklists();

    // Silent auto-backup (runs once per 24 hours)
    AutoBackupService().runIfNeeded();

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
        content: Text("You have $count pending deliveries and pickup in your checklist for today. Would you like to view them now?"),
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

  Future<void> _fetchAdminStats() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final req1 = ModelQueries.list(Clients.classType, limit: 10000);
      final res1 = await Amplify.API.query(request: req1).response;
      final clientsCountRes = res1.data?.items ?? [];
      
      final req2 = ModelQueries.list(ClientLicenses.classType, where: ClientLicenses.STATUS.eq('Active'), limit: 10000);
      final res2 = await Amplify.API.query(request: req2).response;
      final licensesCountRes = res2.data?.items ?? [];
      
      final req3 = ModelQueries.list(Billings.classType, limit: 10000);
      final res3 = await Amplify.API.query(request: req3).response;
      var billingsList = (res3.data?.items ?? []).where((e) => e != null).cast<Billings>().toList();
      billingsList.sort((a, b) => (b.createdAt?.toString() ?? '').compareTo(a.createdAt?.toString() ?? ''));
      
      final now = DateTime.now();
      double totalRevenue = 0;
      for (var row in billingsList.where((b) => b.status == 'Received')) {
        DateTime? recordDate;
        try {
           if (row.data != null) {
              final d = jsonDecode(row.data!);
              if (d['payment_date'] != null) recordDate = DateTime.parse(d['payment_date']);
           }
        } catch (_) {}
        recordDate ??= row.createdAt?.getDateTimeInUtc();
        
        if (recordDate != null && recordDate.month == now.month && recordDate.year == now.year) {
          final amtStr = row.amount?.toString() ?? '0';
          final cleanAmt = amtStr.replaceAll(RegExp(r'[^0-9.]'), '');
          totalRevenue += double.tryParse(cleanAmt) ?? 0.0;
        }
      }

      final reqLogs = ModelQueries.list(ActivityLogs.classType, limit: 10000);
      final resLogs = await Amplify.API.query(request: reqLogs).response;
      final fetchedLogs = (resLogs.data?.items ?? []).whereType<ActivityLogs>().toList();
      
      fetchedLogs.sort((a, b) {
        final aTime = a.createdAt?.getDateTimeInUtc() ?? (a.created_at != null ? DateTime.tryParse(a.created_at!) : null) ?? DateTime(2000);
        final bTime = b.createdAt?.getDateTimeInUtc() ?? (b.created_at != null ? DateTime.tryParse(b.created_at!) : null) ?? DateTime(2000);
        return bTime.compareTo(aTime);
      });
      final recentLogs = fetchedLogs.take(5).toList();

      Map<int, String> nameMap = {};
      try {
        final map = await SupabaseBackupService().getUsernameToIdMap();
        map.forEach((username, id) {
          nameMap[id] = username;
        });
      } catch (_) {}

      final billingRes = billingsList.take(50).toList();

      setState(() {
        _adminStats = {
          'totalClients': clientsCountRes.length.toString(),
          'activeLicenses': licensesCountRes.length.toString(),
          'monthlyRevenue': '₹${NumberFormat('#,##,###').format(totalRevenue)}',
        };
        _recentActivity = recentLogs.map((r) {
          final userName = nameMap[r.user_id] ?? 'System';
          final displayTime = r.createdAt?.getDateTimeInUtc().toLocal().toIso8601String() ?? r.created_at;
          return {
            'action': r.action ?? '',
            'target_type': r.target_type ?? '',
            'details': r.details ?? '',
            'created_at': displayTime,
            'user_name': userName
          };
        }).toList();
        _globalBillings = billingRes.map((b) => {
            'id': b.id,
            'invoice_no': b.invoice_no,
            'client_name': b.client_name,
            'type': b.type,
            'amount': b.amount,
            'status': b.status,
            'created_at': b.createdAt?.toString(),
        }).toList();
        _errorMessage = null;
      });
    } catch (e) {
      debugPrint('Admin stats error: $e');
      if (mounted) {
        setState(() => _errorMessage = e.toString());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load stats: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _runBackup() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Downloading backup...'),
          ],
        ),
      ),
    );

    try {
      final Map<String, List<Map<String, dynamic>>> backupData = {};

      // Fetch all tables
      final tables = <String, dynamic>{
        'Users': Users.classType,
        'Clients': Clients.classType,
        'Deals': Deals.classType,
        'Billings': Billings.classType,
        'Tasks': Tasks.classType,
        'ActivityLogs': ActivityLogs.classType,
        'UserSessions': UserSessions.classType,
        'Messages': Messages.classType,
        'StaffAttendance': StaffAttendance.classType,
        'ClientDocuments': ClientDocuments.classType,
        'InwardPosts': InwardPosts.classType,
        'Notifications': Notifications.classType,
      };

      for (var entry in tables.entries) {
        try {
          final req = ModelQueries.list(entry.value, limit: 10000);
          final res = await Amplify.API.query(request: req).response;
          final items = res.data?.items ?? [];
          backupData[entry.key] = items
              .where((item) => item != null)
              .map((item) => item!.toJson())
              .toList();
        } catch (e) {
          debugPrint('Backup error for ${entry.key}: $e');
          backupData[entry.key] = [];
        }
      }

      final jsonString = const JsonEncoder.withIndent('  ').convert({
        'backup_date': DateTime.now().toIso8601String(),
        'app_version': 'CUC Main Version',
        'tables': backupData,
      });

      if (mounted) Navigator.pop(context);

      // Save to app documents directory
      final dir = await getApplicationDocumentsDirectory();
      final fileName = 'CUC_Backup_${DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now())}.json';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(jsonString);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup saved to: ${file.path}'), backgroundColor: Colors.green, duration: const Duration(seconds: 5)),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _restoreBackup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restore from Backup'),
        content: const Text('WARNING: This will overwrite existing data with the backup data. Are you sure you want to continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Restore', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.single.path == null) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Restoring backup...'),
            ],
          ),
        ),
      );

      final file = File(result.files.single.path!);
      final jsonString = await file.readAsString();
      final data = json.decode(jsonString);

      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backup file loaded: ${data['backup_date'] ?? 'Unknown date'}. Restore requires AWS Console for safety.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isWide = constraints.maxWidth > 900;
        final bool isMobile = constraints.maxWidth < 600;
        
        return PopScope(
          canPop: _selectedIndex == 0,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            if (_selectedIndex != 0) {
              setState(() => _selectedIndex = 0);
            }
          },
          child: Scaffold(
            drawer: (!isWide && _selectedIndex != 31) ? Drawer(
              backgroundColor: const Color(0xFF13131A),
              child: _buildSidebarContent(isWide),
            ) : null,
            appBar: (!isWide && _selectedIndex != 31) ? PremiumAppBar(
              title: Image.asset('assets/CUnitedGold.png', height: 30),
              centerTitle: true,
            ) : null,
            body: SafeArea(
              child: Row(
                children: [
                // Admin Sidebar (Desktop Only)
                if (isWide && _selectedIndex != 31) _buildSidebar(isWide),
                
                // Main Content
                Expanded(
                  child: Container(
                    padding: _selectedIndex == 31 ? EdgeInsets.zero : EdgeInsets.all(isWide ? 32 : 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_selectedIndex != 31) ...[
                          _buildHeader(isWide),
                          SizedBox(height: isWide ? 32 : 16),
                        ],
                        Expanded(
                          child: _isLoading 
                            ? const Center(child: CircularProgressIndicator())
                            : AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                child: _buildMainAdminContent(isWide, isMobile),
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
      }
    );
  }

  Widget _buildSidebar(bool isWide) {
    return Material(
      color: AppTheme.surfaceColor,
      child: Container(
        width: 260,
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: Colors.black.withValues(alpha: 0.05)),
          ),
        ),
        child: _buildSidebarContent(isWide),
      ),
    );
  }

  Widget _buildSidebarContent(bool isWide) {
    return Column(
      children: [
        const SizedBox(height: 40),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Image.asset('assets/CUnitedGold.png', height: 40, fit: BoxFit.contain),
              const SizedBox(width: 12),
              const Text(
                'IT SuperAdmin',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                _sidebarItem(0, Icons.dashboard_outlined, 'Command Overview', isWide),
                _sidebarItem(12, Icons.playlist_add_check_rounded, 'Today\'s Checklist', isWide),
                _sidebarItem(17, Icons.calendar_month_rounded, 'Reminder Calendar', isWide),
                _sidebarItem(11, Icons.account_balance_wallet_rounded, 'Accounting & Pay', isWide),
                _sidebarItem(28, Icons.receipt_long_rounded, 'Billing / Invoices', isWide),
                _sidebarItem(1, Icons.security_rounded, 'Security & Audit', isWide),
                _sidebarItem(24, Icons.folder_shared_rounded, 'Work File', isWide),
                _sidebarItem(31, Icons.hub_rounded, 'CRM Leads', isWide),
                _sidebarItem(25, Icons.contacts_rounded, 'Contact Book', isWide),
                _sidebarItem(2, Icons.people_outline_rounded, 'Staff Management', isWide),

                _sidebarItem(8, Icons.directions_car_filled_outlined, 'Travel Logs', isWide),
                _sidebarItem(3, Icons.layers_outlined, 'Service Checklist', isWide),
                _sidebarItem(23, Icons.menu_book_rounded, 'SOP', isWide),
                _sidebarItem(4, Icons.storage_rounded, 'System Maintenance', isWide),
                _sidebarItem(5, Icons.health_and_safety_outlined, 'System Health', isWide),
                _sidebarItem(26, Icons.help_center_rounded, 'Client Help & Queries', isWide),
                _sidebarItem(19, Icons.cloud_sync, 'Google Docs Vault', isWide),
                _sidebarItem(29, Icons.format_list_bulleted_rounded, 'Formats', isWide),
                _sidebarItem(22, Icons.handshake_rounded, 'File Acknowledgement', isWide),
                _sidebarItem(20, Icons.history_rounded, 'Verification History', isWide),
                _sidebarItem(21, Icons.real_estate_agent_rounded, 'Property Management', isWide),
                _sidebarItem(27, Icons.business_rounded, 'Office Details', isWide),
              ],
            ),
          ),
        ),
        _sidebarItem(7, Icons.logout_rounded, 'Exit Admin', isWide),
        const SizedBox(height: 24),
        _sidebarItem(30, Icons.access_time_rounded, 'Attendance', isWide),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _sidebarItem(int index, IconData icon, String label, bool isWide) {
    final isSelected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: () async {
          if (!isWide) Navigator.pop(context);
          if (index == 7) {
            // Logout logic
            await AuthService().logout();
            if (mounted) {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => const LoginScreen()),
                (route) => false,
              );
            }
          } else {
            setState(() => _selectedIndex = index);
          }
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primaryColor.withValues(alpha: 0.05) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: isSelected ? AppTheme.primaryColor : AppTheme.mutedTextColor),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? AppTheme.primaryColor : AppTheme.mutedTextColor,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
                  Text(
                    'System Governance',
                    style: TextStyle(fontSize: isWide ? 28 : 20, fontWeight: FontWeight.bold, letterSpacing: -1),
                  ).animate().fadeIn(duration: 400.ms).slideX(begin: -0.1),
                  if (isWide) const Text(
                    'Application monitoring, audit transparency, and system maintenance.',
                    style: TextStyle(color: AppTheme.mutedTextColor),
                  ).animate().fadeIn(delay: 100.ms),
                ],
              ),
            ),
            if (isWide) Row(
              children: [
                _headerBadge('System Health: Excellent', Colors.green),
                const SizedBox(width: 16),
                const NotificationBell(),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: _fetchAdminStats,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Refresh'),
                ),
              ],
            ) else Row(
              children: [
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

  Widget _buildMainAdminContent(bool isWide, bool isMobile) {
    switch (_selectedIndex) {
      case 0: return _buildAdminView(isWide, isMobile);
      case 1: return const MonitorScreen();
      case 2: return const StaffManagementScreen();
      case 3: return const ServiceManagementScreen();
      case 4: return _buildBackupView();
      case 5: return _buildHealthView(isWide, isMobile);

      case 8: return const TravelLogScreen();
      case 12: return const ChecklistScreen();
      case 17: return const ReminderCalendarScreen();
      case 11: return CompanyBillManagementScreen();
      case 19: return const DocumentListScreen(userEmail: 'admin@cochinunited.com');
      case 20: return const VerificationHistoryView();
      case 21: return const PropertyManagementScreen();
      case 22: return const FileAcknowledgementScreen(currentUserRole: 'admin', currentUserName: 'Admin');
      case 24: return const ClientFilesScreen();
      case 25: return const ContactBookScreen();
      case 26: return const HelpAndQueriesManagementScreen();
      case 23: return const SopScreen();
      case 27: return const OfficeDetailsScreen();
      case 28: return const BillingScreen();
      case 29: return const FormatsScreen();
      case 30: return const AttendanceScreen();
      case 31: return CrmScreen(onBack: () => setState(() => _selectedIndex = 0));
      default: return _buildPlaceholderView('Coming Soon');
    }
  }

  Widget _buildHealthView(bool isWide, bool isMobile) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _fetchSystemMetrics(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final metrics = snapshot.data!;
        final stats = metrics['tables'] as Map<String, int>;
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('System Health Status', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Live monitoring of database synchronization and storage metrics.', style: TextStyle(color: AppTheme.mutedTextColor)),
            const SizedBox(height: 32),
            
            Expanded(
              child: GridView.count(
                crossAxisCount: isWide ? 4 : (isMobile ? 1 : 2),
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: isMobile ? 2.5 : 1.5,
                children: [
                  _healthCard('DB Sync', metrics['syncStatus'], Icons.cloud_done_rounded, metrics['syncStatus'] == 'Healthy' ? Colors.green : Colors.red),
                  _healthCard('Connection', metrics['connection'], Icons.lan_rounded, Colors.blue),
                  _healthCard('Response', '${metrics['ping']}ms', Icons.speed_rounded, metrics['ping'] < 300 ? Colors.orange : Colors.red),
                  _healthCard('Last Backup', metrics['lastBackup'], Icons.history_rounded, Colors.purple),
                ],
              ),
            ),
            
            const Text('Database Record Distribution', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Expanded(
              flex: 2,
              child: Card(
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: stats.entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.table_chart_outlined, size: 18, color: AppTheme.primaryColor.withValues(alpha: 0.5)),
                        const SizedBox(width: 16),
                        Expanded(child: Text(e.key.toUpperCase().replaceAll('_', ' '), style: const TextStyle(fontWeight: FontWeight.w600))),
                        Text('${e.value} records', style: const TextStyle(color: AppTheme.mutedTextColor, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 24),
                        SizedBox(
                          width: 100,
                          child: LinearProgressIndicator(
                            value: e.value / 1000,
                            backgroundColor: Colors.grey.shade100,
                            color: AppTheme.primaryColor.withValues(alpha: 0.3),
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  )).toList(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<Map<String, dynamic>> _fetchSystemMetrics() async {
    final Map<String, int> stats = {};
    int ping = 0;
    String syncStatus = 'Offline';
    
    try {
      final sw = Stopwatch()..start();
      await Amplify.API.query(request: ModelQueries.list(Users.classType, limit: 1)).response;
      sw.stop();
      ping = sw.elapsedMilliseconds;
      syncStatus = 'Healthy';
      
      stats['clients'] = (await Amplify.API.query(request: ModelQueries.list(Clients.classType, limit: 10000)).response).data?.items.length ?? 0;
      stats['billings'] = (await Amplify.API.query(request: ModelQueries.list(Billings.classType, limit: 10000)).response).data?.items.length ?? 0;
      stats['deals'] = (await Amplify.API.query(request: ModelQueries.list(Deals.classType, limit: 10000)).response).data?.items.length ?? 0;
      stats['tasks'] = (await Amplify.API.query(request: ModelQueries.list(Tasks.classType, limit: 10000)).response).data?.items.length ?? 0;
      stats['activity_logs'] = (await Amplify.API.query(request: ModelQueries.list(ActivityLogs.classType, limit: 10000)).response).data?.items.length ?? 0;
      stats['dsc_records'] = (await Amplify.API.query(request: ModelQueries.list(DscRecords.classType, limit: 10000)).response).data?.items.length ?? 0;
      stats['user_sessions'] = (await Amplify.API.query(request: ModelQueries.list(UserSessions.classType, limit: 10000)).response).data?.items.length ?? 0;
    } catch (e) {
      syncStatus = 'Error';
    }

    String lastBackup = 'Never';
    try {
      final directory = await getApplicationDocumentsDirectory();
      final backupFiles = directory.listSync().where((f) => f.path.contains('CUC_SystemBackup_') || f.path.contains('CUC_Backup_')).toList();
      if (backupFiles.isNotEmpty) {
        backupFiles.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
        final lastModified = backupFiles.first.statSync().modified;
        final diff = DateTime.now().difference(lastModified);
        if (diff.inDays > 0) {
          lastBackup = '${diff.inDays}d ago';
        } else if (diff.inHours > 0) {
          lastBackup = '${diff.inHours}h ago';
        } else if (diff.inMinutes > 0) {
          lastBackup = '${diff.inMinutes}m ago';
        } else {
          lastBackup = 'Just now';
        }
      }
    } catch (e) {
      // ignore
    }

    return {
      'tables': stats,
      'ping': ping,
      'syncStatus': syncStatus,
      'connection': syncStatus == 'Healthy' ? 'Active' : 'Disconnected',
      'lastBackup': lastBackup,
    };
  }

  Widget _healthCard(String title, String val, IconData icon, Color color) {
    return Card(
      elevation: 0,
      color: color.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: color.withValues(alpha: 0.1))),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontSize: 12, color: AppTheme.mutedTextColor)),
            Text(val, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildBackupView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.storage_rounded, size: 80, color: AppTheme.primaryColor),
          const SizedBox(height: 24),
          const Text('Database Maintenance', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          const Text('Manage system backups and data integrity.', style: TextStyle(color: AppTheme.mutedTextColor)),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _runBackup,
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download Full Backup'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Starting S3 file sync in background. Check console for progress.')),
              );
              SupabaseBackupService().syncMissingFiles();
            },
            icon: const Icon(Icons.cloud_sync_rounded),
            label: const Text('Sync S3 Files to Supabase'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: _restoreBackup,
            icon: const Icon(Icons.upload_rounded),
            label: const Text('Restore from Backup'),
          ),
        ],
      ),
    );
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



  Widget _buildAdminView(bool isWide, bool isMobile) {
    return SingleChildScrollView(
      child: Column(
        children: [
          // System Banner
          _buildSystemBanner(isWide),
          const SizedBox(height: 32),
          
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: isWide ? 4 : (isMobile ? 1 : 2),
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: isMobile ? 3.0 : 1.5,
            children: [
              _buildStatCard('Total Clients', _adminStats['totalClients'], '+12%', Icons.people_rounded, Colors.blue, isWide, isMobile),
              _buildStatCard('Active Licenses', _adminStats['activeLicenses'], '+5%', Icons.verified_user_rounded, Colors.purple, isWide, isMobile),
              _buildStatCard('Total Revenue', _adminStats['monthlyRevenue'], '+24%', Icons.account_balance_wallet_rounded, Colors.green, isWide, isMobile),
              _buildStatCard('System Alerts', _adminStats['systemAlerts'], 'Critical', Icons.warning_rounded, Colors.red, isWide, isMobile),
            ].animate(interval: 100.ms).fadeIn().slideY(begin: 0.1),
          ),
          const SizedBox(height: 32),
          // Reminders and Recent Activity
          if (isWide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
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
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: _buildRecentActivityCard(isWide),
                ),
              ],
            )
          else
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
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
                const Text('Recent System Activity', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                TextButton(
                  onPressed: () => setState(() => _selectedIndex = 1),
                  child: const Text('View All Logs', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _recentActivity.isEmpty 
              ? const Center(child: Padding(padding: EdgeInsets.all(40), child: Text('No recent activity', style: TextStyle(color: AppTheme.mutedTextColor))))
              : Column(
                  children: _recentActivity.map((log) {
                    final userName = log['user_name'] ?? 'System';
                    DateTime? parsedDate;
                    if (log['created_at'] != null) {
                      try {
                        parsedDate = DateTime.parse(log['created_at'].toString()).toLocal();
                      } catch (_) {}
                    }
                    final date = parsedDate != null ? DateFormat('hh:mm a • dd MMM').format(parsedDate) : '-';
                    
                    Color actionColor = AppTheme.primaryColor;
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
                        child: Material(
                          color: Colors.transparent,
                          child: Container(
                            decoration: BoxDecoration(border: Border(left: BorderSide(color: actionColor, width: 4))),
                            child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            leading: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(color: actionColor.withAlpha(25), borderRadius: BorderRadius.circular(8)),
                              child: Icon(Icons.info_outline_rounded, color: actionColor, size: 20),
                            ),
                            title: Text('$userName • ${log['action']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text('${log['details']} \n$date', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(color: Colors.grey.shade50, shape: BoxShape.circle),
                              child: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.grey, size: 12),
                            ),
                            onTap: () {
                              setState(() => _selectedIndex = 1);
                            },
                          ),
                        ),
                        ),
                      ),
                    ).animate().fadeIn(duration: 400.ms).slideX(begin: 0.1);
                  }).toList(),
                ),
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
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: isWide
                      ? Row(
                          children: [
                            Expanded(flex: 2, child: Text(b['invoice_no'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13), overflow: TextOverflow.ellipsis)),
                            Expanded(flex: 3, child: Text(b['client_name'] ?? '-', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                            Expanded(flex: 2, child: Text(b['type'] ?? 'INVOICE', style: const TextStyle(fontSize: 12))),
                            Expanded(flex: 2, child: Text(b['amount'] ?? '0/-', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: isPaid ? Colors.green : Colors.black))),
                            Expanded(
                              flex: 2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(color: (isPaid ? Colors.green : Colors.orange).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                                child: Text(isPaid ? 'PAID' : 'PENDING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isPaid ? Colors.green : Colors.orange), textAlign: TextAlign.center),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(b['invoice_no'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 2),
                            Text(b['client_name'] ?? '-', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(b['amount'] ?? '0/-', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: isPaid ? Colors.green : Colors.black)),
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
    final logsRes = await Amplify.API.query(request: ModelQueries.list(ActivityLogs.classType, limit: 10000)).response;
    final logsList = logsRes.data?.items.where((e) => e != null).cast<ActivityLogs>().toList() ?? [];
    logsList.sort((a, b) => (b.createdAt?.toString() ?? '').compareTo(a.createdAt?.toString() ?? ''));

    final usersRes = await Amplify.API.query(request: ModelQueries.list(Users.classType, limit: 10000)).response;
    final usersList = usersRes.data?.items.where((e) => e != null).cast<Users>().toList() ?? [];
    final userMap = {for (var u in usersList) u.id.toString(): u.name ?? 'Unknown'};

    return logsList.map((log) => {
      'user_id': log.user_id,
      'user_name': userMap[log.user_id?.toString()] ?? log.user_id?.toString() ?? 'Unknown',
      'action': log.action,
      'details': log.details,
      'created_at': log.createdAt?.toString() ?? DateTime.now().toIso8601String(),
    }).toList();
  }

  Widget _buildAuditLogView(bool isWide) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _fetchAuditLogs(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        var logsList = snapshot.data ?? [];
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
                  final userName = log['user_name'] as String;
                  final dateStr = log['created_at'] as String;
                  final date = DateTime.parse(dateStr).toLocal();
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
                            child: Text(log['action']?.toString() ?? '-', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.primaryColor), textAlign: TextAlign.center),
                          ),
                        ),
                        Expanded(flex: 4, child: Text(log['details']?.toString() ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.mutedTextColor))),
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
      padding: EdgeInsets.all(isWide ? 32 : 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF13131A), Color(0xFF1E1E2F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: AppTheme.primaryColor.withValues(alpha: 0.2), blurRadius: 20, offset: const Offset(0, 10)),
        ],
      ),
      child: isWide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                      child: const Text('SYSTEM GOVERNANCE', style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                    ),
                    const SizedBox(height: 16),
                    const Text('Central Intelligence Dashboard', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('Monitor system health, manage infrastructure, and oversee audit transparency across all business units.', style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 14)),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Opacity(opacity: 0.2, child: Image.asset('assets/CUnitedGold.png', height: 100)),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                child: const Text('SYSTEM GOVERNANCE', style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              ),
              const SizedBox(height: 16),
              const Text('Central Intelligence Dashboard', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Monitor system health, manage infrastructure, and oversee audit transparency across all business units.', style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 14)),
              const SizedBox(height: 24),
              Opacity(opacity: 0.2, child: Image.asset('assets/CUnitedGold.png', height: 60)),
            ],
          ),
    ).animate().fadeIn().slideY(begin: -0.1);
  }

  Widget _buildStatCard(String title, dynamic value, String trend, IconData icon, Color color, bool isWide, [bool isMobile = false]) {
    return Container(
      padding: EdgeInsets.all(isWide ? 24 : 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.05),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: EdgeInsets.all(isWide ? 12 : 10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: color, size: isWide ? 24 : 20),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.trending_up_rounded, color: Colors.green, size: 14),
                    const SizedBox(width: 4),
                    Text(trend, style: const TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: isWide ? 24 : 16),
          Text(title, style: TextStyle(color: AppTheme.mutedTextColor, fontSize: isWide ? 14 : 11, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text(value?.toString() ?? '-', style: TextStyle(color: AppTheme.textColor, fontSize: isWide ? 28 : 20, fontWeight: FontWeight.bold, letterSpacing: -1)),
        ],
      ),
    );
  }
}
