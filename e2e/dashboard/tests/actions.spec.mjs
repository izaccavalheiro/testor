// What changes testor from the dashboard: approvals, cancelling, deleting, cleaning up. Runs once,
// after the read-only pages (playwright.config.mjs), in this order.
import { expect, test } from "@playwright/test";

const ids = () => JSON.parse(process.env.SEED);
test.describe.configure({ mode: "serial" });

async function open(page, path) {
  await page.goto(path);
  await expect(page.locator("#conn-text")).toContainText("live", { timeout: 30_000 });
}

test("denying an approval: nothing is done, the request leaves the list", async ({ page }) => {
  await open(page, "/");
  const item = page.locator("#approvals .item", { hasText: "cancel_run" });
  await item.getByRole("button", { name: "Deny" }).click();
  await expect(item).toHaveCount(0);
  await expect(page.locator(`.card[data-run="${ids().live}"]`)).toBeVisible();
});

test("approving one: testor does it as the agent (the run is deleted)", async ({ page }) => {
  await open(page, "/");
  const id = ids()["docs-build-cancelled"];
  await expect(page.locator(`tr[data-run="${id}"]`)).toBeVisible();
  await page.locator("#approvals .item", { hasText: "delete_run" }).getByRole("button", { name: "Approve" }).click();
  await expect(page.locator("#approvals")).toBeHidden();
  await expect(page.locator(`tr[data-run="${id}"]`)).toHaveCount(0);
});

test("cancelling the run in progress, after confirming", async ({ page }) => {
  await open(page, `/#/run/${ids().live}`);
  let asked = "";
  page.once("dialog", (dialog) => { asked = dialog.message(); dialog.accept(); });
  await page.getByRole("button", { name: "Cancel run" }).click();
  await expect(page.locator(".badge").first()).toHaveText("cancelled", { timeout: 30_000 });
  expect(asked).toContain("api · test");
  await expect(page.getByRole("button", { name: "Delete run" })).toBeVisible();
  await expect(page.locator("#log-head")).not.toContainText("streaming");
  await open(page, "/");
  await expect(page.getByText("Nothing is running.")).toBeVisible();
});

test("deleting a run: a refused confirmation keeps it, an accepted one deletes it", async ({ page }) => {
  const id = ids()["ml-test-aborted"];
  await open(page, `/#/run/${id}`);
  page.once("dialog", (dialog) => dialog.dismiss());
  await page.getByRole("button", { name: "Delete run" }).click();
  await expect(page).toHaveURL(new RegExp(`#/run/${id}$`));
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Delete run" }).click();
  await expect(page).toHaveURL(/#\/$/);
  await expect(page.locator(`tr[data-run="${id}"]`)).toHaveCount(0);
  // ml's newer run stays its latest.
  await expect(page.locator(`.board a.chip[href="#/run/${encodeURIComponent(ids()["ml-test-passed"])}"]`)).toBeVisible();
});

test("a toast tells when a run starts and ends, and opens it", async ({ page }) => {
  await open(page, "/");
  const id = `20991231-235959-${Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, "0")}`;
  const container = process.env.TESTOR_CONTAINER;
  const { execFileSync } = await import("node:child_process");
  const write = (record) => execFileSync("docker", ["exec", "-i", container, "sh", "-c", `cat > /data/workspaces/.testor/runs/${id}.json`], { input: JSON.stringify(record) });
  const pid = Number(execFileSync("docker", ["exec", container, "sh", "-c", "sleep 60 >/dev/null 2>&1 & echo $!"], { encoding: "utf8" }).trim());
  const record = { id, project: "toast", kind: "test", command: "npm test", pid, workdir: "/data/workspaces/toast", startedAt: new Date().toISOString(), status: "running" };
  write(record);
  await expect(page.locator(".toast", { hasText: "toast · test started" })).toBeVisible();
  write({ ...record, status: "passed", exitCode: 0, endedAt: new Date().toISOString(), durationMs: 2000 });
  const done = page.locator(".toast", { hasText: "toast · test" }).filter({ hasText: "passed" });
  await expect(done).toBeVisible();
  await done.click();
  await expect(page).toHaveURL(new RegExp(`#/run/${id}$`));
});

test("cleaning up the screenshots and artifacts folders now", async ({ page }) => {
  for (const path of ["/#/shots", "/#/artifacts"]) {
    await open(page, path);
    const button = page.getByRole("button", { name: "Clean up now" });
    await button.click();
    await expect(button).toBeEnabled();
    await expect(button).toHaveText("Clean up now");
  }
  // Nothing was old or over the limits: everything is kept.
  await expect(page.locator("h3.group")).toHaveCount(2);
});

test("after testor restarts, the dashboard connects again by itself", async ({ page }) => {
  test.setTimeout(90_000);
  await open(page, "/");
  const { execFileSync } = await import("node:child_process");
  execFileSync("docker", ["restart", process.env.TESTOR_CONTAINER]);
  await expect(page.locator("#conn-text")).not.toContainText("live", { timeout: 30_000 });
  await expect(page.locator("#conn-text")).toContainText("live", { timeout: 60_000 });
  await expect(page.locator("tbody tr.click").first()).toBeVisible();
});
