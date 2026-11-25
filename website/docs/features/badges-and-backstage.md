---
sidebar_position: 14.5
title: Badges and Backstage
description: Status badges for READMEs and wikis, and testor's results in a Backstage developer portal.
---

# Badges and Backstage

## Status badges

`/api/v1/projects/<project>/badge.svg` is the latest result of a project as an SVG badge
(`?kind=test` for one task): **passed**, **failed**, **running**...

```markdown
![tests](https://testor.example.com/api/v1/projects/web/badge.svg?kind=test)
```

A badge needs the `read` scope like the rest of the API. To embed one where readers have no
account (a README, a wiki), list the project in `config.json`: `"publicBadges": ["web"]`. Its
badge then answers without credentials. It shows one word and nothing else: no logs, names or
links.

## Backstage

testor's API gives a developer portal what a component's page needs: the latest runs,
whether a commit passes its [release gate](../reference/attestation.md#release-gates), and
the [DORA metrics](../reference/api.md#dora-metrics) of its deploys.

1. **Annotate the component** with its testor project, and link to the dashboard
   ([`deploy/backstage/catalog-info.yaml`](https://github.com/izaccavalheiro/testor/blob/main/deploy/backstage/catalog-info.yaml)):

   ```yaml
   metadata:
     annotations:
       testor.io/project: web
   ```

2. **Proxy testor's API** through Backstage's backend, with a read token of a user limited
   to the projects the portal shows
   ([`deploy/backstage/app-config.testor.yaml`](https://github.com/izaccavalheiro/testor/blob/main/deploy/backstage/app-config.testor.yaml)):
   `/api/proxy/testor/runs?project=web`, `/api/proxy/testor/projects/web/dora`,
   `/api/proxy/testor/gates/web-release?commit=...`.

3. **Show it**: the badge in the component's overview (a Markdown card or the README
   Backstage renders), and the proxy's JSON in a card of your own (the `testor.io/project`
   annotation tells it which project).

The token goes in Backstage's configuration (`${TESTOR_TOKEN}`), never in the browser.
