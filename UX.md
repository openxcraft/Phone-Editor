# UI / UX

## Principles

- Minimal default surface: one clear primary action per screen.
- Progressive disclosure: advanced formatting, animations, formulas, and
  export options live in contextual sheets/menus, not permanent clutter.
  Selection-scoped actions appear only while a selection exists.
- Neutral palette (2–3 colours max), high contrast, one type family,
  4/8 px spacing grid, dark mode, reduced-motion support.
- No chat bubbles by default, no assistant avatar, no sparkle iconography,
  no branded gradients.
- Keyboard-first and gesture-friendly; accessible labels, sensible focus
  order, screen-reader support on every interactive element.
- Motion: 60 fps target; motion explains state changes; the OS
  reduce-motion setting is honoured everywhere.
- Editor chrome feels calm and native; toolbars collapse on scroll;
  selection actions appear contextually.
- Export and sync show clear progress, errors, and retry actions.
  Save state is always visible in the editor ("Saved on device" /
  "Saving…" / "Save failed — Retry").

## Slice-1 shell behaviour

- Document list: title, last-edited time, one primary action (New document).
- Editor: blocks as plain text fields; a formatting bar appears only when
  a block has focus; an export action in the app bar opens a sheet
  (Markdown available in Slice 1; other formats listed as unavailable
  rather than faked).
