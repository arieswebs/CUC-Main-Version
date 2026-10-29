import 'package:amplify_api/amplify_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import 'login_screen.dart';
import 'task_management_screen.dart';
import 'staff_chat_list_screen.dart';
import 'inward_post_screen.dart';
import 'company_bill_management_screen.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../widgets/notification_bell.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../widgets/premium_app_bar.dart';
import 'package:intl/intl.dart';
import 'dart:io' show Platform;
import 'dart:async';

import '../services/attendance_service.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import '../widgets/startup_task_popup.dart';

class DeliveryDashboardScreen extends StatefulWidget {
  const DeliveryDashboardScreen({super.key});

  @override
  State<DeliveryDashboardScreen> createState() => _DeliveryDashboardScreenState();
}

class _DeliveryDashboardScreenState extends State<DeliveryDashboardScreen> {
  static final DateTime nov1Cutoff = DateTime(2026, 11, 1);
  String _selectedPeriod = '2026-2027'; // Starts fresh from Nov 1, 2026
  int _selectedIndex = 0;
  String _userName = 'User';
  int _pendingTasks = 0;
  int _completedTasks = 0;
  String _taskFilter = 'All';
  DateTime? _lastPressedAt;
  bool _isCheckedIn = false;
  int? _attendanceId;
  String? _checkInTimeStr;
  int _dailyTotalMinutes = 0;
  bool _isAttendanceLoading = true;


  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _fetchTaskStats();
    
