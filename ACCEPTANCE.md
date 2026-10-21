# Acceptance Criteria

The build is acceptable only when all of the following hold. Status as of
the autonomous completion run (2026-10-21; evidence in
FINAL_VERIFICATION.md). "Engine level" means the behaviour is proven by
automated tests of the UI-independent engines; app-level proof requires
the Flutter shell running on a device/emulator.

1. **Airplane-mode editing** — *Met at engine level.* Documents, sheets,
   presentations, and PDF annotations are all local models with local
   persistence and no network anywhere in tests. App-level: pending
   Flutter shell verification.
2. **Sync resolves conflicts without data loss** — *Met.* sync_engine
   scenario tests: offline two-client edits, delete-vs-edit (both
   directions), rename-vs-edit, same-block conflict, interrupted and
   resumed sync; losing versions always preserved as conflict copies.
3. **Playback matches preview and export** — *Met for state; partial
   for files.* One pure `stateAt` core serves preview/presenter/MCP
   `render_state` (byte-identical JSON asserted). PPTX export does not
   carry animations (documented loss in export_engine README).
4. **PDF export passes PDF/A and PDF/UA validation** — *Not met.*
   Structured mode and PDF/A-mode output exist and are structurally
   checked in tests and by Poppler, but the ICC profile is a placeholder
   and no external validator has been run. This is the largest open gap.
5. **Office round-trips** — *Met for core fixtures.* DOCX (byte-stable),
   PPTX and XLSX (export→import→export stable) with documented losses.
6. **Sheets recalculation** — *Met.* Dependency-graph recalc, cycle
   detection, 5,000-cell chain and 1,000-cell range tests. Large-grid
   *scrolling* smoothness is a UI property: not yet measurable.
7. **MCP** — *Met.* Client discovery + calls; server exposes all seven
   permissioned tools; audit log asserted in tests; denied calls change
   nothing.
8. **External-model adapter** — *Met.* Works against a user-supplied
   endpoint (mock-server tests); secrets held only in SecretStore;
   no-leak test proves keys/prompts stay out of errors and logs; no
   vendor branding anywhere (security scan clean).
9. **UI checks** — *Partial.* The shell implements progressive
   disclosure and calm styling per UX.md, but the accessibility audit
   and on-device checks require Flutter, which is unavailable here.
10. **Tests + verification note per increment** — *Met.* 266 automated
    tests across 8 Dart packages and the Rust crate, all passing;
    SLICE1_VERIFICATION.md and FINAL_VERIFICATION.md record results.

## Slice-1 subset (historical, all met)

- [x] Document model operations behave per ENGINES.md (unit tests).
- [x] Deterministic JSON serialization round-trips (unit tests).
- [x] SQLite persistence survives close/reopen; soft delete honours
      `deleted_at`; rows carry `updated_at` and `sync_status` (tests).
- [x] Editing + save + export work with no network (local file DB only).
- [x] Markdown export matches EXPORT.md mapping (golden tests).
- [ ] Flutter shell compiles and runs — blocked: no Flutter SDK in the
      build environment; shell source is provided.
