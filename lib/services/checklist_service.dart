import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart';
import '../models/checklist.dart' as old;
import 'auth_service.dart';
import 'notification_service.dart';
import 'logging_service.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import 'meta_service.dart';

class ChecklistService {

  Future<List<old.Checklist>> getChecklistsForUser(int userId, {String? date}) async {
    final targetDate = date ?? DateTime.now().toIso8601String().split('T')[0];
    
    try {
      final req = ModelQueries.list(
        Checklists.classType,
        where: Checklists.RESPONSIBLE_ID.eq(userId).and(
          Checklists.DUE_DATE.eq(targetDate).or(Checklists.STATUS.eq('Pending').and(Checklists.DUE_DATE.lt(targetDate)))
        )
      , limit: 10000, authorizationMode: APIAuthorizationType.userPools);
      final res = await Amplify.API.query(request: req).response;
      var items = res.data?.items.where((e) => e != null).cast<Checklists>().toList() ?? [];
      
      items.sort((a, b) => (b.createdAt?.toString() ?? '').compareTo(a.createdAt?.toString() ?? ''));
      
      final Map<int, String> userNameMap = {};
      try {
        final uReq = ModelQueries.list(Users.classType, limit: 1000, authorizationMode: APIAuthorizationType.userPools);
        final uRes = await Amplify.API.query(request: uReq).response;
        final users = uRes.data?.items.whereType<Users>() ?? [];
        for (var u in users) {
          final intId = int.tryParse(u.id);
          if (intId != null) userNameMap[intId] = u.name ?? '';
        }
      } catch (_) {}

      List<old.Checklist> mapped = [];
      for (var c in items) {
        mapped.add(old.Checklist.fromMap({
          ...c.toJson(),
          'manager_name': c.manager_id != null ? userNameMap[c.manager_id!] : null,
          'responsible_name': c.responsible_id != null ? userNameMap[c.responsible_id!] : null,
        }));
      }
      return mapped;
    } catch (e) {
      safePrint('Error getChecklistsForUser: $e');
      return [];
    }
  }

  Future<List<old.Checklist>> getAllChecklists({String? date}) async {
    final targetDate = date ?? DateTime.now().toIso8601String().split('T')[0];
    try {
      final req = ModelQueries.list(
        Checklists.classType,
        where: Checklists.DUE_DATE.eq(targetDate).or(Checklists.STATUS.eq('Pending').and(Checklists.DUE_DATE.lt(targetDate)))
      , limit: 10000, authorizationMode: APIAuthorizationType.userPools);
      final res = await Amplify.API.query(request: req).response;
      var items = res.data?.items.where((e) => e != null).cast<Checklists>().toList() ?? [];
      items.sort((a, b) => (b.createdAt?.toString() ?? '').compareTo(a.createdAt?.toString() ?? ''));
      
      final Map<int, String> userNameMap = {};
      try {
        final uReq = ModelQueries.list(Users.classType, limit: 1000, authorizationMode: APIAuthorizationType.userPools);
        final uRes = await Amplify.API.query(request: uReq).response;
        final users = uRes.data?.items.whereType<Users>() ?? [];
        for (var u in users) {
          final intId = int.tryParse(u.id);
          if (intId != null) userNameMap[intId] = u.name ?? '';
        }
      } catch (_) {}

      List<old.Checklist> mapped = [];
      for (var c in items) {
        mapped.add(old.Checklist.fromMap({
          ...c.toJson(),
          'manager_name': c.manager_id != null ? userNameMap[c.manager_id!] : null,
          'responsible_name': c.responsible_id != null ? userNameMap[c.responsible_id!] : null,
        }));
      }
      return mapped;
    } catch (e) {
      safePrint('Error getAllChecklists: $e');
      return [];
    }
  }

