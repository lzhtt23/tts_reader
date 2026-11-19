// gh_commit_files.js —— 用 GitHub REST API 把**指定文件**提交到远端，只增改、不删除
//
// 用法：
//   node tool/gh_commit_files.js --message "提交说明" <文件1> <文件2> ...
//   node tool/gh_commit_files.js --message "..." --from-git <基准commit>
//
// ## 为什么要这个脚本（和 gh_sync_release.js 的区别）
//
// 本机 `github.com:443` **不可达**（git push 走不通），只有 `api.github.com`
// 能连。所以推送只能走 REST（Git Data API）。
//
// 仓库里已有的 `gh_sync_release.js` 是「把整个发布树同步上去」：
// 它用 `base_tree` + **删除树里不存在的文件**，适合发版快照。
// 但它有个致命副作用（HANDOFF §11.8 记着）：白名单漏了哪个 git 已跟踪的文件，
// 那个文件就会被**从远端删掉**（`assets/` 就这么丢过一次）。
//
// 日常提交只需要「改几个文件」，不该动别人的文件。本脚本就只做这件事：
//   · base_tree = 远端当前树
//   · 只添加/覆盖命令行点名的文件
//   · **不产生任何删除**（不列出 = 保持原样）
//
// ## 其余实现要点
//   · blob sha 本地算（sha1("blob <len>\0" + bytes)），与远端树比对，
//     内容没变就不重传（省流量、也避免无意义的树变更）
//   · 二进制安全：上传走 base64
//   · 路径用 Git 仓库内相对路径；带空格/中文都能处理
//   · 成功后打印新 commit sha，并可核对远端文件内容
//
// 凭据：C:\Users\user\.dsh\dsh_wechat\logs\gh-token.txt（仅本机，不进仓库）

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ⚠️ 本机特有的坑：GitHub 流量被本地加速工具劫持，Node 默认不信任它的证书
//
// `steamcommunity_302.cli` 监听本机 443 并用自签 CA 签发 GitHub 证书。
// PowerShell / curl 走 Windows 证书库所以能通，**Node 的 fetch 会失败**：
//   `fetch failed` → cause `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`
//
// 正确做法是把那个根 CA 喂给 Node（NODE_EXTRA_CA_CERTS），**不是**关掉校验。
// TLS 信任锚只能在进程启动时确定，所以这里带上看环境变量**重新执行自己**。
(() => {
  const repoRoot = path.resolve(__dirname, '..');
  const ca = path.join(repoRoot, 'build', 'local-ca.pem');
  if (!process.env.NODE_EXTRA_CA_CERTS && fs.existsSync(ca)) {
    const { spawnSync } = require('child_process');
    const r = spawnSync(process.execPath, [__filename, ...process.argv.slice(2)], {
      stdio: 'inherit',
      env: { ...process.env, NODE_EXTRA_CA_CERTS: ca },
    });
    process.exit(r.status === null ? 1 : r.status);
  }
})();

const OWNER = 'lzhtt23';
const REPO = 'tts_reader';
const BRANCH = 'main';
const TOKEN_PATH = 'C:\\Users\\user\\.dsh\\dsh_wechat\\logs\\gh-token.txt';

const args = process.argv.slice(2);
function takeOpt(name) {
  const i = args.indexOf(name);
  if (i < 0) return null;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
}

const message = takeOpt('--message');
const fromGit = takeOpt('--from-git');
if (!message) {
  console.error('缺少 --message "提交说明"');
  process.exit(2);
}

let files = args.slice();
if (fromGit) {
  // 用 git 算出相对某个基准的改动文件（含新增/修改，不含删除）
  const { execFileSync } = require('child_process');
  const git = fs.existsSync('C:\\ttsbuild\\git\\cmd\\git.exe')
    ? 'C:\\ttsbuild\\git\\cmd\\git.exe'
    : 'git';
  const out = execFileSync(git, ['diff', '--name-only', '-z', '--diff-filter=ACMR', fromGit, 'HEAD'], {
    cwd: path.resolve(__dirname, '..'),
    encoding: 'utf8',
  });
  // ⚠️ 必须用 -z：不加的话 git 会把中文/空格路径转义成 "\346\234\254..."（八进制），
  // 后面 path.join 就找不到文件，被当成"本地缺失"跳过。
  files = out.split('\0').map((s) => s.trim()).filter(Boolean);
}

