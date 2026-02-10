mod cursor_api;
mod models;
mod token_extractor;

use cursor_api::CursorApi;
use models::UsageDisplayData;
use std::sync::Mutex;
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    AppHandle, Manager,
};

/// Shared app state
struct AppState {
    api: Option<CursorApi>,
    last_data: Option<UsageDisplayData>,
    error: Option<String>,
}

/// Tauri command: get the latest usage data
#[tauri::command]
fn get_usage_data(state: tauri::State<'_, Mutex<AppState>>) -> Result<Option<UsageDisplayData>, String> {
    let state = state.lock().map_err(|e| e.to_string())?;
    Ok(state.last_data.clone())
}

/// Tauri command: get current error message
#[tauri::command]
fn get_error(state: tauri::State<'_, Mutex<AppState>>) -> Result<Option<String>, String> {
    let state = state.lock().map_err(|e| e.to_string())?;
    Ok(state.error.clone())
}

/// Tauri command: trigger a manual refresh
#[tauri::command]
async fn refresh(app: AppHandle) -> Result<(), String> {
    do_refresh(&app).await;
    Ok(())
}

/// Tauri command: open the Cursor dashboard in the default browser
#[tauri::command]
fn open_dashboard() -> Result<(), String> {
    open::that("https://cursor.com/dashboard?tab=usage").map_err(|e| e.to_string())
}

/// Perform a data refresh: fetch from API and update tray + state.
async fn do_refresh(app: &AppHandle) {
    let state = app.state::<Mutex<AppState>>();

    // Check if API is initialized
    {
        let s = state.lock().unwrap();
        if s.api.is_none() {
            return;
        }
    }

    // Re-extract token each time (it may have refreshed) and create a new API
    // instance. This avoids holding the Mutex across the await point.
    let api = match token_extractor::extract_token() {
        Ok(info) => Some(CursorApi::new(info.session_token, info.user_id)),
        Err(e) => {
            let mut s = state.lock().unwrap();
            s.error = Some(format!("Token error: {}", e));
            s.last_data = None;
            update_tray_text(app, "Cursor: err");
            return;
        }
    };

    if let Some(api) = api {
        match api.fetch_display_data().await {
            Ok(data) => {
                let today_spend = format!("${:.2}", data.today.spend_dollars);
                let period_spend = format!("${:.2}", data.total_spend_dollars);
                let tray_text = format!("Today: {}  |  Period: {}", today_spend, period_spend);
                let tooltip = format!(
                    "Cursor Usage\nToday: {} ({} req)\nPeriod: {} ({} req)",
                    today_spend, data.today.requests, period_spend, data.total_requests
                );

                update_tray_text(app, &tray_text);
                update_tray_tooltip(app, &tooltip);

                let mut s = state.lock().unwrap();
                s.last_data = Some(data);
                s.error = None;
            }
            Err(e) => {
                eprintln!("[CursorStatusBar] API error: {}", e);
                update_tray_text(app, "Cursor: err");

                let mut s = state.lock().unwrap();
                s.error = Some(format!("API error: {}", e));
            }
        }
    }
}

/// Update the tray icon title (visible text on macOS, ignored on Windows).
fn update_tray_text(app: &AppHandle, text: &str) {
    if let Some(tray) = app.tray_by_id("main-tray") {
        #[cfg(target_os = "macos")]
        let _ = tray.set_title(Some(text));
        // On Windows, title is not supported — tooltip is used instead
    }
}

/// Update the tray icon tooltip (shown on hover on all platforms).
fn update_tray_tooltip(app: &AppHandle, text: &str) {
    if let Some(tray) = app.tray_by_id("main-tray") {
        let _ = tray.set_tooltip(Some(text));
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_process::init())
        .manage(Mutex::new(AppState {
            api: None,
            last_data: None,
            error: None,
        }))
        .invoke_handler(tauri::generate_handler![
            get_usage_data,
            get_error,
            refresh,
            open_dashboard,
        ])
        .setup(|app| {
            // Extract token and initialize API
            let managed_state = app.state::<Mutex<AppState>>();
            match token_extractor::extract_token() {
                Ok(info) => {
                    let mut state = managed_state.lock().unwrap();
                    state.api = Some(CursorApi::new(info.session_token, info.user_id));
                }
                Err(e) => {
                    eprintln!("[CursorStatusBar] Token extraction failed: {}", e);
                    let mut state = managed_state.lock().unwrap();
                    state.error = Some(format!("Token error: {}", e));
                }
            }

            // Build tray menu
            let refresh_item = MenuItemBuilder::with_id("refresh", "Refresh Now").build(app)?;
            let dashboard_item =
                MenuItemBuilder::with_id("dashboard", "Open Cursor Dashboard").build(app)?;
            let quit_item = MenuItemBuilder::with_id("quit", "Quit").build(app)?;

            let menu = MenuBuilder::new(app)
                .items(&[&refresh_item, &dashboard_item, &quit_item])
                .build()?;

            // Build tray icon
            let _tray = TrayIconBuilder::with_id("main-tray")
                .icon(app.default_window_icon().unwrap().clone())
                .icon_as_template(true)
                .tooltip("Cursor Status Bar — Loading...")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(move |app, event| match event.id().as_ref() {
                    "refresh" => {
                        let app = app.clone();
                        tauri::async_runtime::spawn(async move {
                            do_refresh(&app).await;
                        });
                    }
                    "dashboard" => {
                        let _ = open::that("https://cursor.com/dashboard?tab=usage");
                    }
                    "quit" => {
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click { button, .. } = event {
                        if button == tauri::tray::MouseButton::Left {
                            let app = tray.app_handle();
                            // Toggle the popup window
                            if let Some(window) = app.get_webview_window("popup") {
                                if window.is_visible().unwrap_or(false) {
                                    let _ = window.hide();
                                } else {
                                    let _ = window.show();
                                    let _ = window.set_focus();
                                }
                            } else {
                                // Create the popup window near the tray icon
                                let _window = tauri::WebviewWindowBuilder::new(
                                    app,
                                    "popup",
                                    tauri::WebviewUrl::App("index.html".into()),
                                )
                                .title("Cursor Status Bar")
                                .inner_size(440.0, 480.0)
                                .resizable(false)
                                .decorations(false)
                                .always_on_top(true)
                                .visible(true)
                                .focused(true)
                                .build()
                                .ok();
                            }
                        }
                    }
                })
                .build(app)?;

            #[cfg(target_os = "macos")]
            if let Some(tray) = app.tray_by_id("main-tray") {
                let _ = tray.set_title(Some("Cursor: ..."));
            }

            // Initial refresh
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                do_refresh(&handle).await;
            });

            // Periodic refresh every 60 seconds
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                    do_refresh(&handle).await;
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
