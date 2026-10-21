import 'package:amplify_api/amplify_api.dart';
import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import 'encryption_service.dart';
import 'meta_service.dart';

class AppNotification {
  final dynamic id;
  final dynamic userId;
  final String title;
  final String message;
  final String type;
  final dynamic dealId;
  final dynamic taskId;
  final bool isRead;
  final DateTime createdAt;

  AppNotification({
    required this.id,
    required this.userId,
    required this.title,
    required this.message,
    required this.type,
    this.dealId,
    this.taskId,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotification.fromMap(Map<String, dynamic> map) {
    return AppNotification(
      id: map['id'],
      userId: map['user_id'],
      title: map['title'],
      message: map['message'],
      type: map['type'] ?? 'info',
      dealId: map['deal_id'],
      taskId: map['task_id'],
      isRead: map['is_read'] == true,
      createdAt: map['created_at'] == null 
          ? DateTime.now() 
          : (map['created_at'] is DateTime 
              ? map['created_at'] as DateTime 
              : DateTime.tryParse(map['created_at'].toString()) ?? DateTime.now()),
    );
  }
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  /// Global key for showing in-app notification toasts on desktop.
  static GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  final _localNotif = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  
  final _notificationController = StreamController<AppNotification>.broadcast();
  Stream<AppNotification> get notificationStream => _notificationController.stream;
  StreamSubscription<GraphQLResponse<Notifications>>? _subscription;

  Future<void> initLocalNotifications() async {
    if (_isInitialized) return;
    
    // Only initialize on mobile
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      _isInitialized = true;
      return;
    }

    try {
      // Request permissions
      if (Platform.isAndroid) {
        await _localNotif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        await _localNotif.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true);
      }

      const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
      const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings();
      
      const InitializationSettings initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid,
        iOS: initializationSettingsIOS,
      );

      await _localNotif.initialize(
        settings: initializationSettings,
        onDidReceiveNotificationResponse: (details) {
          // Handle tap
        },
      );
      _isInitialized = true;
    } catch (e) {
      debugPrint('Error initializing notifications: $e');
    }
  }

  Future<void> showLocalNotification({
    required String title,
    required String message,
    String? payload,
  }) async {
    try {
      // Desktop / Web: show in-app toast notification
      if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
        _showDesktopNotification(title: title, message: message);
        return;
      }
      
      await initLocalNotifications();

      const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'cuc_tasks',
        'Task Notifications',
        channelDescription: 'Notifications for tasks and work management',
        importance: Importance.max,
        priority: Priority.high,
      );
      
      const NotificationDetails platformDetails = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(),
      );

      await _localNotif.show(
        id: DateTime.now().millisecond % 1000000,
        title: title,
        body: message,
        notificationDetails: platformDetails,
        payload: payload,
      );
    } catch (e) {
      debugPrint('Error showing local notification: $e');
    }
  }

  /// Shows an in-app floating toast notification for desktop platforms.
  void _showDesktopNotification({required String title, required String message}) {
    final messenger = scaffoldMessengerKey?.currentState;
    if (messenger == null) {
      debugPrint('Desktop notification skipped: no scaffoldMessengerKey');
      return;
    }

    try {
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.chat_bubble_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                    const SizedBox(height: 2),
                    Text(message, style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85)), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF1E293B),
          duration: const Duration(seconds: 4),
          width: 380,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 8,
        ),
      );
    } catch (e) {
      debugPrint('Desktop notification UI error (likely no Scaffold): $e');
    }
  }

  Future<List<AppNotification>> getUnreadNotifications(dynamic userId) async {
    try {
      final parsedUserId = userId is int ? userId : int.tryParse(userId.toString()) ?? 0;
      final req = ModelQueries.list(
        Notifications.classType,
        where: Notifications.IS_READ.eq(false).and(Notifications.USER_ID.eq(parsedUserId)),
        limit: 100,
      );
      final res = await Amplify.API.query(request: req).response;
      var items = res.data?.items.where((e) => e != null).cast<Notifications>().toList() ?? [];
      
      items.sort((a, b) => (b.created_at ?? '').compareTo(a.created_at ?? ''));
      
      return items.take(50).map((n) => AppNotification.fromMap(n.toMap())).toList();
    } catch (e) {
      debugPrint('Error getting unread notifications: $e');
      return [];
    }
  }

  Future<void> markAsRead(dynamic notificationId) async {
    try {
      final req = ModelQueries.list(Notifications.classType, where: Notifications.ID.eq(notificationId.toString()), limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      if (res.data?.items.isNotEmpty == true) {
        final notif = res.data!.items.first!;
        final updated = notif.copyWith(is_read: true);
        await BackupAwareApi().update(updated);
      }
    } catch (e) {
      debugPrint('Error marking notification as read: $e');
    }
  }

  Future<void> markAllAsRead(dynamic userId) async {
    try {
      final parsedUserId = userId is int ? userId : int.tryParse(userId.toString()) ?? 0;
      final req = ModelQueries.list(
        Notifications.classType, 
        where: Notifications.IS_READ.eq(false).and(Notifications.USER_ID.eq(parsedUserId)), 
        limit: 100,
      );
      final res = await Amplify.API.query(request: req).response;
      final unread = res.data?.items.whereType<Notifications>() ?? [];
      
      for (var notif in unread) {
        final updated = notif.copyWith(is_read: true);
        await BackupAwareApi().update(updated);
      }
    } catch (e) {
      debugPrint('Error marking all as read: $e');
    }
  }

  Future<void> sendNotification({
    required dynamic userId,
    required String title,
    required String message,
    String type = 'info',
    dynamic dealId,
    dynamic taskId,
    bool showLocal = false,
  }) async {
    try {
      final notif = Notifications(
        user_id: int.tryParse(userId.toString()) ?? 0,
        title: title,
        message: message,
        type: type,
        deal_id: dealId != null ? int.tryParse(dealId.toString()) : null,
        task_id: taskId != null ? int.tryParse(taskId.toString()) : null,
        is_read: false,
        created_at: DateTime.now().toIso8601String()
      );
      await BackupAwareApi().create(notif);

      // Only show local/desktop notification if explicitly requested and directed to the current user
      if (showLocal) {
        final prefs = await SharedPreferences.getInstance();
        final currentUserId = prefs.getInt('current_user_id')?.toString() ?? prefs.getString('current_user_id_str');
        if (currentUserId != null && userId.toString() == currentUserId.toString()) {
          await showLocalNotification(title: title, message: message);
        }
      }
    } catch (e) {
      debugPrint('Error sending notification: $e');
    }
  }

  void startRealtimeListener(dynamic userId) {
    if (_subscription != null) return;
    
    debugPrint('Real-time notification listener disabled: Notifications model not found in backend.');
    // final subReq = ModelSubscriptions.onCreate(Notifications.classType);
    // _subscription = Amplify.API.subscribe(
    //   subReq,
    //   onEstablished: () => debugPrint('Notification subscription established'),
    // ).listen((event) {
    //   final data = event.data;
    //   if (data != null && data.user_id?.toString() == userId.toString()) {
    //     final newNotif = AppNotification.fromMap(data.toMap());
    //     _notificationController.add(newNotif);
    //     showLocalNotification(
    //       title: newNotif.title,
    //       message: newNotif.message,
    //       payload: newNotif.taskId?.toString() ?? newNotif.dealId?.toString(),
    //     );
    //   }
    // }, onError: (dynamic e) {
    //   debugPrint('Notification subscription stream error: $e');
    // });
  }

  void stopRealtimeListener() {
    _subscription?.cancel();
    _subscription = null;
  }

  Future<void> notifyAdmins({
    required String title,
    required String message,
    String type = 'info',
    dynamic dealId,
    dynamic taskId,
  }) async {
    try {
      final req = ModelQueries.list(Users.classType, where: Users.ROLE.eq('admin'), limit: 10000);
      final response = await Amplify.API.query(request: req).response;
      final items = (response.data?.items ?? []).whereType<Users>().toList();
      
      for (var row in items) {
        final adminId = row.id;
        await sendNotification(
          userId: adminId,
          title: title,
          message: message,
          type: type,
          dealId: dealId,
          taskId: taskId,
        );
      }
    } catch (e) {
      debugPrint('Error notifying admins: $e');
    }
  }

  /// Sends both an in-app system notification and an encrypted direct message to all Admins
  /// when a scheduled follow-up is not attended to by staff.
  Future<void> notifyAdminsMissedFollowUp({
    required dynamic dealId,
    required String leadName,
    required String? contactInfo,
    required DateTime scheduledTime,
    String? contactStatus,
    String? company,
  }) async {
    try {
      final timeFormatted = DateFormat('dd MMM yyyy, hh:mm a').format(scheduledTime);
      final title = '🚨 Missed CRM Follow-up: $leadName';
      final message = 'Follow-up for lead "$leadName" (${contactInfo?.isNotEmpty == true ? contactInfo : "No phone"}) scheduled for $timeFormatted was NOT attended to.';

      // 1. High-Priority In-App & Push Notification to all Admins
      await notifyAdmins(
        title: title,
        message: message,
        type: 'missed_followup',
        dealId: dealId,
      );

      // 2. Direct message into Admin Chat Inbox
      final req = ModelQueries.list(Users.classType, where: Users.ROLE.eq('admin'), limit: 100);
      final response = await Amplify.API.query(request: req).response;
      final admins = (response.data?.items ?? []).whereType<Users>().toList();

      final prefs = await SharedPreferences.getInstance();
      final myId = prefs.getInt('current_user_id') ?? 1;

      for (var admin in admins) {
        final adminIdInt = int.tryParse(admin.id.toString());
        if (adminIdInt != null) {
          final content = '[CRM Escalation] ⏰ Follow-up Overdue!\nLead: $leadName\nPhone: ${contactInfo ?? "N/A"}\nPlace: ${company ?? "N/A"}\nStatus: ${contactStatus ?? "Pending"}\nScheduled Time: $timeFormatted\nStaff did not follow up on this lead.';
          final encryptedContent = EncryptionService().encryptText(content);
          final newMsg = Messages(
            sender_id: myId,
            receiver_id: adminIdInt,
            content: encryptedContent,
            is_read: false,
            created_at: DateTime.now().toIso8601String(),
          );
          await BackupAwareApi().create(newMsg);
        }
      }
    } catch (e) {
      debugPrint('Error notifying admins about missed follow-up: $e');
    }
  }

  /// Notifies only relevant stakeholders (Managers and Responsible Staff).
  Future<void> notifyStakeholders({
    dynamic dealId,
    dynamic taskId,
    required String title,
    required String message,
    String type = 'info',
  }) async {
    final Set<String> recipients = {};

    try {
      // 1. Always include Managers
      final req = ModelQueries.list(Users.classType, where: Users.ROLE.eq('manager'), limit: 10000);
      final response = await Amplify.API.query(request: req).response;
      final managers = (response.data?.items ?? []).whereType<Users>().toList();
      for (var row in managers) {
        recipients.add(row.id);
      }

      // 2. If Deal, include Responsible
      if (dealId != null) {
        final dReq = ModelQueries.list(Deals.classType, where: Deals.ID.eq(dealId.toString()), limit: 10000);
        final dRes = await Amplify.API.query(request: dReq).response;
        if (dRes.data?.items.isNotEmpty == true) {
          final dealRes = dRes.data!.items.first!;
          if (dealRes.responsible_id != null) {
            recipients.add(dealRes.responsible_id.toString());
          }
        }
      }

      // 3. If Task, include AssignedTo and AssignedBy
      if (taskId != null) {
        final tReq = ModelQueries.list(Tasks.classType, where: Tasks.ID.eq(taskId.toString()), limit: 10000);
        final tRes = await Amplify.API.query(request: tReq).response;
        if (tRes.data?.items.isNotEmpty == true) {
          final taskRes = tRes.data!.items.first!;
          if (taskRes.assigned_to != null) recipients.add(taskRes.assigned_to.toString());
          if (taskRes.assigned_by != null) recipients.add(taskRes.assigned_by.toString());
        }
      }

      // 4. Send to everyone collected
      for (var uid in recipients) {
        await sendNotification(
          userId: uid,
          title: title,
          message: message,
          type: type,
          dealId: dealId,
          taskId: taskId,
        );
      }

      // 5. Lively automated WhatsApp alert to assigned staff member's company phone
      if (type == 'assignment') {
        if (taskId != null) {
          try {
            final tReq = ModelQueries.list(Tasks.classType, where: Tasks.ID.eq(taskId.toString()), limit: 1);
            final tRes = await Amplify.API.query(request: tReq).response;
            if (tRes.data?.items.isNotEmpty == true && tRes.data!.items.first != null) {
              final taskRes = tRes.data!.items.first!;
              if (taskRes.assigned_to != null) {
                unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
                  staffUserId: taskRes.assigned_to,
                  assignmentTitle: taskRes.title ?? title,
                  workOrTaskType: 'Task Assignment',
                  clientName: taskRes.client_name,
                  dueDate: taskRes.due_date,
                  details: taskRes.description ?? message,
                ));
              }
            }
          } catch (e) {
            debugPrint('Error triggering task WhatsApp alert: $e');
          }
        } else if (dealId != null) {
          try {
            final dReq = ModelQueries.list(Deals.classType, where: Deals.ID.eq(dealId.toString()), limit: 1);
            final dRes = await Amplify.API.query(request: dReq).response;
            if (dRes.data?.items.isNotEmpty == true && dRes.data!.items.first != null) {
              final dealRes = dRes.data!.items.first!;
              if (dealRes.responsible_id != null) {
                unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
                  staffUserId: dealRes.responsible_id,
                  assignmentTitle: dealRes.name ?? title,
                  workOrTaskType: 'Work Assignment',
                  clientName: dealRes.client_name,
                  priority: dealRes.priority,
                  details: message,
                ));
              }
            }
          } catch (e) {
            debugPrint('Error triggering deal WhatsApp alert: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('Error notifying stakeholders: $e');
    }
  }

  static const String _lastReminderCronKey = 'smart_escalation_reminder_last_run';
  static bool _isReminderCronRunning = false;

  /// Checks and sends reminders with dynamic frequency based on urgency.
  Future<void> checkAndSendFrequentReminders() async {
    if (_isReminderCronRunning) return;
    _isReminderCronRunning = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final lastRunMs = prefs.getInt(_lastReminderCronKey);
      if (lastRunMs != null) {
        final elapsed = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastRunMs));
        if (elapsed.inHours < 6) {
          debugPrint('Smart Escalation Reminder Cron skipped (ran ${elapsed.inMinutes}m ago)');
          _isReminderCronRunning = false;
          return;
        }
      }
      await prefs.setInt(_lastReminderCronKey, DateTime.now().millisecondsSinceEpoch);

      debugPrint('Running Smart Escalation Reminder Cron...');

      // Fetch recent notifications once to avoid N+1 queries
      final nReq = ModelQueries.list(Notifications.classType, limit: 1000);
      final nRes = await Amplify.API.query(request: nReq).response;
      final allNotifs = (nRes.data?.items ?? []).whereType<Notifications>().toList();

      // 1. Remind Deals
      final reqDeals = ModelQueries.list(Deals.classType, where: Deals.STAGE.ne('Completed'), limit: 10000);
      final resDeals = await Amplify.API.query(request: reqDeals).response;
      final deals = (resDeals.data?.items ?? []).whereType<Deals>().toList();

      for (final dealMap in deals) {
        if (dealMap.responsible_id == null) continue;
        
        final dealId = dealMap.id;
        final resId = dealMap.responsible_id;
        final name = dealMap.name ?? '';
        final stage = dealMap.stage ?? '';

        // Check frequency for Deal from pre-fetched notifications
        final notifs = allNotifs.where((e) => e.deal_id?.toString() == dealId.toString() && e.type == 'reminder').toList();
        notifs.sort((a, b) => (b.created_at ?? '').compareTo(a.created_at ?? ''));
        
        bool shouldNotify = true;
        if (notifs.isNotEmpty) {
          final lastNotifRes = notifs.first;
          final lastRun = DateTime.tryParse(lastNotifRes.created_at ?? '') ?? DateTime.now();
          // Default frequency for deals: 12 hours
          if (DateTime.now().difference(lastRun).inHours < 12) {
            shouldNotify = false;
          }
        }

        if (shouldNotify) {
          await sendNotification(
            userId: resId,
            title: 'Reminder: Pending Deal',
            message: 'Deal "$name" is still in stage "$stage".',
            type: 'reminder',
            dealId: dealId,
            showLocal: false,
          );
        }
      }

      // 2. Remind Tasks
      final reqTasks = ModelQueries.list(Tasks.classType, where: Tasks.STATUS.ne('Completed'), limit: 10000);
      final resTasks = await Amplify.API.query(request: reqTasks).response;
      final tasks = (resTasks.data?.items ?? []).whereType<Tasks>().toList();

      for (final taskMap in tasks) {
        if (taskMap.assigned_to == null) continue;

        final taskId = taskMap.id;
        final assignedTo = taskMap.assigned_to;
        final title = taskMap.title ?? '';
        final status = taskMap.status ?? '';
        final dueDateStr = taskMap.due_date?.toString();
        final dueDate = dueDateStr != null ? DateTime.tryParse(dueDateStr) : null;
        
        // Calculate dynamic frequency
        Duration interval = const Duration(hours: 24); // Default
        if (dueDate != null) {
          final timeToDue = dueDate.difference(DateTime.now());
          if (timeToDue.isNegative) {
            interval = const Duration(minutes: 30); // Overdue: Very frequent
          } else if (timeToDue.inHours < 4) {
            interval = const Duration(hours: 1); // < 4 hours: Hourly
          } else if (timeToDue.inHours < 24) {
            interval = const Duration(hours: 4); // < 1 day: Every 4 hours
          }
        }

        // Check last notification for this task from pre-fetched notifications
        final notifs = allNotifs.where((e) => e.task_id?.toString() == taskId.toString() && (e.type == 'reminder' || e.type == 'alert')).toList();
        notifs.sort((a, b) => (b.created_at ?? '').compareTo(a.created_at ?? ''));
        
        bool shouldNotify = true;
        if (notifs.isNotEmpty) {
          final lastNotifRes = notifs.first;
          final lastRun = DateTime.tryParse(lastNotifRes.created_at ?? '') ?? DateTime.now();
          if (DateTime.now().difference(lastRun) < interval) {
            shouldNotify = false;
          }
        }

        if (shouldNotify) {
          bool isOverdue = dueDate != null && dueDate.isBefore(DateTime.now());
          await sendNotification(
            userId: assignedTo,
            title: isOverdue ? 'URGENT: OVERDUE TASK' : 'Task Reminder',
            message: isOverdue ? 'Task "$title" is OVERDUE!' : 'Task "$title" is still "$status". Due: ${DateFormat('hh:mm a').format(dueDate?.toLocal() ?? DateTime.now())}',
            type: isOverdue ? 'alert' : 'reminder',
            taskId: taskId,
            showLocal: false,
          );
        }
      }
      
      debugPrint('Smart Escalation Reminders processed.');

    } catch (e) {
      debugPrint('Error running daily reminders: $e');
    } finally {
      _isReminderCronRunning = false;
    }
  }
}
