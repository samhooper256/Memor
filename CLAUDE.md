# Memor

A macOS flashcard app (similar to Anki) built with Swift/SwiftUI and GRDB for local SQLite persistence. (Originally named `Flashcards2`; the app, project, source folder, and database are all `Memor` now.)

## Development Workflow

- **Commit every change.** After making any change to the app, commit it with a relevant, descriptive commit message. Don't batch unrelated changes into one commit — keep each commit scoped to a single logical change.

## Project Structure

```
Memor/
  MemorApp.swift              App entry point, window scene definitions
  ContentView.swift                 Main window shell: AppTab, AppNavigationState, ContentView, TabPageView
  AppDatabase.swift                 Database class + init + CRUD + search parsing + SRS (large; incremental splits underway — see Database/)
  Utilities.swift                   Cross-cutting helpers (QueryRenderContent etc.) that don't yet belong elsewhere
  AddInstanceWindowView.swift       AddInstanceWindowState (tab drafts + selection), EditInstanceWindowState, QueryPreviewWindowState, AddInstanceWindowView (tab container + tab-close/discard flow), EditInstanceWindowView
  SearchWindowView.swift            Unified "Search" window: SearchWindowState + SearchMode (Instances/Queries/Points & Boundaries), Shift+Tab to switch modes
  QueryPreviewWindowView.swift      Query preview WKWebView window
  TypesPageView.swift               Types list view + TypeRowView
  Database/
    AppDatabase+Schema.swift        createSchema (run every launch); canonical table/index definitions; Person seed
    AppDatabase+StackCounts.swift   Stacks-tab refresh: staticTruthValue expression pruning + batched per-type/per-map/per-person color-count SQL (refreshStacksPageData / refreshStackQueryCounts)
    AppDatabase+Person.swift        Person relationship engine: fetchPersonEditorData, savePersonInstance (diff → conflict collection → propagation), deletePersonRelations (convert-to-bare), fetchPersonCandidates, reset-flag accessors
    AppDatabase+PersonQueries.swift Built-in Person queries: enablement, SRS apply/revert, makePersonStudyQuery (the single computed-HTML seam), personQueryJoinFrom + the search/stacks/study fetchers
    AppDatabase+Offices.swift       Office CRUD (case-insensitive unique names, holder counts) + db-level holding/succession read helpers
  Models/
    DatabaseModels.swift            All plain-data structs/enums returned by AppDatabase
    PersonModels.swift              Person types: PersonRef (instance-or-bare-name), slot drafts, PersonQueryKind, PersonSaveError conflicts, the save change set
  Pages/
    StacksPageView.swift            Stacks sidebar + detail pages, stack cards
    InstancesPageView.swift         Instances sidebar + type-instances table + toast + key commands
    CollectionsPageView.swift       Collections sidebar + detail page
    GraphPageView.swift             Graph tab + WKWebView wrapper
    TypeDetailPageView.swift        Type detail: fields section, query-type editors (co-located with TypesPageView)
  Study/
    StudyModeView.swift             Study mode UI, header, rating buttons, undo stack, key commands
  InstanceEditor/
    InstanceEditorWindowView.swift  Core editor body shared by Add/Edit instance windows (InstanceEditorMode enum lives here)
    InstanceEditorDraft.swift       Per-tab ObservableObject holding all in-progress instance state (isDirty/isPristine/tabTitle); Add-mode drafts live on AddInstanceWindowState so tabs survive window close (in-memory only, never persisted)
    AddInstanceTabBar.swift         Add Instance tab strip (chips + X + "+") and the window-scoped ⌘1–⌘9/⌘W key monitor (non-customizable)
    InstanceFieldEditor.swift       Per-field editor cell (text/boolean/sex), InstanceTextView (NSViewRepresentable), AddInstanceFieldFocusController
    PersonSlotsEditor.swift         Person editor's Relationships panel: parent slots, partner cards, synced Children box, person picker popover with bare-name entry
    PersonQueryChecklist.swift      Built-in Person query checkboxes (Relationships per kind + per partner; Offices per holding + All Offices) with enabled-but-empty warnings, preview, and reset
    PersonOfficesEditor.swift       Person editor's Offices panel: ordered office cards (dates/note, predecessor/successor chips) + office picker popover with inline create
    HyperlinkSearch.swift           ⌘K hyperlink-search popup: controller, state, panel, text field, popup view
    CollectionSelector.swift        Collections panel search field + checklist row
    TypePicker.swift                Change-type popup (controller + popup state + popup view)
  PointMap/
    PointMapInstanceEditor.swift    PointMap editor state, sort modes, entry refs, add-point popup, entry row, right-click menu
    PointMapQueryView.swift         PointMap query rendering + MapPointMarker
  Shortcuts/
    KeyBinding.swift                Codable keystroke model (key + modifiers, NSEvent matching)
    ShortcutAction.swift            Enum registry of every user-customizable shortcut
    ShortcutSettings.swift          ObservableObject store backed by UserDefaults
    View+Shortcut.swift             `.shortcut(.action, settings:)` modifier
    ShortcutLabel.swift             Renders "Title (⌘R)" labels that update live
  Shared/
    SRS.swift                       Starter delays, interval formatting, color/bucket helpers
    FlowLayout.swift                Wrapping chip layout (used by the Person editor)
    ToastView.swift                 ToastMessage, ToastStyle, ToastView (used by InstanceEditor)
    WindowKeyCommandHandler.swift   Background NSViewRepresentable wiring ⌘Return/⌘S/⌘B/⌘I/⌘O/⌘J/⌘L/⌘T/Esc
    PlainTextEditor.swift           NSTextView wrapper for plain-text fields
    PlainCodeTextView.swift         Code editor NSTextView + FocusedEditor + query-type editor split view
    SearchHighlightingTextView.swift Search field + highlight rendering used across search windows
    TextSubstitutions.swift         NSTextView.disableAutomaticSubstitutions() + launch-time defaults kill switch
    QueryHTMLView.swift             WKWebView wrapper for rendering query HTML (+ scheme handler)
    HTMLPreviewView.swift           Live-preview WebView for the Types page HTML/CSS editors
  Windows/
    SettingsWindowView.swift        Settings UI with key recorder and conflict resolution
    GlobalCodeEditorWindow.swift    Standalone HTML/CSS editor window opened from the Types page
    ManageOfficesWindowView.swift   "Edit Offices" window: searchable office list w/ holder counts, add/delete (cascade warning), description editor
  MCP/
    MCPConstants.swift              Host/port/path constants + memorDidChangeDatabase notification name
    MCPHTTPListener.swift           Minimal HTTP/1.1 loopback listener (Network.framework) feeding StatelessHTTPServerTransport
    MemorMCPServer.swift            Lifecycle manager: starts Server + transport + listener, overrides Initialize handler
    MemorMCPTools.swift             Tool registration — one function per MCP tool, calls AppDatabase directly
memor-mcp/
  main.swift                        Stdio ↔ HTTP proxy binary Claude Desktop spawns; embedded in Memor.app/Contents/MacOS/
```

