# Memor

A macOS flashcard app in the spirit of Anki. Built with Swift, SwiftUI, and AppKit, with local SQLite persistence via [GRDB](https://github.com/groue/GRDB.swift). The app also hosts an in-process [MCP](https://modelcontextprotocol.io) server so Claude Desktop can create and search instances, manage collections, and more.

## Requirements

- macOS 26.4 or later (the app's deployment target).
- Xcode 26.4 or later.
- An internet connection for the first build. Swift Package Manager fetches GRDB and the MCP Swift SDK at the versions pinned in `Package.resolved`.

## Building and running

1. Clone the repo and open `Memor.xcodeproj` in Xcode.
2. Set the signing team on **both** targets, `Memor` and `memor-mcp`: select the target, open **Signing & Capabilities**, and pick your own team under **Team**. A free Apple ID with a Personal Team is enough. If Xcode has no account yet, add one under **Xcode → Settings → Accounts** first.
3. Select the `Memor` scheme and Run. The `memor-mcp` helper builds automatically and is embedded inside `Memor.app`.

Step 2 is required: the project file carries the author's team ID, so until you change it Xcode reports that no account exists for that team. If Xcode also objects to the bundle identifier `com.sam.Memor`, change it to anything you like. It only determines where the app's sandbox container, and therefore its database, lives.

## Where your data lives

The app is sandboxed. Its SQLite database is created on first launch at:

```
~/Library/Containers/<bundle identifier>/Data/Library/Application Support/Memor/Memor.sqlite
```

Images and audio files you insert into fields stay where they are on disk; the app keeps security-scoped bookmarks to them.

## Claude Desktop integration (optional)

While Memor is running it listens on `127.0.0.1:51745`. To let Claude Desktop use it, add a server entry to `claude_desktop_config.json` that points at the helper embedded in your built app, for example:

```json
{
  "mcpServers": {
    "memor": {
      "command": "/Applications/Memor.app/Contents/MacOS/memor-mcp"
    }
  }
}
```

Adjust the path to wherever your `Memor.app` ends up.

## Documentation

`CLAUDE.md` is the detailed reference for the architecture, domain model, search language, spaced-repetition rules, keyboard shortcuts, and MCP tool surface. It is written for AI coding assistants but is the best place to start for humans too.

Third-party assets bundled with the app, including the Natural Earth country boundaries behind the built-in "Countries" set, are listed in `ATTRIBUTIONS.md`.

## License

Memor is released under the MIT License. See `LICENSE`.
