// Seeds a testor container (scripts/dashboard-e2e.sh) with what the dashboard shows: finished
// runs of several projects (spec tables, real screenshots, a video, an HTML report, coverage, a
// mutation report), a batch of shards, a run in progress, pending approvals and a hub. Files are
// written as run.ps1 writes them, into the testor home, streamed in with tar (as the container's
// user); testor's store then reads them as it reads any run.
//
//   node seed.mjs            (TESTOR_CONTAINER, the container's name; TESTOR_URL, its URL)
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { chromium } from "@playwright/test";

const CONTAINER = process.env.TESTOR_CONTAINER ?? "testor-dashboard-e2e";
const HOME = "/data/workspaces/.testor";
const now = Date.now();
const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;

const docker = (...args) => execFileSync("docker", args, { encoding: "utf8" }).trim();

// --- the screenshots: a small shop, rendered by Chromium ---------------------------------------
const page = (title, body, accent = "#2563eb") => `<!doctype html><html><head><style>
  body { margin: 0; font: 15px system-ui, sans-serif; color: #1b1f24; background: #f6f7f9; }
  header { display: flex; gap: 18px; align-items: center; padding: 14px 28px; background: ${accent}; color: #fff; }
  header b { font-size: 18px; } header span { opacity: .85; }
  main { padding: 28px; display: grid; gap: 18px; }
  .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px; }
  .card { background: #fff; border: 1px solid #e3e6ea; border-radius: 12px; padding: 16px; }
  .img { height: 120px; border-radius: 8px; background: linear-gradient(135deg, #c7d7fe, #fde2e4); margin-bottom: 10px; }
  .btn { display: inline-block; padding: 9px 16px; border-radius: 8px; background: ${accent}; color: #fff; }
  .err { padding: 14px; border-radius: 8px; background: #fdecea; color: #c42b1c; border: 1px solid #f5c2bd; }
  input { width: 100%; padding: 10px; border: 1px solid #cfd4da; border-radius: 8px; font: inherit; box-sizing: border-box; }
  </style></head><body><header><b>Northwind Shop</b><span>${title}</span><span style="margin-left:auto">Cart (2)</span></header><main>${body}</main></body></html>`;
const product = (name, price) => `<div class="card"><div class="img"></div><b>${name}</b><div>${price}</div><div style="margin-top:8px"><span class="btn">Add to cart</span></div></div>`;
const PAGES = {
  home: page("Home", `<h1 style="margin:0">Spring collection</h1><div class="grid">${product("Linen shirt", "$48")}${product("Canvas tote", "$22")}${product("Desk lamp", "$65")}</div>`),
  product: page("Product", `<div class="card" style="display:grid;grid-template-columns:1fr 1fr;gap:24px"><div class="img" style="height:280px"></div><div><h2>Desk lamp</h2><p>Warm light, brass finish, a two-metre cable.</p><h3>$65</h3><span class="btn">Add to cart</span></div></div>`),
  cart: page("Cart", `<div class="card"><h2 style="margin-top:0">Your cart</h2><p>Desk lamp · $65</p><p>Canvas tote · $22</p><hr><b>Total $87</b><div style="margin-top:12px"><span class="btn">Check out</span></div></div>`),
  checkout: page("Checkout", `<div class="card" style="max-width:520px"><h2 style="margin-top:0">Shipping</h2><p><input value="Ada Lovelace"></p><p><input value="12 Analytical Street"></p><span class="btn">Pay $87</span></div>`),
  checkoutFailed: page("Checkout", `<div class="card" style="max-width:520px"><h2 style="margin-top:0">Payment</h2><div class="err">The card was declined (test card 4000 0000 0000 0002).</div><p><input value="4000 0000 0000 0002"></p><span class="btn">Pay $87</span></div>`, "#b45309"),
  login: page("Sign in", `<div class="card" style="max-width:420px"><h2 style="margin-top:0">Sign in</h2><p><input value="ada@example.com"></p><p><input type="password" value="secret"></p><span class="btn">Sign in</span></div>`),
  docs: page("Docs", `<div class="card"><h2 style="margin-top:0">API reference</h2><p>GET /api/orders · POST /api/orders · DELETE /api/orders/:id</p></div>`, "#15803d"),
};