## Domain Model

There are three classes of type (no `type.kind` column — built-ins are identified by name + `is_builtin`):
- **Object types** — the open, default class: text/boolean fields + user query types.
- **Person** — a single built-in, non-deleteable, partially-editable type for genealogy (see the Person section below). Its fields live in the normal `field`/`type{N}` pipeline, so search/templating/user query types work unchanged; its relationships live in bespoke tables.
- **Map types** (`PointMap`, `BoundaryMap`) — the closed, built-in class with bespoke editors/tables.

- **Type** (`type` table) - User-defined data type with named fields and CSS
- **Field** (`field` table) - Named field on a type (`field_type` 'text' | 'boolean' | 'sex'), with `field_index`, `field_display_index`, `is_primary`, and `is_protected` (built-in Person fields: no rename/delete). The seed-only `sex` kind stores the literal string "Male"/"Female" (normalized, default Male) so `{{Sex}}` renders as-is.
- **Instance** (`instance_id_type_id` + `type{N}` tables) - Concrete object of a type. Each type has its own dynamic table `type{typeID}` with columns `field{field_index}`
- **QueryType** (`query_type` table) - Defines a question template (question_html + answer_html) for a type. Person's built-in relationship queries are NOT query_type rows (they live in `person_query`).
- **Query** (`query` table) - A flashcard prompt for a specific instance+query_type pair. Tracks `interval`, `last_answered_timestamp`, `was_last_answer_correct`
- **Collection** (`collection` + `instance_id_collection_id` tables) - Named group of instances (cross-type, many-to-many)
- **Stack** (`stack` table) - Named set of queries defined by a `search` string

## The Person type

Seeded idempotently in `createSchema` (`name='Person' AND is_builtin=1`). Default fields: Name, Description (ordinary, deletable) + protected Sex/WhenBorn/WhenDied. The premade "Name" query type is an ordinary deletable `query_type` row. Person appears in the Types page (openable, not deletable/renameable) with a partially-editable detail page.

