import 'package:amplify_api/amplify_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import '../theme.dart';
import 'login_screen.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../widgets/notification_bell.dart';
import '../services/excel_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart';
import '../widgets/premium_app_bar.dart';
import '../widgets/startup_task_popup.dart';
import '../services/meta_service.dart';

class AccountantDashboardScreen extends StatefulWidget {
  final bool hideScaffold;
  final Function(int)? onNavigate;
  const AccountantDashboardScreen({super.key, this.hideScaffold = false, this.onNavigate});

  @override
  State<AccountantDashboardScreen> createState() => _AccountantDashboardScreenState();
}

class _AccountantDashboardScreenState extends State<AccountantDashboardScreen> {
  final _excel = ExcelService();
  bool _isLoading = true;
  String _userName = 'Accountant';
  
  Map<String, dynamic> _stats = {
    'totalRevenue': 0.0,
    'totalExpenses': 0.0,
    'pendingInvoices': 0,
    'pendingBills': 0,
    'totalClients': 0,
    'outstandingBalance': 0.0,
  };
  List<Map<String, dynamic>> _expenseBreakdown = [];
  List<Map<String, dynamic>> _overdueInvoices = [];

  @override
  void initState() {
    super.initState();
    _loadData();
    
    // Start realtime notifications
    AuthService().getUserId().then((id) {
      if (id != null) {
        NotificationService().startRealtimeListener(id);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      StartupTaskPopup.checkAndShow(context);
    });
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final name = await AuthService().getUserName();
      
      final reqRev = ModelQueries.list(Billings.classType, where: Billings.STATUS.eq('Received').and(Billings.TYPE.eq('INVOICE')), limit: 10000);
      final resRev = await Amplify.API.query(request: reqRev).response;
      final revenueRes = resRev.data?.items ?? [];
      double totalRev = 0;
      for (var r in revenueRes) {
        if (r == null) continue;
        final amt = r.amount?.toString() ?? '0';
        totalRev += double.tryParse(amt.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
      }

      final reqExp = ModelQueries.list(CompanyBills.classType, limit: 10000);
      final resExp = await Amplify.API.query(request: reqExp).response;
      final expenseRes = resExp.data?.items ?? [];
      double totalExp = 0;
      for (var r in expenseRes) {
        if (r == null) continue;
        totalExp += r.amount ?? 0.0;
      }

      final reqPendingInv = ModelQueries.list(Billings.classType, where: Billings.STATUS.ne('Received').and(Billings.TYPE.eq('INVOICE')), limit: 10000);
      final resPendingInv = await Amplify.API.query(request: reqPendingInv).response;
      final pendingInvCount = resPendingInv.data?.items ?? [];

      final reqPendingBill = ModelQueries.list(CompanyBills.classType, where: CompanyBills.STATUS.ne('Paid'), limit: 10000);
      final resPendingBill = await Amplify.API.query(request: reqPendingBill).response;
      final pendingBillCount = resPendingBill.data?.items ?? [];

      final reqClient = ModelQueries.list(Clients.classType, limit: 10000);
      final resClient = await Amplify.API.query(request: reqClient).response;
      final clientCount = resClient.data?.items ?? [];

      double totalOut = 0;
      for (var r in pendingInvCount) {
        if (r == null) continue;
        final amt = r.amount?.toString() ?? '0';
        totalOut += double.tryParse(amt.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
      }
      
      final Map<String, String> clientPhones = {
        for (var c in clientCount) if (c != null && c.name != null) c.name!: c.phone ?? ''
      };
      
      final Map<String, double> breakdownMap = {};
      for (var b in expenseRes) {
        if (b == null) continue;
        final cat = b.category ?? 'Other';
        final amt = b.amount ?? 0.0;
        breakdownMap[cat] = (breakdownMap[cat] ?? 0) + amt;
      }
      final sortedBreakdown = breakdownMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      final breakdownList = sortedBreakdown.take(5).map((e) => {'category': e.key, 'total': e.value}).toList();

      final fifteenDaysAgo = DateTime.now().subtract(const Duration(days: 15)).toIso8601String();
      final reqOverdue = ModelQueries.list(Billings.classType, where: Billings.STATUS.ne('Received').and(Billings.TYPE.eq('INVOICE')).and(Billings.CREATED_AT.lt(fifteenDaysAgo)), limit: 10000);
      final resOverdue = await Amplify.API.query(request: reqOverdue).response;
      var overdueList = (resOverdue.data?.items ?? []).where((e) => e != null).cast<Billings>().toList();
      overdueList.sort((a, b) => (a.createdAt?.toString() ?? '').compareTo(b.createdAt?.toString() ?? ''));
      final overdueRes = overdueList.take(3).toList();

      if (mounted) {
        setState(() {
          _userName = name ?? 'Accountant';
          _stats = {
            'totalRevenue': totalRev,
            'totalExpenses': totalExp,
            'pendingInvoices': pendingInvCount.length,
            'pendingBills': pendingBillCount.length,
            'totalClients': clientCount.length,
            'outstandingBalance': totalOut,
          };
          _expenseBreakdown = breakdownList;
          _overdueInvoices = overdueRes.map((r) => {
            'id': r.id,
            'no': r.invoice_no,
            'client': r.client_name,
            'amount': r.amount,
            'date': r.createdAt?.toString(),
            'phone': clientPhones[r.client_name ?? '']
          }).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading accountant stats: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading dashboard: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isWide = constraints.maxWidth > 800;
        final bool isMobile = constraints.maxWidth < 600;

        Widget mainContent = _isLoading 
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _loadData,
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(isWide ? 32 : 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  _buildGreeting(isWide, isMobile),
                  const SizedBox(height: 24),
                  
                  _buildWelcomeBanner(isWide),
                  const SizedBox(height: 32),

                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: isWide ? 3 : (isMobile ? 1 : 2),
                    mainAxisSpacing: isWide ? 24 : 12,
                    crossAxisSpacing: isWide ? 24 : 12,
                    childAspectRatio: isMobile ? 2.5 : (isWide ? 1.4 : 1.1),
                    children: [
                      _buildStatCard('Total Revenue', '₹${NumberFormat("#,##,###").format(_stats["totalRevenue"])}', 'Overall earnings', Icons.account_balance_wallet_rounded, Colors.green, isWide, isMobile),
                      _buildStatCard('Total Expenses', '₹${NumberFormat("#,##,###").format(_stats["totalExpenses"])}', 'Company payables', Icons.outbound_rounded, Colors.orange, isWide, isMobile),
                      _buildStatCard('Outstanding', '₹${NumberFormat("#,##,###").format(_stats["outstandingBalance"])}', 'Pending from clients', Icons.pending_actions_rounded, Colors.blue, isWide, isMobile),
                    ].animate(interval: 100.ms).fadeIn(duration: 500.ms).slideY(begin: 0.1),
                  ),
                  
                  const SizedBox(height: 40),
                  
                  // NEW: Expense Breakdown and Overdue Reminders
                  if (isWide) 
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: _buildExpenseBreakdown()),
                        const SizedBox(width: 32),
                        Expanded(flex: 2, child: _buildUrgentReminders()),
                      ],
                    )
                  else ...[
                    _buildExpenseBreakdown(),
                    const SizedBox(height: 32),
                    _buildUrgentReminders(),
                  ],

                  const SizedBox(height: 40),
                  const Text('Quick Access', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
                  const SizedBox(height: 16),
                  
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: isWide ? 4 : (isMobile ? 2 : 3),
                    mainAxisSpacing: isWide ? 16 : 12,
                    crossAxisSpacing: isWide ? 16 : 12,
                    childAspectRatio: isWide ? 1.5 : 1.3,
                    children: [
                      _buildModuleItem('Billing', Icons.receipt_long_rounded, Colors.blue, () => widget.onNavigate?.call(2)),
                      _buildModuleItem('Accounting & Pay', Icons.account_balance_wallet_rounded, Colors.purple, () => widget.onNavigate?.call(11)),
                      _buildModuleItem('Clients', Icons.people_alt_rounded, Colors.green, () => widget.onNavigate?.call(3)),
                      _buildModuleItem('Work Tracker', Icons.work_rounded, Colors.indigo, () => widget.onNavigate?.call(6)),
                    ],
                  ).animate().fadeIn(delay: 600.ms),
                ],
              ),
            ),
          );

