import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/meta_service.dart';
import '../theme.dart';

class MetaHubDialog extends StatefulWidget {
  final VoidCallback? onLeadsImported;

  const MetaHubDialog({super.key, this.onLeadsImported});

  static Future<void> show(BuildContext context, {VoidCallback? onLeadsImported}) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => MetaHubDialog(onLeadsImported: onLeadsImported),
    );
  }

  @override
  State<MetaHubDialog> createState() => _MetaHubDialogState();
}

class _MetaHubDialogState extends State<MetaHubDialog> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final MetaLeadService _leadService = MetaLeadService();
  final WhatsAppCloudService _waService = WhatsAppCloudService();

  late TextEditingController _appIdCtrl;
  late TextEditingController _appSecretCtrl;
  late TextEditingController _tokenCtrl;
  late TextEditingController _pageIdCtrl;
  late TextEditingController _formIdCtrl;
  late TextEditingController _verifyTokenCtrl;

  late TextEditingController _waPhoneIdCtrl;
  late TextEditingController _internalWaPhoneIdCtrl;
  late TextEditingController _waWabaIdCtrl;
  late TextEditingController _testPhoneCtrl;
  late TextEditingController _testMsgCtrl;
  late TextEditingController _notifyPhoneCtrl;
  late TextEditingController _simPhoneCtrl;
  late TextEditingController _simMsgCtrl;
  late TextEditingController _broadcastMsgCtrl;

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isSyncingLeads = false;
  bool _isSendingWa = false;
  bool _isSimulating = false;
  bool _isBroadcasting = false;
  String? _simResult;
  String? _broadcastResult;
  bool _simSuccess = false;
  bool _preferCloudApi = true;
  bool _notifyOnNewLead = true;
  bool _notifyStaffOnAssignment = true;
  bool _obscureSecret = true;
  bool _obscureToken = true;
  String _statusMessage = '';
  Color _statusColor = Colors.white70;

  List<Map<String, dynamic>> _staffDirectory = [];
  bool _isLoadingStaff = false;
  final Map<String, bool> _isSendingTo = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _appIdCtrl = TextEditingController(text: MetaConfig.defaultAppId);
    _appSecretCtrl = TextEditingController(text: MetaConfig.defaultAppSecret);
    _tokenCtrl = TextEditingController();
    _pageIdCtrl = TextEditingController();
    _formIdCtrl = TextEditingController();
    _verifyTokenCtrl = TextEditingController(text: MetaConfig.defaultVerifyToken);
    _waPhoneIdCtrl = TextEditingController(text: MetaConfig.defaultWhatsAppPhoneId);
    _internalWaPhoneIdCtrl = TextEditingController();
    _waWabaIdCtrl = TextEditingController(text: MetaConfig.defaultWhatsAppWabaId);
    _notifyPhoneCtrl = TextEditingController(text: MetaConfig.defaultNotifyAdminPhone);
    _testPhoneCtrl = TextEditingController(text: '917012466754');
    _testMsgCtrl = TextEditingController(
      text: 'Hello from Cochin United Consultancy! This is a test message via Meta WhatsApp Cloud API.',
    );
    _simPhoneCtrl = TextEditingController(text: '917012466754');
    _simMsgCtrl = TextEditingController(text: 'task completed');
    _broadcastMsgCtrl = TextEditingController(
      text: 'This is a verification test message from Cochin United Consultancy Operations.\n\nAutomated WhatsApp Integration is active. When assigned a task or work, you can reply "task completed" to automatically mark it completed in the software.',
    );

    _loadConfig();
    _loadStaffDirectory();
  }

  Future<void> _loadConfig() async {
    final cfg = await MetaConfig.load();
    if (mounted) {
      setState(() {
        _appIdCtrl.text = cfg.appId.isNotEmpty ? cfg.appId : MetaConfig.defaultAppId;
        _appSecretCtrl.text = cfg.appSecret.isNotEmpty ? cfg.appSecret : MetaConfig.defaultAppSecret;
        _tokenCtrl.text = cfg.accessToken;
        _pageIdCtrl.text = cfg.pageId;
        _formIdCtrl.text = cfg.formId;
        _verifyTokenCtrl.text = cfg.webhookVerifyToken;
        _waPhoneIdCtrl.text = cfg.whatsappPhoneNumberId;
        _internalWaPhoneIdCtrl.text = cfg.internalOpsWhatsAppPhoneId;
        _waWabaIdCtrl.text = cfg.whatsappWabaId;
        _notifyPhoneCtrl.text = cfg.notifyAdminPhone;
        _notifyOnNewLead = cfg.notifyOnNewLead;
        _notifyStaffOnAssignment = cfg.notifyStaffOnAssignment;
        _preferCloudApi = cfg.preferCloudApi;
        _isLoading = false;
      });
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _isSaving = true);
    final cfg = MetaConfig(
      appId: _appIdCtrl.text.trim(),
      appSecret: _appSecretCtrl.text.trim(),
      accessToken: _tokenCtrl.text.trim(),
      pageId: _pageIdCtrl.text.trim(),
      formId: _formIdCtrl.text.trim(),
      webhookVerifyToken: _verifyTokenCtrl.text.trim(),
      whatsappPhoneNumberId: _waPhoneIdCtrl.text.trim(),
      internalOpsWhatsAppPhoneId: _internalWaPhoneIdCtrl.text.trim(),
      whatsappWabaId: _waWabaIdCtrl.text.trim(),
      preferCloudApi: _preferCloudApi,
      notifyAdminPhone: _notifyPhoneCtrl.text.trim(),
      notifyOnNewLead: _notifyOnNewLead,
      notifyStaffOnAssignment: _notifyStaffOnAssignment,
    );
    await cfg.save();
    if (mounted) {
      setState(() {
        _isSaving = false;
        _statusMessage = 'Settings saved successfully!';
        _statusColor = Colors.greenAccent;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Meta & WhatsApp settings saved!'),
          backgroundColor: Color(0xFF10B981),
        ),
      );
    }
  }

  Future<void> _syncMetaLeads() async {
    if (_tokenCtrl.text.trim().isEmpty) {
      setState(() {
        _statusMessage = 'Please enter your Meta Graph API Access Token first.';
        _statusColor = const Color(0xFFEF4444);
      });
      return;
    }
    if (_formIdCtrl.text.trim().isEmpty && _pageIdCtrl.text.trim().isEmpty) {
      setState(() {
        _statusMessage = 'Please provide either a Form ID or Page ID.';
        _statusColor = const Color(0xFFEF4444);
      });
      return;
    }

    setState(() {
      _isSyncingLeads = true;
      _statusMessage = 'Connecting to Meta Graph API & discovering all active forms...';
      _statusColor = AppTheme.primaryColor;
    });

    try {
      await _saveConfig();
      final leads = await _leadService.fetchLeadsFromMeta();
      int ingestedCount = 0;
      for (final lead in leads) {
        final id = await _leadService.ingestLeadToCrm(lead);
        if (id != null) ingestedCount++;
      }

      if (mounted) {
        setState(() {
          _isSyncingLeads = false;
          _statusMessage = 'Sync Complete: Fetched ${leads.length} leads across active Meta campaigns ($ingestedCount new leads added to CRM).';
          _statusColor = const Color(0xFF10B981);
        });
        widget.onLeadsImported?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncingLeads = false;
          _statusMessage = 'Lead Sync Failed: $e';
          _statusColor = const Color(0xFFEF4444);
        });
      }
    }
  }

  Future<void> _createSampleLead() async {
    setState(() {
      _statusMessage = 'Creating sample Meta Lead in CRM...';
      _statusColor = AppTheme.primaryColor;
    });

    try {
      await _leadService.simulateTestLead();
      if (mounted) {
        setState(() {
          _statusMessage = 'Success! Sample Meta Lead was added directly to CRM Stage: Created.';
          _statusColor = const Color(0xFF10B981);
        });
        widget.onLeadsImported?.call();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sample Meta Lead added to CRM! Check Kanban board.'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Failed to create test lead: $e';
          _statusColor = const Color(0xFFEF4444);
        });
      }
    }
  }

  Future<void> _sendTestWhatsApp() async {
    final phone = _testPhoneCtrl.text.trim();
    final msg = _testMsgCtrl.text.trim();

    if (phone.isEmpty) {
      setState(() {
        _statusMessage = 'Please enter a recipient phone number.';
        _statusColor = const Color(0xFFEF4444);
      });
      return;
    }

    setState(() {
      _isSendingWa = true;
      _statusMessage = 'Sending WhatsApp message...';
      _statusColor = AppTheme.primaryColor;
    });

    try {
      final res = await _waService.sendMessage(toPhone: phone, message: msg);
      if (res.success) {
        if (mounted) {
          setState(() {
            _isSendingWa = false;
            _statusMessage = 'WhatsApp message sent successfully via Meta Cloud API! (ID: ${res.messageId})';
            _statusColor = const Color(0xFF10B981);
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isSendingWa = false;
            _statusMessage = 'Cloud API: ${res.error}';
            _statusColor = const Color(0xFFF59E0B);
          });
          if (res.canFallbackToWaMe) {
            _showFallbackPrompt(phone, msg);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSendingWa = false;
          _statusMessage = 'Error sending WhatsApp: $e';
          _statusColor = const Color(0xFFEF4444);
        });
      }
    }
  }

  void _showFallbackPrompt(String phone, String msg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF181A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.chat_bubble_outline, color: Color(0xFF25D366)),
            SizedBox(width: 8),
            Text('Open in WhatsApp App?', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: Text(
          'Meta Cloud API failed or is not active yet. Would you like to open WhatsApp directly via wa.me to send this message to $phone?',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366)),
            onPressed: () {
              Navigator.pop(ctx);
              WhatsAppCloudService.launchWhatsAppApp(phone: phone, message: msg);
            },
            child: const Text('Open WhatsApp', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _simulateInboundWhatsAppReply() async {
    final phone = _simPhoneCtrl.text.trim();
    final msg = _simMsgCtrl.text.trim();

    if (phone.isEmpty) {
      setState(() {
        _simResult = 'Please enter a staff phone number.';
        _simSuccess = false;
      });
      return;
    }

    if (msg.isEmpty) {
      setState(() {
        _simResult = 'Please enter a reply message (e.g. "task completed").';
        _simSuccess = false;
      });
      return;
    }

    setState(() {
      _isSimulating = true;
      _simResult = null;
    });

    try {
      final res = await WhatsAppInboundProcessor().processInboundMessage(
        fromPhone: phone,
        messageBody: msg,
      );

      if (mounted) {
        setState(() {
          _isSimulating = false;
          _simSuccess = res.success;
          if (res.success) {
            _simResult = '🎉 SUCCESS!\n'
                '• Staff: ${res.staffName} (${res.staffPhone})\n'
                '• Action: Marked ${res.matchedType?.toUpperCase() ?? "TASK"} as COMPLETED in Software!\n'
                '• Item: "${res.matchedTitle}" (ID: ${res.matchedId})\n'
                '• Audit Logged & Confirmation WhatsApp Sent!';
          } else {
            _simResult = res.message;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSimulating = false;
          _simSuccess = false;
          _simResult = 'Simulation Error: $e';
        });
      }
    }
  }

  Future<void> _sendBroadcastToAllStaff() async {
    final msg = _broadcastMsgCtrl.text.trim();
    if (msg.isEmpty) {
      setState(() => _broadcastResult = 'Please enter a message to broadcast.');
      return;
    }

    setState(() {
      _isBroadcasting = true;
      _broadcastResult = null;
    });

    try {
      final res = await _waService.sendTestMessageToAllStaff(
        customMessage: msg,
      );

      if (mounted) {
        setState(() {
          _isBroadcasting = false;
          final sentList = res.sentDetails.map((s) => '✅ ${s['name']} (${s['phone']})').join('\n');
          final failedList = res.failedDetails.isNotEmpty
              ? '\n\n⚠️ Failed (${res.totalFailed}):\n${res.failedDetails.map((f) => '❌ ${f['name']} (${f['phone']}): ${f['error']}').join('\n')}'
              : '';
          final missingList = res.missingPhoneStaff.isNotEmpty
              ? '\n\nℹ️ Staff without phone number in Staff Management:\n${res.missingPhoneStaff.map((m) => '• $m').join('\n')}'
              : '';
          _broadcastResult = '🎉 Broadcast Finished!\n'
              '• Total Staff Contacted: ${res.totalAttempted}\n'
              '• Successfully Delivered: ${res.totalSuccess}\n\n'
              '$sentList$failedList$missingList';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isBroadcasting = false;
          _broadcastResult = 'Broadcast Error: $e';
        });
      }
    }
  }

  Future<void> _loadStaffDirectory() async {
    if (!mounted) return;
    setState(() => _isLoadingStaff = true);
    try {
      final list = await _waService.getStaffDirectoryWithPhones();
      if (mounted) {
        setState(() {
          _staffDirectory = list;
          _isLoadingStaff = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading staff directory in dialog: $e');
      if (mounted) setState(() => _isLoadingStaff = false);
    }
  }

  Future<void> _sendIndividualTest(Map<String, dynamic> staff) async {
    final name = staff['name'] ?? 'Staff Member';
    final phone = staff['phone'] as String?;
    if (phone == null || phone.isEmpty) return;

    setState(() => _isSendingTo[phone] = true);
    try {
      final res = await _waService.sendMessage(
        toPhone: phone,
        message: '👋 *Hi $name,*\n\n'
            'This is a verification test message from *Cochin United Consultancy* Operations.\n\n'
            'Your WhatsApp number (*+$phone*) is connected for live task alerts and auto-completion tracking! 🚀',
      );
      if (mounted) {
        if (!res.success && res.canFallbackToWaMe) {
          _showFallbackPrompt(phone, '👋 Hi $name,\n\nThis is a verification test message from Cochin United Consultancy Operations.');
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(res.success
                  ? '✅ Verification message delivered to $name ($phone)!'
                  : '❌ Delivery note: ${res.error}'),
              backgroundColor: res.success ? const Color(0xFF10B981) : Colors.orangeAccent,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _isSendingTo.remove(phone));
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _appIdCtrl.dispose();
    _appSecretCtrl.dispose();
    _tokenCtrl.dispose();
    _pageIdCtrl.dispose();
    _formIdCtrl.dispose();
    _verifyTokenCtrl.dispose();
    _waPhoneIdCtrl.dispose();
    _internalWaPhoneIdCtrl.dispose();
    _waWabaIdCtrl.dispose();
    _notifyPhoneCtrl.dispose();
    _testPhoneCtrl.dispose();
    _testMsgCtrl.dispose();
    _simPhoneCtrl.dispose();
    _simMsgCtrl.dispose();
    _broadcastMsgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF13141F),
      elevation: 24,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppTheme.primaryColor.withValues(alpha: 0.3), width: 1.2),
      ),
      child: Container(
        width: 740,
        height: 680,
        padding: const EdgeInsets.all(24),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 16),
                  _buildTabBar(),
                  const SizedBox(height: 16),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildLeadsTab(),
                        _buildWhatsAppTab(),
                        _buildWebhookGuideTab(),
                      ],
                    ),
                  ),
                  if (_statusMessage.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: _statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _statusColor.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        _statusMessage,
                        style: TextStyle(color: _statusColor, fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  _buildFooter(),
                ],
              ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF0081FB), Color(0xFF0064E0), Color(0xFF25D366)],
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.all_inclusive_rounded, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Meta Suite & WhatsApp Integration',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Meta Lead Ads (Facebook/Instagram) & WhatsApp Cloud API',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Close',
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E202E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TabBar(
        controller: _tabController,
        indicatorColor: AppTheme.primaryColor,
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: AppTheme.primaryColor,
        unselectedLabelColor: Colors.white60,
        tabs: const [
          Tab(
            icon: Icon(Icons.campaign_rounded, size: 18),
            text: 'Meta Lead Ads',
          ),
          Tab(
            icon: Icon(Icons.chat_rounded, size: 18),
            text: 'WhatsApp Cloud API',
          ),
          Tab(
            icon: Icon(Icons.webhook_rounded, size: 18),
            text: 'Webhook & Setup',
          ),
        ],
      ),
    );
  }

  Widget _buildLeadsTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  label: 'Meta App ID',
                  controller: _appIdCtrl,
                  hint: '1060577493680372',
                  icon: Icons.badge_outlined,
                  readOnly: false,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTextField(
                  label: 'Meta App Secret',
                  controller: _appSecretCtrl,
                  hint: '9fa43105b05139d124cbcdca087e7ae6',
                  icon: Icons.key_rounded,
                  obscure: _obscureSecret,
                  onToggleObscure: () => setState(() => _obscureSecret = !_obscureSecret),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildTextField(
            label: 'Meta Graph API User/Page Access Token',
            controller: _tokenCtrl,
            hint: 'EAA... (Never-expiring System User Token or Page Token)',
            icon: Icons.lock_outline_rounded,
            obscure: _obscureToken,
            onToggleObscure: () => setState(() => _obscureToken = !_obscureToken),
            helperText: 'Generate from Meta Developer Portal > App Dashboard > Graph API Explorer or System Users',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  label: 'Facebook Page ID (Optional)',
                  controller: _pageIdCtrl,
                  hint: 'e.g. 1029384756',
                  icon: Icons.flag_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTextField(
                  label: 'Lead Form ID (Blank = Auto-sync all forms)',
                  controller: _formIdCtrl,
                  hint: 'Blank = All forms, or e.g. 3632264293615869, 1083035564715146',
                  icon: Icons.assignment_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isSyncingLeads ? null : _syncMetaLeads,
                    icon: _isSyncingLeads
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : const Icon(Icons.sync_rounded, color: Colors.black),
                    label: Text(
                      _isSyncingLeads ? 'Syncing...' : 'Sync Live Leads from Meta',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _createSampleLead,
                  icon: const Icon(Icons.add_circle_outline, color: Color(0xFF38BDF8), size: 18),
                  label: const Text('Simulate Test Lead', style: TextStyle(color: Color(0xFF38BDF8))),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF38BDF8)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWhatsAppTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded, color: Color(0xFFFBBF24), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sender Phone (+91 73064 25378) — Verification Status Note',
                        style: TextStyle(color: Color(0xFFFBBF24), fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Meta reports HTTP 200 for outbound messages, but actual phone delivery requires completing the 6-digit SMS OTP in Meta WhatsApp Manager (status: NOT_VERIFIED, 1-hour anti-spam cooldown currently active).\n\n💡 Direct Solution: Click the "Open WhatsApp (wa.me)" icon next to any staff member in the directory below to send the message directly from your WhatsApp Web/Desktop instantly.',
                        style: TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  label: 'Customer-Facing WhatsApp Phone ID',
                  controller: _waPhoneIdCtrl,
                  hint: '979396128599210 (+91 73064 25378)',
                  icon: Icons.people_outline_rounded,
                  helperText: 'Used for chatting with clients, quotations & billing receipts',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildTextField(
                  label: 'Internal Operations WhatsApp Phone ID (New Number)',
                  controller: _internalWaPhoneIdCtrl,
                  hint: 'Optional: ID for internal staff alerts',
                  icon: Icons.admin_panel_settings_outlined,
                  helperText: 'Used for team lead alerts. Falls back to customer number if blank.',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildTextField(
            label: 'WhatsApp Business Account ID (WABA ID)',
            controller: _waWabaIdCtrl,
            hint: '1414737783529187',
            icon: Icons.business_center_outlined,
            helperText: 'Found in Meta Business Manager or WhatsApp Accounts',
          ),
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              title: const Text('Prefer Official WhatsApp Cloud API', style: TextStyle(color: Colors.white, fontSize: 13.5)),
              subtitle: const Text('When enabled, attempts direct API send before falling back to wa.me app', style: TextStyle(color: Colors.white54, fontSize: 11.5)),
              value: _preferCloudApi,
              activeThumbColor: const Color(0xFF25D366),
              contentPadding: EdgeInsets.zero,
              onChanged: (val) => setState(() => _preferCloudApi = val),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E202E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Material(
                  color: Colors.transparent,
                  child: SwitchListTile(
                    title: const Text('Send WhatsApp Alert for New Leads', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Instantly pings admin with lead details whenever a new Meta Ad lead arrives', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    value: _notifyOnNewLead,
                    activeThumbColor: const Color(0xFF38BDF8),
                    contentPadding: EdgeInsets.zero,
                    onChanged: (val) => setState(() => _notifyOnNewLead = val),
                  ),
                ),
                if (_notifyOnNewLead) ...[
                  const SizedBox(height: 6),
                  _buildTextField(
                    label: 'Admin WhatsApp Notification Number(s) (comma-separated)',
                    controller: _notifyPhoneCtrl,
                    hint: '917012466754, 917907675024',
                    icon: Icons.notifications_active_rounded,
                  ),
                ],
                const Divider(color: Colors.white12, height: 24),
                Material(
                  color: Colors.transparent,
                  child: SwitchListTile(
                    title: const Text('Live WhatsApp Alert on Staff Work/Task Assignment', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Sends instant WhatsApp alert to the staff member company phone when assigned a work or task', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    value: _notifyStaffOnAssignment,
                    activeThumbColor: const Color(0xFF10B981),
                    contentPadding: EdgeInsets.zero,
                    onChanged: (val) => setState(() => _notifyStaffOnAssignment = val),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1E2E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF25D366).withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.send_rounded, color: Color(0xFF25D366), size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Test WhatsApp Message Dispatch',
                      style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _buildTextField(
                  label: 'Recipient Phone Number (with Country Code)',
                  controller: _testPhoneCtrl,
                  hint: 'e.g. 919876543210',
                  icon: Icons.contact_phone_outlined,
                ),
                const SizedBox(height: 10),
                _buildTextField(
                  label: 'Test Message Body',
                  controller: _testMsgCtrl,
                  hint: 'Type test message...',
                  icon: Icons.message_outlined,
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isSendingWa ? null : _sendTestWhatsApp,
                      icon: _isSendingWa
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.send_rounded, color: Colors.white, size: 16),
                      label: Text(
                        _isSendingWa ? 'Sending...' : 'Send WhatsApp Message',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Broadcast to Every Staff Member
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1E2038), Color(0xFF131728)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF818CF8).withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF818CF8).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.campaign_rounded, color: Color(0xFF818CF8), size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '📢 Send Test Message to Every Staff Member',
                            style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'Broadcasts an announcement/test message to all registered staff WhatsApp numbers in the software.',
                            style: TextStyle(color: Colors.white60, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildTextField(
                  label: 'Broadcast Message Content',
                  controller: _broadcastMsgCtrl,
                  hint: 'Type broadcast message for all staff...',
                  icon: Icons.chat_bubble_outline_rounded,
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isBroadcasting ? null : _sendBroadcastToAllStaff,
                      icon: _isBroadcasting
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.send_and_archive_rounded, color: Colors.white, size: 16),
                      label: Text(
                        _isBroadcasting ? 'Broadcasting to All Staff...' : 'Broadcast to All Staff Now',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
                if (_broadcastResult != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      _broadcastResult!,
                      style: const TextStyle(color: Color(0xFF34D399), fontSize: 12, height: 1.4, fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          _buildStaffContactsDirectoryCard(),
        ],
      ),
    );
  }

  Widget _buildStaffContactsDirectoryCard() {
    final countWithPhone = _staffDirectory.where((s) => (s['phone'] as String?)?.isNotEmpty == true).length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131728),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.people_alt_rounded, color: Color(0xFF10B981), size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '👥 Registered Staff WhatsApp Directory (${_staffDirectory.length})',
                      style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '$countWithPhone of ${_staffDirectory.length} staff members have active WhatsApp contact numbers.',
                      style: const TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _isLoadingStaff ? null : _loadStaffDirectory,
                icon: _isLoadingStaff
                    ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70))
                    : const Icon(Icons.refresh_rounded, size: 14, color: Colors.white70),
                label: const Text('Refresh', style: TextStyle(color: Colors.white70, fontSize: 11)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_isLoadingStaff)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  children: [
                    SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF10B981))),
                    SizedBox(height: 8),
                    Text('Fetching staff directory from AppSync...', style: TextStyle(color: Colors.white60, fontSize: 11)),
                  ],
                ),
              ),
            )
          else if (_staffDirectory.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              alignment: Alignment.center,
              child: const Text('No staff members loaded yet. Click "Refresh" above.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            )
          else
            Container(
              constraints: const BoxConstraints(maxHeight: 340),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _staffDirectory.length,
                separatorBuilder: (context, index) => const Divider(color: Colors.white10, height: 1),
                itemBuilder: (context, index) {
                  final staff = _staffDirectory[index];
                  final name = staff['name']?.toString() ?? 'Team Member';
                  final username = staff['username']?.toString() ?? '';
                  final role = (staff['role']?.toString() ?? 'staff').toUpperCase();
                  final phone = staff['phone'] as String?;
                  final compPhone = staff['company_phone'] as String?;
                  final persPhone = staff['personal_phone'] as String?;
                  final designation = staff['designation'] as String?;
                  final hasPhone = phone != null && phone.isNotEmpty;
                  final isSending = phone != null && _isSendingTo[phone] == true;

                  Color roleColor;
                  switch (role.toLowerCase()) {
                    case 'admin': roleColor = Colors.purpleAccent; break;
                    case 'manager': roleColor = Colors.indigoAccent; break;
                    case 'hr': roleColor = Colors.pinkAccent; break;
                    case 'accountant': roleColor = Colors.tealAccent; break;
                    default: roleColor = Colors.blueAccent;
                  }

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: roleColor.withValues(alpha: 0.2),
                          child: Text(
                            name.isNotEmpty ? name[0].toUpperCase() : '?',
                            style: TextStyle(color: roleColor, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      name,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                    decoration: BoxDecoration(
                                      color: roleColor.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: roleColor.withValues(alpha: 0.4)),
                                    ),
                                    child: Text(role, style: TextStyle(color: roleColor, fontSize: 9.5, fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  if (username.isNotEmpty)
                                    Text('@$username', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                  if (username.isNotEmpty && designation != null && designation.isNotEmpty)
                                    const Text(' • ', style: TextStyle(color: Colors.white30, fontSize: 11)),
                                  if (designation != null && designation.isNotEmpty)
                                    Flexible(
                                      child: Text(
                                        designation,
                                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              if (compPhone != null && compPhone.isNotEmpty)
                                Row(
                                  children: [
                                    const Icon(Icons.business_center_outlined, size: 11, color: Colors.amberAccent),
                                    const SizedBox(width: 4),
                                    Text('Company Phone: $compPhone', style: const TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.w500)),
                                  ],
                                )
                              else if (persPhone != null && persPhone.isNotEmpty)
                                Row(
                                  children: [
                                    const Icon(Icons.phone_android_outlined, size: 11, color: Colors.white70),
                                    const SizedBox(width: 4),
                                    Text('Personal Phone: $persPhone', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                  ],
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (hasPhone) ...[
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.check_circle_rounded, size: 11, color: Color(0xFF34D399)),
                                    const SizedBox(width: 4),
                                    Text('+$phone', style: const TextStyle(color: Color(0xFF34D399), fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    tooltip: 'Open in WhatsApp Web (wa.me)',
                                    icon: const Icon(Icons.open_in_new_rounded, size: 14, color: Colors.white54),
                                    onPressed: () => WhatsAppCloudService.launchWhatsAppApp(phone: phone, message: 'Hello $name'),
                                  ),
                                  const SizedBox(width: 6),
                                  ElevatedButton(
                                    onPressed: isSending ? null : () => _sendIndividualTest(staff),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF25D366),
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                                    ),
                                    child: isSending
                                        ? const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                                        : const Text('Send Test', style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ] else ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.amber.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                            ),
                            child: const Text('No Phone Saved', style: TextStyle(color: Colors.amber, fontSize: 10.5)),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWebhookGuideTab() {
    final server = MetaWebhookServer();
    final isRunning = server.isRunning;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Live Embedded Webhook Server Status
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isRunning
                    ? [const Color(0xFF0F382A), const Color(0xFF14242E)]
                    : [const Color(0xFF2E1C1C), const Color(0xFF1E202E)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isRunning ? const Color(0xFF10B981).withValues(alpha: 0.4) : Colors.redAccent.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: isRunning ? const Color(0xFF10B981) : Colors.redAccent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: isRunning ? const Color(0xFF10B981) : Colors.redAccent,
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isRunning ? 'Embedded Webhook Server: ACTIVE & LISTENING' : 'Embedded Webhook Server: INACTIVE',
                      style: TextStyle(
                        color: isRunning ? const Color(0xFF34D399) : Colors.redAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Port ${server.port}',
                        style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Listens for real-time Meta WhatsApp replies ("task completed") and Meta Leadgen webhooks.',
                  style: TextStyle(color: Colors.white70, fontSize: 11.5),
                ),
                const SizedBox(height: 10),
                _buildCopyableField('Local Endpoint', 'http://localhost:${server.port}/webhook'),
                const SizedBox(height: 6),
                _buildCopyableField('Verify Token', _verifyTokenCtrl.text.isNotEmpty ? _verifyTokenCtrl.text : MetaConfig.defaultVerifyToken),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Interactive Simulator: Staff WhatsApp Reply ("task completed")
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1D2E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.bolt_rounded, color: AppTheme.primaryColor, size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '🧪 Live Simulator: Staff Replies "Task Completed"',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5),
                          ),
                          Text(
                            'Simulates staff sending a WhatsApp message to test automatic task completion.',
                            style: TextStyle(color: Colors.white60, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: _buildTextField(
                        label: 'Staff Phone Number',
                        controller: _simPhoneCtrl,
                        hint: 'e.g. 917012466754',
                        icon: Icons.phone_rounded,
                        helperText: 'Matched against Staff company or personal phone',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 5,
                      child: _buildTextField(
                        label: 'Staff WhatsApp Message',
                        controller: _simMsgCtrl,
                        hint: 'task completed',
                        icon: Icons.chat_rounded,
                        helperText: 'Try "task completed", "done", or "completed"',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isSimulating ? null : _simulateInboundWhatsAppReply,
                      icon: _isSimulating
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                          : const Icon(Icons.check_circle_outline_rounded, color: Colors.black, size: 17),
                      label: Text(
                        _isSimulating ? 'Processing...' : 'Simulate Staff WhatsApp Reply',
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12.5),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
                if (_simResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _simSuccess
                          ? const Color(0xFF10B981).withValues(alpha: 0.15)
                          : const Color(0xFFF59E0B).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _simSuccess
                            ? const Color(0xFF10B981).withValues(alpha: 0.5)
                            : const Color(0xFFF59E0B).withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      _simResult!,
                      style: TextStyle(
                        color: _simSuccess ? const Color(0xFF34D399) : const Color(0xFFFBBF24),
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 3. Meta Developer Portal Webhook Setup Guide
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2235),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: Color(0xFF38BDF8), size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Meta for Developers Webhook Configuration',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _buildStep(
                  '1',
                  'Meta App Dashboard',
                  'Go to developers.facebook.com > My Apps > App ID 1060577493680372.',
                ),
                _buildStep(
                  '2',
                  'WhatsApp Webhook',
                  'Under WhatsApp > Configuration > Edit Webhook: Enter your public URL (e.g. via ngrok or domain) + /webhook and the Verify Token below.',
                ),
                _buildStep(
                  '3',
                  'Subscribe to Webhook Fields',
                  'Click "Manage" and subscribe to "messages" (for WhatsApp replies) and "leadgen" (for Lead Ads).',
                ),
                _buildStep(
                  '4',
                  'Automatic Live Reflection',
                  'Whenever a staff member replies "task completed" to your WhatsApp Business number, the software matches them, updates the task to Completed, and sends a confirmation WhatsApp back instantly!',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(String num, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.2),
            child: Text(
              num,
              style: TextStyle(color: AppTheme.primaryColor, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12.5)),
                Text(desc, style: const TextStyle(color: Colors.white60, fontSize: 11.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCopyableField(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(color: Colors.white60, fontSize: 12)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Color(0xFF38BDF8), fontFamily: 'monospace', fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 16, color: Colors.white70),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Copy',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Copied $label!'), duration: const Duration(seconds: 1)),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    VoidCallback? onToggleObscure,
    String? helperText,
    bool readOnly = false,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        TextField(
          controller: controller,
          obscureText: obscure,
          readOnly: readOnly,
          maxLines: maxLines,
          style: const TextStyle(color: Colors.white, fontSize: 12.5),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
            prefixIcon: Icon(icon, color: AppTheme.primaryColor.withValues(alpha: 0.7), size: 18),
            suffixIcon: onToggleObscure != null
                ? IconButton(
                    icon: Icon(obscure ? Icons.visibility_off : Icons.visibility, color: Colors.white54, size: 16),
                    onPressed: onToggleObscure,
                  )
                : null,
            filled: true,
            fillColor: const Color(0xFF1E202E),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppTheme.primaryColor, width: 1.5),
            ),
          ),
        ),
        if (helperText != null) ...[
          const SizedBox(height: 3),
          Text(helperText, style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
        ],
      ],
    );
  }

  Widget _buildFooter() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close', style: TextStyle(color: Colors.white60)),
        ),
        const SizedBox(width: 10),
        ElevatedButton.icon(
          onPressed: _isSaving ? null : _saveConfig,
          icon: _isSaving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
              : const Icon(Icons.save_rounded, color: Colors.black, size: 18),
          label: Text(
            _isSaving ? 'Saving...' : 'Save Configuration',
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }
}
