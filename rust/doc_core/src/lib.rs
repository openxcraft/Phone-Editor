//! Format-neutral document core.
//!
//! Mirrors the Dart `doc_engine` package contracts (the reference
//! implementation): the same node tree, the same deterministic JSON
//! serialization (verified byte-for-byte against shared golden files in
//! `rust/golden/`), and the same Markdown export mapping (see the repo
//! root `EXPORT.md`).

pub mod markdown;
pub mod model;

pub use markdown::export_markdown;
pub use model::Document;
