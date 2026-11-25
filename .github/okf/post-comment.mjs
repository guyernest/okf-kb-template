// Phase 212 (KPRV-01, D-06, D-07): stage 2 of the okf-check sticky PR comment.
//
// This script runs from the default branch's `okf-preview-comment` workflow (a `workflow_run`
// job holding `pull-requests: write`). It NEVER executes PR content. The stage-1 artifact is
// produced by a run of the PR's own workflow, so for a fork PR it is attacker-controlled data:
// every field is treated as a claim to be proven against GitHub's own records before anything
// is written, and the comment text is re-validated here before it is posted.
//
// Failure never escalates: every problem becomes one `::warning::` line (a reason token only,
// never the comment body or the token) and the process exits 0, so a poster problem can never
// change the stage-1 check conclusion.
import * as nodeFs from 'node:fs';
import { pathToFileURL } from 'node:url';

export const MARKER = '<!-- okf-check-preview:v1 -->';
export const COMMENT_MAX_BYTES = 60000;

const PR_JSON_MAX_BYTES = 1024;
const MAX_PAGES = 30;
const PER_PAGE = 100;
const MAX_PR_NUMBER = 2147483647;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const SHA_RE = /^[0-9a-f]{40}([0-9a-f]{24})?$/;
const RUN_URL_RE = /^https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/actions\/runs\/[0-9]+$/;
const BOT_LOGIN = 'github-actions[bot]';

/** A reason the poster declines to write. `reason` is a fixed token, never PR-derived text. */
export class Skip extends Error {
  constructor(reason) {
    super(reason);
    this.name = 'Skip';
    this.reason = reason;
  }
}

/** A non-2xx GitHub response. Only the status is kept; the response body is never surfaced. */
export class ApiError extends Error {
  constructor(status) {
    super(`http ${status}`);
    this.name = 'ApiError';
    this.status = status;
  }
}

// ---------------------------------------------------------------- markdown allow-list v1 (D-07)
//
// ONE contract, implemented twice: here (the poster re-checks `comment.md` as untrusted) and in
// the Rust renderer (Plan 04 self-checks its own output). Both are tested case by case against
// tests/fixtures/okf-check/preview/comment-corpus.json, so a change to a rule changes the
// corpus and BOTH validators together, never one side.
//
// Rules run in this order and the FIRST failure decides the reason token:
//   1 too-large  2 encoding  3 marker  4 control-characters, then per line (comment: from
//   line 2; summary: from line 1), in line order:
//   5 fence  6 workflow-command  7 unbalanced-code-span  8 table-pipe-in-span
//   9 url-outside-code  10 reference-outside-code  11 disallowed-character
// Outside code spans only a small ASCII set is allowed, so no markup that could link, mention,
// embed or reference survives; inside a span anything but a control character is data.
export const SUMMARY_PART_MAX_BYTES = 900000;

export const REASONS = Object.freeze([
  'too-large',
  'encoding',
  'marker',
  'control-characters',
  'fence',
  'workflow-command',
  'unbalanced-code-span',
  'table-pipe-in-span',
  'url-outside-code',
  'reference-outside-code',
  'disallowed-character',
]);

// ASCII punctuation allowed outside code spans (letters, digits and space are tested by range).
const ALLOWED_PUNCTUATION = new Set(Array.from(".,:;()-_/*|+='\"?%#", (c) => c.codePointAt(0)));
const MIDDLE_DOT = 0x00b7;

function isAllowedOutside(cp) {
  return (
    (cp >= 0x30 && cp <= 0x39) ||
    (cp >= 0x41 && cp <= 0x5a) ||
    (cp >= 0x61 && cp <= 0x7a) ||
    cp === 0x20 ||
    cp === MIDDLE_DOT ||
    ALLOWED_PUNCTUATION.has(cp)
  );
}