**Relationship slots** (instance editor "Relationships" panel; every entry is another Person instance or a *bare name* — free text with no reciprocity):
- `Mother`/`Father`/`AdoptiveMother`/`AdoptiveFather`: 0-or-1 each (DB-enforced by `UNIQUE(child_id, role)` on `person_parent`). Adoptive slots never affect other instances; adoptive sexes are enforced (AdoptiveMother must be Female).
- `Partners`: ordered per side; `person_partnership` stores is_married/start/end ONCE per stint (both partners' views agree by construction; duplicate stints allowed; row ids are STABLE — edits UPDATE in place because `children_with` SRS anchors to them).
- Children of a couple: one `person_partnership_child` row per child = shared order across both parents. A grouped child's mother/father are MATERIALIZED into `person_parent` by the save routine (bare partner → role opposite the instance partner's sex). Same-sex couples cannot have children.
- Ungrouped children: `person_direct_child` (parent-side order + bare children; a maintained projection of `person_parent` for instance children). The editor's Children box shows grouped + ungrouped; removal syncs both directions.

**Consistency engine** (`savePersonInstance`, one transaction): diffs the drafted slots, collects EVERY contradiction read-only (occupied 0-or-1 slot with a different value, sex/role mismatch, same-sex children, child-side edits of grouping-derived parents, sex changes flipping occupied roles), and throws `PersonSaveError` — surfaced as a BLOCKING NSAlert (UI) or structured tool error (MCP) with nothing written. Consistent changes propagate automatically (fills, list appends, role flips, {person, bare} slot swaps). Deleting a Person converts references on other people to bare names (delete confirmations warn via `hasPersonConnections`). Sex edits must go through `savePersonInstance` — never write the sex column generically (MCP `update_instance` routes Person instances through it).

**Built-in relationship queries** (`person_query`: row existence = enabled, DISABLED by default): mother, father, parents, adoptive_mother, adoptive_father, partners, children, children_with (one per partnership, per side), full_siblings. Non-deleteable; the question is a fixed "Who are the X of:" title + a user-customizable **shared "details" block** + (childrenWith only) the partner line; answers are computed from relationships in `makePersonStudyQuery` — the ONLY HTML seam, feeding Study, Query Preview, and MCP `render_query` (`StudyQuery.kind` stays `.standard` with `personQueryKind`/`personPartnershipID`; ids are `p:instance:kind:partnership`). The details block is one HTML string shared by every built-in kind (with `{{FieldName}}` placeholders), stored in `globals` under `person_builtin_query_html` (`fetchPersonBuiltinQueryHTML`/`setPersonBuiltinQueryHTML`; absent ⇒ `PERSON_BUILTIN_QUERY_HTML_DEFAULT` = `<div class="Name">{{Name}}</div>`), edited via the Type Detail page's synthetic non-deleteable "Built-in Queries" dropdown entry (Question radio only, always enabled; CSS editor is the ordinary shared Person type CSS). Partners lists every partner (in the person's partner order). Full Siblings match both parents (ids / exact bare strings) and include the person as `.person-self`. Multi-name answers (partners, children, children_with, full_siblings) render one name per line via `personAnswerLines` (`.person-answer-line` block divs), not comma-separated. The editor checklist warns (never blocks) on enabled-but-empty answers, except Full Siblings.

**Reset-on-connection-change**: the Person Type Detail checkbox (globals key `person_reset_queries_on_connection_change`, default off). When on, every save's change set resets the affected ENABLED built-in queries (over-approximating full-sibling ripples; office change-set entries are exact) and the green toast reports the count.

