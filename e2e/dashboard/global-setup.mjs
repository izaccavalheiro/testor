// Seeds the testor container once for every spec; the runs' ids reach the specs in SEED.
import { askApprovals, seed, startLive } from "./seed.mjs";

export default async function globalSetup() {
  const ids = await seed();
  // The store reads the finished runs first; the live run then starts as run.ps1's would.
  await new Promise((resolve) => setTimeout(resolve, 1500));
  ids.live = startLive();
  await new Promise((resolve) => setTimeout(resolve, 1500));
  await askApprovals(process.env.TESTOR_URL, process.env.TESTOR_AGENT_TOKEN, [["delete_run", ids["docs-build-cancelled"]], ["cancel_run", ids.live]]);
  process.env.SEED = JSON.stringify(ids);
}
