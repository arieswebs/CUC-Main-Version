import '../utils/safe_json_parse.dart';

class Deal {
  final dynamic id;
  final String name;
  final dynamic clientId;
  final String? clientName;
  final String? contactInfo;
  final String? company;
  final String? workType;
  final String stage;
  final dynamic responsibleId;
  final String? responsibleName;
  final double amount;
  final String currency;
  final String pipeline;
  final String priority;
  final String? description;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? closedAt;
  final bool isWon;

  // New stage-specific fields
  final String? regFeeRequired;
  final String? referredBy;
  final String? filesReceived;
  final String? contactStatus;
  final String? filesAsked;
  final double? estAmountWork;
  final String? createInvoiceShare;
  final double? expenseSpent;
  final List<dynamic>? expensesList;
  final String? uploadInvoicePath;
  final String? sendToCustomer;
  final String? registerNo;
  final double? invoiceAmount;
  final String? paymentType;
  final String? driveLink;
  final dynamic billingId;
  final dynamic quotationId;
  final double? paymentReceived;
  final bool isAdjourned;
  final String? adjournedReason;
  final DateTime? postponedDate;
  final double? partPaymentAmount;
  final bool nocObtained;

  Deal({
    this.id,
    required this.name,
    this.clientId,
    this.clientName,
    this.contactInfo,
    this.company,
    this.workType,
    required this.stage,
    this.responsibleId,
    this.responsibleName,
    this.amount = 0.0,
    this.currency = 'INR',
    this.pipeline = 'General',
    this.priority = 'Normal',
    this.description,
    this.createdAt,
    this.updatedAt,
    this.closedAt,
    this.isWon = false,
    this.regFeeRequired,
    this.referredBy,
    this.filesReceived,
    this.contactStatus,
    this.filesAsked,
    this.estAmountWork,
    this.createInvoiceShare,
    this.expenseSpent,
    this.expensesList,
    this.uploadInvoicePath,
    this.sendToCustomer,
    this.registerNo,
    this.invoiceAmount,
    this.paymentType,
    this.driveLink,
    this.billingId,
    this.quotationId,
    this.paymentReceived,
    this.isAdjourned = false,
    this.adjournedReason,
    this.postponedDate,
    this.partPaymentAmount,
    this.nocObtained = false,
  });

  Deal copyWith({
    dynamic id,
    String? name,
    dynamic clientId,
    String? clientName,
    String? contactInfo,
    String? company,
    String? workType,
    String? stage,
    dynamic responsibleId,
    String? responsibleName,
    double? amount,
    String? currency,
    String? pipeline,
    String? priority,
    String? description,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? closedAt,
    bool? isWon,
    String? regFeeRequired,
    String? referredBy,
    String? filesReceived,
    String? contactStatus,
    String? filesAsked,
    double? estAmountWork,
    String? createInvoiceShare,
    double? expenseSpent,
    List<dynamic>? expensesList,
    String? uploadInvoicePath,
    String? sendToCustomer,
    String? registerNo,
    double? invoiceAmount,
    String? paymentType,
    String? driveLink,
    dynamic billingId,
    dynamic quotationId,
    double? paymentReceived,
    bool? isAdjourned,
    String? adjournedReason,
    DateTime? postponedDate,
    double? partPaymentAmount,
    bool? nocObtained,
  }) {
    return Deal(
      id: id ?? this.id,
      name: name ?? this.name,
      clientId: clientId ?? this.clientId,
      clientName: clientName ?? this.clientName,
      contactInfo: contactInfo ?? this.contactInfo,
      company: company ?? this.company,
      workType: workType ?? this.workType,
      stage: stage ?? this.stage,
      responsibleId: responsibleId ?? this.responsibleId,
      responsibleName: responsibleName ?? this.responsibleName,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      pipeline: pipeline ?? this.pipeline,
      priority: priority ?? this.priority,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      closedAt: closedAt ?? this.closedAt,
      isWon: isWon ?? this.isWon,
      regFeeRequired: regFeeRequired ?? this.regFeeRequired,
      referredBy: referredBy ?? this.referredBy,
      filesReceived: filesReceived ?? this.filesReceived,
      contactStatus: contactStatus ?? this.contactStatus,
      filesAsked: filesAsked ?? this.filesAsked,
      estAmountWork: estAmountWork ?? this.estAmountWork,
      createInvoiceShare: createInvoiceShare ?? this.createInvoiceShare,
      expenseSpent: expenseSpent ?? this.expenseSpent,
      expensesList: expensesList ?? this.expensesList,
      uploadInvoicePath: uploadInvoicePath ?? this.uploadInvoicePath,
      sendToCustomer: sendToCustomer ?? this.sendToCustomer,
      registerNo: registerNo ?? this.registerNo,
      invoiceAmount: invoiceAmount ?? this.invoiceAmount,
      paymentType: paymentType ?? this.paymentType,
      driveLink: driveLink ?? this.driveLink,
      billingId: billingId ?? this.billingId,
      quotationId: quotationId ?? this.quotationId,
      paymentReceived: paymentReceived ?? this.paymentReceived,
      isAdjourned: isAdjourned ?? this.isAdjourned,
      adjournedReason: adjournedReason ?? this.adjournedReason,
      postponedDate: postponedDate ?? this.postponedDate,
      partPaymentAmount: partPaymentAmount ?? this.partPaymentAmount,
      nocObtained: nocObtained ?? this.nocObtained,
    );
  }

