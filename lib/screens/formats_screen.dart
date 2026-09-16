import 'package:flutter/material.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_storage_s3/amplify_storage_s3.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme.dart';
import 'dart:io';
import 'dart:typed_data';
import '../services/supabase_backup_service.dart';
import 'package:file_selector/file_selector.dart' as file_selector;

class FormatsScreen extends StatefulWidget {
  const FormatsScreen({super.key});

  @override
  State<FormatsScreen> createState() => _FormatsScreenState();
}

class _FormatsScreenState extends State<FormatsScreen> {
  bool _isLoading = true;
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String _uploadStatus = '';
  List<String> _currentPath = [];
  List<String> _currentFolders = [];
  List<StorageItem> _currentFiles = [];

  @override
  void initState() {
    super.initState();
    _fetchFormats();
  }

  Future<void> _fetchFormats() async {
    setState(() => _isLoading = true);
    try {
      final result = await Amplify.Storage.list(
        path: const StoragePath.fromString('public/formats/'),
      ).result;
      
      final items = result.items.toList();
      items.sort((a, b) {
        final aDate = a.lastModified ?? DateTime(2000);
        final bDate = b.lastModified ?? DateTime(2000);
        return bDate.compareTo(aDate);
      });
      
      Set<String> folders = {};
      List<StorageItem> files = [];

      for (var item in items) {
        final relativePath = item.path.replaceFirst('public/formats/', '');
        if (relativePath.isEmpty) continue;
        
        final segments = relativePath.split('/');
        
        bool matchesPath = true;
        for (int i = 0; i < _currentPath.length; i++) {
          if (segments.length <= i || segments[i] != _currentPath[i]) {
            matchesPath = false;
            break;
          }
        }
        
        if (matchesPath && segments.length > _currentPath.length) {
          final nextSegment = segments[_currentPath.length];
          
          if (_currentPath.length == segments.length - 1) {
            if (nextSegment.isNotEmpty && nextSegment != '.keep') {
              files.add(item);
            }
          } else {
            if (nextSegment.isNotEmpty) {
              folders.add(nextSegment);
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _currentFolders = folders.toList()..sort();
          _currentFiles = files;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching formats: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load formats: $e'), backgroundColor: Colors.redAccent));
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Folder Name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      )
    );

    if (confirm == true) {
      final folderName = controller.text.trim();
      if (folderName.isEmpty) return;
      
      setState(() => _isLoading = true);
      try {
        final pathPrefix = _currentPath.isEmpty ? 'public/formats/' : 'public/formats/${_currentPath.join('/')}/';
        final newFolderPath = '$pathPrefix$folderName/.keep';
        
        await Amplify.Storage.uploadFile(
          localFile: AWSFile.fromData(Uint8List(0)),
          path: StoragePath.fromString(newFolderPath),
        ).result;
        
        await _fetchFormats();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to create folder: $e'), backgroundColor: Colors.redAccent));
          setState(() => _isLoading = false);
        }
      }
    }
  }

  Future<void> _uploadFolder() async {
    try {
      final directoryPathsNullable = await file_selector.getDirectoryPaths();
      final List<String> directoryPaths = directoryPathsNullable.whereType<String>().toList();
      
      if (directoryPaths.isEmpty) return;

      final List<Map<String, dynamic>> allFiles = [];
      for (final directoryPath in directoryPaths) {
        final dir = Directory(directoryPath);
        final dirName = dir.path.split(Platform.pathSeparator).last;
        final pathPrefix = _currentPath.isEmpty ? 'public/formats/$dirName/' : 'public/formats/${_currentPath.join('/')}/$dirName/';
        
        final files = dir.listSync(recursive: true).whereType<File>();
        for (var file in files) {
          final relativePath = file.path.replaceFirst(dir.path + Platform.pathSeparator, '').replaceAll(Platform.pathSeparator, '/');
          final awsPath = '$pathPrefix$relativePath';
          allFiles.add({'file': file, 'awsPath': awsPath});
        }
      }

      setState(() {
        _isLoading = true;
        _isUploading = true;
        _uploadProgress = 0.0;
        _uploadStatus = 'Uploading 0 of ${allFiles.length} files...';
      });
      
      for (int i = 0; i < allFiles.length; i++) {
        final file = allFiles[i]['file'] as File;
        final awsPath = allFiles[i]['awsPath'] as String;
        
        setState(() {
          _uploadStatus = 'Uploading file ${i + 1} of ${allFiles.length}...';
          _uploadProgress = i / allFiles.length;
        });

        await Amplify.Storage.uploadFile(
          localFile: AWSFile.fromPath(file.path),
          path: StoragePath.fromString(awsPath),
        ).result;
        
        try {
           final bytes = await file.readAsBytes();
           SupabaseBackupService().backupFileInBackground(awsPath, bytes);
        } catch (_) {}
      }
      
      setState(() {
        _uploadProgress = 1.0;
        _uploadStatus = 'Upload complete!';
        _isUploading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Successfully uploaded ${directoryPaths.length} folder(s)'), backgroundColor: Colors.green));
      }
      await _fetchFormats();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Folder upload failed: $e'), backgroundColor: Colors.redAccent));
        setState(() {
          _isLoading = false;
          _isUploading = false;
        });
      }
    }
  }

  Future<void> _uploadFormat() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.any, allowMultiple: true, withData: true);
      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _isLoading = true;
          _isUploading = true;
          _uploadProgress = 0.0;
          _uploadStatus = 'Uploading 0 of ${result.files.length} files...';
        });
        
        final pathPrefix = _currentPath.isEmpty ? 'public/formats/' : 'public/formats/${_currentPath.join('/')}/';
        
        for (int i = 0; i < result.files.length; i++) {
          final file = result.files[i];
          if (file.path == null && file.bytes == null) continue;
          
          setState(() {
            _uploadStatus = 'Uploading file ${i + 1} of ${result.files.length}...';
            _uploadProgress = i / result.files.length;
          });
          
          final fileName = file.name;
          final path = '$pathPrefix$fileName';
          
          final awsFile = file.path != null ? AWSFile.fromPath(file.path!) : AWSFile.fromData(file.bytes!);
          
          await Amplify.Storage.uploadFile(
            localFile: awsFile,
            path: StoragePath.fromString(path),
          ).result;
          
          try {
            if (file.bytes != null) {
              SupabaseBackupService().backupFileInBackground(path, file.bytes!);
            } else if (file.path != null) {
              final bytes = await File(file.path!).readAsBytes();
              SupabaseBackupService().backupFileInBackground(path, bytes);
            }
          } catch (_) {}
        }

        setState(() {
          _uploadProgress = 1.0;
          _uploadStatus = 'Upload complete!';
          _isUploading = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Formats uploaded successfully'), backgroundColor: Colors.green));
        }
        await _fetchFormats();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.redAccent));
        setState(() {
          _isLoading = false;
          _isUploading = false;
        });
      }
    }
  }

  Future<void> _downloadFormat(StorageItem item) async {
    try {
      final result = await Amplify.Storage.getUrl(
        path: StoragePath.fromString(item.path),
        options: const StorageGetUrlOptions(
          pluginOptions: S3GetUrlPluginOptions(
            validateObjectExistence: true,
            expiresIn: Duration(hours: 1),
          ),
        ),
      ).result;
      
      final url = Uri.parse(result.url.toString());
      if (await canLaunchUrl(url)) {
        await launchUrl(url);
      } else {
        throw Exception("Could not open file URL");
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open file: $e'), backgroundColor: Colors.redAccent));
      }
    }
  }

  Future<void> _deleteFormat(StorageItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Format'),
        content: const Text('Are you sure you want to delete this format? This action cannot be undone.'),
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
        await Amplify.Storage.remove(path: StoragePath.fromString(item.path)).result;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Format deleted successfully'), backgroundColor: Colors.green));
        }
        await _fetchFormats();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.redAccent));
          setState(() => _isLoading = false);
        }
      }
    }
  }

  Future<void> _deleteFolder(String folderName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Folder'),
        content: Text('Delete "$folderName" and all its contents? This cannot be undone.'),
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
        final pathPrefix = _currentPath.isEmpty ? 'public/formats/$folderName/' : 'public/formats/${_currentPath.join('/')}/$folderName/';
        
        // Fetch all objects under this folder
        final result = await Amplify.Storage.list(
          path: StoragePath.fromString(pathPrefix),
        ).result;
        
        if (result.items.isNotEmpty) {
          // Remove all objects
          final pathsToRemove = result.items.map((e) => StoragePath.fromString(e.path)).toList();
          await Amplify.Storage.removeMany(paths: pathsToRemove).result;
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Folder deleted successfully (${pathsToRemove.length} items)'), backgroundColor: Colors.green));
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Folder was already empty or could not be found.'), backgroundColor: Colors.orange));
          }
        }
        
        await _fetchFormats();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e'), backgroundColor: Colors.redAccent));
          setState(() => _isLoading = false);
        }
      }
    }
  }

  Future<void> _renameFormat(StorageItem item) async {
    final oldFileName = item.path.split('/').last;
    final controller = TextEditingController(text: oldFileName);
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Format'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'New File Name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rename'),
          ),
        ],
      )
    );

    if (confirm == true) {
      final newFileName = controller.text.trim();
      if (newFileName.isEmpty || newFileName == oldFileName) return;
      
      setState(() => _isLoading = true);
      try {
        final pathPrefix = _currentPath.isEmpty ? 'public/formats/' : 'public/formats/${_currentPath.join('/')}/';
        final newPath = '$pathPrefix$newFileName';
        
        await Amplify.Storage.copy(
          source: StoragePath.fromString(item.path),
          destination: StoragePath.fromString(newPath),
        ).result;
        
        await Amplify.Storage.remove(path: StoragePath.fromString(item.path)).result;
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Format renamed successfully'), backgroundColor: Colors.green));
        }
        await _fetchFormats();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rename failed: $e'), backgroundColor: Colors.redAccent));
          setState(() => _isLoading = false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> breadcrumbItems = [];
    breadcrumbItems.add(
      InkWell(
        onTap: () {
          setState(() => _currentPath.clear());
          _fetchFormats();
        },
        child: Text('Home', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _currentPath.isEmpty ? AppTheme.primaryColor : Colors.grey.shade600)),
      )
    );
    for (int i = 0; i < _currentPath.length; i++) {
      breadcrumbItems.add(const Text(' > ', style: TextStyle(color: Colors.grey, fontSize: 15)));
      breadcrumbItems.add(
        InkWell(
          onTap: () {
            setState(() => _currentPath = _currentPath.sublist(0, i + 1));
            _fetchFormats();
          },
          child: Text(_currentPath[i], style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: i == _currentPath.length - 1 ? AppTheme.primaryColor : Colors.grey.shade600)),
        )
      );
    }

    int totalItems = _currentFolders.length + _currentFiles.length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 4)),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.folder_shared_rounded, color: AppTheme.primaryColor, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Formats & Templates',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: breadcrumbItems,
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _createFolder,
                      icon: const Icon(Icons.create_new_folder_rounded, size: 18),
                      label: const Text('New Folder'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primaryColor,
                        side: const BorderSide(color: AppTheme.primaryColor),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _uploadFolder,
                      icon: const Icon(Icons.drive_folder_upload_rounded, size: 18),
                      label: const Text('Upload Folder'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primaryColor,
                        side: const BorderSide(color: AppTheme.primaryColor),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _uploadFormat,
                      icon: const Icon(Icons.upload_file_rounded, size: 18),
                      label: const Text('Upload File'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ).animate().fadeIn().slideY(begin: -0.1),
          const SizedBox(height: 24),
          
          // List Area
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade200),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 20, offset: const Offset(0, 10)),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _isLoading
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const CircularProgressIndicator(),
                            if (_isUploading) ...[
                              const SizedBox(height: 16),
                              SizedBox(
                                width: 240,
                                child: LinearProgressIndicator(
                                  value: _uploadProgress > 0 ? _uploadProgress : null,
                                  backgroundColor: Colors.grey.shade200,
                                  valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(_uploadStatus, style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                            ],
                          ],
                        ),
                      )
                    : totalItems == 0
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.folder_open_rounded, size: 64, color: Colors.grey.shade300),
                                const SizedBox(height: 16),
                                const Text("This folder is empty", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black54)),
                                const SizedBox(height: 8),
                                Text("Click 'Upload File' or 'New Folder' to add items", style: TextStyle(color: Colors.grey.shade500)),
                              ],
                            ).animate().fadeIn().scaleXY(begin: 0.9),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(24),
                            itemCount: totalItems,
                            separatorBuilder: (context, index) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              if (index < _currentFolders.length) {
                                // Folder Item
                                final folderName = _currentFolders[index];
                                return Material(
                                  color: Colors.transparent,
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                                    hoverColor: Colors.grey.shade50,
                                    leading: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Colors.amber.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Icon(Icons.folder_rounded, color: Colors.amber, size: 28),
                                    ),
                                    title: Text(folderName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                                    subtitle: Text('Folder', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                                    onTap: () {
                                      setState(() => _currentPath.add(folderName));
                                      _fetchFormats();
                                    },
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                                      tooltip: 'Delete Folder',
                                      onPressed: () => _deleteFolder(folderName),
                                    ),
                                  ),
                                );
                              } else {
                                // File Item
                                final item = _currentFiles[index - _currentFolders.length];
                                final fileName = item.path.split('/').last;
                                final dateStr = item.lastModified != null 
                                    ? DateFormat('dd MMM yyyy, hh:mm a').format(item.lastModified!) 
                                    : 'Unknown Date';
                                final isPdf = fileName.toLowerCase().endsWith('.pdf');
                                final isImage = fileName.toLowerCase().endsWith('.png') || fileName.toLowerCase().endsWith('.jpg') || fileName.toLowerCase().endsWith('.jpeg');
                                
                                IconData fileIcon = Icons.insert_drive_file_rounded;
                                Color iconColor = Colors.blueGrey;
                                if (isPdf) {
                                  fileIcon = Icons.picture_as_pdf_rounded;
                                  iconColor = Colors.redAccent;
                                } else if (isImage) {
                                  fileIcon = Icons.image_rounded;
                                  iconColor = Colors.purpleAccent;
                                }

                                return Material(
                                  color: Colors.transparent,
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                                    hoverColor: Colors.grey.shade50,
                                    leading: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: iconColor.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(fileIcon, color: iconColor),
                                    ),
                                    title: Text(fileName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                    subtitle: Text(dateStr, style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.download_rounded, color: Colors.blue),
                                          tooltip: 'Download',
                                          onPressed: () => _downloadFormat(item),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.edit_rounded, color: Colors.orange),
                                          tooltip: 'Rename',
                                          onPressed: () => _renameFormat(item),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                                          tooltip: 'Delete',
                                          onPressed: () => _deleteFormat(item),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
              ),
            ).animate().fadeIn(delay: 100.ms),
          ),
        ],
      ),
    );
  }
}
