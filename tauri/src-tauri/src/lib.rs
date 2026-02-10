mod cursor_api;
mod models;
mod token_extractor;

use cursor_api::CursorApi;
use models::UsageDisplayData;
use std::sync::Mutex;
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager,
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
    // Emit event so the popup window reloads data
    let _ = app.emit("usage-updated", ());
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
            update_tray_tooltip(app, "Cursor Status Bar\nError: token extraction failed");
            return;
        }
    };

    if let Some(api) = api {
        match api.fetch_display_data().await {
            Ok(data) => {
                let today_spend = format!("${:.2}", data.today.spend_dollars);
                let period_spend = format!("${:.2}", data.total_spend_dollars);

                // macOS: show short text in the menu bar
                #[cfg(target_os = "macos")]
                if let Some(tray) = app.tray_by_id("main-tray") {
                    let _ = tray.set_title(Some(&today_spend));
                }

                // Tooltip for all platforms (hover on Windows/Linux)
                let tooltip = format!(
                    "Cursor Status Bar\nToday: {} ({} req)\nLast 7 Days: ${:.2} ({} req)\nBilling Period: {} ({} req)",
                    today_spend, data.today.requests,
                    data.last7_days.spend_dollars, data.last7_days.requests,
                    period_spend, data.total_requests
                );
                update_tray_tooltip(app, &tooltip);

                let mut s = state.lock().unwrap();
                s.last_data = Some(data);
                s.error = None;
            }
            Err(e) => {
                eprintln!("[CursorStatusBar] API error: {}", e);
                update_tray_tooltip(app, &format!("Cursor Status Bar\nError: {}", e));

                let mut s = state.lock().unwrap();
                s.error = Some(format!("API error: {}", e));
            }
        }
    }
}

/// Update the tray icon tooltip (shown on hover on all platforms).
fn update_tray_tooltip(app: &AppHandle, text: &str) {
    if let Some(tray) = app.tray_by_id("main-tray") {
        let _ = tray.set_tooltip(Some(text));
    }
}

/// Show or create the popup window, positioned near the tray area.
fn show_popup(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("popup") {
        if window.is_visible().unwrap_or(false) {
            let _ = window.hide();
            return;
        }
        let _ = window.show();
        let _ = window.set_focus();
    } else {
        let builder = tauri::WebviewWindowBuilder::new(
            app,
            "popup",
            tauri::WebviewUrl::App("index.html".into()),
        )
        .title("Cursor Status Bar")
        .inner_size(440.0, 480.0)
        .resizable(false)
        .always_on_top(true)
        .visible(true)
        .focused(true);

        // On Windows, use decorations for a proper window; on macOS, go frameless
        #[cfg(target_os = "macos")]
        let builder = builder.decorations(false);

        #[cfg(not(target_os = "macos"))]
        let builder = builder.decorations(true);

        let _ = builder.build();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    // Single instance: must be registered FIRST
    #[cfg(desktop)]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // When a second instance is launched, show the popup of the existing one
            show_popup(app);
        }));
    }

    builder
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

            // Build tray menu (right-click on Windows, or fallback)
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
                            show_popup(tray.app_handle());
                        }
                    }
                })
                .build(app)?;

            // macOS: show short loading text in menu bar
            #[cfg(target_os = "macos")]
            if let Some(tray) = app.tray_by_id("main-tray") {
                let _ = tray.set_title(Some("$..."));
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
