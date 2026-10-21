//! Deterministic Markdown export from the neutral node tree.
//! A direct port of the Dart `MarkdownExporter`; the mapping and loss
//! rules are specified in the repo root `EXPORT.md`.

use crate::model::{Block, BlockType, Document, InlineNode, Mark, TableCell};

/// Exports the whole document. Blocks are separated by one blank line;
/// the output ends with exactly one newline.
pub fn export_markdown(doc: &Document) -> String {
    let mut blocks: Vec<String> = Vec::new();
    let title = doc.title.trim();
    if !title.is_empty() {
        blocks.push(format!("# {}", escape(title)));
    }
    for block in doc.all_blocks() {
        blocks.push(export_block(block));
    }
    format!("{}\n", blocks.join("\n\n"))
}

fn export_block(block: &Block) -> String {
    match block.block_type {
        BlockType::Table => {
            let rows = block.table_rows.as_deref().unwrap_or(&[]);
            rows.iter()
                .map(|row| {
                    let cells: Vec<String> = row.iter().map(export_cell).collect();
                    format!("| {} |", cells.join(" | "))
                })
                .collect::<Vec<_>>()
                .join("\n")
        }
        BlockType::Image => {
            // No binary handling: reference the asset by its stored ID.
            let meta = block.image.as_ref();
            let alt = escape(meta.and_then(|m| m.alt.as_deref()).unwrap_or(""));
            let asset = meta.and_then(|m| m.asset_id.as_deref()).unwrap_or("");
            format!("![{alt}](asset:{asset})")
        }
        _ => {
            let inner: String = block.inlines.iter().map(export_inline).collect();
            match block.block_type {
                BlockType::Heading1 => format!("# {inner}"),
                BlockType::Heading2 => format!("## {inner}"),
                BlockType::Paragraph => inner,
                BlockType::Bullet => format!("- {inner}"),
                BlockType::Quote => format!("> {inner}"),
                BlockType::Table | BlockType::Image => unreachable!(),
            }
        }
    }
}

fn export_cell(cell: &TableCell) -> String {
    let inner: String = cell.inlines.iter().map(export_inline).collect();
    inner.replace('|', "\\|")
}

fn export_inline(node: &InlineNode) -> String {
    if node.text.is_empty() {
        return String::new();
    }
    if node.marks.contains(&Mark::Code) {
        // Code spans ignore other marks (see EXPORT.md).
        return format!("`{}`", node.text.replace('`', "\\`"));
    }
    let mut out = escape(&node.text);
    let bold = node.marks.contains(&Mark::Bold);
    let italic = node.marks.contains(&Mark::Italic);
    if bold && italic {
        out = format!("***{out}***");
    } else if bold {
        out = format!("**{out}**");
    } else if italic {
        out = format!("*{out}*");
    }
    // Mark::Underline has no Markdown equivalent: exported as plain text.
    out
}

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if matches!(ch, '\\' | '`' | '*' | '_') {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}
