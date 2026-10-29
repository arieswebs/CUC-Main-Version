import 'package:flutter/material.dart';
import 'workfile_management_screen.dart';
import '../models/deal.dart';

export 'workfile_management_screen.dart';

class CaseManagementScreen extends StatelessWidget {
  final Map<String, dynamic>? existingCase;
  final Deal? existingDeal;

  const CaseManagementScreen({
    super.key,
    this.existingCase,
    this.existingDeal,
  });

  @override
  Widget build(BuildContext context) {
    return WorkfileManagementScreen(
      existingCase: existingCase,
      existingDeal: existingDeal,
    );
  }
}