        if (widget.hideScaffold) return mainContent;

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFB),
          appBar: PremiumAppBar(
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF0F172A), Color(0xFF334155)]),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.account_balance_rounded, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('CUC FINANCE', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 0.5), overflow: TextOverflow.ellipsis),
                      Text('ACCOUNTANT PORTAL', style: TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1.2), overflow: TextOverflow.ellipsis),
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
          body: mainContent,
        );
      },
    );
  }

   Widget _buildGreeting(bool isWide, [bool isMobile = false]) {
    final hour = DateTime.now().hour;
    String greeting = 'Good Evening';
    if (hour < 12) greeting = 'Good Morning';
    else if (hour < 17) greeting = 'Good Afternoon';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$greeting, ${_userName.split(' ').first} 👋', style: TextStyle(fontSize: isMobile ? 24 : 32, fontWeight: FontWeight.bold, letterSpacing: -1)),
            Text('Manage finances, billing, and accounting', style: TextStyle(color: AppTheme.mutedTextColor, fontSize: isMobile ? 12 : 14)),
          ],
        ),
        if (!isMobile) Row(
            children: [
                  const Icon(Icons.calendar_today_rounded, size: 16, color: AppTheme.primaryColor),
                  const SizedBox(width: 10),
                  Text(
                    DateFormat('EEEE, d MMM').format(DateTime.now()),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1E293B)),
                  ),
            ]
        ),
      ],
    );
  }

  Widget _buildWelcomeBanner(bool isWide) {
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
          BoxShadow(color: AppTheme.primaryColor.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 10)),
        ],
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Financial Performance',
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Track revenue, manage company expenses, and monitor client outstanding in real-time.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 16),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () async {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generating Financial Report...')));
                  try {
                    final path = await _excel.exportFinancialReport(
                      stats: _stats,
                      expenseBreakdown: _expenseBreakdown,
                      overdueInvoices: _overdueInvoices,
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Report saved to: $path'), backgroundColor: Colors.green, duration: const Duration(seconds: 4)),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to generate report: $e'), backgroundColor: Colors.redAccent),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('Download Monthly Report'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.primaryColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ),
          if (isWide) Positioned(
            right: 0, top: 0, bottom: 0,
            child: Icon(Icons.auto_graph_rounded, size: 100, color: Colors.white.withValues(alpha: 0.1)),
          ),
        ],
      ),
    ).animate().fadeIn().slideY(begin: -0.1);
  }

  Widget _buildStatCard(String title, dynamic value, String subtitle, IconData icon, Color color, bool isWide, [bool isMobile = false]) {
    return Container(
      padding: EdgeInsets.all(isWide ? 24 : 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 20)],
        border: Border.all(color: color.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(isWide ? 12 : 10),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: color, size: isWide ? 24 : 20),
          ),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(fontSize: isWide ? 24 : 18, fontWeight: FontWeight.w900, letterSpacing: -1)),
          ),
          const SizedBox(height: 4),
          Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: isWide ? 14 : 11, color: AppTheme.textColor)),
          if (isWide) Text(subtitle, style: const TextStyle(fontSize: 11, color: AppTheme.mutedTextColor)),
        ],
      ),
    );
  }

  Widget _buildInsightCard(String label, double progress, Color color, String sub) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 20)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              Text('${(progress * 100).toInt()}%', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: color)),
            ],
          ),
          const SizedBox(height: 6),
          Text(sub, style: const TextStyle(fontSize: 11, color: AppTheme.mutedTextColor)),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: color.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpenseBreakdown() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 20)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Expense Breakdown', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Icon(Icons.pie_chart_outline_rounded, color: Colors.grey.shade400),
            ],
          ),
          const SizedBox(height: 24),
          if (_expenseBreakdown.isEmpty)
            const Center(child: Padding(padding: EdgeInsets.all(20), child: Text('No expense data yet', style: TextStyle(color: Colors.grey))))
          else
            ..._expenseBreakdown.map((item) {
              final percentage = _stats['totalExpenses'] > 0 ? (item['total'] / _stats['totalExpenses']) : 0.0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(item['category'], style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        Text('₹${NumberFormat("#,###").format(item['total'])}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Stack(
                      children: [
                        Container(height: 8, width: double.infinity, decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(4))),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 1000),
                          height: 8,
                          width: MediaQuery.of(context).size.width * 0.4 * percentage, // Rough scale for bars
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [Colors.orange, Colors.deepOrangeAccent]),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    ).animate().fadeIn(delay: 400.ms);
  }

  Widget _buildUrgentReminders() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 20)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Urgent Reminders', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.redAccent)),
          const SizedBox(height: 4),
          const Text('Overdue by 15+ days', style: TextStyle(fontSize: 12, color: AppTheme.mutedTextColor)),
          const SizedBox(height: 24),
          if (_overdueInvoices.isEmpty)
            const Center(child: Padding(padding: EdgeInsets.all(20), child: Text('All caught up!', style: TextStyle(color: Colors.grey))))
          else
            ..._overdueInvoices.map((inv) => Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.02),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.red.withValues(alpha: 0.05)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(inv['client'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis),
                        Text(inv['no'], style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('₹${inv['amount']}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Colors.redAccent)),
                      const Text('Action Required', style: TextStyle(fontSize: 9, color: Colors.redAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: () async {
                      final phone = inv['phone']?.toString().replaceAll(RegExp(r'[^0-9]'), '');
                      if (phone != null && phone.isNotEmpty) {
                        final String message = 'Hello ${inv['client']},\nThis is a gentle reminder regarding Invoice ${inv['no']} for ₹${inv['amount']}. Please arrange the payment at your earliest convenience.\n- Cochin United Consultancy';
                        await WhatsAppCloudService.launchWhatsAppApp(
                          phone: phone,
                          message: message,
                        );
                      } else {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No phone number available for ${inv['client']}')));
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), shape: BoxShape.circle),
                      child: const Icon(Icons.send_rounded, color: Colors.redAccent, size: 16),
                    ),
                  ),
                ],
              ),
            )),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => widget.onNavigate?.call(2),
              child: const Text('View All Invoices', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 600.ms);
  }

  Widget _buildModuleItem(String title, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.black.withValues(alpha: 0.03)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
