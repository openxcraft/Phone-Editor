//! Document model mirroring the Dart `doc_engine` node tree:
//! document -> sections -> blocks -> inline nodes.
//!
//! Serialization is deterministic and byte-compatible with Dart's
//! `jsonEncode(document.toJson())`:
//! - struct field order below is exactly the Dart map insertion order;
//! - `serde_json::to_string` emits no spaces, like `jsonEncode`;
//! - marks are stored in a `BTreeSet` whose variant order is alphabetical,
//!   matching Dart's sorted mark names;
//! - timestamps are `i64` (Dart `int` in JSON), never floats.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

/// Inline formatting marks. Declaration order is alphabetical so the
/// derived `Ord` sorts exactly like Dart's `marks..sort()`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mark {
    Bold,
    Code,
    Italic,
    Underline,
}

/// Block kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlockType {
    #[serde(rename = "paragraph")]
    Paragraph,
    #[serde(rename = "heading1")]
    Heading1,
    #[serde(rename = "heading2")]
    Heading2,
    #[serde(rename = "bullet")]
    Bullet,
    #[serde(rename = "quote")]
    Quote,
    #[serde(rename = "table")]
    Table,
    #[serde(rename = "image")]
    Image,
}

/// A run of text sharing one set of marks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InlineNode {
    pub text: String,
    #[serde(default)]
    pub marks: BTreeSet<Mark>,
}

/// One cell of a table block.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TableCell {
    pub inlines: Vec<InlineNode>,
}

/// Image metadata for image blocks. The core never handles binary data.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImageMeta {
    pub asset_id: Option<String>,
    pub alt: Option<String>,
    pub byte_length: Option<i64>,
    pub hash: Option<String>,
}

/// A block: one unit of a section.
///
/// `table_rows` is present only for table blocks and `image` only for
/// image blocks; both are omitted from JSON when absent, matching the
/// Dart `Block.toJson`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Block {
    pub id: String,
    #[serde(rename = "type")]
    pub block_type: BlockType,
    pub inlines: Vec<InlineNode>,
    #[serde(
        rename = "table_rows",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub table_rows: Option<Vec<Vec<TableCell>>>,
    #[serde(rename = "image", default, skip_serializing_if = "Option::is_none")]
    pub image: Option<ImageMeta>,
}

impl Block {
    /// Concatenated plain text of all inline runs (empty for tables).
    pub fn plain_text(&self) -> String {
        self.inlines.iter().map(|n| n.text.as_str()).collect()
    }
}

/// A comment anchored to a rune range of one block's plain text.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DocComment {
    pub id: String,
    #[serde(rename = "block_id")]
    pub block_id: String,
    pub start: i64,
    pub end: i64,
    pub author: String,
    pub text: String,
    #[serde(rename = "created_at")]
    pub created_at: i64,
    pub resolved: bool,
}

/// Kind of a tracked-change suggestion.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SuggestionKind {
    Insertion,
    Deletion,
}

/// A pending tracked-change suggestion.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Suggestion {
    pub id: String,
    pub kind: SuggestionKind,
    #[serde(rename = "block_id")]
    pub block_id: String,
    pub start: i64,
    pub end: i64,
    pub text: String,
    #[serde(default)]
    pub marks: BTreeSet<Mark>,
    pub author: String,
    #[serde(rename = "created_at")]
    pub created_at: i64,
}

/// A section: an ordered group of blocks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Section {
    pub id: String,
    pub blocks: Vec<Block>,
}

/// Sync lifecycle of a document row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum SyncStatus {
    #[serde(rename = "local_only")]
    #[default]
    LocalOnly,
    #[serde(rename = "pending")]
    Pending,
    #[serde(rename = "synced")]
    Synced,
}

/// The document root. Field order is the Dart serialization order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Document {
    pub id: String,
    pub title: String,
    #[serde(rename = "created_at")]
    pub created_at: i64,
    #[serde(rename = "updated_at")]
    pub updated_at: i64,
    #[serde(rename = "deleted_at")]
    pub deleted_at: Option<i64>,
    #[serde(rename = "sync_status", default)]
    pub sync_status: SyncStatus,
    pub sections: Vec<Section>,
    /// Always serialized (possibly empty), as in Dart. Defaults to empty
    /// when decoding older documents that predate these keys; re-encoding
    /// such a document adds `"comments":[]` / `"suggestions":[]`.
    #[serde(default)]
    pub comments: Vec<DocComment>,
    #[serde(default)]
    pub suggestions: Vec<Suggestion>,
}

impl Document {
    /// All blocks in document order.
    pub fn all_blocks(&self) -> impl Iterator<Item = &Block> {
        self.sections.iter().flat_map(|s| s.blocks.iter())
    }

    /// Parses a document from JSON. Malformed input (invalid JSON, wrong
    /// field types, unknown enum values) is rejected with an error,
    /// mirroring Dart's `FormatException` behaviour.
    pub fn from_json(input: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(input)
    }

    /// Deterministic JSON: no spaces, struct field order, sorted marks.
    /// Byte-identical to Dart `jsonEncode(document.toJson())` for the
    /// same tree (enforced by the golden tests).
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("Document serialization cannot fail")
    }
}
