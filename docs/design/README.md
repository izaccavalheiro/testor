# Designs

Designs for what testor does not do yet, written before the code so they can be discussed
(open an issue). Each says what exists today that it builds on, and what it must not break:
the terminal stays unchanged, and nothing starts a command without an explicit opt-in.

| Design | Roadmap | Status |
| ------ | ------- | ------ |
| [Agent protocol](agent-protocol.md): runners that take work from a controller | 0.4 to 0.12 | steps 1 to 5 done ([jobs](../jobs.md), the hub in 0.12); `container` and `kubernetes` executors and a job's `timeout` next (0.16) |
| [Storage, queue and event ports](ports.md): files, PostgreSQL, S3, SQS/NATS | 0.10 to 0.18 | in progress: the archive, PostgreSQL's queue and several testors done; brokers (0.17), S3 as the main store (0.18) next |
| [Identity](identity.md): OIDC, projects and teams, asymmetric tokens, workload identity, links | 0.8, 0.13 | done |

## Decisions

Items of these designs that testor will not build, and why:

| Item | Decision |
| ---- | -------- |
| SQLite as the single-node run index (ports) | Dropped: files and ETS already serve one node, and SQLite would add a native dependency for no gain. PostgreSQL covers several nodes. |
| Redis for live events (ports) | Dropped: PostgreSQL `LISTEN`/`NOTIFY` needs no new service or dependency. |
| A `worker` executor: Cloudflare Workers, Lambda (agent protocol) | Deferred: these platforms cannot run a project's test command with a file system; suites that target Workers already run in workerd through their own tooling, on any agent. |
| Commands allow-listed in the repository (`.testor.yml` at the commit, agent protocol) | Not done: the runner's owner decides what runs (`agent.json`), and a push cannot change it. |
| WebSocket or mTLS for agents (agent protocol) | Not needed: leases over HTTPS long polling, agent tokens and keys pinned at the first lease (0.7) do the job; ACME (0.13) covers the server's certificate. |
