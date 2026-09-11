# Project Context

- App type: flashcards app similar to Anki
- Language: Swift
- UI framework: SwiftUI
- Platform note: AppKit may be used where necessary
- Local persistence: SQLite database stored on the user's machine
- Database toolkit: GRDB
- The app uses App Sandbox during development.
- Development sandbox database path: `/Users/samhooper/Library/Containers/com.sam.Memor/Data/Library/Application Support/Memor/Memor.sqlite`
- User-selected files and folders are persisted with security-scoped bookmarks so the app can keep loading local image and audio (.mp3) files across launches.

## Core Domain Model

- A "type" is a user-defined data type with several named fields.
- An "instance" is a concrete object of a type, with a value for each field.
- Instance field values may contain HTML, including `<img>` and `<audio controls>` tags that point at local files (individually granted, or inside granted folders).
- Each type has one or more "query types".
- A "query type" defines a kind of question the app can ask about instances of its associated type.
- A "query" is a concrete flashcard-like prompt for a specific instance.
- Each query has two sides: the query side shown first, and the answer side shown after the user flips it.
- Query rendering is defined by the query type using HTML and CSS.
- Once a query type exists for a type, the app can generate queries of that query type for any instance of that type.
- A "collection" is a set of instances. Instances of different types can be in the same collection. The same instance can be in multiple collections simultaneously.
- A "stack" is a named set of queries.
- A stack's contents are determined by its `search` string, which is a search query over rows in the `query` table.
- The purpose of a stack is to let the user study only a chosen subset of all queries in the database.

## Study Mode

- Study mode opens in the main app window when the user clicks a stack from the Stacks list.
- While Study mode is active, the top-level tab bar is hidden and a bottom button bar is shown instead.
- Study mode chooses the next query from the selected stack using the stack's saved `search` string and the spaced-repetition state in the `query` table.
- It first probabilistically chooses between a new query (`interval = 0`) and a seen query (`interval != 0`) based on the proportion of new queries in the stack.
- If it chooses a seen query, it shows the due query with the lowest `last_answered_timestamp + interval`; if none are due yet, Study mode shows the completion message.
- The user reveals the answer with Space or the `Reveal Answer` button.
- After revealing the answer, the user grades the query with `Again`, `Hard`, `Good`, or `Easy`, which updates `was_last_answer_correct`, `last_answered_timestamp`, and `interval`.
- Pressing Escape exits Study mode at any time. If the answer has been revealed but not graded yet, no study-state fields are changed.

## Instance Search Window

- The app has a separate "Search Instances" window, similar in spirit to the "Add Instance" window.
- Keyboard shortcut: `Command+Shift+S` opens the instance search window.
- The search window can search across all instances in the database, including instances from different types.
- Search results should be grouped by type.
- For now, each search result row displays only the field whose `field_display_index` is `1`.
- The search window has two modes:
  - Normal search mode.
  - Add-to-collection mode, opened from a collection detail page.
- In add-to-collection mode, each result row shows a checkbox that reflects whether the instance is currently in the target collection, and toggling the checkbox updates `instance_id_collection_id`.

## Query Search Window

- The app has a separate "Search Queries" window, opened from the Stacks tab via the `Add Stack` button.
- This window searches rows in the `query` table rather than instances directly.
- For now, each result row shows the first display field value of the query's instance plus the query type name.
- For now, the only implemented query-search component is `literal:`, with the same quoted-component behavior as instance search.

## Window Behavior

- Any newly added secondary window should support closing with the Escape key.

## SwiftUI Pointer Behavior

- On macOS in this app, prefer SwiftUI's view-local `pointerStyle(...)` for hover cursor behavior on clickable elements.
- Avoid trying to manage the cursor globally with `NSCursor.set()`, `push()`, or `pop()` for ordinary hover interactions; those approaches caused stale cursor state during view transitions.
- For stack cards specifically, the reliable pattern was to drive `pointerStyle(isHovered ? .link : .default)` from local hover state and clear that hover state on click before navigating away.

## Search Query Language

- A search query is a single line of space-separated components.
- Multiple components are combined with logical AND.
- The only implemented component right now is `literal:`.
- `literal:text` matches instances whose fields contain `text` anywhere in any field.
- `literal:` components can be combined, for example: `literal:cat literal:dog`.
- `collection:name` matches only instances that are in the collection named `name`.
- `col:name` is an abbreviation for `collection:name`.
- Components can optionally be wrapped in double quotes to include spaces inside a single component, for example: `"literal:hi there"`.
- An empty search query should match all instances.
