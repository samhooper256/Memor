//
//  AppDatabase.swift
//  Flashcards2
//
//  Created by Codex on 4/1/26.
//

import Foundation
import GRDB

struct AppDatabase {
    let dbQueue: DatabaseQueue

    init(fileManager: FileManager = .default) throws {
        let databaseURL = try Self.makeDatabaseURL(fileManager: fileManager)
        let databasePath = databaseURL.path(percentEncoded: false)
        let isNewDatabase = !fileManager.fileExists(atPath: databasePath)
        var configuration = Configuration()

        configuration.prepareDatabase { db in
            if isNewDatabase {
                try db.execute(sql: "PRAGMA page_size = 4096")
                try db.execute(sql: "PRAGMA encoding = 'UTF-8'")
                try db.execute(sql: "PRAGMA auto_vacuum = NONE")
            }

            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        dbQueue = try DatabaseQueue(path: databasePath, configuration: configuration)
    }

    private static func makeDatabaseURL(fileManager: FileManager) throws -> URL {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = applicationSupportURL.appendingPathComponent("Flashcards2", isDirectory: true)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        return directoryURL.appendingPathComponent("Flashcards2.sqlite", isDirectory: false)
    }
}
