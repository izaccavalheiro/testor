import Link from "@docusaurus/Link";
import CodeBlock from "@theme/CodeBlock";
import Layout from "@theme/Layout";
import type { ReactNode } from "react";
import styles from "./index.module.css";

const FEATURES: readonly (readonly [string, ReactNode, string])[] = [
  [
    "Live, line by line",
    <>Output streamed to the browser as the runner prints it, with the spec file in progress and running pass and fail counts.</>,
    "/docs/features/live-runs",
  ],
  [
    "Results without reporters",
    <>Spec files and test counts read from the normal output of Vitest, Playwright, pytest, <code>go test</code> and <code>cargo test</code>.</>,
    "/docs/features/spec-results",
  ],
  [
    "Evidence kept",
    <>Screenshots matched to their spec, videos, HTML reports, coverage and JUnit XML kept with each run, served sandboxed.</>,
    "/docs/features/artifacts",
  ],
  [
    "The machine, too",
    <>CPU per core, memory, GPU, disks, network, battery, and the CPU and memory of each test run's process tree.</>,
    "/docs/features/device-stats",
  ],
  [
    "Built for automation",
    <>A versioned JSON API with an OpenAPI 3.1 document and event streams, and an MCP server so AI agents read why a run failed.</>,
    "/docs/features/http-api",
  ],
  [
    "Secure when shared",
    <>Users, roles and scopes, JWT tokens, signed links, DNS rebinding and CSRF protection, rate limiting, built-in TLS, secrets masked in logs.</>,
    "/docs/features/authentication",
  ],
  [
    "Jobs and agents",
    <>Queue runs through the API; agents run them on your machines, other networks, containers or Kubernetes, and send them back. Off until you turn it on.</>,
    "/docs/features/jobs-and-agents",
  ],
  [
    "Evidence you can check",
    <>Every run signed as an in-toto attestation, runs from agents signed by the agent too, and a tamper-evident audit trail, all verifiable with OpenSSL.</>,
    "/docs/features/signed-results",
  ],
];

const TASKFILE = `# your project's Taskfile.yml
includes:
  runner:
    taskfile: ~/git/testor/taskfiles/remote.yml
    internal: true
    vars: { RUNNER: my-runner }
tasks:
  test:
    cmds:
      - task: runner:sync      # upload the working tree, uncommitted changes included
      - task: runner:npm-ci    # only when package-lock.json changed
      - task: runner:exec
        vars: { KIND: test, CMD: "npm test -- {{.CLI_ARGS}}" }`;

const TERMINAL = `$ task test
task: [runner:sync] sync ~/src/my-app -> ~/test-run/my-app
 ✓ tests/parser.test.ts (14 tests) 52ms
 ✓ tests/paths.test.ts (9 tests) 31ms
 Test Files  2 passed (2)
      Tests  23 passed (23)
$ echo $?
0          # same output, same exit code; live at http://my-runner:6767`;

export default function Home(): ReactNode {
  return (
    <Layout
      title="The free, open-source test orchestrator"
      description="testor runs your test suites on any machine over SSH and streams them live to a dashboard, an HTTP API and AI agents."
    >
      <header className={styles.hero}>
        <h1 className={styles.title}>testor</h1>
        <p className={styles.tagline}>
          Run your test suites on any machine you can reach over SSH, on Windows, Linux or macOS,
          and watch them live. Free and open source, on your hardware or in your cloud.
        </p>
        <div className={styles.buttons}>
          <Link className="button button--primary button--lg" to="/docs/getting-started/quick-start">
            Quick start
          </Link>
          <Link className="button button--secondary button--lg" to="/docs/scenarios">
            Real scenarios
          </Link>
          <Link className="button button--secondary button--lg" href="https://github.com/izaccavalheiro/testor">
            GitHub
          </Link>
        </div>
        <p className={styles.badges}>MIT licensed · no paid tier · no telemetry · Elixir/OTP with two dependencies</p>
      </header>

      <main>
        <section className={styles.section}>
          <div className="container">
            <div className={styles.split}>
              <div>
                <h2 style={{ textAlign: "left" }}>Your terminal, unchanged</h2>
                <p>
                  Keep editing and using git where you are. <code>task test</code> uploads a snapshot of
                  your working tree and runs the command on the runner. Output, stderr and the exit code
                  reach your terminal exactly as if it ran locally, so scripts and git hooks keep working.
                </p>
                <p>
                  Meanwhile testor records the run and streams it to everyone watching: the log, spec
                  files as they finish, screenshots, reports, and the machine's load.
                </p>
                <p>
                  <Link to="/docs/getting-started/how-it-works">How it works →</Link>
                </p>
              </div>
              <div className={styles.terminal}>
                <CodeBlock language="bash">{TERMINAL}</CodeBlock>
              </div>
            </div>
          </div>
        </section>

        <section className={styles.section}>
          <div className="container">
            <h2>Everything a run produces, in one place</h2>
            <div className={styles.grid}>
              {FEATURES.map(([title, body, to]) => (
                <div key={title} className={styles.card}>
                  <h3>
                    <Link to={to}>{title}</Link>
                  </h3>
                  <p>{body}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section className={styles.section}>
          <div className="container">
            <h2>Runs where you need it</h2>
            <div className={styles.grid}>
              <div className={styles.card}>
                <h3>On premises</h3>
                <p>
                  A spare laptop, a mini PC, a Mac on a shelf, a GPU box for the team. Reachable over your
                  LAN or Tailscale. <Link to="/docs/scenarios/home-lab-tailscale">Scenario →</Link>
                </p>
              </div>
              <div className={styles.card}>
                <h3>In your cloud</h3>
                <p>
                  Any Linux or Windows VM, private behind Tailscale or public behind TLS, with users and
                  roles. <Link to="/docs/scenarios/cloud-vm-runner">Scenario →</Link>
                </p>
              </div>
              <div className={styles.card}>
                <h3>Cloud native</h3>
                <p>
                  Container images, a Helm chart, and test agents in Kubernetes scaled by KEDA on queued
                  jobs. <Link to="/docs/features/jobs-and-agents">Jobs and agents →</Link>
                </p>
              </div>
            </div>
          </div>
        </section>

        <section className={styles.section}>
          <div className="container">
            <h2>Ten lines in your project</h2>
            <div className={styles.terminal}>
              <CodeBlock language="yaml">{TASKFILE}</CodeBlock>
              <p style={{ textAlign: "center" }}>
                <Link className="button button--primary" to="/docs/getting-started/quick-start">
                  Set up a runner in 15 minutes
                </Link>
              </p>
            </div>
          </div>
        </section>
      </main>
    </Layout>
  );
}
