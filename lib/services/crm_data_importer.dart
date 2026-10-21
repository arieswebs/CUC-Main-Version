import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/deal.dart';
import 'deal_service.dart';

class CrmDataImporter {
  static const List<Map<String, String>> sheetRecords = [
    {
      'date': '2026-10-05',
      'phone': '9207533444',
      'name': 'Vijayan',
      'requirement': 'Railway NOC',
      'remark': 'follow up , clint is waiting for the house plan from his engineer,once he receives it, he will get in touchwith us, check list send',
    },
    {
      'date': '2026-10-05',
      'phone': '7594913694',
      'name': 'philomina',
      'requirement': 'business loan(project report)',
      'remark': 'follow up, clint said that she is confused about the loan sanction and will contact as soon, check listband quotation also send',
    },
    {
      'date': '2026-10-06',
      'phone': '9048190609',
      'name': 'jesto',
      'requirement': 'RA license',
      'remark': 'follow up,check list and quotation also send, he is not responding yet',
    },
    {
      'date': '2026-10-06',
      'phone': '8086689966',
      'name': 'sujith',
      'requirement': 'trade lisence',
      'remark': 'follow up',
    },
    {
      'date': '2026-10-07',
      'phone': '8590241730',
      'name': 'kavya',
      'requirement': 'fssai leballing',
      'remark': 'follow up,check list send / slightle not intrested to talk',
    },
    {
      'date': '2026-10-10',
      'phone': '9847402269',
      'name': 'justin',
      'requirement': 'ownership change',
      'remark': 'follow up, check list send, waiting for his replay/ (1000sq.ft commercial build gift)',
    },
    {
      'date': '2026-10-12',
      'phone': '9895735494',
      'name': 'dileep',
      'requirement': 'name change',
      'remark': 'not intested',
    },
    {
      'date': '2026-10-12',
      'phone': '808928606',
      'name': 'delvin',
      'requirement': 'trade lisence',
      'remark': 'follow up, patnership, checklist send',
    },
    {
      'date': '2026-10-12',
      'phone': '9633038013',
      'name': 'nijo',
      'requirement': 'vechicle license',
      'remark': 'not intested/ bcz not meet our quotation',
    },
    {
      'date': '2026-10-12',
      'phone': '8593033514',
      'name': 'anagha',
      'requirement': 'llp',
      'remark': 'follow up, check list and quotation send',
    },
    {
      'date': '2026-10-13',
      'phone': '7010950551',
      'name': 'priya',
      'requirement': 'fssai',
      'remark': 'follow up.plan to run a resturent, send check list',
    },
    {
      'date': '2026-10-13',
      'phone': '9074538628',
      'name': 'asif',
      'requirement': 'name change',
      'remark': 'fpllow up, relative name change/send check list and quotation/ he is planning to visit our office and wll inform as later',
    },
    {
      'date': '2026-10-13',
      'phone': '9645873681',
      'name': 'varghese',
      'requirement': 'name change',
      'remark': "follow up, the clint is planning to visit our office /grand child's name chnge and will inform us later/ contact monday",
    },
    {
      'date': '2026-10-13',
      'phone': '9995855085',
      'name': 'nikhil',
      'requirement': 'metro NOC',
      'remark': 'cust want metro noc and cooperation lisence also/ a call arranged/',
    },
    {
      'date': '2026-10-13',
      'phone': '9895517444',
      'name': 'muhammed',
      'requirement': 'BOQ',
      'remark': 'thev cust has been hndld by irshad sir bother, not intrested',
    },
    {
      'date': '2026-10-13',
      'phone': '9895412525',
      'name': 'azhar',
      'requirement': 'passport renewal',
      'remark': 'follow up/ contact sat',
    },
    {
      'date': '2026-10-13',
      'phone': '8401224298',
      'name': 'Sreeja',
      'requirement': 'marrage register',
      'remark': 'follow up/ not respond',
    },
    {
      'date': '2026-10-13',
      'phone': '7594959033',
      'name': 'Akhil',
      'requirement': 'Drug license',
      'remark': 'follow up/ contact sat',
    },
    {
      'date': '2026-10-14',
      'phone': '9497775183',
      'name': 'vineet',
      'requirement': 'export and export',
      'remark': '',
    },
    {
      'date': '2026-10-14',
      'phone': '8050947181',
      'name': 'mahesh',
      'requirement': 'name change',
      'remark': 'check list and quotation snd/ not intrested bcz not meet our quotation',
    },
    {
      'date': '2026-10-14',
      'phone': '9516626262',
      'name': 'Ali Ahammed',
      'requirement': 'business set up',
      'remark': 'tomrw visit/ will call',
    },
    {
      'date': '2026-10-14',
      'phone': '6238716229',
      'name': 'vineeth',
      'requirement': 'vihicle ownership',
      'remark': 'check list and quotation snd',
    },
    {
      'date': '2026-10-16',
      'phone': '9605201408',
      'name': 'Abhai',
      'requirement': 'Manufacture drugus',
      'remark': '',
    },
  ];