if (files.length === 0) {
  console.error('没有任何文件要提交');
  process.exit(2);
}

const token = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
const repoRoot = path.resolve(__dirname, '..');

const API = `https://api.github.com/repos/${OWNER}/${REPO}`;
const headers = {
  Authorization: `token ${token}`,
  Accept: 'application/vnd.github+json',
  'User-Agent': 'tts-reader-commit',
  'Content-Type': 'application/json',
};

async function api(method, url, body) {
  const res = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`${method} ${url} -> ${res.status}\n${text.slice(0, 800)}`);
  }
  return text ? JSON.parse(text) : null;
}

/** 本地算 git blob sha，用于"内容没变就不重传" */
function blobSha(buf) {
  const h = crypto.createHash('sha1');
  h.update(`blob ${buf.length}\0`);
  h.update(buf);
  return h.digest('hex');
}

(async () => {
  // 1) 远端当前 head
  const ref = await api('GET', `${API}/git/ref/heads/${BRANCH}`);
  const headSha = ref.object.sha;
  console.log(`远端 ${BRANCH} = ${headSha}`);

  // 2) 当前 commit → tree
  const headCommit = await api('GET', `${API}/git/commits/${headSha}`);
  const baseTreeSha = headCommit.tree.sha;
  console.log(`base tree = ${baseTreeSha}`);

  // 3) 现有树（recursive）→ path → sha
  const baseTree = await api('GET', `${API}/git/trees/${baseTreeSha}?recursive=1`);
  if (baseTree.truncated) {
    console.warn('⚠️ 远端树列表被截断（文件过多），比对可能不完整；仍然继续');
  }
  const existing = new Map();
  for (const e of baseTree.tree) {
    if (e.type === 'blob') existing.set(e.path, e.sha);
  }

  // 4) 逐个文件：内容变了才上传 blob
  const entries = [];
  let added = 0;
  let changed = 0;
  let skipped = 0;
  let removedLocal = 0;

  for (const rel of files) {
    const abs = path.join(repoRoot, rel);
    if (!fs.existsSync(abs)) {
      // 本地文件不存在（可能是删除）——本脚本不处理删除，明确跳过并告警
      console.warn(`跳过（本地不存在，本脚本不删除远端文件）：${rel}`);
      removedLocal++;
      continue;
    }
    const buf = fs.readFileSync(abs);
    const sha = blobSha(buf);
    const old = existing.get(rel);
    if (old === sha) {
      skipped++;
      continue;
    }
    // 上传
    const blob = await api('POST', `${API}/git/blobs`, {
      content: buf.toString('base64'),
      encoding: 'base64',
    });
    entries.push({ path: rel, mode: '100644', type: 'blob', sha: blob.sha });
    if (old === undefined) added++;
    else changed++;
    console.log(`  ${old === undefined ? '新增' : '更新'} ${rel} (${buf.length} bytes)`);
  }

  if (entries.length === 0) {
    console.log(`没有内容变化（${skipped} 个文件与远端一致）`);
    return;
  }

  // 5) 新树：base_tree + 只列改动项 → 其余文件原样保留（**不会删除**）
  const newTree = await api('POST', `${API}/git/trees`, {
    base_tree: baseTreeSha,
    tree: entries,
  });

  // 6) 新 commit
  const newCommit = await api('POST', `${API}/git/commits`, {
    message,
    tree: newTree.sha,
    parents: [headSha],
  });

  // 7) 移动分支
  await api('PATCH', `${API}/git/refs/heads/${BRANCH}`, { sha: newCommit.sha });

  console.log('');
  console.log(`已提交：${newCommit.sha}`);
  console.log(`统计：新增 ${added} / 更新 ${changed} / 未变 ${skipped}` +
    (removedLocal ? ` / 本地缺失跳过 ${removedLocal}` : ''));
  console.log(`对比：${headSha.slice(0, 7)}..${newCommit.sha.slice(0, 7)}`);
})().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
