import 'package:amplify_api/amplify_api.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart';
import '../models/deal.dart' as old;
import '../models/deal_activity.dart' as oldActivity;
import 'notification_service.dart';
import 'meta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cuc_app/services/backup_aware_api.dart';

class DealService {

  Future<List<old.Deal>> getAllDeals() async {
    try {
      var req = ModelQueries.list(Deals.classType, limit: 10000);
      List<Deals> all = [];
      while (true) {
        final res = await Amplify.API.query(request: req).response;
        all.addAll(res.data?.items.where((e) => e != null).cast<Deals>() ?? []);
        if (res.data?.hasNextResult ?? false) {
          req = res.data!.requestForNextResult!;
        } else {
          break;
        }
      }
      all.sort((a, b) => (b.updatedAt?.toString() ?? '').compareTo(a.updatedAt?.toString() ?? ''));
      return all.map((m) => old.Deal.fromMap(m.toJson())).toList();
    } catch (e) {
      debugPrint('Error getAllDeals: $e');
      return [];
    }
  }

  Stream<List<old.Deal>> getDealsStream() {
    late StreamController<List<old.Deal>> controller;
    StreamSubscription<GraphQLResponse<String>>? createSub;
    StreamSubscription<GraphQLResponse<String>>? updateSub;
    StreamSubscription<GraphQLResponse<String>>? deleteSub;

    void fetchAndEmit() async {
      try {
        var req = ModelQueries.list(Deals.classType, limit: 10000);
        List<Deals> all = [];
        while (true) {
          final res = await Amplify.API.query(request: req).response;
          all.addAll(res.data?.items.where((e) => e != null).cast<Deals>() ?? []);
          if (res.data?.hasNextResult ?? false) {
            req = res.data!.requestForNextResult!;
          } else {
            break;
          }
        }
        all.sort((a, b) => (b.updatedAt?.toString() ?? '').compareTo(a.updatedAt?.toString() ?? ''));
        controller.add(all.map((m) => old.Deal.fromMap(m.toJson())).toList());
      } catch (e) {
        debugPrint('Error fetchAndEmit deals: $e');
      }
    }

    controller = StreamController<List<old.Deal>>.broadcast(
      onListen: () {
        fetchAndEmit();
        createSub = Amplify.API.subscribe(GraphQLRequest<String>(document: 'subscription { onCreateDeals { id } }')).listen((_) => fetchAndEmit(), onError: (e) => debugPrint('Deal create sub error: $e'));
        updateSub = Amplify.API.subscribe(GraphQLRequest<String>(document: 'subscription { onUpdateDeals { id } }')).listen((_) => fetchAndEmit(), onError: (e) => debugPrint('Deal update sub error: $e'));
        deleteSub = Amplify.API.subscribe(GraphQLRequest<String>(document: 'subscription { onDeleteDeals { id } }')).listen((_) => fetchAndEmit(), onError: (e) => debugPrint('Deal delete sub error: $e'));
      },
      onCancel: () {
        createSub?.cancel();
        updateSub?.cancel();
        deleteSub?.cancel();
      }
    );

    return controller.stream;
  }

  Future<void> deleteDeal(dynamic id) async {
    try {
      await BackupAwareApi().deleteById(Deals.classType, DealsModelIdentifier(id: id.toString())
      );
    } catch (e) {
      debugPrint('Error deleteDeal: $e');
    }
  }

