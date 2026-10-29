import 'package:flutter/material.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:convert';
import 'package:flutter/services.dart';

import '../models/ModelProvider.dart' as amplify_models;
import '../theme.dart';
import '../models/inward_post_model.dart';
import '../services/inward_post_service.dart';
import '../models/deal.dart';
import '../services/deal_service.dart';
import '../widgets/premium_app_bar.dart';

class CreateFileAcknowledgementScreen extends StatefulWidget {
  final String currentUserRole;
  final String currentUserName;

  final Deal? initialDeal;
  final String? initialFileName;
  final String? initialFromName;
  final String? initialAction;
  final InwardPost? editingPost;

  const CreateFileAcknowledgementScreen({
    super.key,
    required this.currentUserRole,
    required this.currentUserName,
    this.initialDeal,
    this.initialFileName,
    this.initialFromName,
    this.initialAction,
    this.editingPost,
  });

  @override
  State<CreateFileAcknowledgementScreen> createState() => _CreateFileAcknowledgementScreenState();
}

class _CreateFileAcknowledgementScreenState extends State<CreateFileAcknowledgementScreen> {
  final _titleController = TextEditingController();
  final _fromController = TextEditingController();
  final _toController = TextEditingController();
  final _signatureController = TextEditingController();
  final _newFileController = TextEditingController();
  
