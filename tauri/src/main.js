const { invoke } = window.__TAURI__.core;
const { getCurrentWindow } = window.__TAURI__.window;
const { listen } = window.__TAURI__.event;

function spendColorClass(dollars) {
  if (dollars >= 50) return "spend-red";
  if (dollars >= 10) return "spend-amber";
  if (dollars > 0) return "spend-green";
  return "spend-dim";
}

function formatModelName(name) {
  return name
    .replace(/-high-thinking/g, " (thinking)")
    .replace(/-preview/g, "");
}

function formatDollars(amount) {
  return "$" + amount.toFixed(2);
}

function renderPeriods(container, periods) {
  container.innerHTML = "";
  periods.forEach((p) => {
    const row = document.createElement("div");
    row.className = "period-row";
    row.innerHTML = `
      <span class="period-label">${p.label}</span>
      <span class="period-spend ${spendColorClass(p.spendDollars)}">${formatDollars(p.spendDollars)}</span>
      <span class="period-reqs">(${p.requests} req)</span>
    `;
    container.appendChild(row);
  });
}

function renderModels(container, lineItems) {
  container.innerHTML = "";
  const items = lineItems.slice(0, 5);
  items.forEach((item) => {
    const row = document.createElement("div");
    row.className = "model-row";
    row.innerHTML = `
      <span class="model-name">${formatModelName(item.modelName)}</span>
      <span class="model-reqs">${item.requestCount} req</span>
      <span class="model-dash">&mdash;</span>
      <span class="model-cost ${spendColorClass(item.costDollars)}">${formatDollars(item.costDollars)}</span>
    `;
    container.appendChild(row);
  });
}

async function loadData() {
  const errorEl = document.getElementById("error");
  const contentEl = document.getElementById("content");
  const loadingEl = document.getElementById("loading");

  try {
    const [data, error] = await Promise.all([
      invoke("get_usage_data"),
      invoke("get_error"),
    ]);

    loadingEl.style.display = "none";

    if (error) {
      errorEl.textContent = error;
      errorEl.style.display = "block";
    } else {
      errorEl.style.display = "none";
    }

    if (data) {
      contentEl.style.display = "block";
      renderPeriods(document.getElementById("periods"), [
        data.today,
        data.last7Days,
        data.last30Days,
      ]);
      renderModels(document.getElementById("models"), data.lineItems);
    }
  } catch (e) {
    loadingEl.style.display = "none";
    errorEl.textContent = "Failed to load: " + e;
    errorEl.style.display = "block";
  }
}

// Action buttons
document.getElementById("btn-refresh").addEventListener("click", async () => {
  document.getElementById("loading").style.display = "block";
  document.getElementById("loading").textContent = "Refreshing...";
  await invoke("refresh");
  await loadData();
});

document.getElementById("btn-dashboard").addEventListener("click", async () => {
  await invoke("open_dashboard");
});

document.getElementById("btn-quit").addEventListener("click", () => {
  window.__TAURI__.process.exit(0);
});

// Close the popup when it loses focus (like a native tray popup)
const appWindow = getCurrentWindow();
appWindow.onFocusChanged(({ payload: focused }) => {
  if (!focused) {
    appWindow.hide();
  }
});

// Listen for refresh events from the backend
listen("usage-updated", () => {
  loadData();
});

// Load on startup
loadData();
