import 'dart:async';

import 'package:doc_engine/doc_engine.dart';
import 'package:flutter/material.dart';

/// Minimal editor shell over [DocumentEditor].
///
/// Progressive disclosure (UX.md): the formatting bar exists only while a
/// block has focus. Saving is local-only and debounced; the app bar always
/// shows the save state. Export opens a sheet; Markdown is the Slice-1
/// path, other formats are shown disabled rather than faked.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.store, required this.document});

  final DocumentStore store;
  final Document document;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

enum _SaveState { saved, saving, failed }

class _EditorScreenState extends State<EditorScreen> {
  late final DocumentEditor _editor;
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  String? _focusedBlockId;
  Timer? _debounce;
  _SaveState _saveState = _SaveState.saved;

  @override
  void initState() {
    super.initState();
    _editor = DocumentEditor(
      widget.document,
      ids: SequentialIdGenerator(),
      clockMs: () => DateTime.now().millisecondsSinceEpoch,
    );
    for (final block in _editor.document.allBlocks) {
      _controllers[block.id] =
          TextEditingController(text: block.plainText);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onBlockChanged(String blockId, String newText) {
    final block = _editor.document.blockById(blockId);
    if (block == null) return;
    // Shell-level editing: replace the block's text wholesale, preserving
    // the first run's marks. Selection-level mark application lands with
    // the native selection work in Phase 1; the engine already supports
    // it and is unit-tested.
    final marks =
        block.inlines.isNotEmpty ? block.inlines.first.marks : const <Mark>{};
    block.inlines = <InlineNode>[InlineNode(newText, marks)];
    _scheduleSave();
  }

  void _scheduleSave() {
    setState(() => _saveState = _SaveState.saving);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _saveNow);
  }

  Future<void> _saveNow() async {
    try {
      _editor.document.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      await widget.store.save(_editor.document);
      if (mounted) setState(() => _saveState = _SaveState.saved);
    } catch (_) {
      if (mounted) setState(() => _saveState = _SaveState.failed);
    }
  }

  void _applyMarkToFocused(Mark mark) {
    final id = _focusedBlockId;
    if (id == null) return;
    final block = _editor.document.blockById(id);
    if (block == null || block.plainText.isEmpty) return;
    _editor.applyMark(id, 0, block.plainText.runes.length, mark, true);
    _scheduleSave();
    setState(() {});
  }

  Future<void> _exportSheet() async {
    final markdown = const MarkdownExporter().export(_editor.document);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Markdown (.md)'),
              subtitle: const Text('Available'),
              onTap: () {
                Navigator.of(context).pop();
                showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Markdown export'),
                    content: SingleChildScrollView(child: Text(markdown)),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              },
            ),
            const ListTile(
              leading: Icon(Icons.picture_as_pdf_outlined),
              title: Text('PDF'),
              subtitle: Text('Not available yet'),
              enabled: false,
            ),
            const ListTile(
              leading: Icon(Icons.article_outlined),
              title: Text('DOCX'),
              subtitle: Text('Not available yet'),
              enabled: false,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final blocks = _editor.document.allBlocks.toList();
    final saveLabel = switch (_saveState) {
      _SaveState.saved => 'Saved on device',
      _SaveState.saving => 'Saving…',
      _SaveState.failed => 'Save failed',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.document.title),
        actions: <Widget>[
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(saveLabel,
                  style: Theme.of(context).textTheme.labelMedium),
            ),
          ),
          if (_saveState == _SaveState.failed)
            IconButton(
              onPressed: _saveNow,
              icon: const Icon(Icons.refresh),
              tooltip: 'Retry save',
            ),
          IconButton(
            onPressed: () async {
              if (_editor.undo()) {
                for (final b in _editor.document.allBlocks) {
                  _controllers[b.id]?.text = b.plainText;
                }
                _scheduleSave();
                setState(() {});
              }
            },
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
          ),
          IconButton(
            onPressed: _exportSheet,
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: blocks.length,
              itemBuilder: (context, i) {
                final block = blocks[i];
                final controller = _controllers.putIfAbsent(
                  block.id,
                  () => TextEditingController(text: block.plainText),
                );
                final style = switch (block.type) {
                  BlockType.heading1 =>
                    Theme.of(context).textTheme.headlineSmall,
                  BlockType.heading2 =>
                    Theme.of(context).textTheme.titleLarge,
                  _ => Theme.of(context).textTheme.bodyLarge,
                };
                return Focus(
                  onFocusChange: (hasFocus) {
                    if (hasFocus) {
                      setState(() => _focusedBlockId = block.id);
                    }
                  },
                  child: TextField(
                    controller: controller,
                    style: style,
                    maxLines: null,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Write…',
                    ),
                    onChanged: (text) => _onBlockChanged(block.id, text),
                  ),
                );
              },
            ),
          ),
          // Contextual formatting bar: visible only with a focused block.
          if (_focusedBlockId != null)
            SafeArea(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  IconButton(
                    onPressed: () => _applyMarkToFocused(Mark.bold),
                    icon: const Icon(Icons.format_bold),
                    tooltip: 'Bold (whole block in Slice 1 shell)',
                  ),
                  IconButton(
                    onPressed: () => _applyMarkToFocused(Mark.italic),
                    icon: const Icon(Icons.format_italic),
                    tooltip: 'Italic (whole block in Slice 1 shell)',
                  ),
                  IconButton(
                    onPressed: () {
                      final id = _focusedBlockId!;
                      const order = BlockType.values;
                      final current =
                          _editor.document.blockById(id)?.type ??
                              BlockType.paragraph;
                      final next =
                          order[(order.indexOf(current) + 1) % order.length];
                      _editor.setBlockType(id, next);
                      _scheduleSave();
                      setState(() {});
                    },
                    icon: const Icon(Icons.format_size),
                    tooltip: 'Cycle block style',
                  ),
                  IconButton(
                    onPressed: () {
                      final newId = _editor.insertBlock(
                          afterBlockId: _focusedBlockId);
                      _controllers[newId] = TextEditingController();
                      _scheduleSave();
                      setState(() => _focusedBlockId = newId);
                    },
                    icon: const Icon(Icons.add),
                    tooltip: 'Add block below',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