**Offices** (what public offices a person held — U.S. President, Pope, …):
- Tables: `office` (user-created entities, names unique **case-insensitively**; managed via the Person type detail page's "Edit Offices" button → the `manage-offices` window, or created inline from the editor's office picker), `person_office` (one holding per (person, office), `UNIQUE(instance_id, office_id)`, with `when_began`/`when_ended`/`note` freetext + per-person `order_index`), `person_office_succession` (one row per directed "A precedes B in X" fact, stored ONCE — reciprocity by construction). The succession table's **composite FKs** `(person_id, office_id) REFERENCES person_office(instance_id, office_id) ON DELETE CASCADE` mean an edge can only exist while both endpoints hold the office, and deleting a holding/office/person cascades its edges automatically.
- Every holding references an existing `office` row (the picker creates offices in the DB immediately; an abandoned draft can leave a 0-holder office — visible/deletable in the manager). Predecessor/successor links are Person **instances only** (no bare names); linking a peer who doesn't hold the office AUTO-ADDS the holding (empty fields, end of their order). Removing a holding deletes that person's per-office query row (SRS loss) and their edges for that office. Deleting a Person removes succession edges (FK cascade; `deletePersonRelations` only gathers the peers' change-set entries); delete confirmations count succession peers via `hasPersonConnections` (wired into the editor/Instances/Search delete alerts through `personDeletionConsequencesMessage`). Deleting an Office cascades holdings → edges → per-office `person_query` rows.
- Offices ride `savePersonInstance` (full-state `PersonRelationsDraft.offices`; **every caller must originate drafts from `fetchPersonEditorData`** or holdings get wiped — all current callers do).
- **Built-in office queries** live in the same `person_query` table: kinds `office` (`office_id` non-NULL, one per holding — the `children_with` pattern) and `all_offices` (standalone). All `person_query` keying is null-safe `partnership_id IS ? AND office_id IS ?`. The three partial unique indexes cover the three row shapes (the standalone one is `idx_person_query_unique_standalone2`; the `2` suffix is historical). `StudyQuery`/`QuerySearchResult`/`QueryTarget` carry `personOfficeID`; ids are `p:instance:kind:(partnership ?? office ?? 0)`.
- Rendering (in `makePersonStudyQuery`, as always): a per-office **question** is the user-editable template rendered alone (globals key `person_office_query_html`, default `<div class="Office">{{@Office}}: {{@WhenBegan}}–{{@WhenEnded}}</div>`; `{{@Note}}` also supported — `{{@…}}` = a per-holding "field" that may repeat, substituted BEFORE the normal `{{FieldName}}` pipeline), edited via the Type Detail dropdown's "Built-in Office Queries" entry (sentinel -2, Question-only; the old "Built-in Queries" entry is now "Built-in Relationship Queries"). The per-office **answer** is fixed: a 20%/60%/20% flex row (`.office-succession-*` classes, thin white dividers around the middle panel) of predecessors / the person's hyperlinked name / successors, in edge-creation order. `all_offices` asks "What are the offices of:" + the shared details block; its answer renders the office template once per holding, in the person's order.
- **The `_offices` element** (user-authored Person query HTML): any element with id `_offices` gets its CONTENTS replaced at render time with one `.office-succession` row per holding, in the person's office order — same three-panel layout, but the middle panel is "Office: began–ended" (name alone when both dates are blank) instead of the person's name. Seam: `buildRenderedQuestionHTML`/`buildRenderedAnswerHTML` → `AppDatabase.renderPersonOfficesElements` (so Study, Query Preview, and MCP `render_query` all get it); standard Person queries get `personBuiltinQueryDefaultCSS` prepended there so the rows style. Template previews (no instance) leave the element as typed. Documented in the help bubble beside the Question/Answer radios on the Person type detail page (user query types only).

- SQLite via GRDB (`DatabaseQueue`)
- App Sandbox enabled
- DB path: `~/Library/Containers/com.sam.Memor/Data/Library/Application Support/Memor/Memor.sqlite`
- Dynamic per-type tables: `type{typeID}` with columns `field{fieldID}`
- Global settings in `globals` table (global_query_html, global_query_css, stacks_last_updated_timestamp)
- Security-scoped bookmarks for image file access (`image_file` table)
- **Schema evolution — there is NO migration machinery** (deleted July 2026: single user, schema current). `AppDatabase.init` runs `createSchema` on every launch; everything in it is `CREATE TABLE/INDEX IF NOT EXISTS` plus idempotent seeds, so NEW tables and indexes reach an existing database automatically. Adding a column to an EXISTING table is different: editing its `CREATE TABLE` only affects fresh databases, so also apply a one-off `ALTER TABLE` to the live database (or add a `PRAGMA table_info`-guarded helper if it must self-apply on launch).

## Search Query Language

The unified "Search" window (and the ⌘K hyperlink popup) has three modes, each with its own language flavor, all parsed by `parseSearchExpression` with feature flags:
- **Instances** (`searchInstances`): instances of every type, incl. PointMap/BoundaryMap instances.
- **Queries** (`searchQueries`): individual studyable queries — standard object queries, Person built-in relationship queries (merged into the Person type's section, named "Mother"/"Children with Alice"/…), plus PointMap and BoundaryMap **Forward/Reverse** queries (one result per enabled direction, via `pointMapDirectionalFrom`/`boundaryMapDirectionalFrom`). **Invariant: the Queries language is exactly the Stacks language** — a Stack's search text in Queries mode returns exactly that Stack's studied queries (both consume the same parser + condition builders). **Person lockstep rule**: the four person scan surfaces (searchQueries, computeQueryCountGroups, fetchStackDueDayCounts, fetchStudyQueryBuckets/selectNextStudyQuery) must all use `personQueryJoinFrom` + `makeQuerySearchConditions(srsAlias: "pq")` + `staticTruthValue(typeName: PERSON_TYPE_NAME, newIsAlwaysFalse: false)`; never inline a divergent FROM or predicate.
- **Points & Boundaries** (`searchMapElements`): PointMap points and BoundaryMap boundaries themselves (one row per point/boundary). Uses a restricted grammar (`parseMapElementSearchQuery`, flag `allowsTypeCollectionId: false`): only quotes, parens, OR/NOT, `literal:`, and plain strings.

Components:
- Space-separated components combined with AND
- `literal:text` - field contains text
- `collection:name` or `col:name` - instance in named collection
- `type:name` - instance of named type
- `id:number` - the single instance with this ID
- `:noqueries` - **instance search only** - instances with no queries enabled (Person built-in queries count). Enforced by the `allowsNoQueries` flag threaded through `parseSearchExpression`.
- `:new` - **query search only** - queries that are new (`interval = 0`). Matches standard and Person built-in queries; map queries never match (their condition builders compile `:new` to constant false). Enforced by the `allowsNew` flag.
- Components can use `or(...)` for OR logic
- Double quotes for spaces inside components: `"literal:hi there"`
- Empty query matches all
- Three help windows (`InstanceSearchHelpWindowView` / `QuerySearchHelpWindowView` / `MapElementSearchHelpWindowView`, opened from the `?` button beside the search box) document each mode's components; the `?` opens the one matching the current mode.

## Spaced Repetition

- Query colors: blue (new, interval=0), red (seen, interval < 1 day), green (seen, interval < 1 day but answered correctly), magenta (interval >= 1 day)
- Starter delays: 60s and 600s
- Rating multipliers: Again (reset to starter), Hard (1.2x), Good (2.5x), Easy (3.25x)
- Study mode loads queries into blue/red/green pools, prioritizes overdue red queries, then randomly picks from blue+green

## Keyboard Shortcuts

The shortcut system lives in `Memor/Shortcuts/`. **Customizable** shortcuts are driven by a registry, persisted to UserDefaults (key `com.sam.Memor.shortcuts`), and re-render the UI live when changed via `ShortcutSettings: ObservableObject`.

### Adding a new customizable shortcut

1. Add a case to `ShortcutAction` in `Shortcuts/ShortcutAction.swift` with `title`, `category`, and `default: KeyBinding`.
2. Apply it to the SwiftUI view: `.shortcut(.myAction, settings: shortcutSettings)` (replaces `.keyboardShortcut(...)`).
3. Display it in button text: `ShortcutLabel(title: "Save", action: .myAction)` or interpolate `shortcutSettings.binding(for: .myAction).displayString`.
4. For `NSEvent.addLocalMonitorForEvents` handlers, store a `ShortcutSettings` ref on the NSView and call `settings.binding(for: .myAction).matches(event)`. See `StudyModeKeyCommandHandler` in Study/StudyModeView.swift for a reference implementation.
5. Every scene that hosts the view must inject `.environmentObject(shortcutSettings)` (see MemorApp.swift).

### Non-customizable bindings (kept hard-coded)

These are intentionally NOT in `ShortcutAction`:
- Escape (close secondary windows, cancel study, exit popovers)
- Tab / Shift-Tab (instance-editor field navigation)
- Arrow keys (⌘← for Query Preview back history; bare ←/→ reserved for instance link shortcuts — see below; up/down in popups)
- Delete key (remove row from instance table / collection table)
- Shift (press to toggle the collection overlay in Study mode; on BoundaryMap queries it instead toggles the gold "boundary finder" — a gold frame around the current boundary, or a gold edge arrow pointing to it when off-screen — for forward queries only)
- `.defaultAction` on confirmation buttons (Return)

If you reach for these, leave them in place. Don't promote them to `ShortcutAction`.

### Link keyboard shortcuts (`data-shortcut`)

An `<a>` link in a text field whose `href` starts with `id:` (an instance/query/PointMap
link) may carry an optional `data-shortcut` attribute so it can be opened by keyboard.
Pressing the shortcut is equivalent to clicking the link (the Query Preview window opens or
navigates to the linked instance).

- **Accepted values are a closed set: `left` and `right`** (the left/right arrow keys). Any
  other value is ignored. `data-shortcut` is authored manually in the field editor's raw
  HTML — there is no ⌘K / editor UI for it.
- Works in two places: **Study mode after the answer is revealed**, and **Query Preview
  windows**. These bare arrow keys are intentionally non-customizable, like the other arrow
  bindings.
- The handler scans **all of the instance's stored field values** (`StudyQuery.fieldValuesByName`),
  not the currently-rendered HTML, so every link on the instance works even if it isn't
  visible on the showing query. Person built-in query answer links are out of scope
  (they aren't stored in a text field and can't carry `data-shortcut`).
- If two+ links on the instance share the same shortcut, pressing that key shows a system
  `NSAlert` instead of navigating.
- Implementation: [Memor/Shared/LinkShortcuts.swift](Memor/Shared/LinkShortcuts.swift)
  (`parseLinkShortcuts` / `resolveLinkShortcut` / `presentLinkShortcutCollisionAlert`,
  reusing `parseLinkedInstanceID` / `parseLinkedQueryID` from `Shared/QueryHTMLView.swift`).
  Wired into the key monitors in `Study/StudyModeView.swift` and `QueryPreviewWindowView.swift`.

### Built-in defaults

| Action | Default |
|---|---|
| Go to Stacks / Instances / Collections / Types / Graph | ⌘1–⌘5 |
| Add Instance | ⌘⇧A |
| Open Search (preserves last mode) | ⌘⇧S |
| Open Search in Queries mode | ⌘⌥S |
| Search — switch mode (Instances / Queries / Points & Boundaries) | Shift+Tab |
| Settings | ⌘, |
| Study — reveal / Good | Space |
| Study — Again / Hard / Good / Easy | 1 / 2 / 3 / 4 |
| Study — Undo | ⌘Z |
| Study — Edit current instance | E |
| Study — Edit Type (exit Study, open the instance's type detail page) | ⌘⇧T |
| Study — Duplicate current instance (open Add Instance prefilled; post-reveal, Object types only) | ⌘D |
| Instance editor — Save | ⌘S |
| Types page — Save current editor | ⌘S |
| Query Search — Reset Due Dates | ⌘R |

## Key Patterns

- Window state communicated via `@StateObject` ObservableObject classes with UUID nonces for change detection
- NSViewRepresentable used extensively for key command handling (NSEvent monitors) and WKWebView
- HTML field values rendered via template substitution: `{{FieldName}}` placeholders, `{{{Content}}}` for global wrapper, `{{#QuestionContent}}` for answer-side question reference, `{{#InstanceID}}` for the instance's numeric id (empty in template previews), `{{#CollectionIDs}}`/`{{#CollectionClasses}}` for collection membership. The instance-scoped `{{#...}}` tokens (InstanceID, CollectionIDs) are substituted in `generatePreviewHTMLForQuestion`/`generatePreviewHTMLForAnswer` (Utilities.swift) using the passed `instanceID`; the answer path re-runs them after `{{#QuestionContent}}` splices the raw question HTML back in.
- Local images served via custom WKURLSchemeHandler (`flashcards-local-image://`)
- Prefer `pointerStyle(...)` over NSCursor for hover effects
- Escape key closes all secondary windows
- Customizable keyboard shortcuts are routed through `ShortcutSettings` / `.shortcut(.action, settings:)` — don't hard-code `.keyboardShortcut(...)` for actions a user should be able to rebind.
- Copy `StudyQuery` only via its copy-helpers (`withFieldValues` / `withStudyOutcome` in Models/DatabaseModels.swift), never with a memberwise `StudyQuery(...)` — the defaulted identity fields (`personQueryKind`/`personPartnershipID`/`personOfficeID`) drop silently and turn a Person card into a broken standard card.
- **No macOS automatic text substitution, ever, in any editor** (no `...` → `…`, smart quotes/dashes, autocorrect). Every new NSTextView must call `disableAutomaticSubstitutions()` (Shared/TextSubstitutions.swift); NSTextField and SwiftUI TextField surfaces are covered by `registerSubstitutionKillDefaults()` in `MemorApp.init`, which writes the `NSAutomatic*Enabled` defaults false (a `set`, not `register` — the registration domain loses to NSGlobalDomain). Gotcha: `...` → `…` is smart DASHES (`isAutomaticDashSubstitutionEnabled`), not text replacement.

## Code Style

- SwiftUI + AppKit (NSViewRepresentable) for macOS
- `@StateObject` / `@EnvironmentObject` for shared state (not Combine pipelines)
- Raw SQL via GRDB (no GRDB query builder)
- Async/await for data loading, `@MainActor` annotations on state-mutating methods
- Monospaced font for code editors and search fields
- Default isolation is `MainActor` (`default-isolation=MainActor` is enabled project-wide). Explicit `@MainActor` on a class annotation will break `ObservableObject` conformance — rely on the default.
- `MemberImportVisibility` is enabled, so imports must be explicit (e.g. `import Combine` when using `@Published`).

## MCP Server

Memor hosts an in-process MCP (Model Context Protocol) server so Claude Desktop can drive it (create instances, manage collections, search, etc.). Architecture:

```
Claude Desktop  ──stdio JSON-RPC──▶  memor-mcp  ──HTTP /mcp──▶  Memor.app (StatelessHTTPServerTransport)
```

- **In-app server**: `MemorMCPServer` owns a `Server` + `StatelessHTTPServerTransport` + `MCPHTTPListener` bound to `127.0.0.1:51745` (see `MCPConstants`). Uses the `modelcontextprotocol/swift-sdk` SPM dependency.
- **Stdio helper** (`memor-mcp/main.swift`): a separate command-line tool target. The build embeds the binary in `Memor.app/Contents/MacOS/` via a Copy Files build phase. Claude Desktop's `claude_desktop_config.json` points `"command"` at `/Applications/Memor.app/Contents/MacOS/memor-mcp`.
- **Sandbox**: requires `com.apple.security.network.server` in [Memor.entitlements](Memor.entitlements). The listener binds loopback only.

### Tool surface (~41 tools in `MemorMCPTools.swift`)

- **Types**: `list_types`, `get_type` (read-only — schema management is intentionally NOT exposed; Person exposes `is_person`, `builtin_query_kinds`, per-field `is_protected`).
- **Instances**: `create_instance` / `create_instances` (per-item batch results), `update_instance`, `delete_instance`, `get_instance` (field values, per-query SRS status; Person adds `relations` + `builtin_queries`; map-shaped payload for map instances), `search_instances` (limit + optional full field values). Field values can be keyed by field name or field ID.
- **Person**: `update_person_relations` — full-state slot editing through `savePersonInstance` (identical propagation + contradiction blocking as the UI; conflicts return a structured `contradictions` error with nothing written). `update_person_offices` — full-state ordered holdings editing (items name EXISTING offices by id or case-insensitive name; never creates offices; succession replace + AUTO-ADD semantics identical to the UI). `update_instance` on a Person routes its field writes through the same engine (sex changes propagate or block). `delete_instance` converts references to bare names and drops succession edges.
- **Offices**: `list_offices` (holder counts, name filter), `create_office`, `update_office` (rename/description), `delete_office` (irreversible cascade: holdings + edges + per-office queries).
- **Maps**: `create_pointmap_instance`, `update_pointmap_instance`, `add_pointmap_point`, `update_pointmap_point`, `delete_pointmap_point`, `create_boundarymap_instance`, `update_boundarymap_instance`, `list_boundary_sets`, `list_boundaries`.
- **SRS maintenance**: `reset_due_dates` (by search or pairs; pair items accept `{instance_id, person_kind, partnership_id?, office_id?}` — partnership_id exactly for children_with, office_id exactly for office), `set_queries_enabled` (same person items), `set_max_interval` (Person built-ins have no max interval). Auto-studying (`applyStudyResponse` etc.) is intentionally NOT exposed.
- **Collections**: list/get/create/delete/rename + add/remove instance(s).
- **Queries/Stacks**: `search_queries` (limit; `is_reverse` for map queries; `person_kind`/`partnership_id`/`office_id` for Person built-ins), `render_query` (final question/answer HTML — pass `person_kind` (+ `partnership_id` or `office_id`) for Person built-ins — or map payload), `describe_search_syntax`, `list_stacks` (optional color counts), `create_stack`, `update_stack`, `delete_stack`.

### Non-obvious gotchas (do not "simplify" these away)

- **`memor-mcp` reads stdin with raw `Darwin.read(0, …)`, not `FileHandle.standardInput`.** Foundation's `FileHandle` buffers pipe reads from a parent process and doesn't return bytes until the pipe is closed, producing a ~60s hang per JSON-RPC message when spawned by Claude Desktop. Raw POSIX `read(2)` returns as soon as any bytes arrive.
- **`memor-mcp` uses raw BSD sockets, not `URLSession`.** `URLSession` has multi-second latency when the process is spawned by sandboxed apps like Claude Desktop. `socket(AF_INET, SOCK_STREAM, 0)` + `connect()` + `send()` + `recv()` is fast.
- **HTTP `Accept` header must include both `application/json` and `text/event-stream`.** The MCP Streamable HTTP spec requires it; omitting `text/event-stream` makes the in-app listener return `406 Not Acceptable`.
- **`MemorMCPServer` overrides the SDK's default `Initialize` handler with an idempotent one.** The SDK's built-in handler sets a private `isInitialized` flag and throws `-32600 "Server is already initialized"` on every subsequent `initialize` request. Claude Desktop respawns the helper for each chat session and sends a fresh `initialize` each time, so the default handler breaks every session after the first. The override returns a valid `Initialize.Result` without checking state. The server runs in default (non-strict) configuration, so tool calls don't require `isInitialized` to be set.
- **Every MCP tool that mutates the DB must post `memorDidChangeDatabase`** (see `MCPConstants`) so the visible page states (`StacksPageState`, `InstancesPageState`, `CollectionsPageState`) refetch and the SwiftUI views update live while Claude is acting.

### Adding a new MCP tool

Edit [Memor/MCP/MemorMCPTools.swift](Memor/MCP/MemorMCPTools.swift):

1. Add a `Tool(...)` entry to the `tools` array in `register(on:appDatabase:)` with a JSON schema for its args.
2. Add a `case` to the `withMethodHandler(CallTool.self)` dispatch that decodes the args, calls `AppDatabase`, and returns `CallTool.Result(content: [.text(text: jsonResult, annotations: nil, _meta: nil)])`.
3. If the tool writes to the DB, post `NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)` on `MainActor` after the write.

No changes to `MemorMCPServer`, the helper, or the listener are needed — new tools are a pure addition inside `MemorMCPTools.swift`.

## Xcode Project

- Target name is `Memor`, project file is `Memor.xcodeproj`.
- The `Memor/` group is a `PBXFileSystemSynchronizedRootGroup` — Swift files added anywhere under `Memor/` are auto-picked-up by the target. Do not add explicit `PBXFileReference` entries for new files.
- The `Products` group in `project.pbxproj` is Xcode's standard built-products virtual group (owns `Memor.app`, referenced by `productRefGroup`). Do not delete it.
- `memor-mcp/` is a separate command-line-tool target. The `Memor` app target has a Copy Files build phase (destination: Executables, subpath `Contents/MacOS`) that embeds the built `memor-mcp` binary inside `Memor.app`.
- SPM dependencies include `modelcontextprotocol/swift-sdk` (the `MCP` product), used by both the app target and the `memor-mcp` target.

## Distribution (TestFlight / Mac App Store)

- App Store Connect record: "Memor: Study Tool" (SKU `memor`), team `4A6G9YXAJT`, Apple ID <Apple ID: see CLAUDE.local.md>. The record's bundle ID is **`com.samhooper.Memor`** — NOT the local `com.sam.Memor`. (History: the record was first created as lowercase `com.sam.memor`; Apple reserves App IDs case-insensitively forever — deleting the record leaves the ID "in use by the App Store" — so neither `com.sam.Memor` nor a reuse of the lowercase one was viable, and a fresh ID was registered instead.)
- Local builds MUST keep `com.sam.Memor` (capital M) — the sandbox container (DB path) and security-scoped image bookmarks are keyed to it. The app target's Release `PRODUCT_BUNDLE_IDENTIFIER` is `$(MEMOR_APP_BUNDLE_ID:default=com.sam.Memor)`, so only distribution archives override it. The memor-mcp helper keeps `com.sam.Memor.mcp` everywhere.
- Archive: `xcodebuild -project Memor.xcodeproj -scheme Memor -configuration Release archive -archivePath <path>.xcarchive MEMOR_APP_BUNDLE_ID=com.samhooper.Memor -allowProvisioningUpdates`
- Upload: `xcodebuild -exportArchive -archivePath <path>.xcarchive -exportOptionsPlist ExportOptions.plist -authenticationKeyPath ~/Desktop/AppleDevelopment/AuthKey_<key ID>.p8 -authenticationKeyID <key ID> -authenticationKeyIssuerID <issuer ID>`. Signed-in-account auth does NOT work from the CLI (stale keychain Xcode tokens); always pass the API-key flags. The `.p8` lives outside the repo.
- Signing is MANUAL (see ExportOptions.plist) — the API key lacks cloud-managed-certificate permission, so `-allowProvisioningUpdates` cloud signing fails with "Cloud signing permission error". The "3rd Party Mac Developer Application/Installer" certificates were created via the ASC API from a local CSR (private key lives in the login keychain; certs/profile can be recreated through the API any time) and the "Memor Mac App Store" provisioning profile is installed under `~/Library/MobileDevice/Provisioning Profiles/`.
- ASC app ID `<ASC app ID>`; TestFlight external group "Friends". The ASC API drives all of TestFlight (groups, testers, review submissions) — only app-record create/delete needs the web UI.
- Bump `CURRENT_PROJECT_VERSION` (both app configs) before each new upload; TestFlight builds expire after 90 days.
- Mac App Store requirements already baked in — don't undo: memor-mcp is sandboxed with its own entitlements + `CREATE_INFOPLIST_SECTION_IN_BINARY` (a standalone sandboxed CLI crashes in `_libsecinit_appsandbox` at launch without an embedded Info.plist to key its container) and `SKIP_INSTALL = YES` (otherwise the tool lands in the archive as a second product at usr/local/bin, making the archive "generic" — the symptom is exportArchive reporting zero valid methods: `expected one {}`). The app target carries `INFOPLIST_KEY_LSApplicationCategoryType` and `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO`.
- Never install the TestFlight build on Sam's own machine over the locally built /Applications/Memor.app (different bundle ID → different container).
