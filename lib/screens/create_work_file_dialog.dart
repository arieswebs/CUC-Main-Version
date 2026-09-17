import 'package:flutter/material.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_storage_s3/amplify_storage_s3.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:cuc_app/services/backup_aware_api.dart';
import '../models/ModelProvider.dart' as amplify_models;
import '../models/client.dart';
import '../theme.dart';
import '../services/supabase_backup_service.dart';
import '../widgets/google_docs_picker_dialog.dart';
import '../services/logging_service.dart';

class CreateWorkFileDialog extends StatefulWidget {
  final VoidCallback onSaved;
  const CreateWorkFileDialog({super.key, required this.onSaved});

  @override
  State<CreateWorkFileDialog> createState() => _CreateWorkFileDialogState();
}

class _CreateWorkFileDialogState extends State<CreateWorkFileDialog> {
  final _googleDocsController = TextEditingController();
  final _workNameController = TextEditingController();
  final _fileNoController = TextEditingController();
  final _workTypeController = TextEditingController();
  
  String _selectedCategory = 'General';
  
  bool _isLoading = false;
  List<Client> _clients = [];
  Client? _selectedClient;
  
  List<amplify_models.Users> _staffList = [];
  amplify_models.Users? _selectedStaff;
  final Map<String, int> _staffIdMap = {};
  
  List<StorageItem> _clientFiles = [];
  final Set<String> _selectedFiles = {};
  bool _isLoadingFiles = false;
  DateTime? _selectedDeadline;

  @override
  void initState() {
    super.initState();
    _fetchClients();
    _fetchStaff();
  }

  Future<void> _fetchStaff() async {
    try {
      final req = ModelQueries.list(amplify_models.Users.classType, limit: 1000);
      final res = await Amplify.API.query(request: req).response;
      if (res.data != null) {
        final List<amplify_models.Users> fetched = res.data!.items.whereType<amplify_models.Users>().toList();
        final sbUserMap = await SupabaseBackupService().getUsernameToIdMap();
        final List<amplify_models.Users> deduplicated = [];
        for (var staff in fetched) {
          final intId = sbUserMap[staff.username] ?? sbUserMap[staff.email];
          if (intId != null) {
            _staffIdMap[staff.id] = intId;
          }
          final name = (staff.name ?? staff.username ?? 'Unknown').trim();
          if (name == 'Unknown' || name.isEmpty) continue;
          
          bool isDuplicate = false;
          for (int i = 0; i < deduplicated.length; i++) {
            final existingName = (deduplicated[i].name ?? deduplicated[i].username ?? '').trim();
            final n1 = name.toLowerCase();
            final n2 = existingName.toLowerCase();
            
            if (n1.startsWith(n2) || n2.startsWith(n1)) {
              isDuplicate = true;
              if (name.length > existingName.length) {
                deduplicated[i] = staff;
              }
              break;
            }
          }
          
          if (!isDuplicate) {
            deduplicated.add(staff);
          }
        }
        deduplicated.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
        if (mounted) setState(() => _staffList = deduplicated);
      }
    } catch (e) {
      debugPrint('Error fetching staff: $e');
    }
  }

  @override
  void dispose() {
    _googleDocsController.dispose();
    _workNameController.dispose();
    _fileNoController.dispose();
    super.dispose();
  }