async function render(dir) {
  const browser = await chromium.launch();
  const shots = {};
  const context = await browser.newContext({ viewport: { width: 1000, height: 620 } });
  const tab = await context.newPage();
  for (const [name, html] of Object.entries(PAGES)) {
    await tab.setContent(html);
    shots[name] = await tab.screenshot();
  }
  await context.close();
  // A video as Playwright records one: the shop's checkout, walked through.
  const videoDir = join(dir, "video");
  const recorded = await browser.newContext({ viewport: { width: 640, height: 400 }, recordVideo: { dir: videoDir, size: { width: 640, height: 400 } } });
  const walk = await recorded.newPage();
  for (const name of ["home", "product", "cart", "checkout"]) { await walk.setContent(PAGES[name]); await walk.waitForTimeout(400); }
  const video = walk.video();
  await recorded.close();
  shots.video = await video.path();
  await browser.close();
  return shots;
}

// --- runs ---------------------------------------------------------------------------------------
const iso = (t) => new Date(t).toISOString();
let seq = 0;
const runId = (t) => {
  const d = new Date(t), p = (n) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}-${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}-${(0xa00000 + seq++).toString(16)}`;
};

function writeFile(root, rel, data) {
  const path = join(root, ...rel.split("/"));
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

function run(root, { project, kind, command, start, ms, status, log, extra = {} }) {
  const id = runId(start);
  const record = {
    id, project, kind, command, pid: 4000 + seq, workdir: `/data/workspaces/${project}`,
    startedAt: iso(start), status, exitCode: status === "passed" ? 0 : status === "failed" ? 1 : null,
    endedAt: iso(start + ms), durationMs: ms, ...extra,
  };
  writeFile(root, `runs/${id}.json`, JSON.stringify(record));
  writeFile(root, `logs/${id}.log`, log);
  return id;
}

const vitest = (files) => files.map(([file, ok, tests, ms]) => ` ${ok ? "✓" : "×"} ${file} (${tests} tests${ok ? "" : ` | 1 failed`}) ${ms}ms`).join("\n");

export async function seed() {
  const root = mkdtempSync(join(tmpdir(), "testor-seed-"));
  try {
    const shots = await render(root);
    const ids = {};

    // shop · e2e, passed: Playwright's list reporter, a screenshot per spec, a video, an HTML report.
    ids.e2e = run(root, {
      project: "shop", kind: "e2e", command: "npx playwright test --reporter=list", start: now - 25 * MIN, ms: 94_000, status: "passed",
      log: ["Running 9 tests using 3 workers", "",
        "  ✓  1 [chromium] › tests/home.spec.ts:4:1 › shows the collection (1.2s)",
        "  ✓  2 [chromium] › tests/home.spec.ts:12:1 › filters by category (0.9s)",
        "  ✓  3 [chromium] › tests/product.spec.ts:5:1 › adds to the cart (1.4s)",
        "  ✓  4 [chromium] › tests/cart.spec.ts:6:1 › updates quantities (1.1s)",
        "  ✓  5 [chromium] › tests/cart.spec.ts:18:1 › removes an item (0.8s)",
        "  ✓  6 [chromium] › tests/checkout.spec.ts:7:1 › pays with a card (2.6s)",
        "  ✓  7 [chromium] › tests/checkout.spec.ts:30:1 › keeps the address (1.9s)",
        "  ✓  8 [chromium] › tests/login.spec.ts:4:1 › signs in (1.0s)",
        "  ✓  9 [chromium] › tests/login.spec.ts:15:1 › rejects a wrong password (0.7s)", "", "  9 passed (1.5m)", ""].join("\n"),
      extra: { actor: { user: "ci", declared: "ada" } },
    });
    for (const [spec, img] of [["home", "home"], ["product", "product"], ["cart", "cart"], ["checkout", "checkout"], ["login", "login"]])
      writeFile(root, `screenshots/${ids.e2e}/test-results/${spec}-chromium/test-finished-1.png`, shots[img]);
    writeFile(root, `artifacts/${ids.e2e}/test-results/checkout-chromium/video.webm`, (await import("node:fs")).readFileSync(shots.video));
    writeFile(root, `artifacts/${ids.e2e}/playwright-report/index.html`, `<!doctype html><title>Playwright report</title><h1>9 passed</h1>`);
    writeFile(root, `artifacts/${ids.e2e}/playwright-report/data/report.json`, JSON.stringify({ passed: 9 }));

    // shop · unit, failed: Vitest, a failing spec, coverage (Istanbul's summary).
    ids.unit = run(root, {
      project: "shop", kind: "unit", command: "npx vitest run --coverage", start: now - 50 * MIN, ms: 21_400, status: "failed",
      log: [" RUN  v5.1.0 /data/workspaces/shop", "",
        vitest([["tests/cart.test.ts", true, 14, 38], ["tests/price.test.ts", false, 9, 21], ["tests/stock.test.ts", true, 6, 12], ["tests/format.test.ts", true, 22, 9]]),
        "", " FAIL  tests/price.test.ts > applies the spring discount", "AssertionError: expected 43.2 to be 43.20 // Object.is equality",
        "", " Test Files  1 failed | 3 passed (4)", "      Tests  1 failed | 50 passed (51)", ""].join("\n"),
      extra: { error: "1 test failed: tests/price.test.ts" },
    });
    const pct = (covered, total) => ({ total, covered, skipped: 0, pct: Math.round(1000 * covered / total) / 10 });
    writeFile(root, `reports/${ids.unit}/coverage-summary.json`, JSON.stringify({
      total: { lines: pct(842, 960), statements: pct(870, 1000), functions: pct(118, 131), branches: pct(301, 388) },
      "src/cart.ts": { lines: pct(210, 214), statements: pct(220, 224), functions: pct(31, 31), branches: pct(80, 84) },
      "src/price.ts": { lines: pct(180, 240), statements: pct(181, 241), functions: pct(20, 26), branches: pct(51, 90) },
      "src/stock.ts": { lines: pct(300, 330), statements: pct(310, 340), functions: pct(40, 44), branches: pct(120, 150) },
      "src/format.ts": { lines: pct(152, 176), statements: pct(159, 195), functions: pct(27, 30), branches: pct(50, 64) },
    }));
    writeFile(root, `artifacts/${ids.unit}/coverage/index.html`, `<!doctype html><title>Coverage</title><h1>87.7% of lines</h1>`);

    // api · mutation, passed: a mutation-testing report (StrykerJS's schema).
    const source = "export function total(items) {\n  let sum = 0;\n  for (const i of items) sum += i.price * i.qty;\n  return sum > 100 ? sum * 0.9 : sum;\n}\n";
    const mutant = (id, mutatorName, replacement, line, c1, c2, status) => ({ id, mutatorName, replacement, status, location: { start: { line, column: c1 }, end: { line, column: c2 } } });
    ids.mutation = run(root, {
      project: "api", kind: "mutation", command: "npx stryker run", start: now - 3 * HOUR, ms: 7 * MIN + 12_000, status: "passed",
      log: "INFO MutationTestReportHelper Final mutation score of 80.00 is greater than or equal to break threshold 60\n",
    });
    writeFile(root, `reports/${ids.mutation}/mutation.json`, JSON.stringify({
      schemaVersion: "1", thresholds: { high: 80, low: 60 },
      files: {
        "src/total.js": { language: "javascript", source, mutants: [
          mutant("1", "ArithmeticOperator", "i.price / i.qty", 3, 30, 45, "Killed"),
          mutant("2", "EqualityOperator", "sum >= 100", 4, 10, 19, "Survived"),
          mutant("3", "ArithmeticOperator", "sum / 0.9", 4, 22, 31, "Killed"),
          mutant("4", "BlockStatement", "{}", 1, 31, 5, "Killed"),
          mutant("5", "AssignmentOperator", "sum -= i.price * i.qty", 3, 25, 46, "Killed") ] },
        "src/orders.js": { language: "javascript", source: "export const open = (o) => o.filter((x) => !x.closed);\n", mutants: [
          mutant("6", "BooleanLiteral", "x.closed", 1, 42, 51, "Killed"),
          mutant("7", "MethodExpression", "o", 1, 28, 52, "NoCoverage"),
          mutant("8", "ArrowFunction", "() => undefined", 1, 37, 51, "Killed"),
          mutant("9", "ConditionalExpression", "true", 1, 42, 51, "Killed"),
          mutant("10", "ConditionalExpression", "false", 1, 42, 51, "Killed") ] },
      },
    }));

    // shop · e2e as a batch of three shards, one per agent, merged.
    const shardStart = now - 2 * HOUR;
    const shards = [[1, 41_000], [2, 38_500], [3, 44_200]].map(([index, ms]) => ({
      index, ms, id: run(root, {
        project: "shop", kind: "e2e", command: `npx playwright test --shard=${index}/3`, start: shardStart + index * 1000, ms, status: "passed",
        log: `  ✓  1 [chromium] › tests/shard${index}.spec.ts:3:1 › runs its share (1.0s)\n`, extra: { shard: { index, total: 3 } },
      }),
    }));
    ids.batch = run(root, {
      project: "shop", kind: "e2e", command: "batch of 3 shards", start: shardStart, ms: 46_000, status: "passed", log: "",
      extra: { pid: null, batch: { cpuMs: 123_700, shards: shards.map((s) => ({ index: s.index, run: s.id, status: "passed", durationMs: s.ms })) } },
    });

    // History: more projects, more outcomes, over a week.
    const history = [
      ["api", "test", "go test ./...", 6 * HOUR, 48_000, "passed", "ok  \texample.com/api/orders\t0.41s\nok  \texample.com/api/users\t0.22s\nok  \texample.com/api/billing\t1.02s\n"],
      ["api", "test", "go test ./...", DAY + 2 * HOUR, 51_000, "failed", "ok  \texample.com/api/orders\t0.40s\nFAIL\texample.com/api/billing\t0.98s\n"],
      ["docs", "build", "npm run build", 9 * HOUR, 64_000, "cancelled", "[build] compiling 214 pages…\n"],
      ["shop", "lint", "npx eslint .", 2 * DAY, 12_000, "passed", "✔ no problems\n"],
      ["ml", "test", "pytest -q", 3 * DAY, 132_000, "passed", "tests/test_model.py ....  [ 50%]\ntests/test_data.py ....  [100%]\n"],
      ["ml", "test", "pytest -q", 5 * DAY, 129_000, "aborted", "tests/test_model.py ..\n"],
    ];
    for (const [project, kind, command, ago, ms, status, log] of history) ids[`${project}-${kind}-${status}`] = run(root, { project, kind, command, start: now - ago, ms, status, log });
    // A failed e2e run, with the screenshot of its failure.
    ids.failedE2e = run(root, {
      project: "shop", kind: "e2e", command: "npx playwright test --reporter=list", start: now - DAY, ms: 88_000, status: "failed",
      log: "  ✓  1 [chromium] › tests/cart.spec.ts:6:1 › updates quantities (1.1s)\n  ✘  2 [chromium] › tests/checkout.spec.ts:7:1 › pays with a card (5.0s)\n\n  1 failed\n",
    });
    writeFile(root, `screenshots/${ids.failedE2e}/test-results/checkout-chromium/test-failed-1.png`, shots.checkoutFailed);
    // A screenshot dropped in the folder, without a run.
    writeFile(root, "screenshots/docs-home.png", shots.docs);

    // config.json: cleaning from the dashboard, approvals for what AI agents ask.
    writeFile(root, "config.json", JSON.stringify({ maintenance: { enabled: true }, approvals: { tools: ["delete_run", "cancel_run"] } }));

    execFileSync("sh", ["-c", `tar -C "${root}" --owner=10001 --group=10001 -cf - --exclude=video . | docker exec -i ${CONTAINER} tar -xf - -C ${HOME}`]);
    return ids;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// A run in progress: a shell that prints a spec line a second, its pid the run's.
export function startLive() {
  const id = runId(now - 40_000);
  const script = `echo $$ > /tmp/live.pid; i=0; while :; do i=$((i+1)); echo " ✓ tests/orders/case-$i.test.ts (3 tests) 4ms" >> ${HOME}/logs/${id}.log; sleep 1; done`;
  spawnSync("docker", ["exec", "-d", CONTAINER, "sh", "-c", script]);
  let pid = "";
  for (let i = 0; i < 50 && !pid; i++) { pid = spawnSync("docker", ["exec", CONTAINER, "cat", "/tmp/live.pid"], { encoding: "utf8" }).stdout.trim(); }
  const record = { id, project: "api", kind: "test", command: "npx vitest run --reporter=verbose", pid: Number(pid), workdir: "/data/workspaces/api", startedAt: iso(now - 40_000), status: "running" };
  execFileSync("docker", ["exec", "-i", CONTAINER, "sh", "-c", `cat > ${HOME}/runs/${id}.json`], { input: JSON.stringify(record) });
  return id;
}

// Pending approvals: an AI agent (its token, TESTOR_AGENT_TOKEN) asks, over MCP, for tools that
// need a person's approval (approvals in config.json).
export async function askApprovals(base, token, asks) {
  for (const [tool, id] of asks) {
    const res = await fetch(`${base}/mcp`, {
      method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool, arguments: { id } } }),
    });
    const body = await res.json();
    if (!body.result?.structuredContent?.approval) throw new Error(`${tool}: no approval asked: ${JSON.stringify(body)}`);
  }
}

