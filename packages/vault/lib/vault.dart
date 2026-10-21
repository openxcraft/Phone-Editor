/// Encryption at rest for documents: AES-256-GCM envelope over any
/// doc_engine DocumentStore, with keys supplied via KeyProvider.
library vault;

export 'src/encrypted_document_store.dart';
export 'src/key_provider.dart';
export 'src/vault_exception.dart';
