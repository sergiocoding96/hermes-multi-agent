/**
 * hermes-profile-switcher.js — adds a floating "view as <profile>" picker
 * to the v2 plugin's bundled viewer.
 *
 * Why this exists: the v2 viewer is bound to a single namespace at daemon
 * startup. The bundled UI ships i18n strings for an agent switcher but
 * doesn't render it, and the API enforces visibility on the daemon's
 * fixed namespace. This overlay:
 *
 *   1. Fetches /api/v1/diag/namespace once on load to list all profiles
 *      that have ever written to the store (sergio, hr-agent, mohammed,
 *      research-agent, email-marketing, …).
 *   2. Injects a small floating dropdown in the top-right corner.
 *   3. On selection, persists choice in localStorage and patches
 *      window.fetch to add `X-As-Profile: <profile>` to every /api/v1/*
 *      request — the server's dispatch layer reads this header and runs
 *      handlers inside a per-request AsyncLocalStorage namespace context
 *      so visibility filters resolve to the requested profile.
 *
 * Added by the Hermes integration 2026-05-17. Server-side counterpart:
 *   core/runtime/request-namespace.ts (ALS module)
 *   core/pipeline/memory-core.ts (effectiveNamespace() + visibleToCurrent default)
 *   server/http.ts (dispatch parses ?as_profile= / X-As-Profile)
 *
 * Lives outside the React bundle on purpose — overlay survives bundle
 * rebuilds and doesn't touch shadow-DOM internals. Imperatively
 * re-renders when the bundle navigates between #/ routes.
 */

