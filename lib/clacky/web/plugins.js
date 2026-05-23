// ── Plugins — plugins state, rendering, reload ─────────────────────────────
//
// Responsibilities:
//   - Single source of truth for plugins data
//   - Render the "Plugins" entry in the sidebar
//   - Show/render the plugins panel with plugin cards
//   - Hot reload plugins via POST /api/plugins/reload
//
// Panel switching is delegated to Router — Plugins only manages data + rendering.
//
// Depends on: Router (app.js), global $ / escapeHtml helpers, I18n (i18n.js)
// ─────────────────────────────────────────────────────────────────────────────

const Plugins = (() => {
  // ── Private state ──────────────────────────────────────────────────────────
  let _plugins = [];       // [{ key, name, version, description, enabled, ... }]
  let _loading = false;
  let _domWired = false;

  // ── Private helpers ────────────────────────────────────────────────────────

  /** Fetch plugins from the server. */
  async function _loadPlugins() {
    const container = $("plugins-list");
    if (!container) return;

    _loading = true;
    container.innerHTML = `<div class="plugins-loading">${I18n.t("plugins.loading") || "Loading plugins..."}</div>`;

    try {
      const res = await fetch("/api/plugins");
      const data = await res.json();

      if (!res.ok) {
        container.innerHTML = `<div class="plugins-error">${escapeHtml(data.error || "Failed to load plugins")}</div>`;
        return;
      }

      _plugins = data.plugins || [];
      _renderPlugins();
    } catch (e) {
      container.innerHTML = `<div class="plugins-error">Network error — please try again.</div>`;
      console.error("[Plugins] load failed", e);
    } finally {
      _loading = false;
    }
  }

  /** Render all plugins into the plugins panel. */
  function _renderPlugins() {
    const container = $("plugins-list");
    if (!container) return;
    container.innerHTML = "";

    if (_plugins.length === 0) {
      container.innerHTML = `<div class="plugins-empty">${I18n.t("plugins.empty") || "No plugins installed"}</div>`;
      return;
    }

    // Render all plugins in a flat grid (no grouping)
    _plugins.forEach(plugin => {
      const card = _renderPluginCard(plugin);
      container.appendChild(card);
    });
  }

  /** Render a single plugin card. */
  function _renderPluginCard(plugin) {
    const card = document.createElement("div");
    card.className = "plugin-card" + (plugin.enabled ? "" : " plugin-card-disabled");
    card.dataset.key = plugin.key;


    const statusLabel = plugin.enabled
      ? (I18n.t("plugins.status.enabled") || "Enabled")
      : (I18n.t("plugins.status.disabled") || "Disabled");

    const settingsBtnHtml = plugin.has_config ? `<button class="plugin-settings-btn" data-key="${escapeHtml(plugin.key)}" title="${I18n.t("plugins.settings") || "Settings"}"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/></svg></button>` : "";

    card.innerHTML = `
      <div class="plugin-card-info">
        <div class="plugin-card-name-row">
          <span class="plugin-name">${escapeHtml(plugin.name)}</span>
          <span class="plugin-version">v${escapeHtml(plugin.version || "0.0.0")}</span>
        </div>
        <div class="plugin-kind">${escapeHtml(plugin.kind || "standalone")}</div>
        ${plugin.description ? `<div class="plugin-description">${escapeHtml(plugin.description)}</div>` : ""}
      </div>
      <div class="plugin-card-actions">
        <div class="plugin-action-btns">
          <button class="plugin-detail-btn" data-key="${escapeHtml(plugin.key)}" title="${I18n.t("plugins.detail") || "Details"}">
            <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <circle cx="12" cy="12" r="10"/>
              <path d="M12 16v-4"/>
              <path d="M12 8h.01"/>
            </svg>
          </button>
          ${settingsBtnHtml}
        </div>
        <label class="plugin-toggle">
          <input type="checkbox" class="plugin-toggle-input" ${plugin.enabled ? "checked" : ""} data-key="${escapeHtml(plugin.key)}">
          <span class="plugin-toggle-track"></span>
        </label>
      </div>
    `;

    // Wire up toggle event
    const toggle = card.querySelector(".plugin-toggle-input");
    if (toggle) {
      toggle.addEventListener("change", () => _togglePlugin(plugin.key, toggle));
    }

    // Wire up detail button
    const detailBtn = card.querySelector(".plugin-detail-btn");
    if (detailBtn) {
      detailBtn.addEventListener("click", () => _showPluginDetail(plugin));
    }

    // Wire up settings button
    const settingsBtn = card.querySelector(".plugin-settings-btn");
    if (settingsBtn) {
      settingsBtn.addEventListener("click", () => _showPluginSettings(plugin));
    }

    return card;
  }

  /** Toggle plugin enabled state. */
  async function _togglePlugin(key, toggleEl) {
    toggleEl.disabled = true;
    try {
      const res = await fetch(`/api/plugins/${encodeURIComponent(key)}/toggle`, { method: "POST" });
      const data = await res.json();

      if (!res.ok || !data.ok) {
        toggleEl.checked = !toggleEl.checked; // revert
        console.error("[Plugins] toggle failed", data.error);
        return;
      }

      // Update card appearance
      const card = toggleEl.closest(".plugin-card");
      if (card) {
        card.classList.toggle("plugin-card-disabled", !data.enabled);
        // Update status label
        const label = card.querySelector(".plugin-card-actions-label");
        if (label) {
          label.textContent = data.enabled
            ? (I18n.t("plugins.status.enabled") || "Enabled")
            : (I18n.t("plugins.status.disabled") || "Disabled");
        }
      }
    } catch (e) {
      toggleEl.checked = !toggleEl.checked; // revert
      console.error("[Plugins] toggle failed", e);
    } finally {
      toggleEl.disabled = false;
    }
  }

  /** Show plugin detail modal. */
  function _showPluginDetail(plugin) {
    // Remove existing modal if any
    const existingModal = document.querySelector(".plugin-detail-modal");
    if (existingModal) existingModal.remove();

    const modal = document.createElement("div");
    modal.className = "plugin-detail-modal";

    const toolsHtml = plugin.tools && plugin.tools.length > 0
      ? plugin.tools.map(t => `<span class="pd-tag">${escapeHtml(t)}</span>`).join("")
      : `<span class="pd-empty">${I18n.t("plugins.detail.none") || "None"}</span>`;

    const hooksHtml = plugin.hooks && plugin.hooks.length > 0
      ? plugin.hooks.map(h => `<span class="pd-tag">${escapeHtml(h)}</span>`).join("")
      : `<span class="pd-empty">${I18n.t("plugins.detail.none") || "None"}</span>`;

    const commandsHtml = plugin.commands && plugin.commands.length > 0
      ? plugin.commands.map(c => `<span class="pd-tag">/${escapeHtml(c)}</span>`).join("")
      : `<span class="pd-empty">${I18n.t("plugins.detail.none") || "None"}</span>`;

    const statusText = plugin.enabled
      ? (I18n.t("plugins.status.enabled") || "Enabled")
      : (I18n.t("plugins.status.disabled") || "Disabled");

    modal.innerHTML = `
      <div class="plugin-detail-overlay"></div>
      <div class="plugin-detail-content">
        <div class="pd-header">
          <div class="pd-title">${escapeHtml(plugin.name)}</div>
          <button class="pd-close-btn" title="Close">&times;</button>
        </div>
        <div class="pd-body">
          <div class="pd-row">
            <span class="pd-label">${I18n.t("plugins.detail.status") || "Status"}</span>
            <span class="pd-value"><span class="pd-status ${plugin.enabled ? "pd-enabled" : "pd-disabled"}">${statusText}</span></span>
          </div>
          <div class="pd-row">
            <span class="pd-label">${I18n.t("plugins.detail.version") || "Version"}</span>
            <span class="pd-value">${escapeHtml(plugin.version || "0.0.0")}</span>
          </div>
          <div class="pd-row">
            <span class="pd-label">${I18n.t("plugins.detail.type") || "Type"}</span>
            <span class="pd-value">${escapeHtml(plugin.kind || "standalone")}</span>
          </div>
          <div class="pd-row">
            <span class="pd-label">${I18n.t("plugins.detail.author") || "Author"}</span>
            <span class="pd-value">${escapeHtml(plugin.author || "-")}</span>
          </div>
          <div class="pd-row">
            <span class="pd-label">${I18n.t("plugins.detail.description") || "Description"}</span>
            <span class="pd-value">${escapeHtml(plugin.description || "-")}</span>
          </div>
          ${plugin.error ? `
          <div class="pd-row pd-error-row">
            <span class="pd-label">${I18n.t("plugins.detail.error") || "Error"}</span>
            <span class="pd-value pd-error-msg">${escapeHtml(plugin.error)}</span>
          </div>
          ` : ""}
          <div class="pd-row">
            <span class="pd-label">${I18n.t("plugins.detail.tools") || "Tools"}</span>
            <span class="pd-value pd-tags">${toolsHtml}</span>
          </div>
          <div class="pd-row">
            <span class="pd-label">${I18n.t("plugins.detail.hooks") || "Hooks"}</span>
            <span class="pd-value pd-tags">${hooksHtml}</span>
          </div>
          <div class="pd-row">
            <span class="pd-label">${I18n.t("plugins.detail.commands") || "Commands"}</span>
            <span class="pd-value pd-tags">${commandsHtml}</span>
          </div>
          <div class="pd-row">
            <span class="pd-label">${I18n.t("plugins.detail.path") || "Path"}</span>
            <span class="pd-value pd-path">${escapeHtml(plugin.path || plugin.key)}</span>
          </div>
        </div>
      </div>
    `;

    document.body.appendChild(modal);

    // Close handlers
    const closeBtn = modal.querySelector(".pd-close-btn");
    const overlay = modal.querySelector(".plugin-detail-overlay");
    const closeModal = () => modal.remove();
    closeBtn.addEventListener("click", closeModal);
    overlay.addEventListener("click", closeModal);
    document.addEventListener("keydown", function escHandler(e) {
      if (e.key === "Escape") {
        closeModal();
        document.removeEventListener("keydown", escHandler);
      }
    });
  }

  /** Show plugin settings modal. */
  async function _showPluginSettings(plugin) {
    // Remove existing modal if any
    const existingModal = document.querySelector(".plugin-settings-modal");
    if (existingModal) existingModal.remove();

    // Fetch current config
    let config = {};
    try {
      const res = await fetch(`/api/plugins/${encodeURIComponent(plugin.key)}/config`);
      const data = await res.json();
      if (data.ok) config = data.config || {};
    } catch (e) {
      console.error("[Plugins] Failed to load config", e);
    }

    const modal = document.createElement("div");
    modal.className = "plugin-settings-modal";

    // Build config fields
    const configKeys = Object.keys(config);
    let fieldsHtml = "";
    if (configKeys.length > 0) {
      fieldsHtml = configKeys.map(key => {
        const value = config[key];
        const valueStr = typeof value === "object" ? JSON.stringify(value, null, 2) : String(value);
        const isMultiline = typeof value === "object" || valueStr.includes("\n") || valueStr.length > 50;
        if (isMultiline) {
          return `
            <div class="ps-field">
              <label class="ps-field-label">${escapeHtml(key)}</label>
              <textarea class="ps-field-input ps-textarea" data-key="${escapeHtml(key)}">${escapeHtml(valueStr)}</textarea>
            </div>
          `;
        }
        return `
          <div class="ps-field">
            <label class="ps-field-label">${escapeHtml(key)}</label>
            <input type="text" class="ps-field-input" data-key="${escapeHtml(key)}" value="${escapeHtml(valueStr)}">
          </div>
        `;
      }).join("");
    } else {
      fieldsHtml = `<div class="ps-empty">${I18n.t("plugins.settings.empty") || "No configuration available"}</div>`;
    }

    modal.innerHTML = `
      <div class="plugin-settings-overlay"></div>
      <div class="plugin-settings-content">
        <div class="ps-header">
          <div class="ps-title">${escapeHtml(plugin.name)} - ${I18n.t("plugins.settings") || "Settings"}</div>
          <button class="ps-close-btn" title="Close">&times;</button>
        </div>
        <div class="ps-body">
          ${fieldsHtml}
        </div>
        <div class="ps-footer">
          <button class="ps-save-btn">${I18n.t("plugins.settings.save") || "Save"}</button>
        </div>
      </div>
    `;

    document.body.appendChild(modal);

    // Close handlers
    const closeBtn = modal.querySelector(".ps-close-btn");
    const overlay = modal.querySelector(".plugin-settings-overlay");
    const closeModal = () => modal.remove();
    closeBtn.addEventListener("click", closeModal);
    overlay.addEventListener("click", closeModal);

    // Save handler
    const saveBtn = modal.querySelector(".ps-save-btn");
    saveBtn.addEventListener("click", async () => {
      const newConfig = {};
      modal.querySelectorAll(".ps-field-input").forEach(input => {
        const key = input.dataset.key;
        let value = input.value;
        // Try to parse JSON for objects/arrays
        try {
          const parsed = JSON.parse(value);
          if (typeof parsed === "object") {
            value = parsed;
          }
        } catch (e) {
          // Keep as string
        }
        newConfig[key] = value;
      });

      saveBtn.disabled = true;
      saveBtn.textContent = I18n.t("plugins.settings.saving") || "Saving...";

      try {
        const res = await fetch(`/api/plugins/${encodeURIComponent(plugin.key)}/config`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ config: newConfig })
        });
        const data = await res.json();
        if (data.ok) {
          closeModal();
          // Optionally reload plugins to apply new config
          await _loadPlugins();
        } else {
          alert(data.error || "Failed to save config");
        }
      } catch (e) {
        alert("Network error — please try again.");
        console.error("[Plugins] save config failed", e);
      } finally {
        saveBtn.disabled = false;
        saveBtn.textContent = I18n.t("plugins.settings.save") || "Save";
      }
    });

    // ESC key handler
    document.addEventListener("keydown", function escHandler(e) {
      if (e.key === "Escape") {
        closeModal();
        document.removeEventListener("keydown", escHandler);
      }
    });
  }

  /** Hot reload all plugins. */
  async function _reloadPlugins() {
    const btn = $("btn-reload-plugins");
    if (btn) {
      btn.disabled = true;
      btn.textContent = I18n.t("plugins.reloading") || "Reloading...";
    }

    try {
      const res = await fetch("/api/plugins/reload", { method: "POST" });
      const data = await res.json();

      if (!res.ok || !data.ok) {
        alert(data.error || "Failed to reload plugins");
        return;
      }

      // Refresh the list
      await _loadPlugins();
    } catch (e) {
      alert("Network error — please try again.");
      console.error("[Plugins] reload failed", e);
    } finally {
      if (btn) {
        btn.disabled = false;
        btn.textContent = I18n.t("plugins.btn.reload") || "Reload";
      }
    }
  }

  /** Wire up DOM event listeners (called once). */
  function _wireDom() {
    if (_domWired) return;
    _domWired = true;

    const reloadBtn = $("btn-reload-plugins");
    if (reloadBtn) {
      reloadBtn.addEventListener("click", _reloadPlugins);
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /** Called when the plugins panel is opened. */
  function open() {
    _wireDom();
    _loadPlugins();
  }

  /** Get current plugins data. */
  function getPlugins() {
    return _plugins;
  }

  /** Refresh plugins from server. */
  function refresh() {
    _loadPlugins();
  }

  return {
    open,
    getPlugins,
    refresh
  };
})();
