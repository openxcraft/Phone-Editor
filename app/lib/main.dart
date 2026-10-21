import 'package:doc_engine/doc_engine.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'editor_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  final store = SqliteDocumentStore(p.join(dir.path, 'workspace.db'));
  runApp(WorkspaceApp(store: store));
}

/// Calm, neutral shell. One primary action per screen; advanced tools are
/// contextual (see UX.md). No gradients, no decorative iconography.
class WorkspaceApp extends StatelessWidget {
  const WorkspaceApp({super.key, required this.store});

  final DocumentStore store;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3E4A59), // single neutral slate accent
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3E4A59),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Workspace',
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      darkTheme: ThemeData(colorScheme: darkScheme, useMaterial3: true),
      home: DocumentListScreen(store: store),
    );
  }
}

class DocumentListScreen extends StatefulWidget {
  const DocumentListScreen({super.key, required this.store});

  final DocumentStore store;

  @override
  State<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends State<DocumentListScreen> {
  late Future<List<Document>> _docs;

  @override
  void initState() {
    super.initState();
    _docs = widget.store.list();
  }

  Future<void> _create() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final editor = DocumentEditor.newDocument(
      ids: SequentialIdGenerator(),
      title: 'Untitled',
      nowMs: now,
    );
    // Sequential IDs are deterministic for tests; the shell namespaces
    // document IDs by creation time to avoid collisions between sessions.
    final doc = Document(
      id: 'doc-$now',
      title: editor.document.title,
      createdAtMs: now,
      updatedAtMs: now,
      sections: editor.document.sections,
    );
    await widget.store.save(doc);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditorScreen(store: widget.store, document: doc),
      ),
    );
    setState(() => _docs = widget.store.list());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Documents')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New document'),
      ),
      body: FutureBuilder<List<Document>>(
        future: _docs,
        builder: (context, snapshot) {
          final docs = snapshot.data ?? const <Document>[];
          if (docs.isEmpty) {
            return const Center(child: Text('No documents yet.'));
          }
          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final doc = docs[i];
              final edited =
                  DateTime.fromMillisecondsSinceEpoch(doc.updatedAtMs);
              return ListTile(
                title: Text(doc.title),
                subtitle: Text('Edited ${edited.toLocal()}'),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          EditorScreen(store: widget.store, document: doc),
                    ),
                  );
                  setState(() => _docs = widget.store.list());
                },
              );
            },
          );
        },
      ),
    );
  }
}
