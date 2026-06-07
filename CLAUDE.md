# Memor

A macOS flashcard app (similar to Anki) built with Swift/SwiftUI and GRDB for local SQLite persistence. (The Xcode project name is `Memor`; a few legacy files and identifiers still say "Flashcards2".)

## Project Structure

```
Flashcards2/
  Flashcards2App.swift              App entry point, window scene definitions
  ContentView.swift                 Main window shell: AppTab, AppNavigationState, ContentView, TabPageView
  AppDatabase.swift                 Database class + init + CRUD + search parsing + SRS (large; incremental splits underway — see Database/)
  Utilities.swift                   Cross-cutting helpers (QueryRenderContent etc.) that don't yet belong elsewhere
  AddInstanceWindowView.swift       Thin wrappers only: AddInstanceWindowState, EditInstanceWindowState, QueryPreviewWindowState, AddInstanceWindowView, EditInstanceWindowView
  InstanceSearchWindowView.swift    Instance search + Query search windows
  QueryPreviewWindowView.swift      Query preview WKWebView window
  TypesPageView.swift               Types list view + TypeRowView
  Database/
    AppDatabase+Schema.swift        createSchema (run every launch) + idempotent migration helpers; canonical table/index definitions
  Models/
    DatabaseModels.swift            All plain-data structs/enums returned by AppDatabase
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
    InstanceFieldEditor.swift       Per-field editor cell, InstanceTextView (NSViewRepresentable), AddInstanceFieldFocusController
    NodeLinkFieldEditor.swift       Node-instance link-field editor: target chips + search popover (uses fetchNodeCandidates)
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
    ToastView.swift                 ToastMessage, ToastStyle, ToastView (used by InstanceEditor)
    WindowKeyCommandHandler.swift   Background NSViewRepresentable wiring ⌘Return/⌘S/⌘B/⌘I/⌘O/⌘J/⌘L/⌘T/Esc
    PlainTextEditor.swift           NSTextView wrapper for plain-text fields
    PlainCodeTextView.swift         Code editor NSTextView + FocusedEditor + query-type editor split view
    SearchHighlightingTextView.swift Search field + highlight rendering used across search windows
    QueryHTMLView.swift             WKWebView wrapper for rendering query HTML (+ scheme handler)
    HTMLPreviewView.swift           Live-preview WebView for the Types page HTML/CSS editors
  Windows/
    SettingsWindowView.swift        Settings UI with key recorder and conflict resolution
    GlobalCodeEditorWindow.swift    Standalone HTML/CSS editor window opened from the Types page
  MCP/
    MCPConstants.swift              Host/port/path constants + memorDidChangeDatabase notification name
    MCPHTTPListener.swift           Minimal HTTP/1.1 loopback listener (Network.framework) feeding StatelessHTTPServerTransport
    MemorMCPServer.swift            Lifecycle manager: starts Server + transport + listener, overrides Initialize handler
    MemorMCPTools.swift             Tool registration — one function per MCP tool, calls AppDatabase directly
memor-mcp/
  main.swift                        Stdio ↔ HTTP proxy binary Claude Desktop spawns; embedded in Memor.app/Contents/MacOS/
```

## Domain Model

There are three classes of type, discriminated by `type.kind` ('object' | 'node') plus the built-in Map types (identified by name + `is_builtin`):
- **Object types** (`kind='object'`) — the open, default class: text fields + user query types.
- **Node types** (`kind='node'`) — an open class where each instance can link ("edge") to zero-or-more instances of the same type. Node types reuse all Object machinery (text fields in `type{N}`, `query_type`/`query`, HTML rendering, per-type CSS, per-instance enabled query types, Max Interval) and add link fields.
- **Map types** (`PointMap`, `BoundaryMap`) — the closed, built-in class with bespoke editors/tables (`kind='object'`, identified by name + `is_builtin`).

