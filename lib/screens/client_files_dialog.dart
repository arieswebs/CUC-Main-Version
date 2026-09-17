import '../services/supabase_backup_service.dart';
import 'package:amplify_api/amplify_api.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:file_picker/file_picker.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_storage_s3/amplify_storage_s3.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../theme.dart';
import '../models/client.dart';
import '../services/logging_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cuc_app/services/backup_aware_api.dart';

// Isolate upload bytes was removed because Amplify Storage handles its own isolate/upload management.

class ClientFilesDialog extends StatefulWidget {
  final Client client;
  final bool isSelectionMode;

  const ClientFilesDialog({super.key, required this.client, this.isSelectionMode = false});

  @override
  State<ClientFilesDialog> createState() => _ClientFilesDialogState();
}

class _ClientFilesDialogState extends State<ClientFilesDialog> {
  bool _isLoading = true;
  List<StorageItem> _personalFiles = [];
  List<StorageItem> _workItems = [];
  List<String> _workFolders = [];
  List<StorageItem> _voiceFiles = [];
  String? _currentWorkFolder;
  String _currentTab = 'personal'; // 'personal', 'work', or 'voice'
  Map<String, amplify_models.ClientDocuments> _dbDocs = {};

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadFiles() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    try {
      try {
        final clientIdStr = widget.client.id.toString();
        List<amplify_models.ClientDocuments> filteredDocs = [];
        
        GraphQLRequest<PaginatedResult<amplify_models.ClientDocuments>> dbReq = ModelQueries.list(
          amplify_models.ClientDocuments.classType,
          limit: 1000,
          where: amplify_models.ClientDocuments.CLIENT_ID.eq(clientIdStr),
        );
        
        while (true) {
          final dbRes = await Amplify.API.query(request: dbReq).response;
          if (dbRes.data?.items != null) {
            filteredDocs.addAll(dbRes.data!.items.whereType<amplify_models.ClientDocuments>());
          }
          if (dbRes.data?.hasNextResult == true) {
            dbReq = dbRes.data!.requestForNextResult!;
          } else {
            break;
          }
        }
        
        _dbDocs = { for (var d in filteredDocs) if (d.storage_path != null) d.storage_path!: d };
      } catch (dbErr) {
        debugPrint('Error fetching ClientDocuments: $dbErr');
      }

      final pFilesRes = await Amplify.Storage.list(
        path: StoragePath.fromString('public/${widget.client.id}/personal/'),
        options: StorageListOptions(pluginOptions: S3ListPluginOptions.listAll()),
      ).result;
      
      final workPath = _currentWorkFolder == null 
          ? 'public/${widget.client.id}/work/' 
          : 'public/${widget.client.id}/work/$_currentWorkFolder/';
          
      final wFilesRes = await Amplify.Storage.list(
        path: StoragePath.fromString(workPath),
        options: StorageListOptions(pluginOptions: S3ListPluginOptions.listAll()),
      ).result;
      
      final vFilesRes = await Amplify.Storage.list(
        path: StoragePath.fromString('public/${widget.client.id}/voice/'),
        options: StorageListOptions(pluginOptions: S3ListPluginOptions.listAll()),
      ).result;
      
      if (!mounted) return;
      setState(() {
        _personalFiles = pFilesRes.items.where((f) => !f.path.contains('.emptyPlaceholder')).toList();
        _voiceFiles = vFilesRes.items.where((f) => !f.path.contains('.emptyPlaceholder')).toList();
        
        if (_currentWorkFolder == null) {
          Set<String> folderNames = {};
          final workPathStr = workPath.toString();
          
          for (var item in wFilesRes.items) {
            String itemPath;
            try {
              itemPath = Uri.decodeFull(item.path);
            } catch (_) {
              itemPath = item.path; 
            }
            
            if (!itemPath.startsWith(workPathStr)) continue;
            
            final relativePath = itemPath.substring(workPathStr.length);
            if (relativePath.isEmpty || relativePath == '.emptyPlaceholder') continue;
            
            final parts = relativePath.split('/');
            if (parts.isNotEmpty && parts[0].isNotEmpty && !parts[0].contains('.emptyPlaceholder')) {
               folderNames.add(parts[0]);
            }
          }
          _workFolders = folderNames.toList()..sort();
          _workItems = [];
        } else {
          _workFolders = [];
          _workItems = wFilesRes.items.where((f) => !f.path.contains('.emptyPlaceholder')).toList();
        }
      });
    } catch (e) {
      debugPrint("Load files error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error loading files: $e'), 
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _createFolder() async {
    final folder = await _showWorkPrefixDialog();
    if (folder == null || folder.isEmpty) return;
    
    setState(() => _isLoading = true);
    try {
      final path = 'public/${widget.client.id}/work/${folder.replaceAll('/', '_')}/.emptyPlaceholder';
      
      await Amplify.Storage.uploadData(
        data: StorageDataPayload.string('folder_placeholder'),
        path: StoragePath.fromString(path),
      ).result;
      
      await _logUpload('work', 'Folder Created: $folder');
      await _loadFiles();
    } catch (e) {
      debugPrint('Create folder error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to create folder: $e'), backgroundColor: Colors.redAccent));
      setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleVisibility(String path, String fileName, bool makeVisible) async {
    try {
      final existingDoc = _dbDocs[path];
      if (existingDoc != null) {
        String newRemarks = (existingDoc.remarks ?? '').replaceAll('[SHARED]', '').trim();
        if (makeVisible) newRemarks += '${newRemarks.isEmpty ? '' : ' '}[SHARED]';
        
        final updatedDoc = existingDoc.copyWith(remarks: newRemarks);
        
        setState(() {
          _dbDocs[path] = updatedDoc;
        });
        
        // Use raw GraphQL to bypass Hot-Reload static schema cache
        final req = GraphQLRequest<String>(
          document: '''
            mutation UpdateClientDocuments(\$input: UpdateClientDocumentsInput!) {
              updateClientDocuments(input: \$input) {
                id
                remarks
              }
            }
          ''',
          variables: {
            'input': {
              'id': updatedDoc.id,
              'remarks': newRemarks,
            }
          },
        );
        final res = await Amplify.API.mutate(request: req).response;
        if (res.hasErrors) throw Exception(res.errors.first.message);
        
        // Attempt to sync backup if needed, though BackupAwareApi usually handles this
        try {
          BackupAwareApi().update(updatedDoc); // Fire and forget, may fail locally but DB is already updated
        } catch (_) {}
      } else {
        // Create new record
        final newRemarks = makeVisible ? 'File OK [SHARED]' : 'File OK';
        final newId = UUID.getUUID();
        final newDoc = amplify_models.ClientDocuments(
          id: newId,
          client_id: widget.client.id.toString(),
          client_name: widget.client.name,
          document_name: fileName,
          storage_path: path,
          og_copy: 'Copy',
          remarks: newRemarks,
        );
        
        setState(() {
          _dbDocs[path] = newDoc;
        });
        
        // Use raw GraphQL
        final req = GraphQLRequest<String>(
          document: '''
            mutation CreateClientDocuments(\$input: CreateClientDocumentsInput!) {
              createClientDocuments(input: \$input) {
                id
              }
            }
          ''',
          variables: {
            'input': {
              'id': newId,
              'client_id': widget.client.id.toString(),
              'client_name': widget.client.name,
              'document_name': fileName,
              'storage_path': path,
              'og_copy': 'Copy',
              'remarks': newRemarks,
            }
          },
        );
        final res = await Amplify.API.mutate(request: req).response;
        if (res.hasErrors) throw Exception(res.errors.first.message);
        
        try {
          BackupAwareApi().create(newDoc); // Fire and forget
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update visibility: $e'), backgroundColor: Colors.redAccent));
      // On failure, reload to revert optimistic UI
      _loadFiles();
    }
  }

  Future<void> _uploadFile(String category) async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: category == 'voice' ? FileType.any : FileType.custom,
        allowedExtensions: category == 'voice' ? null : ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx', 'xls', 'xlsx', 'mp3', 'wav', 'm4a', 'aac', 'ogg'],
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final displayFileName = result.files.length == 1 ? result.files.first.name : '${result.files.length} files';
        
        // Show dialog to collect og_copy and remarks
        final details = await _showUploadDetailsDialog(displayFileName, isVoiceNote: category == 'voice');
        if (details == null) return; // User cancelled
        
        setState(() => _isLoading = true);
        
        for (var pickedFile in result.files) {
          if (pickedFile.path == null) continue;
          final filePath = pickedFile.path!;
          String fileName = pickedFile.name;
          
          if (details['name'] != null && details['name']!.trim().isNotEmpty) {
             final extension = fileName.contains('.') ? '.${fileName.split('.').last}' : '';
             final suffix = result.files.length > 1 ? ' (${result.files.indexOf(pickedFile) + 1})' : '';
             fileName = '${details['name']!.trim()}$suffix$extension';
          }
          
          String path;
          if (category == 'work') {
            if (_currentWorkFolder == null) {
              continue; 
            }
            path = 'public/${widget.client.id}/work/$_currentWorkFolder/$fileName';
          } else {
            path = 'public/${widget.client.id}/$category/$fileName';
          }
          
          // Read file bytes and upload
          final file = File(filePath);
          
          await Amplify.Storage.uploadFile(
            localFile: AWSFile.fromPath(file.path),
            path: StoragePath.fromString(path),
          ).result;
          try {
            final bytes = await File(file.path).readAsBytes();
            SupabaseBackupService().backupFileInBackground(path, bytes);
          } catch (_) {}
          
          // Record in client_documents table
          try {
            final newDoc = amplify_models.ClientDocuments(
              client_id: widget.client.id.toString(),
              client_name: widget.client.name,
              document_name: fileName,
              storage_path: path,
              og_copy: details['og_copy'],
              remarks: details['remarks'],
            );
            await BackupAwareApi().create(newDoc);
          } catch (dbError) {
            debugPrint('Failed to log document to DB: $dbError');
          }
          
          await _logUpload(category, fileName);
        }
        await _loadFiles();
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.redAccent));
      setState(() => _isLoading = false);
    }
  }