  Future<old.Deal?> getDealById(dynamic id) async {
    try {
      final req = ModelQueries.list(Deals.classType, where: Deals.ID.eq(id.toString()), limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      if (res.data?.items.isNotEmpty == true) {
        return old.Deal.fromMap(res.data!.items.first!.toJson());
      }
    } catch (e) {
      debugPrint('Error getDealById: $e');
    }
    return null;
  }

  Future<List<old.Deal>> getDealsByStage(String stage) async {
    try {
      var req = ModelQueries.list(Deals.classType, where: Deals.STAGE.eq(stage), limit: 10000);
      List<Deals> all = [];
      while (true) {
        final res = await Amplify.API.query(request: req).response;
        all.addAll(res.data?.items.where((e) => e != null).cast<Deals>() ?? []);
        if (res.data?.hasNextResult ?? false) {
          req = res.data!.requestForNextResult!;
        } else {
          break;
        }
      }
      all.sort((a, b) => (b.updatedAt?.toString() ?? '').compareTo(a.updatedAt?.toString() ?? ''));
      return all.map((m) => old.Deal.fromMap(m.toJson())).toList();
    } catch (e) {
      debugPrint('Error getDealsByStage: $e');
      return [];
    }
  }

  Future<dynamic> createDeal(old.Deal deal, {bool sendNotification = true}) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('current_user_id');
    final userName = prefs.getString('user_name');

    final Map<String, dynamic> values = deal.toMap();
    values['id'] = values['id']?.toString() ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    if (values['responsible_id'] == null) values['responsible_id'] = userId;
    if (values['responsible_name'] == null) values['responsible_name'] = userName;
    if (values['created_at'] == null) values['created_at'] = DateTime.now().toIso8601String();
    if (values['updated_at'] == null) values['updated_at'] = DateTime.now().toIso8601String();

    if (values['expenses_list'] is List) {
      values['expenses_list'] = jsonEncode(values['expenses_list']);
    } else if (values['expenses_list'] != null) {
      values['expenses_list'] = values['expenses_list'].toString();
    }

    try {
      final newDeal = Deals.fromJson(values);
      final res = await BackupAwareApi().create(newDeal);
      final dealId = res.data?.id;

      if (dealId != null && userId != null) {
        final assignee = DealAssignees(deal_id: int.tryParse(dealId.toString()), user_id: userId, role: 'Lead');
        await BackupAwareApi().create(assignee);
      }

      if (dealId != null) {
        await addActivity(oldActivity.DealActivity(
          dealId: dealId,
          type: 'status',
          title: 'Work Created',
          description: 'Project pipeline started at stage: ${deal.stage}',
          createdBy: userId ?? 1,
        ));

        if (sendNotification) {
          await NotificationService().notifyStakeholders(
            title: 'New Work Created',
            message: '${userName ?? 'A staff member'} created a new work: ${deal.name}',
            dealId: dealId,
          );
        }

        // Send lively WhatsApp notification to assigned staff member
        final assignedStaffId = values['responsible_id'];
        if (assignedStaffId != null) {
          unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
            staffUserId: assignedStaffId,
            assignmentTitle: deal.name,
            workOrTaskType: 'New Work Assignment',
            clientName: deal.clientName,
            priority: deal.priority,
            assignedByName: userName ?? 'Management',
            details: deal.description ?? 'New work assigned to you in CUC System.',
          ));
        }
      }