  Future<void> _fetchClients() async {
    setState(() => _isLoading = true);
    try {
      final req = ModelQueries.list(amplify_models.Clients.classType, limit: 1000);
      final res = await Amplify.API.query(request: req).response;
      if (res.data != null) {
        final List<Client> fetched = res.data!.items
            .whereType<amplify_models.Clients>()
            .map((m) => Client(
              id: m.id,
              name: m.name ?? '',
              phone: m.phone,
            ))
            .toList();
        fetched.sort((a, b) => a.name.compareTo(b.name));
        if (mounted) setState(() => _clients = fetched);
      }
    } catch (e) {
      debugPrint('Error fetching clients: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadClientFiles(Client client) async {
    setState(() {
      _isLoadingFiles = true;
      _clientFiles = [];
      _selectedFiles.clear();
    });
    
    try {
      // Fetch both personal and work files
      final pFilesRes = await Amplify.Storage.list(
        path: StoragePath.fromString('public/${client.id}/personal/'),
        options: StorageListOptions(pluginOptions: S3ListPluginOptions.listAll()),
      ).result;
      
      final wFilesRes = await Amplify.Storage.list(
        path: StoragePath.fromString('public/${client.id}/work/'),
        options: StorageListOptions(pluginOptions: S3ListPluginOptions.listAll()),
      ).result;
      
      if (!mounted) return;
      setState(() {
        _clientFiles.addAll(pFilesRes.items.where((f) => !f.path.contains('.emptyPlaceholder')));
        _clientFiles.addAll(wFilesRes.items.where((f) => !f.path.contains('.emptyPlaceholder')));
      });
    } catch (e) {
      debugPrint("Load files error: $e");
    } finally {
      if (mounted) setState(() => _isLoadingFiles = false);
    }
  }

  Future<void> _saveWorkFile() async {
    if (_selectedClient == null || _workNameController.text.trim().isEmpty || _fileNoController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a client, enter a work name, and provide a File No.')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final filesJson = jsonEncode(_selectedFiles.toList());
      
      final prefs = await SharedPreferences.getInstance();
      final currentUserName = prefs.getString('current_user_name') ?? 'Unknown';

      final newDeal = amplify_models.Deals(
        name: _workNameController.text.trim(),
        client_name: _selectedClient!.name,
        company: _selectedClient!.id.toString(), // Using company field to store Client ID safely
        pipeline: 'Work File',
        stage: 'Active',
        work_type: _selectedCategory == 'General' 
            ? _workTypeController.text.trim() 
            : _workTypeController.text.trim().isEmpty 
                ? _selectedCategory 
                : '$_selectedCategory - ${_workTypeController.text.trim()}',
        drive_link: _googleDocsController.text.trim(),
        register_no: _fileNoController.text.trim(),
        files_received: filesJson,
        responsible_id: _selectedStaff != null ? (_staffIdMap[_selectedStaff!.id] ?? int.tryParse(_selectedStaff!.id)) : null,
        responsible_name: _selectedStaff?.name,
        closed_at: _selectedDeadline?.toIso8601String(),
        referred_by: currentUserName, // Using referred_by to store the creator
        created_at: DateTime.now().toIso8601String(),
        updated_at: DateTime.now().toIso8601String(),
      );

      await BackupAwareApi().create(newDeal);

      await LoggingService().logAction(
        action: 'WORK_FILE_CREATED',
        targetType: 'WorkFile',
        targetId: newDeal.name,
        details: 'Created Work File for ${_selectedClient!.name}${_selectedStaff != null ? ' assigned to ${_selectedStaff!.name}' : ''}',
      );

      if (mounted) {
        widget.onSaved();
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Error saving work file: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.create_new_folder_rounded, color: AppTheme.primaryColor, size: 24),
          ),
          const SizedBox(width: 16),
          const Expanded(child: Text('Create New Work File', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: -0.5))),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _workNameController,
                decoration: InputDecoration(
                  labelText: 'Work File Name (e.g. Annual Audit 2026)',
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _selectedCategory,
                decoration: InputDecoration(
                  labelText: 'Category',
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                ),
                items: ['General', 'Legal', 'Consultancy'].map((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
                onChanged: (newValue) {
                  setState(() {
                    _selectedCategory = newValue!;
                  });
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _workTypeController,
                decoration: InputDecoration(
                  labelText: 'Type of Work (e.g. Tax Return, Audit)',
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                ),
              ),
              const SizedBox(height: 16),
              Autocomplete<Client>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  if (textEditingValue.text.isEmpty) {
                    return _clients.take(10);
                  }
                  return _clients.where((Client client) {
                    final label = '${client.name} ${client.phone}'.toLowerCase();
                    return label.contains(textEditingValue.text.toLowerCase());
                  }).take(10);
                },
                displayStringForOption: (Client option) => '${option.name} ${option.phone != null ? '(${option.phone})' : ''}',
                onSelected: (Client selection) {
                  setState(() => _selectedClient = selection);
                  _loadClientFiles(selection);
                },
                fieldViewBuilder: (BuildContext context, TextEditingController textEditingController, FocusNode focusNode, VoidCallback onFieldSubmitted) {
                  if (_selectedClient != null && textEditingController.text.isEmpty) {
                    textEditingController.text = '${_selectedClient!.name} ${_selectedClient!.phone != null ? '(${_selectedClient!.phone})' : ''}';
                  }
                  return TextField(
                    controller: textEditingController,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      labelText: 'Select Client (Type to search)',
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                      suffixIcon: const Icon(Icons.search_rounded, color: Colors.grey),
                    ),
                  );
                },
                optionsViewBuilder: (BuildContext context, AutocompleteOnSelected<Client> onSelected, Iterable<Client> options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      color: Colors.white,
                      child: Container(
                        width: MediaQuery.of(context).size.width > 600 ? 450 : MediaQuery.of(context).size.width * 0.8,
                        constraints: const BoxConstraints(maxHeight: 250),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: options.length,
                          itemBuilder: (BuildContext context, int index) {
                            final Client option = options.elementAt(index);
                            return ListTile(
                              title: Text('${option.name} ${option.phone != null ? '(${option.phone})' : ''}', style: const TextStyle(fontWeight: FontWeight.w500)),
                              onTap: () {
                                onSelected(option);
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<amplify_models.Users>(
                initialValue: _selectedStaff,
                decoration: InputDecoration(
                  labelText: 'Assign To Staff (Optional)',
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                  prefixIcon: const Icon(Icons.person, color: Colors.grey),
                ),
                items: _staffList.map((staff) {
                  return DropdownMenuItem(
                    value: staff,
                    child: Text(staff.name ?? staff.username ?? 'Unknown'),
                  );
                }).toList(),
                onChanged: (val) => setState(() => _selectedStaff = val),
              ),
              const SizedBox(height: 16),
                    TextField(
                      controller: _fileNoController,
                      decoration: InputDecoration(
                        labelText: 'File No',
                        filled: true,
                        fillColor: Colors.grey.shade50,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(_selectedDeadline == null ? 'Select Deadline' : 'Deadline: ${_selectedDeadline!.toLocal().toString().split(' ')[0]}'),
                      leading: const Icon(Icons.calendar_today, color: AppTheme.primaryColor),
                      trailing: _selectedDeadline != null
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: Colors.red),
                              onPressed: () => setState(() => _selectedDeadline = null),
                            )
                          : null,
                      onTap: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _selectedDeadline ?? DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (date != null) setState(() => _selectedDeadline = date);
                      },
                    ),
                    const SizedBox(height: 16),
                    
                    if (_selectedClient != null) ...[
                      const Padding(
                        padding: EdgeInsets.only(top: 8, bottom: 8),
                        child: Text('Select Needed Files', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87)),
                      ),
                      Container(
                        height: 200,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _isLoadingFiles
                          ? const Center(child: CircularProgressIndicator())
                          : _clientFiles.isEmpty
                            ? Center(child: Text('No files found for this client.', style: TextStyle(color: Colors.grey.shade500)))
                            : ListView.builder(
                                itemCount: _clientFiles.length,
                                itemBuilder: (context, index) {
                                  final file = _clientFiles[index];
                                  final isPersonal = file.path.contains('/personal/');
                                  final category = isPersonal ? 'Personal' : 'Work';
                                  final fileName = file.path.split('/').last;
                                  final isSelected = _selectedFiles.contains(file.path);
                                  
                                  return CheckboxListTile(
                                    title: Text(fileName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                                    subtitle: Text(category, style: TextStyle(fontSize: 11, color: isPersonal ? Colors.blue.shade700 : Colors.green.shade700)),
                                    value: isSelected,
                                    activeColor: AppTheme.primaryColor,
                                    checkboxShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                    onChanged: (val) {
                                      setState(() {
                                        if (val == true) {
                                          _selectedFiles.add(file.path);
                                        } else {
                                          _selectedFiles.remove(file.path);
                                        }
                                      });
                                    },
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _googleDocsController,
                            decoration: InputDecoration(
                              labelText: 'Connected Google Docs Link',
                              hintText: 'Paste or pick Google Docs URL',
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2)),
                              prefixIcon: const Icon(Icons.link_rounded, color: AppTheme.primaryColor),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: IconButton(
                            tooltip: 'Browse Google Docs',
                            icon: const Icon(Icons.add_to_drive, color: Colors.blue),
                            onPressed: () async {
                              final String? link = await showDialog<String>(
                                context: context,
                                builder: (context) => GoogleDocsPickerDialog(
                                  initialFileName: _workNameController.text.isNotEmpty ? _workNameController.text : null,
                                ),
                              );
                              if (link != null && link.isNotEmpty) {
                                setState(() {
                                  _googleDocsController.text = link;
                                });
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context), 
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14), foregroundColor: Colors.grey.shade700),
                child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ElevatedButton(
                onPressed: _isLoading ? null : _saveWorkFile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor, 
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  shadowColor: AppTheme.primaryColor.withValues(alpha: 0.3),
                ),
                child: _isLoading 
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save Work File', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ],
          );
        }
      }
