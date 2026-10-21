import 'dart:convert';

import 'package:doc_engine/doc_engine.dart';

/// A delta between two versions of the same [Document], computed by ID.
///
/// Carries exactly what [apply] needs to turn the base into the target:
/// - title change (flag + value);
/// - final metadata: `updatedAtMs`, `deletedAtMs`, `syncStatus`;
/// - sections added wholesale, sections removed by ID;
/// - blocks upserted (new or content-changed, full copies) and removed
///   by ID, per existing section;
/// - target section order / per-section block order, when they differ.
///
/// Deterministic: collections are emitted in target document order, and
/// block comparison uses the model's canonical JSON.
class DocumentDelta {
  DocumentDelta({
    required this.documentId,
    required this.titleChanged,
    required this.newTitle,
    required this.updatedAtMs,
    required this.deletedAtMs,
    required this.syncStatus,
    required this.addedSections,
    required this.removedSectionIds,
    required this.blockUpserts,
    required this.removedBlockIds,
    required this.sectionOrder,
    required this.blockOrders,
  });

  final String documentId;
  final bool titleChanged;
  final String? newTitle;

  /// Final metadata of the target version (always carried).
  final int updatedAtMs;
  final int? deletedAtMs;
  final SyncStatus syncStatus;

  /// Sections present in the target but not the base (full copies).
  final List<Section> addedSections;

  /// Section IDs present in the base but not the target.
  final List<String> removedSectionIds;

  /// Per section ID (existing sections only): blocks that are new or
  /// whose canonical JSON changed.
  final Map<String, List<Block>> blockUpserts;

  /// Per section ID (existing sections only): block IDs removed.
  final Map<String, List<String>> removedBlockIds;

  /// Target section ID order, or null when unchanged from base.
  final List<String>? sectionOrder;

  /// Per section ID: target block ID order, when it differs from base.
  final Map<String, List<String>> blockOrders;

  /// True when nothing but (possibly) metadata differs.
  bool get isContentEmpty =>
      !titleChanged &&
      addedSections.isEmpty &&
      removedSectionIds.isEmpty &&
      blockUpserts.values.every((l) => l.isEmpty) &&
      removedBlockIds.values.every((l) => l.isEmpty) &&
      sectionOrder == null &&
      blockOrders.isEmpty;

  /// Computes the delta that turns [base] into [target].
  /// Both must be versions of the same document (same `id`).
  static DocumentDelta compute(Document base, Document target) {
    if (base.id != target.id) {
      throw ArgumentError('Delta requires two versions of one document: '
          '${base.id} vs ${target.id}');
    }
    String blockJson(Block b) => jsonEncode(b.toJson());

    final baseSections = <String, Section>{
      for (final s in base.sections) s.id: s,
    };
    final targetSections = <String, Section>{
      for (final s in target.sections) s.id: s,
    };

    final addedSections = <Section>[
      for (final s in target.sections)
        if (!baseSections.containsKey(s.id)) s.copy(),
    ];
    final removedSectionIds = <String>[
      for (final s in base.sections)
        if (!targetSections.containsKey(s.id)) s.id,
    ];

    final blockUpserts = <String, List<Block>>{};
    final removedBlockIds = <String, List<String>>{};
    final blockOrders = <String, List<String>>{};

    for (final targetSection in target.sections) {
      final baseSection = baseSections[targetSection.id];
      if (baseSection == null) continue; // added wholesale above
      final baseBlocks = <String, Block>{
        for (final b in baseSection.blocks) b.id: b,
      };
      final upserts = <Block>[
        for (final b in targetSection.blocks)
          if (!baseBlocks.containsKey(b.id) ||
              blockJson(baseBlocks[b.id]!) != blockJson(b))
            b.copy(),
      ];
      if (upserts.isNotEmpty) blockUpserts[targetSection.id] = upserts;

      final targetBlockIds = targetSection.blocks.map((b) => b.id).toSet();
      final removed = <String>[
        for (final b in baseSection.blocks)
          if (!targetBlockIds.contains(b.id)) b.id,
      ];
      if (removed.isNotEmpty) removedBlockIds[targetSection.id] = removed;

      final baseOrder = baseSection.blocks.map((b) => b.id).toList();
      final targetOrder = targetSection.blocks.map((b) => b.id).toList();
      if (!_listEquals(baseOrder, targetOrder)) {
        blockOrders[targetSection.id] = targetOrder;
      }
    }

    final baseSectionOrder = base.sections.map((s) => s.id).toList();
    final targetSectionOrder = target.sections.map((s) => s.id).toList();

    return DocumentDelta(
      documentId: target.id,
      titleChanged: base.title != target.title,
      newTitle: base.title != target.title ? target.title : null,
      updatedAtMs: target.updatedAtMs,
      deletedAtMs: target.deletedAtMs,
      syncStatus: target.syncStatus,
      addedSections: addedSections,
      removedSectionIds: removedSectionIds,
      blockUpserts: blockUpserts,
      removedBlockIds: removedBlockIds,
      sectionOrder: _listEquals(baseSectionOrder, targetSectionOrder)
          ? null
          : targetSectionOrder,
      blockOrders: blockOrders,
    );
  }

  /// Applies this delta to [base] and returns the resulting document.
  /// [base] is not mutated. The result reproduces the compute-target
  /// exactly (verified by canonical JSON in tests).
  Document apply(Document base) {
    if (base.id != documentId) {
      throw ArgumentError('Delta for $documentId cannot apply to ${base.id}');
    }
    final result = base.copy();
    if (titleChanged) result.title = newTitle!;
    result.updatedAtMs = updatedAtMs;
    result.deletedAtMs = deletedAtMs;
    result.syncStatus = syncStatus;

    result.sections.removeWhere((s) => removedSectionIds.contains(s.id));
    for (final added in addedSections) {
      result.sections.removeWhere((s) => s.id == added.id);
      result.sections.add(added.copy());
    }

    for (final section in result.sections) {
      final removed = removedBlockIds[section.id];
      if (removed != null) {
        section.blocks.removeWhere((b) => removed.contains(b.id));
      }
      final upserts = blockUpserts[section.id];
      if (upserts != null) {
        for (final upsert in upserts) {
          final idx = section.blocks.indexWhere((b) => b.id == upsert.id);
          if (idx >= 0) {
            section.blocks[idx] = upsert.copy();
          } else {
            section.blocks.add(upsert.copy());
          }
        }
      }
      final order = blockOrders[section.id];
      if (order != null) {
        section.blocks = _reorder(section.blocks, order, (b) => b.id);
      }
    }

    if (sectionOrder != null) {
      result.sections = _reorder(result.sections, sectionOrder!, (s) => s.id);
    }
    return result;
  }

  static List<T> _reorder<T>(List<T> items, List<String> order,
      String Function(T) idOf) {
    final byId = <String, T>{for (final item in items) idOf(item): item};
    final out = <T>[
      for (final id in order)
        if (byId.containsKey(id)) byId[id] as T,
    ];
    // Anything not named in the order keeps its relative place at the end.
    final named = order.toSet();
    out.addAll(items.where((item) => !named.contains(idOf(item))));
    return out;
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Canonical JSON for a document, used for change detection everywhere
/// in this package.
String documentJson(Document doc) => jsonEncode(doc.toJson());

/// Canonical JSON with `sync_status` normalised away, so two versions
/// that differ only in sync lifecycle compare equal. Content, titles,
/// structure and timestamps still count.
String documentContentJson(Document doc) {
  final json = doc.toJson();
  json['sync_status'] = 'synced';
  return jsonEncode(json);
}
