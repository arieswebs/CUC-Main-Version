import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../models/deal.dart';
import 'deal_service.dart';
import 'notification_service.dart';
import 'logging_service.dart';
import 'supabase_backup_service.dart';

/// Configuration for Meta Developer Platform & WhatsApp Cloud API
class MetaConfig {
  static const String defaultAppId = '1900554747410807';
  static const String defaultAppSecret = '9fa43105b05139d124cbcdca087e7ae6';
  static const String defaultGraphApiVersion = 'v19.0';
  static const String defaultVerifyToken = 'cuc_meta_verify_token_2026';
  static const String defaultPageId = '900929969768115';
  static const String defaultFormId = ''; // Blank = Automatically discover & sync all active forms on the Page!
  static const String defaultAccessToken =
      'EAAbAi2KYeXcBS1nCfNqRxa6vM2PDliFwQ0jAIXCqUP9WRF8Oh8gx9AveihGNZCuGxUUcM9xro3x6KiEpirFu4t8iwAOzwZAZAdZCeJgkRnBxbVEOiCKXEfrczDzjktvnOxIG53slI1YBLk2pLiOZCDyZBygmM87ZCEZBeMKMZCd1C35Y7SfW3tfePidDE8qmCiQZDZD';

  // WhatsApp Cloud API Defaults
  static const String defaultWhatsAppPhoneId = '979396128599210';
  static const String defaultWhatsAppWabaId = '1414737783529187';
  static const String defaultNotifyAdminPhone = '917012466754, 917907675024';

  String appId;
  String appSecret;
  String graphApiVersion;
  String accessToken;
  String pageId;
  String formId;
  String webhookVerifyToken;

  // WhatsApp Cloud API
  String whatsappPhoneNumberId; // Customer-facing WhatsApp number ID
  String internalOpsWhatsAppPhoneId; // Internal operations WhatsApp number ID
  String whatsappWabaId;
  bool preferCloudApi;
  String notifyAdminPhone;
  bool notifyOnNewLead;
  bool notifyStaffOnAssignment;

  MetaConfig({
    this.appId = defaultAppId,
    this.appSecret = defaultAppSecret,
    this.graphApiVersion = defaultGraphApiVersion,
    this.accessToken = defaultAccessToken,
    this.pageId = defaultPageId,
    this.formId = defaultFormId,
    this.webhookVerifyToken = defaultVerifyToken,
    this.whatsappPhoneNumberId = defaultWhatsAppPhoneId,
    this.internalOpsWhatsAppPhoneId = '',
    this.whatsappWabaId = defaultWhatsAppWabaId,
    this.preferCloudApi = true,
    this.notifyAdminPhone = defaultNotifyAdminPhone,
    this.notifyOnNewLead = true,
    this.notifyStaffOnAssignment = true,
  });

  static Future<MetaConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString('meta_access_token');
    final savedPageId = prefs.getString('meta_page_id');
    final savedFormId = prefs.getString('meta_form_id');
    final savedWaPhoneId = prefs.getString('meta_wa_phone_id');
    final savedInternalPhoneId = prefs.getString('meta_internal_ops_wa_phone_id');
    final savedWaWabaId = prefs.getString('meta_wa_waba_id');
    final savedNotifyPhone = prefs.getString('meta_notify_phone');

    final configVersion = prefs.getInt('meta_config_version') ?? 0;
    String effectiveToken = defaultAccessToken;
    if (configVersion >= 4 && savedToken != null && savedToken.trim().isNotEmpty) {
      effectiveToken = savedToken;
    } else {
      // Migrate to new active token
      await prefs.setInt('meta_config_version', 4);
      await prefs.setString('meta_access_token', defaultAccessToken);
      effectiveToken = defaultAccessToken;
    }

    String effectiveFormId = savedFormId?.trim() ?? defaultFormId;
    // Migrate old hardcoded valuation form '1083035564715146' so it defaults to syncing ALL active forms
    if (effectiveFormId == '1083035564715146' || configVersion < 4) {
      effectiveFormId = '';
      await prefs.setString('meta_form_id', '');
    }

    return MetaConfig(
      appId: prefs.getString('meta_app_id') ?? defaultAppId,
      appSecret: prefs.getString('meta_app_secret') ?? defaultAppSecret,
      graphApiVersion: prefs.getString('meta_api_version') ?? defaultGraphApiVersion,
      accessToken: effectiveToken,
      pageId: (savedPageId != null && savedPageId.trim().isNotEmpty) ? savedPageId : defaultPageId,
      formId: effectiveFormId,
      webhookVerifyToken: prefs.getString('meta_verify_token') ?? defaultVerifyToken,
      whatsappPhoneNumberId: (savedWaPhoneId != null && savedWaPhoneId.trim().isNotEmpty) ? savedWaPhoneId : defaultWhatsAppPhoneId,
      internalOpsWhatsAppPhoneId: savedInternalPhoneId ?? '',
      whatsappWabaId: (savedWaWabaId != null && savedWaWabaId.trim().isNotEmpty) ? savedWaWabaId : defaultWhatsAppWabaId,
      preferCloudApi: prefs.getBool('meta_prefer_cloud_api') ?? true,
      notifyAdminPhone: (savedNotifyPhone != null && savedNotifyPhone.trim().isNotEmpty) ? savedNotifyPhone : defaultNotifyAdminPhone,
      notifyOnNewLead: prefs.getBool('meta_notify_on_new_lead') ?? true,
      notifyStaffOnAssignment: prefs.getBool('meta_notify_staff_on_assignment') ?? true,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('meta_config_version', 4);
    await prefs.setString('meta_app_id', appId.trim());
    await prefs.setString('meta_app_secret', appSecret.trim());
    await prefs.setString('meta_api_version', graphApiVersion.trim());
    await prefs.setString('meta_access_token', accessToken.trim());
    await prefs.setString('meta_page_id', pageId.trim());
    await prefs.setString('meta_form_id', formId.trim());
    await prefs.setString('meta_verify_token', webhookVerifyToken.trim());
    await prefs.setString('meta_wa_phone_id', whatsappPhoneNumberId.trim());
    await prefs.setString('meta_internal_ops_wa_phone_id', internalOpsWhatsAppPhoneId.trim());
    await prefs.setString('meta_wa_waba_id', whatsappWabaId.trim());
    await prefs.setBool('meta_prefer_cloud_api', preferCloudApi);
    await prefs.setString('meta_notify_phone', notifyAdminPhone.trim());
    await prefs.setBool('meta_notify_on_new_lead', notifyOnNewLead);
    await prefs.setBool('meta_notify_staff_on_assignment', notifyStaffOnAssignment);
  }
}

/// Representation of an incoming Meta Lead (Facebook / Instagram Lead Ads)
class MetaLead {
  final String id;
  final String name;
  final String? phone;
  final String? email;
  final String? city;
  final String? workType;
  final String? adName;
  final String? campaignName;
  final String? formName;
  final DateTime createdTime;
  final Map<String, dynamic> rawFields;

  MetaLead({
    required this.id,
    required this.name,
    this.phone,
    this.email,
    this.city,
    this.workType,
    this.adName,
    this.campaignName,
    this.formName,
    required this.createdTime,
    this.rawFields = const {},
  });

