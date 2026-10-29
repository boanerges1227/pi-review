"use strict";
const productionFrame = document.getElementById("production-frame");
const productionOpen = document.getElementById("production-open");
const productionReload = document.getElementById("production-reload");
const productionNotice = document.getElementById("production-notice");
let productionTimer, productionGeneration = 0;

/** Clear credential-bearing iframe and link attributes when the user signs out. */
function clearProduction() {
  productionGeneration += 1;
  clearTimeout(productionTimer);
  productionFrame.hidden = true;
  productionFrame.removeAttribute("src");
  productionOpen.removeAttribute("href");
  productionOpen.hidden = true;
}

/** Resolve only the fixed same-origin Production target after the server verifies the site session. */
async function loadProduction() {
  clearProduction();
  const generation = productionGeneration;
  productionReload.disabled = true;
  document.getElementById("production-placeholder").hidden = false;
  productionNotice.textContent = "";
  document.getElementById("production-summary").textContent = "Connecting to Production…";
  try {
    const target = await identityAdmin.request("/production-target");
    // A response started before logout or a newer load must never restore credential-bearing elements.
    if (generation !== productionGeneration) return;
    const url = new URL(target.url, window.location.origin);
    if (url.origin !== window.location.origin || !/^\/csp\/[a-z0-9_-]+\/EnsPortal\.ProductionConfig\.zen$/.test(url.pathname)) throw new Error("The Production destination is invalid.");
    document.getElementById("production-summary").textContent = `${target.namespace} · ${target.production} · Demo account: ${target.username}`;
    productionOpen.href = url.href;
    productionOpen.hidden = false;
    productionFrame.src = url.href;
    productionTimer = setTimeout(() => { productionNotice.textContent = "Production is taking longer to load. Try Reload Production or open it in a new tab."; }, 20000);
  } catch (error) {
    if (generation !== productionGeneration) return;
    if (error.code === "ADMIN_AUTHENTICATION_REQUIRED") { identityAdmin.signIn("/identity/production");return; }
    productionNotice.textContent = error.code === "PRODUCTION_PORTAL_NOT_CONFIGURED" ? "The Production demo account is not configured. Ask your administrator to set it up." : error.message;
    document.getElementById("production-summary").textContent = "Production unavailable";
    document.querySelector("#production-placeholder p").textContent = "Use Reload Production after the connection is available.";
  } finally { if (generation === productionGeneration) productionReload.disabled = false; }
}

/** Distinguish native login/error pages from a loaded Production instead of reporting iframe load as success. */
productionFrame.addEventListener("load", () => {
  if (!productionFrame.hasAttribute("src")) return;
  clearTimeout(productionTimer);
  productionFrame.hidden = false;
  document.getElementById("production-placeholder").hidden = true;
  try {
    const doc = productionFrame.contentDocument;
    if (!doc || !doc.body || doc.location.href === "about:blank") throw new Error("Unavailable frame");
    if (doc.querySelector('input[name="IRISPassword"]')) {
      productionNotice.textContent = "IRIS requires sign-in. Check the configured demo account or sign in within the portal.";
    } else if (productionFrame.contentWindow.zenPage?._serverClass !== "EnsPortal.ProductionConfig") {
      productionNotice.textContent = "Check the native portal response below. If Production did not load, open it in a new tab.";
    } else { productionNotice.textContent = ""; }
  } catch { productionNotice.textContent = "The portal could not be displayed here. Open Production in a new tab."; }
});

productionReload.addEventListener("click", loadProduction);
identityAdmin.init({required:true, target:"/identity/production", notice:"production-notice", onAuthenticated:loadProduction, onLogout:clearProduction});
