# Golden vectors — how they were generated

`document.json` and `document.md` are **not hand-written**. They were
produced by the real Dart `doc_engine` (the reference implementation)
with a throwaway Dart script run on 2026-10-21, then deleted:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:doc_engine/doc_engine.dart';

void main() {
  final doc = Document(
    id: 'doc-1',
    title: 'Spec',
    createdAtMs: 1000,
    updatedAtMs: 1000,
    deletedAtMs: null,
    syncStatus: SyncStatus.localOnly,
    sections: [
      Section(id: 'sec-1', blocks: [
        Block(id: 'blk-1', type: BlockType.heading1,
            inlines: [InlineNode('Intro')]),
        Block(id: 'blk-2', type: BlockType.paragraph, inlines: [
          InlineNode('Hello', {Mark.bold}),
          InlineNode(' world'),
        ]),
        Block(id: 'blk-3', type: BlockType.bullet,
            inlines: [InlineNode('Item one')]),
      ]),
    ],
  );
  // jsonEncode output exactly, no trailing newline.
  File('document.json').writeAsStringSync(jsonEncode(doc.toJson()));
  // MarkdownExporter output; ends with exactly one newline.
  File('document.md')
      .writeAsStringSync(const MarkdownExporter().export(doc));
}
```

Run it (from a scratch directory, not inside `packages/`) with:

```sh
dart --packages=packages/doc_engine/.dart_tool/package_config.json <script.dart>
```

writing into `rust/golden/`. If the Dart serialization format changes,
regenerate these files in the same change and update the Rust model to
match — the Rust golden tests must stay byte-exact.