      return dealId;
    } catch (e) {
      debugPrint('Error createDeal: $e');
      rethrow;
    }
  }

  Future<void> updateDeal(old.Deal deal) async {
    final Map<String, dynamic> values = deal.toMap();
    final id = values['id'] ?? deal.id;
    values.remove('id');
    
    try {
      Deals? c;
      try {
        final req = ModelQueries.get(Deals.classType, DealsModelIdentifier(id: id.toString()));
        final res = await Amplify.API.query(request: req).response;
        c = res.data;
      } catch (e) {
        debugPrint('Direct get in updateDeal failed: $e');
      }

      if (c == null) {
        final listReq = ModelQueries.list(Deals.classType, where: Deals.ID.eq(id.toString()), limit: 1);
        final listRes = await Amplify.API.query(request: listReq).response;
        if (listRes.data?.items.isNotEmpty == true) {
          c = listRes.data!.items.first;
        }
      }

      final Deals updated;
      if (c != null) {
        updated = c.copyWith(
          name: values['name'],
          client_id: values['client_id'],
          client_name: values['client_name'],
          contact_info: values['contact_info'],
          company: values['company'],
          work_type: values['work_type'],
          stage: values['stage'],
          responsible_id: values['responsible_id'],
          responsible_name: values['responsible_name'],
          amount: values['amount'] != null ? double.tryParse(values['amount'].toString()) : null,
          currency: values['currency'],
          pipeline: values['pipeline'],
          priority: values['priority'],
          description: values['description'],
          is_won: values['is_won'],
          reg_fee_required: values['reg_fee_required'],
          referred_by: values['referred_by'],
          files_received: values['files_received'],
          contact_status: values['contact_status'],
          files_asked: values['files_asked'],
          est_amount_work: values['est_amount_work'] != null ? double.tryParse(values['est_amount_work'].toString()) : null,
          create_invoice_share: values['create_invoice_share'],
          expense_spent: values['expense_spent'] != null ? double.tryParse(values['expense_spent'].toString()) : null,
          upload_invoice_path: values['upload_invoice_path'],
          send_to_customer: values['send_to_customer'],
          register_no: values['register_no'],
          invoice_amount: values['invoice_amount'] != null ? double.tryParse(values['invoice_amount'].toString()) : null,
          payment_type: values['payment_type'],
          drive_link: values['drive_link'],
          billing_id: values['billing_id'],
          quotation_id: values['quotation_id'],
          payment_received: values['payment_received'] != null ? double.tryParse(values['payment_received'].toString()) : null,
          part_payment_amount: values['part_payment_amount'] != null ? double.tryParse(values['part_payment_amount'].toString()) : null,
          noc_obtained: values['noc_obtained'],
          expenses_list: values['expenses_list'] is List ? jsonEncode(values['expenses_list']) : values['expenses_list']?.toString(),
        );
      } else {
        values['id'] = id.toString();
        updated = Deals.fromJson(values);
      }
      
      await BackupAwareApi().update(updated);

      await NotificationService().notifyStakeholders(
        title: 'Work Updated',
        message: 'Work "${deal.name}" has been updated.',
        dealId: deal.id,
      );
    } catch (e) {
      debugPrint('Error updateDeal: $e');
      rethrow;
    }
  }

  Future<void> passLeadToWork({
    required old.Deal lead,
    required String clientId,
    required String clientName,
    int? currentUserId,
  }) async {
    final updatedDeal = lead.copyWith(
      clientId: int.tryParse(clientId) ?? lead.clientId,
      clientName: clientName,
      isWon: true,
      stage: (lead.stage == 'Registration' || lead.stage == 'Contact Customer' || lead.stage == 'Lead')
          ? 'Work Started'
          : lead.stage,
      closedAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await updateDeal(updatedDeal);

    await addActivity(oldActivity.DealActivity(
      dealId: lead.id!,
      type: 'status',
      title: 'Lead Passed to Work & Client',
      description: 'Passed from CRM into active Work Management and registered as Client in Client Management.',
      createdBy: currentUserId ?? 1,
    ));

    await NotificationService().notifyStakeholders(
      title: 'CRM Lead Passed to Work',
      message: 'Lead "${lead.name}" for client "$clientName" was passed to Work Management.',
      dealId: lead.id,
    );
  }

  Future<void> moveDealToStage(dynamic dealId, String fromStage, String toStage) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('current_user_id');

    try {
      final req = ModelQueries.list(Deals.classType, where: Deals.ID.eq(dealId.toString()), limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      if (res.data?.items.isEmpty == true) return;
      
      final c = res.data!.items.first!;
      final updated = c.copyWith(stage: toStage);
      await BackupAwareApi().update(updated);

      final hist = DealStageHistory(
        deal_id: int.tryParse(dealId.toString()),
        from_stage: fromStage,
        to_stage: toStage,
        changed_by: userId,
      );
      await BackupAwareApi().create(hist);

      final dealName = c.name ?? 'Unknown Deal';
      final responsibleId = c.responsible_id;
      
      if (toStage == 'Completed' && responsibleId != null) {
        await NotificationService().sendNotification(
          userId: responsibleId,
          title: 'Work Completed',
          message: 'Your work "$dealName" has been marked as Completed.',
          type: 'completion',
          dealId: dealId,
        );
      } else {
        await NotificationService().notifyStakeholders(
          title: 'Work Stage Updated',
          message: 'Work "$dealName" moved from $fromStage to $toStage',
          dealId: dealId,
        );
      }
    } catch (e) {
      debugPrint('Error moveDealToStage: $e');
    }
  }

  Future<void> handoverDeal(dynamic dealId, int fromUserId, int toUserId, String note) async {
    try {
      final handover = DealHandoverHistory(
        deal_id: int.tryParse(dealId.toString()),
        from_user_id: fromUserId,
        to_user_id: toUserId,
        note: note,
      );
      await BackupAwareApi().create(handover);

      // 2. Update primary responsible person
      String toUserName = 'Unknown';
      final uReq = ModelQueries.list(Users.classType, where: Users.ID.eq(toUserId), limit: 10000);
      final uRes = await Amplify.API.query(request: uReq).response;
      if (uRes.data?.items.isNotEmpty == true) toUserName = uRes.data!.items.first?.name ?? 'Unknown';

      final dReq = ModelQueries.list(Deals.classType, where: Deals.ID.eq(dealId.toString()), limit: 10000);
      final dRes = await Amplify.API.query(request: dReq).response;
      if (dRes.data?.items.isNotEmpty == true) {
        final c = dRes.data!.items.first!;
        final updated = c.copyWith(
          responsible_id: toUserId,
          responsible_name: toUserName,
        );
        await BackupAwareApi().update(updated);

        // 3. Ensure new person is an assignee with Lead role
        final aReq1 = ModelQueries.list(DealAssignees.classType, where: DealAssignees.DEAL_ID.eq(dealId.toString()).and(DealAssignees.USER_ID.eq(fromUserId)), limit: 10000);
        final aRes1 = await Amplify.API.query(request: aReq1).response;
        if (aRes1.data?.items.isNotEmpty == true) {
          final a1 = aRes1.data!.items.first!;
          await BackupAwareApi().update(a1.copyWith(role: 'Collaborator'));
        }

        final aReq2 = ModelQueries.list(DealAssignees.classType, where: DealAssignees.DEAL_ID.eq(dealId.toString()).and(DealAssignees.USER_ID.eq(toUserId)), limit: 10000);
        final aRes2 = await Amplify.API.query(request: aReq2).response;
        if (aRes2.data?.items.isNotEmpty == true) {
          final a2 = aRes2.data!.items.first!;
          await BackupAwareApi().update(a2.copyWith(role: 'Lead'));
        } else {
          final newA = DealAssignees(deal_id: int.tryParse(dealId.toString()), user_id: toUserId, role: 'Lead');
          await BackupAwareApi().create(newA);
        }

        String fromUserName = 'Unknown';
        final fReq = ModelQueries.list(Users.classType, where: Users.ID.eq(fromUserId), limit: 10000);
        final fRes = await Amplify.API.query(request: fReq).response;
        if (fRes.data?.items.isNotEmpty == true) fromUserName = fRes.data!.items.first?.name ?? 'Unknown';

        final dealName = c.name ?? 'Work';

        await NotificationService().notifyStakeholders(
          title: 'Work Handover',
          message: '$fromUserName handed over work "$dealName" to you ($toUserName). Note: $note',
          type: 'assignment',
          dealId: dealId,
        );

        unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
          staffUserId: toUserId,
          assignmentTitle: dealName,
          workOrTaskType: 'Work Handover',
          clientName: c.client_name,
          assignedByName: fromUserName,
          details: note.isNotEmpty ? note : 'Work has been handed over to you.',
        ));
      }
    } catch (e) {
      debugPrint('Error handoverDeal: $e');
    }
  }

  Future<void> addAssignee(dynamic dealId, int userId, {String role = 'Collaborator'}) async {
    try {
      final parsedDealId = int.tryParse(dealId.toString()) ?? 0;
      final aReq = ModelQueries.list(DealAssignees.classType, where: DealAssignees.DEAL_ID.eq(parsedDealId).and(DealAssignees.USER_ID.eq(userId)), limit: 10000);
      final aRes = await Amplify.API.query(request: aReq).response;
      if (aRes.data?.items.isNotEmpty == true) {
        final a = aRes.data!.items.first!;
        await BackupAwareApi().update(a.copyWith(role: role));
      } else {
        final newA = DealAssignees(deal_id: int.tryParse(dealId.toString()), user_id: userId, role: role);
        await BackupAwareApi().create(newA);
      }

      String dealName = 'Work';
      final dReq = ModelQueries.list(Deals.classType, where: Deals.ID.eq(dealId.toString()), limit: 10000);
      final dRes = await Amplify.API.query(request: dReq).response;
      if (dRes.data?.items.isNotEmpty == true) dealName = dRes.data!.items.first?.name ?? 'Work';

      await NotificationService().notifyStakeholders(
        dealId: dealId,
        title: 'Work Team Updated',
        message: 'Team for "$dealName" has been updated.',
        type: 'assignment',
      );

      unawaited(WhatsAppCloudService().notifyStaffOfAssignment(
        staffUserId: userId,
        assignmentTitle: dealName,
        workOrTaskType: 'Work Team ($role)',
        details: 'You have been assigned to "$dealName" as a team member ($role).',
      ));
    } catch (e) {
      debugPrint('Error addAssignee: $e');
    }
  }

  Future<void> removeAssignee(dynamic dealId, int userId) async {
    try {
      final parsedDealId = int.tryParse(dealId.toString()) ?? 0;
      final aReq = ModelQueries.list(DealAssignees.classType, where: DealAssignees.DEAL_ID.eq(parsedDealId).and(DealAssignees.USER_ID.eq(userId)), limit: 10000);
      final aRes = await Amplify.API.query(request: aReq).response;
      if (aRes.data?.items.isNotEmpty == true) {
        await BackupAwareApi().delete(aRes.data!.items.first!);
      }
    } catch (e) {
      debugPrint('Error removeAssignee: $e');
    }
  }

  Future<List<old.DealAssignee>> getAssignees(dynamic dealId) async {
    try {
      final parsedDealId = int.tryParse(dealId.toString()) ?? 0;
      final aReq = ModelQueries.list(DealAssignees.classType, where: DealAssignees.DEAL_ID.eq(parsedDealId), limit: 10000);
      final aRes = await Amplify.API.query(request: aReq).response;
      var items = aRes.data?.items.where((e) => e != null).cast<DealAssignees>().toList() ?? [];
      
      List<old.DealAssignee> result = [];
      for (var a in items) {
        String? uName;
        if (a.user_id != null) {
          final uReq = ModelQueries.list(Users.classType, where: Users.ID.eq(a.user_id), limit: 10000);
          final uRes = await Amplify.API.query(request: uReq).response;
          if (uRes.data?.items.isNotEmpty == true) uName = uRes.data!.items.first?.name;
        }
        result.add(old.DealAssignee.fromMap({
          ...a.toJson(),
          'user_name': uName,
        }));
      }
      return result;
    } catch (e) {
      debugPrint('Error getAssignees: $e');
      return [];
    }
  }


  Future<void> addActivity(oldActivity.DealActivity activity) async {
    try {
      final values = activity.toMap();
      values['id'] = values['id']?.toString() ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
      values.remove('is_completed');
      // deal_id is now String in the schema, so just convert to string
      if (values['deal_id'] != null) {
        values['deal_id'] = values['deal_id'].toString();
      }
      // Ensure created_by is int for the schema
      if (values['created_by'] != null) {
        values['created_by'] = values['created_by'] is int ? values['created_by'] : int.tryParse(values['created_by'].toString());
      }
      if (values['created_at'] == null) {
        values['created_at'] = DateTime.now().toIso8601String();
      }
      
      final newAct = DealActivities.fromJson(values);
      await BackupAwareApi().create(newAct);
    } catch (e, stackTrace) {
      debugPrint('Error addActivity: $e');
      debugPrint('Stack: $stackTrace');
    }
  }

  Future<List<oldActivity.DealActivity>> getActivities(dynamic dealId) async {
    try {
      final dealIdStr = dealId.toString();
      var req = ModelQueries.list(DealActivities.classType, where: DealActivities.DEAL_ID.eq(dealIdStr), limit: 10000);
      List<DealActivities> all = [];
      while (true) {
        final res = await Amplify.API.query(request: req).response;
        all.addAll(res.data?.items.where((e) => e != null).cast<DealActivities>() ?? []);
        if (res.data?.hasNextResult ?? false) {
          req = res.data!.requestForNextResult!;
        } else {
          break;
        }
      }
      all.sort((a, b) => (b.createdAt?.toString() ?? '').compareTo(a.createdAt?.toString() ?? ''));
      
      final users = await getAllUsers();
      final userMap = <int, String>{};
      for (var u in users) {
        int id = u['id'] is int ? u['id'] : int.tryParse(u['id']?.toString() ?? '') ?? 0;
        userMap[id] = u['name'] as String? ?? 'Unknown';
      }
      
      return all.map((a) {
        final j = a.toJson();
        final cId = a.created_by;
        if (cId != null) j['creator_name'] = userMap[cId] ?? 'Unknown';
        return oldActivity.DealActivity.fromMap(j);
      }).toList();
    } catch (e) {
      debugPrint('Error getActivities: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getVerificationHistory() async {
    try {
      var req = ModelQueries.list(DealActivities.classType, limit: 10000);
      List<DealActivities> allActs = [];
      while (true) {
        final res = await Amplify.API.query(request: req).response;
        allActs.addAll(res.data?.items.where((e) => e != null && (e.title == 'Work Verified' || e.title == 'Reverification Needed')).cast<DealActivities>() ?? []);
        if (res.data?.hasNextResult ?? false) {
          req = res.data!.requestForNextResult!;
        } else {
          break;
        }
      }
      allActs.sort((a, b) => (b.createdAt?.toString() ?? '').compareTo(a.createdAt?.toString() ?? ''));

      final users = await getAllUsers();
      final userMap = <int, String>{};
      for (var u in users) {
        int id = u['id'] is int ? u['id'] : int.tryParse(u['id']?.toString() ?? '') ?? 0;
        userMap[id] = u['name'] as String? ?? 'Unknown';
      }
      
      List<Map<String, dynamic>> mapped = [];
      for (var a in allActs) {
        Map<String, dynamic>? dealData;
        if (a.deal_id != null) {
          final dReq = ModelQueries.list(Deals.classType, where: Deals.ID.eq(a.deal_id.toString()), limit: 10000);
          final dRes = await Amplify.API.query(request: dReq).response;
          if (dRes.data?.items.isNotEmpty == true) {
            dealData = dRes.data!.items.first!.toJson();
          }
        }

        mapped.add({
          'id': a.id,
          'deal_id': a.deal_id,
          'deal_name': dealData?['name'] ?? 'Unknown Deal',
          'drive_link': dealData?['drive_link'],
          'sender': dealData?['responsible_name'] ?? 'Unknown',
          'reviewer': userMap[a.created_by] ?? 'Unknown',
          'status': a.title == 'Work Verified' ? 'Verified' : 'Rejected',
          'reason': a.title == 'Work Verified' ? '-' : a.description?.replaceAll('Returned for reverification. Remarks: ', '') ?? '',
          'created_at': a.createdAt?.toString(),
        });
      }
      return mapped;
    } catch (e) {
      debugPrint('Error getVerificationHistory: $e');
      return [];
    }
  }

  Future<void> toggleActivityCompletion(dynamic activityId, bool completed) async {
    try {
      final req = ModelQueries.list(DealActivities.classType, where: DealActivities.ID.eq(activityId.toString()), limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      if (res.data?.items.isNotEmpty == true) {
        final c = res.data!.items.first!;
        await BackupAwareApi().update(c.copyWith(is_completed: completed));
      }
    } catch (e) {
      debugPrint('Error toggleActivityCompletion: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getAllUsers() async {
    try {
      var req = ModelQueries.list(Users.classType, limit: 10000);
      List<Users> all = [];
      while (true) {
        final res = await Amplify.API.query(request: req).response;
        all.addAll(res.data?.items.where((e) => e != null).cast<Users>() ?? []);
        if (res.data?.hasNextResult ?? false) {
          req = res.data!.requestForNextResult!;
        } else {
          break;
        }
      }
      
      // Deduplicate by ID
      final uniqueMap = <String, Users>{};
      for (var u in all) {
        uniqueMap[u.id] = u;
      }
      all = uniqueMap.values.toList();
      
      all.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      return all.map((u) => u.toJson()).toList();
    } catch (e) {
      debugPrint('Error getAllUsers: $e');
      return [];
    }
  }

  /// Remove duplicate CRM leads by matching 10-digit phone number or Meta Lead ID
  Future<int> cleanDuplicateLeads() async {
    try {
      final all = await getAllDeals();
      final crmDeals = all.where((d) {
        final p = d.pipeline.toLowerCase();
        return p == 'crm' || p == 'lead';
      }).toList();

      final groups = <String, List<old.Deal>>{};
      for (final d in crmDeals) {
        final phone = (d.contactInfo ?? '').replaceAll(RegExp(r'[^0-9]'), '');
        final phone10 = phone.length >= 10 ? phone.substring(phone.length - 10) : phone;
        final name = d.name.trim().toLowerCase();
        final key = phone10.isNotEmpty
            ? phone10
            : (d.registerNo?.isNotEmpty == true ? d.registerNo! : name);
        groups.putIfAbsent(key, () => []).add(d);
      }

      int deletedCount = 0;
      for (final entry in groups.entries) {
        final list = entry.value;
        if (list.length > 1) {
          list.sort((a, b) {
            final aStage = a.stage.toLowerCase().trim();
            final bStage = b.stage.toLowerCase().trim();
            if (aStage != 'created' && bStage == 'created') return -1;
            if (bStage != 'created' && aStage == 'created') return 1;
            if (a.postponedDate != null && b.postponedDate == null) return -1;
            if (b.postponedDate != null && a.postponedDate == null) return 1;
            final aDate = a.createdAt?.toIso8601String() ?? '';
            final bDate = b.createdAt?.toIso8601String() ?? '';
            return aDate.compareTo(bDate);
          });

          for (int i = 1; i < list.length; i++) {
            final toDelete = list[i];
            if (toDelete.id != null) {
              await deleteDeal(toDelete.id);
              deletedCount++;
            }
          }
        }
      }
      return deletedCount;
    } catch (e) {
      debugPrint('Error cleanDuplicateLeads: $e');
      return 0;
    }
  }
}