function isControl(cp) {
  return (
    (cp <= 0x1f && cp !== 0x0a) ||
    cp === 0x7f ||
    (cp >= 0x80 && cp <= 0x9f) ||
    cp === 0x2028 ||
    cp === 0x2029 ||
    cp === 0x200e ||
    cp === 0x200f ||
    (cp >= 0x202a && cp <= 0x202e) ||
    (cp >= 0x2066 && cp <= 0x2069) ||
    cp === 0xfeff
  );
}

/**
 * The CommonMark backtick-run scan over ONE line: an opening run closes at the next run of
 * exactly the same length, and a span never continues onto the next line. `balanced` is false
 * when some run has no closing run on the line (that run is then literal text).
 */
export function codeSpans(line) {
  const spans = [];
  let balanced = true;
  let i = 0;
  while (i < line.length) {
    if (line[i] !== '`') {
      i++;
      continue;
    }
    let j = i;
    while (line[j] === '`') j++;
    const n = j - i;
    let k = j;
    let close = -1;
    while (k < line.length) {
      if (line[k] === '`') {
        let m = k;
        while (line[m] === '`') m++;
        if (m - k === n) {
          close = k;
          break;
        }
        k = m;
      } else {
        k++;
      }
    }
    if (close < 0) {
      balanced = false;
      i = j;
    } else {
      spans.push({ start: i, end: close + n, content: line.slice(j, close) });
      i = close + n;
    }
  }
  return { spans, balanced };
}

/** The line with every complete code span removed; an unmatched run stays as outside text. */
export function outsideCodeSpans(line) {
  const { spans } = codeSpans(line);
  let out = '';
  let at = 0;
  for (const s of spans) {
    out += line.slice(at, s.start);
    at = s.end;
  }
  return out + line.slice(at);
}

/**
 * True when the text holds a token like `GH-12`: a letter-led alphanumeric run immediately
 * followed by a hyphen and a digit (`[A-Za-z][A-Za-z0-9]*-[0-9]`). Written as a single linear
 * scan: the regex form backtracks quadratically on a long run of letters.
 */
function hasLetterLedHyphenDigit(text) {
  let runHasLetter = false;
  let inRun = false;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    const isLetter = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    const isDigit = c >= 0x30 && c <= 0x39;
    if (isLetter || isDigit) {
      runHasLetter = runHasLetter || isLetter;
      inRun = true;
      continue;
    }
    if (c === 0x2d && inRun && runHasLetter) {
      const next = text.charCodeAt(i + 1);
      if (next >= 0x30 && next <= 0x39) return true;
    }
    runHasLetter = false;
    inRun = false;
  }
  return false;
}