  Future<dynamic> createChecklist(old.Checklist checklist) async {
    final prefs = await SharedPreferences.getInstance();
    final managerId = prefs.getInt('current_user_id');
    
    final Map<String, dynamic> values = checklist.toMap();
    final mId = values['manager_id'] ?? managerId;
    final dDate = values['due_date'] ?? DateTime.now().toIso8601String().split('T')[0];
    
    final newChecklist = Checklists(
      title: values['title'] ?? '',
      description: values['description'],
      manager_id: mId,
      responsible_id: values['responsible_id'],
      status: values['status'] ?? 'Pending',
      remarks: values['remarks'],
      reason: values['reason'],
      due_date: dDate,
    );

    try {
      final res = await BackupAwareApi().create(newChecklist);
      final checklistId = res.data?.id;

      if (checklist.responsibleId != null) {
        final managerName = await AuthService().getUserName();
        await NotificationService().sendNotification(
          userId: checklist.responsibleId!,
          title: "New Checklist Assigned",
          message: "${managerName ?? 'Manager'} assigned you a new checklist: ${checklist.title}",
          type: 'checklist',
        );

        // Lively real-time WhatsApp alert to assigned staff member's company phone
        unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
          staffUserId: checklist.responsibleId!,
          assignmentTitle: checklist.title,
          workOrTaskType: 'Daily Task (Manager Master)',
          clientName: checklist.dealName,
          dueDate: checklist.dueDate,
          assignedByName: managerName ?? 'Manager',
          details: checklist.description ?? 'Task assigned to you in Manager Master.',
        ));
      }
      await LoggingService().logAction(action: 'CHECKLIST_CREATED', targetType: 'Checklist', targetId: checklistId?.toString(), details: 'Created checklist: ${checklist.title}');
      return checklistId;
    } catch (e) {
      safePrint('Error createChecklist: $e');
      rethrow;
    }
  }

  Future<void> updateChecklistStatus(dynamic id, String status, {String? remarks, String? reason, String? newDueDate, bool reassignToManager = false}) async {
    try {
      final req = ModelQueries.get(Checklists.classType, ChecklistsModelIdentifier(id: id.toString()), authorizationMode: APIAuthorizationType.userPools);
      final res = await Amplify.API.query(request: req).response;
      if (res.data == null) return;
      
      final c = res.data!;
      int? respId = c.responsible_id;
      if (reassignToManager && c.manager_id != null) {
        respId = c.manager_id;
      }

      String currentDesc = c.description ?? '';
      
      if (status == 'In Progress' && !currentDesc.contains('[START_TIME]')) {
        currentDesc += '\n[START_TIME] ${DateTime.now().toIso8601String()}';
      }
      if (status == 'Completed' && !currentDesc.contains('[END_TIME]')) {
        currentDesc += '\n[END_TIME] ${DateTime.now().toIso8601String()}';
      }
      currentDesc = currentDesc.trim();

      final updated = c.copyWith(
        status: status,
        remarks: remarks,
        reason: reason,
        due_date: newDueDate,
        responsible_id: respId,
        description: currentDesc,
      );
      
      await BackupAwareApi().update(updated);
      await LoggingService().logAction(action: 'CHECKLIST_STATUS_UPDATED', targetType: 'Checklist', targetId: id.toString(), details: 'Checklist "${c.title}" status changed to $status');

      if (c.manager_id != null) {
        String responsibleName = 'Staff';
        if (c.responsible_id != null) {
          final rReq = ModelQueries.list(Users.classType, where: Users.ID.eq(c.responsible_id), limit: 10000, authorizationMode: APIAuthorizationType.userPools);
          final rRes = await Amplify.API.query(request: rReq).response;
          if (rRes.data?.items.isNotEmpty == true) responsibleName = rRes.data!.items.first?.name ?? 'Staff';
        }

        await NotificationService().sendNotification(
          userId: c.manager_id!,
          title: "Checklist $status",
          message: "$responsibleName marked \"${c.title}\" as $status${reassignToManager ? ' and assigned it back to you' : ''}.",
          type: 'checklist_update',
        );
      }
    } catch (e) {
      safePrint('Error updateChecklistStatus: $e');
      rethrow;
    }
  }

  Future<int> getPendingCountForUser(int userId) async {
    final today = DateTime.now().toIso8601String().split('T')[0];
    try {
      final req = ModelQueries.list(
        Checklists.classType, 
        where: Checklists.RESPONSIBLE_ID.eq(userId)
          .and(Checklists.DUE_DATE.eq(today))
          .and(Checklists.STATUS.eq('Pending'))
      , limit: 10000, authorizationMode: APIAuthorizationType.userPools);
      final res = await Amplify.API.query(request: req).response;
      return res.data?.items.length ?? 0;
    } catch (e) {
      safePrint('Error getPendingCountForUser: $e');
      return 0;
    }
  }

  Future<List<Map<String, dynamic>>> getAllUsers() async {
    try {
      final req = ModelQueries.list(Users.classType, limit: 10000, authorizationMode: APIAuthorizationType.userPools);
      final res = await Amplify.API.query(request: req).response;
      var items = res.data?.items.where((e) => e != null).cast<Users>().toList() ?? [];
      
      final Map<String, Users> uniqueUsers = {};
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
      
      var uniqueItems = uniqueUsers.values.toList();
      uniqueItems.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      return uniqueItems.map((u) => u.toJson()).toList();
    } catch (e) {
      safePrint('Error getAllUsers: $e');
      return [];
    }
  }

  Future<void> patchNullTasksToSariga(int sarigaId) async {
    try {
      final req = ModelQueries.list(Checklists.classType, limit: 10000, authorizationMode: APIAuthorizationType.userPools);
      final res = await Amplify.API.query(request: req).response;
      final items = res.data?.items ?? [];
      for (var item in items) {
        if (item != null && item.responsible_id == null) {
          final uReq = ModelMutations.update(item.copyWith(responsible_id: sarigaId));
          await Amplify.API.mutate(request: uReq).response;
        }
      }
    } catch (e) {
      safePrint('Error patching tasks: $e');
    }
  }

  Future<void> updateChecklist(old.Checklist checklist) async {
    try {
      final req = ModelQueries.get(Checklists.classType, ChecklistsModelIdentifier(id: checklist.id.toString()), authorizationMode: APIAuthorizationType.userPools);
      final res = await Amplify.API.query(request: req).response;
      if (res.data == null) throw Exception("Checklist not found");
      
      final c = res.data!;
      final updated = c.copyWith(
        title: checklist.title,
        description: checklist.description,
        responsible_id: checklist.responsibleId,
        manager_id: checklist.managerId,
        status: checklist.status,
        remarks: checklist.remarks,
        reason: checklist.reason,
        due_date: checklist.dueDate,
      );
      
      await BackupAwareApi().update(updated);
      await LoggingService().logAction(action: 'CHECKLIST_UPDATED', targetType: 'Checklist', targetId: checklist.id.toString(), details: 'Updated checklist: ${checklist.title}');
    } catch (e) {
      safePrint('Error updateChecklist: $e');
      rethrow;
    }
  }

  Future<void> deleteChecklist(dynamic id) async {
    try {
      await BackupAwareApi().deleteById(Checklists.classType, ChecklistsModelIdentifier(id: id.toString())
      );
      await LoggingService().logAction(action: 'CHECKLIST_DELETED', targetType: 'Checklist', targetId: id.toString(), details: 'Deleted checklist');
    } catch (e) {
      safePrint('Error deleteChecklist: $e');
      rethrow;
    }
  }
}
