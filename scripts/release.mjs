#!/usr/bin/env node
// testor's release tool: semantic versions driven by Conventional Commits.
// No dependencies beyond Node.js 20+ and git. See VERSIONING.md.
//
//   node scripts/release.mjs current               the version in orchestrator/mix.exs
//   node scripts/release.mjs next [--from <ref>]   the bump the commits since the last release call for
//   node scripts/release.mjs bump <level|version>  write it: mix.exs and CHANGELOG.md (level: major,
//                                                  minor, patch, auto, or an exact x.y.z[-pre])
//   node scripts/release.mjs check [--tag vX.Y.Z]  mix.exs, CHANGELOG.md and the tag agree
//   node scripts/release.mjs notes <version>       the CHANGELOG section of a version (release notes)
//   node scripts/release.mjs lint-commits <range>  every commit subject in range is a Conventional Commit
//
// The version lives in one place, orchestrator/mix.exs; the release reports it at /api/health
// and in MCP's serverInfo. A release is a tag v<version> on a commit whose
// mix.exs says <version> and whose CHANGELOG.md has a "## <version>" section.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const MIX = join(root, "orchestrator", "mix.exs");
const CHANGELOG = join(root, "CHANGELOG.md");
// Files that carry the version too: bump writes them, check requires them to agree with mix.exs.
export const FOLLOWERS = [
  { file: join(root, "deploy", "helm", "testor", "Chart.yaml"), name: "deploy/helm/testor/Chart.yaml", patterns: [/^(version: )(\S+)()$/m, /^(appVersion: ")([^"]+)(")$/m] },
  {
    file: join(root, "deploy", "terraform", "testor", "variables.tf"),
    name: "deploy/terraform/testor/variables.tf (chart_version)",
    patterns: [/(variable "chart_version" \{[^}]*?default\s*=\s*")([^"]+)(")/],
  },
];

// SemVer 2.0.0, without build metadata (a release is never told apart by it).
const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?$/;
const MIX_VERSION = /^(\s*version: ")([^"]+)(",)$/m;
// "## 1.2.3", "## 1.2.3 - 2026-12-01" or "## Unreleased"
const SECTION = /^## (Unreleased|\S+)(?: - (\d{4}-\d{2}-\d{2}))?\s*$/gm;

export const TYPES = ["feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert"];
// type(scope)!: subject: the scope is lower-case words, the subject starts lower-case or with a
// code span, and does not end with a period.
const CONVENTIONAL = new RegExp(`^(${TYPES.join("|")})(\\([a-z0-9][a-z0-9 ,/_.-]*\\))?(!)?: [^\\sA-Z.](?:.*[^.])?$`);
// Dependabot's own subjects ("build(deps): Bump x from 1 to 2") capitalise "Bump", which it
// cannot be told not to do.
const ALLOWED_SUBJECTS = [/^Merge /, /^Revert "/, /^(fixup|squash|amend)! /, /^(build|ci)\(deps(-dev)?\): Bump \S/];

const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();

function fail(message) {
  console.error(`release: ${message}`);
  process.exit(1);
}

export function parse(version) {
  const m = SEMVER.exec(version);
  if (!m) return null;
  return { major: +m[1], minor: +m[2], patch: +m[3], pre: m[4] ?? null };
}

export function format({ major, minor, patch, pre }) {
  return `${major}.${minor}.${patch}${pre ? `-${pre}` : ""}`;
}

/** Orders two versions as SemVer does: -1, 0 or 1. */
export function compare(a, b) {
  const x = parse(a), y = parse(b);
  for (const k of ["major", "minor", "patch"]) if (x[k] !== y[k]) return x[k] < y[k] ? -1 : 1;
  if (x.pre === y.pre) return 0;
  if (x.pre === null) return 1;
  if (y.pre === null) return -1;
  const p = x.pre.split("."), q = y.pre.split(".");
  for (let i = 0; i < Math.max(p.length, q.length); i++) {
    if (p[i] === undefined) return -1;
    if (q[i] === undefined) return 1;
    const n = /^\d+$/.test(p[i]), m = /^\d+$/.test(q[i]);
    if (n && m && +p[i] !== +q[i]) return +p[i] < +q[i] ? -1 : 1;
    if (n !== m) return n ? -1 : 1;
    if (!n && p[i] !== q[i]) return p[i] < q[i] ? -1 : 1;
  }
  return 0;
}

/**
 * The bump a list of commits calls for: "major", "minor", "patch" or null. Before 1.0.0 a
 * breaking change bumps the minor version and a feature the minor too (SemVer leaves 0.x open;
 * this keeps patch releases safe to take). From 1.0.0 a breaking change bumps the major.
 */
export function levelFor(commits, current) {
  const stable = parse(current).major >= 1;
  let level = null;
  const rank = { patch: 1, minor: 2, major: 3 };
  const raise = (l) => { if (!level || rank[l] > rank[level]) level = l; };
  for (const { subject, body } of commits) {
    const m = CONVENTIONAL.exec(subject);
    const breaking = (m && m[3] === "!") || /^BREAKING[ -]CHANGE: /m.test(body ?? "");
    if (breaking) raise(stable ? "major" : "minor");
    else if (m && m[1] === "feat") raise("minor");
    else if (m && (m[1] === "fix" || m[1] === "perf")) raise("patch");
  }
  return level;
}

export function bumped(current, level) {
  const v = parse(current);
  if (v.pre) {
    // 1.2.0-rc.1 + any level: the release it was a candidate for.
    return format({ ...v, pre: null });
  }
  if (level === "major") return format({ major: v.major + 1, minor: 0, patch: 0 });
  if (level === "minor") return format({ major: v.major, minor: v.minor + 1, patch: 0 });
  return format({ major: v.major, minor: v.minor, patch: v.patch + 1 });
}

export function lintSubject(subject) {
  if (ALLOWED_SUBJECTS.some((r) => r.test(subject))) return null;
  if (subject.length > 100) return "longer than 100 characters";
  if (!CONVENTIONAL.test(subject)) {
    return `not "<type>(<scope>)!: <subject>" with type ${TYPES.join(", ")}; lower-case start, no final period`;
  }
  return null;
}

function currentVersion() {
  const m = MIX_VERSION.exec(readFileSync(MIX, "utf8"));
  if (!m) fail(`no version line in ${MIX}`);
  return m[2];
}

/** The last release: the newest v* tag that is an ancestor of HEAD, or the commit that set the current version. */
function lastRelease() {
  const tags = git("tag", "--list", "v*", "--merged", "HEAD").split("\n").filter((t) => parse(t.slice(1)));
  if (tags.length) {
    const tag = tags.sort((a, b) => compare(a.slice(1), b.slice(1))).at(-1);
    return { ref: tag, label: tag };
  }
  const version = currentVersion();
  const introduced = git("log", "--format=%H", "-S", `version: "${version}"`, "--", "orchestrator/mix.exs").split("\n").filter(Boolean).at(-1);
  if (!introduced) return { ref: null, label: "the first commit" };
  return { ref: introduced, label: `${introduced.slice(0, 7)} (set ${version}; no tag yet)` };
}

function commitsSince(ref) {
  const range = ref ? [`${ref}..HEAD`] : ["HEAD"];
  const out = git("log", "--no-merges", "--format=%H%x1f%s%x1f%b%x1e", ...range);
  return out.split("\x1e").map((e) => e.trim()).filter(Boolean).map((e) => {
    const [hash, subject, body] = e.split("\x1f");
    return { hash, subject, body };
  });
}

/** CHANGELOG.md's sections in order: [{name, date, start, end, body}]. */
export function sections(text) {
  const heads = [...text.matchAll(SECTION)];
  return heads.map((m, i) => {
    const end = i + 1 < heads.length ? heads[i + 1].index : text.length;
    return { name: m[1], date: m[2] ?? null, start: m.index, end, body: text.slice(m.index + m[0].length, end).trim() };
  });
}

function args(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) out[argv[i].slice(2)] = argv[i + 1]?.startsWith("--") === false ? argv[++i] : true;
    else out._.push(argv[i]);
  }
  return out;
}

function cmdNext(opts) {
  const current = currentVersion();
  const base = opts.from ? { ref: opts.from, label: opts.from } : lastRelease();
  const commits = commitsSince(base.ref);
  const level = levelFor(commits, current);
  console.log(`current version: ${current}`);
  console.log(`commits since ${base.label}: ${commits.length}`);
  for (const t of ["breaking", ...TYPES, "other"]) {
    const of = commits.filter((c) => {
      const m = CONVENTIONAL.exec(c.subject);
      const breaking = (m && m[3] === "!") || /^BREAKING[ -]CHANGE: /m.test(c.body ?? "");
      if (t === "breaking") return breaking;
      if (breaking) return false;
      return t === "other" ? !m : m?.[1] === t;
    });
    if (of.length) {
      console.log(`\n${t}:`);
      for (const c of of) console.log(`  ${c.hash.slice(0, 7)} ${c.subject}`);
    }
  }
  console.log(level ? `\nnext: ${bumped(current, level)} (${level})` : "\nnext: no release needed (no feat, fix, perf or breaking change)");
}

function cmdBump(target) {
  if (!target) fail("bump needs a level (major, minor, patch, auto) or a version");
  const current = currentVersion();
  let next;
  if (["major", "minor", "patch"].includes(target)) next = bumped(current, target);
  else if (target === "auto") {
    const level = levelFor(commitsSince(lastRelease().ref), current);
    if (!level) fail("no feat, fix, perf or breaking change since the last release: nothing to release");
    next = bumped(current, level);
  } else if (parse(target)) next = target;
  else fail(`not a level or a SemVer version: ${target}`);
  if (compare(next, current) <= 0) fail(`${next} is not after ${current}`);

  const text = readFileSync(CHANGELOG, "utf8");
  const unreleased = sections(text).find((s) => s.name === "Unreleased");
  if (!unreleased || !unreleased.body) fail(`CHANGELOG.md has no "## Unreleased" entries to release as ${next}`);
  const date = new Date().toISOString().slice(0, 10);
  const changelog = text.slice(0, unreleased.start) + `## Unreleased\n\n## ${next} - ${date}\n\n${unreleased.body}\n\n` + text.slice(unreleased.end);
  writeFileSync(CHANGELOG, changelog);
  writeFileSync(MIX, readFileSync(MIX, "utf8").replace(MIX_VERSION, `$1${next}$3`));
  for (const f of FOLLOWERS) {
    writeFileSync(f.file, f.patterns.reduce((text, p) => text.replace(p, `$1${next}$3`), readFileSync(f.file, "utf8")));
  }
  console.log(`${current} -> ${next}: orchestrator/mix.exs, CHANGELOG.md, the Helm chart and the Terraform module updated.`);
  console.log(`Next: review, commit "chore(release): ${next}", merge, then tag the merge commit:`);
  console.log(`  git tag -s v${next} -m "testor ${next}" && git push origin v${next}`);
}

/** The files of FOLLOWERS whose version is not `version`. */
export function followerErrors(version, read = (file) => readFileSync(file, "utf8")) {
  const errors = [];
  for (const f of FOLLOWERS) {
    const text = read(f.file);
    for (const p of f.patterns) {
      const m = p.exec(text);
      if (!m) errors.push(`${f.name}: no version found`);
      else if (m[2] !== version) errors.push(`${f.name}: ${m[2]} does not match mix.exs (${version})`);
    }
  }
  return errors;
}

function cmdCheck(opts) {
  const errors = [];
  const version = currentVersion();
  if (!parse(version)) errors.push(`orchestrator/mix.exs: "${version}" is not a SemVer version`);
  const all = sections(readFileSync(CHANGELOG, "utf8"));
  const released = all.filter((s) => s.name !== "Unreleased");
  if (all[0]?.name !== "Unreleased") errors.push(`CHANGELOG.md: the first section must be "## Unreleased"`);
  for (const s of released) {
    if (!parse(s.name)) errors.push(`CHANGELOG.md: "## ${s.name}" is not a version`);
  }
  for (let i = 1; i < released.length; i++) {
    if (parse(released[i - 1].name) && parse(released[i].name) && compare(released[i - 1].name, released[i].name) <= 0) {
      errors.push(`CHANGELOG.md: ${released[i - 1].name} is listed above ${released[i].name} but is not newer`);
    }
  }
  const own = released.find((s) => s.name === version);
  if (!own) errors.push(`CHANGELOG.md has no "## ${version}" section for the version in mix.exs`);
  else if (!own.body) errors.push(`CHANGELOG.md: "## ${version}" is empty`);
  if (typeof opts.tag === "string" && opts.tag !== `v${version}`) {
    errors.push(`tag ${opts.tag} does not match mix.exs (expected v${version})`);
  }
  errors.push(...followerErrors(version));
  if (errors.length) fail(`\n  ${errors.join("\n  ")}`);
  console.log(`ok: ${version}${typeof opts.tag === "string" ? `, tag ${opts.tag}` : ""}`);
}

function cmdNotes(version) {
  if (!version) fail("notes needs a version");
  const s = sections(readFileSync(CHANGELOG, "utf8")).find((x) => x.name === version.replace(/^v/, ""));
  if (!s || !s.body) fail(`CHANGELOG.md has no entries for ${version}`);
  console.log(s.body);
}

function cmdLint(range) {
  if (!range) fail("lint-commits needs a range, such as origin/main..HEAD");
  const out = git("log", "--format=%H%x1f%s", range);
  const bad = out.split("\n").filter(Boolean).map((l) => l.split("\x1f")).map(([h, s]) => [h, s, lintSubject(s)]).filter(([, , e]) => e);
  for (const [h, s, e] of bad) console.error(`${h.slice(0, 7)} "${s}": ${e}`);
  if (bad.length) fail(`${bad.length} commit subject(s) are not Conventional Commits (see CONTRIBUTING.md)`);
  console.log("ok: every commit subject is a Conventional Commit");
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("release.mjs")) {
  const [command, ...rest] = process.argv.slice(2);
  const opts = args(rest);
  switch (command) {
    case "current": console.log(currentVersion()); break;
    case "next": cmdNext(opts); break;
    case "bump": cmdBump(opts._[0]); break;
    case "check": cmdCheck(opts); break;
    case "notes": cmdNotes(opts._[0]); break;
    case "lint-commits": cmdLint(opts._[0]); break;
    default:
      fail("usage: release.mjs current | next [--from <ref>] | bump <major|minor|patch|auto|x.y.z> | check [--tag vX.Y.Z] | notes <version> | lint-commits <range>");
  }
}
