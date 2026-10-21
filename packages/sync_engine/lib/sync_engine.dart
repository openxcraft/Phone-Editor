/// Offline-first sync primitives: RGA text CRDT, document delta sync,
/// field-level merge with conflict copies, and a resumable, cancellable
/// sync session against an in-memory reference server.
///
/// Deterministic by construction: no clocks, no randomness, no network.
/// All timestamps and IDs are caller-supplied.
library sync_engine;

export 'src/crdt_text.dart';
export 'src/delta.dart';
export 'src/merge.dart';
export 'src/session.dart';
