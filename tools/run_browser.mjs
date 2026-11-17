// Usage: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core CHROME=/path/to/chrome node tools/run_browser.mjs
// (serve the repo root on http://127.0.0.1:8765 first, e.g. python3 -m http.server 8765 --bind 127.0.0.1)
const { chromium } = await import(process.env.PLAYWRIGHT_CORE + "/index.mjs");
const browser = await chromium.launch({
  executablePath: process.env.CHROME,
  headless: true, args: ["--no-sandbox"],
});
const page = await browser.newPage();
page.on("pageerror", (e) => console.log("pageerror:", e.message));
await page.goto("http://127.0.0.1:8765/bench/browser_bench.html");
await page.waitForFunction(() => /DONE|ERROR/.test(document.getElementById("out").textContent), null, { timeout: 1_500_000 });
console.log("browser:", await browser.version());
console.log(await page.$eval("#out", (e) => e.textContent));
await browser.close();
