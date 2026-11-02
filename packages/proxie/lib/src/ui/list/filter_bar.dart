import 'package:flutter/material.dart';

import 'package:proxie/src/storage/call_query.dart';
import 'package:proxie/src/ui/list/list_controller.dart';

/// The search box and filter chips above the call list.
///
/// Chips: All (clears every chip filter), JSON, Errors, `Hide > N MB` (N from
/// [renderCap]), Hide binary, one per method in [methods], and one per
/// adapter in [adapterNames] when there are at least two. Typing searches
/// through [ListController.search], so queries wait for a pause.
class FilterBar extends StatefulWidget {
  /// Creates the bar that edits [controller]'s query.
  const FilterBar({
    required this.controller,
    required this.renderCap,
    super.key,
    this.adapterNames = const [],
  });

  /// The list whose query the bar edits.
  final ListController controller;

  /// The render cap in bytes; the size chip hides larger responses.
  final int renderCap;

  /// Names of the attached adapters.
  final List<String> adapterNames;

  /// The methods that get a chip.
  static const List<String> methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

  @override
  State<FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<FilterBar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  ListController get _controller => widget.controller;

  static Set<String> _toggle(Set<String> set, String value) =>
      set.contains(value) ? ({...set}..remove(value)) : {...set, value};

  String get _capLabel {
    final mb = widget.renderCap / (1024 * 1024);
    final n = mb == mb.roundToDouble()
        ? mb.toStringAsFixed(0)
        : mb.toStringAsFixed(1);
    return 'Hide > $n MB';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final q = _controller.query;
      final noChips =
          q.status == StatusFilter.all &&
          !q.onlyJson &&
          !q.hideBinary &&
          q.maxSize == null &&
          q.methods.isEmpty &&
          q.adapters.isEmpty;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _search,
              onChanged: _controller.search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search URL or body',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: ListenableBuilder(
                  listenable: _search,
                  builder: (context, _) => _search.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _search.clear();
                            _controller.clearSearch();
                          },
                        ),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(
              children: [
                _chip(
                  'All',
                  selected: noChips,
                  onTap: () {
                    _controller.query = q.copyWith(
                      status: StatusFilter.all,
                      onlyJson: false,
                      hideBinary: false,
                      clearMaxSize: true,
                      methods: const {},
                      adapters: const {},
                    );
                  },
                ),
                _chip(
                  'JSON',
                  selected: q.onlyJson,
                  onTap: () =>
                      _controller.query = q.copyWith(onlyJson: !q.onlyJson),
                ),
                _chip(
                  'Errors',
                  selected: q.status == StatusFilter.errors,
                  onTap: () => _controller.query = q.copyWith(
                    status: q.status == StatusFilter.errors
                        ? StatusFilter.all
                        : StatusFilter.errors,
                  ),
                ),
                _chip(
                  _capLabel,
                  selected: q.maxSize != null,
                  onTap: () => _controller.query = q.maxSize == null
                      ? q.copyWith(maxSize: widget.renderCap)
                      : q.copyWith(clearMaxSize: true),
                ),
                _chip(
                  'Hide binary',
                  selected: q.hideBinary,
                  onTap: () =>
                      _controller.query = q.copyWith(hideBinary: !q.hideBinary),
                ),
                for (final m in FilterBar.methods)
                  _chip(
                    m,
                    selected: q.methods.contains(m),
                    onTap: () => _controller.query = q.copyWith(
                      methods: _toggle(q.methods, m),
                    ),
                  ),
                if (widget.adapterNames.length > 1)
                  for (final a in widget.adapterNames)
                    _chip(
                      a,
                      selected: q.adapters.contains(a),
                      onTap: () => _controller.query = q.copyWith(
                        adapters: _toggle(q.adapters, a),
                      ),
                    ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _chip(
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => onTap(),
    ),
  );
}
