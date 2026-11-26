// Tests of scripts/release.mjs: node --test scripts/
import assert from "node:assert/strict";
import { test } from "node:test";
import { bumped, compare, FOLLOWERS, followerErrors, levelFor, lintSubject, parse, sections } from "./release.mjs";

const c = (subject, body = "") => ({ subject, body });

test("parse and compare follow SemVer 2.0.0 precedence", () => {
  assert.deepEqual(parse("1.2.3-rc.1"), { major: 1, minor: 2, patch: 3, pre: "rc.1" });
  assert.equal(parse("01.2.3"), null);
  assert.equal(parse("1.2"), null);
  const ordered = ["0.9.0", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"];
  for (let i = 1; i < ordered.length; i++) {
    assert.equal(compare(ordered[i - 1], ordered[i]), -1, `${ordered[i - 1]} < ${ordered[i]}`);
    assert.equal(compare(ordered[i], ordered[i - 1]), 1);
  }
  assert.equal(compare("1.0.0", "1.0.0"), 0);
});

test("before 1.0.0, breaking changes and features bump the minor version", () => {
  assert.equal(levelFor([c("fix: a"), c("feat(api): b")], "0.1.0"), "minor");
  assert.equal(levelFor([c("feat!: drop the old routes")], "0.4.2"), "minor");
  assert.equal(levelFor([c("fix: a"), c("perf(store): b")], "0.1.0"), "patch");
  assert.equal(levelFor([c("docs: a"), c("chore: b"), c("ci: c")], "0.1.0"), null);
});

test("from 1.0.0, a breaking change bumps the major version", () => {
  assert.equal(levelFor([c("feat!: x")], "1.3.0"), "major");
  assert.equal(levelFor([c("refactor(auth): x", "BREAKING CHANGE: tokens need aud")], "1.3.0"), "major");
  assert.equal(levelFor([c("feat: x")], "1.3.0"), "minor");
});

test("bumped resets lower parts, and a pre-release becomes its release", () => {
  assert.equal(bumped("0.1.0", "minor"), "0.2.0");
  assert.equal(bumped("0.1.4", "patch"), "0.1.5");
  assert.equal(bumped("1.9.3", "major"), "2.0.0");
  assert.equal(bumped("1.0.0-rc.2", "patch"), "1.0.0");
});

test("lintSubject accepts Conventional Commits and refuses the rest", () => {
  for (const ok of ["feat: versioned API, MCP server and authentication", "fix(runner): install.ps1 exits 0 when it succeeds", "feat(api)!: rename runs.kind", "docs: `run.ps1` parameters", "Merge pull request #3 from x/y", 'Revert "feat: x"']) {
    assert.equal(lintSubject(ok), null, ok);
  }
  for (const bad of ["Added stuff", "feat: Capitalized", "feat: ends with a period.", "feature: x", "fix(Runner): x", "feat:no space"]) {
    assert.notEqual(lintSubject(bad), null, bad);
  }
});

test("sections splits CHANGELOG.md by version", () => {
  const text = "# Changelog\n\nintro\n\n## Unreleased\n\n- a\n\n## 0.2.0 - 2026-12-01\n\n- b\n\n## 0.1.0\n\n- c\n";
  const s = sections(text);
  assert.deepEqual(s.map((x) => [x.name, x.date, x.body]), [["Unreleased", null, "- a"], ["0.2.0", "2026-12-01", "- b"], ["0.1.0", null, "- c"]]);
});

test("the Helm chart and the Terraform module carry mix.exs's version", () => {
  const texts = {
    [FOLLOWERS[0].file]: 'version: 1.2.3\nappVersion: "1.2.3"\n',
    [FOLLOWERS[1].file]: 'variable "chart_version" {\n  type    = string\n  default = "1.2.3"\n}\n',
  };
  assert.deepEqual(followerErrors("1.2.3", (f) => texts[f]), []);
  assert.equal(followerErrors("1.2.4", (f) => texts[f]).length, 3);
  assert.match(followerErrors("1.2.3", () => "")[0], /no version found/);
});
