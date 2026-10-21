import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme.dart';

class MenuItem {
  final int index;
  final IconData icon;
  final String label;

  MenuItem(this.index, this.icon, this.label);
}

class MenuCategory {
  final String title;
  final List<MenuItem> items;

  MenuCategory(this.title, this.items);
}

class DashboardMenuGrid extends StatefulWidget {
  final int selectedIndex;
  final Function(int) onItemSelected;
  final VoidCallback? onBackPressed;

  DashboardMenuGrid({
    super.key,
    required this.selectedIndex,
    required this.onItemSelected,
    this.onBackPressed,
  });

  @override
  State<DashboardMenuGrid> createState() => _DashboardMenuGridState();
}

class _DashboardMenuGridState extends State<DashboardMenuGrid> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  final List<MenuCategory> _allCategories = [
    MenuCategory('Core Operations', [
      MenuItem(0, Icons.insights_rounded, 'Operations Overview'),
      MenuItem(12, Icons.playlist_add_check_rounded, 'Today\'s Task'),
      MenuItem(1, Icons.design_services_outlined, 'Service Checklist'),
      MenuItem(23, Icons.menu_book_rounded, 'SOP'),
      MenuItem(6, Icons.work_rounded, 'Work Management'),
      MenuItem(13, Icons.rate_review_rounded, 'Verification'),
      MenuItem(20, Icons.history_rounded, 'Verification History'),
    ]),
    MenuCategory('Clients & Contacts', [
      MenuItem(3, Icons.people_alt_rounded, 'Client Data'),
      MenuItem(31, Icons.hub_rounded, 'CRM'),
      MenuItem(25, Icons.contacts_rounded, 'Contact Book'),
      MenuItem(26, Icons.help_center_rounded, 'Client Help & Queries'),
      MenuItem(22, Icons.handshake_rounded, 'File Acknowledgement'),
    ]),
    MenuCategory('Finance & Accounting', [
      MenuItem(4, Icons.receipt_long_rounded, 'Billing'),
      MenuItem(11, Icons.account_balance_wallet_rounded, 'Accounting & Pay'),
    ]),
    MenuCategory('Documents & Files', [
      MenuItem(24, Icons.folder_shared_rounded, 'Work File'),
      MenuItem(19, Icons.cloud_sync, 'Google Docs Vault'),
      MenuItem(29, Icons.format_list_bulleted_rounded, 'Formats'),
    ]),
    MenuCategory('Tools & Utilities', [
      MenuItem(5, Icons.verified_user_rounded, 'Licences'),
      MenuItem(9, Icons.vpn_key_rounded, 'Digital Signature'),
      MenuItem(8, Icons.task_alt_rounded, 'Deliveries and Pickup'),
      MenuItem(17, Icons.calendar_month_rounded, 'Reminder Calendar'),
      MenuItem(14, Icons.table_view_rounded, 'Upload Table'),
      MenuItem(18, Icons.mark_email_unread_rounded, 'Post Register'),
    ]),
    MenuCategory('HR & Office', [
      MenuItem(2, Icons.people_outline_rounded, 'Staff Management'),
      MenuItem(28, Icons.analytics_rounded, 'Staff Performance'),
      MenuItem(30, Icons.access_time_rounded, 'Attendance'),
      MenuItem(10, Icons.chat_bubble_outline_rounded, 'Staff Chat'),
      MenuItem(16, Icons.directions_car_filled_outlined, 'Travel Logs'),
      MenuItem(21, Icons.real_estate_agent_rounded, 'Property Management'),
      MenuItem(27, Icons.business_rounded, 'Office Details'),
    ]),
    MenuCategory('System', [
      MenuItem(7, Icons.settings_rounded, 'Settings'),
      MenuItem(99, Icons.logout_rounded, 'Exit Admin'),
    ]),
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Filter categories based on search query
    List<MenuCategory> displayCategories = [];
    if (_searchQuery.isEmpty) {
      displayCategories = _allCategories;
    } else {
      for (var cat in _allCategories) {
        final filteredItems = cat.items.where((item) => 
          item.label.toLowerCase().contains(_searchQuery.toLowerCase())
        ).toList();
        
        if (filteredItems.isNotEmpty) {
          displayCategories.add(MenuCategory(cat.title, filteredItems));
        }
      }
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D12),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 30, 40, 0),
            child: Row(
              children: [
                if (widget.onBackPressed != null) ...[
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                      onPressed: widget.onBackPressed,
                      tooltip: 'Back',
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: TextField(
                      controller: _searchCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search modules...',
                        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                        prefixIcon: Icon(Icons.search_rounded, color: AppTheme.primaryColor),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        suffixIcon: _searchQuery.isNotEmpty 
                          ? IconButton(
                              icon: const Icon(Icons.close_rounded, color: Colors.white60),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      ),
                      onChanged: (value) => setState(() => _searchQuery = value),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: displayCategories.isEmpty
              ? const Center(
                  child: Text(
                    'No modules found.',
                    style: TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
                  itemCount: displayCategories.length,
                  itemBuilder: (context, index) {
                    final category = displayCategories[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(bottom: 24, top: index == 0 ? 0 : 32),
                          child: Row(
                            children: [
                              Container(
                                width: 4,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryColor,
                                  borderRadius: BorderRadius.circular(4),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppTheme.primaryColor.withValues(alpha: 0.5),
                                      blurRadius: 8,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                category.title.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: 2.0,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Wrap(
                          spacing: 20,
                          runSpacing: 20,
                          children: category.items.map((item) => _HoverableMenuItem(
                            item: item,
                            onTap: () => widget.onItemSelected(item.index),
                          )).toList(),
                        ),
                        const SizedBox(height: 24),
                        if (index < displayCategories.length - 1)
                          Divider(
                            color: Colors.white.withValues(alpha: 0.05),
                            thickness: 1,
                            height: 1,
                          ),
                      ],
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }
}

class _HoverableMenuItem extends StatefulWidget {
  final MenuItem item;
  final VoidCallback onTap;

  const _HoverableMenuItem({required this.item, required this.onTap});

  @override
  State<_HoverableMenuItem> createState() => _HoverableMenuItemState();
}

class _HoverableMenuItemState extends State<_HoverableMenuItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          width: 150,
          height: 130,
          transform: Matrix4.identity()
            ..scale(_isHovered ? 1.05 : 1.0)
            ..translate(_isHovered ? 0.0 : 0.0, _isHovered ? -4.0 : 0.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: _isHovered ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.03),
            border: Border.all(
              color: _isHovered 
                ? AppTheme.primaryColor.withValues(alpha: 0.5) 
                : Colors.white.withValues(alpha: 0.05),
              width: 1.5,
            ),
            boxShadow: [
              if (_isHovered)
                BoxShadow(
                  color: AppTheme.primaryColor.withValues(alpha: 0.15),
                  blurRadius: 20,
                  spreadRadius: 2,
                  offset: const Offset(0, 8),
                ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      // Subtle glowing orb behind the icon
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOutCubic,
                        width: _isHovered ? 75 : 60,
                        height: _isHovered ? 75 : 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.primaryColor.withValues(alpha: _isHovered ? 0.15 : 0.05),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primaryColor.withValues(alpha: _isHovered ? 0.4 : 0.0),
                              blurRadius: 25,
                              spreadRadius: _isHovered ? 8 : 0,
                            ),
                          ],
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        padding: EdgeInsets.all(_isHovered ? 14 : 12),
                        decoration: BoxDecoration(
                          color: _isHovered 
                              ? AppTheme.primaryColor.withValues(alpha: 0.2) 
                              : AppTheme.primaryColor.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppTheme.primaryColor.withValues(alpha: _isHovered ? 0.5 : 0.0),
                            width: 1,
                          ),
                        ),
                        child: Icon(
                          widget.item.icon,
                          color: _isHovered ? Colors.white : AppTheme.primaryColor,
                          size: _isHovered ? 30 : 26,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 300),
                      style: TextStyle(
                        color: _isHovered ? Colors.white : Colors.white70,
                        fontSize: 12,
                        fontWeight: _isHovered ? FontWeight.bold : FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                      textAlign: TextAlign.center,
                      child: Text(widget.item.label),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