function checkLine(line) {
  if (/^ {0,3}(?:`{3,}|~{3,})/.test(line)) return 'fence';
  if (line.startsWith('::')) return 'workflow-command';
  const { spans, balanced } = codeSpans(line);
  if (!balanced) return 'unbalanced-code-span';
  // Every line, not only lines that start with `|`: GFM reads each line after a table header
  // and delimiter row as a body row and splits it on an unescaped `|` BEFORE it reads code spans.
  if (spans.some((s) => /(?:^|[^\\])\|/.test(s.content))) return 'table-pipe-in-span';
  const outside = outsideCodeSpans(line);
  const lower = outside.toLowerCase();
  if (lower.includes('://') || lower.includes('www.')) return 'url-outside-code';
  // A leading heading run (`# ` .. `###### `) is the one place a `#` is legitimate.
  const heading = /^#{1,6} /.exec(line);
  const rest = heading ? outside.slice(heading[0].length - 1) : outside;
  if (rest.includes('#')) return 'reference-outside-code';
  if (hasLetterLedHyphenDigit(outside)) return 'reference-outside-code';
  for (const m of outside.matchAll(/[0-9A-Fa-f]{7,}/g)) {
    if (/[A-Fa-f]/.test(m[0])) return 'reference-outside-code';
  }
  for (const ch of outside) {
    if (!isAllowedOutside(ch.codePointAt(0))) return 'disallowed-character';
  }
  return null;
}

/**
 * Validate `text` (a string or the raw bytes) against the allow-list. kind is `comment`
 * (one sticky comment, marker required) or `summary` (one job-summary part, marker forbidden).
 * Returns {ok: true} or {ok: false, reason}.
 */
export function validateMarkdown(input, kind) {
  if (kind !== 'comment' && kind !== 'summary') throw new TypeError('kind must be comment or summary');
  const limit = kind === 'summary' ? SUMMARY_PART_MAX_BYTES : COMMENT_MAX_BYTES;
  const isString = typeof input === 'string';
  const bytes = isString ? Buffer.byteLength(input, 'utf8') : input.length;
  if (bytes > limit) return { ok: false, reason: 'too-large' };

  let text;
  if (isString) {
    // A lone surrogate cannot be encoded as UTF-8.
    if (/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(input)) {
      return { ok: false, reason: 'encoding' };
    }
    text = input;
  } else {
    try {
      // ignoreBOM keeps a U+FEFF in the text so rule 4 can refuse it.
      text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(input);
    } catch {
      return { ok: false, reason: 'encoding' };
    }
  }

  const firstNewline = text.indexOf('\n');
  if (kind === 'comment') {
    const first = firstNewline < 0 ? text : text.slice(0, firstNewline);
    if (first !== MARKER || text.indexOf(MARKER, MARKER.length) >= 0) return { ok: false, reason: 'marker' };
  } else if (text.includes(MARKER)) {
    return { ok: false, reason: 'marker' };
  }

  for (const ch of text) {
    if (isControl(ch.codePointAt(0))) return { ok: false, reason: 'control-characters' };
  }

  const lines = text.split('\n');
  for (let n = kind === 'comment' ? 1 : 0; n < lines.length; n++) {
    const reason = checkLine(lines[n]);
    if (reason) return { ok: false, reason };
  }
  return { ok: true };
}

export function validateComment(input) {
  return validateMarkdown(input, 'comment');
}

/**
 * The fixed notice posted when `comment.md` fails validation. Built only from a reason token
 * and the validated head sha, so it carries nothing from the artifact; it is itself valid.
 */
export function fallbackBody(reason, headSha) {
  if (!REASONS.includes(reason)) throw new TypeError('unknown reason token');
  if (typeof headSha !== 'string' || !SHA_RE.test(headSha)) throw new TypeError('invalid head sha');
  return (
    `${MARKER}\n### okf-check preview\n\n` +
    `The preview for commit \`${headSha.slice(0, 12)}\` could not be shown (${reason}). ` +
    'The check result is unaffected; see the okf-check job summary.\n'
  );
}

// ---------------------------------------------------------------- pr.json

/** `pr.json` is exactly `{"number": <int>, "headSha": "<hex>"}`; anything else throws a token. */
export function parsePrJson(text) {
  let obj;
  try {
    obj = JSON.parse(text);
  } catch {
    throw new Skip('pr-json-invalid');
  }
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) throw new Skip('pr-json-invalid');
  const keys = Object.keys(obj).sort();
  if (keys.length !== 2 || keys[0] !== 'headSha' || keys[1] !== 'number') throw new Skip('pr-json-invalid');
  const { number, headSha } = obj;
  if (typeof number !== 'number' || !Number.isInteger(number) || number < 1 || number > MAX_PR_NUMBER) {
    throw new Skip('pr-json-invalid');
  }
  if (typeof headSha !== 'string' || !SHA_RE.test(headSha)) throw new Skip('pr-json-invalid');
  return { number, headSha };
}

/** `OKF_RUN_PR_NUMBERS` is a JSON array of at most 100 PR numbers (GitHub's own association). */
export function parseRunPrNumbers(text) {
  let arr;
  try {
    arr = JSON.parse(text);
  } catch {
    throw new Skip('run-prs-invalid');
  }
  if (!Array.isArray(arr) || arr.length > 100) throw new Skip('run-prs-invalid');
  for (const n of arr) {
    if (typeof n !== 'number' || !Number.isInteger(n) || n < 1 || n > MAX_PR_NUMBER) throw new Skip('run-prs-invalid');
  }
  return arr;
}

// ---------------------------------------------------------------- GitHub API

export function makeApi({ fetchImpl, baseUrl, token }) {
  if (typeof baseUrl !== 'string' || !baseUrl.startsWith('https://')) throw new Skip('env-invalid');
  const base = baseUrl.replace(/\/+$/, '');
  return {
    async request(method, apiPath, body) {
      const headers = {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };
      const init = { method, headers };
      if (body !== undefined) {
        init.body = JSON.stringify(body);
        headers['Content-Type'] = 'application/json';
      }
      const res = await fetchImpl(`${base}${apiPath}`, init);
      if (!res || res.status < 200 || res.status >= 300) throw new ApiError(res ? res.status : 0);
      const text = await res.text();
      return text === '' ? null : JSON.parse(text);
    },
  };
}

/** Page through a list endpoint. `complete` is true only when a short page proved the end. */
async function listPages(api, pathAndQuery) {
  const sep = pathAndQuery.includes('?') ? '&' : '?';
  const items = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const batch = await api.request('GET', `${pathAndQuery}${sep}per_page=${PER_PAGE}&page=${page}`);
    if (!Array.isArray(batch)) throw new Skip('api-shape');
    items.push(...batch);
    if (batch.length < PER_PAGE) return { items, complete: true };
  }
  return { items, complete: false };
}

