import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../models/deal.dart';
import '../models/deal_activity.dart';
import '../services/deal_service.dart';
import 'deal_detail_screen.dart';
import 'google_docs_webview_screen.dart';
import 'package:intl/intl.dart';

class WorkManagementScreen extends StatefulWidget {
  final bool showOnlyVerification;
  const WorkManagementScreen({super.key, this.showOnlyVerification = false});

  @override
  State<WorkManagementScreen> createState() => _WorkManagementScreenState();
}

class _WorkManagementScreenState extends State<WorkManagementScreen> {
  final _dealService = DealService();
  List<Deal> _allDeals = [];
  bool _isLoading = true;

  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  String _sortOption = 'Newest First';
  static final DateTime nov1Cutoff = DateTime(2026, 11, 1);
  String _selectedPeriod = 'All'; // 'All', '2026-2027', '2025-2026'

  DateTime _getDealDate(Deal d) {
    if (d.createdAt != null) return d.createdAt!;
    return DateTime(2000);
  }
  bool _showOnlyMyWorks = true;
  bool _isBoardView = true;
  String? _selectedStaffFilter;
  int? _currentUserId;
  bool _isManagerOrAdmin = false;
  StreamSubscription? _dealsSubscription;
  final ScrollController _boardScrollController = ScrollController();

  @override
  void dispose() {
    _dealsSubscription?.cancel();
    _boardScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentUserId();
    _subscribeToDeals();
  }

  void _subscribeToDeals() {
    setState(() => _isLoading = true);
    _dealsSubscription = _dealService.getDealsStream().listen((deals) {
      if (mounted) {
        setState(() {
          _allDeals = deals;
          _isLoading = false;
        });
      }
    }, onError: (e) {
      debugPrint('Error loading deals: $e');
      if (mounted) setState(() => _isLoading = false);
    });
  }