(function () {
  "use strict";
  const STORAGE_KEY = "hermes.as_profile";
  const TOAST_KEY = "hermes.profile_toast_seen";

  // ── styles ───────────────────────────────────────────────────────────
  const css = `
    #hermes-profile-switcher {
      position: fixed; top: 12px; right: 18px; z-index: 9999;
      display: flex; align-items: center; gap: 8px;
      padding: 6px 10px;
      background: rgba(15, 32, 66, 0.92);
      color: #f4f6fa;
      border: 1px solid rgba(255, 140, 66, 0.55);
      border-radius: 8px;
      font: 600 12px/1.2 system-ui, -apple-system, "Segoe UI", sans-serif;
      box-shadow: 0 6px 22px rgba(15, 32, 66, 0.22);
      backdrop-filter: blur(4px);
    }
    #hermes-profile-switcher .hps-label {
      letter-spacing: 0.06em; text-transform: uppercase; font-size: 10px;
      color: #ff8c42;
    }
    #hermes-profile-switcher select {
      background: #f4f6fa; color: #0f2042;
      border: 1px solid rgba(255, 140, 66, 0.7);
      border-radius: 5px;
      padding: 3px 6px; font: 600 12px/1.2 inherit;
      cursor: pointer;
    }
    #hermes-profile-switcher select:focus { outline: 2px solid #ff8c42; }
    #hermes-profile-switcher .hps-clear {
      background: transparent; color: #ff8c42; border: 0; cursor: pointer;
      font-size: 14px; line-height: 1; padding: 0 4px;
    }
    #hermes-profile-switcher .hps-active {
      width: 8px; height: 8px; border-radius: 50%;
      background: #ff8c42; box-shadow: 0 0 6px rgba(255,140,66,0.7);
    }
    #hermes-profile-switcher .hps-inactive {
      width: 8px; height: 8px; border-radius: 50%;
      background: #6b7280; opacity: 0.5;
    }
    #hermes-profile-toast {
      position: fixed; top: 60px; right: 18px; z-index: 9998;
      max-width: 320px; padding: 10px 14px;
      background: #fff; color: #0f2042;
      border: 1px solid #ff8c42; border-left-width: 4px;
      border-radius: 6px;
      font: 500 12px/1.4 system-ui, -apple-system, sans-serif;
      box-shadow: 0 8px 24px rgba(15, 32, 66, 0.18);
    }
    #hermes-profile-toast b { color: #ff8c42; }
  `;
  const styleEl = document.createElement("style");
  styleEl.textContent = css;
  document.head.appendChild(styleEl);

  // ── state ────────────────────────────────────────────────────────────
  let currentProfile = localStorage.getItem(STORAGE_KEY) || ""; // "" = no override

  // ── fetch interceptor ────────────────────────────────────────────────
  const origFetch = window.fetch.bind(window);
  const pageIsHttps = location.protocol === "https:";
  window.fetch = function (input, init) {
    // Resolve URL safely whether it's a string, URL, or Request object.
    let urlStr = "";
    if (typeof input === "string") urlStr = input;
    else if (input instanceof URL) urlStr = input.toString();
    else if (input && typeof input.url === "string") urlStr = input.url;

    // Mixed-content guard. The React bundle probes a sibling daemon at a
    // hardcoded `http://<host>:<port>/api/v1/health` to offer a "switch
    // daemon" link (wa={openclaw:18799,hermes:18800}). On this single-daemon,
    // reverse-proxied HTTPS deployment that sibling port isn't reachable and
    // the browser blocks the insecure request — logging a Mixed Content error
    // on every 15s poll. Short-circuit any insecure http:// request from an
    // https page by rejecting, so the bundle's own `catch { return null }`
    // path runs silently. Same-origin app calls are relative ("/api/v1/…")
    // and never match this.
    if (pageIsHttps && urlStr.startsWith("http://")) {
      return Promise.reject(
        new DOMException(
          "Blocked insecure cross-origin request (mixed content)",
          "SecurityError",
        ),
      );
    }

    if (!currentProfile) return origFetch(input, init);
    if (!urlStr.includes("/api/v1/")) return origFetch(input, init);
    // Exclude auth endpoints — namespace override is meaningless there.
    if (urlStr.includes("/api/v1/auth/")) return origFetch(input, init);

    const headers = new Headers((init && init.headers) || (input instanceof Request ? input.headers : undefined));
    headers.set("X-As-Profile", currentProfile);
    const merged = Object.assign({}, init || {}, { headers });
    return origFetch(input, merged);
  };

  // ── DOM ──────────────────────────────────────────────────────────────
  function buildShell() {
    let el = document.getElementById("hermes-profile-switcher");
    if (el) return el;
    el = document.createElement("div");
    el.id = "hermes-profile-switcher";
    el.innerHTML = `
      <span class="${currentProfile ? "hps-active" : "hps-inactive"}" id="hps-dot" title="${currentProfile ? "Override active" : "Using daemon namespace"}"></span>
      <span class="hps-label">view as</span>
      <select id="hps-select" aria-label="View memories as profile">
        <option value="">— self (daemon ns) —</option>
      </select>
      <button class="hps-clear" id="hps-clear" title="Reset to self" aria-label="Reset">✕</button>
    `;
    document.body.appendChild(el);
    return el;
  }

  function showToast(html) {
    const t = document.createElement("div");
    t.id = "hermes-profile-toast";
    t.innerHTML = html;
    document.body.appendChild(t);
    setTimeout(() => { try { t.remove(); } catch (_) {} }, 4500);
  }

  function setProfile(p) {
    currentProfile = p || "";
    if (currentProfile) localStorage.setItem(STORAGE_KEY, currentProfile);
    else localStorage.removeItem(STORAGE_KEY);
    const dot = document.getElementById("hps-dot");
    if (dot) {
      dot.className = currentProfile ? "hps-active" : "hps-inactive";
      dot.title = currentProfile ? `Override active: as_profile=${currentProfile}` : "Using daemon namespace";
    }
    // Trigger a soft reload of the page's data — try in-app refresh
    // buttons first; fall back to full reload.
    const refreshBtns = Array.from(document.querySelectorAll("button"))
      .filter(b => /refresh|刷新/i.test(b.textContent || ""));
    if (refreshBtns.length > 0) {
      refreshBtns.forEach(b => b.click());
    } else {
      // No refresh button visible — full page reload.
      setTimeout(() => location.reload(), 80);
    }
  }

  async function loadProfiles() {
    try {
      const r = await origFetch("/api/v1/diag/namespace", { credentials: "include" });
      if (!r.ok) return [];
      const data = await r.json();
      return Array.isArray(data.namespaces) ? data.namespaces : [];
    } catch (e) {
      console.warn("[hermes-profile-switcher] failed to load namespaces", e);
      return [];
    }
  }

  // Public (non-session-gated) endpoint. Returns
  // { enabled, needsSetup, authenticated }. We use it to avoid firing
  // session-gated requests (e.g. /api/v1/diag/namespace) before the user
  // has unlocked the viewer — which would otherwise log a 401 on load.
  async function isAuthenticated() {
    try {
      const r = await origFetch("/api/v1/auth/status", { credentials: "include" });
      if (!r.ok) return false;
      const d = await r.json();
      // If auth is disabled there's no lock screen; otherwise require unlock.
      return d.enabled === false || d.authenticated === true;
    } catch (_) {
      return false;
    }
  }

  async function mount() {
    if (document.getElementById("hermes-profile-switcher")) return;
    // Don't show on the login screen.
    if (document.querySelector('input[type="password"]')) {
      setTimeout(mount, 400);
      return;
    }
    // Wait until the viewer is unlocked before hitting session-gated APIs.
    if (!(await isAuthenticated())) {
      setTimeout(mount, 800);
      return;
    }
    const profiles = await loadProfiles();
    if (profiles.length === 0) {
      // Either not logged in yet, or no namespaces. Try again later.
      setTimeout(mount, 800);
      return;
    }
    const el = buildShell();
    const sel = el.querySelector("#hps-select");
    profiles
      .sort((a, b) => (b.count || 0) - (a.count || 0))
      .forEach((ns) => {
        const opt = document.createElement("option");
        const id = ns.profileId || "default";
        opt.value = id;
        opt.textContent = `${id} (${ns.count || 0})`;
        if (currentProfile === id) opt.selected = true;
        sel.appendChild(opt);
      });
    sel.addEventListener("change", (e) => setProfile(e.target.value));
    el.querySelector("#hps-clear").addEventListener("click", () => {
      sel.value = "";
      setProfile("");
    });

    // First-time hint.
    if (!localStorage.getItem(TOAST_KEY)) {
      showToast(
        `<b>View-as toggle ready.</b><br/>Pick a profile to see that agent's private traces. ` +
        `Adds <code style="background:#f4f6fa;padding:1px 4px;border-radius:3px">X-As-Profile</code> ` +
        `header so the daemon swaps the visibility namespace per request.`
      );
      localStorage.setItem(TOAST_KEY, "1");
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mount);
  } else {
    mount();
  }

  // Re-attach on hash navigation (SPA route changes don't remount us).
  window.addEventListener("hashchange", () => {
    if (!document.getElementById("hermes-profile-switcher")) mount();
  });

  // ────────────────────────────────────────────────────────────────────
  // Sidebar tab: "Viewer" → /memory-map.html
  //
  // The React sidebar renders a stack of icon-only links. We can't reach
  // into the React state, but we can add a sibling <a> via DOM. React
  // doesn't reconcile away unknown children inside its mount point, so
  // appending an extra child to the sidebar's <nav> survives.
  //
  // A MutationObserver re-adds the link if React replaces the sidebar
  // (e.g. on route change). Hash-routes inside the SPA don't, but it's
  // cheap insurance.
  // ────────────────────────────────────────────────────────────────────

  const MEMORY_MAP_ICON = `
    <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor"
         stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <circle cx="5" cy="6.5" r="1.7"/>
      <circle cx="18.5" cy="6" r="1.5"/>
      <circle cx="12" cy="12" r="2"/>
      <circle cx="5.5" cy="17.5" r="1.5"/>
      <circle cx="18.5" cy="18" r="1.5"/>
      <path d="M6.5 6.8 L11 11.4 M17.2 6.5 L13 11.2 M6.7 16.6 L11 13.5 M17.2 17.5 L13 13.5"
            stroke-dasharray="2 2" opacity="0.6"/>
    </svg>
  `;
  const MAP_LINK_ID = "hermes-memory-map-link";

  function mountSidebarTab() {
    if (document.getElementById(MAP_LINK_ID)) return; // already in DOM
    // Find a sidebar link to use as a sibling — looks for one of the
    // built-in routes the React app renders.
    const seed = document.querySelector(
      'a[href="#/skills"], a[href="#/memories"], a[href="#/overview"]',
    );
    if (!seed) return; // sidebar not mounted yet
    const nav = seed.parentElement;
    if (!nav) return;

    const a = document.createElement("a");
    a.id = MAP_LINK_ID;
    a.href = "/memory-map.html";
    a.title = "Viewer";
    // Mirror the styling of sibling sidebar links so it visually belongs.
    a.className = seed.className;
    a.style.cssText = (seed.getAttribute("style") || "");
    a.innerHTML = MEMORY_MAP_ICON;
    // Append at the end of the same group.
    nav.appendChild(a);
  }

  // Initial mount + retry until sidebar appears.
  const sidebarInterval = setInterval(() => {
    mountSidebarTab();
    if (document.getElementById(MAP_LINK_ID)) clearInterval(sidebarInterval);
  }, 500);

  // Re-mount on hash navigation (React sometimes rebuilds the nav).
  window.addEventListener("hashchange", mountSidebarTab);
  // Also observe top-level DOM changes — cheap safety net.
  new MutationObserver(() => mountSidebarTab()).observe(
    document.body, { childList: true, subtree: true },
  );
})();