/**
 * Prove the artifact's PR claim against GitHub's records. Returns {ok: true, number} or
 * {ok: false, reason}; nothing is written either way. The artifact's number is only a claim:
 * a head repository plus SHA is not a unique PR identity (the same head can back PRs to two
 * base branches), so the PR must also be the ONE open PR with that head, and when GitHub
 * lists the run's PRs they must be exactly the claimed one.
 * run = {event, headSha, headRepo, headBranch, prNumbers}
 */
export async function resolveTarget({ api, repo, prNumber, run }) {
  if (run.event !== 'pull_request') return { ok: false, reason: 'event-not-pull-request' };
  if (run.prNumbers.length > 1) return { ok: false, reason: 'ambiguous-pr' };
  if (run.prNumbers.length === 1 && run.prNumbers[0] !== prNumber) return { ok: false, reason: 'pr-mismatch' };

  const pr = await api.request('GET', `/repos/${repo}/pulls/${prNumber}`);
  if (!pr || pr.state !== 'open') return { ok: false, reason: 'pr-not-open' };
  if (pr.head?.sha !== run.headSha) return { ok: false, reason: 'head-sha-mismatch' };
  if (pr.head?.repo?.full_name !== run.headRepo) return { ok: false, reason: 'head-repo-mismatch' };
  if (pr.head?.ref !== run.headBranch) return { ok: false, reason: 'head-ref-mismatch' };
  if (pr.base?.repo?.full_name !== repo) return { ok: false, reason: 'base-repo-mismatch' };

  // Complete enumeration of open PRs (not the `pulls?head=` filter): exactly one may share this head.
  const open = await listPages(api, `/repos/${repo}/pulls?state=open`);
  if (!open.complete) return { ok: false, reason: 'pr-enumeration-incomplete' };
  const sharing = open.items
    .filter((p) => p?.head?.sha === run.headSha && p?.head?.repo?.full_name === run.headRepo)
    .map((p) => p.number);
  if (sharing.length !== 1 || sharing[0] !== prNumber) return { ok: false, reason: 'ambiguous-pr' };
  return { ok: true, number: prNumber };
}

// ---------------------------------------------------------------- sticky comment

/** Bot-authored comments whose body starts with the marker, oldest first. */
export function listStickyComments(comments) {
  return comments
    .filter(
      (c) =>
        c?.user?.login === BOT_LOGIN &&
        c?.user?.type === 'Bot' &&
        typeof c.body === 'string' &&
        c.body.startsWith(MARKER),
    )
    .sort((a, b) => a.id - b.id);
}

