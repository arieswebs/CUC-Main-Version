import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/deal.dart';
import '../services/deal_service.dart';
import '../services/client_service.dart';
import '../theme.dart';
import 'deal_detail_screen.dart';
import '../services/crm_data_importer.dart';
import '../services/notification_service.dart';
import '../services/meta_service.dart';
import '../widgets/meta_hub_dialog.dart';

class CrmScreen extends StatefulWidget {
  final VoidCallback? onBack;
  const CrmScreen({super.key, this.onBack});

  @override
  State<CrmScreen> createState() => _CrmScreenState();
}

class _CrmScreenState extends State<CrmScreen>
    with SingleTickerProviderStateMixin {
  final DealService _dealService = DealService();
  final ClientService _clientService = ClientService();
  List<Deal> _deals = [];
  bool _isLoading = true;
  String? _errorMessage;
  late TabController _tabController;

  String _searchQuery = '';
  String _selectedStage = 'All';
  String _selectedPriority = 'All';
  String _selectedFollowUpFilter = 'All';
  bool _showAllPipelines = false;
  bool _isBatchImporting = false;
  String _batchImportStatus = '';
  late StreamSubscription<List<Deal>> _dealSubscription;

  static const String stageCreated = 'Created';
  static const String stageFollowUp = 'Follow-up';
  static const String stagePassed = 'Passed to Work';
  static const String stageLost = 'Deal Lose';

  static const List<String> crmStages = [
    stageCreated,
    stageFollowUp,
    stagePassed,
    stageLost,
  ];

  String getCrmStage(Deal deal) {
    if (deal.isWon || deal.stage == 'Passed to Work' || deal.stage == 'Won') {
      return stagePassed;
    }
    final s = deal.stage.toLowerCase().trim();
    if (s == 'deal lose' || s == 'lost' || s == 'deal lost' || s == 'lose') {
      return stageLost;
    }
    if (s == 'follow-up' ||
        s == 'follow-ups' ||
        s == 'in follow-up' ||
        s == 'follow up' ||
        deal.postponedDate != null) {
      return stageFollowUp;
    }
    return stageCreated;
  }

  final List<String> _stages = [
    'All',
    stageCreated,
    stageFollowUp,
    stagePassed,
    stageLost,
  ];

  final List<String> _priorities = ['All', ...Deal.priorities];
  final List<String> _followUpFilters = [
    'All',
    'Due Today',
    'Overdue',
    'Upcoming',
    'Pending Set',
  ];

  Timer? _reminderTimer;
  Timer? _realtimePollTimer;
  Timer? _metaAutoSyncTimer;
  final Set<String> _notifiedReminderDealIds = {};
  final Set<String> _escalatedToAdminDealIds = {};
  bool _isShowingReminderDialog = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _subscribeToDeals();
    _startLiveReminderEngine();
    _startMetaLeadAutoSync();
  }

  void _startLiveReminderEngine() {
    _reminderTimer?.cancel();
    // Check every 5 seconds for live due reminders
    _reminderTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) return;
      _checkLiveFollowUpReminders();
    });

    // Periodic poll every 20 seconds to guarantee live updates without manual refresh
    _realtimePollTimer?.cancel();
    _realtimePollTimer = Timer.periodic(const Duration(seconds: 20), (timer) async {
      if (!mounted) return;
      try {
        final fresh = await _dealService.getAllDeals();
        if (mounted && fresh.isNotEmpty) {
          setState(() {
            _deals = fresh;
          });
          _checkLiveFollowUpReminders();
        }
      } catch (e) {
        debugPrint('Auto-refresh poll error: $e');
      }
    });
  }

  void _startMetaLeadAutoSync() {
    _metaAutoSyncTimer?.cancel();
    // Quick initial check 5s after screen load
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) _runMetaLeadAutoSync();
    });
    // Recurring check every 2 minutes
    _metaAutoSyncTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (mounted) _runMetaLeadAutoSync();
    });
  }

  Future<void> _runMetaLeadAutoSync() async {
    try {
      final cfg = await MetaConfig.load();
      if (cfg.accessToken.isNotEmpty && (cfg.formId.isNotEmpty || cfg.pageId.isNotEmpty)) {
        final leads = await MetaLeadService().fetchLeadsFromMeta(config: cfg);
        int newLeadsCount = 0;
        for (final lead in leads) {
          final id = await MetaLeadService().ingestLeadToCrm(lead);
          if (id != null) newLeadsCount++;
        }
        if (newLeadsCount > 0 && mounted) {
          debugPrint('🎯 Auto-synced $newLeadsCount fresh Meta leads into CRM!');
          final fresh = await _dealService.getAllDeals();
          if (mounted && fresh.isNotEmpty) {
            setState(() => _deals = fresh);
          }
        }
      }
    } catch (e) {
      debugPrint('Background Meta Lead auto-sync: $e');
    }
  }

  void _checkLiveFollowUpReminders() {
    if (!mounted) return;
    final now = DateTime.now();

    for (final deal in _deals) {
      if (deal.id == null) continue;
      final dealIdStr = deal.id.toString();

      // Only check active Created and Follow-up leads
      final stage = getCrmStage(deal);
      if (stage != stageCreated && stage != stageFollowUp) continue;
      if (deal.postponedDate == null) continue;

      final fu = deal.postponedDate!;

      // 1. Trigger popup 5 minutes before the scheduled follow-up time (or if past trigger time)
      final alertTriggerTime = fu.subtract(const Duration(minutes: 5));
      final shouldShowPopup = now.isAfter(alertTriggerTime);
      if (shouldShowPopup && !_notifiedReminderDealIds.contains(dealIdStr) && !_isShowingReminderDialog) {
        _notifiedReminderDealIds.add(dealIdStr);
        _triggerLiveReminderPopup(deal);
      }

      // 2. Escalation: If scheduled time has passed and still not followed up, alert Admin!
      final isPastDueTime = now.isAfter(fu);
      if (isPastDueTime && !_escalatedToAdminDealIds.contains(dealIdStr)) {
        _escalatedToAdminDealIds.add(dealIdStr);
        NotificationService().notifyAdminsMissedFollowUp(
          dealId: deal.id,
          leadName: deal.name,
          contactInfo: deal.contactInfo,
          scheduledTime: fu,
          contactStatus: deal.contactStatus,
          company: deal.company,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Follow-up missed for "${deal.name}". Admin has been alerted!'),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFFDC2626),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    }
  }

  Future<void> _triggerLiveReminderPopup(Deal deal) async {
    if (!mounted || _isShowingReminderDialog) return;
    _isShowingReminderDialog = true;

    // Play alert chime
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {}

    final now = DateTime.now();
    final fu = deal.postponedDate;
    final isUpcoming = fu != null && fu.isAfter(now);
    final minutesLeft = isUpcoming
        ? (fu.difference(now).inSeconds / 60).ceil()
        : 0;

    final notifTitle = isUpcoming
        ? '⏰ Follow-up in $minutesLeft min: ${deal.name}'
        : '🚨 Follow-up Due Now: ${deal.name}';
    final notifMessage = fu != null
        ? 'Scheduled at ${DateFormat('hh:mm a').format(fu)}. Status: ${deal.contactStatus ?? "Pending"}.'
        : 'Follow-up is due now.';

    // Send local notification for desktop / mobile
    NotificationService().showLocalNotification(
      title: notifTitle,
      message: notifMessage,
    );

    if (!mounted) {
      _isShowingReminderDialog = false;
      return;
    }

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final (alarmSource, alarmNotes) = _extractSourceAndNotes(deal);
            final nowInner = DateTime.now();
            final isPastDue = deal.postponedDate != null && deal.postponedDate!.isBefore(nowInner);
            final minsBefore = (deal.postponedDate != null && deal.postponedDate!.isAfter(nowInner))
                ? (deal.postponedDate!.difference(nowInner).inSeconds / 60).ceil()
                : 0;

            return Dialog(
              backgroundColor: const Color(0xFF181A2A),
              elevation: 28,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: BorderSide(
                  color: isPastDue ? const Color(0xFFEF4444) : const Color(0xFFF59E0B),
                  width: 1.5,
                ),
              ),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Top alert banner
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: (isPastDue ? const Color(0xFFEF4444) : const Color(0xFFF59E0B))
                                .withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isPastDue ? const Color(0xFFEF4444) : const Color(0xFFF59E0B),
                            ),
                          ),
                          child: Icon(
                            isPastDue ? Icons.warning_rounded : Icons.alarm_on_rounded,
                            color: isPastDue ? const Color(0xFFEF4444) : const Color(0xFFF59E0B),
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                minsBefore > 0
                                    ? 'Follow-up in $minsBefore min!'
                                    : (isPastDue ? 'Follow-up Overdue!' : 'Follow-up Due Now!'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                deal.postponedDate != null
                                    ? (minsBefore > 0
                                        ? 'Scheduled for: ${DateFormat('hh:mm a').format(deal.postponedDate!)} (Upcoming)'
                                        : 'Scheduled for: ${DateFormat('dd MMM • hh:mm a').format(deal.postponedDate!)}')
                                    : 'Scheduled follow-up due now',
                                style: TextStyle(
                                  color: isPastDue ? const Color(0xFFF87171) : const Color(0xFFF59E0B),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(dialogCtx),
                          icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // Lead Info Box
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10121C),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF262A3C)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.person_rounded, size: 16, color: AppTheme.primaryColor),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  deal.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              if (deal.contactStatus != null && deal.contactStatus!.trim().isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFC084FC).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: const Color(0xFFC084FC).withValues(alpha: 0.5)),
                                  ),
                                  child: Text(
                                    deal.contactStatus!,
                                    style: const TextStyle(color: Color(0xFFC084FC), fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ),
                          if (deal.contactInfo != null && deal.contactInfo!.trim().isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                const Icon(Icons.phone_rounded, size: 14, color: Colors.white54),
                                const SizedBox(width: 8),
                                Text(
                                  deal.contactInfo!,
                                  style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                                const Spacer(),
                                // WhatsApp
                                InkWell(
                                  onTap: () => _openWhatsApp(deal.contactInfo!, deal.name),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF25D366).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFF25D366).withValues(alpha: 0.5)),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFF25D366), size: 13),
                                        SizedBox(width: 4),
                                        Text('WhatsApp', style: TextStyle(color: Color(0xFF25D366), fontSize: 11, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Call
                                InkWell(
                                  onTap: () => _makePhoneCall(deal.contactInfo!),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0EA5E9).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFF0EA5E9).withValues(alpha: 0.5)),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.call_outlined, color: Color(0xFF38BDF8), size: 13),
                                        SizedBox(width: 4),
                                        Text('Call', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (alarmSource.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Icon(Icons.campaign_outlined, size: 12, color: Color(0xFF38BDF8)),
                                const SizedBox(width: 4),
                                Text(
                                  alarmSource,
                                  style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ],
                          if (alarmNotes.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            const Divider(color: Color(0xFF262A3C), height: 1),
                            const SizedBox(height: 8),
                            Text(
                              alarmNotes,
                              style: const TextStyle(color: Colors.white60, fontSize: 12),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),

                    // Quick Snooze options
                    Row(
                      children: [
                        const Text(
                          'Snooze:',
                          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        ActionChip(
                          label: const Text('+15 min', style: TextStyle(fontSize: 11.5, color: Colors.white)),
                          backgroundColor: const Color(0xFF222638),
                          side: const BorderSide(color: Color(0xFF363C54)),
                          onPressed: () async {
                            final snoozeTime = DateTime.now().add(const Duration(minutes: 15));
                            final updated = deal.copyWith(postponedDate: snoozeTime);
                            await _dealService.updateDeal(updated);
                            _notifiedReminderDealIds.remove(deal.id.toString());
                            _escalatedToAdminDealIds.remove(deal.id.toString());
                            if (mounted) {
                              setState(() {
                                final idx = _deals.indexWhere((d) => d.id?.toString() == updated.id?.toString());
                                if (idx != -1) _deals[idx] = updated;
                              });
                            }
                            if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Reminder snoozed for 15 minutes')),
                              );
                            }
                          },
                        ),
                        const SizedBox(width: 6),
                        ActionChip(
                          label: const Text('+1 hour', style: TextStyle(fontSize: 11.5, color: Colors.white)),
                          backgroundColor: const Color(0xFF222638),
                          side: const BorderSide(color: Color(0xFF363C54)),
                          onPressed: () async {
                            final snoozeTime = DateTime.now().add(const Duration(hours: 1));
                            final updated = deal.copyWith(postponedDate: snoozeTime);
                            await _dealService.updateDeal(updated);
                            _notifiedReminderDealIds.remove(deal.id.toString());
                            _escalatedToAdminDealIds.remove(deal.id.toString());
                            if (mounted) {
                              setState(() {
                                final idx = _deals.indexWhere((d) => d.id?.toString() == updated.id?.toString());
                                if (idx != -1) _deals[idx] = updated;
                              });
                            }
                            if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Reminder snoozed for 1 hour')),
                              );
                            }
                          },
                        ),
                        const SizedBox(width: 6),
                        ActionChip(
                          label: const Text('Tomorrow', style: TextStyle(fontSize: 11.5, color: Colors.white)),
                          backgroundColor: const Color(0xFF222638),
                          side: const BorderSide(color: Color(0xFF363C54)),
                          onPressed: () async {
                            final snoozeTime = DateTime.now().add(const Duration(days: 1));
                            final updated = deal.copyWith(postponedDate: snoozeTime);
                            await _dealService.updateDeal(updated);
                            _notifiedReminderDealIds.remove(deal.id.toString());
                            _escalatedToAdminDealIds.remove(deal.id.toString());
                            if (mounted) {
                              setState(() {
                                final idx = _deals.indexWhere((d) => d.id?.toString() == updated.id?.toString());
                                if (idx != -1) _deals[idx] = updated;
                              });
                            }
                            if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Reminder snoozed until tomorrow')),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Footer actions
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final updated = deal.copyWith(postponedDate: null);
                            await _dealService.updateDeal(updated);
                            _notifiedReminderDealIds.remove(deal.id.toString());
                            _escalatedToAdminDealIds.remove(deal.id.toString());
                            if (mounted) {
                              setState(() {
                                final idx = _deals.indexWhere((d) => d.id?.toString() == updated.id?.toString());
                                if (idx != -1) _deals[idx] = updated;
                              });
                            }
                            if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Follow-up marked as completed!'), backgroundColor: Color(0xFF16A34A)),
                              );
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF4ADE80),
                            side: const BorderSide(color: Color(0xFF4ADE80), width: 1.0),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.check_circle_outline_rounded, size: 15),
                          label: const Text('Mark Done', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogCtx),
                              child: const Text('Dismiss', style: TextStyle(color: Colors.white60)),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton.icon(
                              onPressed: () {
                                Navigator.pop(dialogCtx);
                                _showLeadDetailsDialog(deal);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryColor,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.open_in_new_rounded, size: 15),
                              label: const Text('View Lead', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    _isShowingReminderDialog = false;
  }

  List<Deal> get _dueRemindersNow {
    final now = DateTime.now();
    return _scopedDeals.where((d) {
      final st = getCrmStage(d);
      if (st != stageCreated && st != stageFollowUp) return false;
      if (d.postponedDate == null) return false;
      return d.postponedDate!.isBefore(now);
    }).toList();
  }

  void _subscribeToDeals() {
    _dealSubscription = _dealService.getDealsStream().listen(
      (deals) {
        if (mounted) {
          setState(() {
            _deals = deals;
            _isLoading = false;
          });
          _checkLiveFollowUpReminders();
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Failed to load deals: $e';
            _isLoading = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _dealSubscription.cancel();
    _reminderTimer?.cancel();
    _realtimePollTimer?.cancel();
    _metaAutoSyncTimer?.cancel();
    super.dispose();
  }

  List<Deal> get _crmDeals => _deals.where((d) {
        final p = d.pipeline.toLowerCase();
        return p == 'crm' || p == 'lead';
      }).toList();

  List<Deal> get _scopedDeals {
    if (_showAllPipelines) return _deals;
    return _crmDeals;
  }

  bool _matchesFollowUpFilter(Deal deal) {
    if (_selectedFollowUpFilter == 'All') return true;
    final d = deal.postponedDate;
    if (_selectedFollowUpFilter == 'Pending Set') {
      return d == null;
    }
    if (d == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(d.year, d.month, d.day);

    switch (_selectedFollowUpFilter) {
      case 'Due Today':
        return target.isAtSameMomentAs(today);
      case 'Overdue':
        return target.isBefore(today);
      case 'Upcoming':
        return target.isAfter(today);
      default:
        return true;
    }
  }

  List<Deal> get _followUpTodayDeals {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _scopedDeals.where((d) {
      if (d.postponedDate == null) return false;
      final target = DateTime(d.postponedDate!.year, d.postponedDate!.month, d.postponedDate!.day);
      return target.isAtSameMomentAs(today);
    }).toList();
  }

  List<Deal> get _overdueDeals {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _scopedDeals.where((d) {
      if (d.postponedDate == null) return false;
      final target = DateTime(d.postponedDate!.year, d.postponedDate!.month, d.postponedDate!.day);
      return target.isBefore(today);
    }).toList();
  }

  List<Deal> get _filteredDeals {
    return _scopedDeals.where((deal) {
      final matchesSearch = _searchQuery.isEmpty ||
          deal.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          (deal.clientName?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false) ||
          (deal.company?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false) ||
          (deal.contactInfo?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false) ||
          (deal.workType?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false);

      final crmStage = getCrmStage(deal);
      final matchesStage = _selectedStage == 'All' || crmStage == _selectedStage;

      final matchesPriority =
          _selectedPriority == 'All' || deal.priority == _selectedPriority;

      return matchesSearch && matchesStage && matchesPriority && _matchesFollowUpFilter(deal);
    }).toList();
  }

  List<Deal> get _createdDeals =>
      _scopedDeals.where((d) => getCrmStage(d) == stageCreated).toList();
  List<Deal> get _followUpDeals =>
      _scopedDeals.where((d) => getCrmStage(d) == stageFollowUp).toList();
  List<Deal> get _passedDeals =>
      _scopedDeals.where((d) => getCrmStage(d) == stagePassed).toList();
  List<Deal> get _lostDeals =>
      _scopedDeals.where((d) => getCrmStage(d) == stageLost).toList();

  double get _totalPipelineValue =>
      _createdDeals.fold(0.0, (sum, d) => sum + d.amount);

  double get _totalWonValue =>
      _passedDeals.fold(0.0, (sum, d) => sum + d.amount);

  String _fmt(double v) =>
      '₹${NumberFormat('#,##,###').format(v)}';

  Color _stageColor(String stage) {
    switch (stage) {
      case stageCreated:
        return const Color(0xFF38BDF8);
      case stageFollowUp:
        return const Color(0xFFF59E0B);
      case stagePassed:
        return const Color(0xFF4ADE80);
      case stageLost:
        return const Color(0xFFF87171);
      default:
        return AppTheme.primaryColor;
    }
  }

  Color _priorityColor(String priority) {
    switch (priority) {
      case 'Urgent':
        return Colors.redAccent;
      case 'High':
        return Colors.orange;
      case 'Normal':
        return Colors.blueAccent;
      case 'Low':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  (String, String, String) _extractSourceInquiryAndRemarks(Deal deal) {
    String source = deal.referredBy?.trim() ?? '';
    String rawDesc = deal.description?.trim() ?? '';

    // Check if description has legacy or embedded Meta/ad source block
    String cleanDesc = rawDesc;
    if (cleanDesc.contains('[Source:') || cleanDesc.contains('🎯 [Source:')) {
      final lines = cleanDesc.split('\n');
      final cleanNotesLines = <String>[];
      String? foundSource;
      String? foundCampaign;

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;

        if (line.contains('[Source:')) {
          final match = RegExp(r'\[Source:\s*([^\]]+)\]').firstMatch(line);
          if (match != null) {
            foundSource = match.group(1)?.trim();
          }
          continue;
        }
        if (line.startsWith('Lead ID:')) {
          continue;
        }
        if (line.startsWith('Campaign:')) {
          foundCampaign = line.substring('Campaign:'.length).trim();
          continue;
        }
        if (line.startsWith('Ad:')) {
          continue;
        }
        if (line.startsWith('--- Form Responses ---') || line.startsWith('Form Responses:')) {
          continue;
        }

        cleanNotesLines.add(lines[i]);
      }

      if (source.isEmpty || source.toLowerCase() == 'meta lead ads') {
        if (foundSource != null && foundSource.isNotEmpty) {
          source = foundSource;
        } else if (foundCampaign != null && foundCampaign.isNotEmpty) {
          source = 'Meta Ads: $foundCampaign';
        } else if (source.isEmpty) {
          source = 'Meta Lead Ads';
        }
      }

      cleanDesc = cleanNotesLines.join('\n').trim();
    }

    String inq = '';
    String rem = '';

    // Check for explicit dividers
    final hasInquiryHeader = cleanDesc.contains('--- Inquiry Details ---') || cleanDesc.contains('[Inquiry Details]');
    final hasRemarksHeader = cleanDesc.contains('--- Remarks ---') || cleanDesc.contains('[Remarks]');

    if (hasInquiryHeader || hasRemarksHeader) {
      String remaining = cleanDesc;
      if (hasInquiryHeader) {
        final parts = remaining.split(RegExp(r'(?:---\s*Inquiry Details\s*---|\[Inquiry Details\])'));
        if (parts.length > 1) {
          remaining = parts[1].trim();
        }
      }
      if (remaining.contains('--- Remarks ---') || remaining.contains('[Remarks]')) {
        final remParts = remaining.split(RegExp(r'(?:---\s*Remarks\s*---|\[Remarks\])'));
        inq = remParts[0].trim();
        if (remParts.length > 1) {
          rem = remParts[1].trim();
        }
      } else {
        inq = remaining.trim();
      }
    } else {
      // Smart auto-separation for existing leads / Meta form responses
      final lines = cleanDesc.split('\n');
      final inqLines = <String>[];
      final remLines = <String>[];

      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;

        final isFollowUpLine = RegExp(r'^\[\s*\d{1,2}\s+[A-Za-z]+.*-\s*Follow-up\]').hasMatch(line);
        final isRemarkPrefix = line.toLowerCase().startsWith('remark:') || line.toLowerCase().startsWith('remarks:');

        final isInquiryField = (line.contains('?:') ||
            line.contains('? :') ||
            line.toLowerCase().startsWith('email:') ||
            line.toLowerCase().startsWith('what_') ||
            line.toLowerCase().startsWith('which_') ||
            line.toLowerCase().startsWith('where_') ||
            line.toLowerCase().startsWith('service:') ||
            line.toLowerCase().startsWith('service needed:') ||
            line.toLowerCase().startsWith('property_') ||
            line.contains('നിങ്ങൾക്ക്'));

        if (isFollowUpLine || isRemarkPrefix) {
          remLines.add(rawLine);
        } else if (isInquiryField) {
          inqLines.add(rawLine);
        } else {
          if (inqLines.isNotEmpty) {
            remLines.add(rawLine);
          } else {
            inqLines.add(rawLine);
          }
        }
      }

      inq = inqLines.join('\n').trim();
      rem = remLines.join('\n').trim();
    }

    return (source, inq, rem);
  }

  (String, String) _extractSourceAndNotes(Deal deal) {
    final (source, inq, rem) = _extractSourceInquiryAndRemarks(deal);
    if (inq.isNotEmpty && rem.isNotEmpty) {
      return (source, '$inq\n\n$rem');
    }
    return (source, inq.isNotEmpty ? inq : rem);
  }

  void _openDeal(Deal deal) {
    _showLeadDetailsDialog(deal);
  }

  void _openDealDetailScreen(Deal deal) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DealDetailScreen(deal: deal, isCrm: true),
      ),
    );
  }

  Future<void> _showLeadDetailsDialog(Deal initialDeal) async {
    Deal currentDeal = initialDeal;
    final (extractedSource, inqDetails, initialRemarks) = _extractSourceInquiryAndRemarks(currentDeal);
    final nameController = TextEditingController(text: currentDeal.name);
    final phoneController = TextEditingController(text: currentDeal.contactInfo ?? '');
    final placeController = TextEditingController(text: currentDeal.company ?? '');
    final workTypeController = TextEditingController(text: currentDeal.workType ?? '');
    final sourceController = TextEditingController(text: extractedSource);
    final inquiryController = TextEditingController(text: inqDetails);
    final remarksController = TextEditingController(text: initialRemarks);
    String selectedPriority = currentDeal.priority.isNotEmpty ? currentDeal.priority : 'Normal';
    final formKey = GlobalKey<FormState>();
    bool isSaving = false;

    await showDialog(
      context: context,
      barrierDismissible: !isSaving,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final stage = getCrmStage(currentDeal);
            final stageCol = _stageColor(stage);
            final dateStr = currentDeal.createdAt != null
                ? DateFormat('dd MMM yyyy, hh:mm a').format(currentDeal.createdAt!)
                : 'Recent';

            // Check follow-up status
            String? followUpBadgeText;
            Color followUpBadgeColor = Colors.grey;
            if (currentDeal.postponedDate != null) {
              final now = DateTime.now();
              final today = DateTime(now.year, now.month, now.day);
              final fuDate = DateTime(
                currentDeal.postponedDate!.year,
                currentDeal.postponedDate!.month,
                currentDeal.postponedDate!.day,
              );
              final diff = fuDate.difference(today).inDays;
              if (diff < 0) {
                followUpBadgeText = 'Overdue by ${-diff}d (${DateFormat('dd MMM').format(currentDeal.postponedDate!)})';
                followUpBadgeColor = const Color(0xFFEF4444);
              } else if (diff == 0) {
                followUpBadgeText = 'Follow-up Due Today';
                followUpBadgeColor = const Color(0xFFF59E0B);
              } else if (diff == 1) {
                followUpBadgeText = 'Tomorrow (${DateFormat('dd MMM').format(currentDeal.postponedDate!)})';
                followUpBadgeColor = const Color(0xFF38BDF8);
              } else {
                followUpBadgeText = 'In $diff days (${DateFormat('dd MMM').format(currentDeal.postponedDate!)})';
                followUpBadgeColor = const Color(0xFF60A5FA);
              }
            }

            return Dialog(
              backgroundColor: const Color(0xFF161824),
              elevation: 24,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFF2A2E44), width: 1.2),
              ),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 620, maxHeight: 760),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                      decoration: const BoxDecoration(
                        color: Color(0xFF1B1D2C),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(20),
                          topRight: Radius.circular(20),
                        ),
                        border: Border(
                          bottom: BorderSide(color: Color(0xFF282C3F), width: 1.0),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  AppTheme.primaryColor,
                                  AppTheme.primaryColor.withValues(alpha: 0.7),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              currentDeal.name.isNotEmpty
                                  ? currentDeal.name[0].toUpperCase()
                                  : 'L',
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                                fontSize: 20,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        currentDeal.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Stage badge
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: stageCol.withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(color: stageCol.withValues(alpha: 0.6)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 6,
                                            height: 6,
                                            decoration: BoxDecoration(
                                              color: stageCol,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                          Text(
                                            stage,
                                            style: TextStyle(
                                              color: stageCol,
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(Icons.calendar_today_rounded, size: 12, color: Colors.white.withValues(alpha: 0.45)),
                                    const SizedBox(width: 5),
                                    Text(
                                      'Created $dateStr',
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.5),
                                        fontSize: 11.5,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text('•', style: TextStyle(color: Colors.white.withValues(alpha: 0.3))),
                                    const SizedBox(width: 10),
                                    _priorityTag(selectedPriority),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 20),
                            splashRadius: 20,
                          ),
                        ],
                      ),
                    ),

                    // Quick Communication & Direct Actions strip
                    if (currentDeal.contactInfo != null && currentDeal.contactInfo!.trim().isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                        color: const Color(0xFF12141F),
                        child: Row(
                          children: [
                            Icon(Icons.phone_outlined, size: 15, color: Colors.white.withValues(alpha: 0.6)),
                            const SizedBox(width: 8),
                            SelectableText(
                              currentDeal.contactInfo!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: currentDeal.contactInfo!));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Phone number copied to clipboard'),
                                      duration: Duration(seconds: 1),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.copy_rounded, size: 14, color: Color(0xFF94A3B8)),
                              tooltip: 'Copy Number',
                              splashRadius: 16,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                            ),
                            const Spacer(),
                            // WhatsApp button
                            InkWell(
                              onTap: () => _openWhatsApp(currentDeal.contactInfo!, currentDeal.name),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF25D366).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFF25D366).withValues(alpha: 0.5)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFF25D366), size: 13),
                                    SizedBox(width: 5),
                                    Text(
                                      'WhatsApp',
                                      style: TextStyle(
                                        color: Color(0xFF25D366),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Call button
                            InkWell(
                              onTap: () => _makePhoneCall(currentDeal.contactInfo!),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0EA5E9).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFF0EA5E9).withValues(alpha: 0.5)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.call_outlined, color: Color(0xFF38BDF8), size: 13),
                                    SizedBox(width: 5),
                                    Text(
                                      'Call',
                                      style: TextStyle(
                                        color: Color(0xFF38BDF8),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Body scrollable details
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(22),
                        child: Form(
                          key: formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Follow-up card
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E2235),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFF2D334E)),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: (followUpBadgeText != null ? followUpBadgeColor : Colors.white24)
                                            .withValues(alpha: 0.15),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        Icons.alarm_on_rounded,
                                        color: followUpBadgeText != null ? followUpBadgeColor : Colors.white60,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            followUpBadgeText ?? 'No Follow-up Scheduled',
                                            style: TextStyle(
                                              color: followUpBadgeText != null ? followUpBadgeColor : Colors.white70,
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          if (currentDeal.contactStatus != null && currentDeal.contactStatus!.trim().isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 2),
                                              child: Text(
                                                'Status: ${currentDeal.contactStatus}',
                                                style: const TextStyle(color: Color(0xFFC084FC), fontSize: 11.5),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        final updatedAfterFollowUp = await _showFollowUpDialog(currentDeal);
                                        if (updatedAfterFollowUp != null) {
                                          setDialogState(() {
                                            currentDeal = updatedAfterFollowUp;
                                            final (src, inq, rem) = _extractSourceInquiryAndRemarks(updatedAfterFollowUp);
                                            if (sourceController.text.trim().isEmpty) {
                                              sourceController.text = src;
                                            }
                                            inquiryController.text = inq;
                                            remarksController.text = rem;
                                          });
                                        }
                                      },
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFFF59E0B),
                                        side: const BorderSide(color: Color(0xFFF59E0B), width: 1.0),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      icon: const Icon(Icons.edit_calendar_rounded, size: 13),
                                      label: Text(
                                        currentDeal.postponedDate != null ? 'Reschedule' : 'Set Follow-up',
                                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),

                              if (stage == stageLost) ...[
                                Container(
                                  margin: const EdgeInsets.only(bottom: 14),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.cancel_outlined, color: Color(0xFFF87171), size: 18),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'DEAL LOSE REASON',
                                              style: TextStyle(
                                                color: Color(0xFFF87171),
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              currentDeal.adjournedReason?.trim().isNotEmpty == true
                                                  ? currentDeal.adjournedReason!
                                                  : 'No specific reason recorded',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      TextButton.icon(
                                        onPressed: () async {
                                          Navigator.pop(dialogCtx);
                                          await _promptLeadLostReason(currentDeal);
                                        },
                                        icon: const Icon(Icons.edit_note_rounded, size: 15, color: Color(0xFFF87171)),
                                        label: const Text(
                                          'Edit Reason',
                                          style: TextStyle(
                                            color: Color(0xFFF87171),
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],

                              // Form fields: Name and Phone
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _buildLeadDialogField(
                                      controller: nameController,
                                      label: 'Lead / Client Name',
                                      isRequired: true,
                                      hint: 'Enter client name',
                                      icon: Icons.person_rounded,
                                      validator: (val) => val == null || val.trim().isEmpty ? 'Enter name' : null,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: _buildLeadDialogField(
                                      controller: phoneController,
                                      label: 'Phone Number',
                                      isRequired: false,
                                      hint: 'Enter phone',
                                      icon: Icons.phone_rounded,
                                      keyboardType: TextInputType.phone,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),

                              // Place, Work Type, and Priority
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _buildLeadDialogField(
                                      controller: placeController,
                                      label: 'Place / Company',
                                      isRequired: false,
                                      hint: 'e.g. Kakkanad / ABC Corp',
                                      icon: Icons.location_on_rounded,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: _buildLeadDialogField(
                                      controller: workTypeController,
                                      label: 'Work / Service Type',
                                      isRequired: false,
                                      hint: 'e.g. GST Registration, License',
                                      icon: Icons.work_outline_rounded,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),

                              // Lead Source
                              _buildLeadDialogField(
                                controller: sourceController,
                                label: 'Lead Source',
                                isRequired: false,
                                hint: 'e.g. Meta Lead Ads, Direct Call, Referral, Walk-in...',
                                icon: Icons.campaign_rounded,
                              ),
                              const SizedBox(height: 7),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  'Meta Lead Ads',
                                  'Direct Call',
                                  'WhatsApp',
                                  'Client Referral',
                                  'Walk-in',
                                  'Website',
                                ].map((preset) => InkWell(
                                  onTap: () {
                                    setDialogState(() {
                                      sourceController.text = preset;
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF10121C),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: sourceController.text.trim() == preset
                                            ? AppTheme.primaryColor
                                            : const Color(0xFF282C3F),
                                      ),
                                    ),
                                    child: Text(
                                      preset,
                                      style: TextStyle(
                                        color: sourceController.text.trim() == preset
                                            ? AppTheme.primaryColor
                                            : Colors.white70,
                                        fontSize: 11,
                                        fontWeight: sourceController.text.trim() == preset ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                )).toList(),
                              ),
                              const SizedBox(height: 14),

                              // Priority Selector
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Priority',
                                    style: TextStyle(
                                      color: Color(0xFFE2E8F0),
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                  Row(
                                    children: ['Low', 'Normal', 'High', 'Urgent'].map((p) {
                                      final isSel = selectedPriority == p;
                                      final pCol = _priorityColor(p);
                                      return Padding(
                                        padding: const EdgeInsets.only(right: 8),
                                        child: ChoiceChip(
                                          label: Text(p),
                                          selected: isSel,
                                          onSelected: (val) {
                                            if (val) {
                                              setDialogState(() => selectedPriority = p);
                                            }
                                          },
                                          labelStyle: TextStyle(
                                            color: isSel ? Colors.black : Colors.white70,
                                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                            fontSize: 12,
                                          ),
                                          selectedColor: pCol,
                                          backgroundColor: const Color(0xFF10121C),
                                          side: BorderSide(
                                            color: isSel ? pCol : const Color(0xFF282C3F),
                                          ),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),

                              // 1. Inquiry Details (Multi-line)
                              _buildLeadDialogField(
                                controller: inquiryController,
                                label: 'Inquiry Details',
                                isRequired: false,
                                hint: 'Client requirements, questions, Meta ad form responses...',
                                icon: Icons.question_answer_outlined,
                                keyboardType: TextInputType.multiline,
                                minLines: 2,
                                maxLines: 5,
                              ),
                              const SizedBox(height: 14),

                              // 2. Remarks (Multi-line)
                              _buildLeadDialogField(
                                controller: remarksController,
                                label: 'Remarks',
                                isRequired: false,
                                hint: 'Staff discussion notes, follow-up remarks, callback summary...',
                                icon: Icons.rate_review_outlined,
                                keyboardType: TextInputType.multiline,
                                minLines: 2,
                                maxLines: 5,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // Footer actions
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                      decoration: const BoxDecoration(
                        color: Color(0xFF1B1D2C),
                        borderRadius: BorderRadius.only(
                          bottomLeft: Radius.circular(20),
                          bottomRight: Radius.circular(20),
                        ),
                        border: Border(
                          top: BorderSide(color: Color(0xFF282C3F), width: 1.0),
                        ),
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          // Stage Action buttons on the left
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (stage == stageCreated || stage == stageFollowUp) ...[
                                ElevatedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(dialogCtx);
                                    _showPassLeadDialog(currentDeal);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF16A34A),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    elevation: 2,
                                  ),
                                  icon: const Icon(Icons.check_circle_outline_rounded, size: 15),
                                  label: const Text('Pass to Work', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(dialogCtx);
                                    _markLeadAsLost(currentDeal);
                                  },
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFFEF4444),
                                    side: const BorderSide(color: Color(0xFFEF4444), width: 1.0),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.cancel_outlined, size: 14),
                                  label: const Text('Deal Lose', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                              ] else if (stage == stageLost) ...[
                                ElevatedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(dialogCtx);
                                    _reopenLead(currentDeal);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryColor,
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.replay_rounded, size: 15),
                                  label: const Text('Reopen Lead', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(dialogCtx);
                                    _promptLeadLostReason(currentDeal);
                                  },
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFFF87171),
                                    side: const BorderSide(color: Color(0xFFF87171), width: 1.0),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.edit_note_rounded, size: 14),
                                  label: const Text('Edit Lose Reason', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                              ] else if (stage == stagePassed) ...[
                                OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(dialogCtx);
                                    _openDealDetailScreen(currentDeal);
                                  },
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF38BDF8),
                                    side: const BorderSide(color: Color(0xFF38BDF8), width: 1.0),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.open_in_new_rounded, size: 14),
                                  label: const Text('Open Project Work', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                              ],
                            ],
                          ),

                          // Save & Close on the right
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                                style: TextButton.styleFrom(foregroundColor: const Color(0xFF94A3B8)),
                                child: const Text('Close'),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: isSaving
                                    ? null
                                    : () async {
                                        if (!formKey.currentState!.validate()) return;
                                        setDialogState(() => isSaving = true);
                                        final messenger = ScaffoldMessenger.of(context);
                                        try {
                                          final inq = inquiryController.text.trim();
                                          final rem = remarksController.text.trim();
                                          final String combinedDescription;
                                          if (inq.isNotEmpty && rem.isNotEmpty) {
                                            combinedDescription = '--- Inquiry Details ---\n$inq\n\n--- Remarks ---\n$rem';
                                          } else if (inq.isNotEmpty) {
                                            combinedDescription = inq;
                                          } else {
                                            combinedDescription = rem;
                                          }

                                          final updated = currentDeal.copyWith(
                                            name: nameController.text.trim(),
                                            clientName: nameController.text.trim(),
                                            contactInfo: phoneController.text.trim(),
                                            company: placeController.text.trim(),
                                            workType: workTypeController.text.trim(),
                                            referredBy: sourceController.text.trim(),
                                            description: combinedDescription,
                                            priority: selectedPriority,
                                            postponedDate: currentDeal.postponedDate,
                                            contactStatus: currentDeal.contactStatus,
                                            isAdjourned: currentDeal.isAdjourned,
                                            adjournedReason: currentDeal.adjournedReason,
                                          );
                                          await _dealService.updateDeal(updated);
                                          setDialogState(() {
                                            isSaving = false;
                                            currentDeal = updated;
                                          });
                                          // Update screen state immediately so board cards reflect changes
                                          if (mounted) {
                                            setState(() {
                                              final idx = _deals.indexWhere((d) => d.id?.toString() == updated.id?.toString());
                                              if (idx != -1) {
                                                _deals[idx] = updated;
                                              }
                                            });
                                          }
                                          messenger.showSnackBar(
                                            const SnackBar(
                                              content: Text('Lead details updated successfully!'),
                                              backgroundColor: Color(0xFF16A34A),
                                              duration: Duration(seconds: 2),
                                            ),
                                          );
                                          if (dialogCtx.mounted) {
                                            Navigator.pop(dialogCtx);
                                          }
                                        } catch (e) {
                                          setDialogState(() => isSaving = false);
                                          messenger.showSnackBar(
                                            SnackBar(
                                              content: Text('Failed to update lead: $e'),
                                              backgroundColor: Colors.redAccent,
                                            ),
                                          );
                                        }
                                      },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primaryColor,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  elevation: 2,
                                ),
                                icon: isSaving
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                                      )
                                    : const Icon(Icons.save_rounded, size: 15),
                                label: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
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
          },
        );
      },
    );
  }

  void _createNewDeal() {
    _showCreateLeadDialog();
  }

  Future<void> _showCreateLeadDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final placeController = TextEditingController();
    final workTypeController = TextEditingController();
    final sourceController = TextEditingController();
    final inquiryController = TextEditingController();
    final remarksController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isSaving = false;

    await showDialog(
      context: context,
      barrierDismissible: !isSaving,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: const Color(0xFF191B28),
              elevation: 24,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: const BorderSide(color: Color(0xFF2E334D), width: 1.2),
              ),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
                child: Form(
                  key: formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    AppTheme.primaryColor,
                                    AppTheme.primaryColor.withValues(alpha: 0.75),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppTheme.primaryColor.withValues(alpha: 0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.person_add_alt_1_rounded, color: Colors.black, size: 22),
                            ),
                            const SizedBox(width: 14),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'New Lead',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 19,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    'Create a new inquiry in CRM',
                                    style: TextStyle(
                                      color: Color(0xFF94A3B8),
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                              icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 20),
                              splashRadius: 20,
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        const Divider(color: Color(0xFF262A3C), height: 1),
                        const SizedBox(height: 20),

                        // 1. Name
                        _buildLeadDialogField(
                          controller: nameController,
                          label: 'Name',
                          isRequired: true,
                          hint: 'Client or contact person name',
                          icon: Icons.person_rounded,
                          validator: (val) {
                            if (val == null || val.trim().isEmpty) {
                              return 'Please enter name';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // 2. Phone Number
                        _buildLeadDialogField(
                          controller: phoneController,
                          label: 'Phone Number',
                          isRequired: true,
                          hint: 'Mobile or phone number',
                          icon: Icons.phone_rounded,
                          keyboardType: TextInputType.phone,
                          validator: (val) {
                            if (val == null || val.trim().isEmpty) {
                              return 'Please enter phone number';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // 3. Place
                        _buildLeadDialogField(
                          controller: placeController,
                          label: 'Place',
                          hint: 'City, town, or location',
                          icon: Icons.location_on_rounded,
                        ),
                        const SizedBox(height: 16),

                        // 4. Type of Work (Input box only!)
                        _buildLeadDialogField(
                          controller: workTypeController,
                          label: 'Type of Work',
                          hint: 'e.g. GST Registration, Trade License, Audit...',
                          icon: Icons.work_rounded,
                        ),
                        const SizedBox(height: 16),

                        // 5. Lead Source
                        _buildLeadDialogField(
                          controller: sourceController,
                          label: 'Lead Source',
                          hint: 'e.g. Meta Lead Ads, Direct Call, Referral, Walk-in...',
                          icon: Icons.campaign_rounded,
                        ),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            'Meta Lead Ads',
                            'Direct Call',
                            'WhatsApp',
                            'Client Referral',
                            'Walk-in',
                            'Website',
                          ].map((preset) => InkWell(
                            onTap: () {
                              setDialogState(() {
                                sourceController.text = preset;
                              });
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10121C),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: sourceController.text.trim() == preset
                                      ? AppTheme.primaryColor
                                      : const Color(0xFF282C3F),
                                ),
                              ),
                              child: Text(
                                preset,
                                style: TextStyle(
                                  color: sourceController.text.trim() == preset
                                      ? AppTheme.primaryColor
                                      : Colors.white70,
                                  fontSize: 11,
                                  fontWeight: sourceController.text.trim() == preset ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                          )).toList(),
                        ),
                        const SizedBox(height: 16),

                        // 6. Inquiry Details (Multi-line)
                        _buildLeadDialogField(
                          controller: inquiryController,
                          label: 'Inquiry Details',
                          hint: 'Client requirements, questions, or service details...',
                          icon: Icons.question_answer_outlined,
                          keyboardType: TextInputType.multiline,
                          minLines: 2,
                          maxLines: 4,
                        ),
                        const SizedBox(height: 16),

                        // 7. Remarks (Multi-line)
                        _buildLeadDialogField(
                          controller: remarksController,
                          label: 'Remarks',
                          hint: 'Discussion notes, callback instructions, or remarks...',
                          icon: Icons.rate_review_outlined,
                          keyboardType: TextInputType.multiline,
                          minLines: 2,
                          maxLines: 4,
                        ),
                        const SizedBox(height: 26),

                        // Buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton(
                              onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFCBD5E1),
                                side: const BorderSide(color: Color(0xFF333852)),
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton.icon(
                              onPressed: isSaving ? null : () async {
                                if (!formKey.currentState!.validate()) return;
                                setDialogState(() => isSaving = true);
                                final messenger = ScaffoldMessenger.of(context);
                                try {
                                  final enteredName = nameController.text.trim();
                                  final enteredWorkType = workTypeController.text.trim().isNotEmpty
                                      ? workTypeController.text.trim()
                                      : 'General Work';
                                  final inq = inquiryController.text.trim();
                                  final rem = remarksController.text.trim();
                                  final String combinedDescription;
                                  if (inq.isNotEmpty && rem.isNotEmpty) {
                                    combinedDescription = '--- Inquiry Details ---\n$inq\n\n--- Remarks ---\n$rem';
                                  } else if (inq.isNotEmpty) {
                                    combinedDescription = inq;
                                  } else {
                                    combinedDescription = rem;
                                  }

                                  final newLead = Deal(
                                    name: enteredName,
                                    clientName: enteredName,
                                    contactInfo: phoneController.text.trim(),
                                    company: placeController.text.trim(),
                                    workType: enteredWorkType,
                                    referredBy: sourceController.text.trim(),
                                    description: combinedDescription,
                                    pipeline: 'CRM',
                                    stage: stageCreated,
                                    priority: 'Normal',
                                    amount: 0.0,
                                    currency: 'INR',
                                    isWon: false,
                                  );

                                  await _dealService.createDeal(newLead);

                                  if (dialogCtx.mounted) {
                                    Navigator.pop(dialogCtx);
                                  }

                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text('Lead "$enteredName" created successfully!'),
                                      backgroundColor: const Color(0xFF16A34A),
                                    ),
                                  );
                                } catch (e) {
                                  setDialogState(() => isSaving = false);
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text('Failed to create lead: $e'),
                                      backgroundColor: Colors.redAccent,
                                    ),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryColor,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                elevation: 3,
                              ),
                              icon: isSaving
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                                    )
                                  : const Icon(Icons.check_rounded, size: 18),
                              label: Text(
                                isSaving ? 'Saving...' : 'Create Lead',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLeadDialogField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool isRequired = false,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    int? minLines,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
            if (isRequired)
              const Text(
                ' *',
                style: TextStyle(
                  color: AppTheme.primaryColor,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
        const SizedBox(height: 7),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: maxLines,
          minLines: minLines,
          validator: validator,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
            prefixIcon: Icon(icon, color: AppTheme.primaryColor.withValues(alpha: 0.85), size: 18),
            filled: true,
            fillColor: const Color(0xFF10121C),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF282C3F), width: 1.0),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.redAccent, width: 1.0),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showPassLeadDialog(Deal deal) async {
    final clientNameController = TextEditingController(
      text: deal.clientName?.isNotEmpty == true ? deal.clientName : deal.name,
    );
    final contactController = TextEditingController(text: deal.contactInfo ?? '');
    final workNameController = TextEditingController(text: deal.name);
    final workTypeController = TextEditingController(text: deal.workType ?? 'General Work');
    final amountController = TextEditingController(
      text: deal.amount > 0 ? deal.amount.toInt().toString() : '',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Colors.white12),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF16A34A).withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.verified, color: Color(0xFF4ADE80), size: 24),
            ),
            const SizedBox(width: 12),
            const Text(
              'Pass Lead to Work & Client',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 20, color: Colors.blueAccent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Passing this lead will automatically register the client in Client Management and activate this project in Work Management.',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade200),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: clientNameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Client Name *',
                  labelStyle: const TextStyle(color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF16A34A)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contactController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Contact Phone / Email',
                  labelStyle: const TextStyle(color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF16A34A)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: workNameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Work Name *',
                  labelStyle: const TextStyle(color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF16A34A)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: workTypeController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Work Type',
                        labelStyle: const TextStyle(color: Colors.white70),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF16A34A)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: amountController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Amount (₹)',
                        labelStyle: const TextStyle(color: Colors.white70),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF16A34A)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check_circle, size: 18),
            label: const Text('Confirm & Pass to Work', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        final client = await _clientService.getOrCreateClientForLead(
          clientName: clientNameController.text.trim().isNotEmpty
              ? clientNameController.text.trim()
              : (deal.clientName ?? deal.name),
          phone: contactController.text.trim(),
          typeOfWork: workTypeController.text.trim(),
        );

        final updatedDeal = deal.copyWith(
          name: workNameController.text.trim(),
          clientId: int.tryParse(client.id) ?? deal.clientId,
          clientName: client.name ?? clientNameController.text.trim(),
          contactInfo: contactController.text.trim(),
          workType: workTypeController.text.trim(),
          amount: double.tryParse(amountController.text) ?? deal.amount,
          pipeline: 'CRM',
          isWon: true,
          stage: stagePassed,
          closedAt: DateTime.now(),
        );

        await _dealService.passLeadToWork(
          lead: updatedDeal,
          clientId: client.id,
          clientName: client.name ?? clientNameController.text.trim(),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Lead "${updatedDeal.name}" passed to Work Management and registered in Client Management!',
              ),
              backgroundColor: const Color(0xFF16A34A),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error passing lead: $e'), backgroundColor: Colors.red),
          );
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _promptLeadLostReason(Deal deal) async {
    final reasonController = TextEditingController(text: deal.adjournedReason ?? '');
    String selectedChip = deal.adjournedReason ?? '';
    final isAlreadyLost = getCrmStage(deal) == stageLost;
    final quickReasons = [
      'Not Interested / Dropped',
      'Price Too High / Budget Issue',
      'Competitor Chosen',
      'Plan Postponed / Not Ready',
      'Out of Service Area',
      'No Response / Invalid Number',
    ];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF181A2A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: const Color(0xFFEF4444).withValues(alpha: 0.5), width: 1.2),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.cancel_outlined, color: Color(0xFFF87171), size: 20),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isAlreadyLost ? 'Edit Deal Lose Reason' : 'Mark as Deal Lose',
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select or enter the reason why lead "${deal.name}" was lost:',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 14),
                    const Text('Quick Reasons:', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: quickReasons.map((r) {
                        final isSel = selectedChip == r || reasonController.text == r;
                        return ChoiceChip(
                          label: Text(
                            r,
                            style: TextStyle(
                              fontSize: 11,
                              color: isSel ? Colors.white : Colors.white70,
                              fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          selected: isSel,
                          selectedColor: const Color(0xFFEF4444).withValues(alpha: 0.35),
                          backgroundColor: const Color(0xFF222638),
                          side: BorderSide(
                            color: isSel ? const Color(0xFFEF4444) : const Color(0xFF363C54),
                          ),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          onSelected: (sel) {
                            setDialogState(() {
                              selectedChip = sel ? r : '';
                              if (sel) reasonController.text = r;
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: reasonController,
                      maxLines: 3,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Enter specific reason or notes for losing this deal...',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                        filled: true,
                        fillColor: const Color(0xFF10121C),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFF282C3F)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFF282C3F)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFFEF4444)),
                        ),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx, false),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                ),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(dialogCtx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: Text(
                    isAlreadyLost ? 'Save Reason' : 'Confirm Deal Lose',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true) {
      final reason = reasonController.text.trim();
      final updatedDeal = deal.copyWith(
        stage: stageLost,
        isWon: false,
        isAdjourned: true,
        adjournedReason: reason.isNotEmpty ? reason : 'Unspecified',
      );
      await _dealService.updateDeal(updatedDeal);
      if (mounted) {
        setState(() {
          final idx = _deals.indexWhere((d) => d.id?.toString() == updatedDeal.id?.toString());
          if (idx != -1) _deals[idx] = updatedDeal;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isAlreadyLost
                ? 'Reason for "${deal.name}" saved: ${reason.isNotEmpty ? reason : "Unspecified"}'
                : 'Lead "${deal.name}" moved to Deal Lose: ${reason.isNotEmpty ? reason : "Marked Lost"}'),
            backgroundColor: const Color(0xFFEF4444),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _markLeadAsLost(Deal deal, {String? reason}) async {
    if (reason == null) {
      await _promptLeadLostReason(deal);
      return;
    }
    final updatedDeal = deal.copyWith(
      stage: stageLost,
      isWon: false,
      isAdjourned: true,
      adjournedReason: reason,
    );
    await _dealService.updateDeal(updatedDeal);
    if (mounted) {
      setState(() {
        final idx = _deals.indexWhere((d) => d.id?.toString() == updatedDeal.id?.toString());
        if (idx != -1) _deals[idx] = updatedDeal;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lead "${deal.name}" moved to Deal Lose: $reason'),
          backgroundColor: const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _moveToFollowUp(Deal deal) async {
    if (deal.postponedDate == null) {
      await _showFollowUpDialog(deal);
    } else {
      final updatedDeal = deal.copyWith(
        stage: stageFollowUp,
      );
      await _dealService.updateDeal(updatedDeal);
      if (mounted) {
        setState(() {
          final idx = _deals.indexWhere((d) => d.id?.toString() == updatedDeal.id?.toString());
          if (idx != -1) _deals[idx] = updatedDeal;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lead "${deal.name}" moved to Follow-ups'),
            backgroundColor: const Color(0xFFF59E0B),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _reopenLead(Deal deal) async {
    final updatedDeal = deal.copyWith(
      stage: stageCreated,
      isWon: false,
      isAdjourned: false,
      clearPostponedDate: true,
      clearAdjournedReason: true,
    );
    await _dealService.updateDeal(updatedDeal);
    if (mounted) {
      setState(() {
        final idx = _deals.indexWhere((d) => d.id?.toString() == updatedDeal.id?.toString());
        if (idx != -1) _deals[idx] = updatedDeal;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lead "${deal.name}" moved back to Created'),
          backgroundColor: const Color(0xFF38BDF8),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openWhatsApp(String phone, String name) async {
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanPhone.isEmpty) return;
    final formattedPhone = cleanPhone.length == 10 ? '91$cleanPhone' : cleanPhone;
    final defaultMessage =
        'Hello $name, this is regarding your inquiry with Cochin United Consultancy.';

    final cfg = await MetaConfig.load();
    if (cfg.preferCloudApi &&
        cfg.whatsappPhoneNumberId.isNotEmpty &&
        cfg.accessToken.isNotEmpty) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (dialogCtx) {
          final msgCtrl = TextEditingController(text: defaultMessage);
          bool isSending = false;
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              return AlertDialog(
                backgroundColor: const Color(0xFF181A2A),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: Row(
                  children: [
                    const Icon(Icons.chat_rounded, color: Color(0xFF25D366)),
                    const SizedBox(width: 8),
                    Text('Send WhatsApp to $name',
                        style: const TextStyle(color: Colors.white, fontSize: 16)),
                  ],
                ),
                content: SizedBox(
                  width: 480,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.business_rounded, size: 14, color: Color(0xFF25D366)),
                            const SizedBox(width: 6),
                            const Text(
                              'Sender: CUC Official (+91 73064 25378)',
                              style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500),
                            ),
                            const Spacer(),
                            Text(
                              'To: +$formattedPhone',
                              style: const TextStyle(color: Colors.white54, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text('Quick Templates:', style: TextStyle(color: Colors.white60, fontSize: 11)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _buildQuickReplyChip('👋 Intro', 'Hello $name, this is regarding your inquiry with Cochin United Consultancy. How may we assist you today?', msgCtrl, setDialogState),
                          _buildQuickReplyChip('📋 Valuation', 'Hello $name, regarding your property valuation request, could you please confirm the exact location and land/building area?', msgCtrl, setDialogState),
                          _buildQuickReplyChip('📄 Documents', 'Hello $name, to proceed with your file at Cochin United Consultancy, please share a copy of your title deed and tax receipt.', msgCtrl, setDialogState),
                          _buildQuickReplyChip('⏰ Follow-up', 'Hello $name, following up on our previous discussion regarding your CUC consultancy service. Please let us know if you need any clarification.', msgCtrl, setDialogState),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: msgCtrl,
                        maxLines: 4,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFF242738),
                          hintText: 'Type your message...',
                          hintStyle: const TextStyle(color: Colors.white38),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 14, color: Colors.white70),
                    label: const Text('Open App (wa.me)',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                    onPressed: () {
                      Navigator.pop(dialogCtx);
                      WhatsAppCloudService.launchWhatsAppApp(
                          phone: formattedPhone, message: msgCtrl.text);
                    },
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366)),
                    icon: isSending
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send_rounded, color: Colors.white, size: 14),
                    label: Text(isSending ? 'Sending...' : 'Send Cloud API',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                    onPressed: isSending
                        ? null
                        : () async {
                            setDialogState(() => isSending = true);
                            final res = await WhatsAppCloudService().sendMessage(
                              toPhone: formattedPhone,
                              message: msgCtrl.text,
                            );
                            if (dialogCtx.mounted) {
                              Navigator.pop(dialogCtx);
                            }
                            if (mounted) {
                              if (res.success) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                        'WhatsApp message sent successfully via Meta Cloud API!'),
                                    backgroundColor: Color(0xFF10B981),
                                  ),
                                );
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                        'Cloud API failed: ${res.error}. Opening WhatsApp app...'),
                                    backgroundColor: const Color(0xFFEF4444),
                                  ),
                                );
                                WhatsAppCloudService.launchWhatsAppApp(
                                    phone: formattedPhone, message: msgCtrl.text);
                              }
                            }
                          },
                  ),
                ],
              );
            },
          );
        },
      );
      return;
    }

    // Default fallback to direct WhatsApp app launch
    await WhatsAppCloudService.launchWhatsAppApp(
        phone: formattedPhone, message: defaultMessage);
  }

  Widget _buildQuickReplyChip(
    String label,
    String text,
    TextEditingController controller,
    StateSetter setDialogState,
  ) {
    return InkWell(
      onTap: () {
        setDialogState(() {
          controller.text = text;
        });
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF25D366).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF25D366).withValues(alpha: 0.3)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFF25D366),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Future<void> _makePhoneCall(String phone) async {
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (cleanPhone.isEmpty) return;
    final url = Uri.parse('tel:$cleanPhone');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      await Clipboard.setData(ClipboardData(text: phone));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Phone number $phone copied to clipboard'),
            backgroundColor: const Color(0xFF38BDF8),
          ),
        );
      }
    }
  }

  Widget _buildFollowUpBadge(DateTime followUpDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(followUpDate.year, followUpDate.month, followUpDate.day);
    final isOverdue = target.isBefore(today);
    final isToday = target.isAtSameMomentAs(today);

    final Color badgeColor = isOverdue
        ? const Color(0xFFEF4444)
        : isToday
            ? const Color(0xFFF59E0B)
            : const Color(0xFF38BDF8);

    final String text = isOverdue
        ? 'Overdue: ${DateFormat('dd MMM').format(followUpDate)}'
        : isToday
            ? 'Follow-up Today'
            : 'Follow-up: ${DateFormat('dd MMM').format(followUpDate)}';

    final IconData icon = isOverdue
        ? Icons.error_outline_rounded
        : isToday
            ? Icons.notifications_active_rounded
            : Icons.event_available_rounded;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: badgeColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: badgeColor),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: badgeColor,
              fontSize: 10.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactStatusBadge(String status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.purpleAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.record_voice_over_rounded, size: 10, color: Colors.purpleAccent),
          const SizedBox(width: 4),
          Text(
            status,
            style: const TextStyle(
              color: Colors.purpleAccent,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickDateChip({
    required String label,
    required DateTime date,
    required DateTime? selectedDate,
    required VoidCallback onSelect,
  }) {
    final isSelected = selectedDate != null &&
        selectedDate.year == date.year &&
        selectedDate.month == date.month &&
        selectedDate.day == date.day;

    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFF59E0B).withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? const Color(0xFFF59E0B) : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFFF59E0B) : Colors.white70,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Future<Deal?> _showFollowUpDialog(Deal deal) async {
    Deal? savedResult;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime? selectedDate = deal.postponedDate != null
        ? DateTime(deal.postponedDate!.year, deal.postponedDate!.month, deal.postponedDate!.day)
        : today;
    TimeOfDay selectedTime = deal.postponedDate != null
        ? TimeOfDay(hour: deal.postponedDate!.hour, minute: deal.postponedDate!.minute)
        : TimeOfDay(hour: (now.minute > 30 ? (now.hour + 1) % 24 : now.hour), minute: (now.minute > 30 ? 0 : 30));
    String selectedStatus = deal.contactStatus ?? 'Follow-up Scheduled';
    final noteController = TextEditingController();
    bool isSaving = false;

    final statuses = [
      'Follow-up Scheduled',
      'Interested',
      'Callback Requested',
      'Documents Pending',
      'Quotation Sent',
      'Meeting Scheduled',
      'No Answer / Busy',
      'Call Back Later',
    ];

    await showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final nowInner = DateTime.now();
            final todayInner = DateTime(nowInner.year, nowInner.month, nowInner.day);

            DateTime? combinedDateTime;
            if (selectedDate != null) {
              combinedDateTime = DateTime(
                selectedDate!.year,
                selectedDate!.month,
                selectedDate!.day,
                selectedTime.hour,
                selectedTime.minute,
              );
            }

            String relativeTimeStr = '';
            if (combinedDateTime != null) {
              final diffMinutes = combinedDateTime.difference(nowInner).inMinutes;
              if (diffMinutes < 0) {
                relativeTimeStr = 'Overdue by ${-diffMinutes} min';
              } else if (diffMinutes == 0) {
                relativeTimeStr = 'Due right now';
              } else if (diffMinutes < 60) {
                relativeTimeStr = 'in $diffMinutes min';
              } else {
                final diffHours = (diffMinutes / 60).round();
                if (diffHours < 24) {
                  relativeTimeStr = 'in ~$diffHours hrs';
                } else {
                  final diffDays = (diffHours / 24).round();
                  relativeTimeStr = 'in $diffDays days';
                }
              }
            }

            return Dialog(
              backgroundColor: const Color(0xFF161622),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.alarm_add_rounded, color: Color(0xFFF59E0B), size: 22),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Set Live Follow-up & Reminder',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16.5,
                                    ),
                                  ),
                                  Text(
                                    deal.name,
                                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(dialogCtx),
                              icon: const Icon(Icons.close_rounded, color: Colors.white38),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Quick Call & WhatsApp banner if phone exists
                        if (deal.contactInfo != null && deal.contactInfo!.trim().isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.phone_outlined, color: Colors.white38, size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    deal.contactInfo!,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _openWhatsApp(deal.contactInfo!, deal.name),
                                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: Color(0xFF22C55E)),
                                  tooltip: 'WhatsApp Client',
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  padding: EdgeInsets.zero,
                                ),
                                const SizedBox(width: 6),
                                IconButton(
                                  onPressed: () => _makePhoneCall(deal.contactInfo!),
                                  icon: const Icon(Icons.call_outlined, size: 18, color: Color(0xFF38BDF8)),
                                  tooltip: 'Call Client',
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  padding: EdgeInsets.zero,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // 1. Follow-up Date
                        const Text(
                          '1. Follow-up Date',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _buildQuickDateChip(
                              label: 'Today',
                              date: todayInner,
                              selectedDate: selectedDate,
                              onSelect: () => setDialogState(() => selectedDate = todayInner),
                            ),
                            _buildQuickDateChip(
                              label: 'Tomorrow',
                              date: todayInner.add(const Duration(days: 1)),
                              selectedDate: selectedDate,
                              onSelect: () => setDialogState(() => selectedDate = todayInner.add(const Duration(days: 1))),
                            ),
                            _buildQuickDateChip(
                              label: 'In 3 Days',
                              date: todayInner.add(const Duration(days: 3)),
                              selectedDate: selectedDate,
                              onSelect: () => setDialogState(() => selectedDate = todayInner.add(const Duration(days: 3))),
                            ),
                            _buildQuickDateChip(
                              label: 'In 1 Week',
                              date: todayInner.add(const Duration(days: 7)),
                              selectedDate: selectedDate,
                              onSelect: () => setDialogState(() => selectedDate = todayInner.add(const Duration(days: 7))),
                            ),
                            InkWell(
                              onTap: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: selectedDate ?? todayInner,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2035),
                                );
                                if (picked != null) {
                                  setDialogState(() => selectedDate = picked);
                                }
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.calendar_month_rounded, size: 13, color: Colors.white70),
                                    SizedBox(width: 4),
                                    Text('Custom Date', style: TextStyle(color: Colors.white70, fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 16),

                        // 2. Follow-up Time
                        const Text(
                          '2. Reminder Time (Live Auto-Trigger)',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            // Quick relative time options
                            _buildQuickTimeChip(
                              label: 'In 15 Min',
                              isSelected: false,
                              onSelect: () {
                                final target = nowInner.add(const Duration(minutes: 15));
                                setDialogState(() {
                                  selectedDate = todayInner;
                                  selectedTime = TimeOfDay(hour: target.hour, minute: target.minute);
                                });
                              },
                            ),
                            _buildQuickTimeChip(
                              label: 'In 30 Min',
                              isSelected: false,
                              onSelect: () {
                                final target = nowInner.add(const Duration(minutes: 30));
                                setDialogState(() {
                                  selectedDate = todayInner;
                                  selectedTime = TimeOfDay(hour: target.hour, minute: target.minute);
                                });
                              },
                            ),
                            _buildQuickTimeChip(
                              label: 'In 1 Hour',
                              isSelected: false,
                              onSelect: () {
                                final target = nowInner.add(const Duration(hours: 1));
                                setDialogState(() {
                                  selectedDate = target.day != nowInner.day ? todayInner.add(const Duration(days: 1)) : todayInner;
                                  selectedTime = TimeOfDay(hour: target.hour, minute: target.minute);
                                });
                              },
                            ),
                            _buildQuickTimeChip(
                              label: '10:00 AM',
                              isSelected: selectedTime.hour == 10 && selectedTime.minute == 0,
                              onSelect: () => setDialogState(() => selectedTime = const TimeOfDay(hour: 10, minute: 0)),
                            ),
                            _buildQuickTimeChip(
                              label: '02:30 PM',
                              isSelected: selectedTime.hour == 14 && selectedTime.minute == 30,
                              onSelect: () => setDialogState(() => selectedTime = const TimeOfDay(hour: 14, minute: 30)),
                            ),
                            _buildQuickTimeChip(
                              label: '05:00 PM',
                              isSelected: selectedTime.hour == 17 && selectedTime.minute == 0,
                              onSelect: () => setDialogState(() => selectedTime = const TimeOfDay(hour: 17, minute: 0)),
                            ),
                            InkWell(
                              onTap: () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: selectedTime,
                                );
                                if (picked != null) {
                                  setDialogState(() => selectedTime = picked);
                                }
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.access_time_rounded, size: 13, color: Colors.white70),
                                    const SizedBox(width: 4),
                                    Text(
                                      selectedTime.format(context),
                                      style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 12, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),

                        if (combinedDateTime != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.alarm_on_rounded, size: 18, color: Color(0xFFF59E0B)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Reminder set: ${DateFormat('EEE, dd MMM yyyy • hh:mm a').format(combinedDateTime)}',
                                        style: const TextStyle(color: Color(0xFFF59E0B), fontSize: 12.5, fontWeight: FontWeight.bold),
                                      ),
                                      if (relativeTimeStr.isNotEmpty)
                                        Text(
                                          'Alert will pop up automatically $relativeTimeStr (live, no refresh needed)',
                                          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11),
                                        ),
                                    ],
                                  ),
                                ),
                                InkWell(
                                  onTap: () => setDialogState(() => selectedDate = null),
                                  child: const Icon(Icons.close_rounded, size: 16, color: Colors.white54),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 18),

                        // Status / Disposition
                        const Text(
                          '3. Lead / Contact Status',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: statuses.contains(selectedStatus) ? selectedStatus : statuses.first,
                              isExpanded: true,
                              dropdownColor: const Color(0xFF1E1E2D),
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              icon: const Icon(Icons.arrow_drop_down, color: Colors.white38),
                              items: statuses
                                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) {
                                  setDialogState(() => selectedStatus = v);
                                }
                              },
                            ),
                          ),
                        ),

                        const SizedBox(height: 18),

                        // Follow-up Notes
                        const Text(
                          '4. Add Remark / Note',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: noteController,
                          maxLines: 3,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'What did the client say? What is the callback discussion?',
                            hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.04),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: AppTheme.primaryColor),
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Action buttons
                        Row(
                          children: [
                            if (deal.postponedDate != null)
                              OutlinedButton.icon(
                                onPressed: isSaving
                                    ? null
                                    : () async {
                                        setDialogState(() => isSaving = true);
                                        final updated = deal.copyWith(
                                          clearPostponedDate: true,
                                        );
                                        await _dealService.updateDeal(updated);
                                        _notifiedReminderDealIds.remove(deal.id?.toString());
                                        _escalatedToAdminDealIds.remove(deal.id?.toString());
                                        savedResult = updated;
                                        if (mounted) {
                                          setState(() {
                                            final idx = _deals.indexWhere((d) => d.id?.toString() == updated.id?.toString());
                                            if (idx != -1) _deals[idx] = updated;
                                          });
                                        }
                                        if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                                      },
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFFEF4444),
                                  side: BorderSide(color: const Color(0xFFEF4444).withValues(alpha: 0.3)),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                icon: const Icon(Icons.check_circle_outline, size: 14),
                                label: const Text('Mark Done', style: TextStyle(fontSize: 12)),
                              ),
                            const Spacer(),
                            TextButton(
                              onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
                              style: TextButton.styleFrom(foregroundColor: Colors.white60),
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(width: 10),
                            ElevatedButton.icon(
                              onPressed: isSaving
                                  ? null
                                  : () async {
                                      setDialogState(() => isSaving = true);
                                      final note = noteController.text.trim();
                                      final (extractedSource, inqDetails, existingRemarks) = _extractSourceInquiryAndRemarks(deal);
                                      String updatedRemarks = existingRemarks;
                                      if (note.isNotEmpty) {
                                        final timestamp = DateFormat('dd MMM, hh:mm a').format(DateTime.now());
                                        final prefix = updatedRemarks.trim().isNotEmpty
                                            ? '$updatedRemarks\n\n'
                                            : '';
                                        updatedRemarks = '$prefix[$timestamp - Follow-up] $note';
                                      }

                                      final String finalDesc;
                                      if (inqDetails.isNotEmpty && updatedRemarks.isNotEmpty) {
                                        finalDesc = '--- Inquiry Details ---\n$inqDetails\n\n--- Remarks ---\n$updatedRemarks';
                                      } else if (inqDetails.isNotEmpty) {
                                        finalDesc = inqDetails;
                                      } else {
                                        finalDesc = updatedRemarks;
                                      }

                                      final updated = deal.copyWith(
                                        referredBy: deal.referredBy?.trim().isNotEmpty == true
                                            ? deal.referredBy
                                            : (extractedSource.isNotEmpty ? extractedSource : null),
                                        postponedDate: combinedDateTime,
                                        contactStatus: selectedStatus,
                                        description: finalDesc.isNotEmpty ? finalDesc : null,
                                      );

                                      // Re-arm reminder so it triggers automatically live
                                      if (deal.id != null) {
                                        _notifiedReminderDealIds.remove(deal.id.toString());
                                        _escalatedToAdminDealIds.remove(deal.id.toString());
                                      }

                                      await _dealService.updateDeal(updated);
                                      savedResult = updated;

                                      // Immediate local update so no refresh is needed
                                      if (mounted) {
                                        setState(() {
                                          final idx = _deals.indexWhere((d) => d.id?.toString() == deal.id?.toString());
                                          if (idx != -1) {
                                            _deals[idx] = updated;
                                          }
                                        });
                                      }

                                      if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                                      if (context.mounted) {
                                        final dateFormatted = combinedDateTime != null
                                            ? DateFormat('dd MMM, hh:mm a').format(combinedDateTime)
                                            : 'cleared';
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('Follow-up scheduled for $dateFormatted — live reminder active!'),
                                            backgroundColor: const Color(0xFF16A34A),
                                          ),
                                        );
                                      }
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryColor,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: isSaving
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                                  : const Icon(Icons.alarm_on_rounded, size: 16),
                              label: Text(
                                isSaving ? 'Saving...' : 'Set Reminder',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    return savedResult;
  }

  Widget _buildQuickTimeChip({
    required String label,
    required bool isSelected,
    required VoidCallback onSelect,
  }) {
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF38BDF8).withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? const Color(0xFF38BDF8) : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF38BDF8) : Colors.white70,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Future<void> _showImportToCrmDialog() async {
    final nonCrm = _deals
        .where((d) => d.pipeline.toLowerCase() != 'crm' && d.pipeline.toLowerCase() != 'lead')
        .toList();

    if (nonCrm.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No works available to import.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Colors.white12),
        ),
        title: const Text(
          'Import Existing Work to CRM',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        content: SizedBox(
          width: 500,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select an existing project to manage in the separate CRM lead pipeline:',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: nonCrm.length,
                  itemBuilder: (c, idx) {
                    final d = nonCrm[idx];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: ListTile(
                        title: Text(
                          d.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          '${d.clientName ?? 'No client'} • ${d.stage} • ₹${d.amount}',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryColor,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            minimumSize: Size.zero,
                          ),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            final updated = d.copyWith(pipeline: 'CRM');
                            await _dealService.updateDeal(updated);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Transferred "${d.name}" to CRM Lead pipeline!'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            }
                          },
                          child: const Text(
                            'Import to CRM',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  Future<void> _directImportSheetLeads() async {
    final pending = CrmDataImporter.getPending(_deals);
    if (pending.isEmpty) return;

    setState(() {
      _isBatchImporting = true;
      _batchImportStatus = 'Adding 0 of ${pending.length} leads to CRM...';
    });

    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await CrmDataImporter.importPending(
        dealService: _dealService,
        existingDeals: _deals,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _batchImportStatus = 'Adding $done of $total leads to CRM...';
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _isBatchImporting = false;
          _batchImportStatus = '';
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text('Successfully added $count inquiry leads to CRM!'),
            backgroundColor: const Color(0xFF16A34A),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isBatchImporting = false;
          _batchImportStatus = '';
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text('Import error: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _showImportSheetDialog() async {
    final pending = CrmDataImporter.getPending(_deals);
    if (pending.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All 23 October inquiry leads are already in CRM!'),
          backgroundColor: Color(0xFF16A34A),
        ),
      );
      return;
    }

    bool isImporting = false;
    String progressText = 'Ready to import ${pending.length} leads';
    double progressValue = 0.0;

    await showDialog(
      context: context,
      barrierDismissible: !isImporting,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: const Color(0xFF191B28),
              elevation: 24,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFF2E334D), width: 1.2),
              ),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 580, maxHeight: 600),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEAB308).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFEAB308).withValues(alpha: 0.3)),
                          ),
                          child: const Icon(Icons.table_view_rounded, color: Color(0xFFFACC15), size: 22),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Import Inquiry Register (${pending.length} Leads)',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                'October 2026 Register • Will be added to Active CRM Leads',
                                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: isImporting ? null : () => Navigator.pop(dialogCtx),
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Divider(color: Color(0xFF262A3C), height: 1),
                    const SizedBox(height: 12),
                    if (isImporting) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Column(
                          children: [
                            LinearProgressIndicator(
                              value: progressValue > 0 ? progressValue : null,
                              backgroundColor: const Color(0xFF262A3C),
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFEAB308)),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              progressText,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Writing to CRM database and disaster recovery backup...',
                              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      Expanded(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: pending.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (ctx, idx) {
                            final item = pending[idx];
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF121420),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFF262A3C)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.blueAccent.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      item['date'] ?? '',
                                      style: const TextStyle(
                                        color: Colors.lightBlueAccent,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              item['name'] ?? '',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13.5,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              item['phone'] ?? '',
                                              style: const TextStyle(
                                                color: Color(0xFF94A3B8),
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          item['requirement'] ?? '',
                                          style: const TextStyle(
                                            color: Color(0xFFFACC15),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (item['remark']?.isNotEmpty == true) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            item['remark']!,
                                            style: const TextStyle(
                                              color: Color(0xFF64748B),
                                              fontSize: 11,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFEAB308),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.cloud_upload_rounded, size: 18),
                            label: Text(
                              'Import All (${pending.length}) Leads',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            onPressed: () async {
                              setDialogState(() {
                                isImporting = true;
                                progressText = 'Importing 0 of ${pending.length}...';
                                progressValue = 0.0;
                              });

                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                final count = await CrmDataImporter.importPending(
                                  dealService: _dealService,
                                  existingDeals: _deals,
                                  onProgress: (done, total) {
                                    setDialogState(() {
                                      progressText = 'Importing $done of $total leads...';
                                      progressValue = done / total;
                                    });
                                  },
                                );

                                if (dialogCtx.mounted) {
                                  Navigator.pop(dialogCtx);
                                }

                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text('Successfully added $count leads to CRM!'),
                                    backgroundColor: const Color(0xFF16A34A),
                                  ),
                                );
                              } catch (e) {
                                setDialogState(() => isImporting = false);
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text('Failed during import: $e'),
                                    backgroundColor: Colors.redAccent,
                                  ),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildImportBanner() {
    final pending = CrmDataImporter.getPending(_deals);
    if (pending.isEmpty && !_isBatchImporting) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFEAB308).withValues(alpha: 0.16),
            const Color(0xFFCA8A04).withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEAB308).withValues(alpha: 0.45)),
      ),
      child: _isBatchImporting
          ? Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: Color(0xFFFACC15)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    _batchImportStatus.isNotEmpty
                        ? _batchImportStatus
                        : 'Importing leads into CRM...',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5),
                  ),
                ),
              ],
            )
          : Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAB308).withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.cloud_download_rounded, color: Color(0xFFFACC15), size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${pending.length} October Inquiries Ready to Add to CRM',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Leads from registration sheet (${pending.take(3).map((e) => e['name']).join(', ')}${pending.length > 3 ? ', +${pending.length - 3} more' : ''})',
                        style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _showImportSheetDialog,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFACC15),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  child: const Text('Review List', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _directImportSheetLeads,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEAB308),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.add_task_rounded, size: 16),
                  label: Text(
                    'Add All (${pending.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                  ),
                ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D12),
      body: Column(
        children: [
          _buildHeader(),
          _buildImportBanner(),
          _buildTabBar(),
          Expanded(
            child: _isLoading
                ? _buildLoadingState()
                : _errorMessage != null
                    ? _buildErrorState()
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildKanbanBoard(),
                          _buildDealsListTab(),
                          _buildAnalyticsTab(),
                        ],
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewDeal,
        backgroundColor: AppTheme.primaryColor,
        icon: const Icon(Icons.add_rounded, color: Colors.black),
        label: const Text(
          'New Lead',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF13131A),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
                tooltip: 'Back to Dashboard',
                onPressed: () {
                  if (widget.onBack != null) {
                    widget.onBack!();
                  } else if (Navigator.canPop(context)) {
                    Navigator.pop(context);
                  }
                },
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  hoverColor: Colors.white.withValues(alpha: 0.16),
                  padding: const EdgeInsets.all(10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.primaryColor.withValues(alpha: 0.3),
                  ),
                ),
                child: Icon(Icons.hub_rounded, color: AppTheme.primaryColor, size: 22),
              ),
              const SizedBox(width: 14),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CRM',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    'Customer Relationship & Lead Management',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
              const Spacer(),
              _buildStatBadge('Created', _createdDeals.length.toString(), const Color(0xFF38BDF8)),
              const SizedBox(width: 8),
              _buildStatBadge('Follow-ups', _followUpDeals.length.toString(), const Color(0xFFF59E0B)),
              const SizedBox(width: 8),
              _buildStatBadge('Passed to Work', _passedDeals.length.toString(), const Color(0xFF4ADE80)),
              const SizedBox(width: 8),
              _buildStatBadge('Deal Lose', _lostDeals.length.toString(), const Color(0xFFF87171)),
              if (_followUpTodayDeals.isNotEmpty) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    setState(() {
                      _selectedFollowUpFilter = _selectedFollowUpFilter == 'Due Today' ? 'All' : 'Due Today';
                    });
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: _buildStatBadge(
                    'Follow-up Today',
                    _followUpTodayDeals.length.toString(),
                    const Color(0xFFF59E0B),
                    isActive: _selectedFollowUpFilter == 'Due Today',
                  ),
                ),
              ],
              if (_overdueDeals.isNotEmpty) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    setState(() {
                      _selectedFollowUpFilter = _selectedFollowUpFilter == 'Overdue' ? 'All' : 'Overdue';
                    });
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: _buildStatBadge(
                    'Overdue',
                    _overdueDeals.length.toString(),
                    const Color(0xFFEF4444),
                    isActive: _selectedFollowUpFilter == 'Overdue',
                  ),
                ),
              ],
              if (_dueRemindersNow.isNotEmpty) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    _triggerLiveReminderPopup(_dueRemindersNow.first);
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFEF4444)),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.notifications_active_rounded, color: Color(0xFFEF4444), size: 14),
                        const SizedBox(width: 5),
                        Text(
                          '${_dueRemindersNow.length} Due Now',
                          style: const TextStyle(
                            color: Color(0xFFEF4444),
                            fontSize: 11.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (CrmDataImporter.getPending(_deals).isNotEmpty) ...[
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _showImportSheetDialog,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEAB308),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 14, color: Colors.black),
                  label: Text(
                    'Import Sheet (${CrmDataImporter.getPending(_deals).length})',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black),
                  ),
                ),
              ],
              const SizedBox(width: 10),
              InkWell(
                onTap: () {
                  MetaHubDialog.show(context, onLeadsImported: () {
                    _subscribeToDeals();
                  });
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF0064E0), Color(0xFF25D366)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0064E0).withValues(alpha: 0.35),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.all_inclusive_rounded, size: 14, color: Colors.white),
                      SizedBox(width: 6),
                      Text(
                        'Meta & WhatsApp Hub',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              InkWell(
                onTap: () {
                  setState(() => _showAllPipelines = !_showAllPipelines);
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _showAllPipelines
                        ? AppTheme.primaryColor.withValues(alpha: 0.2)
                        : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _showAllPipelines ? AppTheme.primaryColor : Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _showAllPipelines ? Icons.layers_rounded : Icons.filter_alt_outlined,
                        size: 14,
                        color: _showAllPipelines ? AppTheme.primaryColor : Colors.white70,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _showAllPipelines ? 'All Pipelines' : 'CRM Only',
                        style: TextStyle(
                          color: _showAllPipelines ? AppTheme.primaryColor : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Search + filter row
          Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: TextField(
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Search leads, clients, companies...',
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 14,
                      ),
                      prefixIcon: Icon(Icons.search_rounded, color: AppTheme.primaryColor, size: 20),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _buildDropdown(
                value: _selectedStage,
                items: _stages,
                onChanged: (v) => setState(() => _selectedStage = v!),
                hint: 'Stage',
              ),
              const SizedBox(width: 8),
              _buildDropdown(
                value: _selectedPriority,
                items: _priorities,
                onChanged: (v) => setState(() => _selectedPriority = v!),
                hint: 'Priority',
              ),
              const SizedBox(width: 8),
              _buildDropdown(
                value: _selectedFollowUpFilter,
                items: _followUpFilters,
                onChanged: (v) => setState(() => _selectedFollowUpFilter = v!),
                hint: 'Follow-up',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatBadge(String label, String value, Color color, {bool isActive = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: isActive ? color.withValues(alpha: 0.25) : color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isActive ? color : color.withValues(alpha: 0.25),
          width: isActive ? 1.5 : 1.0,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '$label: $value',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    required String hint,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          items: items
              .map((s) => DropdownMenuItem(
                    value: s,
                    child: Text(
                      s,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ))
              .toList(),
          onChanged: onChanged,
          dropdownColor: const Color(0xFF1A1A24),
          icon: Icon(Icons.expand_more_rounded, color: Colors.white38, size: 18),
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ),
    );
  }

  bool _matchesSearchAndPriority(Deal deal) {
    final matchesSearch = _searchQuery.isEmpty ||
        deal.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
        (deal.clientName?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false) ||
        (deal.company?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false) ||
        (deal.contactInfo?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false) ||
        (deal.workType?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false);

    final matchesPriority =
        _selectedPriority == 'All' || deal.priority == _selectedPriority;

    return matchesSearch && matchesPriority && _matchesFollowUpFilter(deal);
  }

  Widget _buildTabBar() {
    return Container(
      color: const Color(0xFF13131A),
      child: TabBar(
        controller: _tabController,
        indicatorColor: AppTheme.primaryColor,
        indicatorWeight: 3,
        labelColor: AppTheme.primaryColor,
        unselectedLabelColor: Colors.white38,
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        tabs: [
          const Tab(
            icon: Icon(Icons.view_kanban_rounded, size: 18),
            text: 'Kanban Board',
          ),
          Tab(
            icon: const Icon(Icons.list_alt_rounded, size: 18),
            text: 'All Leads (${_filteredDeals.length})',
          ),
          const Tab(
            icon: Icon(Icons.bar_chart_rounded, size: 18),
            text: 'Analytics',
          ),
        ],
      ),
    );
  }

  // ─── Kanban Board Tab ─────────────────────────────────────────────────────────

  Widget _buildKanbanBoard() {
    if (_scopedDeals.isEmpty) {
      return _buildEmptyCrmState();
    }

    final createdList = _createdDeals.where(_matchesSearchAndPriority).toList();
    final followUpList = _followUpDeals.where(_matchesSearchAndPriority).toList();
    final passedList = _passedDeals.where(_matchesSearchAndPriority).toList();
    final lostList = _lostDeals.where(_matchesSearchAndPriority).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1350;
        final colWidth = isWide ? (constraints.maxWidth - 32 - 48) / 4 : 330.0;

        final columns = [
          _buildKanbanColumn(
            stage: stageCreated,
            title: 'Created',
            icon: Icons.inbox_rounded,
            color: const Color(0xFF38BDF8),
            deals: createdList,
            width: colWidth,
          ),
          _buildKanbanColumn(
            stage: stageFollowUp,
            title: 'Follow-ups',
            icon: Icons.event_repeat_rounded,
            color: const Color(0xFFF59E0B),
            deals: followUpList,
            width: colWidth,
          ),
          _buildKanbanColumn(
            stage: stagePassed,
            title: 'Passed to Work',
            icon: Icons.verified_rounded,
            color: const Color(0xFF4ADE80),
            deals: passedList,
            width: colWidth,
          ),
          _buildKanbanColumn(
            stage: stageLost,
            title: 'Deal Lose',
            icon: Icons.cancel_outlined,
            color: const Color(0xFFF87171),
            deals: lostList,
            width: colWidth,
          ),
        ];

        if (isWide) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < columns.length; i++) ...[
                  if (i > 0) const SizedBox(width: 16),
                  Expanded(child: columns[i]),
                ],
              ],
            ),
          );
        }

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: constraints.maxHeight - 32,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < columns.length; i++) ...[
                  if (i > 0) const SizedBox(width: 16),
                  SizedBox(width: colWidth, child: columns[i]),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildKanbanColumn({
    required String stage,
    required String title,
    required IconData icon,
    required Color color,
    required List<Deal> deals,
    required double width,
  }) {
    final totalValue = deals.fold(0.0, (sum, d) => sum + d.amount);

    return DragTarget<Deal>(
      onWillAcceptWithDetails: (details) => getCrmStage(details.data) != stage,
      onAcceptWithDetails: (details) {
        final deal = details.data;
        if (stage == stagePassed) {
          _showPassLeadDialog(deal);
        } else if (stage == stageLost) {
          _promptLeadLostReason(deal);
        } else if (stage == stageFollowUp) {
          _moveToFollowUp(deal);
        } else if (stage == stageCreated) {
          _reopenLead(deal);
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF13131A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isHovered ? color : color.withValues(alpha: 0.25),
              width: isHovered ? 2 : 1,
            ),
            boxShadow: isHovered
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.2),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Column Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: isHovered
                      ? color.withValues(alpha: 0.16)
                      : color.withValues(alpha: 0.08),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                  border: Border(
                    bottom: BorderSide(
                      color: color.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, color: color, size: 16),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${deals.length}',
                                  style: TextStyle(
                                    color: color,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (totalValue > 0) ...[
                            const SizedBox(height: 2),
                            Text(
                              _fmt(totalValue),
                              style: TextStyle(
                                color: color.withValues(alpha: 0.8),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (stage == stageCreated)
                      IconButton(
                        icon: const Icon(Icons.add_rounded, size: 18),
                        color: color,
                        tooltip: 'Add Lead',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        onPressed: _createNewDeal,
                      ),
                  ],
                ),
              ),

              // Drop zone & Cards
              Expanded(
                child: deals.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isHovered ? Icons.file_download_rounded : icon,
                                size: 36,
                                color: isHovered ? color : Colors.white12,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                isHovered
                                    ? 'Drop here to move to $title'
                                    : 'No leads in $title',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isHovered ? color : Colors.white24,
                                  fontSize: 12,
                                  fontWeight: isHovered ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        itemCount: deals.length,
                        itemBuilder: (context, index) {
                          final deal = deals[index];
                          return Draggable<Deal>(
                            data: deal,
                            feedback: Material(
                              color: Colors.transparent,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: width - 20),
                                child: _buildKanbanCard(deal, stage, isDragging: true),
                              ),
                            ),
                            childWhenDragging: Opacity(
                              opacity: 0.3,
                              child: _buildKanbanCard(deal, stage),
                            ),
                            child: _buildKanbanCard(deal, stage),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildKanbanCard(Deal deal, String stage, {bool isDragging = false}) {
    final color = _stageColor(stage);
    final dateStr = deal.createdAt != null
        ? DateFormat('dd MMM yyyy').format(deal.createdAt!)
        : 'Recent';
    final (cardSource, cardNotes) = _extractSourceAndNotes(deal);

    return InkWell(
      onTap: () => _openDeal(deal),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDragging
              ? const Color(0xFF1E1E2A)
              : const Color(0xFF181824),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDragging
                ? color
                : Colors.white.withValues(alpha: 0.08),
            width: isDragging ? 1.5 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: date & priority
            Row(
              children: [
                const Icon(Icons.calendar_today_rounded, size: 11, color: Colors.white38),
                const SizedBox(width: 4),
                Text(
                  dateStr,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const Spacer(),
                _priorityTag(deal.priority),
              ],
            ),
            if (deal.postponedDate != null || (deal.contactStatus != null && deal.contactStatus!.trim().isNotEmpty)) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (deal.postponedDate != null)
                    _buildFollowUpBadge(deal.postponedDate!),
                  if (deal.contactStatus != null && deal.contactStatus!.trim().isNotEmpty)
                    _buildContactStatusBadge(deal.contactStatus!),
                ],
              ),
            ],
            const SizedBox(height: 8),

            // Lead Name / Title
            Text(
              deal.name,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),

            // Contact & Place
            if ((deal.contactInfo != null && deal.contactInfo!.trim().isNotEmpty) ||
                (deal.company != null && deal.company!.trim().isNotEmpty)) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (deal.contactInfo != null && deal.contactInfo!.trim().isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.phone_outlined, color: Colors.white38, size: 12),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: Text(
                            deal.contactInfo!,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: () => _openWhatsApp(deal.contactInfo!, deal.name),
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF22C55E).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(Icons.chat_bubble_outline_rounded, size: 12, color: Color(0xFF22C55E)),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () => _makePhoneCall(deal.contactInfo!),
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(Icons.call_outlined, size: 12, color: Color(0xFF38BDF8)),
                          ),
                        ),
                      ],
                    ),
                  if (deal.company != null && deal.company!.trim().isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.location_on_outlined, color: Colors.white38, size: 12),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: Text(
                            deal.company!,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],

            // Work Type Badge
            if (deal.workType != null && deal.workType!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.25)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.work_outline_rounded, size: 11, color: AppTheme.primaryColor),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Text(
                        deal.workType!,
                        style: TextStyle(
                          color: AppTheme.primaryColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Lead Source Badge
            if (cardSource.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.campaign_outlined, size: 11, color: Color(0xFF38BDF8)),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Text(
                        cardSource,
                        style: const TextStyle(
                          color: Color(0xFF38BDF8),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Notes / Inquiry / Remarks
            if (cardNotes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                cardNotes,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],

            // Deal Lose Reason Banner (if lost)
            if (stage == stageLost && deal.adjournedReason != null && deal.adjournedReason!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cancel_outlined, size: 12, color: Color(0xFFF87171)),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        'Reason: ${deal.adjournedReason}',
                        style: const TextStyle(
                          color: Color(0xFFF87171),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (deal.amount > 0) ...[
              const SizedBox(height: 6),
              Text(
                _fmt(deal.amount),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],

            const SizedBox(height: 8),
            const Divider(color: Colors.white10, height: 1),
            const SizedBox(height: 8),

            // Actions row
            Row(
              children: [
                if (stage == stageCreated) ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _showPassLeadDialog(deal),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.check_circle_outline, size: 13),
                      label: const Text(
                        'Pass to Work',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => _showFollowUpDialog(deal),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: deal.postponedDate != null
                            ? const Color(0xFFF59E0B).withValues(alpha: 0.18)
                            : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: deal.postponedDate != null
                              ? const Color(0xFFF59E0B).withValues(alpha: 0.35)
                              : Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.event_note_rounded,
                            size: 13,
                            color: deal.postponedDate != null ? const Color(0xFFF59E0B) : Colors.white70,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Follow-up',
                            style: TextStyle(
                              fontSize: 11,
                              color: deal.postponedDate != null ? const Color(0xFFF59E0B) : Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: () => _promptLeadLostReason(deal),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFF87171),
                      side: BorderSide(color: const Color(0xFFF87171).withValues(alpha: 0.4)),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.cancel_outlined, size: 13),
                    label: const Text('Lose', style: TextStyle(fontSize: 11)),
                  ),
                ] else if (stage == stageFollowUp) ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _showPassLeadDialog(deal),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.check_circle_outline, size: 13),
                      label: const Text(
                        'Pass to Work',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => _showFollowUpDialog(deal),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.alarm_on_rounded,
                            size: 13,
                            color: Color(0xFFF59E0B),
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Reschedule',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFF59E0B),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: () => _promptLeadLostReason(deal),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFF87171),
                      side: BorderSide(color: const Color(0xFFF87171).withValues(alpha: 0.4)),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.cancel_outlined, size: 13),
                    label: const Text('Lose', style: TextStyle(fontSize: 11)),
                  ),
                ] else if (stage == stagePassed) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF16A34A).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.verified, size: 12, color: Color(0xFF4ADE80)),
                        SizedBox(width: 4),
                        Text(
                          'Passed to Work & Client',
                          style: TextStyle(
                            color: Color(0xFF4ADE80),
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => _openDeal(deal),
                    icon: const Icon(Icons.open_in_new, size: 14, color: Colors.white60),
                    tooltip: 'Open in Detail',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  ),
                ] else if (stage == stageLost) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _reopenLead(deal),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF38BDF8),
                        side: BorderSide(color: const Color(0xFF38BDF8).withValues(alpha: 0.4)),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.replay_rounded, size: 13),
                      label: const Text('Reopen', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => _promptLeadLostReason(deal),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.25)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.edit_note_rounded, size: 13, color: Color(0xFFF87171)),
                          SizedBox(width: 4),
                          Text('Reason', style: TextStyle(fontSize: 11, color: Color(0xFFF87171), fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    onPressed: () => _showPassLeadDialog(deal),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF16A34A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.check_circle_outline, size: 13),
                    label: const Text('Pass', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyCrmState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
              ),
              child: Icon(Icons.hub_rounded, size: 56, color: AppTheme.primaryColor),
            ),
            const SizedBox(height: 24),
            const Text(
              'CRM Lead Pipeline',
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              'Leads created in CRM remain here as inquiries.\nOnly when a lead is passed to work does it appear in Client and Work Management.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _createNewDeal,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Create New Lead', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 14),
                OutlinedButton.icon(
                  onPressed: _showImportToCrmDialog,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Import Existing Work'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── All Deals Tab ───────────────────────────────────────────────────────────

  Widget _buildDealsListTab() {
    final filtered = _filteredDeals;
    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, color: Colors.white24, size: 48),
            const SizedBox(height: 12),
            const Text('No leads found', style: TextStyle(color: Colors.white38, fontSize: 16)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: filtered.length,
      itemBuilder: (ctx, i) {
        final deal = filtered[i];
        final color = deal.isWon ? Colors.greenAccent : _stageColor(deal.stage);
        return _buildDealCard(deal, color)
            .animate()
            .fadeIn(delay: Duration(milliseconds: i * 40));
      },
    );
  }

  Widget _buildDealCard(Deal deal, Color color) {
    final crmStage = getCrmStage(deal);
    final stageColor = _stageColor(crmStage);
    final (listSource, listNotes) = _extractSourceAndNotes(deal);

    return InkWell(
      onTap: () => _openDeal(deal),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 52,
              decoration: BoxDecoration(
                color: stageColor,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          deal.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _tag(crmStage, stageColor),
                      const SizedBox(width: 6),
                      _priorityTag(deal.priority),
                    ],
                  ),
                  if (deal.postponedDate != null || (deal.contactStatus != null && deal.contactStatus!.trim().isNotEmpty)) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (deal.postponedDate != null)
                          _buildFollowUpBadge(deal.postponedDate!),
                        if (deal.contactStatus != null && deal.contactStatus!.trim().isNotEmpty)
                          _buildContactStatusBadge(deal.contactStatus!),
                      ],
                    ),
                  ],
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (deal.contactInfo != null && deal.contactInfo!.trim().isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.phone_outlined, color: Colors.white38, size: 12),
                            const SizedBox(width: 4),
                            Text(
                              deal.contactInfo!,
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => _openWhatsApp(deal.contactInfo!, deal.name),
                              borderRadius: BorderRadius.circular(4),
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF22C55E).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Icon(Icons.chat_bubble_outline_rounded, size: 11, color: Color(0xFF22C55E)),
                              ),
                            ),
                            const SizedBox(width: 4),
                            InkWell(
                              onTap: () => _makePhoneCall(deal.contactInfo!),
                              borderRadius: BorderRadius.circular(4),
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Icon(Icons.call_outlined, size: 11, color: Color(0xFF38BDF8)),
                              ),
                            ),
                          ],
                        ),
                      if (deal.company != null && deal.company!.trim().isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.location_on_outlined, color: Colors.white38, size: 12),
                            const SizedBox(width: 4),
                            Text(
                              deal.company!,
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      if (deal.workType != null && deal.workType!.trim().isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.work_outline_rounded, color: Colors.white38, size: 12),
                            const SizedBox(width: 4),
                            Text(
                              deal.workType!,
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                    ],
                  ),
                  if (listSource.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.campaign_outlined, size: 11, color: Color(0xFF38BDF8)),
                        const SizedBox(width: 4),
                        Text(
                          listSource,
                          style: const TextStyle(
                            color: Color(0xFF38BDF8),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (listNotes.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      listNotes,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  if (crmStage == stageLost && deal.adjournedReason != null && deal.adjournedReason!.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.cancel_outlined, size: 11, color: Color(0xFFF87171)),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Reason: ${deal.adjournedReason}',
                            style: const TextStyle(
                              color: Color(0xFFF87171),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (deal.amount > 0)
                  Text(
                    _fmt(deal.amount),
                    style: TextStyle(
                      color: stageColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () => _showFollowUpDialog(deal),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: deal.postponedDate != null
                              ? const Color(0xFFF59E0B).withValues(alpha: 0.18)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: deal.postponedDate != null
                                ? const Color(0xFFF59E0B).withValues(alpha: 0.35)
                                : Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.event_note_rounded,
                              size: 13,
                              color: deal.postponedDate != null ? const Color(0xFFF59E0B) : Colors.white70,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Follow-up',
                              style: TextStyle(
                                fontSize: 11,
                                color: deal.postponedDate != null ? const Color(0xFFF59E0B) : Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (crmStage == stageCreated || crmStage == stageFollowUp) ...[
                      ElevatedButton.icon(
                        onPressed: () => _showPassLeadDialog(deal),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF16A34A),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.check_circle_outline, size: 13),
                        label: const Text('Pass to Work', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton.icon(
                        onPressed: () => _promptLeadLostReason(deal),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFF87171),
                          side: BorderSide(color: const Color(0xFFF87171).withValues(alpha: 0.4)),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.cancel_outlined, size: 12),
                        label: const Text('Lose', style: TextStyle(fontSize: 11)),
                      ),
                    ] else if (crmStage == stagePassed)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF16A34A).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified, size: 11, color: Color(0xFF4ADE80)),
                            SizedBox(width: 3),
                            Text('Passed', style: TextStyle(color: Color(0xFF4ADE80), fontSize: 10, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      )
                    else if (crmStage == stageLost) ...[
                      ElevatedButton.icon(
                        onPressed: () => _reopenLead(deal),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF38BDF8).withValues(alpha: 0.2),
                          foregroundColor: const Color(0xFF38BDF8),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Color(0xFF38BDF8)),
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.replay_rounded, size: 13),
                        label: const Text('Reopen', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton.icon(
                        onPressed: () => _promptLeadLostReason(deal),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFF87171),
                          side: BorderSide(color: const Color(0xFFF87171).withValues(alpha: 0.3)),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.edit_note_rounded, size: 12),
                        label: const Text('Reason', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _tag(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _priorityTag(String priority) {
    return _tag(priority, _priorityColor(priority));
  }

  // ─── Analytics Tab ───────────────────────────────────────────────────────────

  Widget _buildAnalyticsTab() {
    final Map<String, int> stageCount = {};
    final Map<String, double> stageValue = {};
    for (final s in crmStages) {
      final stageDeals = _scopedDeals.where((d) => getCrmStage(d) == s).toList();
      stageCount[s] = stageDeals.length;
      stageValue[s] = stageDeals.fold(0.0, (sum, d) => sum + d.amount);
    }

    final totalDeals = _scopedDeals.length;
    final winRate = totalDeals > 0
        ? ((_passedDeals.length / totalDeals) * 100).toStringAsFixed(1)
        : '0.0';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Key Metrics'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              _analyticsCard(
                'Total Pipeline',
                _fmt(_totalPipelineValue),
                Icons.account_balance_wallet_rounded,
                AppTheme.primaryColor,
              ),
              _analyticsCard(
                'Total Passed',
                _fmt(_totalWonValue),
                Icons.verified_rounded,
                const Color(0xFF4ADE80),
              ),
              _analyticsCard(
                'Created Leads',
                _createdDeals.length.toString(),
                Icons.inbox_rounded,
                const Color(0xFF38BDF8),
              ),
              _analyticsCard(
                'Follow-ups',
                _followUpDeals.length.toString(),
                Icons.event_repeat_rounded,
                const Color(0xFFF59E0B),
              ),
              _analyticsCard(
                'Deal Lose',
                _lostDeals.length.toString(),
                Icons.cancel_outlined,
                const Color(0xFFF87171),
              ),
              _analyticsCard(
                'Passed Rate',
                '$winRate%',
                Icons.pie_chart_rounded,
                Colors.orangeAccent,
              ),
            ],
          ),
          const SizedBox(height: 32),
          _sectionTitle('Stage Breakdown'),
          const SizedBox(height: 16),
          ...crmStages.map((stage) {
            final count = stageCount[stage] ?? 0;
            final value = stageValue[stage] ?? 0.0;
            final color = _stageColor(stage);
            final ratio = totalDeals > 0 ? count / totalDeals : 0.0;

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF13131A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        stage,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '$count leads',
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _fmt(value),
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ratio.clamp(0.0, 1.0),
                      backgroundColor: Colors.white.withValues(alpha: 0.06),
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _analyticsCard(String label, String value, IconData icon, Color color) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF13131A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    ).animate().fadeIn().slideY(begin: 0.2);
  }

  Widget _sectionTitle(String title) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: AppTheme.primaryColor,
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primaryColor.withValues(alpha: 0.5),
                blurRadius: 8,
              )
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: CircularProgressIndicator(
        color: AppTheme.primaryColor,
        strokeWidth: 2,
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 44),
          const SizedBox(height: 12),
          Text(
            _errorMessage ?? 'An error occurred',
            style: const TextStyle(color: Colors.white54, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
