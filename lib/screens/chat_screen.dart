import 'package:amplify_api/amplify_api.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../services/auth_service.dart';
import '../services/encryption_service.dart';
import '../services/notification_service.dart';
import '../services/deal_service.dart';
import '../models/deal.dart';
import 'deal_detail_screen.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import '../models/ModelProvider.dart';
import 'package:cuc_app/services/backup_aware_api.dart';
class ChatScreen extends StatefulWidget {
  final int? targetUserId; // If null, staff is chatting with Admin
  final String? targetUserName;
  final bool isSplitView;
  final VoidCallback? onBackPressed;

  const ChatScreen({super.key, this.targetUserId, this.targetUserName, this.isSplitView = false, this.onBackPressed});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  int? _myId;
  bool _isLoading = true;
  bool _isTargetOnline = false;
  Deal? _selectedDeal;
  StreamSubscription? _messagesSubscription;
  String? _targetRole;

  @override
  void initState() {
    super.initState();
    _initChat();
  }

  Future<void> _initChat() async {
    final prefs = await SharedPreferences.getInstance();
    _myId = prefs.getInt('current_user_id');
    
    _fetchTargetInfo();
    _subscribeToMessages();
  }

  Future<void> _fetchTargetInfo() async {
    final targetId = widget.targetUserId ?? 1;
    try {
      final req = ModelQueries.list(Users.classType, where: Users.ID.eq(targetId), limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      final u = (res.data?.items ?? []).isNotEmpty ? res.data!.items.first : null;
      if (u != null && mounted) {
        setState(() => _targetRole = u.role);
      }
    } catch (_) {}
  }

  void _subscribeToMessages() async {
    final targetId = widget.targetUserId ?? 1;
    if (_myId == null) return;

    setState(() => _isLoading = true);

    try {
      // Fetch initial messages
      final req = ModelQueries.list(Messages.classType, limit: 10000);
      final res = await Amplify.API.query(request: req).response;
      var allMsgs = res.data?.items.where((e) => e != null).cast<Messages>().toList() ?? [];
      
      allMsgs.sort((a, b) => (a.createdAt?.toString() ?? '').compareTo(b.createdAt?.toString() ?? ''));
      
      var filtered = allMsgs.where((m) {
        final sId = m.sender_id;
        final rId = m.receiver_id;
        return (sId == _myId && rId == targetId) || (sId == targetId && rId == _myId);
      }).toList();
      
      await _processMessages(filtered.map((m) => m.toJson()).toList());
      
      // Subscribe to new messages
      _messagesSubscription = Amplify.API.subscribe(
        GraphQLRequest<String>(document: '''
          subscription OnCreateMessages {
            onCreateMessages {
              id
              sender_id
              receiver_id
              content
              is_read
              created_at
              attachment_type
              attachment_id
              createdAt
              updatedAt
            }
          }
        ''')
      ).listen((event) async {
          final req = ModelQueries.list(Messages.classType, limit: 10000);
          final res = await Amplify.API.query(request: req).response;
          var allMsgs = res.data?.items.where((e) => e != null).cast<Messages>().toList() ?? [];
          allMsgs.sort((a, b) => (a.createdAt?.toString() ?? '').compareTo(b.createdAt?.toString() ?? ''));
          var filtered = allMsgs.where((m) {
            final sId = m.sender_id;
            final rId = m.receiver_id;
            return (sId == _myId && rId == targetId) || (sId == targetId && rId == _myId);
          }).toList();
          await _processMessages(filtered.map((m) => m.toJson()).toList());
        },
        onError: (dynamic e) {
          debugPrint('Chat subscription stream error: $e');
        }
      );
    } catch (e) {
      debugPrint('Stream error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _processMessages(List<Map<String, dynamic>> rawMessages) async {
    try {
      final targetId = widget.targetUserId ?? 1;

      if (_myId != null) {
        try {
          final uReq = ModelQueries.list(Users.classType, where: Users.ID.eq(_myId), limit: 10000);
          final uRes = await Amplify.API.query(request: uReq).response;
          if (uRes.data?.items.isNotEmpty == true) {
             final u = uRes.data!.items.first!;
             final updated = u.copyWith(last_seen: DateTime.now().toIso8601String());
             await BackupAwareApi().update(updated);
          }
        } catch (_) {}
      }

      bool isOnline = false;
      try {
        final sReq = ModelQueries.list(UserSessions.classType, where: UserSessions.USER_ID.eq(targetId), limit: 10000);
        final sRes = await Amplify.API.query(request: sReq).response;
        if (sRes.data?.items.isNotEmpty == true) {
          isOnline = sRes.data!.items.first?.is_active == true;
        }
      } catch (_) {}

      final processed = rawMessages.map((m) {
        return {
          ...m,
          'content': EncryptionService().decryptText(m['content'] ?? '')
        };
      }).toList();

      if (mounted) {
        setState(() {
          _isTargetOnline = isOnline;
          _messages = processed;
          _isLoading = false;
        });
        _scrollToBottom();

        // Mark messages as read
        final unreadMsgs = processed.where((m) => m['sender_id'] == targetId && m['is_read'] == false).toList();
        if (unreadMsgs.isNotEmpty) {
           for (var m in unreadMsgs) {
             try {
               final msgReq = ModelQueries.list(Messages.classType, where: Messages.ID.eq(m['id']), limit: 10000);
               final msgRes = await Amplify.API.query(request: msgReq).response;
               if (msgRes.data?.items.isNotEmpty == true) {
                 final msg = msgRes.data!.items.first!;
                 final updated = msg.copyWith(is_read: true);
                 await BackupAwareApi().update(updated);
               }
             } catch (_) {}
           }
        }
      }
    } catch (e) {
      debugPrint('Error processing messages: $e');
    }
  }

  @override
  void dispose() {
    _messagesSubscription?.cancel();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final attachmentId = _selectedDeal?.id;
    final attachmentType = attachmentId != null ? 'work' : null;

    if (_msgController.text.trim().isEmpty && attachmentId == null) return;
    
    final content = _msgController.text.trim();
    _msgController.clear();
    setState(() => _selectedDeal = null);
    
    try {
      final targetId = widget.targetUserId ?? 1;
      final encryptedContent = EncryptionService().encryptText(content.isEmpty ? '[Attachment]' : content);
      
      final newMsg = Messages(
        sender_id: _myId,
        receiver_id: targetId,
        content: encryptedContent,
        attachment_type: attachmentType,
        attachment_id: attachmentId,
        is_read: false,
        created_at: DateTime.now().toIso8601String(),
      );
      await BackupAwareApi().create(newMsg);

      String senderName = await AuthService().getUserName() ?? 'Someone';
      String preview = content.isEmpty ? '📎 Attached a work' : content;
      await NotificationService().sendNotification(
        userId: targetId,
        title: 'New Message from $senderName',
        message: preview.length > 50 ? '${preview.substring(0, 47)}...' : preview,
        type: 'chat',
      );

      _scrollToBottom();
    } catch (e) {
      _msg('Send failed: $e');
    }
  }

  Future<void> _showWorkPicker() async {
    final dealService = DealService();
    try {
      final allDeals = await dealService.getAllDeals();
      final deals = allDeals.where((d) {
        final isCrm = d.pipeline.toLowerCase() == 'crm' || d.pipeline.toLowerCase() == 'lead';
        if (isCrm && !d.isWon) return false;
        return true;
      }).toList();
      if (!mounted) return;
      
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (context) => Container(
          padding: const EdgeInsets.symmetric(vertical: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 24),
              const Text('Attach Work to Chat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
              const SizedBox(height: 16),
              Expanded(
                child: deals.isEmpty 
                  ? Center(child: Text('No work found', style: TextStyle(color: Colors.grey.shade500)))
                  : ListView.builder(
                      itemCount: deals.length,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemBuilder: (context, index) {
                        final d = deals[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade100)
                          ),
                          child: ListTile(
                            leading: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2))]),
                              child: const Icon(Icons.work_rounded, color: Colors.blueAccent, size: 20),
                            ),
                            title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            subtitle: Text(d.clientName ?? 'No Client', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                            trailing: const Icon(Icons.add_circle_rounded, color: Colors.blueAccent),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            onTap: () {
                              Navigator.pop(context);
                              setState(() => _selectedDeal = d);
                            },
                          ),
                        );
                      },
                    ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      _msg('Failed to load work: $e');
    }
  }

  void _msg(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));