/**
 * Exactly one sticky comment per PR. The PR's comments are enumerated completely: the oldest
 * sticky one is PATCHed and any further sticky comments are deleted (duplicate reconciliation);
 * a POST happens only when none exists AND the enumeration proved complete, so a long thread
 * can never make the bot add a second comment.
 */
export async function upsert({ api, repo, prNumber, body, log = () => {} }) {
  const { items, complete } = await listPages(api, `/repos/${repo}/issues/${prNumber}/comments`);
  const sticky = listStickyComments(items);
  if (sticky.length === 0) {
    if (!complete) return { action: 'skipped', reason: 'comments-enumeration-incomplete' };
    const created = await api.request('POST', `/repos/${repo}/issues/${prNumber}/comments`, { body });
    return { action: 'created', id: created?.id };
  }
  await api.request('PATCH', `/repos/${repo}/issues/comments/${sticky[0].id}`, { body });
  let removed = 0;
  let failed = 0;
  for (const dup of sticky.slice(1)) {
    try {
      await api.request('DELETE', `/repos/${repo}/issues/comments/${dup.id}`);
      removed++;
    } catch {
      failed++;
    }
  }
  if (removed > 0) log(`::warning::okf-check preview: removed ${removed} duplicate preview comments`);
  if (failed > 0) log(`::warning::okf-check preview: could not remove ${failed} duplicate preview comments`);
  return { action: 'updated', id: sticky[0].id, removed };
}

/** Trusted footer: built only from GitHub's run URL and the validated head sha, never artifact text. */
export function footer(runUrl, headSha) {
  if (typeof runUrl !== 'string' || !RUN_URL_RE.test(runUrl)) return '';
  return `\n\n<sub>okf-check run for ${headSha.slice(0, 12)}: [details](${runUrl})</sub>\n`;
}

// ---------------------------------------------------------------- artifact reading

function lstatOrSkip(fs, p) {
  try {
    return fs.lstatSync(p);
  } catch (e) {
    if (e && e.code === 'ENOENT') throw new Skip('artifact-missing');
    throw new Skip('artifact-not-regular');
  }
}

/** Read a regular, non-symlink file of at most `max` bytes; null when it is larger. */
function readRegular(fs, p, max) {
  const st = lstatOrSkip(fs, p);
  if (!st.isFile()) throw new Skip('artifact-not-regular');
  if (st.size > max) return null;
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0);
  let fd;
  try {
    fd = fs.openSync(p, flags);
  } catch {
    throw new Skip('artifact-not-regular');
  }
  try {
    const fst = fs.fstatSync(fd);
    if (!fst.isFile() || fst.size > max) {
      if (fst.isFile()) return null;
      throw new Skip('artifact-not-regular');
    }
    const buf = Buffer.alloc(fst.size);
    let off = 0;
    while (off < buf.length) {
      const n = fs.readSync(fd, buf, off, buf.length - off, off);
      if (n === 0) break;
      off += n;
    }
    return buf.subarray(0, off);
  } finally {
    fs.closeSync(fd);
  }
}

/** The artifact directory and both files must be real (non-symlink) filesystem objects. */
export function readArtifact(dir, fs = nodeFs) {
  if (typeof dir !== 'string' || dir === '') throw new Skip('artifact-missing');
  const st = lstatOrSkip(fs, dir);
  if (!st.isDirectory()) throw new Skip('artifact-not-regular');
  const prBytes = readRegular(fs, `${dir}/pr.json`, PR_JSON_MAX_BYTES);
  if (prBytes === null) throw new Skip('pr-json-invalid');
  const pr = parsePrJson(prBytes.toString('utf8'));
  const comment = readRegular(fs, `${dir}/comment.md`, COMMENT_MAX_BYTES);
  return { pr, comment };
}

