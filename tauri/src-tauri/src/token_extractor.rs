use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rusqlite::Connection;
use std::path::PathBuf;

#[derive(Debug)]
pub struct TokenInfo {
    pub session_token: String,
    pub user_id: String,
}

#[derive(Debug, thiserror::Error)]
pub enum TokenError {
    #[error("Cursor database not found at: {0}")]
    DatabaseNotFound(String),
    #[error("Cannot open database: {0}")]
    CannotOpen(String),
    #[error("Query failed: {0}")]
    QueryFailed(String),
    #[error("No auth token found in Cursor database. Are you logged in?")]
    TokenNotFound,
    #[error("Auth token is not a valid JWT")]
    InvalidJwt,
    #[error("JWT missing 'sub' claim")]
    MissingSubClaim,
}

/// Path to the Cursor SQLite database, platform-aware.
fn database_path() -> PathBuf {
    let base = if cfg!(target_os = "macos") {
        dirs::home_dir()
            .unwrap()
            .join("Library/Application Support")
    } else if cfg!(target_os = "windows") {
        dirs::config_dir().unwrap() // %APPDATA%
    } else {
        // Linux
        dirs::config_dir().unwrap() // ~/.config
    };
    base.join("Cursor/User/globalStorage/state.vscdb")
}

/// Extract the session token from the Cursor local database.
/// Returns (session_token, user_id) where session_token is formatted as
/// "{userId}%3A%3A{jwtToken}" for use as the WorkosCursorSessionToken cookie.
pub fn extract_token() -> Result<TokenInfo, TokenError> {
    let db_path = database_path();

    if !db_path.exists() {
        return Err(TokenError::DatabaseNotFound(
            db_path.to_string_lossy().to_string(),
        ));
    }

    let conn = Connection::open_with_flags(&db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| TokenError::CannotOpen(e.to_string()))?;

    let jwt_token: String = conn
        .query_row(
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
            [],
            |row| row.get(0),
        )
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => TokenError::TokenNotFound,
            other => TokenError::QueryFailed(other.to_string()),
        })?;

    let user_id = extract_user_id_from_jwt(&jwt_token)?;
    let session_token = format!("{}%3A%3A{}", user_id, jwt_token);

    Ok(TokenInfo {
        session_token,
        user_id,
    })
}

/// Decode a JWT payload (without verification) to extract the 'sub' claim.
/// The 'sub' field looks like "auth0|{userId}" — we extract just the userId part.
fn extract_user_id_from_jwt(jwt: &str) -> Result<String, TokenError> {
    let parts: Vec<&str> = jwt.split('.').collect();
    if parts.len() < 2 {
        return Err(TokenError::InvalidJwt);
    }

    let payload_bytes = URL_SAFE_NO_PAD
        .decode(parts[1])
        .map_err(|_| TokenError::InvalidJwt)?;

    let payload: serde_json::Value =
        serde_json::from_slice(&payload_bytes).map_err(|_| TokenError::InvalidJwt)?;

    let sub = payload["sub"]
        .as_str()
        .ok_or(TokenError::MissingSubClaim)?;

    // The sub field is "provider|userId" — extract the userId after the pipe
    let user_id = sub
        .split('|')
        .nth(1)
        .unwrap_or(sub)
        .to_string();

    Ok(user_id)
}