  Future<void> _loadCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _currentUserId = prefs.getInt('current_user_id');
      });
    }
  }

  Future<void> _refreshDeals() async {
    try {
      final deals = await _dealService.getAllDeals();
      if (mounted) {
        setState(() {
          _allDeals = deals;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error refreshing deals: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openDealDetail([Deal? deal]) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DealDetailScreen(deal: deal),
      ),
    ).then((_) => _refreshDeals());
  }

  Future<void> _deleteDeal(Deal deal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Work'),
        content: Text('Are you sure you want to delete "${deal.name}"? This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _dealService.deleteDeal(deal.id!);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Work deleted successfully'), backgroundColor: Colors.green),
          );
          _refreshDeals();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting work: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _handleVerification(Deal deal, bool isVerified) async {
    if (isVerified) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm Verification'),
          content: const Text('Are you sure you want to verify this work and move it to the next stage?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
            TextButton(
              onPressed: () => Navigator.pop(context, true), 
              style: TextButton.styleFrom(foregroundColor: Colors.green),
              child: const Text('VERIFY')
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      try {
        await _dealService.addActivity(DealActivity(
          dealId: deal.id!,
          type: 'note',
          title: 'Work Verified',
          description: 'Work verified by manager/admin.',
          createdBy: _currentUserId ?? 1,
        ));
        await _dealService.moveDealToStage(deal.id!, 'Verification', 'Invoice');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Work Verified! Moved to Invoice stage.'), backgroundColor: Colors.green));
          _refreshDeals();
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    } else {
      final remarkController = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Not Verified'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Please provide remarks for reverification:'),
              const SizedBox(height: 12),
              TextField(
                controller: remarkController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Enter remarks...',
                ),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
            TextButton(
              onPressed: () => Navigator.pop(context, true), 
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('SUBMIT')
            ),
          ],
        ),
      );

      if (confirmed == true && remarkController.text.trim().isNotEmpty) {
        try {
          await _dealService.addActivity(DealActivity(
            dealId: deal.id!,
            type: 'note',
            title: 'Reverification Needed',
            description: 'Returned for reverification. Remarks: ${remarkController.text.trim()}',
            createdBy: _currentUserId ?? 1,
          ));
          await _dealService.moveDealToStage(deal.id!, 'Verification', 'In Progress');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sent for reverification'), backgroundColor: Colors.orange));
            _refreshDeals();
          }
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
        }
      } else if (confirmed == true && remarkController.text.trim().isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Remarks are required'), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isWide = MediaQuery.of(context).size.width > 900;
    
    var list = _allDeals.where((d) {
      final isCrm = d.pipeline.toLowerCase() == 'crm' || d.pipeline.toLowerCase() == 'lead';
      if (isCrm) {
        // Only CRM leads that have been passed come into Work Management
        return d.isWon;
      }
      return true;
    }).toList();
    if (_selectedPeriod == '2025-2026') {
      list = list.where((d) => _getDealDate(d).isBefore(nov1Cutoff)).toList();
    } else if (_selectedPeriod == '2026-2027') {
      list = list.where((d) => !_getDealDate(d).isBefore(nov1Cutoff)).toList();
    }
    if (widget.showOnlyVerification) {
      list = list.where((d) => d.stage.toLowerCase() == 'verification').toList();
    }
    if (_showOnlyMyWorks && _currentUserId != null) {
      if (widget.showOnlyVerification) {
        list = list.where((d) {
          final parsedVer = VerificationDetails.parse(d.description);
          return parsedVer.verifierId?.toString() == _currentUserId.toString();
        }).toList();
      } else {
        list = list.where((d) => d.responsibleId?.toString() == _currentUserId.toString()).toList();
      }
    }
    
    if (_selectedStaffFilter != null) {
      list = list.where((d) {
        if (d.responsibleName == null || d.responsibleName!.trim().isEmpty) return false;
        final firstWord = d.responsibleName!.trim().split(' ').first;
        if (firstWord.isEmpty) return false;
        final formattedFirstWord = firstWord[0].toUpperCase() + firstWord.substring(1).toLowerCase();
        return formattedFirstWord == _selectedStaffFilter;
      }).toList();
    }
    
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((d) => 
          d.name.toLowerCase().contains(q) || 
          (d.clientName?.toLowerCase().contains(q) ?? false) ||
          (d.registerNo?.toLowerCase().contains(q) ?? false) ||
          (d.workType?.toLowerCase().contains(q) ?? false)
      ).toList();
    }
    
    if (_sortOption == 'Newest First') {
      list.sort((a, b) => (b.createdAt ?? DateTime(2000)).compareTo(a.createdAt ?? DateTime(2000)));
    } else if (_sortOption == 'Oldest First') {
      list.sort((a, b) => (a.createdAt ?? DateTime(2000)).compareTo(b.createdAt ?? DateTime(2000)));
    } else if (_sortOption == 'A-Z') {
      list.sort((a, b) => a.name.compareTo(b.name));
    } else if (_sortOption == 'Z-A') {
      list.sort((a, b) => b.name.compareTo(a.name));
    } else if (_sortOption == 'Highest Amount') {
      list.sort((a, b) => (b.amount).compareTo(a.amount));
    } else if (_sortOption == 'Lowest Amount') {
      list.sort((a, b) => (a.amount).compareTo(b.amount));
    } else if (_sortOption == 'Invoice No (A-Z)') {
      list.sort((a, b) => (a.registerNo ?? '').compareTo(b.registerNo ?? ''));
    } else if (_sortOption == 'Invoice No (Z-A)') {
      list.sort((a, b) => (b.registerNo ?? '').compareTo(a.registerNo ?? ''));
    } else if (_sortOption == 'Legal First') {
      list.sort((a, b) {
        bool aLegal = (a.workType ?? '').toLowerCase().contains('legal');
        bool bLegal = (b.workType ?? '').toLowerCase().contains('legal');
        if (aLegal && !bLegal) return -1;
        if (!aLegal && bLegal) return 1;
        return (b.createdAt ?? DateTime(2000)).compareTo(a.createdAt ?? DateTime(2000));
      });
    } else if (_sortOption == 'Consultancy First') {
      list.sort((a, b) {
        bool aCons = (a.workType ?? '').toLowerCase().contains('consultancy');
        bool bCons = (b.workType ?? '').toLowerCase().contains('consultancy');
        if (aCons && !bCons) return -1;
        if (!aCons && bCons) return 1;
        return (b.createdAt ?? DateTime(2000)).compareTo(a.createdAt ?? DateTime(2000));
      });
    }

    final staffNames = _allDeals
        .map((d) => d.responsibleName)
        .where((name) => name != null && name.trim().isNotEmpty)
        .map((name) {
          final trimmed = name!.trim();
          final firstWord = trimmed.split(' ').first;
          if (firstWord.isEmpty) return '';
          return firstWord[0].toUpperCase() + firstWord.substring(1).toLowerCase();
        })
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    
    return Container(
      color: const Color(0xFFF8FAFB),
      child: Padding(
        padding: EdgeInsets.fromLTRB(isWide ? 16 : 12, 4, isWide ? 16 : 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPremiumHeader(list.length, staffNames),
            const SizedBox(height: 12),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refreshDeals,
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : list.isEmpty
                        ? _buildEmptyState()
                        : _isBoardView
                            ? _buildBoardView(list, MediaQuery.of(context).size.width > 1100)
                            : _buildPremiumListView(list, MediaQuery.of(context).size.width > 1100),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatWorkType(String? workType) {
    if (workType == null || workType.trim().isEmpty) return 'General Work';
    final trimmed = workType.trim();
    if (trimmed == trimmed.toUpperCase() && trimmed.length > 3) {
      return trimmed
          .split(' ')
          .map((word) => word.isNotEmpty
              ? word[0].toUpperCase() + word.substring(1).toLowerCase()
              : '')
          .join(' ');
    }
    return trimmed;
  }

  Widget _buildPremiumHeader(int count, List<String> staffNames) {
    final double width = MediaQuery.of(context).size.width;
    final bool isWide = width > 1180;
    final isVerification = widget.showOnlyVerification;
    final bool hasActiveFilters = _searchQuery.isNotEmpty || !_showOnlyMyWorks || _selectedStaffFilter != null || _selectedPeriod != 'All';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: isWide
          ? Row(
              children: [
                // Count pill
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.layers_outlined, size: 14, color: Color(0xFF475569)),
                      const SizedBox(width: 6),
                      Text(
                        '$count ${count == 1 ? 'work' : 'works'}',
                        style: const TextStyle(
                          color: Color(0xFF1E293B),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Search box
                Expanded(
                  child: _buildSearchBox(),
                ),
                const SizedBox(width: 10),
                _buildScopeSegment(),
                const SizedBox(width: 10),
                _buildStaffDropdown(staffNames),
                const SizedBox(width: 10),
                _buildPeriodDropdown(),
                const SizedBox(width: 10),
                _buildSortDropdown(),
                if (hasActiveFilters) ...[
                  const SizedBox(width: 8),
                  _buildResetButton(),
                ],
                const SizedBox(width: 12),
                Container(width: 1, height: 26, color: Colors.grey.shade200),
                const SizedBox(width: 12),
                _buildCompactViewToggle(),
                const SizedBox(width: 8),
                _buildRefreshButton(),
                if (!isVerification) ...[
                  const SizedBox(width: 8),
                  _buildCreateButton(),
                ],
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Text(
                        '$count ${count == 1 ? 'work' : 'works'}',
                        style: const TextStyle(
                          color: Color(0xFF1E293B),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const Spacer(),
                    _buildCompactViewToggle(),
                    const SizedBox(width: 8),
                    _buildRefreshButton(),
                    if (!isVerification) ...[
                      const SizedBox(width: 8),
                      _buildCreateButton(),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _buildSearchBox()),
                    const SizedBox(width: 8),
                    _buildScopeSegment(),
                    const SizedBox(width: 8),
                    _buildStaffDropdown(staffNames),
                    const SizedBox(width: 8),
                    _buildPeriodDropdown(),
                    const SizedBox(width: 8),
                    _buildSortDropdown(),
                    if (hasActiveFilters) ...[
                      const SizedBox(width: 8),
                      _buildResetButton(),
                    ],
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildRefreshButton() {
    return Tooltip(
      message: 'Refresh Works',
      child: InkWell(
        onTap: _refreshDeals,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 36,
          width: 36,
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: const Icon(Icons.refresh, size: 18, color: Color(0xFF475569)),
        ),
      ),
    );
  }

  Widget _buildResetButton() {
    return Tooltip(
      message: 'Reset Filters',
      child: InkWell(
        onTap: () {
          setState(() {
            _searchQuery = '';
            _searchController.clear();
            _showOnlyMyWorks = true;
            _selectedStaffFilter = null;
            _selectedPeriod = 'All';
          });
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.shade200),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.close, size: 14, color: Colors.red),
              const SizedBox(width: 4),
              Text('Reset', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red.shade700)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBox() {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(fontSize: 13),
        onChanged: (v) => setState(() => _searchQuery = v),
        decoration: InputDecoration(
          hintText: 'Search by client, title, file no...',
          hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
          prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF94A3B8)),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
        ),
      ),
    );
  }

  Widget _buildScopeSegment() {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _scopeOption(
            label: 'All Works',
            isSelected: !_showOnlyMyWorks,
            onTap: () {
              setState(() {
                _showOnlyMyWorks = false;
              });
            },
          ),
          _scopeOption(
            label: 'My Works',
            isSelected: _showOnlyMyWorks,
            onTap: () {
              setState(() {
                _showOnlyMyWorks = true;
                _selectedStaffFilter = null;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _scopeOption({required String label, required bool isSelected, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: isSelected
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1))]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? AppTheme.textColor : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  Widget _buildStaffDropdown(List<String> staffNames) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _selectedStaffFilter != null ? AppTheme.primaryColor : Colors.grey.shade300,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _selectedStaffFilter,
          icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF64748B), size: 20),
          hint: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person, size: 14, color: Color(0xFF64748B)),
              SizedBox(width: 5),
              Text('All Staff', style: TextStyle(fontSize: 12, color: Color(0xFF475569), fontWeight: FontWeight.w500)),
            ],
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.people, size: 14, color: Color(0xFF64748B)),
                  SizedBox(width: 6),
                  Text('All Staff', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            ...staffNames.map((name) => DropdownMenuItem<String?>(
              value: name,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 8,
                    backgroundColor: const Color(0xFFE0E7FF),
                    child: Text(name[0], style: const TextStyle(fontSize: 8, color: Color(0xFF3730A3), fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 6),
                  Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            )),
          ],
          onChanged: (val) {
            setState(() {
              _selectedStaffFilter = val;
              if (val != null) _showOnlyMyWorks = false;
            });
          },
        ),
      ),
    );
  }

  Widget _buildCreateButton() {
    return ElevatedButton.icon(
      onPressed: () => _openDealDetail(),
      icon: const Icon(Icons.add, size: 18, color: Colors.white),
      label: const Text(
        'New Work',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF00C16C),
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Widget _buildCompactViewToggle() {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'Board View',
            child: InkWell(
              onTap: () => setState(() => _isBoardView = true),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _isBoardView ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: _isBoardView
                      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1))]
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.view_kanban, size: 16, color: _isBoardView ? const Color(0xFF0F172A) : const Color(0xFF64748B)),
                    const SizedBox(width: 4),
                    Text(
                      'Board',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: _isBoardView ? FontWeight.bold : FontWeight.w500,
                        color: _isBoardView ? const Color(0xFF0F172A) : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Tooltip(
            message: 'List View',
            child: InkWell(
              onTap: () => setState(() => _isBoardView = false),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: !_isBoardView ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: !_isBoardView
                      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1))]
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.format_list_bulleted, size: 16, color: !_isBoardView ? const Color(0xFF0F172A) : const Color(0xFF64748B)),
                    const SizedBox(width: 4),
                    Text(
                      'List',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: !_isBoardView ? FontWeight.bold : FontWeight.w500,
                        color: !_isBoardView ? const Color(0xFF0F172A) : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodDropdown() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _selectedPeriod != 'All' ? const Color(0xFF6366F1) : Colors.grey.shade300,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedPeriod,
          icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF64748B), size: 20),
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF1E293B), fontWeight: FontWeight.w600),
          items: const [
            DropdownMenuItem(value: 'All', child: Text('All Periods')),
            DropdownMenuItem(value: '2026-2027', child: Text('2026-2027 (From Nov 1)')),
            DropdownMenuItem(value: '2025-2026', child: Text('2025-2026 (Till Nov 1)')),
          ],
          onChanged: (val) {
            if (val != null) setState(() => _selectedPeriod = val);
          },
        ),
      ),
    );
  }

  Widget _buildSortDropdown() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _sortOption,
          icon: const Icon(Icons.sort, color: Color(0xFF64748B), size: 18),
          items: [
            'Newest First',
            'Oldest First',
            'A-Z',
            'Z-A',
            'Highest Amount',
            'Lowest Amount',
            'Invoice No (A-Z)',
            'Legal First',
            'Consultancy First'
          ].map((String value) {
            return DropdownMenuItem<String>(
              value: value,
              child: Text(
                value,
                style: TextStyle(color: Colors.grey.shade800, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            );
          }).toList(),
          onChanged: (newValue) {
            if (newValue != null) {
              setState(() => _sortOption = newValue);
            }
          },
        ),
      ),
    );
  }

  Widget _buildPremiumListView(List<Deal> deals, bool isWide) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isWide ? 32 : 16),
      child: Column(
        children: [
          if (isWide) _buildTableHeader(isWide),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              itemCount: deals.length,
              itemBuilder: (context, index) {
                return _buildDealRow(deals[index], index, isWide);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeader(bool isWide) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text(widget.showOnlyVerification ? 'DOCUMENT' : 'DEAL NAME', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1))),
          if (widget.showOnlyVerification) ...[
            const Expanded(flex: 2, child: Text('ACTIONS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1))),
          ],
          if (!widget.showOnlyVerification) ...[
            Expanded(flex: 2, child: Text(isWide ? 'PIPELINE STAGE' : 'STAGE', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1))),
            Expanded(flex: 2, child: Text(isWide ? 'CLIENT' : 'INFO', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1))),
            if (isWide) ...[
              const Expanded(flex: 1, child: Text('DAYS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1))),
              const Expanded(flex: 1, child: Text('AMOUNT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1))),
              const Expanded(flex: 1, child: Text('LEAD', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 1))),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildDealRow(Deal deal, int index, bool isWide) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 4))],
        border: Border.all(color: Colors.black.withValues(alpha: 0.03)),
      ),
      child: InkWell(
        onTap: () => _openDealDetail(deal),
        child: isWide 
          ? Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: widget.showOnlyVerification 
                              ? _buildVerificationDocInfo(deal)
                              : Text(
                                  deal.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: Colors.black,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                          ),
                          if (deal.isAdjourned) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.amber.shade50,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.amber.shade200),
                              ),
                              child: Text(
                                'ADJOURNED',
                                style: TextStyle(
                                  color: Colors.amber.shade900,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (!widget.showOnlyVerification) ...[
                        const SizedBox(height: 4),
                        Text(deal.workType ?? 'General Work', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                      ],
                    ],
                  ),
                ),
                if (widget.showOnlyVerification) ...[
                  Expanded(
                    flex: 2,
                    child: Row(
                      children: [
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00C16C),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          ),
                          onPressed: () => _handleVerification(deal, true),
                          child: const Text('Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          ),
                          onPressed: () => _handleVerification(deal, false),
                          child: const Text('Not Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ],
                if (!widget.showOnlyVerification) ...[
                  Expanded(
                    flex: 2,
                    child: _buildStageProgress(deal.stage),
                  ),
                  Expanded(
                    flex: 2,
                    child: Row(
                      children: [
                        const Icon(Icons.person_outline_rounded, size: 14, color: Colors.grey),
                        const SizedBox(width: 8),
                        Expanded(child: Text(deal.clientName ?? 'N/A', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                  if (isWide) ...[
                    Expanded(
                      flex: 1,
                      child: _buildDaysColumn(deal),
                    ),
                    Expanded(
                      flex: 1,
                      child: Text(
                        '₹${NumberFormat('#,##,###').format(deal.amount)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF00C16C)),
                      ),
                    ),
                    Expanded(
                      flex: 1,
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 12,
                            backgroundColor: const Color(0xFF2563EB).withValues(alpha: 0.1),
                            child: Text((deal.responsibleName != null && deal.responsibleName!.isNotEmpty) ? deal.responsibleName![0].toUpperCase() : '?', style: const TextStyle(fontSize: 10, color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text((deal.responsibleName?.isNotEmpty == true) ? deal.responsibleName!.split(' ')[0] : 'N/A', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                  ],
                ],
                const SizedBox(width: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: () => _openDealDetail(deal),
                      icon: const Icon(Icons.visibility_outlined, color: Colors.green, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'View Work',
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () {
                        if (deal.driveLink != null && deal.driveLink!.isNotEmpty) {
                          try {
                            final parsed = jsonDecode(deal.driveLink!);
                            if (parsed is List && parsed.isNotEmpty) {
                              launchUrl(Uri.parse(parsed.first['url'] ?? deal.driveLink!));
                            } else {
                              launchUrl(Uri.parse(deal.driveLink!));
                            }
                          } catch (e) {
                            launchUrl(Uri.parse(deal.driveLink!));
                          }
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No documents attached')));
                        }
                      },
                      icon: const Icon(Icons.download_rounded, color: Colors.purple, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Download Documents',
                    ),
                  ],
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        deal.name,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _openDealDetail(deal),
                          icon: const Icon(Icons.visibility_outlined, color: Colors.green, size: 20),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'View Work',
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () {
                            if (deal.driveLink != null && deal.driveLink!.isNotEmpty) {
                              try {
                                final parsed = jsonDecode(deal.driveLink!);
                                if (parsed is List && parsed.isNotEmpty) {
                                  launchUrl(Uri.parse(parsed.first['url'] ?? deal.driveLink!));
                                } else {
                                  launchUrl(Uri.parse(deal.driveLink!));
                                }
                              } catch (e) {
                                launchUrl(Uri.parse(deal.driveLink!));
                              }
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No documents attached')));
                            }
                          },
                          icon: const Icon(Icons.download_rounded, color: Colors.purple, size: 20),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Download Documents',
                        ),
                      ],
                    ),
                  ],
                ),
                if (deal.isAdjourned)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.amber.shade200),
                    ),
                    child: Text(
                      'ADJOURNED',
                      style: TextStyle(color: Colors.amber.shade900, fontSize: 9, fontWeight: FontWeight.bold),
                    ),
                  ),
                if (!widget.showOnlyVerification) ...[
                  Text(deal.workType ?? 'General Work', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.person_outline_rounded, size: 14, color: Colors.grey),
                      const SizedBox(width: 8),
                      Expanded(child: Text(deal.clientName ?? 'N/A', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildStageProgress(deal.stage),
                ] else ...[
                  const SizedBox(height: 12),
                  _buildVerificationDocInfo(deal),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C16C), foregroundColor: Colors.white),
                          onPressed: () => _handleVerification(deal, true),
                          child: const Text('Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                          onPressed: () => _handleVerification(deal, false),
                          child: const Text('Not Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ]
              ],
            ),
      ),
    ).animate().fadeIn(delay: (index * 50).ms).slideX(begin: 0.1);
  }

  Widget _buildVerificationDocInfo(Deal deal) {
    List<Map<String, String>> docs = [];
    if (deal.driveLink != null && deal.driveLink!.isNotEmpty) {
      try {
        final List<dynamic> parsed = jsonDecode(deal.driveLink!);
        for (var item in parsed) {
          docs.add({"name": item["name"].toString(), "url": item["url"].toString()});
        }
      } catch (e) {
        docs.add({"name": "Connected Document", "url": deal.driveLink!});
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (docs.isEmpty)
          const Text('No Document Linked', style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold))
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: docs.map((doc) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => GoogleDocsWebviewScreen(url: doc['url']!, title: doc['name'] ?? 'Document')));
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.description_outlined, size: 16, color: Color(0xFF2563EB)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        doc['name'] ?? 'Document',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF2563EB), decoration: TextDecoration.underline),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            )).toList(),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.person_pin_circle_rounded, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              'Assigned by: ${deal.responsibleName?.split(' ')[0] ?? 'Unknown'}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDaysColumn(Deal deal) {
    if (deal.createdAt == null) {
      return Text('â€”', style: TextStyle(color: Colors.grey.shade400, fontSize: 13));
    }
    final days = DateTime.now().difference(deal.createdAt!).inDays;
    final Color bgColor;
    final Color textColor;
    if (days <= 7) {
      bgColor = const Color(0xFFDCFCE7);
      textColor = const Color(0xFF166534);
    } else if (days <= 30) {
      bgColor = const Color(0xFFFEF3C7);
      textColor = const Color(0xFF92400E);
    } else {
      bgColor = const Color(0xFFFEE2E2);
      textColor = const Color(0xFF991B1B);
    }
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            days == 0 ? 'Today' : days == 1 ? '1 day' : '$days days',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: textColor),
          ),
        ),
      ],
    );
  }

  Widget _buildStageProgress(String stage) {
    final idx = stage == 'Completed' ? Deal.stages.length : Deal.stages.indexOf(stage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(stage.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
        const SizedBox(height: 8),
        Row(
          children: List.generate(Deal.stages.length, (i) {
            final isPast = i < idx;
            final isCurrent = i == idx;
            return Expanded(
              child: Container(
                height: 4,
                margin: const EdgeInsets.only(right: 2),
                decoration: BoxDecoration(
                  color: isPast || isCurrent ? const Color(0xFF2563EB) : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    final isVerification = widget.showOnlyVerification;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 40)],
              ),
              child: Icon(
                isVerification ? Icons.verified_user_rounded : Icons.work_history_outlined,
                size: 80,
                color: const Color(0xFFD1D5DB),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              isVerification ? 'No drafts pending verification' : 'No projects found',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              isVerification
                  ? 'All peer work drafts are verified and up to date!'
                  : 'Start your first deal to see it in the pipeline tracker',
              style: const TextStyle(color: Colors.grey),
            ),
            if (!isVerification) ...[
              const SizedBox(height: 40),
              _buildCreateButton(),
            ],
          ],
        ).animate().fadeIn(duration: 600.ms).scale(begin: const Offset(0.9, 0.9)),
      ),
    );
  }

  Color _getStageColor(String stage) {
    switch (stage.toLowerCase()) {
      case 'active':
        return const Color(0xFF2563EB); // Royal Blue
      case 'registration':
        return const Color(0xFF6366F1); // Indigo
      case 'contact customer':
        return const Color(0xFFD97706); // Amber
      case 'work started':
        return const Color(0xFF0D9488); // Teal
      case 'in progress':
        return const Color(0xFFEA580C); // Orange
      case 'verification':
        return const Color(0xFF9333EA); // Purple
      case 'invoice':
        return const Color(0xFF0284C7); // Sky Blue
      case 'billing status':
        return const Color(0xFF4F46E5); // Violet
      case 'close deal':
      case 'completed':
        return const Color(0xFF16A34A); // Emerald
      default:
        return const Color(0xFF64748B); // Slate
    }
  }

  Widget _buildBoardView(List<Deal> deals, bool isWide) {
    List<String> visibleStages = widget.showOnlyVerification ? ['Verification'] : List.from(Deal.stages);
    
    if (!widget.showOnlyVerification) {
      final existingStages = deals.map((d) => d.stage).toSet();
      final unknownStages = existingStages.where((s) => !visibleStages.contains(s)).toList();
      unknownStages.sort();
      visibleStages.insertAll(0, unknownStages);
    }

    return RawScrollbar(
      controller: _boardScrollController,
      thumbVisibility: true,
      thickness: 6,
      radius: const Radius.circular(4),
      thumbColor: Colors.grey.shade400.withValues(alpha: 0.6),
      child: SingleChildScrollView(
        controller: _boardScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(left: 4, right: 16, bottom: 8, top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: visibleStages.map((stage) {
            final stageDeals = deals.where((d) => d.stage == stage).toList();
            return _buildBoardColumn(stage, stageDeals);
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildBoardColumn(String stage, List<Deal> stageDeals) {
    final stageColor = _getStageColor(stage);

    return DragTarget<Deal>(
      onWillAcceptWithDetails: (details) => details.data.stage != stage,
      onAcceptWithDetails: (details) async {
        final deal = details.data;
        // Optimistic UI update to prevent snap-back
        setState(() {
          final index = _allDeals.indexWhere((d) => d.id == deal.id);
          if (index != -1) {
            _allDeals[index] = deal.copyWith(stage: stage);
          }
        });
        
        try {
          await _dealService.moveDealToStage(deal.id!, deal.stage, stage);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Moved to $stage'), backgroundColor: Colors.green),
            );
          }
        } catch (e) {
          // Revert on error
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
            );
            _refreshDeals();
          }
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        return Container(
          width: 295,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: isHovering ? const Color(0xFFECFDF5) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isHovering ? const Color(0xFF10B981) : const Color(0xFFE2E8F0),
              width: isHovering ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
                  border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: stageColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        stage,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: stageColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${stageDeals.length}',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: stageColor),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: stageDeals.isEmpty
                    ? Center(
                        child: Text(
                          'No works in this stage',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade400, fontStyle: FontStyle.italic),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(10),
                        itemCount: stageDeals.length,
                        itemBuilder: (context, index) {
                          final deal = stageDeals[index];
                          return Draggable<Deal>(
                            data: deal,
                            feedback: Material(
                              elevation: 8,
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              child: SizedBox(
                                width: 280,
                                child: _buildBoardCard(deal),
                              ),
                            ),
                            childWhenDragging: Opacity(
                              opacity: 0.3,
                              child: _buildBoardCard(deal),
                            ),
                            child: _buildBoardCard(deal),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBoardCard(Deal deal) {
    final days = deal.createdAt != null ? DateTime.now().difference(deal.createdAt!).inDays : null;
    final currentIndex = Deal.stages.indexOf(deal.stage);
    final String? nextStage = (currentIndex != -1 && currentIndex < Deal.stages.length - 1)
        ? Deal.stages[currentIndex + 1]
        : (currentIndex == -1 ? Deal.stages.first : null);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _openDealDetail(deal),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Row: Work Type & Priority/Age Tag
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _formatWorkType(deal.workType),
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (deal.pipeline.toLowerCase() == 'crm') ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF86EFAC)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified, size: 10, color: Color(0xFF16A34A)),
                            SizedBox(width: 3),
                            Text(
                              'CRM',
                              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF166534)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (deal.isAdjourned)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'Adjourned',
                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF92400E)),
                        ),
                      )
                    else if (deal.priority == 'Urgent')
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '🔥 Urgent',
                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF991B1B)),
                        ),
                      )
                    else if (deal.priority == 'High')
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '⚡ High',
                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF92400E)),
                        ),
                      )
                    else if (days != null)
                      Text(
                        days == 0 ? 'Today' : '${days}d ago',
                        style: TextStyle(
                          fontSize: 10,
                          color: days > 20 ? Colors.red.shade700 : Colors.grey.shade500,
                          fontWeight: days > 20 ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                // Deal Title
                Text(
                  deal.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: Color(0xFF0F172A),
                    height: 1.25,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                // Client row
                if (deal.clientName != null && deal.clientName!.trim().isNotEmpty) ...[
                  Row(
                    children: [
                      const Icon(Icons.person_outline, size: 14, color: Color(0xFF64748B)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          deal.clientName!,
                          style: const TextStyle(fontSize: 12, color: Color(0xFF475569), fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (deal.registerNo != null && deal.registerNo!.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(left: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '#${deal.registerNo}',
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                // Amount & Staff Info Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      deal.amount > 0 ? '₹${NumberFormat('#,##,###').format(deal.amount)}' : '₹0',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: deal.amount > 0 ? const Color(0xFF059669) : Colors.grey.shade400,
                      ),
                    ),
                    if (deal.responsibleName != null && deal.responsibleName!.trim().isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 9,
                            backgroundColor: const Color(0xFFE0E7FF),
                            child: Text(
                              deal.responsibleName![0].toUpperCase(),
                              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF3730A3)),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            deal.responsibleName!.split(' ').first,
                            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Divider(height: 1, color: Colors.grey.shade100),
                const SizedBox(height: 6),
                // Quick Action Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _quickCardAction(
                      icon: Icons.edit_note,
                      label: 'Note',
                      tooltip: 'Add Quick Note',
                      onTap: () => _showQuickNoteDialog(deal),
                    ),
                    if (nextStage != null)
                      _quickCardAction(
                        icon: Icons.arrow_forward,
                        label: 'Advance',
                        tooltip: 'Move to $nextStage',
                        isPrimary: true,
                        onTap: () => _advanceDeal(deal),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle, size: 12, color: Color(0xFF166534)),
                            SizedBox(width: 3),
                            Text('Done', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF166534))),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _quickCardAction({
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback onTap,
    bool isPrimary = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isPrimary ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: isPrimary ? const Color(0xFFBBF7D0) : const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: isPrimary ? const Color(0xFF16A34A) : const Color(0xFF64748B)),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isPrimary ? const Color(0xFF16A34A) : const Color(0xFF475569),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  Future<void> _advanceDeal(Deal deal) async {
    final currentIndex = Deal.stages.indexOf(deal.stage);
    final String nextStage;
    if (currentIndex == -1) {
      nextStage = Deal.stages.first;
    } else if (currentIndex < Deal.stages.length - 1) {
      nextStage = Deal.stages[currentIndex + 1];
    } else {
      return;
    }

    // Optimistic UI update
    setState(() {
      final idx = _allDeals.indexWhere((d) => d.id == deal.id);
      if (idx != -1) {
        _allDeals[idx] = deal.copyWith(stage: nextStage);
      }
    });

    try {
      await _dealService.moveDealToStage(deal.id!, deal.stage, nextStage);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moved "${deal.name}" to $nextStage'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
        _refreshDeals();
      }
    }
  }

  Future<void> _showQuickNoteDialog(Deal deal) async {
    final _noteController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Quick Note'),
        content: TextField(
          controller: _noteController,
          decoration: const InputDecoration(hintText: 'Type your note here...', border: OutlineInputBorder()),
          maxLines: 3,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          TextButton(
            onPressed: () async {
              if (_noteController.text.trim().isNotEmpty) {
                try {
                  await _dealService.addActivity(DealActivity(
                    dealId: deal.id!,
                    type: 'note',
                    title: 'Quick Note',
                    description: _noteController.text.trim(),
                    createdBy: _currentUserId ?? 1,
                  ));
                  if (mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Note added'), backgroundColor: Colors.green));
                  }
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
                }
              }
            },
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
  }
}



