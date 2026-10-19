// gh_release_asset.js —— 把 APK 传到 GitHub Release 的附件里
//
// 为什么不用 git tree：APK 47MB，塞进仓库会让每次 clone 都拉它，
// 而且 GitHub 对单文件 >100MB 直接拒收。Release 附件才是放二进制的正路。
//
// 用法：node tool/gh_release_asset.js <tag> <文件路径> [显示名]
//
// 凭据：C:\Users\user\.dsh\dsh_wechat\logs\gh-token.txt（仅本机，不进仓库）
//
// ⚠️ 本机踩过的坑（与 gh_sync_release.js 相同）：GitHub 流量被本地加速工具劫持，
// 它用自签 CA 签证书，Node 的 fetch 会报 UNABLE_TO_GET_ISSUER_CERT_LOCALLY。
// 正确做法是把根 CA 喂给 Node（NODE_EXTRA_CA_CERTS），而不是关掉校验。
// 本脚本会自动这么做（若 build/local-ca.pem 存在且环境变量还没设）。
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
const UPLOAD = 'https://uploads.github.com';

const tag = process.argv[2];
const filePath = process.argv[3];
// 显示名优先取环境变量：PowerShell 把**非 ASCII 参数**传给 node 时会被控制台代码页
// 弄坏（实测「桃花源阅读器-1.22.0.apk」传进来变成「-1.22.0.apk」）。
// 环境变量走 UTF-16 → UTF-8 转换，中文能完整保留。
const displayName =
  process.env.ASSET_NAME ||
  process.argv[4] ||
  (filePath ? path.basename(filePath) : '');

if (!tag || !filePath || !fs.existsSync(filePath)) {
  console.error('用法: node gh_release_asset.js <tag> <文件路径> [显示名]');
  process.exit(2);
}

const token = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
const headers = {
  Authorization: `token ${token}`,
  'User-Agent': 'dsh-agent',
  Accept: 'application/vnd.github+json',
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
  if (!res.ok) {
    throw new Error(`${options.method || 'GET'} ${url} → ${res.status} ${text.slice(0, 400)}`);
  }
  return text ? JSON.parse(text) : null;
}

async function main() {
  // 1) 找 tag 对应的 release，没有就建一个
  let release = null;
  try {
    release = await api(`${API}/repos/${OWNER}/${REPO}/releases/tags/${tag}`);
    console.log(`已有 release: ${release.id}`);
  } catch (e) {
    if (!String(e.message).includes('404')) throw e;
  }

  if (!release) {
    const body = [
      `桃花源阅读器 ${tag}`,
      '',
      '大版本更新：发现页搜书 + 订阅源（RSS）+ 本地/在线双书架 + 一键导入深链。',
      '详细改动见 CHANGELOG.md。',
      '',
      '安装包见下方附件（arm64 / universal）。',
    ].join('\n');
    release = await api(`${API}/repos/${OWNER}/${REPO}/releases`, {
      method: 'POST',
      headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tag_name: tag,
        name: `桃花源阅读器 ${tag}`,
        body,
        draft: false,
        prerelease: false,
      }),
    });
    console.log(`新建 release: ${release.id}`);
  }

  // 2) 同名附件先删掉（重复上传会 422）
  const assets = release.assets || [];
  for (const a of assets) {
    if (a.name === displayName) {
      await api(`${API}/repos/${OWNER}/${REPO}/releases/assets/${a.id}`, {
        method: 'DELETE',
      });
      console.log(`删除同名旧附件: ${a.name}`);
    }
  }

  // 3) 上传
  const buf = fs.readFileSync(filePath);
  console.log(`上传 ${displayName}（${(buf.length / 1024 / 1024).toFixed(1)} MB）…`);
  const uploaded = await api(
    `${UPLOAD}/repos/${OWNER}/${REPO}/releases/${release.id}/assets?name=${encodeURIComponent(displayName)}`,
    {
      method: 'POST',
      headers: {
        ...headers,
        'Content-Type': 'application/vnd.android.package-archive',
        'Content-Length': String(buf.length),
      },
      body: buf,
      duplex: 'half',
    },
  );
  console.log(`完成：${uploaded.name} ${(uploaded.size / 1024 / 1024).toFixed(1)} MB`);
  console.log(`下载地址：${uploaded.browser_download_url}`);
  console.log(JSON.stringify({
    release: release.id,
    tag,
    asset: uploaded.name,
    size: uploaded.size,
    url: uploaded.browser_download_url,
  }));
}

main().catch((e) => {
  console.error('失败：', e.message);
  process.exit(1);
});