  static const List<String> stages = [
    'Registration',
    'Contact Customer',
    'Work Started',
    'In Progress',
    'Verification',
    'Invoice',
    'Billing Status',
    'Close Deal',
  ];

  static const List<String> priorities = ['Low', 'Normal', 'High', 'Urgent'];

  Map<String, dynamic> toMap() {
    final String adjBlock;
    if (isAdjourned || postponedDate != null) {
      final dateStr = postponedDate != null
          ? "\nPostponedDate: ${postponedDate!.toIso8601String()}"
          : "";
      adjBlock =
          "\n\n[ADJOURNED]\nIsAdjourned: ${isAdjourned ? 'true' : 'false'}\nReason: ${adjournedReason ?? ''}$dateStr";
    } else {
      adjBlock = "";
    }

    String finalDesc = description ?? '';
    final index = finalDesc.indexOf('[ADJOURNED]');
    if (index != -1) {
      finalDesc = finalDesc.substring(0, index).trim();
    }
    finalDesc = "$finalDesc$adjBlock";

    return {
      'id': id,
      'name': name,
      'client_id': clientId,
      'client_name': clientName,
      'contact_info': contactInfo,
      'company': company,
      'work_type': workType,
      'stage': stage,
      'responsible_id': responsibleId,
      'responsible_name': responsibleName,
      'amount': amount,
      'currency': currency,
      'pipeline': pipeline,
      'priority': priority,
      'description': finalDesc,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
      'closed_at': closedAt?.toIso8601String(),
      'is_won': isWon,
      'reg_fee_required': regFeeRequired,
      'referred_by': referredBy,
      'files_received': filesReceived,
      'contact_status': contactStatus,
      'files_asked': filesAsked,
      'est_amount_work': estAmountWork,
      'create_invoice_share': createInvoiceShare,
      'expense_spent': expenseSpent,
      'expenses_list': expensesList,
      'upload_invoice_path': uploadInvoicePath,
      'send_to_customer': sendToCustomer,
      'register_no': registerNo,
      'invoice_amount': invoiceAmount,
      'payment_type': paymentType,
      'drive_link': driveLink,
      'billing_id': billingId,
      'quotation_id': quotationId,
      'payment_received': paymentReceived,
      'part_payment_amount': partPaymentAmount,
      'noc_obtained': nocObtained,
    };
  }