- **Type** (`type` table) - User-defined data type with named fields, CSS, and `kind`
- **Field** (`field` table) - Named text field on a type, with `field_index`, `field_display_index`, and `is_primary`. For Node types the primary field is kept at BOTH `is_primary=1` and `field_display_index=1` so all display-value SQL (keyed on `display_index=1`) works unchanged.
- **LinkField** (`link_field` table) - Node-only edge field: `name`, `is_parent` (stored metadata only), `min_count`, `max_count` (NULL = unlimited), `link_field_index`. Creating one auto-creates an undeleteable link `query_type` (only its question is editable; the answer is computed from the instance's links at render time).
- **NodeLink** (`node_link` table) - A directed edge `(source_instance_id, link_field_id, target_instance_id, order_index)`. Cascades clean up on instance- or link-field deletion.
- **Instance** (`instance_id_type_id` + `type{N}` tables) - Concrete object of a type. Each type has its own dynamic table `type{typeID}` with columns `field{fieldID}` (text fields only)
- **QueryType** (`query_type` table) - Defines a question template (question_html + answer_html) for a type. `link_field_id` is non-NULL for auto-generated Node link query types.
- **Query** (`query` table) - A flashcard prompt for a specific instance+query_type pair. Tracks `interval`, `last_answered_timestamp`, `was_last_answer_correct`
- **Collection** (`collection` + `instance_id_collection_id` tables) - Named group of instances (cross-type, many-to-many)
- **Stack** (`stack` table) - Named set of queries defined by a `search` string

## Database

- SQLite via GRDB (`DatabaseQueue`)
- App Sandbox enabled
- DB path: `~/Library/Containers/com.sam.Flashcards2/Data/Library/Application Support/Flashcards2/Flashcards2.sqlite`
- Dynamic per-type tables: `type{typeID}` with columns `field{fieldID}`
- Global settings in `globals` table (global_query_html, global_query_css, stacks_last_updated_timestamp)
- Security-scoped bookmarks for image file access (`image_file` table)
- **Migrations.** `AppDatabase.init` runs `createSchema` on every launch. `createSchema` creates tables with `CREATE TABLE IF NOT EXISTS` and calls idempotent migration helpers (e.g. `migrateNodeTypeColumns`, `migrateQueryStateColumn`, `migrateReverseQueryColumns`, `migrateQueryMaxIntervalColumn`) that add new columns guarded by `PRAGMA table_info` checks, so existing databases upgrade in place on launch without data loss. To evolve the schema, update `createSchema` and add/extend an idempotent migration helper for any new column (new tables just use `CREATE TABLE IF NOT EXISTS`).

## Search Query Language

- Space-separated components combined with AND
- `literal:text` - field contains text
- `collection:name` or `col:name` - instance in named collection
- `type:name` - instance of named type
- `id:number` - the single instance with this ID
- `:noqueries` - **instance search only** - instances with no query types enabled (no `query` rows; for PointMap/BoundaryMap, no points / boundary queries). Rejected in query search. The instance-vs-query distinction is enforced by the `allowsNoQueries` flag threaded through `parseSearchExpression`.
- Components can use `or(...)` for OR logic
- Double quotes for spaces inside components: `"literal:hi there"`
- Empty query matches all
- The two help windows (`InstanceSearchHelpWindowView` / `QuerySearchHelpWindowView`, opened from the `?` button beside each search box) document these components; only the instance one lists `:noqueries`.

## Spaced Repetition

- Query colors: blue (new, interval=0), red (seen, interval < 1 day), green (seen, interval < 1 day but answered correctly), magenta (interval >= 1 day)
- Starter delays: 60s and 600s
- Rating multipliers: Again (reset to starter), Hard (1.2x), Good (2.5x), Easy (3.25x)
- Study mode loads queries into blue/red/green pools, prioritizes overdue red queries, then randomly picks from blue+green

## Keyboard Shortcuts

The shortcut system lives in `Flashcards2/Shortcuts/`. **Customizable** shortcuts are driven by a registry, persisted to UserDefaults (key `com.sam.Memor.shortcuts`), and re-render the UI live when changed via `ShortcutSettings: ObservableObject`.

### Adding a new customizable shortcut

1. Add a case to `ShortcutAction` in `Shortcuts/ShortcutAction.swift` with `title`, `category`, and `default: KeyBinding`.
2. Apply it to the SwiftUI view: `.shortcut(.myAction, settings: shortcutSettings)` (replaces `.keyboardShortcut(...)`).
3. Display it in button text: `ShortcutLabel(title: "Save", action: .myAction)` or interpolate `shortcutSettings.binding(for: .myAction).displayString`.
4. For `NSEvent.addLocalMonitorForEvents` handlers, store a `ShortcutSettings` ref on the NSView and call `settings.binding(for: .myAction).matches(event)`. See `StudyModeKeyCommandHandler` in ContentView.swift for a reference implementation.
5. Every scene that hosts the view must inject `.environmentObject(shortcutSettings)` (see Flashcards2App.swift).

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
  visible on the showing query. Node link-field auto-generated answer links are out of scope
  (they aren't stored in a text field and can't carry `data-shortcut`).
- If two+ links on the instance share the same shortcut, pressing that key shows a system
  `NSAlert` instead of navigating.
- Implementation: [Flashcards2/Shared/LinkShortcuts.swift](Flashcards2/Shared/LinkShortcuts.swift)
  (`parseLinkShortcuts` / `resolveLinkShortcut` / `presentLinkShortcutCollisionAlert`,
  reusing `parseLinkedInstanceID` / `parseLinkedQueryID` from `Shared/QueryHTMLView.swift`).
  Wired into the key monitors in `Study/StudyModeView.swift` and `QueryPreviewWindowView.swift`.

### Built-in defaults

| Action | Default |
|---|---|
| Go to Stacks / Instances / Collections / Types / Graph | ⌘1–⌘5 |
| Add Instance | ⌘⇧A |
| Search Instances | ⌘⇧S |
| Search Queries | ⌘⌥S |
| Settings | ⌘, |
| Study — reveal / Good | Space |
| Study — Again / Hard / Good / Easy | 1 / 2 / 3 / 4 |
| Study — Undo | ⌘Z |
| Study — Edit current instance | E |
| Instance editor — Save | ⌘S |
| Types page — Save current editor | ⌘S |
| Query Search — Reset Due Dates | ⌘R |

## Key Patterns

- Window state communicated via `@StateObject` ObservableObject classes with UUID nonces for change detection
- NSViewRepresentable used extensively for key command handling (NSEvent monitors) and WKWebView
- HTML field values rendered via template substitution: `{{FieldName}}` placeholders, `{{{Content}}}` for global wrapper, `{{#QuestionContent}}` for answer-side question reference
- Local images served via custom WKURLSchemeHandler (`flashcards-local-image://`)
- Prefer `pointerStyle(...)` over NSCursor for hover effects
- Escape key closes all secondary windows
- Customizable keyboard shortcuts are routed through `ShortcutSettings` / `.shortcut(.action, settings:)` — don't hard-code `.keyboardShortcut(...)` for actions a user should be able to rebind.

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
- **Sandbox**: requires `com.apple.security.network.server` in [Flashcards2.entitlements](Flashcards2.entitlements). The listener binds loopback only.

### Non-obvious gotchas (do not "simplify" these away)

- **`memor-mcp` reads stdin with raw `Darwin.read(0, …)`, not `FileHandle.standardInput`.** Foundation's `FileHandle` buffers pipe reads from a parent process and doesn't return bytes until the pipe is closed, producing a ~60s hang per JSON-RPC message when spawned by Claude Desktop. Raw POSIX `read(2)` returns as soon as any bytes arrive.
- **`memor-mcp` uses raw BSD sockets, not `URLSession`.** `URLSession` has multi-second latency when the process is spawned by sandboxed apps like Claude Desktop. `socket(AF_INET, SOCK_STREAM, 0)` + `connect()` + `send()` + `recv()` is fast.
- **HTTP `Accept` header must include both `application/json` and `text/event-stream`.** The MCP Streamable HTTP spec requires it; omitting `text/event-stream` makes the in-app listener return `406 Not Acceptable`.
- **`MemorMCPServer` overrides the SDK's default `Initialize` handler with an idempotent one.** The SDK's built-in handler sets a private `isInitialized` flag and throws `-32600 "Server is already initialized"` on every subsequent `initialize` request. Claude Desktop respawns the helper for each chat session and sends a fresh `initialize` each time, so the default handler breaks every session after the first. The override returns a valid `Initialize.Result` without checking state. The server runs in default (non-strict) configuration, so tool calls don't require `isInitialized` to be set.
- **Every MCP tool that mutates the DB must post `memorDidChangeDatabase`** (see `MCPConstants`) so the visible page states (`StacksPageState`, `InstancesPageState`, `CollectionsPageState`) refetch and the SwiftUI views update live while Claude is acting.

### Adding a new MCP tool

Edit [Flashcards2/MCP/MemorMCPTools.swift](Flashcards2/MCP/MemorMCPTools.swift):

1. Add a `Tool(...)` entry to the `tools` array in `register(on:appDatabase:)` with a JSON schema for its args.
2. Add a `case` to the `withMethodHandler(CallTool.self)` dispatch that decodes the args, calls `AppDatabase`, and returns `CallTool.Result(content: [.text(text: jsonResult, annotations: nil, _meta: nil)])`.
3. If the tool writes to the DB, post `NotificationCenter.default.post(name: .memorDidChangeDatabase, object: nil)` on `MainActor` after the write.

No changes to `MemorMCPServer`, the helper, or the listener are needed — new tools are a pure addition inside `MemorMCPTools.swift`.

## Xcode Project

- Target name is `Memor`, project file is `Memor.xcodeproj`.
- The `Flashcards2/` group is a `PBXFileSystemSynchronizedRootGroup` — Swift files added anywhere under `Flashcards2/` are auto-picked-up by the target. Do not add explicit `PBXFileReference` entries for new files.
- The `Products` group in `project.pbxproj` is Xcode's standard built-products virtual group (owns `Memor.app`, referenced by `productRefGroup`). Do not delete it.
- `memor-mcp/` is a separate command-line-tool target. The `Memor` app target has a Copy Files build phase (destination: Executables, subpath `Contents/MacOS`) that embeds the built `memor-mcp` binary inside `Memor.app`.
- SPM dependencies include `modelcontextprotocol/swift-sdk` (the `MCP` product), used by both the app target and the `memor-mcp` target.