  bool _isSameDay(DateTime date1, DateTime date2) {
    return date1.year == date2.year && date1.month == date2.month && date1.day == date2.day;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB), // Very light, clean background
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: widget.isSplitView ? null : IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.black87, size: 20),
          onPressed: () {
            if (widget.onBackPressed != null) {
              widget.onBackPressed!();
            } else {
              Navigator.pop(context);
            }
          },
        ),
        title: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.grey.shade100,
                  child: Text(
                    widget.targetUserName?[0].toUpperCase() ?? 'A',
                    style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12, height: 12,
                    decoration: BoxDecoration(
                      color: _isTargetOnline ? Colors.green : Colors.grey.shade400,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.targetUserName ?? 'Admin',
                          style: const TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_targetRole == 'admin') ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(4)),
                          child: const Text('ADMIN', style: TextStyle(color: Colors.red, fontSize: 9, fontWeight: FontWeight.bold)),
                        )
                      ]
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _isTargetOnline ? 'Active Now' : 'Offline',
                    style: TextStyle(fontSize: 12, color: _isTargetOnline ? Colors.green : Colors.grey.shade500, fontWeight: _isTargetOnline ? FontWeight.w600 : FontWeight.normal),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(icon: Icon(Icons.videocam_rounded, color: Colors.grey.shade600), onPressed: () {}),
          IconButton(icon: Icon(Icons.call_rounded, color: Colors.grey.shade600, size: 20), onPressed: () {}),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: Colors.grey.shade200, height: 1),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading 
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final m = _messages[index];
                    final isMe = m['sender_id'] == _myId;
                    final time = DateTime.parse(m['created_at'].toString()).toLocal();
                    
                    // Logic to show date separators
                    bool showDate = false;
                    if (index == 0) {
                      showDate = true;
                    } else {
                      final prevTime = DateTime.parse(_messages[index - 1]['created_at'].toString()).toLocal();
                      if (!_isSameDay(time, prevTime)) {
                        showDate = true;
                      }
                    }

                    // Determine if we need a tail (last message in a sequence by the same sender)
                    bool showTail = true;
                    if (index < _messages.length - 1) {
                      final nextM = _messages[index + 1];
                      if (nextM['sender_id'] == m['sender_id']) {
                        showTail = false;
                      }
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showDate)
                          Center(
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 24, top: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12)),
                              child: Text(
                                _isSameDay(time, DateTime.now()) ? 'Today' : DateFormat('MMM d, yyyy').format(time),
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey.shade600),
                              ),
                            ),
                          ).animate().fadeIn(),
                          
                        Align(
                          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: EdgeInsets.only(bottom: showTail ? 16 : 4),
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                            decoration: BoxDecoration(
                              gradient: isMe ? const LinearGradient(
                                colors: [Color(0xFF2E3856), Color(0xFF1E2436)], // Premium dark charcoal gradient
                                begin: Alignment.topLeft, end: Alignment.bottomRight,
                              ) : null,
                              color: isMe ? null : Colors.white,
                              boxShadow: isMe ? [
                                BoxShadow(color: const Color(0xFF1E2436).withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 4))
                              ] : [
                                BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 8, offset: const Offset(0, 2))
                              ],
                              borderRadius: BorderRadius.only(
                                topLeft: const Radius.circular(20),
                                topRight: const Radius.circular(20),
                                bottomLeft: Radius.circular(isMe || !showTail ? 20 : 4),
                                bottomRight: Radius.circular(!isMe || !showTail ? 20 : 4),
                              ),
                              border: isMe ? null : Border.all(color: Colors.grey.shade100, width: 1),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                            child: Column(
                              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                if (m['attachment_type'] == 'work' && m['attachment_id'] != null)
                                  FutureBuilder<Deal?>(
                                    future: DealService().getDealById(int.parse(m['attachment_id'].toString())),
                                    builder: (context, snapshot) {
                                      if (!snapshot.hasData) return const SizedBox(height: 40, width: 150, child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))));
                                      final deal = snapshot.data!;
                                      return InkWell(
                                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => DealDetailScreen(deal: deal))),
                                        child: Container(
                                          margin: const EdgeInsets.only(bottom: 8),
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: isMe ? Colors.white.withValues(alpha: 0.1) : Colors.blue.shade50,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.all(8),
                                                decoration: BoxDecoration(color: isMe ? Colors.white.withValues(alpha: 0.2) : Colors.blueAccent.withValues(alpha: 0.1), shape: BoxShape.circle),
                                                child: Icon(Icons.folder_shared_rounded, color: isMe ? Colors.white : Colors.blueAccent, size: 18),
                                              ),
                                              const SizedBox(width: 12),
                                              Flexible(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      deal.name,
                                                      style: TextStyle(color: isMe ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 13),
                                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                                    ),
                                                    Text(
                                                      deal.clientName ?? 'No Client',
                                                      style: TextStyle(color: isMe ? Colors.white70 : Colors.grey.shade600, fontSize: 11),
                                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                if (m['content'] != '[Attachment]')
                                  Text(
                                    m['content'],
                                    style: TextStyle(
                                      color: isMe ? Colors.white : const Color(0xFF1E293B),
                                      fontSize: 15,
                                      height: 1.3,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      DateFormat('hh:mm a').format(time),
                                      style: TextStyle(
                                        color: isMe ? Colors.white.withValues(alpha: 0.6) : Colors.grey.shade400,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (isMe) ...[
                                      const SizedBox(width: 4),
                                      Icon(m['is_read'] == true ? Icons.done_all_rounded : Icons.check_rounded, size: 14, color: m['is_read'] == true ? Colors.blue.shade200 : Colors.white.withValues(alpha: 0.6)),
                                    ]
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ).animate().fadeIn(duration: 200.ms).slideY(begin: 0.1, end: 0, duration: 200.ms),
                      ],
                    );
                  },
                ),
          ),
          
          // Selected Attachment Preview
          if (_selectedDeal != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Colors.grey.shade100))),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      child: const Icon(Icons.work_rounded, color: Colors.blueAccent, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Attaching Work', style: TextStyle(fontSize: 11, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                          Text(_selectedDeal!.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20, color: Colors.grey),
                      onPressed: () => setState(() => _selectedDeal = null),
                      style: IconButton.styleFrom(backgroundColor: Colors.white, padding: const EdgeInsets.all(4)),
                    ),
                  ],
                ),
              ).animate().slideY(begin: 1, end: 0).fadeIn(),
            ),
            
          // Input Area
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), // Extra bottom padding for safe area
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 20, offset: const Offset(0, -5))
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_rounded, color: Color(0xFF64748B), size: 28),
                  onPressed: _showWorkPicker,
                  padding: const EdgeInsets.all(12),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9), // Light gray background
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _msgController,
                            minLines: 1,
                            maxLines: 5,
                            textCapitalization: TextCapitalization.sentences,
                            style: const TextStyle(fontSize: 15, color: Colors.black87),
                            decoration: const InputDecoration(
                              hintText: 'Message...',
                              hintStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 15),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.sentiment_satisfied_rounded, color: Color(0xFF94A3B8), size: 24),
                          onPressed: () {},
                          padding: const EdgeInsets.only(bottom: 12, right: 8),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  margin: const EdgeInsets.only(bottom: 2),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [Color(0xFF2E3856), Color(0xFF1E2436)]),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    onPressed: _sendMessage,
                    padding: const EdgeInsets.all(14),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
