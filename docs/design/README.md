# Designs

Designs for what testor does not do yet, written before the code so they can be discussed
(open an issue). Each says what exists today that it builds on, and what it must not break:
the terminal stays unchanged, and nothing starts a command without an explicit opt-in.

| Design | Roadmap | Status |
| ------ | ------- | ------ |
| [Agent protocol](agent-protocol.md): runners that take work from a controller | 0.4, 0.5 | steps 1 and 2 done ([jobs](../jobs.md)) |
| [Storage, queue and event ports](ports.md): files, SQLite/PostgreSQL, S3, RabbitMQ/NATS | 0.6 | proposed |
| [Identity](identity.md): OIDC, projects and teams, asymmetric tokens, workload identity | 0.7 | proposed |