  factory MetaLead.fromGraphApi(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final createdTimeStr = json['created_time']?.toString();
    DateTime createdTime;
    if (createdTimeStr != null) {
      final parsed = DateTime.tryParse(createdTimeStr);
      if (parsed != null) {
        final utc = parsed.isUtc ? parsed : parsed.toUtc();
        createdTime = utc.add(const Duration(hours: 5, minutes: 30));
      } else {
        createdTime = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
      }
    } else {
      createdTime = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    }

    String name = 'Meta Lead';
    String? phone;
    String? email;
    String? city;
    String? startingType;
    String? startingStage;
    String? propertyType;
    String? genericWork;
    final Map<String, dynamic> fieldsMap = {};

    final campaignName = json['campaign_name']?.toString();
    final adName = json['ad_name']?.toString();
    final formName = json['form_name']?.toString();

    final fieldData = json['field_data'];
    if (fieldData is List) {
      for (final item in fieldData) {
        if (item is Map) {
          final fName = (item['name'] ?? '').toString().toLowerCase();
          final values = item['values'];
          final val = (values is List && values.isNotEmpty) ? values.first?.toString() : null;
          if (val == null || val.trim().isEmpty) continue;

          fieldsMap[item['name']?.toString() ?? ''] = val;

          if (fName.contains('full_name') || fName == 'name') {
            name = val;
          } else if (fName.contains('first_name') && name == 'Meta Lead') {
            name = val;
          } else if (fName.contains('phone') || fName.contains('mobile') || fName.contains('contact')) {
            phone = val;
          } else if (fName.contains('email')) {
            email = val;
          } else if (fName.contains('city') || fName.contains('place') || fName.contains('location') || fName.contains('where')) {
            city = val;
          } else if (fName.contains('starting') || fName.contains('restaurant') || fName.contains('hotel')) {
            startingType = val;
          } else if (fName.contains('stage')) {
            startingStage = val.replaceAll('_', ' ');
          } else if (fName.contains('property') || fName.contains('valuation')) {
            propertyType = val;
          } else if (fName.contains('മാറ്റേണ്ടത്') || fName.contains('ഗസറ്റ്')) {
            genericWork = 'Gazette Name Change ($val)';
          } else if (fName.contains('service') || fName.contains('requirement') || fName.contains('work') || fName.contains('inquiry') || fName.contains('type')) {
            genericWork = val;
          }
        }
      }
    }

    String? workType;
    if (startingType != null && startingType.isNotEmpty) {
      final capStarting = startingType[0].toUpperCase() + startingType.substring(1);
      workType = startingStage != null ? '$capStarting ($startingStage)' : capStarting;
    } else if (propertyType != null && propertyType.isNotEmpty) {
      workType = 'Property Valuation ($propertyType)';
    } else if (genericWork != null && genericWork.isNotEmpty) {
      workType = genericWork;
    } else if (campaignName != null && campaignName.toLowerCase().contains('hotel')) {
      workType = 'Hotel / Restaurant Consulting';
    } else if (campaignName != null && campaignName.toLowerCase().contains('valuation')) {
      workType = 'Property Valuation';
    } else if (campaignName != null && campaignName.toLowerCase().contains('name change')) {
      workType = 'Gazette Name Change';
    } else if (formName != null && formName.isNotEmpty) {
      workType = formName;
    } else {
      workType = 'Meta Ad Inquiry';
    }

    return MetaLead(
      id: id,
      name: name,
      phone: phone,
      email: email,
      city: city,
      workType: workType,
      adName: adName,
      campaignName: campaignName,
      formName: formName,
      createdTime: createdTime,
      rawFields: fieldsMap,
    );
  }
}

/// Service to fetch and ingest Leads from Meta Graph API
class MetaLeadService {
  final DealService _dealService = DealService();

  /// Fetch leads directly from Meta Graph API across all active forms or specified Form ID(s)
  Future<List<MetaLead>> fetchLeadsFromMeta({MetaConfig? config}) async {
    final cfg = config ?? await MetaConfig.load();
    if (cfg.accessToken.isEmpty) {
      throw Exception('Meta Graph API Access Token is missing. Please set it in Meta Hub Settings.');
    }

    if (cfg.formId.isEmpty && cfg.pageId.isEmpty) {
      throw Exception('Meta Form ID or Facebook Page ID is required to fetch leads.');
    }

    // 1. Get Page Access Token if Page ID is configured
    String pageToken = cfg.accessToken;
    if (cfg.pageId.isNotEmpty) {
      try {
        final pageTokenUrl = Uri.parse(
          'https://graph.facebook.com/${cfg.graphApiVersion}/${cfg.pageId}'
          '?fields=access_token,name'
          '&access_token=${Uri.encodeComponent(cfg.accessToken)}',
        );
        final pageRes = await http.get(pageTokenUrl);
        if (pageRes.statusCode == 200) {
          final pageData = jsonDecode(pageRes.body);
          if (pageData['access_token'] != null && pageData['access_token'].toString().isNotEmpty) {
            pageToken = pageData['access_token'].toString();
            // Automatically ensure the page is subscribed to leadgen Webhooks so any new ad immediately connects
            try {
              final subUrl = Uri.parse(
                'https://graph.facebook.com/${cfg.graphApiVersion}/${cfg.pageId}/subscribed_apps'
                '?subscribed_fields=leadgen'
                '&access_token=${Uri.encodeComponent(pageToken)}',
              );
              unawaited(http.post(subUrl));
            } catch (_) {}
          }
        }
      } catch (e) {
        debugPrint('Could not exchange for Page Access Token: $e');
      }
    }

    final Set<String> targetFormIds = {};
    final Map<String, String> formNames = {};

    // Helper to fetch leads for a specific form ID
    Future<List<MetaLead>> fetchForForm(String formId, {String? formName}) async {
      final tokenToUse = pageToken.isNotEmpty ? pageToken : cfg.accessToken;
      final url = Uri.parse(
        'https://graph.facebook.com/${cfg.graphApiVersion}/$formId/leads'
        '?fields=id,created_time,field_data,ad_name,campaign_name'
        '&access_token=${Uri.encodeComponent(tokenToUse)}'
        '&limit=100',
      );
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List items = data['data'] ?? [];
        return items.map((i) {
          final m = Map<String, dynamic>.from(i as Map);
          if (formName != null && !m.containsKey('form_name')) {
            m['form_name'] = formName;
          }
          return MetaLead.fromGraphApi(m);
        }).toList();
      } else {
        final err = jsonDecode(res.body);
        final errMsg = err['error']?['message'] ?? res.body;
        if (errMsg.toString().contains('Session has expired') && cfg.accessToken != MetaConfig.defaultAccessToken) {
          debugPrint('🔄 Stored Meta access token was expired. Auto-recovering using fresh active token...');
          cfg.accessToken = MetaConfig.defaultAccessToken;
          await cfg.save();
          final retryUrl = Uri.parse(
            'https://graph.facebook.com/${cfg.graphApiVersion}/$formId/leads'
            '?fields=id,created_time,field_data,ad_name,campaign_name'
            '&access_token=${Uri.encodeComponent(MetaConfig.defaultAccessToken)}'
            '&limit=100',
          );
          final retryRes = await http.get(retryUrl);
          if (retryRes.statusCode == 200) {
            final data = jsonDecode(retryRes.body);
            final List items = data['data'] ?? [];
            return items.map((i) {
              final m = Map<String, dynamic>.from(i as Map);
              if (formName != null && !m.containsKey('form_name')) {
                m['form_name'] = formName;
              }
              return MetaLead.fromGraphApi(m);
            }).toList();
          }
        }
        debugPrint('Meta API Form Error for form $formId (${res.statusCode}): $errMsg');
        return [];
      }
    }

    // 2. Discover all active forms on Facebook Page
    if (cfg.pageId.isNotEmpty) {
      try {
        final formsUrl = Uri.parse(
          'https://graph.facebook.com/${cfg.graphApiVersion}/${cfg.pageId}/leadgen_forms'
          '?fields=id,name,status,leads_count'
          '&access_token=${Uri.encodeComponent(pageToken)}'
          '&limit=50',
        );
        final formsRes = await http.get(formsUrl);
        if (formsRes.statusCode == 200) {
          final formsData = jsonDecode(formsRes.body);
          final List forms = formsData['data'] ?? [];
          for (final f in forms) {
            final fId = f['id']?.toString();
            final fName = f['name']?.toString() ?? '';
            final fStatus = f['status']?.toString().toUpperCase();
            if (fId != null && fId.isNotEmpty && (fStatus == 'ACTIVE' || fStatus == null)) {
              targetFormIds.add(fId);
              if (fName.isNotEmpty) formNames[fId] = fName;
            }
          }
        }
      } catch (e) {
        debugPrint('Error discovering page forms: $e');
      }
    }