  String _actionType = 'Received';
  List<Map<String, dynamic>> _users = [];
  List<Deal> _deals = [];
  Deal? _selectedDeal;
  List<String> _selectedFiles = [];
  final Map<String, String> _fileRemarks = {};
  final Map<String, TextEditingController> _fileRemarkControllers = {};
  final Map<String, String> _fileTypes = {};
  
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialAction != null) {
      _actionType = widget.initialAction!;
    }
    
    if (widget.editingPost != null) {
      _loadEditingPost();
    } else {
      _updateControllersForAction();
      if (widget.initialFileName != null) {
        _selectedFiles = widget.initialFileName!.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        for (var f in _selectedFiles) {
          _fileTypes[f] = 'Original';
        }
      }
    }
    
    _loadData();
    
    // Add listeners to trigger PDF rebuild
    _titleController.addListener(() => setState(() {}));
    _fromController.addListener(() => setState(() {}));
    _toController.addListener(() => setState(() {}));
    _signatureController.addListener(() => setState(() {}));
  }
  
  void _loadEditingPost() {
    final post = widget.editingPost!;
    _fromController.text = post.senderName;
    _toController.text = post.recipientName;
    
    String fileDesc = post.description;
    if (fileDesc.startsWith('[Received]')) {
      _actionType = 'Received';
      fileDesc = fileDesc.replaceAll('[Received]', '').trim();
    } else if (fileDesc.startsWith('[Returned]')) {
      _actionType = 'Returned';
      fileDesc = fileDesc.replaceAll('[Returned]', '').trim();
    }

    String filesPart = fileDesc;
    String remarks = '';
    
    if (filesPart.contains('Title: ') && filesPart.contains(' | File: ')) {
      final titlePart = filesPart.split(' | File: ')[0];
      _titleController.text = titlePart.replaceFirst('Title: ', '').trim();
      filesPart = filesPart.substring(filesPart.indexOf(' | File: ') + 9);
    }

    if (filesPart.contains(' | Remarks:')) {
      final parts = fileDesc.split(' | Remarks:');
      filesPart = parts[0];
      remarks = parts[1].trim();
    }
    if (filesPart.startsWith('File: ')) {
      filesPart = filesPart.replaceFirst('File: ', '');
    }
    String legacyFileTypeStr = '';
    if (filesPart.contains('(') && filesPart.endsWith(')')) {
      int lastParen = filesPart.lastIndexOf('(');
      legacyFileTypeStr = filesPart.substring(lastParen).trim();
      legacyFileTypeStr = legacyFileTypeStr.replaceAll('(', '').replaceAll(')', '');
      filesPart = filesPart.substring(0, lastParen).trim();
    }
    List<String> filePartsList;
    if (filesPart.contains('||')) {
      filePartsList = filesPart.split(' ; ');
    } else {
      filePartsList = filesPart.contains(' ; ') ? filesPart.split(' ; ') : filesPart.split(',');
    }
    
    for (var fName in filePartsList) {
      fName = fName.trim();
      if (fName.isEmpty) continue;
      
      String fileRemark = '';
      String currentFileType = legacyFileTypeStr.isNotEmpty ? legacyFileTypeStr : 'Original';
      
      if (fName.contains('||')) {
        final typeParts = fName.split('||');
        fName = typeParts[0].trim();
        if (typeParts.length > 1) {
          final rest = typeParts[1];
          if (rest.contains('::')) {
            final rParts = rest.split('::');
            currentFileType = rParts[0].trim();
            fileRemark = rParts[1].trim();
          } else {
            currentFileType = rest.trim();
          }
        }
      } else if (fName.contains('::')) {
        final parts = fName.split('::');
        fName = parts[0].trim();
        if (parts.length > 1) {
          fileRemark = parts[1].trim();
        }
      }
      if (fileRemark.isEmpty && remarks.isNotEmpty) {
        fileRemark = remarks;
      }
      
      _selectedFiles.add(fName);
      _fileTypes[fName] = currentFileType;
      _fileRemarks[fName] = fileRemark;
    }
  }

  void _updateControllersForAction({bool clearFiles = true}) {
    String dealClientData = '';
    if (_selectedDeal != null) {
      List<String> parts = [];
      if (_selectedDeal!.clientName != null && _selectedDeal!.clientName!.isNotEmpty) {
        parts.add(_selectedDeal!.clientName!);
      }
      if (_selectedDeal!.company != null && _selectedDeal!.company!.isNotEmpty) {
        parts.add(_selectedDeal!.company!);
      }
      if (_selectedDeal!.contactInfo != null && _selectedDeal!.contactInfo!.isNotEmpty) {
        parts.add(_selectedDeal!.contactInfo!);
      }
      dealClientData = parts.join('\n');
    }

    String currentClientName = '';
    if (_fromController.text != widget.currentUserName && _fromController.text.isNotEmpty) {
      currentClientName = _fromController.text;
    } else if (_toController.text != widget.currentUserName && _toController.text.isNotEmpty) {
      currentClientName = _toController.text;
    }

    if (_actionType == 'Received') {
      _fromController.text = widget.currentUserName;
      if (_selectedDeal != null) {
        _toController.text = dealClientData;
      } else if (widget.initialFromName != null) {
        _toController.text = widget.initialFromName!;
      } else if (currentClientName.isNotEmpty) {
        _toController.text = currentClientName;
      } else if (widget.editingPost == null) {
        _toController.clear();
      }
    } else {
      _toController.text = widget.currentUserName;
      if (_selectedDeal != null) {
        _fromController.text = dealClientData;
      } else if (widget.initialFromName != null) {
        _fromController.text = widget.initialFromName!;
      } else if (currentClientName.isNotEmpty) {
        _fromController.text = currentClientName;
      } else if (widget.editingPost == null) {
        _fromController.clear();
      }
    }
    
    if (clearFiles) {
      _selectedFiles.clear();
    }
    setState((){});
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    List<Deal> deals = [];
    try {
      final allDeals = await DealService().getAllDeals();
      deals = allDeals.where((d) {
        final isCrm = d.pipeline.toLowerCase() == 'crm' || d.pipeline.toLowerCase() == 'lead';
        if (isCrm && !d.isWon) return false;
        return true;
      }).toList();
    } catch(e) {
      debugPrint('Error fetching deals: $e');
    }
    List<Map<String, dynamic>> users = [];
    try {
      final req = ModelQueries.list(amplify_models.Users.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      final usersList = (res.data?.items ?? []).whereType<amplify_models.Users>().toList() ?? [];
      usersList.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      users = usersList.map((u) => {
        'id': u.id,
        'name': u.name,
        'role': u.role,
      }).toList();
    } catch(e) {
      debugPrint('Error fetching users: $e');
    }
    
    if (mounted) {
      setState(() {
        _users = users;
        _deals = deals;
        if (widget.initialDeal != null) {
          try {
            _selectedDeal = deals.firstWhere((d) => d.id == widget.initialDeal!.id);
          } catch(e) {
            _selectedDeal = widget.initialDeal;
          }
        }
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _fromController.dispose();
    _toController.dispose();
    _newFileController.dispose();
    for (var c in _fileRemarkControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _deletePost(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Acknowledgement'),
        content: const Text('Are you sure you want to delete this acknowledgement? This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true), 
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    
    if (confirm == true && mounted) {
      setState(() => _isLoading = true);
      await InwardPostService.deletePost(widget.editingPost!.id);
      if (mounted) {
        Navigator.pop(context, true);
      }
    }
  }

  Future<void> _save() async {
    final String fileName = _selectedFiles.map((f) {
      final remark = _fileRemarks[f] ?? '';
      final type = _fileTypes[f] ?? 'Original';
      String res = '$f||$type';
      return remark.isNotEmpty ? '$res::$remark' : res;
    }).join(' ; ');

    if (fileName.isEmpty || _fromController.text.trim().isEmpty || _toController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File Name, Handed Over By, and Received By are required'), backgroundColor: Colors.redAccent),
      );
      return;
    }

    String title = _titleController.text.trim();
    String descText = title.isNotEmpty 
        ? '[$_actionType] Title: $title | File: $fileName'
        : '[$_actionType] File: $fileName';

    final newPost = InwardPost(
      id: widget.editingPost?.id ?? 'FILEACK-${DateTime.now().millisecondsSinceEpoch}',
      senderName: _fromController.text.trim(),
      recipientName: _toController.text.trim(),
      receivedBy: widget.editingPost?.receivedBy ?? widget.currentUserName,
      receivedDate: widget.editingPost?.receivedDate ?? DateTime.now(),
      status: widget.editingPost?.status ?? PostStatus.pendingConfirmation,
      description: descText,
    );

    if (widget.editingPost != null) {
      await InwardPostService.updatePost(newPost);
    } else {
      await InwardPostService.addPost(newPost);
    }
    
    if (_selectedDeal != null && _selectedFiles.isNotEmpty) {
      try {
        List<Map<String, dynamic>> fileStates = [];
        final rawReceived = _selectedDeal!.filesReceived ?? '';
        final receivedJson = rawReceived.isEmpty ? '[]' : rawReceived;
        final decoded = jsonDecode(receivedJson);
        if (decoded is List) {
           if (decoded.isNotEmpty && decoded.first is String) {
             fileStates = decoded.map((e) => {'name': e.toString(), 'status': 'Received', 'type': 'Copy'}).toList();
           } else {
             fileStates = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
           }
        }
        
        List<String> askedList = (_selectedDeal!.filesAsked ?? '').split(RegExp(r'[,\n]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

        for (final file in _selectedFiles) {
          int stateIndex = fileStates.indexWhere((s) => s['name'] == file);
          if (stateIndex != -1) {
            fileStates[stateIndex]['status'] = _actionType == 'Received' ? 'Received' : 'Returned';
          } else {
            fileStates.add({
              'name': file,
              'status': _actionType == 'Received' ? 'Received' : 'Returned',
              'type': 'Copy'
            });
          }
          if (_actionType == 'Received' && !askedList.contains(file)) {
            askedList.add(file);
          }
        }

        final updatedDeal = _selectedDeal!.copyWith(
          filesReceived: jsonEncode(fileStates),
          filesAsked: askedList.join(', ')
        );
        await DealService().updateDeal(updatedDeal);
      } catch (e) {
        debugPrint('Error updating deal files: $e');
      }
    }

    if (mounted) {
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Acknowledgement logged successfully!'), backgroundColor: Colors.green),
      );
    }
  }

  InwardPost _buildPreviewPost() {
    final String fileName = _selectedFiles.map((f) {
      final remark = _fileRemarks[f] ?? '';
      final type = _fileTypes[f] ?? 'Original';
      String res = '$f||$type';
      return remark.isNotEmpty ? '$res::$remark' : res;
    }).join(' ; ');

    String title = _titleController.text.trim();
    String descText = title.isNotEmpty 
        ? '[$_actionType] Title: $title | File: $fileName'
        : '[$_actionType] File: $fileName';

    return InwardPost(
      id: 'preview',
      senderName: _fromController.text.trim(),
      recipientName: _toController.text.trim(),
      receivedBy: widget.currentUserName,
      receivedDate: DateTime.now(),
      status: PostStatus.pendingConfirmation,
      description: descText,
    );
  }

  Future<Uint8List> _generateLivePdf(PdfPageFormat format) async {
    final post = _buildPreviewPost();
    final font = await PdfGoogleFonts.notoSansRegular();
    final fontBold = await PdfGoogleFonts.notoSansBold();
    final fallbackFont = await PdfGoogleFonts.notoSansMalayalamRegular();
    final fallbackEmoji = await PdfGoogleFonts.notoColorEmoji();
    final doc = pw.Document(theme: pw.ThemeData.withFont(
      base: font, 
      bold: fontBold,
      fontFallback: [fallbackFont, fallbackEmoji],
    ));
    
    String action = 'Received';
    String fileDesc = post.description;
    if (post.description.startsWith('[Received]')) {
      action = 'Received';
      fileDesc = post.description.replaceAll('[Received]', '').trim();
    } else if (post.description.startsWith('[Returned]')) {
      action = 'Returned';
      fileDesc = post.description.replaceAll('[Returned]', '').trim();
    }

    String filesPart = fileDesc;
    String remarks = '';
    String title = '';
    
    if (filesPart.contains('Title: ') && filesPart.contains(' | File: ')) {
      final titlePart = filesPart.split(' | File: ')[0];
      title = titlePart.replaceFirst('Title: ', '').trim();
      filesPart = filesPart.substring(filesPart.indexOf(' | File: ') + 9);
    }

    if (filesPart.contains(' | Remarks:')) {
      final parts = fileDesc.split(' | Remarks:');
      filesPart = parts[0];
      remarks = parts[1].trim();
    }
    if (filesPart.startsWith('File: ')) {
      filesPart = filesPart.replaceFirst('File: ', '');
    }
    String legacyFileTypeStr = '';
    if (filesPart.contains('(') && filesPart.endsWith(')')) {
      int lastParen = filesPart.lastIndexOf('(');
      legacyFileTypeStr = filesPart.substring(lastParen).trim();
      legacyFileTypeStr = legacyFileTypeStr.replaceAll('(', '[').replaceAll(')', ']');
      filesPart = filesPart.substring(0, lastParen).trim();
    }
    List<String> filePartsList;
    if (filesPart.contains('||')) {
      filePartsList = filesPart.split(' ; ');
    } else {
      filePartsList = filesPart.contains(' ; ') ? filesPart.split(' ; ') : filesPart.split(',');
    }
    List<String> fileNames = filePartsList.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    List<pw.Widget> buildAddress(String name, bool isCompany) {
      final lines = name.split('\n');
      final widgets = <pw.Widget>[];
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        widgets.add(
          pw.Text(
            line.toUpperCase(), 
            style: pw.TextStyle(
              fontSize: 10, 
              fontWeight: i == 0 ? pw.FontWeight.bold : pw.FontWeight.normal,
            )
          )
        );
      }
      if (isCompany) {
        widgets.addAll([
          pw.Text('COCHIN UNITED CONSULTANCY', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          pw.Text('4th FLOOR, MATHER SQUARE, C- BLOCK,', style: const pw.TextStyle(fontSize: 10)),
          pw.Text('NEAR NORTH RAILWAY STATION', style: const pw.TextStyle(fontSize: 10)),
          pw.Text('ERNAKULAM - 682018', style: const pw.TextStyle(fontSize: 10)),
        ]);
      }
      return widgets;
    }

    bool senderIsCompany = action == 'Received';
    bool recipientIsCompany = action == 'Returned';

    String fromName = post.senderName;
    bool fromIsCompany = senderIsCompany;

    String toName = post.recipientName;
    bool toIsCompany = recipientIsCompany;
    
    String bodyText = action == 'Returned' 
        ? 'We hereby acknowledge receipt of the below-mentioned documents:' 
        : 'The following documents are submitted herewith:';

    pw.MemoryImage? logoImage;
    try {
      final ByteData bytes = await rootBundle.load('assets/logo.png');
      logoImage = pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (e) {
      debugPrint('Could not load logo for PDF: $e');
    }

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 30),
          buildBackground: (pw.Context context) {
            if (logoImage != null && action != 'Returned') {
              return pw.Center(
                child: pw.Opacity(
                  opacity: 0.1,
                  child: pw.Image(logoImage, width: 480, height: 480),
                ),
              );
            }
            return pw.SizedBox();
          },
        ),
        footer: (pw.Context context) {
          return pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.SizedBox(height: 20),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 20),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.SizedBox(),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text('Authorized Signature', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700)),
                        pw.SizedBox(height: 40),
                        pw.Text('(${_signatureController.text.trim().isNotEmpty ? _signatureController.text.trim() : fromName.split('\n').first.trim()})', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Center(
                child: pw.Text('This is a system generated document. Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
              ),
            ],
          );
        },
        build: (pw.Context context) {
          return [
            if (action != 'Returned') ...[
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (logoImage != null) pw.Image(logoImage, width: 90, height: 90) else pw.SizedBox(width: 90, height: 90),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(
                        'COCHIN UNITED CONSULTANCY',
                        style: pw.TextStyle(fontSize: 16, color: PdfColors.black, fontWeight: pw.FontWeight.bold),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text('4th Floor, Mather Square, C- Block,', style: const pw.TextStyle(fontSize: 8)),
                      pw.Text('Near North Railway Station, Ernakulam, Kerala 682018', style: const pw.TextStyle(fontSize: 8)),
                      pw.SizedBox(height: 2),
                      pw.Text('email id: cochinunitedconsultancydm@gmail.com', style: const pw.TextStyle(fontSize: 8, color: PdfColors.blue700)),

                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.Divider(thickness: 0.5, color: PdfColors.grey400),
              pw.SizedBox(height: 24),
            ] else ...[
              pw.SizedBox(height: 80),
            ],
            
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 20),
              child: pw.Center(
                child: pw.Text('ACKNOWLEDGEMENT LETTER', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline)),
              ),
            ),
            pw.SizedBox(height: 30),
            
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 20),
              child: pw.Text('FROM', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 60, right: 20, top: 8),
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: buildAddress(fromName, fromIsCompany)),
            ),
            
            pw.SizedBox(height: 20),
            
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 20),
              child: pw.Text('TO', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 60, right: 20, top: 8),
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: buildAddress(toName, toIsCompany)),
            ),
            
            pw.SizedBox(height: 30),
            
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 20),
              child: pw.Text('Sub: Document Acknowledgement Letter.', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
            ),
            
            pw.SizedBox(height: 20),
            
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 20),
              child: pw.Text(bodyText, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
            ),
            
            if (title.isNotEmpty) ...[
              pw.SizedBox(height: 10),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 20),
                child: pw.Text('Title: $title', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
              ),
            ],
            
            pw.SizedBox(height: 20),
            
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 40),
              child: pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
                columnWidths: {
                  0: const pw.FixedColumnWidth(40),
                  1: const pw.FlexColumnWidth(3),
                  2: const pw.FixedColumnWidth(60),
                  3: const pw.FlexColumnWidth(2),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('Sl No', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center)),
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('Document Name', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold))),
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('Type', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center)),
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('Remarks', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold))),
                    ],
                  ),
                  ...List.generate(fileNames.length, (index) {
                      String fName = fileNames[index];
                      String fileRemark = '';
                      String currentFileType = legacyFileTypeStr.isNotEmpty ? legacyFileTypeStr : '[Original]';
                      
                      if (fName.contains('||')) {
                        final typeParts = fName.split('||');
                        fName = typeParts[0].trim();
                        if (typeParts.length > 1) {
                          final rest = typeParts[1];
                          if (rest.contains('::')) {
                            final rParts = rest.split('::');
                            currentFileType = '[${rParts[0].trim()}]';
                            fileRemark = rParts[1].trim();
                          } else {
                            currentFileType = '[${rest.trim()}]';
                          }
                        }
                      } else if (fName.contains('::')) {
                        final parts = fName.split('::');
                        fName = parts[0].trim();
                        if (parts.length > 1) {
                          fileRemark = parts[1].trim();
                        }
                      }
                      if (fileRemark.isEmpty && remarks.isNotEmpty) {
                        fileRemark = remarks;
                      }
                      return pw.TableRow(
                        children: [
                          pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('${index + 1}', style: const pw.TextStyle(fontSize: 10), textAlign: pw.TextAlign.center)),
                          pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(fName.toUpperCase(), style: const pw.TextStyle(fontSize: 10))),
                          pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(currentFileType, style: const pw.TextStyle(fontSize: 10), textAlign: pw.TextAlign.center)),
                          pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(fileRemark, style: const pw.TextStyle(fontSize: 10))),
                        ],
                      );
                  }),
                ],
              ),
            ),
            
          ];
        },
      ),
    );

    return doc.save();
  }
  
  Widget _buildFileChecklist() {
    final availableFiles = <String>{};
    if (_selectedDeal?.filesReceived != null) {
      List<Map<String, dynamic>> fileStates = [];
      try {
        final rawReceived = _selectedDeal!.filesReceived ?? '';
        final receivedJson = rawReceived.isEmpty ? '[]' : rawReceived;
        final decoded = jsonDecode(receivedJson);
        if (decoded is List) {
           if (decoded.isNotEmpty && decoded.first is String) {
             fileStates = decoded.map((e) => {'name': e.toString(), 'status': 'Received', 'type': 'Copy'}).toList();
           } else {
             fileStates = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
           }
        }
      } catch(e) {
        debugPrint('Error parsing files: $e');
      }
      
      final askedList = (_selectedDeal!.filesAsked ?? '').split(RegExp(r'[,\n]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

      if (_actionType == 'Received') {
        for (final f in askedList) {
          final state = fileStates.firstWhere((s) => s['name'] == f, orElse: () => {'name': f, 'status': 'Pending', 'type': 'Copy'});
          if (state['status'] != 'Received') {
            availableFiles.add(f);
          }
        }
      } else {
        for (final state in fileStates) {
          if (state['status'] == 'Received') {
            availableFiles.add(state['name']);
          }
        }
      }
    }

    for (final f in _selectedFiles) {
      if (!availableFiles.contains(f)) {
        availableFiles.add(f);
      }
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _actionType == 'Received' ? 'Select files being received:' : 'Select files being handed over:',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87),
          ),
          const SizedBox(height: 8),
          if (availableFiles.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No matching files found. You can add one below.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: availableFiles.map((file) {
              final isSelected = _selectedFiles.contains(file);
              return FilterChip(
                label: Text(file, style: TextStyle(fontSize: 12, color: isSelected ? Colors.white : Colors.black87)),
                selected: isSelected,
                selectedColor: AppTheme.primaryColor,
                checkmarkColor: Colors.white,
                onSelected: (val) {
                  setState(() {
                    if (val) {
                      _selectedFiles.add(file);
                    } else {
                      _selectedFiles.remove(file);
                    }
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newFileController,
                  decoration: InputDecoration(
                    hintText: 'Type new file name and press Add...',
                    hintStyle: const TextStyle(fontSize: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onSubmitted: (val) {
                    if (val.trim().isNotEmpty) {
                      setState(() {
                        if (!_selectedFiles.contains(val.trim())) _selectedFiles.add(val.trim());
                        _newFileController.clear();
                      });
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  final val = _newFileController.text.trim();
                  if (val.isNotEmpty) {
                    setState(() {
                      if (!_selectedFiles.contains(val)) _selectedFiles.add(val);
                      _newFileController.clear();
                    });
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                child: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_selectedFiles.isNotEmpty) ...[
            const Text('File Settings:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87)),
            const SizedBox(height: 8),
            ..._selectedFiles.map((f) {
              _fileRemarkControllers[f] ??= TextEditingController(text: _fileRemarks[f] ?? '');
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _fileRemarkControllers[f],
                            decoration: InputDecoration(
                              labelText: 'Remarks (optional)',
                              hintStyle: const TextStyle(fontSize: 12),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                        onChanged: (val) {
                          _fileRemarks[f] = val;
                          setState(() {}); // live update
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 1,
                      child: DropdownButtonFormField<String>(
                        initialValue: _fileTypes[f] ?? 'Original',
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        items: ['Original', 'Copy'].map((type) {
                          return DropdownMenuItem(value: type, child: Text(type, style: const TextStyle(fontSize: 13)));
                        }).toList(),
                        onChanged: (val) {
                          setState(() {
                            _fileTypes[f] = val!;
                          });
                        },
                      ),
                    ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildDealAutocomplete() {
    return Autocomplete<Deal>(
      displayStringForOption: (Deal option) {
        final prefix = option.company != null && option.company!.isNotEmpty ? '${option.company} - ' : '';
        return '$prefix${option.name} (${option.clientName ?? ''})';
      },
      optionsBuilder: (TextEditingValue textEditingValue) {
        if (textEditingValue.text.isEmpty) {
          return const Iterable<Deal>.empty();
        }
        final lower = textEditingValue.text.toLowerCase();
        return _deals.where((Deal deal) {
          return (deal.name.toLowerCase().contains(lower)) ||
                 (deal.clientName?.toLowerCase().contains(lower) ?? false) ||
                 (deal.company?.toLowerCase().contains(lower) ?? false);
        });
      },
      onSelected: (Deal selection) {
        setState(() {
          _selectedDeal = selection;
          _updateControllersForAction();
        });
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        if (_selectedDeal != null) {
          final prefix = _selectedDeal!.company != null && _selectedDeal!.company!.isNotEmpty ? '${_selectedDeal!.company} - ' : '';
          controller.text = '$prefix${_selectedDeal!.name} (${_selectedDeal!.clientName ?? ''})';
        }
        return TextField(
          controller: controller,
          focusNode: focusNode,
          onSubmitted: (String value) => onFieldSubmitted(),
          decoration: InputDecoration(
            hintText: 'Search for Work / Deal...',
            hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            filled: true,
            fillColor: Colors.grey.shade50,
            prefixIcon: const Icon(Icons.work_outline_rounded, color: AppTheme.primaryColor),
            suffixIcon: _selectedDeal != null
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      setState(() {
                        _selectedDeal = null;
                        controller.clear();
                        _updateControllersForAction();
                      });
                    },
                  )
                : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4.0,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 300,
              height: 200,
              child: ListView.builder(
                padding: const EdgeInsets.all(8.0),
                itemCount: options.length,
                itemBuilder: (BuildContext context, int index) {
                  final Deal option = options.elementAt(index);
                  return ListTile(
                    title: Text(option.name),
                    subtitle: Text('${option.company ?? ''} - ${option.clientName ?? ''}'),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildUserAutocomplete({required TextEditingController controller, required String hint, required IconData icon}) {
    return Autocomplete<String>(
      optionsBuilder: (TextEditingValue textEditingValue) {
        if (textEditingValue.text.isEmpty) {
          return const Iterable<String>.empty();
        }
        final lower = textEditingValue.text.toLowerCase();
        final matches = _users
            .map((u) => u['name'] as String)
            .where((name) => name.toLowerCase().contains(lower))
            .toList();
        
        if (matches.isEmpty && _selectedDeal != null) {
          final dealClientNames = <String>[];
          if (_selectedDeal!.clientName != null) dealClientNames.add(_selectedDeal!.clientName!);
          if (_selectedDeal!.company != null) dealClientNames.add(_selectedDeal!.company!);
          
          return dealClientNames.where((n) => n.toLowerCase().contains(lower));
        }
        return matches;
      },
      onSelected: (String selection) {
        controller.text = selection;
        setState(() {}); // live update
      },
      fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
        if (textController.text.isEmpty && controller.text.isNotEmpty) {
          textController.text = controller.text;
        }
        textController.addListener(() {
          if (controller.text != textController.text) {
             controller.text = textController.text;
          }
        });

        return TextField(
          controller: textController,
          focusNode: focusNode,
          maxLines: null,
          minLines: 1,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            filled: true,
            fillColor: Colors.grey.shade50,
            prefixIcon: Icon(icon, color: AppTheme.primaryColor),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4.0,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 300,
              height: 200,
              child: ListView.builder(
                padding: const EdgeInsets.all(8.0),
                itemCount: options.length,
                itemBuilder: (BuildContext context, int index) {
                  final String option = options.elementAt(index);
                  return ListTile(
                    title: Text(option),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputField({required TextEditingController controller, required String hint, required IconData icon}) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
        filled: true,
        fillColor: Colors.grey.shade50,
        prefixIcon: Icon(icon, color: AppTheme.primaryColor),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade200)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobile = constraints.maxWidth < 950;
        
        final formPanel = Container(
          width: isMobile ? double.infinity : 460,
          decoration: BoxDecoration(
            color: Colors.white, 
            boxShadow: isMobile ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 40, offset: const Offset(10, 0))]
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16), 
                decoration: BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: Colors.grey.shade100))),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: AppTheme.primaryColor, borderRadius: BorderRadius.circular(6)),
                            child: const Icon(Icons.description_rounded, color: Colors.white, size: 16)),
                          const SizedBox(width: 12),
                          Expanded(child: Text(widget.editingPost != null ? 'Edit Acknowledgement' : 'New Acknowledgement', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF1E293B)), overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                    if (!isMobile)
                      Row(
                        children: [
                          if (widget.editingPost != null) ...[
                            IconButton(
                              onPressed: () => _deletePost(context),
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              tooltip: 'Delete',
                            ),
                            const SizedBox(width: 8),
                          ],
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Colors.grey, fontSize: 13))),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: _save, 
                            icon: const Icon(Icons.save_rounded, size: 14), 
                            label: const Text('Save', style: TextStyle(fontSize: 13)), 
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8))
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              // Form content
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(isMobile ? 16 : 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: RadioListTile<String>(
                              title: const Text('Received', style: TextStyle(fontSize: 14)),
                              value: 'Received',
                              groupValue: _actionType,
                              activeColor: AppTheme.primaryColor,
                              contentPadding: EdgeInsets.zero,
                              onChanged: (val) {
                                setState(() {
                                  _actionType = val!;
                                  _updateControllersForAction(clearFiles: false);
                                });
                              },
                            ),
                          ),
                          Expanded(
                            child: RadioListTile<String>(
                              title: const Text('Returned', style: TextStyle(fontSize: 14)),
                              value: 'Returned',
                              groupValue: _actionType,
                              activeColor: AppTheme.primaryColor,
                              contentPadding: EdgeInsets.zero,
                              onChanged: (val) {
                                setState(() {
                                  _actionType = val!;
                                  _updateControllersForAction(clearFiles: false);
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text('TITLE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black54, letterSpacing: 1.0)),
                      const SizedBox(height: 8),
                      _buildInputField(controller: _titleController, hint: 'Optional title', icon: Icons.title_rounded),
                      const SizedBox(height: 16),
                      const Text('WORK / DEAL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black54, letterSpacing: 1.0)),
                      const SizedBox(height: 8),
                      _buildDealAutocomplete(),
                      const SizedBox(height: 16),
                      _buildFileChecklist(),
                      const SizedBox(height: 16),
                      const Text('FROM', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black54, letterSpacing: 1.0)),
                      const SizedBox(height: 8),
                      _buildUserAutocomplete(controller: _fromController, hint: 'Handed Over By', icon: Icons.person_outline),
                      const SizedBox(height: 16),
                      const Text('TO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black54, letterSpacing: 1.0)),
                      const SizedBox(height: 8),
                      _buildUserAutocomplete(controller: _toController, hint: 'Received By', icon: Icons.person_outline),
                      const SizedBox(height: 16),
                      const Text('AUTHORIZED SIGNATURE NAME (OPTIONAL)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black54, letterSpacing: 1.0)),
                      const SizedBox(height: 8),
                      _buildInputField(controller: _signatureController, hint: 'Default is From Name', icon: Icons.draw_outlined),
                      const SizedBox(height: 60),
                    ],
                  ),
                ),
              ),
              // Mobile footer
              if (isMobile)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Colors.grey.shade100))),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.save_rounded, size: 18),
                          label: const Text('Save'),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

        final previewPanel = Container(
          color: const Color(0xFFF1F5F9), 
          child: Center(
            child: PdfPreview(
              build: (format) => _generateLivePdf(format),
              canChangePageFormat: false, 
              canChangeOrientation: false, 
              canDebug: false, 
              actions: const [],
            ),
          ),
        );

        if (isMobile) {
          return DefaultTabController(
            length: 2,
            child: Scaffold(
              backgroundColor: const Color(0xFFF8FAFC),
              appBar: PremiumAppBar(
                title: Text(widget.editingPost != null ? 'Edit Acknowledgement' : 'New Acknowledgement', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                leading: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20)),
                actions: [
                  if (widget.editingPost != null)
                    IconButton(
                      onPressed: () => _deletePost(context),
                      icon: const Icon(Icons.delete_outline, color: Colors.white),
                    ),
                ],
                bottom: const TabBar(
                  tabs: [
                    Tab(text: 'DETAILS', icon: Icon(Icons.edit_note_rounded, size: 20)),
                    Tab(text: 'PREVIEW', icon: Icon(Icons.remove_red_eye_rounded, size: 20)),
                  ],
                  labelColor: AppTheme.primaryColor,
                  unselectedLabelColor: Colors.grey,
                  indicatorColor: AppTheme.primaryColor,
                  indicatorWeight: 3,
                  labelStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1),
                ),
              ),
              body: TabBarView(children: [formPanel, previewPanel]),
            ),
          );
        }

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          body: Row(children: [formPanel, Expanded(child: previewPanel)]),
        );
      },
    );
  }
}