  /// Check if an entry is already present in CRM deals
  static bool isImported(Map<String, String> item, List<Deal> existingDeals) {
    final phone = item['phone']?.trim() ?? '';
    final name = (item['name'] ?? '').trim().toLowerCase();
    final req = (item['requirement'] ?? '').trim().toLowerCase();

    return existingDeals.any((d) {
      final dPhone = (d.contactInfo ?? '').trim();
      final dName = d.name.trim().toLowerCase();
      final dReq = (d.workType ?? '').trim().toLowerCase();

      if (phone.isNotEmpty && dPhone.isNotEmpty && phone == dPhone) {
        return true;
      }
      if (name.isNotEmpty && dName == name && req.isNotEmpty && dReq == req) {
        return true;
      }
      return false;
    });
  }

  /// Get pending unimported records
  static List<Map<String, String>> getPending(List<Deal> existingDeals) {
    return sheetRecords.where((item) => !isImported(item, existingDeals)).toList();
  }

  /// Import all pending leads into CRM
  static Future<int> importPending({
    required DealService dealService,
    required List<Deal> existingDeals,
    void Function(int done, int total)? onProgress,
  }) async {
    final pending = getPending(existingDeals);
    if (pending.isEmpty) return 0;

    int importedCount = 0;
    for (int i = 0; i < pending.length; i++) {
      final item = pending[i];
      try {
        final parsedDate = DateTime.tryParse(item['date'] ?? '') ?? DateTime.now();
        final rawName = (item['name'] ?? 'Inquiry').trim();
        final formattedName = rawName.isNotEmpty
            ? rawName[0].toUpperCase() + rawName.substring(1)
            : 'Inquiry';

        final remarkLower = (item['remark'] ?? '').toLowerCase();
        final bool isLost = remarkLower.contains('not intrested') ||
            remarkLower.contains('not interested') ||
            remarkLower.contains('not intested');

        final newLead = Deal(
          name: formattedName,
          clientName: formattedName,
          contactInfo: item['phone']?.trim(),
          workType: item['requirement']?.trim().isNotEmpty == true
              ? item['requirement']!.trim()
              : 'General Inquiry',
          description: item['remark']?.trim() ?? '',
          pipeline: 'CRM',
          stage: isLost ? 'Deal Lose' : 'Created',
          priority: 'Normal',
          amount: 0.0,
          currency: 'INR',
          isWon: false,
          createdAt: parsedDate,
        );

        await dealService.createDeal(newLead, sendNotification: false);
        importedCount++;
        onProgress?.call(i + 1, pending.length);

        // Small delay to ensure timestamp separation
        await Future.delayed(const Duration(milliseconds: 150));
      } catch (e) {
        debugPrint('Error importing lead ${item['name']}: $e');
      }
    }
    return importedCount;
  }
}
