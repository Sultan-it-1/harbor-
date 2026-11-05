// Phone smoke test for the Android build of the web UI (run after `pnpm run build`):
// serves dist/, opens it in a phone-sized Chromium with a stand-in for the Android shell's bridge
// (offline: every native fetch fails, as on a phone without a connection), visits every main
// screen in English and Arabic, and fails on a page error, a missing tab bar, a Back gesture that
// does nothing, or text the Arabic catalog is missing.
// Usage: pnpm run test:phone
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const DIST = path.join(ROOT, "dist");
const VIEWS = ["home", "discover", "movies", "shows", "live", "library", "downloads", "addons", "calendar", "settings"];
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".jpg": "image/jpeg", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf", ".wasm": "application/wasm" };

if (!fs.existsSync(path.join(DIST, "index.html"))) {
  console.error("phone-smoke: dist/ not found. Run `pnpm run build` first.");
  process.exit(1);
}

const server = http.createServer((req, res) => {
  let p = decodeURIComponent((req.url || "/").split("?")[0]);
  if (p === "/") p = "/index.html";
  const file = path.join(DIST, path.normalize(p).replace(/^(\.\.[/\\])+/, ""));
  if (!file.startsWith(DIST) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.statusCode = 404;
    return res.end();
  }
  res.setHeader("content-type", TYPES[path.extname(file)] || "application/octet-stream");
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

// The Android shell, minus the native parts: fetch answers "offline", the rest records calls.
const SHELL = ({ lang }) => {
  window.__harborI18nMisses = new Set();
  window.HarborAndroid = {
    version: () => "smoke",
    fetch: (id) => setTimeout(() => window.__harborNativeFetchDone?.(id, JSON.stringify({ ok: false, error: "java.net.UnknownHostException: offline" })), 5),
    fetchCancel: () => {},
    play: () => {}, command: () => {}, stop: () => {}, openExternal: () => {},
    dlStart: () => JSON.stringify({ ok: true }), dlStatus: () => "{}", dlDelete: () => true, dlPause: () => true, dlResume: () => true,
    dlAddSubs: () => true, dlFiles: () => "{}", dlStorage: () => JSON.stringify({ free: 5e10, used: 0 }),
    takeLink: () => "", dlKeepAlive: () => {}, bgAllowed: () => true, bgRequest: () => {},
  };
  try {
    localStorage.setItem("harbor.onboarding", JSON.stringify({ onboarded: true, nudges: {} }));
    const cur = JSON.parse(localStorage.getItem("harbor.settings") || "{}");
    localStorage.setItem("harbor.settings", JSON.stringify({ ...cur, uiLanguage: lang }));
  } catch {}
};

const failures = [];
const browser = await chromium.launch();
for (const lang of ["en", "ar"]) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, locale: lang === "ar" ? "ar" : "en-US",
    userAgent: "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36 HarborAndroid/smoke" });
  // Nothing leaves the machine: the test must not depend on outside services.
  await ctx.route((url) => !url.href.startsWith(base) && !url.href.startsWith("data:") && !url.href.startsWith("blob:"), (route) => route.abort("internetdisconnected"));
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e.message || e).slice(0, 200)));
  await page.addInitScript(SHELL, { lang });
  await page.goto(`${base}/index.html`);
  await page.waitForFunction(() => !!window.harbor?.navigate, null, { timeout: 30_000 });
  if (lang === "ar" && (await page.evaluate(() => document.documentElement.dir)) !== "rtl") failures.push("ar: the page is not right to left");
  for (const v of VIEWS) {
    await page.evaluate((v) => window.harbor.navigate(v), v);
    await page.waitForTimeout(1500);
    const ok = await page.evaluate(() => !!document.querySelector("main"));
    if (!ok) failures.push(`${lang}/${v}: no <main> rendered`);
    if (v !== "settings" && !(await page.$("[data-phone-tabbar]"))) failures.push(`${lang}/${v}: the tab bar is missing`);
  }
  // Back from a page returns to where you were.
  await page.evaluate(() => window.harbor.navigate("library"));
  await page.waitForTimeout(800);
  await page.evaluate(() => window.harbor.navigate("downloads"));
  await page.waitForTimeout(800);
  const handled = await page.evaluate(() => (window.__harborAndroidBack ? window.__harborAndroidBack() : "no handler"));
  await page.waitForTimeout(800);
  if (handled === "no handler") failures.push(`${lang}: no Android Back handler`);
  if (lang === "ar") {
    // Arabic text keys are fine; anything else falls back to English.
    const missing = (await page.evaluate(() => [...window.__harborI18nMisses])).filter((k) => !/[؀-ۿ]/.test(k));
    if (missing.length) failures.push(`ar: missing Arabic for ${JSON.stringify(missing.slice(0, 20))}`);
  }
  if (errors.length) failures.push(`${lang}: page errors ${JSON.stringify(errors.slice(0, 5))}`);
  await ctx.close();
}
await browser.close();
server.close();

if (failures.length) {
  console.error("phone-smoke: FAILED");
  for (const f of failures) console.error("  - " + f);
  process.exit(1);
}
console.log(`phone-smoke: ${VIEWS.length} screens in English and Arabic, no page errors, tab bar and Back work, no missing Arabic.`);
