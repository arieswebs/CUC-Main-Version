import 'dart:io';
import '../../services/supabase_backup_service.dart';
import 'package:flutter/material.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:file_picker/file_picker.dart';
import 'client_deal_chat_screen.dart';
import '../../models/ModelProvider.dart';
import '../../theme.dart';
import '../../services/auth_service.dart';
import '../../services/backup_aware_api.dart';
import 'package:intl/intl.dart';
import 'dart:convert';

class ClientDealsView extends StatefulWidget {
  const ClientDealsView({super.key});

  @override
  State<ClientDealsView> createState() => _ClientDealsViewState();
}

class _ClientDealsViewState extends State<ClientDealsView> {
  bool _isLoading = true;
  List<Deals> _deals = [];
  Map<String, double> _dealPaidAmounts = {};
  Map<String, List<DealActivities>> _dealUpdates = {};

  @override
  void initState() {
    super.initState();
    _fetchDeals();
  }

  Future<void> _fetchDeals() async {
    setState(() => _isLoading = true);
    try {
      final clientName = await AuthService().getUserName();
      if (clientName != null) {
        final request = ModelQueries.list(
          Deals.classType,
          where: Deals.CLIENT_NAME.eq(clientName),
         limit: 10000);
        final response = await Amplify.API.query(request: request).response;
        
        final billsReq = ModelQueries.list(
          Billings.classType,
          where: Billings.CLIENT_NAME.eq(clientName),
         limit: 10000);
        final billsRes = await Amplify.API.query(request: billsReq).response;
        final clientBills = (billsRes.data?.items ?? []).whereType<Billings>().toList() ?? [];

        final rawDeals = (response.data?.items ?? []).whereType<Deals>().toList();
        final fetchedDeals = rawDeals.where((d) {
          final isCrm = (d.pipeline ?? '').toLowerCase() == 'crm' || (d.pipeline ?? '').toLowerCase() == 'lead';
          if (isCrm && d.is_won != true) return false;
          return true;
        }).toList();
        final Map<String, double> paidAmounts = {};

        for (final deal in fetchedDeals) {
          double totalPaid = (deal.payment_received ?? 0) + (deal.part_payment_amount ?? 0);
          for (final bill in clientBills) {
            try {
               final data = jsonDecode(bill.data ?? '{}');
               final items = data['items'] as List<dynamic>? ?? [];
               final desc = items.isNotEmpty ? items.first['description']?.toString().trim().toLowerCase() ?? '' : '';
               final dealName = deal.name?.trim().toLowerCase() ?? '';
               
               bool isMatch = false;
               if (deal.billing_id != null && bill.id == deal.billing_id.toString()) {
                 isMatch = true;
               } else if (dealName.isNotEmpty && desc.isNotEmpty) {
                 if (desc == dealName || desc.contains(dealName) || dealName.contains(desc)) {
                   isMatch = true;
                 }
               }
               
               if (isMatch) {
                  double advance = double.tryParse(data['advance_received']?.toString().replaceAll(RegExp(r'[^0-9.]'), '') ?? '0') ?? 0;
                  // Avoid double counting if the staff already entered it in part_payment_amount
                  if (advance > (deal.part_payment_amount ?? 0)) {
                      totalPaid += (advance - (deal.part_payment_amount ?? 0));
                  }
               }
            } catch (_) {}
          }
          paidAmounts[deal.id] = totalPaid;
        }

        // Fetch Daily Updates
        final updatesReq = ModelQueries.list(DealActivities.classType, limit: 1000);
        final updatesRes = await Amplify.API.query(request: updatesReq).response;
        final allUpdates = (updatesRes.data?.items ?? []).whereType<DealActivities>().where((a) => a.type == 'daily_update').toList() ?? [];
        
        final Map<String, List<DealActivities>> dealUpdates = {};
        for (var act in allUpdates) {
          if (act.deal_id != null) {
            final dIdStr = act.deal_id.toString();
            dealUpdates.putIfAbsent(dIdStr, () => []).add(act);
          }
        }
        // Sort each list by date descending
        dealUpdates.forEach((key, list) {
          list.sort((a, b) {
            final aDate = a.createdAt?.getDateTimeInUtc() ?? DateTime.tryParse(a.created_at ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bDate = b.createdAt?.getDateTimeInUtc() ?? DateTime.tryParse(b.created_at ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
            return bDate.compareTo(aDate);
          });
        });

        setState(() {
          _deals = fetchedDeals;
          _dealPaidAmounts = paidAmounts;
          _dealUpdates = dealUpdates;
        });
      }
    } catch (e) {
      debugPrint('Error fetching client deals: $e');
    }
    setState(() => _isLoading = false);
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return 'Unknown';
    try {
      final DateTime dt = DateTime.parse(dateStr);
      return DateFormat('dd MMM yyyy').format(dt);
    } catch (e) {
      return dateStr.split('T').first.split(' ').first;
    }
  }

  Future<void> _uploadRequiredDocument(Deals deal, String requestedName) async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx', 'xls', 'xlsx'],
      );

      if (result != null) {
        setState(() => _isLoading = true);
        
        final clientId = await AuthService().getUserIdStr();
        final clientName = await AuthService().getUserName();
        
        if (clientId == null || clientName == null) {
          setState(() => _isLoading = false);
          return;
        }

        String ext = '';
        if (result.files.single.name.contains('.')) {
          ext = '.${result.files.single.name.split('.').last}';
        }
        
        String finalName = requestedName;
        if (!finalName.toLowerCase().endsWith(ext.toLowerCase())) {
           if (!finalName.contains('.')) {
              finalName = finalName + ext;
           }
        }

        String path = 'public/$clientId/portal_uploads/$finalName';
        
        AWSFile awsFile;
        if (result.files.single.bytes != null) {
          awsFile = AWSFile.fromData(result.files.single.bytes!);
        } else if (result.files.single.path != null) {
          awsFile = AWSFile.fromPath(result.files.single.path!);
        } else {
          throw Exception('File data not available');
        }
        
        await Amplify.Storage.uploadFile(
          localFile: awsFile,
          path: StoragePath.fromString(path),
        ).result;
        try {
          final bytes = await File(result.files.single.path!).readAsBytes();
          SupabaseBackupService().backupFileInBackground(path, bytes);
        } catch (_) {}
        
        final newDoc = ClientDocuments(
          client_id: clientId,
          client_name: clientName,
          document_name: finalName,
          storage_path: path,
          og_copy: 'No',
          remarks: 'Uploaded directly for deal: ${deal.name}',
          verification_status: 'Under Verification',
          rejection_reason: '',
        );
        
        await BackupAwareApi().create(newDoc);
        
        List<dynamic> askedFiles = [];
        List<dynamic> receivedFiles = [];
        
        if (deal.files_asked != null && deal.files_asked!.isNotEmpty) {
           try { askedFiles = jsonDecode(deal.files_asked!); } catch (_) { 
             askedFiles = deal.files_asked!.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(); 
           }
        }
        if (deal.files_received != null && deal.files_received!.isNotEmpty) {
           try { receivedFiles = jsonDecode(deal.files_received!); } catch (_) { 
             receivedFiles = deal.files_received!.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(); 
           }
        }
        
        askedFiles.removeWhere((f) {
           String name = f is Map ? f['name'].toString() : f.toString();
           return name == requestedName || name.split('/').last == requestedName;
        });
        
        receivedFiles.add({
           'name': finalName,
           'status': 'Received',
           'date': DateTime.now().toIso8601String(),
        });
        
        final updatedDeal = deal.copyWith(
           files_asked: jsonEncode(askedFiles),
           files_received: jsonEncode(receivedFiles)
        );
        
        await BackupAwareApi().update(updatedDeal);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Document uploaded successfully!'), backgroundColor: Colors.green),
          );
        }
        