    // Start realtime notifications
    AuthService().getUserId().then((id) {
      if (id != null) {
        NotificationService().startRealtimeListener(id);
      }
    });
    _fetchAttendanceStatus();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      StartupTaskPopup.checkAndShow(context);
    });
  }

  @override
  void dispose() {

    super.dispose();
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
    if (userId == null) return;

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
    if (userId == null) return;

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

  Future<void> _loadUserInfo() async {
    final name = await AuthService().getUserName();
    if (mounted) {
      setState(() {
        _userName = name ?? 'Delivery Staff';
      });
    }
  }

  Future<void> _fetchTaskStats() async {
    try {
      final userId = await AuthService().getUserId();
      if (userId == null) return;

      final req = ModelQueries.list(amplify_models.Tasks.classType, where: amplify_models.Tasks.ASSIGNED_TO.eq(userId), limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      final tasksList = (res.data?.items ?? []).whereType<amplify_models.Tasks>().toList();

      int pending = 0;
      int completed = 0;
      for (var row in tasksList) {
        DateTime date = DateTime(2000);
        if (row.created_at != null && row.created_at!.isNotEmpty) {
          date = DateTime.tryParse(row.created_at!) ?? date;
        } else if (row.createdAt != null) {
          date = row.createdAt!.getDateTimeInUtc().toLocal();
        }

        if (_selectedPeriod == '2025-2026' && !date.isBefore(nov1Cutoff)) continue;
        if (_selectedPeriod == '2026-2027' && date.isBefore(nov1Cutoff)) continue;

        final status = row.status?.toString();
        if (status == 'Completed') {
          completed++;
        } else {
          pending++;
        }
      }

      if (mounted) {
        setState(() {
          _pendingTasks = pending;
          _completedTasks = completed;
        });
      }
    } catch (_) {}
  }

  Widget _buildPeriodSelector() {
    return Container(
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
        children: [
          _buildPeriodChip(
            id: '2026-2027',
            title: '2026-2027 (Current)',
            icon: Icons.fiber_new_rounded,
            activeColor: const Color(0xFF10B981),
          ),
          _buildPeriodChip(
            id: '2025-2026',
            title: '2025-2026',
            icon: Icons.history_rounded,
            activeColor: const Color(0xFF6366F1),
          ),
          _buildPeriodChip(
            id: 'All',
            title: 'All Deliveries',
            icon: Icons.inventory_2_rounded,
            activeColor: AppTheme.primaryColor,
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodChip({
    required String id,
    required String title,
    required IconData icon,
    required Color activeColor,
  }) {
    final isSelected = _selectedPeriod == id;
    return InkWell(
      onTap: () {
        setState(() {
          _selectedPeriod = id;
        });
        _fetchTaskStats();
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
              size: 15,
              color: isSelected ? Colors.white : const Color(0xFF64748B),
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                color: isSelected ? Colors.white : const Color(0xFF1E293B),
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleLogout() async {
    await AuthService().logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  Widget _buildHomeView() {
    final hour = DateTime.now().hour;
    String greeting = 'Good Morning';
    if (hour >= 12 && hour < 17) {
      greeting = 'Good Afternoon';
    } else if (hour >= 17) greeting = 'Good Evening';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$greeting,',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 16, fontWeight: FontWeight.w500),
          ).animate().fadeIn(duration: 600.ms).slideX(begin: -0.2),
          const SizedBox(height: 4),
          Text(
            _userName,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -1, color: Color(0xFF1E293B)),
          ).animate().fadeIn(delay: 200.ms, duration: 600.ms).slideX(begin: -0.1),
          const SizedBox(height: 32),
          
          // Fleet Banner
          _buildFleetBanner(),
          const SizedBox(height: 24),
          _buildPeriodSelector(),
          const SizedBox(height: 20),
          
          // Stats Cards
          if (MediaQuery.of(context).size.width > 600)
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    'Pending Deliveries',
                    _pendingTasks.toString(),
                    'Assigned to you',
                    Icons.pending_actions_rounded,
                    const Color(0xFF2563EB),
                    onTap: () => setState(() {
                      _taskFilter = 'Pending';
                      _selectedIndex = 1;
                    }),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: _buildStatCard(
                    'Completed',
                    _completedTasks.toString(),
                    'Total success',
                    Icons.check_circle_rounded,
                    const Color(0xFF10B981),
                    onTap: () => setState(() {
                      _taskFilter = 'Completed';
                      _selectedIndex = 1;
                    }),
                  ),
                ),
              ],
            ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.1)
          else
            Column(
              children: [
                _buildStatCard(
                  'Pending Deliveries',
                  _pendingTasks.toString(),
                  'Assigned to you',
                  Icons.pending_actions_rounded,
                  const Color(0xFF2563EB),
                  onTap: () => setState(() {
                    _taskFilter = 'Pending';
                    _selectedIndex = 1;
                  }),
                ),
                const SizedBox(height: 12),
                _buildStatCard(
                  'Completed',
                  _completedTasks.toString(),
                  'Total success',
                  Icons.check_circle_rounded,
                  const Color(0xFF10B981),
                  onTap: () => setState(() {
                    _taskFilter = 'Completed';
                    _selectedIndex = 1;
                  }),
                ),
              ],
            ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.1),
          
          const SizedBox(height: 40),
          
          const Text(
            'Quick Actions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
          ),
          const SizedBox(height: 16),
          
          _buildQuickAction(
            'View My Tasks',
            'Check your delivery schedule',
            Icons.list_alt_rounded,
            const Color(0xFF2563EB),
            () => setState(() => _selectedIndex = 1),
          ),
          const SizedBox(height: 12),
          _buildQuickAction(
            'Open Chat',
            'Connect with the team',
            Icons.chat_bubble_rounded,
            const Color(0xFF8B5CF6),
            () => setState(() => _selectedIndex = 2),
          ),
          const SizedBox(height: 12),
          _buildQuickAction(
            'Travel Log',
            'Record your next destination',
            Icons.directions_car_rounded,
            const Color(0xFF10B981),
            _showTravelLogDialog,
          ),
          const SizedBox(height: 12),
          _buildQuickAction(
            'Post Register',
            'Log and view inward physical posts',
            Icons.mark_email_unread_rounded,
            const Color(0xFFF59E0B),
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => InwardPostScreen(
                currentUserRole: 'delivery',
                currentUserName: _userName,
              )),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFleetBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF13131A), Color(0xFF1E1E2F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: const Color(0xFF2563EB).withValues(alpha: 0.2), blurRadius: 20, offset: const Offset(0, 10)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'FLEET COMMAND',
              style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Operational Readiness',
            style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Manage your assigned tasks and communicate with the logistics team in real-time.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
          ),
          if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isAttendanceLoading ? null : _toggleAttendance,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isCheckedIn ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 8,
                  shadowColor: (_isCheckedIn ? const Color(0xFFEF4444) : const Color(0xFF10B981)).withValues(alpha: 0.4),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _isAttendanceLoading
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Icon(_isCheckedIn ? Icons.stop_circle : Icons.play_circle_fill, size: 24),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _isCheckedIn 
                            ? 'Check Out (In since ${_checkInTimeStr ?? ""})' 
                            : 'Check In to Start Tracking',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '⌚ Total Time Today: ${_dailyTotalMinutes ~/ 60}h ${_dailyTotalMinutes % 60}m',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn().slideY(begin: -0.1);
  }

  Widget _buildStatCard(String title, String value, String trend, IconData icon, Color color, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: color.withValues(alpha: 0.1)),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.05), blurRadius: 20, offset: const Offset(0, 10)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16)),
                  child: Icon(icon, color: color, size: 24),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                  child: Text(trend, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(title, style: const TextStyle(color: AppTheme.mutedTextColor, fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: -1)),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickAction(String title, String subtitle, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey.shade100),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E293B))),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.grey.shade300),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isWide = MediaQuery.of(context).size.width > 900;
    final List<Widget> pages = [
      _buildHomeView(),
      TaskManagementScreen(initialStatus: _taskFilter),
      const StaffChatListScreen(),
      CompanyBillManagementScreen(),
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        
        if (_selectedIndex != 0) {
          setState(() {
            _selectedIndex = 0;
            _taskFilter = 'All';
          });
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
            ),
          );
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
      backgroundColor: const Color(0xFFF8FAFB),
      appBar: PremiumAppBar(
        centerTitle: false,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)]),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.delivery_dining_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('COCHIN UNITED', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 0.5), overflow: TextOverflow.ellipsis),
                  Text('DELIVERY PORTAL', style: TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1.2), overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
        actions: [
          const NotificationBell(),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _handleLogout,
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: Colors.red.shade50, shape: BoxShape.circle),
              child: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 18),
            ),
            tooltip: 'Logout',
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.all(MediaQuery.of(context).size.width > 900 ? 24 : 16),
        child: !isWide 
          ? pages[_selectedIndex]
          : Row(
            children: [
              // Sidebar (Desktop/Tablet)
              NavigationRail(
                selectedIndex: _selectedIndex,
                onDestinationSelected: (idx) => setState(() {
                  _selectedIndex = idx;
                  _taskFilter = 'All';
                }),
                backgroundColor: Colors.white,
                labelType: NavigationRailLabelType.none,
                extended: isWide,
                minExtendedWidth: 200,
                selectedIconTheme: const IconThemeData(color: AppTheme.primaryColor, size: 24),
                selectedLabelTextStyle: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold, fontSize: 13),
                unselectedLabelTextStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: Text('Home'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.assignment_outlined),
                    selectedIcon: Icon(Icons.assignment_rounded),
                    label: Text('Deliveries and Pickup'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.chat_bubble_outline_rounded),
                    selectedIcon: Icon(Icons.chat_bubble_rounded),
                    label: Text('Chat'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.account_balance_wallet_outlined),
                    selectedIcon: Icon(Icons.account_balance_wallet_rounded),
                    label: Text('Accounting & Pay'),
                  ),
                ],
              ),
              const VerticalDivider(thickness: 1, width: 1),
              // Content
              Expanded(
                child: pages[_selectedIndex],
              ),
            ],
          ),
      ),
      bottomNavigationBar: !isWide 
        ? Container(
            decoration: BoxDecoration(
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 20, offset: const Offset(0, -5))],
            ),
            child: BottomNavigationBar(
              currentIndex: _selectedIndex,
              onTap: (idx) => setState(() {
                _selectedIndex = idx;
                _taskFilter = 'All';
              }),
              selectedItemColor: AppTheme.primaryColor,
              unselectedItemColor: Colors.grey.shade400,
              showUnselectedLabels: true,
              elevation: 0,
              type: BottomNavigationBarType.fixed,
              backgroundColor: Colors.white,
              selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.home_outlined),
                  activeIcon: Icon(Icons.home_rounded),
                  label: 'Home',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.assignment_outlined),
                  activeIcon: Icon(Icons.assignment_rounded),
                  label: 'Deliveries and Pickup',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.chat_bubble_outline_rounded),
                  activeIcon: Icon(Icons.chat_bubble_rounded),
                  label: 'Chat',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  activeIcon: Icon(Icons.account_balance_wallet_rounded),
                  label: 'Accounting & Pay',
                ),
              ],
            ),
          )
        : null,
      ),
    );
  }
}
