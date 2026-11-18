const { chromium } = await import(process.env.PLAYWRIGHT || "playwright");
const b = await chromium.launch();
const p = await b.newPage();
p.on("console", (m) => console.log(m.text()));
p.on("pageerror", (e) => console.log("PAGEERROR", e.message));
await p.goto("http://127.0.0.1:8765/");
await p.waitForFunction(() => /DONE|ERROR/.test(document.getElementById("o").textContent), null, { timeout: 0 });
await b.close();
