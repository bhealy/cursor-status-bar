import Foundation
import SQLite3

enum TokenError: Error, LocalizedError {
    case databaseNotFound(String)
    case cannotOpenDatabase(String)
    case queryFailed(String)
    case tokenNotFound
    case invalidJWT
    case missingSubClaim

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return "Cursor database not found at: \(path)"
        case .cannotOpenDatabase(let msg):
            return "Cannot open database: \(msg)"
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        case .tokenNotFound:
            return "No auth token found in Cursor database. Are you logged in?"
        case .invalidJWT:
            return "Auth token is not a valid JWT"
        case .missingSubClaim:
            return "JWT missing 'sub' claim"
        }
    }
}

struct TokenExtractor {
    /// Path to the Cursor SQLite database on macOS
    static var databasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    /// Extract the session token from the Cursor local database.
    /// Returns a tuple of (sessionToken, userId) where sessionToken is
    /// formatted as "{userId}%3A%3A{jwtToken}" for use as the
    /// WorkosCursorSessionToken cookie.
    static func extractToken() throws -> (sessionToken: String, userId: String) {
        let dbPath = databasePath

        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw TokenError.databaseNotFound(dbPath)
        }

        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY
        let rc = sqlite3_open_v2(dbPath, &db, openFlags, nil)
        guard rc == SQLITE_OK, let database = db else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw TokenError.cannotOpenDatabase(msg)
        }
        defer { sqlite3_close(database) }

        var stmt: OpaquePointer?
        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
        let prepareRc = sqlite3_prepare_v2(database, query, -1, &stmt, nil)
        guard prepareRc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(database))
            throw TokenError.queryFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw TokenError.tokenNotFound
        }

        guard let cString = sqlite3_column_text(stmt, 0) else {
            throw TokenError.tokenNotFound
        }
        let jwtToken = String(cString: cString)

        // Decode the JWT payload to extract the 'sub' claim
        let userId = try extractUserIdFromJWT(jwtToken)

        // Construct the session token in the same format as the browser cookie
        let sessionToken = "\(userId)%3A%3A\(jwtToken)"

        return (sessionToken, userId)
    }

    /// Decode a JWT's payload (without verification) to extract the 'sub' claim.
    /// The 'sub' field looks like "auth0|{userId}" — we extract just the userId part.
    private static func extractUserIdFromJWT(_ jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            throw TokenError.invalidJWT
        }

        // Base64URL decode the payload
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let payloadData = Data(base64Encoded: base64) else {
            throw TokenError.invalidJWT
        }

        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let sub = json["sub"] as? String else {
            throw TokenError.missingSubClaim
        }

        // The sub field is "provider|userId" — extract the userId after the pipe
        let components = sub.split(separator: "|")
        let userId = components.count > 1 ? String(components[1]) : sub

        return userId
    }
}