  factory Deal.fromMap(Map<String, dynamic> map) {
    final rawDesc = map['description'] as String? ?? '';
    bool isAdj = false;
    String? adjReason;
    DateTime? postDate;
    String cleanDesc = rawDesc;

    final index = rawDesc.indexOf('[ADJOURNED]');
    if (index != -1) {
      cleanDesc = rawDesc.substring(0, index).trim();
      final adjPart = rawDesc.substring(index);

      final isAdjMatch = RegExp(r'IsAdjourned:[ \t]*(true|false)', caseSensitive: false).firstMatch(adjPart);
      if (isAdjMatch != null) {
        isAdj = isAdjMatch.group(1)?.toLowerCase() == 'true';
      }

      final reasonMatch = RegExp(r'Reason:[ \t]*([^\r\n]*)', caseSensitive: false).firstMatch(adjPart);
      if (reasonMatch != null) {
        final rStr = reasonMatch.group(1)?.trim();
        if (rStr != null && rStr.isNotEmpty) {
          adjReason = rStr;
        }
      }

      final postMatch = RegExp(r'PostponedDate:[ \t]*([^\r\n]+)', caseSensitive: false).firstMatch(adjPart);
      if (postMatch != null) {
        final dateStr = postMatch.group(1)?.trim();
        if (dateStr != null && dateStr.isNotEmpty) {
          postDate = DateTime.tryParse(dateStr);
        }
      }
    }

    return Deal(
      id: map['id'],
      name: map['name'] ?? '',
      clientId: safeParseInt(map['client_id']),
      clientName: map['client_name'],
      contactInfo: map['contact_info'],
      company: map['company'],
      workType: map['work_type'],
      stage: map['stage'] ?? 'Registration',
      responsibleId: safeParseInt(map['responsible_id']),
      responsibleName: map['responsible_name'],
      amount: double.tryParse(map['amount']?.toString() ?? '0') ?? 0.0,
      currency: map['currency'] ?? 'INR',
      pipeline: map['pipeline'] ?? 'General',
      priority: map['priority'] ?? 'Normal',
      description: cleanDesc,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString())
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'].toString())
          : null,
      closedAt: map['closed_at'] != null
          ? DateTime.tryParse(map['closed_at'].toString())
          : null,
      isWon: map['is_won'] == true || map['is_won'] == 'true',
      regFeeRequired: map['reg_fee_required'],
      referredBy: map['referred_by'],
      filesReceived: map['files_received'],
      contactStatus: map['contact_status'],
      filesAsked: map['files_asked'],
      estAmountWork: double.tryParse(map['est_amount_work']?.toString() ?? ''),
      createInvoiceShare: map['create_invoice_share'],
      expenseSpent: double.tryParse(map['expense_spent']?.toString() ?? ''),
      expensesList: map['expenses_list'] is List
          ? map['expenses_list'] as List<dynamic>
          : null,
      uploadInvoicePath: map['upload_invoice_path'],
      sendToCustomer: map['send_to_customer'],
      registerNo: map['register_no'],
      invoiceAmount: double.tryParse(map['invoice_amount']?.toString() ?? ''),
      paymentType: map['payment_type'],
      driveLink: map['drive_link'],
      billingId: safeParseInt(map['billing_id']),
      quotationId: safeParseInt(map['quotation_id']),
      paymentReceived: double.tryParse(
        map['payment_received']?.toString() ?? '',
      ),
      isAdjourned: isAdj,
      adjournedReason: adjReason,
      postponedDate: postDate,
      partPaymentAmount: double.tryParse(
        map['part_payment_amount']?.toString() ?? '',
      ),
      nocObtained: map['noc_obtained'] == true || map['noc_obtained'] == 'true',
    );
  }
}

class DealAssignee {
  final dynamic id;
  final dynamic dealId;
  final dynamic userId;
  final String? userName;
  final String role; // 'Lead', 'Collaborator'

  DealAssignee({
    this.id,
    required this.dealId,
    required this.userId,
    this.userName,
    required this.role,
  });

  Map<String, dynamic> toMap() => {
    'deal_id': dealId,
    'user_id': userId,
    'role': role,
  };
  factory DealAssignee.fromMap(Map<String, dynamic> map) => DealAssignee(
    id: map['id'],
    dealId: safeParseInt(map['deal_id']),
    userId: safeParseInt(map['user_id']),
    userName: map['user_name'],
    role: map['role'],
  );
}

class DealHandover {
  final dynamic id;
  final dynamic dealId;
  final dynamic fromUserId;
  final dynamic toUserId;
  final String? note;
  final DateTime? createdAt;

  DealHandover({
    this.id,
    required this.dealId,
    required this.fromUserId,
    required this.toUserId,
    this.note,
    this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'deal_id': dealId,
    'from_user_id': fromUserId,
    'to_user_id': toUserId,
    'note': note,
  };
}