        await _fetchDeals();
      }
    } catch (e) {
      debugPrint('Upload error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red),
        );
      }
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    bool isMobile = MediaQuery.of(context).size.width < 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.all(isMobile ? 16 : 24),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [AppTheme.accentColor, Colors.orangeAccent]),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: AppTheme.accentColor.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))
                  ]
                ),
                child: const Icon(Icons.work_outline_rounded, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('My Workfiles', style: TextStyle(fontSize: isMobile ? 22 : 26, fontWeight: FontWeight.w800, color: AppTheme.textColor, letterSpacing: -0.5)),
                    Text('Track the progress of your ongoing cases', style: TextStyle(fontSize: isMobile ? 12 : 14, color: AppTheme.mutedTextColor)),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _deals.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open_rounded, size: 64, color: Colors.grey.shade300),
                    const SizedBox(height: 16),
                    const Text('No active workfiles found.', style: TextStyle(color: AppTheme.mutedTextColor, fontSize: 16, fontWeight: FontWeight.w500)),
                  ],
                ).animate().fade().scale(curve: Curves.easeOutBack, duration: 500.ms),
              )
            : ListView.builder(
                padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 24, vertical: 8),
                itemCount: _deals.length,
                itemBuilder: (context, index) {
                  final deal = _deals[index];
                  final totalAmount = deal.amount ?? 0;
                  final paidAmount = _dealPaidAmounts[deal.id] ?? 0;
                  final percentPaid = totalAmount > 0 ? (paidAmount / totalAmount).clamp(0.0, 1.0) : 0.0;
                  
                  return Container(
                    margin: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 24, offset: const Offset(0, 8)),
                        BoxShadow(color: AppTheme.accentColor.withValues(alpha: 0.02), blurRadius: 12, spreadRadius: 4),
                      ],
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header Gradient Strip
                          Container(
                            height: 6,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: deal.stage == 'Completed' 
                                  ? [Colors.green, Colors.greenAccent]
                                  : [AppTheme.accentColor, Colors.orangeAccent],
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.all(isMobile ? 16 : 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(deal.name ?? 'Unnamed Workfile', style: const TextStyle(fontSize: 20, color: AppTheme.textColor, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
                                          if (deal.work_type != null && deal.work_type!.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 6),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: Colors.grey.shade100,
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(deal.work_type!, style: TextStyle(color: Colors.grey.shade700, fontSize: 12, fontWeight: FontWeight.w600)),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: deal.stage == 'Completed' ? Colors.green.withValues(alpha: 0.1) : AppTheme.accentColor.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(color: deal.stage == 'Completed' ? Colors.green.withValues(alpha: 0.3) : AppTheme.accentColor.withValues(alpha: 0.3)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(deal.stage == 'Completed' ? Icons.check_circle_rounded : Icons.pending_actions_rounded, 
                                            size: 14, 
                                            color: deal.stage == 'Completed' ? Colors.green : AppTheme.accentColor
                                          ),
                                          const SizedBox(width: 6),
                                          Text(deal.stage ?? 'Pending', style: TextStyle(color: deal.stage == 'Completed' ? Colors.green : AppTheme.accentColor, fontSize: 13, fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: const Color(0xFFE2E8F0)),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _buildPremiumInfoColumn('Assigned To', deal.responsible_name ?? 'Unassigned', Icons.person_rounded, Colors.blue),
                                      ),
                                      Container(width: 1, height: 32, color: Colors.grey.shade300),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: _buildPremiumInfoColumn('Date Started', _formatDate(deal.created_at), Icons.calendar_month_rounded, Colors.purple),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                
                                // Payment Progress Section
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text('Payment Progress', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textColor)),
                                        Text('₹${paidAmount.toStringAsFixed(0)} / ₹${totalAmount.toStringAsFixed(0)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: percentPaid >= 1 ? Colors.green : AppTheme.accentColor)),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: LinearProgressIndicator(
                                        value: percentPaid,
                                        minHeight: 8,
                                        backgroundColor: Colors.grey.shade200,
                                        valueColor: AlwaysStoppedAnimation<Color>(percentPaid >= 1 ? Colors.green : AppTheme.accentColor),
                                      ),
                                    ),
                                  ],
                                ),
                                
                                if (deal.description != null && deal.description!.isNotEmpty) ...[
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 20),
                                    child: Divider(height: 1, color: Color(0xFFF1F5F9)),
                                  ),
                                  Row(
                                    children: [
                                      Icon(Icons.notes_rounded, size: 18, color: Colors.grey.shade500),
                                      const SizedBox(width: 8),
                                      const Text('Description', style: TextStyle(fontSize: 13, color: AppTheme.mutedTextColor, fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(deal.description!, style: const TextStyle(fontSize: 14, color: AppTheme.textColor, height: 1.5)),
                                ],
                                
                                if (deal.files_asked != null && deal.files_asked!.isNotEmpty && deal.files_asked != '[]') ...[
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 20),
                                    child: Divider(height: 1, color: Color(0xFFF1F5F9)),
                                  ),
                                  const Text('Documents Required', style: TextStyle(fontSize: 13, color: AppTheme.textColor, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 12),
                                  _buildFilesList(deal.files_asked, Icons.upload_file_rounded, Colors.orange, deal: deal, isUploadable: true),
                                ],
                                
                                if (deal.files_received != null && deal.files_received!.isNotEmpty && deal.files_received != '[]') ...[
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 20),
                                    child: Divider(height: 1, color: Color(0xFFF1F5F9)),
                                  ),
                                  const Text('Documents Received', style: TextStyle(fontSize: 13, color: AppTheme.textColor, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 12),
                                  _buildFilesList(deal.files_received, Icons.check_circle_rounded, Colors.green),
                                ],

                                // Daily Updates Timeline
                                if (_dealUpdates[deal.id]?.isNotEmpty ?? false) ...[
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 20),
                                    child: Divider(height: 1, color: Color(0xFFF1F5F9)),
                                  ),
                                  Row(
                                    children: [
                                      const Icon(Icons.timeline_rounded, color: AppTheme.accentColor, size: 20),
                                      const SizedBox(width: 8),
                                      const Text('Daily Updates', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textColor)),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  Container(
                                    decoration: BoxDecoration(
                                      color: AppTheme.primaryColor.withValues(alpha: 0.03),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.1)),
                                    ),
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      children: _dealUpdates[deal.id]!.take(5).map((update) {
                                        DateTime date = update.createdAt?.getDateTimeInUtc() ?? DateTime.now();
                                        if (update.created_at != null) {
                                          date = DateTime.tryParse(update.created_at!) ?? date;
                                        }
                                        return Padding(
                                          padding: const EdgeInsets.only(bottom: 12),
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Container(
                                                margin: const EdgeInsets.only(top: 4, right: 12),
                                                width: 10,
                                                height: 10,
                                                decoration: const BoxDecoration(
                                                  color: AppTheme.primaryColor,
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      update.description ?? '',
                                                      style: const TextStyle(fontSize: 14, color: AppTheme.textColor),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      DateFormat('MMM dd, hh:mm a').format(date),
                                                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ],
                                
                                const SizedBox(height: 24),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: () {
                                      Navigator.push(context, MaterialPageRoute(builder: (_) => ClientDealChatScreen(deal: deal)));
                                    },
                                    icon: const Icon(Icons.help_outline_rounded, size: 18),
                                    label: const Text('Help & Queries', style: TextStyle(fontWeight: FontWeight.bold)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppTheme.accentColor.withValues(alpha: 0.1),
                                      foregroundColor: AppTheme.accentColor,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ).animate().fade(delay: (index * 100).ms).slideY(begin: 0.1, end: 0, curve: Curves.easeOutCubic, duration: 600.ms);
                },
              ),
        ),
      ],
    );
  }

  Widget _buildPremiumInfoColumn(String label, String value, IconData icon, Color iconColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 16, color: iconColor),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.mutedTextColor, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 13, color: AppTheme.textColor, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFilesList(String? filesJson, IconData icon, Color color, {Deals? deal, bool isUploadable = false}) {
    if (filesJson == null || filesJson.trim().isEmpty) return const SizedBox();
    
    List<dynamic> files = [];
    try {
      final decoded = jsonDecode(filesJson);
      if (decoded is List) {
        files = decoded;
      } else {
        files = filesJson.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
    } catch (_) {
      files = filesJson.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }

    if (files.isEmpty) return const SizedBox();

    return Column(
      children: files.map((f) {
        String rawName = '';
        String status = 'Pending';
        
        if (f is Map) {
          rawName = f['name']?.toString() ?? 'Unknown File';
          status = f['status']?.toString() ?? 'Pending';
        } else {
          rawName = f.toString();
        }
        
        final cleanName = rawName.split('/').last;

        return InkWell(
          onTap: isUploadable && deal != null ? () => _uploadRequiredDocument(deal, rawName) : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: color == Colors.green ? Colors.green.shade50 : (isUploadable ? AppTheme.primaryColor.withValues(alpha: 0.05) : const Color(0xFFF8FAFC)),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color == Colors.green ? Colors.green.shade100 : (isUploadable ? AppTheme.primaryColor.withValues(alpha: 0.2) : const Color(0xFFE2E8F0))),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(cleanName, style: TextStyle(fontSize: 13, color: color == Colors.green ? Colors.green.shade800 : AppTheme.textColor, fontWeight: FontWeight.w600)),
                      if (isUploadable)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('Click to upload', style: TextStyle(fontSize: 11, color: AppTheme.primaryColor.withValues(alpha: 0.8), fontWeight: FontWeight.w500)),
                        ),
                    ],
                  ),
                ),
                if (color != Colors.green)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isUploadable ? AppTheme.primaryColor : (status == 'Received' ? Colors.green.shade100 : Colors.orange.shade100),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(isUploadable ? 'Upload' : status, style: TextStyle(fontSize: 10, color: isUploadable ? Colors.white : (status == 'Received' ? Colors.green.shade800 : Colors.orange.shade800), fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
