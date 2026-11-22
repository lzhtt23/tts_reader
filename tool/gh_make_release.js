// gh_make_release.js —— 按 tag 建一个 GitHub Release（已存在则复用）
//
// 用法：node tool/gh_make_release.js <tag> [说明文件路径]
//
// 为什么要单独一个脚本：`gh_release_asset.js` 只负责**上传附件**，
// 它要求 release 已经存在（内部 GET /releases/tags/<tag>）。
//
// 本机坑同 gh_commit_files.js：GitHub 流量被本地加速工具劫持，Node 不认它的自签 CA。
// 脚本会自动带上 build/local-ca.pem（走 NODE_EXTRA_CA_CERTS 重新执行自己）。
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const LOCAL_CA = path.join(__dirname, '..', 'build', 'local-ca.pem');
if (!process.env.NODE_EXTRA_CA_CERTS && fs.existsSync(LOCAL_CA)) {
  const r = spawnSync(process.execPath, [__filename, ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: { ...process.env, NODE_EXTRA_CA_CERTS: LOCAL_CA },
  });
  process.exit(r.status === null ? 1 : r.status);
}

const OWNER = 'lzhtt23';
const REPO = 'tts_reader';
const TOKEN_PATH = 'C:\\Users\\user\\.dsh\\dsh_wechat\\logs\\gh-token.txt';
const API = 'https://api.github.com';

const tag = process.argv[2];
const bodyPath = process.argv[3] || '';
if (!tag) {
  console.error('用法: node tool/gh_make_release.js <tag> [说明文件路径]');
  process.exit(2);
}

const token = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
const headers = {
  Authorization: `token ${token}`,
  'User-Agent': 'dsh-agent',
  Accept: 'application/vnd.github+json',
  'Content-Type': 'application/json',
};

async function api(url, options = {}, attempt = 0) {
  const res = await fetch(url, { headers, ...options });
  const text = await res.text();
  if ((res.status === 403 || res.status === 429 || res.status >= 500) && attempt < 4) {
    const wait = 1500 * (attempt + 1);
    console.error(`  ${res.status} → ${wait}ms 后重试`);
    await new Promise((r) => setTimeout(r, wait));
    return api(url, options, attempt + 1);
  }
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  if (!res.ok) {
    const err = new Error(`${res.status} ${url} ${text.slice(0, 240)}`);
    err.status = res.status;
    throw err;
  }
  return json;
}

(async () => {
  // 1) 已存在就直接用
  try {
    const existing = await api(`${API}/repos/${OWNER}/${REPO}/releases/tags/${tag}`);
    console.log(`Release 已存在: ${existing.tag_name} (id=${existing.id})`);
    console.log(existing.html_url);
    return;
  } catch (e) {
    if (e.status !== 404) throw e;
  }

  // 2) 远端 main 的 sha 作为 target（tag 由 GitHub 自动建）
  const ref = await api(`${API}/repos/${OWNER}/${REPO}/git/ref/heads/main`);
  const sha = ref.object.sha;
  console.log(`远端 main = ${sha}`);

  const body = bodyPath && fs.existsSync(bodyPath)
    ? fs.readFileSync(bodyPath, 'utf8')
    : `v${tag} 自动发布`;

  const release = await api(`${API}/repos/${OWNER}/${REPO}/releases`, {
    method: 'POST',
    body: JSON.stringify({
      tag_name: tag,
      target_commitish: sha,
      name: tag,
      body,
      draft: false,
      prerelease: false,
    }),
  });
  console.log(`已建 Release: ${release.tag_name} (id=${release.id})`);
  console.log(release.html_url);
})().catch((e) => {
  console.error('失败:', e.message);
  process.exit(1);
});
