# Designs

Designs for what testor does not do yet, written before the code so they can be discussed
(open an issue). Each says what exists today that it builds on, and what it must not break:
the terminal stays unchanged, and nothing starts a command without an explicit opt-in.

| Design | Roadmap | Status |
| ------ | ------- | ------ |
| [Agent protocol](agent-protocol.md): runners that take work from a controller | 0.4 to 0.7 | steps 1 to 4 done ([jobs](../jobs.md)) |
| [Storage, queue and event ports](ports.md): files, SQLite/PostgreSQL, S3, RabbitMQ/NATS | 0.9 | proposed |
| [Identity](identity.md): OIDC, projects and teams, asymmetric tokens, workload identity | 0.8 | in progress: per-project access, asymmetric tokens, single sign-on and the secrets broker done |
