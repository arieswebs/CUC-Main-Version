import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:file_picker/file_picker.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../theme.dart';
import '../models/deal.dart';
import '../services/deal_service.dart';
import '../services/client_service.dart';
import '../services/google_docs_service.dart';
import 'google_docs_webview_screen.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
import '../services/logging_service.dart';


class DocumentListScreen extends StatefulWidget {
  final String userEmail;
  const DocumentListScreen({super.key, required this.userEmail});

  @override
  State<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends State<DocumentListScreen> {
  List<drive.File> _documents = [];
  String _searchQuery = '';
  bool _isLoading = false;
  String? _currentUser;
  Map<String, String> _docLinkToDealName = {};
  Map<String, String> _docLinkToClientName = {};

  @override
  void initState() {
    super.initState();
    _checkSignInStatus();
  }

  Future<void> _checkSignInStatus() async {
    setState(() => _isLoading = true);
    final account = await GoogleDocsService.signIn();
    if (account != null) {
      _currentUser = account;
      await _loadDocuments();
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signIn() async {
    setState(() => _isLoading = true);
    final account = await GoogleDocsService.signIn();
    if (account != null) {
      _currentUser = account;
      await _loadDocuments();
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signOut() async {
    await GoogleDocsService.signOut();
    setState(() {
      _currentUser = null;
      _documents = [];
    });
  }

  Future<void> _loadDocuments() async {
    setState(() => _isLoading = true);
    final docs = await GoogleDocsService.getDriveFiles();
    
    try {
      final dealsReq = ModelQueries.list(amplify_models.Deals.classType, limit: 10000);
      final dealsRes = await Amplify.API.query(request: dealsReq).response;
      
      final clientsReq = ModelQueries.list(amplify_models.ClientDocuments.classType, limit: 10000);
      final clientsRes = await Amplify.API.query(request: clientsReq).response;

      final newDealMappings = <String, String>{};
      for (var deal in dealsRes.data?.items ?? []) {
        if (deal != null && deal.drive_link != null && deal.drive_link!.isNotEmpty) {
          final isCrm = (deal.pipeline ?? '').toLowerCase() == 'crm' || (deal.pipeline ?? '').toLowerCase() == 'lead';
          if (isCrm && deal.is_won != true) continue;
          newDealMappings[deal.drive_link!] = deal.name;
        }
      }

      final newClientMappings = <String, String>{};
      for (var clientDoc in clientsRes.data?.items ?? []) {
        if (clientDoc != null && clientDoc.storage_path != null && clientDoc.storage_path!.isNotEmpty) {
          newClientMappings[clientDoc.storage_path!] = clientDoc.client_name ?? 'Unknown Client';
        }
      }

      if (mounted) {
        setState(() {
          _docLinkToDealName = newDealMappings;
          _docLinkToClientName = newClientMappings;
        });
      }
    } catch (e) {
      debugPrint('Error loading document mappings: $e');
    }

    if (mounted) {
      setState(() {
        _documents = docs;
        _isLoading = false;
      });
    }
  }

  Future<void> _createNewDocument() async {
    final TextEditingController nameController = TextEditingController(text: 'New Legal Document');
    
    setState(() => _isLoading = true);
    List<Map<String, dynamic>> clients = [];
    List<Deal> deals = [];
    try {
      clients = await ClientService().getAllClients();
      final allDeals = await DealService().getAllDeals();
      deals = allDeals.where((d) {
        final isCrm = d.pipeline.toLowerCase() == 'crm' || d.pipeline.toLowerCase() == 'lead';
        if (isCrm && !d.isWon) return false;
        return true;
      }).toList();
    } catch (e) {
      debugPrint('Error loading clients/deals: $e');
    }
    setState(() => _isLoading = false);

    if (!mounted) return;

    Map<String, dynamic>? selectedClient;
    Deal? selectedDeal;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: Colors.transparent,
              child: Container(
                width: 500,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceColor,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 20)],
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.description_rounded, color: AppTheme.primaryColor),
                          ),
                          const SizedBox(width: 16),
                          const Text('Create Google Doc', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textColor)),
                        ],
                      ),
                      const SizedBox(height: 32),
                      TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          labelText: 'Document Name',
                          labelStyle: const TextStyle(color: AppTheme.mutedTextColor),
                          filled: true,
                          fillColor: AppTheme.primaryColor.withValues(alpha: 0.03),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                        ),
                      ),
                      const SizedBox(height: 20),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          return Autocomplete<Map<String, dynamic>>(
                            optionsBuilder: (TextEditingValue textEditingValue) {
                              if (textEditingValue.text.isEmpty) {
                                return const Iterable<Map<String, dynamic>>.empty();
                              }
                              return clients.where((c) {
                                final name = c['name']?.toString().toLowerCase() ?? '';
                                return name.contains(textEditingValue.text.toLowerCase());
                              });
                            },
                            displayStringForOption: (option) => option['name']?.toString() ?? 'Unknown',
                            onSelected: (selection) => setDialogState(() => selectedClient = selection),
                            fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                              return TextField(
                                controller: textEditingController,
                                focusNode: focusNode,
                                decoration: InputDecoration(
                                  labelText: 'Connect Client (Optional)',
                                  hintText: 'Type to search...',
                                  labelStyle: const TextStyle(color: AppTheme.mutedTextColor),
                                  filled: true,
                                  fillColor: AppTheme.primaryColor.withValues(alpha: 0.03),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                                  suffixIcon: IconButton(
                                    icon: const Icon(Icons.clear, size: 20),
                                    onPressed: () {
                                      textEditingController.clear();
                                      setDialogState(() => selectedClient = null);
                                    },
                                  ),
                                ),
                              );
                            },
                            optionsViewBuilder: (context, onSelected, options) {
                              return Align(
                                alignment: Alignment.topLeft,
                                child: Material(
                                  elevation: 4,
                                  borderRadius: BorderRadius.circular(12),
                                  color: AppTheme.surfaceColor,
                                  child: Container(
                                    width: constraints.maxWidth,
                                    constraints: const BoxConstraints(maxHeight: 200),
                                    child: ListView.builder(
                                      padding: EdgeInsets.zero,
                                      shrinkWrap: true,
                                      itemCount: options.length,
                                      itemBuilder: (context, index) {
                                        final option = options.elementAt(index);
                                        return ListTile(
                                          title: Text(option['name']?.toString() ?? 'Unknown', style: const TextStyle(color: AppTheme.textColor)),
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
                      ),
                      const SizedBox(height: 20),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          return Autocomplete<Deal>(
                            optionsBuilder: (TextEditingValue textEditingValue) {
                              if (textEditingValue.text.isEmpty) {
                                return const Iterable<Deal>.empty();
                              }
                              return deals.where((d) {
                                return d.name.toLowerCase().contains(textEditingValue.text.toLowerCase());
                              });
                            },
                            displayStringForOption: (option) => option.name,
                            onSelected: (selection) => setDialogState(() => selectedDeal = selection),
                            fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                              return TextField(
                                controller: textEditingController,
                                focusNode: focusNode,
                                decoration: InputDecoration(
                                  labelText: 'Connect Work/Deal (Optional)',
                                  hintText: 'Type to search...',
                                  labelStyle: const TextStyle(color: AppTheme.mutedTextColor),
                                  filled: true,
                                  fillColor: AppTheme.primaryColor.withValues(alpha: 0.03),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                                  suffixIcon: IconButton(
                                    icon: const Icon(Icons.clear, size: 20),
                                    onPressed: () {
                                      textEditingController.clear();
                                      setDialogState(() => selectedDeal = null);
                                    },
                                  ),
                                ),
                              );
                            },
                            optionsViewBuilder: (context, onSelected, options) {
                              return Align(
                                alignment: Alignment.topLeft,
                                child: Material(
                                  elevation: 4,
                                  borderRadius: BorderRadius.circular(12),
                                  color: AppTheme.surfaceColor,
                                  child: Container(
                                    width: constraints.maxWidth,
                                    constraints: const BoxConstraints(maxHeight: 200),
                                    child: ListView.builder(
                                      padding: EdgeInsets.zero,
                                      shrinkWrap: true,
                                      itemCount: options.length,
                                      itemBuilder: (context, index) {
                                        final option = options.elementAt(index);
                                        return ListTile(
                                          title: Text(option.name, style: const TextStyle(color: AppTheme.textColor)),
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
                      ),
                      const SizedBox(height: 32),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
                            child: const Text('CANCEL', style: TextStyle(color: AppTheme.mutedTextColor, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryColor,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              elevation: 0,
                            ),
                            child: const Text('CREATE DOC', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
        );
      }
    );

    if (result == true && nameController.text.isNotEmpty) {
      setState(() => _isLoading = true);
      final url = await GoogleDocsService.createNewDocument(nameController.text);
      if (mounted) setState(() => _isLoading = false);

      if (url != null) {
        await _linkDocument(url, nameController.text, selectedClient, selectedDeal);
        _openUrl(url, nameController.text);
        _loadDocuments();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to create document.', style: TextStyle(fontFamily: 'Montserrat'))),
          );
        }
      }
    }
  }

  Future<void> _linkDocument(String url, String docName, Map<String, dynamic>? selectedClient, Deal? selectedDeal) async {
    // Link to Work/Deal if selected
    if (selectedDeal != null) {
      try {
        final req = ModelQueries.list(amplify_models.Deals.classType, where: amplify_models.Deals.ID.eq(selectedDeal.id.toString()), limit: 10000);
        final res = await Amplify.API.query(request: req).response;
        final dealObj = res.data?.items.isNotEmpty == true ? res.data?.items.first : null;
        if (dealObj != null) {
          final updatedDeal = dealObj.copyWith(drive_link: url);
          await BackupAwareApi().update(updatedDeal);
        }
      } catch (e) {
        debugPrint('Failed to update deal: $e');
      }
    }
    
    // Link to Client if selected
    if (selectedClient != null) {
      try {
        final newClientDoc = amplify_models.ClientDocuments(
          client_id: selectedClient['id'].toString(),
          client_name: selectedClient['name'],
          document_name: docName,
          storage_path: url,
          og_copy: 'Original',
          remarks: 'Google Doc',
        );
        await BackupAwareApi().create(newClientDoc);

        await LoggingService().logAction(
          action: 'FILE_UPLOADED',
          targetType: 'Client',
          targetId: selectedClient['name'],
          details: 'Uploaded document: $docName',
        );
      } catch (e) {
        debugPrint('Failed to update client docs: $e');
      }
    }
  }

  Future<void> _uploadDocument() async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['doc', 'docx', 'txt', 'rtf'],
        withData: true,
      );

      if (result != null && result.files.single.bytes != null) {
        final fileBytes = result.files.single.bytes!;
        final fileName = result.files.single.name;
        
        setState(() => _isLoading = true);
        List<Map<String, dynamic>> clients = [];
        List<Deal> deals = [];
        try {
          clients = await ClientService().getAllClients();
          final allDeals = await DealService().getAllDeals();
      deals = allDeals.where((d) {
        final isCrm = d.pipeline.toLowerCase() == 'crm' || d.pipeline.toLowerCase() == 'lead';
        if (isCrm && !d.isWon) return false;
        return true;
      }).toList();
        } catch (e) {}
        setState(() => _isLoading = false);

        if (!mounted) return;

        Map<String, dynamic>? selectedClient;
        Deal? selectedDeal;

        final dialogResult = await showDialog<bool>(
          context: context,
          builder: (context) {
            return StatefulBuilder(
              builder: (context, setDialogState) {
                return Dialog(
                  backgroundColor: Colors.transparent,
                  child: Container(
                    width: 500,
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 20)],
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.upload_file_rounded, color: AppTheme.primaryColor),
                              ),
                              const SizedBox(width: 16),
                              const Expanded(child: Text('Upload & Convert', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textColor))),
                            ],
                          ),
                          const SizedBox(height: 32),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.2)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.file_present_rounded, color: AppTheme.primaryColor),
                                const SizedBox(width: 12),
                                Expanded(child: Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textColor))),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              return Autocomplete<Map<String, dynamic>>(
                                optionsBuilder: (TextEditingValue textEditingValue) {
                                  if (textEditingValue.text.isEmpty) {
                                    return const Iterable<Map<String, dynamic>>.empty();
                                  }
                                  return clients.where((c) {
                                    final name = c['name']?.toString().toLowerCase() ?? '';
                                    return name.contains(textEditingValue.text.toLowerCase());
                                  });
                                },
                                displayStringForOption: (option) => option['name']?.toString() ?? 'Unknown',
                                onSelected: (selection) => setDialogState(() => selectedClient = selection),
                                fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                                  return TextField(
                                    controller: textEditingController,
                                    focusNode: focusNode,
                                    decoration: InputDecoration(
                                      labelText: 'Connect Client (Optional)',
                                      hintText: 'Type to search...',
                                      labelStyle: const TextStyle(color: AppTheme.mutedTextColor),
                                      filled: true,
                                      fillColor: AppTheme.primaryColor.withValues(alpha: 0.03),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                                      suffixIcon: IconButton(
                                        icon: const Icon(Icons.clear, size: 20),
                                        onPressed: () {
                                          textEditingController.clear();
                                          setDialogState(() => selectedClient = null);
                                        },
                                      ),
                                    ),
                                  );
                                },
                                optionsViewBuilder: (context, onSelected, options) {
                                  return Align(
                                    alignment: Alignment.topLeft,
                                    child: Material(
                                      elevation: 4,
                                      borderRadius: BorderRadius.circular(12),
                                      color: AppTheme.surfaceColor,
                                      child: Container(
                                        width: constraints.maxWidth,
                                        constraints: const BoxConstraints(maxHeight: 200),
                                        child: ListView.builder(
                                          padding: EdgeInsets.zero,
                                          shrinkWrap: true,
                                          itemCount: options.length,
                                          itemBuilder: (context, index) {
                                            final option = options.elementAt(index);
                                            return ListTile(
                                              title: Text(option['name']?.toString() ?? 'Unknown', style: const TextStyle(color: AppTheme.textColor)),
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
                          ),
                          const SizedBox(height: 20),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              return Autocomplete<Deal>(
                                optionsBuilder: (TextEditingValue textEditingValue) {
                                  if (textEditingValue.text.isEmpty) {
                                    return const Iterable<Deal>.empty();
                                  }
                                  return deals.where((d) {
                                    return d.name.toLowerCase().contains(textEditingValue.text.toLowerCase());
                                  });
                                },
                                displayStringForOption: (option) => option.name,
                                onSelected: (selection) => setDialogState(() => selectedDeal = selection),
                                fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                                  return TextField(
                                    controller: textEditingController,
                                    focusNode: focusNode,
                                    decoration: InputDecoration(
                                      labelText: 'Connect Work/Deal (Optional)',
                                      hintText: 'Type to search...',
                                      labelStyle: const TextStyle(color: AppTheme.mutedTextColor),
                                      filled: true,
                                      fillColor: AppTheme.primaryColor.withValues(alpha: 0.03),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor)),
                                      suffixIcon: IconButton(
                                        icon: const Icon(Icons.clear, size: 20),
                                        onPressed: () {
                                          textEditingController.clear();
                                          setDialogState(() => selectedDeal = null);
                                        },
                                      ),
                                    ),
                                  );
                                },
                                optionsViewBuilder: (context, onSelected, options) {
                                  return Align(
                                    alignment: Alignment.topLeft,
                                    child: Material(
                                      elevation: 4,
                                      borderRadius: BorderRadius.circular(12),
                                      color: AppTheme.surfaceColor,
                                      child: Container(
                                        width: constraints.maxWidth,
                                        constraints: const BoxConstraints(maxHeight: 200),
                                        child: ListView.builder(
                                          padding: EdgeInsets.zero,
                                          shrinkWrap: true,
                                          itemCount: options.length,
                                          itemBuilder: (context, index) {
                                            final option = options.elementAt(index);
                                            return ListTile(
                                              title: Text(option.name, style: const TextStyle(color: AppTheme.textColor)),
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
                          ),
                          const SizedBox(height: 32),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
                                child: const Text('CANCEL', style: TextStyle(color: AppTheme.mutedTextColor, fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(context, true),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primaryColor,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  elevation: 0,
                                ),
                                child: const Text('UPLOAD', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
            );
          }
        );

        if (dialogResult == true) {
          setState(() => _isLoading = true);
          final url = await GoogleDocsService.uploadDocument(fileBytes, fileName);
          
          if (mounted) {
            setState(() => _isLoading = false);
            if (url != null) {
              await _linkDocument(url, fileName, selectedClient, selectedDeal);
              _openUrl(url, fileName);
              _loadDocuments();
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Failed to upload document.', style: TextStyle(fontFamily: 'Montserrat'))),
              );
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking file: $e')),
        );
      }
    }
  }

  Future<void> _openUrl(String? urlString, String title) async {
    if (urlString != null) {
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GoogleDocsWebviewScreen(
              url: urlString,
              title: title,
            ),
          ),
        ).then((_) => _loadDocuments());
      }
    } else {
      debugPrint('Could not launch document');
    }
  }

  Future<void> _confirmDelete(drive.File doc) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceColor,
        title: const Text('Delete Document', style: TextStyle(color: AppTheme.textColor, fontFamily: 'Montserrat', fontWeight: FontWeight.bold)),
        content: Text('Are you sure you want to delete "${doc.name}"? This action cannot be undone and will permanently delete the file from your Google Drive.', style: const TextStyle(color: AppTheme.mutedTextColor, fontFamily: 'Montserrat')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL', style: TextStyle(color: AppTheme.mutedTextColor, fontFamily: 'Montserrat')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('DELETE', style: TextStyle(color: Colors.red, fontFamily: 'Montserrat', fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true && doc.id != null) {
      setState(() => _isLoading = true);
      final success = await GoogleDocsService.deleteDocument(doc.id!);
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Document deleted successfully', style: TextStyle(fontFamily: 'Montserrat', color: Colors.white)),
              backgroundColor: Colors.green,
            ),
          );
          _loadDocuments();
        } else {
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to delete document', style: TextStyle(fontFamily: 'Montserrat', color: Colors.white)),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surfaceColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: AppTheme.surfaceColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Image.asset('assets/logo.png', width: 28, height: 28),
            const SizedBox(width: 10),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Google Docs Vault',
                  style: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.bold, color: AppTheme.textColor),
                ),
                Text(
                  _currentUser != null ? _currentUser! : 'Not Signed In',
                  style: const TextStyle(fontFamily: 'Montserrat', fontSize: 11, color: AppTheme.mutedTextColor),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (_currentUser != null) ...[
            IconButton(
              icon: const Icon(Icons.upload_file_rounded, color: AppTheme.primaryColor),
              tooltip: 'Upload Document',
              onPressed: _uploadDocument,
            ),
            IconButton(
              icon: const Icon(Icons.logout, color: Colors.red),
              tooltip: 'Sign Out',
              onPressed: _signOut,
            ),
          ],
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, AppTheme.primaryColor.withValues(alpha: 0.3), Colors.transparent],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: _currentUser != null
          ? FloatingActionButton.extended(
              onPressed: _createNewDocument,
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('NEW GOOGLE DOC', style: TextStyle(fontFamily: 'Montserrat', fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
            )
          : null,
      body: _currentUser == null
          ? _buildSignInState()
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.12)),
                    ),
                    child: TextField(
                      style: const TextStyle(fontFamily: 'Montserrat', color: AppTheme.textColor, fontSize: 13),
                      onChanged: (val) => setState(() => _searchQuery = val),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded, size: 20, color: AppTheme.mutedTextColor),
                        hintText: 'Search documents...',
                        hintStyle: TextStyle(fontFamily: 'Montserrat', color: AppTheme.mutedTextColor.withValues(alpha: 0.4), fontSize: 12),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor))
                      : _buildLogsList(),
                ),
              ],
            ),
    );
  }

  Widget _buildSignInState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_sync, size: 64, color: AppTheme.primaryColor),
          const SizedBox(height: 16),
          const Text('Connect to Google Docs', style: TextStyle(fontFamily: 'Montserrat', fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textColor)),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Sign in with your Google account to view and manage your legal documents directly via Google Drive.',
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Montserrat', fontSize: 14, color: AppTheme.mutedTextColor),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            icon: const Icon(Icons.login),
            label: const Text('Sign in with Google', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: _signIn,
          ),
        ],
      ),
    );
  }

  Widget _buildLogsList() {
    final filtered = _documents.where((d) => (d.name ?? '').toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    if (filtered.isEmpty) {
      return const Center(
        child: Text('No documents found in Google Drive.', style: TextStyle(color: AppTheme.mutedTextColor)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final doc = filtered[index];
        final String docUrl = doc.webViewLink ?? '';
        final String? clientName = _docLinkToClientName[docUrl];
        final String? dealName = _docLinkToDealName[docUrl];

        final List<String> connections = [];
        if (clientName != null) connections.add('Client: $clientName');
        if (dealName != null) connections.add('Work: $dealName');

        final String modifiedDate = doc.modifiedTime?.toLocal().toString().split('.')[0] ?? '';

        return Card(
          color: Colors.grey[100],
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: const Icon(Icons.description, color: Colors.blueAccent),
            title: Text(doc.name ?? 'Untitled', style: const TextStyle(color: AppTheme.textColor, fontWeight: FontWeight.bold)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Modified: $modifiedDate', style: const TextStyle(color: AppTheme.mutedTextColor, fontSize: 12)),
                if (connections.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(connections.join('  •  '), style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.w600, fontSize: 12)),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, color: Colors.red, size: 20),
                  onPressed: () => _confirmDelete(doc),
                  tooltip: 'Delete Document',
                ),
                const Icon(Icons.open_in_new, color: AppTheme.primaryColor, size: 18),
              ],
            ),
            onTap: () => _openUrl(doc.webViewLink, doc.name ?? 'Google Doc'),
          ),
        ).animate().fadeIn(delay: Duration(milliseconds: 50 * index)).slideX();
      },
    );
  }
}