    // 3. Add explicit form IDs if specified in cfg.formId (comma or space separated)
    if (cfg.formId.isNotEmpty && cfg.formId.trim().toLowerCase() != 'all') {
      final explicitIds = cfg.formId
          .split(RegExp(r'[,;\s]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty && s.toLowerCase() != 'all');
      targetFormIds.addAll(explicitIds);
    }

    // 4. Fallback if no forms found
    if (targetFormIds.isEmpty) {
      if (cfg.formId.isNotEmpty) {
        targetFormIds.add(cfg.formId.trim());
      } else if (cfg.pageId.isNotEmpty) {
        targetFormIds.add(cfg.pageId.trim());
      }
    }

    // 5. Query all discovered & targeted forms
    final List<MetaLead> allLeads = [];
    final Set<String> seenLeadIds = {};

    for (final fId in targetFormIds) {
      try {
        final formLeads = await fetchForForm(fId, formName: formNames[fId]);
        for (final l in formLeads) {
          if (l.id.isNotEmpty && !seenLeadIds.contains(l.id)) {
            seenLeadIds.add(l.id);
            allLeads.add(l);
          }
        }
      } catch (e) {
        debugPrint('Error fetching leads for form $fId: $e');
      }
    }

    allLeads.sort((a, b) => b.createdTime.compareTo(a.createdTime));
    return allLeads;
  }

  /// Ingest a Meta Lead into CUC CRM as a Deal
  /// Ingest a Meta Lead into CUC CRM as a Deal with database-level deduplication
  Future<dynamic> ingestLeadToCrm(
    MetaLead lead, {
    bool checkDuplicate = true,
    bool sendWhatsAppAlert = true,
    List<Deal>? existingDeals,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final ingestedIds = (prefs.getStringList('ingested_meta_lead_ids') ?? []).toSet();

    if (checkDuplicate && lead.id.isNotEmpty && ingestedIds.contains(lead.id)) {
      debugPrint('Lead ${lead.id} already in local ingested cache.');
      return null;
    }

    if (checkDuplicate) {
      final dealsToCheck = existingDeals ?? await _dealService.getAllDeals();
      final cleanLeadPhone = (lead.phone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
      final cleanLeadPhone10 = cleanLeadPhone.length >= 10
          ? cleanLeadPhone.substring(cleanLeadPhone.length - 10)
          : cleanLeadPhone;
      final leadNameLower = lead.name.trim().toLowerCase();

      final alreadyInDb = dealsToCheck.any((d) {
        // 1. Check by Meta Lead ID if present
        if (lead.id.isNotEmpty) {
          if (d.registerNo == lead.id) return true;
          if (d.description?.contains('Meta Lead ID: ${lead.id}') == true) return true;
        }

        // 2. Check by 10-digit phone number match
        if (cleanLeadPhone10.isNotEmpty && d.contactInfo != null) {
          final dPhone = d.contactInfo!.replaceAll(RegExp(r'[^0-9]'), '');
          final dPhone10 = dPhone.length >= 10 ? dPhone.substring(dPhone.length - 10) : dPhone;
          if (dPhone10 == cleanLeadPhone10) {
            final dName = d.name.trim().toLowerCase();
            // Same 10-digit phone and matching name or both from Meta
            if (dName == leadNameLower ||
                dName.contains(leadNameLower) ||
                leadNameLower.contains(dName) ||
                (d.referredBy?.toLowerCase().contains('meta') == true)) {
              return true;
            }
          }
        }
        return false;
      });

      if (alreadyInDb) {
        debugPrint('🛡️ Deduplication: Lead ${lead.id} (${lead.name} / ${lead.phone}) already exists in CRM database. Skipping duplicate creation.');
        if (lead.id.isNotEmpty) {
          ingestedIds.add(lead.id);
          await prefs.setStringList('ingested_meta_lead_ids', ingestedIds.toList());
        }
        return null;
      }
    }

    final descriptionBuffer = StringBuffer();
    if (lead.email != null && lead.email!.isNotEmpty) {
      descriptionBuffer.writeln('Email: ${lead.email}');
    }
    if (lead.rawFields.isNotEmpty) {
      lead.rawFields.forEach((k, v) {
        final keyLower = k.toLowerCase().trim();
        // Skip basic contact fields already captured in Deal fields
        if (keyLower != 'full name' &&
            keyLower != 'full_name' &&
            keyLower != 'phone number' &&
            keyLower != 'phone_number' &&
            keyLower != 'phone' &&
            keyLower != 'city' &&
            keyLower != 'service needed' &&
            keyLower != 'work_type') {
          descriptionBuffer.writeln('$k: $v');
        }
      });
    }
    if (lead.id.isNotEmpty) {
      descriptionBuffer.writeln('Meta Lead ID: ${lead.id}');
    }

    String leadSource = 'Meta Lead Ads (Facebook/Instagram)';
    if (lead.campaignName != null && lead.campaignName!.trim().isNotEmpty) {
      leadSource = 'Meta Ads: ${lead.campaignName!.trim()}';
    } else if (lead.formName != null && lead.formName!.trim().isNotEmpty) {
      leadSource = 'Meta Ads: ${lead.formName!.trim()}';
    }

    final newDeal = Deal(
      name: lead.name.isNotEmpty ? lead.name : 'Meta Ad Lead',
      stage: 'Created',
      pipeline: 'CRM',
      priority: 'High',
      contactInfo: lead.phone,
      company: lead.city ?? 'Facebook/Instagram',
      workType: lead.workType ?? 'Meta Lead Ad Inquiry',
      referredBy: leadSource,
      registerNo: lead.id.isNotEmpty ? lead.id : null,
      description: descriptionBuffer.toString().trim(),
      createdAt: lead.createdTime,
    );

    final dealId = await _dealService.createDeal(newDeal, sendNotification: true);

    if (lead.id.isNotEmpty) {
      ingestedIds.add(lead.id);
      await prefs.setStringList('ingested_meta_lead_ids', ingestedIds.toList());
    }

    // Trigger local desktop notification
    try {
      NotificationService().showLocalNotification(
        title: '🎯 New Meta Lead Received!',
        message: '${lead.name} (${lead.phone ?? "No phone"}) - ${lead.workType ?? "Meta Ads"}',
      );
    } catch (_) {}

    // Automatically send instant WhatsApp notification to Admin (only for recent leads or simulation)
    try {
      final isRecent = DateTime.now().difference(lead.createdTime).inHours.abs() < 4;
      final cfg = await MetaConfig.load();
      if (sendWhatsAppAlert && isRecent && cfg.notifyOnNewLead && cfg.notifyAdminPhone.isNotEmpty) {
        final alertMsg = StringBuffer();
        alertMsg.writeln('🎯 *New Meta Lead Alert!*');
        alertMsg.writeln('');
        alertMsg.writeln('👤 *Name:* ${lead.name}');
        alertMsg.writeln('📞 *Phone:* ${lead.phone ?? "N/A"}');
        if (lead.city != null && lead.city!.isNotEmpty) {
          alertMsg.writeln('📍 *Location:* ${lead.city}');
        }
        if (lead.workType != null && lead.workType!.isNotEmpty) {
          alertMsg.writeln('📋 *Requirement:* ${lead.workType}');
        }
        if (lead.campaignName != null && lead.campaignName!.isNotEmpty) {
          alertMsg.writeln('🏷️ *Campaign:* ${lead.campaignName}');
        }
        final istTime = lead.createdTime.isUtc
            ? lead.createdTime.add(const Duration(hours: 5, minutes: 30))
            : lead.createdTime;
        alertMsg.writeln('⏰ *Time (IST):* ${DateFormat('dd-MMM-yyyy hh:mm a').format(istTime)}');
        alertMsg.writeln('');
        alertMsg.writeln('👉 *Cochin United Consultancy CRM*');

        final senderId = cfg.internalOpsWhatsAppPhoneId.isNotEmpty
            ? cfg.internalOpsWhatsAppPhoneId
            : cfg.whatsappPhoneNumberId;

        final phoneList = cfg.notifyAdminPhone
            .split(',')
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .toList();

        for (final targetPhone in phoneList) {
          try {
            await WhatsAppCloudService().sendMessage(
              toPhone: targetPhone,
              message: alertMsg.toString(),
              senderPhoneNumberId: senderId,
              config: cfg,
            );
          } catch (e) {
            debugPrint('Failed to send WhatsApp alert to $targetPhone: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('Error sending automated WhatsApp lead alert: $e');
    }

    return dealId;
  }

  /// Create a mock/test lead to verify CRM ingestion and WhatsApp workflow
  Future<dynamic> simulateTestLead({
    String name = 'Test Meta Lead (Rahul Menon)',
    String phone = '9876543210',
    String email = 'rahul.test@meta-leads.in',
    String city = 'Kochi, Kerala',
    String workType = 'Company Registration & GST Inquiry',
  }) async {
    final mockLead = MetaLead(
      id: 'test_meta_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      phone: phone,
      email: email,
      city: city,
      workType: workType,
      adName: 'CUC Business Advisory - Kerala 2026',
      campaignName: 'Kerala Startup & Corporate Advisory Campaign',
      formName: 'Quick Inquiry Instant Form',
      createdTime: DateTime.now(),
      rawFields: {
        'Full Name': name,
        'Phone Number': phone,
        'Email': email,
        'City': city,
        'Service Needed': workType,
        'Preferred Contact Time': 'Morning 10 AM - 1 PM',
      },
    );

    return await ingestLeadToCrm(mockLead, checkDuplicate: false);
  }

  /// Get list of all ingested Meta lead IDs
  Future<List<String>> getIngestedLeadIds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('ingested_meta_lead_ids') ?? [];
  }

  /// Sync a single lead by its leadgen_id (from incoming Webhook)
  Future<dynamic> syncSingleLeadById(String leadgenId) async {
    try {
      final cfg = await MetaConfig.load();
      final url = Uri.parse('https://graph.facebook.com/${cfg.graphApiVersion}/$leadgenId?access_token=${Uri.encodeComponent(cfg.accessToken)}');
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final lead = MetaLead.fromGraphApi(data);
        return await ingestLeadToCrm(lead);
      }
    } catch (e) {
      debugPrint('Error syncing single lead $leadgenId: $e');
    }
    return null;
  }
}

/// Result of a WhatsApp send operation
class WhatsAppSendResult {
  final bool success;
  final String? messageId;
  final String? error;
  final bool canFallbackToWaMe;

  WhatsAppSendResult({
    required this.success,
    this.messageId,
    this.error,
    this.canFallbackToWaMe = false,
  });
}

/// Service to interact with Meta WhatsApp Cloud API (Official WhatsApp Business Platform)
class WhatsAppCloudService {
  /// Clean and format a phone number (e.g. adds standard country code 91 if 10 digits)
  static String formatPhone(String rawPhone) {
    var digits = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('0091') && digits.length == 14) {
      digits = digits.substring(2);
    }
    if (digits.length == 11 && digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    if (digits.length == 10) {
      return '91$digits';
    }
    return digits;
  }

  /// Send a free-form text message via Meta WhatsApp Cloud API
  Future<WhatsAppSendResult> sendMessage({
    required String toPhone,
    required String message,
    String? senderPhoneNumberId,
    MetaConfig? config,
  }) async {
    final cfg = config ?? await MetaConfig.load();
    final cleanPhone = formatPhone(toPhone);

    if (cleanPhone.isEmpty) {
      return WhatsAppSendResult(
        success: false,
        error: 'Recipient phone number is invalid or empty.',
        canFallbackToWaMe: false,
      );
    }

    final activePhoneId = (senderPhoneNumberId != null && senderPhoneNumberId.trim().isNotEmpty)
        ? senderPhoneNumberId.trim()
        : cfg.whatsappPhoneNumberId;

    if (activePhoneId.isEmpty || cfg.accessToken.isEmpty) {
      return WhatsAppSendResult(
        success: false,
        error: 'WhatsApp Cloud API Phone Number ID or Access Token is not configured.',
        canFallbackToWaMe: true,
      );
    }

    final url = Uri.parse(
      'https://graph.facebook.com/${cfg.graphApiVersion}/$activePhoneId/messages',
    );

    final payload = {
      'messaging_product': 'whatsapp',
      'recipient_type': 'individual',
      'to': cleanPhone,
      'type': 'text',
      'text': {
        'preview_url': false,
        'body': message,
      },
    };

    try {
      final res = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer ${cfg.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );

      if (res.statusCode == 200 || res.statusCode == 201) {
        final data = jsonDecode(res.body);
        final msgId = (data['messages'] is List && (data['messages'] as List).isNotEmpty)
            ? data['messages'][0]['id']?.toString()
            : null;
        return WhatsAppSendResult(success: true, messageId: msgId);
      } else {
        final err = jsonDecode(res.body);
        final errMsg = err['error']?['message']?.toString() ?? res.body;

        // Auto-recovery 1: Stored access token expired or invalid (HTTP 401)
        if ((res.statusCode == 401 ||
                errMsg.contains('Authentication Error') ||
                errMsg.contains('Session has expired') ||
                errMsg.contains('Error validating access token')) &&
            cfg.accessToken != MetaConfig.defaultAccessToken) {
          debugPrint('🔄 Stored access token invalid ($errMsg). Retrying with active token...');
          cfg.accessToken = MetaConfig.defaultAccessToken;
          await cfg.save();
          return await sendMessage(
            toPhone: toPhone,
            message: message,
            senderPhoneNumberId: senderPhoneNumberId,
            config: cfg,
          );
        }

        // Auto-recovery 2: Selected sender ID is not registered on Cloud API (e.g. SMB number)
        if (errMsg.contains('Account not registered') && activePhoneId != MetaConfig.defaultWhatsAppPhoneId) {
          debugPrint('🔄 Phone ID $activePhoneId not registered. Auto-falling back to verified sender ${MetaConfig.defaultWhatsAppPhoneId}...');
          return await sendMessage(
            toPhone: toPhone,
            message: message,
            senderPhoneNumberId: MetaConfig.defaultWhatsAppPhoneId,
            config: cfg,
          );
        }

        return WhatsAppSendResult(
          success: false,
          error: 'Meta WhatsApp API Error (${res.statusCode}): $errMsg',
          canFallbackToWaMe: true,
        );
      }
    } catch (e) {
      return WhatsAppSendResult(
        success: false,
        error: 'Connection error: $e',
        canFallbackToWaMe: true,
      );
    }
  }

  /// Send an official Meta WhatsApp template message (e.g. 'hello_world' or custom approved template)
  Future<WhatsAppSendResult> sendTemplateMessage({
    required String toPhone,
    required String templateName,
    String languageCode = 'en_US',
    List<Map<String, dynamic>>? components,
    MetaConfig? config,
  }) async {
    final cfg = config ?? await MetaConfig.load();
    final cleanPhone = formatPhone(toPhone);

    if (cleanPhone.isEmpty) {
      return WhatsAppSendResult(success: false, error: 'Recipient phone number is empty.');
    }

    if (cfg.whatsappPhoneNumberId.isEmpty || cfg.accessToken.isEmpty) {
      return WhatsAppSendResult(
        success: false,
        error: 'WhatsApp Cloud API Phone Number ID or Access Token is not configured.',
        canFallbackToWaMe: true,
      );
    }

    final url = Uri.parse(
      'https://graph.facebook.com/${cfg.graphApiVersion}/${cfg.whatsappPhoneNumberId}/messages',
    );

    final Map<String, dynamic> templatePayload = {
      'name': templateName,
      'language': {'code': languageCode},
    };
    if (components != null) {
      templatePayload['components'] = components;
    }

    final payload = {
      'messaging_product': 'whatsapp',
      'to': cleanPhone,
      'type': 'template',
      'template': templatePayload,
    };

    try {
      final res = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer ${cfg.accessToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );

      if (res.statusCode == 200 || res.statusCode == 201) {
        final data = jsonDecode(res.body);
        final msgId = (data['messages'] is List && (data['messages'] as List).isNotEmpty)
            ? data['messages'][0]['id']?.toString()
            : null;
        return WhatsAppSendResult(success: true, messageId: msgId);
      } else {
        final err = jsonDecode(res.body);
        final errMsg = err['error']?['message'] ?? res.body;
        return WhatsAppSendResult(
          success: false,
          error: 'Template API Error (${res.statusCode}): $errMsg',
          canFallbackToWaMe: true,
        );
      }
    } catch (e) {
      return WhatsAppSendResult(
        success: false,
        error: 'Connection error: $e',
        canFallbackToWaMe: true,
      );
    }
  }

  /// Send formatted automated WhatsApp notification to a staff member
  Future<WhatsAppSendResult> sendStaffAssignmentAlert({
    required String staffPhone,
    required String staffName,
    required String title,
    required String details,
    String? workOrTaskType,
    String? clientName,
    String? dueDate,
    String? priority,
    String? assignedByName,
    MetaConfig? config,
  }) async {
    final cleanPhone = formatPhone(staffPhone);
    if (cleanPhone.isEmpty) {
      return WhatsAppSendResult(
        success: false,
        error: 'Staff phone number is empty or invalid.',
      );
    }

    final typeLabel = workOrTaskType ?? 'Work / Task';
    final timeStr = DateFormat('dd-MMM-yyyy hh:mm a').format(DateTime.now());

    final msg = StringBuffer();
    msg.writeln('🔔 *CUC Assignment Alert*');
    msg.writeln('');
    msg.writeln('Hello *$staffName*,');
    msg.writeln('A new *$typeLabel* has been assigned to you in CUC System.');
    msg.writeln('');
    msg.writeln('📌 *Title:* $title');
    if (clientName != null && clientName.trim().isNotEmpty) {
      msg.writeln('👤 *Client:* $clientName');
    }
    if (dueDate != null && dueDate.trim().isNotEmpty) {
      msg.writeln('📅 *Deadline:* $dueDate');
    }
    if (priority != null && priority.trim().isNotEmpty) {
      msg.writeln('⚡ *Priority:* $priority');
    }
    if (assignedByName != null && assignedByName.trim().isNotEmpty) {
      msg.writeln('👤 *Assigned By:* $assignedByName');
    }
    if (details.trim().isNotEmpty) {
      msg.writeln('📝 *Details:* $details');
    }
    msg.writeln('⏰ *Assigned at:* $timeStr');
    msg.writeln('');
    msg.writeln('👉 *Please open Cochin United Consultancy App to view & take action.*');

    return await sendMessage(
      toPhone: cleanPhone,
      message: msg.toString(),
      config: config,
    );
  }

  /// Automatically look up a staff member and send a real-time WhatsApp alert to their company phone
  Future<WhatsAppSendResult?> notifyStaffOfAssignment({
    required dynamic staffUserId,
    required String assignmentTitle,
    String? workOrTaskType,
    String? clientName,
    String? dueDate,
    String? priority,
    String? details,
    String? assignedByName,
    MetaConfig? config,
  }) async {
    if (staffUserId == null) return null;
    final cfg = config ?? await MetaConfig.load();
    if (!cfg.notifyStaffOnAssignment) {
      debugPrint('Staff assignment WhatsApp alert disabled in settings.');
      return null;
    }

    try {
      final uId = staffUserId.toString().trim();
      if (uId.isEmpty) return null;

      String? staffName;
      String? staffPhone;

      final staffDirectory = await getStaffDirectoryWithPhones();
      final uIdLower = uId.toLowerCase();

      final staff = staffDirectory.firstWhere(
        (s) {
          final idMatch = s['id']?.toString() == uId;
          final sbIdMatch = s['supabase_id']?.toString() == uId;
          final idsMatch = (s['ids'] is Iterable) && (s['ids'] as Iterable).map((e) => e.toString()).contains(uId);
          final userMatch = s['username']?.toString().toLowerCase() == uIdLower;
          final emailMatch = s['email']?.toString().toLowerCase() == uIdLower;
          final nameMatch = s['name']?.toString().toLowerCase() == uIdLower;
          final nameContains = uId.length >= 3 && (
            (s['name']?.toString().toLowerCase() ?? '').contains(uIdLower) ||
            uIdLower.contains(s['name']?.toString().toLowerCase() ?? '')
          );
          return idMatch || sbIdMatch || idsMatch || userMatch || emailMatch || nameMatch || nameContains;
        },
        orElse: () => <String, dynamic>{},
      );

      if (staff.isNotEmpty) {
        staffName = staff['name'] as String?;
        staffPhone = staff['phone'] as String?;
      }

      // Fallback to Supabase direct query if phone not found in directory
      if (staffPhone == null || staffPhone.isEmpty) {
        try {
          final suRes = await http.get(
            Uri.parse('https://bzxtgiqjgfojblezdubd.supabase.co/rest/v1/users?id=eq.$uId&select=*'),
            headers: {
              'apikey': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ6eHRnaXFqZ2ZvamJsZXpkdWJkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU3OTMxMzIsImV4cCI6MjA4MTM2OTEzMn0.E8IKI5PvnW9WoEX4EcXvcSVk0b74LGrrQhNhFX99Dxo',
              'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ6eHRnaXFqZ2ZvamJsZXpkdWJkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU3OTMxMzIsImV4cCI6MjA4MTM2OTEzMn0.E8IKI5PvnW9WoEX4EcXvcSVk0b74LGrrQhNhFX99Dxo',
            },
          );
          if (suRes.statusCode == 200) {
            final List data = jsonDecode(suRes.body);
            if (data.isNotEmpty) {
              final row = data.first;
              staffName ??= row['name']?.toString();

              // Match against staff directory using username or name from Supabase row
              final sbUser = (row['username']?.toString() ?? '').toLowerCase().trim();
              final sbEmail = (row['email']?.toString() ?? '').toLowerCase().trim();
              final sbName = (row['name']?.toString() ?? '').toLowerCase().trim();
              final dirMatch = staffDirectory.firstWhere(
                (s) => (sbUser.isNotEmpty && s['username']?.toString().toLowerCase() == sbUser) ||
                       (sbEmail.isNotEmpty && s['email']?.toString().toLowerCase() == sbEmail) ||
                       (sbName.isNotEmpty && (s['name']?.toString().toLowerCase() == sbName ||
                                              (s['name']?.toString().toLowerCase() ?? '').contains(sbName) ||
                                              sbName.contains(s['name']?.toString().toLowerCase() ?? ''))),
                orElse: () => <String, dynamic>{},
              );
              if (dirMatch.isNotEmpty && dirMatch['phone'] != null) {
                staffPhone = dirMatch['phone'] as String?;
                staffName ??= dirMatch['name'] as String?;
              }

              if (staffPhone == null || staffPhone.isEmpty) {
                final cp = (row['company_phone']?.toString() ?? row['phone']?.toString() ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                final pp = (row['personal_phone']?.toString() ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                if (cp.length >= 10) {
                  staffPhone = formatPhone(row['company_phone']?.toString() ?? row['phone']?.toString() ?? '');
                } else if (pp.length >= 10) {
                  staffPhone = formatPhone(row['personal_phone']?.toString() ?? '');
                }
              }
            }
          }
        } catch (_) {}
      }

      if (staffPhone == null || staffPhone.isEmpty) {
        debugPrint('ℹ️ Staff user $uId ($staffName) does not have a 10-digit WhatsApp phone configured in Staff Management.');
        return null;
      }

      debugPrint('📲 Dispatching live WhatsApp alert to staff: $staffName ($staffPhone) for: $assignmentTitle');
      final res = await sendStaffAssignmentAlert(
        staffPhone: staffPhone,
        staffName: staffName ?? 'Team Member',
        title: assignmentTitle,
        details: details ?? '',
        workOrTaskType: workOrTaskType ?? 'Work / Task',
        clientName: clientName,
        dueDate: dueDate,
        priority: priority,
        assignedByName: assignedByName,
        config: cfg,
      );

      if (res.success) {
        debugPrint('✅ Staff assignment alert successfully delivered to $staffPhone (ID: ${res.messageId})');
      } else {
        debugPrint('❌ Staff assignment alert failed for $staffPhone: ${res.error}');
      }
      return res;
    } catch (e) {
      debugPrint('Error notifyStaffOfAssignment: $e');
      return null;
    }
  }

  /// Fetches all active staff members with their resolved WhatsApp contact numbers,
  /// prioritizing company_phone as configured in Staff Management / Directory.
  Future<List<Map<String, dynamic>>> getStaffDirectoryWithPhones() async {
    final Map<String, Map<String, dynamic>> staffMap = {};

    void registerOrMerge({
      required String id,
      required String? name,
      required String? username,
      required String? email,
      required String? role,
      required String? designation,
      required String? companyPhone,
      required String? personalPhone,
      required String? emergencyContact,
      required String? companyEmail,
    }) {
      final normName = (name ?? '').trim();
      final normUser = (username ?? '').trim().toLowerCase();
      final normEmail = (email ?? '').trim().toLowerCase();

      if (normName.isEmpty && normUser.isEmpty && normEmail.isEmpty) return;

      var key = normUser.isNotEmpty ? normUser : (normEmail.isNotEmpty ? normEmail : normName.toLowerCase());
      if (key.contains('jithasree')) key = 'jitha';

      // Pick best valid phone (company_phone > personal_phone > emergency_contact)
      String? cleanPhone;
      for (final p in [companyPhone, personalPhone, emergencyContact]) {
        if (p != null) {
          final digits = p.replaceAll(RegExp(r'[^0-9]'), '');
          if (digits.length >= 10) {
            cleanPhone = formatPhone(p);
            break;
          }
        }
      }

      final isUuid = id.contains('-');
      final isNumeric = int.tryParse(id) != null;

      if (!staffMap.containsKey(key)) {
        staffMap[key] = {
          'id': id,
          'supabase_id': isNumeric ? id : null,
          'ids': <String>{if (id.isNotEmpty) id},
          'name': normName.isNotEmpty ? normName : (username ?? 'Team Member'),
          'username': normUser,
          'email': normEmail,
          'role': role ?? 'staff',
          'designation': designation ?? '',
          'company_phone': companyPhone,
          'personal_phone': personalPhone,
          'emergency_contact': emergencyContact,
          'phone': cleanPhone,
        };
      } else {
        final existing = staffMap[key]!;
        final idsSet = (existing['ids'] as Set<String>?) ?? <String>{};
        if (id.isNotEmpty) idsSet.add(id);
        existing['ids'] = idsSet;

        if (isNumeric) {
          existing['supabase_id'] = id;
        }
        if (isUuid && !(existing['id'] as String).contains('-')) {
          existing['id'] = id;
        }

        if ((existing['phone'] == null || (existing['phone'] as String).isEmpty) && cleanPhone != null) {
          existing['phone'] = cleanPhone;
        }
        if ((existing['company_phone'] == null || (existing['company_phone'] as String).isEmpty) &&
            companyPhone != null &&
            companyPhone.trim().isNotEmpty) {
          existing['company_phone'] = companyPhone;
        }
        if ((existing['personal_phone'] == null || (existing['personal_phone'] as String).isEmpty) &&
            personalPhone != null &&
            personalPhone.trim().isNotEmpty) {
          existing['personal_phone'] = personalPhone;
        }
        if (normName.isNotEmpty && (existing['name'] == null || existing['name'] == 'Team Member')) {
          existing['name'] = normName;
        }
        if (role != null && (existing['role'] == null || existing['role'] == 'staff')) {
          existing['role'] = role;
        }
        if (designation != null && (existing['designation'] == null || (existing['designation'] as String).isEmpty)) {
          existing['designation'] = designation;
        }
      }
    }

    // 1. Fetch from Amplify DynamoDB with userPools authorization
    try {
      final uReq = ModelQueries.list(
        amplify_models.Users.classType,
        limit: 10000,
        authorizationMode: APIAuthorizationType.userPools,
      );
      final uRes = await Amplify.API.query(request: uReq).response;
      if (uRes.hasErrors) {
        debugPrint('GraphQL warnings on fetch users: ${uRes.errors.map((e) => e.message).join(", ")}');
      }
      final items = (uRes.data?.items ?? []).whereType<amplify_models.Users>().toList();
      for (final u in items) {
        registerOrMerge(
          id: u.id,
          name: u.name,
          username: u.username,
          email: u.email,
          role: u.role,
          designation: u.designation,
          companyPhone: u.company_phone,
          personalPhone: u.personal_phone,
          emergencyContact: u.emergency_contact,
          companyEmail: u.company_email,
        );
      }
    } catch (e) {
      debugPrint('Error fetching staff via userPools: $e. Retrying default auth...');
      try {
        final uReq = ModelQueries.list(amplify_models.Users.classType, limit: 10000);
        final uRes = await Amplify.API.query(request: uReq).response;
        final items = (uRes.data?.items ?? []).whereType<amplify_models.Users>().toList();
        for (final u in items) {
          registerOrMerge(
            id: u.id,
            name: u.name,
            username: u.username,
            email: u.email,
            role: u.role,
            designation: u.designation,
            companyPhone: u.company_phone,
            personalPhone: u.personal_phone,
            emergencyContact: u.emergency_contact,
            companyEmail: u.company_email,
          );
        }
      } catch (e2) {
        debugPrint('Error fetching staff via default auth: $e2');
      }
    }

    // 2. Fetch / merge from Supabase backup
    try {
      final sbUsers = await SupabaseBackupService().getAllUsersData();
      for (final row in sbUsers) {
        registerOrMerge(
          id: row['id']?.toString() ?? '',
          name: row['name']?.toString(),
          username: row['username']?.toString(),
          email: row['email']?.toString(),
          role: row['role']?.toString(),
          designation: row['designation']?.toString(),
          companyPhone: row['company_phone']?.toString() ?? row['phone']?.toString(),
          personalPhone: row['personal_phone']?.toString() ?? row['phone_number']?.toString(),
          emergencyContact: row['emergency_contact']?.toString(),
          companyEmail: row['company_email']?.toString(),
        );
      }
    } catch (e) {
      debugPrint('Supabase backup users lookup error: $e');
    }

    final list = staffMap.values.toList();
    list.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return list;
  }

  /// Send a test message or announcement to every staff member configured in the software
  Future<StaffBroadcastResult> sendTestMessageToAllStaff({
    String? customMessage,
    MetaConfig? config,
  }) async {
    final cfg = config ?? await MetaConfig.load();
    final List<Map<String, dynamic>> sentList = [];
    final List<Map<String, dynamic>> failedList = [];
    final Set<String> processedLast10 = {};

    final baseMsg = customMessage ??
        'This is a verification test message from *Cochin United Consultancy* Operations.\n\n'
        '📌 *Automated WhatsApp Integration is Active:*\n'
        '• When assigned a task or work, you will receive real-time alerts.\n'
        '• When complete, simply reply *"task completed"* to this chat.\n'
        '• The CUC software will automatically mark your task as Completed in real-time!\n\n'
        'Have a productive day! 🚀';

    final staffDirectory = await getStaffDirectoryWithPhones();
    final List<Map<String, String>> staffTargets = [];
    final List<String> missingPhoneStaff = [];

    for (final staff in staffDirectory) {
      final name = staff['name'] as String;
      final phone = staff['phone'] as String?;
      final compPhone = staff['company_phone'] as String?;
      final role = staff['role'] as String? ?? 'staff';

      debugPrint('👤 Staff Member: $name (@${staff['username']}) | Company Phone: $compPhone | Target WhatsApp: $phone');

      if (phone != null && phone.trim().isNotEmpty) {
        final last10 = phone.length >= 10 ? phone.substring(phone.length - 10) : phone;
        if (!processedLast10.contains(last10)) {
          processedLast10.add(last10);
          staffTargets.add({'name': name, 'phone': phone, 'role': role});
        }
      } else {
        missingPhoneStaff.add('$name (@${staff['username'] ?? 'no-user'})');
      }
    }

    // Always include admin/managing numbers if not already included
    final adminPhones = cfg.notifyAdminPhone.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty);
    for (final ap in adminPhones) {
      final clean = formatPhone(ap);
      final last10 = clean.length >= 10 ? clean.substring(clean.length - 10) : clean;
      if (!processedLast10.contains(last10)) {
        processedLast10.add(last10);
        staffTargets.add({'name': 'Management ($ap)', 'phone': clean, 'role': 'admin'});
      }
    }

    debugPrint('📢 Broadcasting test message to ${staffTargets.length} staff members (Missing phones: ${missingPhoneStaff.length})...');

    for (final target in staffTargets) {
      final name = target['name']!;
      final phone = target['phone']!;
      final personalized = '👋 *Hi $name,*\n\n$baseMsg';

      debugPrint('📲 Dispatching WhatsApp to $name ($phone)...');
      final res = await sendMessage(
        toPhone: phone,
        message: personalized,
        config: cfg,
      );

      if (res.success) {
        debugPrint('✅ WhatsApp Delivered to $name ($phone) | ID: ${res.messageId}');
        sentList.add({
          'name': name,
          'phone': phone,
          'messageId': res.messageId,
          'time': DateTime.now().toIso8601String(),
        });
      } else {
        debugPrint('❌ WhatsApp FAILED for $name ($phone): ${res.error}');
        failedList.add({
          'name': name,
          'phone': phone,
          'error': res.error,
        });
      }
    }

    return StaffBroadcastResult(
      totalAttempted: staffTargets.length,
      totalSuccess: sentList.length,
      totalFailed: failedList.length,
      sentDetails: sentList,
      failedDetails: failedList,
      missingPhoneStaff: missingPhoneStaff,
    );
  }

  /// Launch external WhatsApp application / web interface (wa.me)
  static Future<bool> launchWhatsAppApp({required String phone, required String message}) async {
    final cleanPhone = formatPhone(phone);
    if (cleanPhone.isEmpty) return false;
    final encodedMsg = Uri.encodeComponent(message);
    final url = Uri.parse('https://wa.me/$cleanPhone?text=$encodedMsg');
    if (await canLaunchUrl(url)) {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    return false;
  }
}

/// Result report of broadcasting WhatsApp messages to all staff
class StaffBroadcastResult {
  final int totalAttempted;
  final int totalSuccess;
  final int totalFailed;
  final List<Map<String, dynamic>> sentDetails;
  final List<Map<String, dynamic>> failedDetails;
  final List<String> missingPhoneStaff;

  StaffBroadcastResult({
    required this.totalAttempted,
    required this.totalSuccess,
    required this.totalFailed,
    required this.sentDetails,
    required this.failedDetails,
    this.missingPhoneStaff = const [],
  });
}

/// Result returned when processing an inbound WhatsApp reply from a staff member
class InboundProcessResult {
  final bool success;
  final String message;
  final String? matchedType; // 'task' or 'work'
  final String? matchedId;
  final String? matchedTitle;
  final String? staffName;
  final String? staffPhone;

  InboundProcessResult({
    required this.success,
    required this.message,
    this.matchedType,
    this.matchedId,
    this.matchedTitle,
    this.staffName,
    this.staffPhone,
  });
}

/// Inbound WhatsApp message processor that handles replies like "task completed"
class WhatsAppInboundProcessor {
  static final WhatsAppInboundProcessor _instance = WhatsAppInboundProcessor._internal();
  factory WhatsAppInboundProcessor() => _instance;
  WhatsAppInboundProcessor._internal();

  /// Check if the incoming message text expresses completion intent
  static bool isCompletionIntent(String text) {
    final clean = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').trim();
    if (clean.isEmpty) return false;

    final keywords = [
      'task completed',
      'task complete',
      'work completed',
      'work complete',
      'completed task',
      'completed work',
      'task done',
      'work done',
      'done',
      'completed',
      'finish',
      'finished',
      'task finished',
      'work finished',
      'complete',
      'all done',
      'job done',
      'job completed',
    ];

    for (final kw in keywords) {
      if (clean == kw || clean.startsWith('$kw ') || clean.endsWith(' $kw') || clean.contains(' $kw ')) {
        return true;
      }
    }

    return clean.contains('completed') || (clean.contains('task') && clean.contains('done'));
  }

  /// Process an inbound message from a sender phone (e.g. from WhatsApp Cloud Webhook or Simulator)
  Future<InboundProcessResult> processInboundMessage({
    required String fromPhone,
    required String messageBody,
    String? senderName,
    MetaConfig? config,
  }) async {
    final cleanDigits = fromPhone.replaceAll(RegExp(r'[^0-9]'), '');
    final last10 = cleanDigits.length >= 10 ? cleanDigits.substring(cleanDigits.length - 10) : cleanDigits;

    debugPrint('📥 Processing inbound WhatsApp message from $fromPhone ($last10): "$messageBody"');

    // Check completion intent
    if (!isCompletionIntent(messageBody)) {
      debugPrint('ℹ️ Message does not express completion intent: "$messageBody"');
      return InboundProcessResult(
        success: false,
        message: 'Message did not express completion intent ("$messageBody").',
      );
    }

    // 1. Identify staff member by matching last 10 digits against all staff company phones
    Map<String, dynamic>? staffUser;
    int? staffId;
    String? matchedStaffName;
    String? matchedStaffPhone;

    try {
      final staffDirectory = await WhatsAppCloudService().getStaffDirectoryWithPhones();
      for (final s in staffDirectory) {
        final p = (s['phone'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
        final cp = (s['company_phone'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
        final pp = (s['personal_phone'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
        if ((p.length >= 10 && p.endsWith(last10)) ||
            (cp.length >= 10 && cp.endsWith(last10)) ||
            (pp.length >= 10 && pp.endsWith(last10))) {
          staffUser = s;
          staffId = int.tryParse(s['supabase_id']?.toString() ?? s['id']?.toString() ?? '');
          matchedStaffName = s['name'] as String?;
          matchedStaffPhone = s['phone'] as String?;
          debugPrint('🎯 Inbound WhatsApp from $fromPhone matched to staff: $matchedStaffName (${s['company_phone']})');
          break;
        }
      }
    } catch (e) {
      debugPrint('Staff directory search error in inbound processor: $e');
    }

    matchedStaffName ??= senderName ?? 'Staff Member';

    // 2. Search for pending Tasks assigned to this staff member
    try {
      final tReq = ModelQueries.list(
        amplify_models.Tasks.classType,
        limit: 10000,
        authorizationMode: APIAuthorizationType.userPools,
      );
      final tRes = await Amplify.API.query(request: tReq).response;
      final allTasks = (tRes.data?.items ?? []).whereType<amplify_models.Tasks>().toList();

      // Filter tasks assigned to this staff member that are not already Completed
      final pendingTasks = allTasks.where((t) {
        if (t.status == 'Completed') return false;
        if (staffId != null && t.assigned_to == staffId) return true;
        if (staffUser != null) {
          final sId = staffUser['id']?.toString().toLowerCase();
          final sUser = staffUser['username']?.toString().toLowerCase();
          final sEmail = staffUser['email']?.toString().toLowerCase();
          final tAssigned = t.assigned_to?.toString().toLowerCase();
          if (tAssigned != null && (tAssigned == sId || tAssigned == sUser || tAssigned == sEmail)) {
            return true;
          }
        }
        return false;
      }).toList();

      if (pendingTasks.isNotEmpty) {
        // Sort newest first
        pendingTasks.sort((a, b) {
          final dA = a.createdAt?.getDateTimeInUtc() ?? DateTime(2000);
          final dB = b.createdAt?.getDateTimeInUtc() ?? DateTime(2000);
          return dB.compareTo(dA);
        });

        // Check if message specifically references a particular task title
        amplify_models.Tasks targetTask = pendingTasks.first;
        final cleanMsg = messageBody.toLowerCase();
        for (final t in pendingTasks) {
          final tTitle = (t.title ?? '').toLowerCase();
          if (tTitle.isNotEmpty && cleanMsg.contains(tTitle)) {
            targetTask = t;
            break;
          }
        }

        // Mark as Completed!
        final updatedTask = targetTask.copyWith(
          status: 'Completed',
          updated_at: DateTime.now().toIso8601String(),
        );
        await BackupAwareApi().update(updatedTask);
        debugPrint('🎉 Task "${targetTask.title}" (ID: ${targetTask.id}) marked as COMPLETED via WhatsApp reply from $matchedStaffName');

        // Log Action
        try {
          await LoggingService().logAction(
            action: 'TASK_COMPLETED_VIA_WHATSAPP',
            targetType: 'task',
            targetId: targetTask.id,
            details: 'Task "${targetTask.title}" marked as Completed via WhatsApp reply from $matchedStaffName ($fromPhone)',
          );
        } catch (_) {}

        // Notify stakeholders
        try {
          await NotificationService().notifyStakeholders(
            title: 'Task Completed (WhatsApp)',
            message: '$matchedStaffName marked task "${targetTask.title}" as Completed via WhatsApp.',
            dealId: null,
          );
        } catch (_) {}

        // Send confirmation WhatsApp message back to staff
        try {
          final confirmMsg = '✅ *Task Marked as Completed!*\n\n'
              'Hi $matchedStaffName, your task:\n'
              '📌 *${targetTask.title}*\n'
              'has been automatically marked as *Completed* in the Cochin United Consultancy software.\n\n'
              'Great job and thank you! 👍';
          await WhatsAppCloudService().sendMessage(
            toPhone: fromPhone,
            message: confirmMsg,
            config: config,
          );
        } catch (e) {
          debugPrint('Error sending confirmation WhatsApp: $e');
        }

        return InboundProcessResult(
          success: true,
          message: 'Task "${targetTask.title}" marked as Completed successfully.',
          matchedType: 'task',
          matchedId: targetTask.id,
          matchedTitle: targetTask.title,
          staffName: matchedStaffName,
          staffPhone: matchedStaffPhone ?? fromPhone,
        );
      }
    } catch (e) {
      debugPrint('Error processing task completion: $e');
    }

    // 2b. Search for pending Checklists (Manager Master) assigned to this staff member
    try {
      final cReq = ModelQueries.list(
        amplify_models.Checklists.classType,
        limit: 10000,
        authorizationMode: APIAuthorizationType.userPools,
      );
      final cRes = await Amplify.API.query(request: cReq).response;
      final allChecklists = (cRes.data?.items ?? []).whereType<amplify_models.Checklists>().toList();

      final pendingChecklists = allChecklists.where((c) {
        if (c.status == 'Completed') return false;
        if (staffId != null && c.responsible_id == staffId) return true;
        if (staffUser != null) {
          final sId = staffUser['supabase_id']?.toString() ?? staffUser['id']?.toString();
          if (sId != null && c.responsible_id?.toString() == sId) return true;
        }
        return false;
      }).toList();

      if (pendingChecklists.isNotEmpty) {
        pendingChecklists.sort((a, b) {
          final dA = a.createdAt?.getDateTimeInUtc() ?? DateTime(2000);
          final dB = b.createdAt?.getDateTimeInUtc() ?? DateTime(2000);
          return dB.compareTo(dA);
        });

        amplify_models.Checklists targetChecklist = pendingChecklists.first;
        final cleanMsg = messageBody.toLowerCase();
        for (final c in pendingChecklists) {
          final tTitle = (c.title ?? '').toLowerCase();
          if (tTitle.isNotEmpty && cleanMsg.contains(tTitle)) {
            targetChecklist = c;
            break;
          }
        }

        final nowIso = DateTime.now().toIso8601String();
        String currentDesc = targetChecklist.description ?? '';
        if (!currentDesc.contains('[END_TIME]')) {
          currentDesc = '$currentDesc\n[END_TIME] $nowIso'.trim();
        }
        final updatedChecklist = targetChecklist.copyWith(
          status: 'Completed',
          description: currentDesc,
        );
        await BackupAwareApi().update(updatedChecklist);
        debugPrint('🎉 Checklist "${targetChecklist.title}" marked as COMPLETED via WhatsApp reply from $matchedStaffName');

        try {
          await LoggingService().logAction(
            action: 'CHECKLIST_COMPLETED_VIA_WHATSAPP',
            targetType: 'Checklist Task',
            targetId: targetChecklist.id,
            details: 'Checklist "${targetChecklist.title}" marked as Completed via WhatsApp reply from $matchedStaffName ($fromPhone)',
          );
        } catch (_) {}

        if (targetChecklist.manager_id != null) {
          try {
            await NotificationService().sendNotification(
              userId: targetChecklist.manager_id!,
              title: "Task Completed",
              message: "$matchedStaffName marked \"${targetChecklist.title}\" as Completed via WhatsApp.",
              type: 'checklist_update',
            );
          } catch (_) {}
        }

        try {
          final confirmMsg = '✅ *Task Marked as Completed!*\n\n'
              'Hi $matchedStaffName, your daily task:\n'
              '📌 *${targetChecklist.title}*\n'
              'has been automatically marked as *Completed* in Cochin United Consultancy software.\n\n'
              'Great job and thank you! 👍';
          await WhatsAppCloudService().sendMessage(
            toPhone: fromPhone,
            message: confirmMsg,
            config: config,
          );
        } catch (e) {
          debugPrint('Error sending confirmation WhatsApp: $e');
        }

        return InboundProcessResult(
          success: true,
          message: 'Checklist Task "${targetChecklist.title}" marked as Completed successfully.',
          matchedType: 'checklist',
          matchedId: targetChecklist.id,
          matchedTitle: targetChecklist.title,
          staffName: matchedStaffName,
          staffPhone: matchedStaffPhone ?? fromPhone,
        );
      }
    } catch (e) {
      debugPrint('Error processing checklist completion: $e');
    }

    // 3. Fallback: Search for pending Work / Deal assigned to this staff member
    try {
      final allDeals = await DealService().getAllDeals();
      final pendingDeals = allDeals.where((d) {
        if (d.stage == 'Completed' || d.stage == 'Closed Lost') return false;
        if (staffId != null && d.responsibleId == staffId) return true;
        return false;
      }).toList();

      if (pendingDeals.isNotEmpty) {
        final targetDeal = pendingDeals.first;
        await DealService().moveDealToStage(
          targetDeal.id,
          targetDeal.stage,
          'Completed',
        );

        debugPrint('🎉 Work "${targetDeal.name}" (ID: ${targetDeal.id}) marked as COMPLETED via WhatsApp reply from $matchedStaffName');

        // Log Action
        try {
          await LoggingService().logAction(
            action: 'WORK_COMPLETED_VIA_WHATSAPP',
            targetType: 'deal',
            targetId: targetDeal.id.toString(),
            details: 'Work "${targetDeal.name}" marked as Completed via WhatsApp reply from $matchedStaffName ($fromPhone)',
          );
        } catch (_) {}

        // Send confirmation WhatsApp message back to staff
        try {
          final confirmMsg = '✅ *Work Marked as Completed!*\n\n'
              'Hi $matchedStaffName, your work assignment:\n'
              '📌 *${targetDeal.name}*\n'
              'has been automatically marked as *Completed* in Cochin United Consultancy software.\n\n'
              'Great job and thank you! 👍';
          await WhatsAppCloudService().sendMessage(
            toPhone: fromPhone,
            message: confirmMsg,
            config: config,
          );
        } catch (e) {
          debugPrint('Error sending confirmation WhatsApp: $e');
        }

        return InboundProcessResult(
          success: true,
          message: 'Work "${targetDeal.name}" marked as Completed successfully.',
          matchedType: 'work',
          matchedId: targetDeal.id.toString(),
          matchedTitle: targetDeal.name,
          staffName: matchedStaffName,
          staffPhone: matchedStaffPhone ?? fromPhone,
        );
      }
    } catch (e) {
      debugPrint('Error processing work completion: $e');
    }

    // 4. No pending task or work found for this staff member
    final notFoundMsg = 'ℹ️ Hi $matchedStaffName, we received your message ("$messageBody"), but no pending tasks or works were found assigned to your account in Cochin United Consultancy. Please open the app to verify.';
    try {
      await WhatsAppCloudService().sendMessage(
        toPhone: fromPhone,
        message: notFoundMsg,
        config: config,
      );
    } catch (_) {}

    return InboundProcessResult(
      success: false,
      message: 'No pending tasks or works found for staff $matchedStaffName ($fromPhone). Sent informational WhatsApp.',
      staffName: matchedStaffName,
      staffPhone: matchedStaffPhone ?? fromPhone,
    );
  }

  /// Process raw Webhook JSON payload received from Meta
  Future<void> processWebhookPayload(Map<String, dynamic> payload) async {
    final entries = payload['entry'] as List?;
    if (entries == null) return;

    for (final entry in entries) {
      final changes = entry['changes'] as List?;
      if (changes == null) continue;

      for (final change in changes) {
        final field = change['field']?.toString();
        final value = change['value'] as Map<String, dynamic>?;
        if (value == null) continue;

        // 1. Meta Lead Ads Webhook
        if (field == 'leadgen') {
          final leadgenId = value['leadgen_id']?.toString();
          if (leadgenId != null && leadgenId.isNotEmpty) {
            debugPrint('🎯 Inbound Meta Leadgen Event detected! Lead ID: $leadgenId');
            MetaLeadService().syncSingleLeadById(leadgenId);
          }
        }

        // 2. WhatsApp Messages Webhook
        if (field == 'messages') {
          final messages = value['messages'] as List?;
          if (messages == null || messages.isEmpty) continue;

          String? contactName;
          final contacts = value['contacts'] as List?;
          if (contacts != null && contacts.isNotEmpty) {
            contactName = contacts[0]['profile']?['name']?.toString();
          }

          for (final msg in messages) {
            final from = msg['from']?.toString();
            final type = msg['type']?.toString();
            String? body;

            if (type == 'text') {
              body = msg['text']?['body']?.toString();
            } else if (type == 'button') {
              body = msg['button']?['text']?.toString();
            } else if (type == 'interactive') {
              body = msg['interactive']?['button_reply']?['title']?.toString() ??
                  msg['interactive']?['list_reply']?['title']?.toString();
            }

            if (from != null && body != null && body.trim().isNotEmpty) {
              await processInboundMessage(
                fromPhone: from,
                messageBody: body,
                senderName: contactName,
              );
            }
          }
        }
      }
    }
  }
}

/// Embedded HTTP Webhook Server for receiving real-time Meta WhatsApp & Leadgen events
class MetaWebhookServer {
  static final MetaWebhookServer _instance = MetaWebhookServer._internal();
  factory MetaWebhookServer() => _instance;
  MetaWebhookServer._internal();

  HttpServer? _server;
  bool get isRunning => _server != null;
  int get port => _server?.port ?? 8088;
  String? lastEventSummary;
  DateTime? lastEventTime;

  /// Start the embedded HTTP webhook server
  Future<bool> startServer({int port = 8088}) async {
    if (_server != null) return true;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      debugPrint('🚀 Meta Webhook Server listening on http://0.0.0.0:$port/webhook');
      _server!.listen(_handleRequest);
      return true;
    } catch (e) {
      debugPrint('⚠️ Meta Webhook Server could not bind on port $port: $e');
      return false;
    }
  }

  /// Stop the embedded HTTP webhook server
  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type, Authorization');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;
    if (path == '/api/staff_directory' || path == '/api/staff_directory/') {
      try {
        final directory = await WhatsAppCloudService().getStaffDirectoryWithPhones();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'success': true,
            'total': directory.length,
            'staff': directory,
          }));
        await request.response.close();
        return;
      } catch (e) {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'success': false, 'error': e.toString()}));
        await request.response.close();
        return;
      }
    }

    if (path == '/webhook' || path == '/webhook/' || path == '/') {
      if (request.method == 'GET') {
        final mode = request.uri.queryParameters['hub.mode'] ??
            request.uri.queryParameters['hub_mode'] ??
            request.uri.queryParameters['mode'];
        final token = request.uri.queryParameters['hub.verify_token'] ??
            request.uri.queryParameters['hub_verify_token'] ??
            request.uri.queryParameters['verify_token'] ??
            request.uri.queryParameters['token'];
        final challenge = request.uri.queryParameters['hub.challenge'] ??
            request.uri.queryParameters['hub_challenge'] ??
            request.uri.queryParameters['challenge'];

        // Handle browser or health-check probe
        if (mode == null && token == null && challenge == null) {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write(
              '<html><body style="font-family:sans-serif;background:#0f172a;color:#f8fafc;padding:30px;">'
              '<h2>✅ CUC Meta Webhook Server is Active</h2>'
              '<p>Listening on port 8088. Ready for Meta WhatsApp and Lead Ads events.</p>'
              '<p style="color:#94a3b8;font-size:13px;">Expected Verify Token: <code>cuc_meta_verify_token_2026</code></p>'
              '</body></html>',
            );
          await request.response.close();
          return;
        }

        final cfg = await MetaConfig.load();
        final expectedToken = cfg.webhookVerifyToken.isNotEmpty ? cfg.webhookVerifyToken : MetaConfig.defaultVerifyToken;

        if (token == expectedToken) {
          debugPrint('✅ Meta Webhook challenge verified successfully: $challenge');
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.text
            ..write(challenge ?? '');
          await request.response.close();
          return;
        } else {
          debugPrint('❌ Webhook token mismatch. Got: $token, expected: $expectedToken');
          request.response
            ..statusCode = HttpStatus.forbidden
            ..headers.contentType = ContentType.text
            ..write('Verification token mismatch');
          await request.response.close();
          return;
        }
      } else if (request.method == 'POST') {
        // Inbound Event from Meta
        try {
          final bodyStr = await utf8.decoder.bind(request).join();
          request.response
            ..statusCode = HttpStatus.ok
            ..write('EVENT_RECEIVED');
          await request.response.close();

          lastEventTime = DateTime.now();
          lastEventSummary = 'Received event (${bodyStr.length} bytes)';
          debugPrint('📩 Meta Webhook POST received: $bodyStr');

          final data = jsonDecode(bodyStr);
          if (data is Map<String, dynamic>) {
            await WhatsAppInboundProcessor().processWebhookPayload(data);
          }
        } catch (e) {
          debugPrint('Error handling webhook POST: $e');
        }
        return;
      }
    }

    request.response
      ..statusCode = HttpStatus.notFound
      ..write('Not Found');
    await request.response.close();
  }
}
