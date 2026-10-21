import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart';
import 'backup_aware_api.dart';
import 'logging_service.dart';

class ClientService {

  Future<List<Map<String, dynamic>>> searchClients(String query) async {
    try {
      final req = ModelQueries.list(
        Clients.classType,
        limit: 10000
      );
      final res = await Amplify.API.query(request: req).response;
      var items = (res.data?.items ?? []).whereType<Clients>().toList();
      
      final lowerQuery = query.toLowerCase();
      var filtered = items.where((c) => (c.name ?? '').toLowerCase().contains(lowerQuery)).toList();
      
      return filtered.take(10).map((c) => {
        'id': c.id,
        'name': c.name,
        'address': c.address,
        'phone': c.phone,
        'email': c.email,
        'type_of_work': c.type_of_work,
        'balance_due': c.balance_due,
        'companies': c.companies,
      }).toList();
    } catch (e) {
      safePrint('Error searchClients: $e');
      return [];
    }
  }
  
  Future<List<Map<String, dynamic>>> getAllClients() async {
    try {
      final req = ModelQueries.list(Clients.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      var items = res.data?.items.where((e) => e != null).cast<Clients>().toList() ?? [];
      
      items.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      return items.map((c) => c.toJson()).toList();
    } catch (e) {
      safePrint('Error getAllClients: $e');
      return [];
    }
  }

  /// Finds an existing client matching the lead, or registers a new client with an official CUC registration number.
  Future<Clients> getOrCreateClientForLead({
    required String clientName,
    String? phone,
    String? email,
    String? company,
    String? typeOfWork,
  }) async {
    try {
      final req = ModelQueries.list(Clients.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      final clientsList = (res.data?.items ?? []).whereType<Clients>().toList();

      final cleanName = clientName.trim().toLowerCase();
      final cleanPhone = phone?.replaceAll(RegExp(r'\D'), '') ?? '';

      // Check if client already exists by name or phone
      for (final c in clientsList) {
        final cName = (c.name ?? '').trim().toLowerCase();
        final cPhone = (c.phone ?? '').replaceAll(RegExp(r'\D'), '');

        if (cleanName.isNotEmpty && cName == cleanName) {
          return c;
        }
        if (cleanPhone.isNotEmpty && cleanPhone.length >= 10 && cPhone == cleanPhone) {
          return c;
        }
      }

      // Compute next case number (e.g. CUC-0042)
      int maxRegNo = 0;
      for (var c in clientsList) {
        if (c.case_number != null && c.case_number!.startsWith('CUC-')) {
          final match = RegExp(r'\d+').firstMatch(c.case_number!);
          if (match != null) {
            final num = int.tryParse(match.group(0)!) ?? 0;
            if (num > maxRegNo) maxRegNo = num;
          }
        }
      }
      final newRegNo = 'CUC-${(maxRegNo + 1).toString().padLeft(4, '0')}';

      final newClient = Clients(
        name: clientName.trim(),
        phone: phone?.trim(),
        email: email?.trim(),
        type_of_work: typeOfWork,
        case_number: newRegNo,
        companies: (company != null && company.trim().isNotEmpty) ? [company.trim()] : null,
        created_at: DateTime.now().toIso8601String(),
        is_contacted: true,
      );

      final createRes = await BackupAwareApi().create(newClient);
      final createdObj = createRes.data ?? newClient;

      await LoggingService().logAction(
        action: 'CLIENT_CREATED',
        targetType: 'Client',
        targetId: createdObj.id,
        details: 'Client created from passed CRM lead: ${clientName.trim()}',
      );

      return createdObj;
    } catch (e) {
      safePrint('Error getOrCreateClientForLead: $e');
      rethrow;
    }
  }
}
