# Impact analysis

For a change, testor says which tests to run first, from the project's own history:

```sh
curl -u ada -H 'content-type: application/json' https://testor.example.com/api/v1/projects/shop/impact \
  -d '{"changed": ["src/cart.ts", "src/price.ts"], "limit": 20}'
```

```json
{"data": [
  {"file": "tests/cart.flow.test.ts", "score": 6.8, "reasons": ["co-failed with src/cart.ts", "failed recently"]},
  {"file": "tests/cart.test.ts", "score": 2.0, "reasons": ["named after src/cart.ts"]}
]}
```

MCP has the same as `get_impacted_tests` (scope read, per project).

## The evidence

| Evidence | Points |
| -------- | ------ |
| **co-failure**: a past run that failed with one of these files in its `changedFiles`, per failing spec, weighed down by age (a 30-day half-life) | 3 |
| a changed spec file itself | 5 |
| **coverage**: the spec covers a changed file, from the latest mutation report's `coveredBy` and `testFiles` | 2 |
| **naming**: `src/foo.ts` and `foo.test.ts`, `foo.spec.ts`, `test_foo.py`, `foo_test.go` | 2 |
| **recency**: a ranked spec that failed in the last 10 runs | 1 |

After the ranked specs come the rest of the suite's, the shortest first, so a ranking always
covers it. Without history, it falls back to naming, then to duration. It reads the project's
last 500 run records when asked.

A run records `changedFiles`: the files a snapshot job's change touched (testor gives the agent
the files changed since the branch's last snapshot), else what git says where the run's folder
is a repository (the branch's commits since its upstream's main, and what is not committed). At
most 1,000 relative paths; untrusted, shown escaped.

## Using it

- A job with `"order": "impact"` gets `TESTOR_TEST_ORDER`, a file of its specs in rank order,
  for a command that can take an order.
- `"impact": {"first": 20}` with it runs the 20 first-ranked specs alone (as files of the
  task's `select`), reported at once, then the whole suite; `"failFast": true` skips the rest
  when they fail.
- [Affected tests](handoff.md#affected-tests) found by naming are run in this order too.

## Measuring it

`Testor.Impact.replay/1` runs the ranking over a project's recorded history: for each failed run
with `changedFiles`, the ranks its failing specs get from the runs before it. It reports the
average APFD (average percentage of faults detected; 1 is best) and the median rank of the first
failing spec:

```sh
bin/testor eval 'IO.inspect(Testor.Impact.replay(~s[shop]))'
# %{"apfd" => 0.91, "medianRank" => 2, "medianRankPercent" => 4.0, "runs" => 37}
```