  Future<void> _logUpload(String category, String fileName) async {
    await LoggingService().logAction(
      action: 'FILE_UPLOADED',
      targetType: 'Client',
      targetId: widget.client.name,
      details: 'Uploaded $category file: $fileName',
    );
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File uploaded successfully!'), backgroundColor: Colors.green));
  }

  Future<String?> _showWorkPrefixDialog() async {
    String? prefix;
    await showDialog(
      context: context,
      builder: (context) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text("Create Work Folder"),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(
              hintText: "e.g. GST Return Q1",
              helperText: "A new folder will be created for this work",
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () {
                prefix = ctrl.text;
                Navigator.pop(context);
              },
              child: const Text("Create Folder"),
            ),
          ],
        );
      }
    );
    return prefix;
  }

  Future<Map<String, String>?> _showUploadDetailsDialog(String fileName, {bool isVoiceNote = false}) async {
    String selectedOgCopy = 'Copy';
    bool shareWithClient = false;
    final remarksController = TextEditingController();
    final nameController = TextEditingController();
    
    return await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('File Details'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('File: $fileName', style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  const Text('Custom File Name (Optional)', style: TextStyle(fontWeight: FontWeight.w500)),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      hintText: 'e.g. ${fileName.split('.').first}',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!isVoiceNote) ...[
                    const Text('Document Type', style: TextStyle(fontWeight: FontWeight.w500)),
                    DropdownButton<String>(
                      value: selectedOgCopy,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(value: 'Original', child: Text('Original')),
                        DropdownMenuItem(value: 'Copy', child: Text('Copy')),
                        DropdownMenuItem(value: 'NA', child: Text('NA')),
                      ],
                      onChanged: (val) {
                        if (val != null) setDialogState(() => selectedOgCopy = val);
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Text('Remarks', style: TextStyle(fontWeight: FontWeight.w500)),
                  TextField(
                    controller: remarksController,
                    decoration: const InputDecoration(
                      hintText: 'e.g. Needs verification, File OK',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: shareWithClient,
                        onChanged: (val) {
                          if (val != null) setDialogState(() => shareWithClient = val);
                        },
                      ),
                      const Expanded(child: Text('Visible to Client in Portal')),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor, foregroundColor: Colors.white),
                  onPressed: () {
                    String finalRemarks = remarksController.text.trim().isEmpty ? 'File OK' : remarksController.text.trim();
                    if (shareWithClient) {
                      finalRemarks += ' [SHARED]';
                    }
                    Navigator.pop(context, {
                      'og_copy': selectedOgCopy,
                      'remarks': finalRemarks,
                      'name': nameController.text,
                    });
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          }
        );
      }
    );
  }

  Future<void> _renameFile(String category, String oldFileName, String actualPath) async {
    final newNameCtrl = TextEditingController(text: oldFileName);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename File'),
        content: TextField(
          controller: newNameCtrl,
          decoration: const InputDecoration(hintText: 'New file name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
            onPressed: () => Navigator.pop(context, newNameCtrl.text.trim()), 
            child: const Text('Rename', style: TextStyle(color: Colors.white)),
          ),
        ],
      )
    );

    if (newName == null || newName.isEmpty || newName == oldFileName) return;

    setState(() => _isLoading = true);
    try {
      final newPath = actualPath.replaceFirst(oldFileName, newName);
      
      await Amplify.Storage.copy(
        source: StoragePath.fromString(actualPath),
        destination: StoragePath.fromString(newPath),
      ).result;
      
      await Amplify.Storage.remove(path: StoragePath.fromString(actualPath)).result;
      
      if (_dbDocs.containsKey(actualPath)) {
        final doc = _dbDocs[actualPath]!;
        final newDoc = amplify_models.ClientDocuments(
          id: doc.id,
          client_id: doc.client_id,
          client_name: doc.client_name,
          document_name: newName,
          storage_path: newPath,
          og_copy: doc.og_copy,
          remarks: doc.remarks,
        );
        await BackupAwareApi().update(newDoc);
      }
      
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File renamed successfully!'), backgroundColor: Colors.green));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rename failed: $e'), backgroundColor: Colors.redAccent));
    }
    
    await _loadFiles();
    setState(() => _isLoading = false);
  }

  Future<void> _deleteFile(String category, String fileName, {bool isFolder = false}) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isFolder ? 'Delete Folder' : 'Delete File'),
        content: Text('Are you sure you want to delete "$fileName"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true), 
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      )
    );

    if (confirm == true) {
      setState(() => _isLoading = true);
      try {
        if (isFolder) {
          final folderPath = 'public/${widget.client.id}/work/$fileName/';
          final filesRes = await Amplify.Storage.list(path: StoragePath.fromString(folderPath)).result;
          for (var f in filesRes.items) {
            String pathToRemove = f.path;
            if (!pathToRemove.startsWith('public/')) {
              if (pathToRemove.contains('${widget.client.id}/work/')) {
                pathToRemove = 'public/$pathToRemove';
              } else {
                pathToRemove = folderPath + pathToRemove.replaceFirst(RegExp(r'^/'), '');
              }
            }
            await Amplify.Storage.remove(path: StoragePath.fromString(pathToRemove)).result;
          }
        } else {
          String pathToDelete = category == 'work' && _currentWorkFolder != null 
              ? 'public/${widget.client.id}/work/$_currentWorkFolder/$fileName'
              : 'public/${widget.client.id}/$category/$fileName';
          await Amplify.Storage.remove(path: StoragePath.fromString(pathToDelete)).result;
        }
        await _loadFiles();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.redAccent));
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _downloadFile(String category, String fileName) async {
    try {
      String pathToDownload = category == 'work' && _currentWorkFolder != null 
          ? 'public/${widget.client.id}/work/$_currentWorkFolder/$fileName'
          : 'public/${widget.client.id}/$category/$fileName';
      final res = await Amplify.Storage.getUrl(path: StoragePath.fromString(pathToDownload)).result;
      if (await canLaunchUrl(res.url)) {
        await launchUrl(res.url);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open file: $e'), backgroundColor: Colors.redAccent));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 600;
          
          Widget sidebar = Container(
            width: isWide ? 260 : double.infinity,
            color: const Color(0xFFF8FAFC),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.all(isWide ? 24 : 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.folder_special, color: AppTheme.primaryColor, size: 24),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(child: Text('Files Vault', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                          if (!isWide)
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.black54),
                              onPressed: () => Navigator.pop(context),
                              style: IconButton.styleFrom(backgroundColor: Colors.grey.shade100),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(widget.client.name, style: TextStyle(color: Colors.grey.shade600, fontSize: 13, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (isWide) const SizedBox(height: 16),
                if (isWide) ...[
                  _buildNavItem('Personal Details', Icons.person_outline, 'personal', isMobile: false),
                  _buildNavItem('Work Folders', Icons.work_outline, 'work', isMobile: false),
                  _buildNavItem('Voice Notes', Icons.mic_none_outlined, 'voice', isMobile: false),
                ] else
                  Row(
                    children: [
                      Expanded(child: _buildNavItem('Personal', Icons.person_outline, 'personal', isMobile: true)),
                      Expanded(child: _buildNavItem('Work', Icons.work_outline, 'work', isMobile: true)),
                      Expanded(child: _buildNavItem('Voice', Icons.mic_none_outlined, 'voice', isMobile: true)),
                    ],
                  ),
              ],
            ),
          );

          Widget mainContent = Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Bar
                Container(
                  padding: EdgeInsets.symmetric(horizontal: isWide ? 32 : 16, vertical: isWide ? 0 : 16),
                  height: isWide ? 80 : null,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
                  ),
                  child: Row(
                    children: [
                      if (_currentTab == 'work' && _currentWorkFolder != null) ...[
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.black87),
                          onPressed: () {
                            setState(() => _currentWorkFolder = null);
                            _loadFiles();
                          },
                          style: IconButton.styleFrom(backgroundColor: Colors.grey.shade100),
                        ),
                        const SizedBox(width: 16),
                      ],
                      Expanded(
                        child: Text(
                          _currentTab == 'personal' ? 'Personal Files' 
                          : _currentTab == 'voice' ? 'Voice Notes'
                          : _currentWorkFolder == null ? 'Work Folders' 
                          : _currentWorkFolder!,
                          style: TextStyle(fontSize: isWide ? 22 : 18, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () {
                          if (_currentTab == 'work' && _currentWorkFolder == null) {
                            _createFolder();
                          } else {
                            _uploadFile(_currentTab);
                          }
                        },
                        icon: Icon(_currentTab == 'work' && _currentWorkFolder == null ? Icons.create_new_folder : Icons.cloud_upload_outlined, size: 18),
                        label: Text(isWide ? (_currentTab == 'work' && _currentWorkFolder == null ? 'New Folder' : 'Upload File') : (_currentTab == 'work' && _currentWorkFolder == null ? 'Folder' : 'Upload')),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: EdgeInsets.symmetric(horizontal: isWide ? 24 : 12, vertical: isWide ? 16 : 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                      if (isWide) ...[
                        const SizedBox(width: 16),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.black54),
                          onPressed: () => Navigator.pop(context),
                          style: IconButton.styleFrom(backgroundColor: Colors.grey.shade100),
                        ),
                      ],
                    ],
                  ),
                ),
                // Content Grid/List
                Expanded(
                  child: Container(
                    color: Colors.white,
                    child: _isLoading 
                      ? const Center(child: CircularProgressIndicator())
                      : _currentTab == 'personal' 
                          ? _buildFileList(_personalFiles, 'personal', isWide) 
                          : _currentTab == 'voice'
                              ? _buildFileList(_voiceFiles, 'voice', isWide)
                              : _buildFileList(_workItems, 'work', isWide),
                  ),
                ),
              ],
            ),
          );

          return Container(
            constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 750),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 32, offset: Offset(0, 16))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: isWide 
                ? Row(
                    children: [
                      sidebar,
                      Container(width: 1, color: Colors.grey.shade200),
                      mainContent,
                    ],
                  )
                : Column(
                    children: [
                      sidebar,
                      Container(height: 1, color: Colors.grey.shade200),
                      mainContent,
                    ],
                  ),
            ),
          );
        }
      ).animate().fadeIn(duration: 300.ms).scaleXY(begin: 0.98, end: 1.0, curve: Curves.easeOutQuart),
    );
  }

  Widget _buildNavItem(String title, IconData icon, String tab, {bool isMobile = false}) {
    final isSelected = _currentTab == tab;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 16, vertical: isMobile ? 8 : 4),
      child: InkWell(
        onTap: () {
          setState(() {
            _currentTab = tab;
            _currentWorkFolder = null;
          });
          _loadFiles();
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 16, vertical: isMobile ? 10 : 14),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primaryColor.withValues(alpha: 0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: isMobile ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Icon(icon, color: isSelected ? AppTheme.primaryColor : Colors.grey.shade600, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title, 
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? AppTheme.primaryColor : Colors.grey.shade700, 
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileList(List<StorageItem> files, String category, bool isWide) {
    final isWorkFoldersView = category == 'work' && _currentWorkFolder == null;

    if (isWorkFoldersView && _workFolders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: Colors.grey.shade50, shape: BoxShape.circle),
              child: Icon(Icons.snippet_folder_outlined, size: 64, color: Colors.grey.shade300),
            ),
            const SizedBox(height: 24),
            Text(
              "No work folders created yet.", 
              style: TextStyle(color: Colors.grey.shade500, fontSize: 16, fontWeight: FontWeight.w500)
            ),
            const SizedBox(height: 8),
            Text(
              "Click the button above to add one.", 
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13)
            ),
          ],
        ).animate().fadeIn().slideY(begin: 0.1),
      );
    } else if (!isWorkFoldersView && files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: Colors.grey.shade50, shape: BoxShape.circle),
              child: Icon(Icons.snippet_folder_outlined, size: 64, color: Colors.grey.shade300),
            ),
            const SizedBox(height: 24),
            Text(
              "No files uploaded here yet.", 
              style: TextStyle(color: Colors.grey.shade500, fontSize: 16, fontWeight: FontWeight.w500)
            ),
            const SizedBox(height: 8),
            Text(
              "Click the button above to add one.", 
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13)
            ),
          ],
        ).animate().fadeIn().slideY(begin: 0.1),
      );
    }

    int itemCount = isWorkFoldersView ? _workFolders.length : files.length;

    return ListView.builder(
      padding: EdgeInsets.all(isWide ? 32 : 16),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (isWorkFoldersView) {
          final folderName = _workFolders[index];
          return Card(
            elevation: 0,
            color: Colors.amber.shade50,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.amber.shade200)),
            margin: const EdgeInsets.only(bottom: 12),
            child: InkWell(
              onTap: () {
                setState(() => _currentWorkFolder = folderName);
                _loadFiles();
              },
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.amber.shade100, borderRadius: BorderRadius.circular(10)),
                    child: Icon(Icons.folder, color: Colors.amber.shade800),
                  ),
                  title: Text(folderName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                        onPressed: () => _deleteFile('work', folderName, isFolder: true),
                        tooltip: "Delete Folder",
                        style: IconButton.styleFrom(backgroundColor: Colors.red.shade50),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.chevron_right, color: Colors.amber.shade700),
                    ],
                  ),
                ),
              ),
            ),
          ).animate().fadeIn(delay: (30 * index).ms).slideY(begin: 0.1);
        }

        // File Item
        final f = files[index];
        String decodedPath;
        try {
          decodedPath = Uri.decodeFull(f.path);
        } catch (_) {
          decodedPath = f.path;
        }
        final itemName = decodedPath.split('/').last;
        
        final basePath = 'public/${widget.client.id}/$category/$itemName';
        final actualPath = category == 'work' && _currentWorkFolder != null
            ? 'public/${widget.client.id}/work/$_currentWorkFolder/$itemName'
            : basePath;
            
        final isShared = _dbDocs[actualPath]?.remarks?.contains('[SHARED]') ?? false;

        IconData icon = Icons.insert_drive_file;
        Color iconColor = Colors.blueGrey;
        if (itemName.toLowerCase().endsWith('.pdf')) {
          icon = Icons.picture_as_pdf;
          iconColor = Colors.redAccent;
        } else if (itemName.toLowerCase().endsWith('.jpg') || itemName.toLowerCase().endsWith('.png') || itemName.toLowerCase().endsWith('.jpeg')) {
          icon = Icons.image;
          iconColor = Colors.purpleAccent;
        } else if (itemName.toLowerCase().endsWith('.mp3') || itemName.toLowerCase().endsWith('.wav') || itemName.toLowerCase().endsWith('.m4a') || itemName.toLowerCase().endsWith('.aac') || itemName.toLowerCase().endsWith('.ogg')) {
          icon = Icons.audiotrack;
          iconColor = Colors.orangeAccent;
        }

        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              onTap: widget.isSelectionMode 
                ? () {
                    Navigator.pop(context, actualPath);
                  }
                : null,
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, color: iconColor),
              ),
              title: Text(itemName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${(f.size ?? 0) ~/ 1024} KB', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              trailing: widget.isSelectionMode
                ? ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context, actualPath);
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: 'Visible to Client in Portal',
                        child: Switch(
                          value: isShared,
                          onChanged: (val) => _toggleVisibility(actualPath, itemName, val),
                          activeThumbColor: AppTheme.primaryColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.download_rounded, color: Colors.blueGrey, size: 20),
                        onPressed: () => _downloadFile(category, itemName),
                        tooltip: "Download File",
                        style: IconButton.styleFrom(backgroundColor: Colors.grey.shade100),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, color: Colors.blue, size: 20),
                        onPressed: () => _renameFile(category, itemName, actualPath),
                        tooltip: "Rename File",
                        style: IconButton.styleFrom(backgroundColor: Colors.blue.shade50),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                        onPressed: () => _deleteFile(category, itemName),
                        tooltip: "Delete File",
                        style: IconButton.styleFrom(backgroundColor: Colors.red.shade50),
                      ),
                    ],
                  ),
            ),
          ),
        ).animate().fadeIn(delay: (30 * index).ms).slideY(begin: 0.1);
      },
    );
  }
}