// ---------------------------------------------------------------- main

function reasonOf(e) {
  if (e instanceof Skip) return e.reason;
  if (e instanceof ApiError) return `api-error-${e.status}`;
  return 'internal-error';
}

async function post({ env, fetchImpl, fs, log }) {
  const repo = env.GITHUB_REPOSITORY;
  if (typeof repo !== 'string' || !REPO_RE.test(repo)) throw new Skip('env-invalid');
  const token = env.GITHUB_TOKEN;
  if (typeof token !== 'string' || token === '') throw new Skip('env-invalid');
  const runHeadSha = env.OKF_RUN_HEAD_SHA;
  const headRepo = env.OKF_RUN_HEAD_REPO;
  const headBranch = env.OKF_RUN_HEAD_BRANCH;
  if (typeof runHeadSha !== 'string' || !SHA_RE.test(runHeadSha)) throw new Skip('env-invalid');
  if (typeof headRepo !== 'string' || !REPO_RE.test(headRepo)) throw new Skip('env-invalid');
  if (typeof headBranch !== 'string' || headBranch === '') throw new Skip('env-invalid');

  const { pr, comment } = readArtifact(env.OKF_ARTIFACT_DIR, fs);
  if (pr.headSha !== runHeadSha) throw new Skip('artifact-sha-mismatch');
  const prNumbers = parseRunPrNumbers(env.OKF_RUN_PR_NUMBERS ?? '[]');

  const api = makeApi({ fetchImpl, baseUrl: env.GITHUB_API_URL || 'https://api.github.com', token });
  const target = await resolveTarget({
    api,
    repo,
    prNumber: pr.number,
    run: { event: env.OKF_RUN_EVENT, headSha: runHeadSha, headRepo, headBranch, prNumbers },
  });
  if (!target.ok) throw new Skip(target.reason);

  // D-07: the engine already sanitised comment.md, but a fork's artifact is not the engine's.
  const verdict = comment === null ? { ok: false, reason: 'too-large' } : validateComment(comment);
  const text = verdict.ok ? comment.toString('utf8') : fallbackBody(verdict.reason, pr.headSha);
  const body = text + footer(env.OKF_RUN_URL, pr.headSha);

  const result = await upsert({ api, repo, prNumber: target.number, body, log });
  if (result.action === 'skipped') throw new Skip(result.reason);
  log(`okf-check preview comment ${result.action}`);
}

export async function main({ env = process.env, fetchImpl = globalThis.fetch, fs = nodeFs, log = console.log } = {}) {
  try {
    await post({ env, fetchImpl, fs, log });
  } catch (e) {
    log(`::warning::okf-check preview comment not posted: ${reasonOf(e)}`);
  }
  return 0;
}

// ---------------------------------------------------------------- CLI

/**
 * `--validate <dir>`: the same lstat checks and the same allow-list, no network. Plan 10 runs
 * it over real engine output. Returns {ok: true} or {ok: false, reason}.
 */
export function validateArtifactDir(dir, fs = nodeFs) {
  try {
    const { comment } = readArtifact(dir, fs);
    if (comment === null) return { ok: false, reason: 'too-large' };
    return validateComment(comment);
  } catch (e) {
    return { ok: false, reason: reasonOf(e) };
  }
}

function isEntryScript() {
  if (!process.argv[1]) return false;
  try {
    return import.meta.url === pathToFileURL(nodeFs.realpathSync(process.argv[1])).href;
  } catch {
    return false;
  }
}

if (isEntryScript()) {
  const args = process.argv.slice(2);
  if (args[0] === '--validate') {
    const verdict = args.length === 2 ? validateArtifactDir(args[1]) : { ok: false, reason: 'usage' };
    console.log(verdict.ok ? 'valid' : `invalid: ${verdict.reason}`);
    process.exitCode = verdict.ok ? 0 : 1;
  } else {
    await main();
    process.exitCode = 0;
  }
}
