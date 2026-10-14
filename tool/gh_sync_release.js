// gh_sync_release.js —— 把发布树同步到 GitHub（本机 git-over-HTTPS 不通，只能走 REST API）
//
// 用法：node tool/gh_sync_release.js <发布树目录> <提交信息> [tag]
//   tag 可选：给了就顺带把 tag 指到新提交（Release 用）
//
// 凭据：C:\Users\user\.dsh\dsh_wechat\logs\gh-token.txt（仅本机，不进仓库）
//
// ## ⚠️ 本机特有的坑：GitHub 流量被本地加速工具劫持，Node 默认不信任它的证书
//
// 本机跑着 `steamcommunity_302.cli`（GitHub 加速），它监听本机 443 并用**自签 CA**
// 签发 GitHub 的证书。PowerShell 走 Windows 证书库所以能通，**Node 的 fetch 会失败**：
//   `TypeError: fetch failed` → cause `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`
//
// 正确做法是**把那个根 CA 喂给 Node**（`NODE_EXTRA_CA_CERTS`），**不是**关掉证书校验。
// 本脚本会**自动**做这件事：若 `build/local-ca.pem` 存在且环境变量还没设，
// 就带上看环境变量**重新执行自己**（TLS 的信任锚只能在进程启动时确定，运行期改不了）。
// CA 的导出见 `tool/export_local_ca.ps1`。
//
// 做法（Git Data API）：
//   1) 取 main 当前 commit → 它的 tree（拿每个文件的 blob sha，作为"没变就不重传"的依据）
//   2) 逐文件比对内容 sha：一样 → 复用原 blob；不一样 → POST /git/blobs 传新的
//   3) 一次性 POST /git/trees（带 base_tree，删掉已不在发布树里的文件）
//   4) POST /git/commits → PATCH /git/refs/heads/main
//
// 输出：新 commit sha 与增删改统计，并写进 logs/gh-commit-<tag>.txt 便于追溯。

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

// ---- 证书信任锚：本机加速工具的 CA（见文件头说明）----
const LOCAL_CA = path.join(__dirname, '..', 'build', 'local-ca.pem');
if (!process.env.NODE_EXTRA_CA_CERTS && fs.existsSync(LOCAL_CA)) {
  const r = spawnSync(
    process.execPath,
    [__filename, ...process.argv.slice(2)],
    { stdio: 'inherit', env: { ...process.env, NODE_EXTRA_CA_CERTS: LOCAL_CA } }
  );
  process.exit(r.status === null ? 1 : r.status);
}

const OWNER = 'lzhtt23';
const REPO = 'tts_reader';
const BRANCH = 'main';
const TOKEN_PATH = 'C:\\Users\\user\\.dsh\\dsh_wechat\\logs\\gh-token.txt';
const API = 'https://api.github.com';

const publishDir = process.argv[2];
const message = process.argv[3] || 'chore: sync source';
const tag = process.argv[4] || '';

if (!publishDir || !fs.existsSync(publishDir)) {
  console.error('用法: node gh_sync_release.js <发布树目录> "<提交信息>" [tag]');
  process.exit(2);
}

const token = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
const headers = {
  Authorization: `token ${token}`,
  'User-Agent': 'dsh-agent',
  Accept: 'application/vnd.github+json',
  'Content-Type': 'application/json',
};

async function api(pathname, options = {}, attempt = 0) {
  const res = await fetch(API + pathname, { headers, ...options });
  if (res.status === 403 || res.status === 429 || res.status >= 500) {
    if (attempt < 4) {
      const wait = 1500 * Math.pow(2, attempt);
      console.log(`  · ${res.status} ${pathname} → ${wait}ms 后重试`);
      await new Promise((r) => setTimeout(r, wait));
      return api(pathname, options, attempt + 1);
    }
  }
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`${res.status} ${pathname}: ${text.slice(0, 400)}`);
  }
  return res.status === 204 ? null : res.json();
}

/** 递归列出发布树里所有文件（相对路径，POSIX 分隔） */
function listFiles(root) {
  const out = [];
  // 与发布树 .gitignore 对齐的排除项（发布树是白名单复制出来的，
  // 这里再挡一道：机器相关 / 可再生的文件不该进公开仓库）
  const skip = [
    /(^|\/)\.gradle\//,
    /(^|\/)build\//,
    /(^|\/)local\.properties$/,
    /(^|\/)key\.properties$/,
    /gradle-wrapper\.jar$/,
    /\.jks$/,
    /\.keystore$/,
  ];
  const ignored = (rel) => skip.some((re) => re.test(rel));
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir)) {
      if (name === '.git') continue;
      const full = path.join(dir, name);
      const rel = path.relative(root, full).split(path.sep).join('/');
      if (ignored(rel + (fs.statSync(full).isDirectory() ? '/' : ''))) continue;
      const st = fs.statSync(full);
      if (st.isDirectory()) walk(full);
      else if (st.isFile()) out.push(rel);
    }
  };
  walk(root);
  return out.sort();
}

/** git 的 blob sha = sha1("blob <len>\0" + content) */
function gitBlobSha(buf) {
  const head = Buffer.from(`blob ${buf.length}\0`, 'utf8');
  return crypto.createHash('sha1').update(Buffer.concat([head, buf])).digest('hex');
}

(async () => {
  console.log(`仓库: ${OWNER}/${REPO}  分支: ${BRANCH}`);
  console.log(`发布树: ${publishDir}`);

  const ref = await api(`/repos/${OWNER}/${REPO}/git/ref/heads/${BRANCH}`);
  const baseCommitSha = ref.object.sha;
  const baseCommit = await api(`/repos/${OWNER}/${REPO}/git/commits/${baseCommitSha}`);
  const baseTreeSha = baseCommit.tree.sha;
  console.log(`基线 commit: ${baseCommitSha.slice(0, 8)}  tree: ${baseTreeSha.slice(0, 8)}`);

  // 基线 tree 的扁平化：相对路径 → blob sha
  const baseTree = await api(`/repos/${OWNER}/${REPO}/git/trees/${baseTreeSha}?recursive=1`);
  const remote = new Map();
  for (const e of baseTree.tree) {
    if (e.type === 'blob') remote.set(e.path, e.sha);
  }
  console.log(`远端文件数: ${remote.size}`);

  const files = listFiles(publishDir);
  console.log(`发布树文件数: ${files.length}`);

  const entries = [];
  const added = [];
  const changed = [];
  let uploaded = 0;
  const queue = [];

  for (const rel of files) {
    const buf = fs.readFileSync(path.join(publishDir, rel));
    const sha = gitBlobSha(buf);
    if (remote.get(rel) === sha) {
      entries.push({ path: rel, mode: '100644', type: 'blob', sha });
      continue;
    }
    if (remote.has(rel)) changed.push(rel);
    else added.push(rel);
    queue.push({ rel, buf, sha });
  }

  const removed = [...remote.keys()].filter((p) => !files.includes(p));

  // 并发上传新 blob（限流友好）
  const CONCURRENCY = 8;
  for (let i = 0; i < queue.length; i += CONCURRENCY) {
    const slice = queue.slice(i, i + CONCURRENCY);
    const results = await Promise.all(
      slice.map(async ({ rel, buf }) => {
        const res = await api(`/repos/${OWNER}/${REPO}/git/blobs`, {
          method: 'POST',
          body: JSON.stringify({ content: buf.toString('base64'), encoding: 'base64' }),
        });
        return { rel, sha: res.sha };
      })
    );
    for (const r of results) {
      entries.push({ path: r.rel, mode: '100644', type: 'blob', sha: r.sha });
      uploaded += 1;
    }
    process.stdout.write(`\r  已上传 ${uploaded}/${queue.length} 个 blob`);
  }
  if (queue.length) process.stdout.write('\n');

  console.log(`新增 ${added.length} / 修改 ${changed.length} / 删除 ${removed.length} / 未变 ${entries.length - added.length - changed.length}`);
  if (added.length) console.log('  新增: ' + added.slice(0, 12).join(', ') + (added.length > 12 ? ' …' : ''));
  if (changed.length) console.log('  修改: ' + changed.slice(0, 12).join(', ') + (changed.length > 12 ? ' …' : ''));
  if (removed.length) console.log('  删除: ' + removed.slice(0, 12).join(', ') + (removed.length > 12 ? ' …' : ''));

  const tree = await api(`/repos/${OWNER}/${REPO}/git/trees`, {
    method: 'POST',
    body: JSON.stringify({ base_tree: baseTreeSha, tree: entries }),
  });
  console.log(`新 tree: ${tree.sha.slice(0, 8)}`);

  const commit = await api(`/repos/${OWNER}/${REPO}/git/commits`, {
    method: 'POST',
    body: JSON.stringify({ message, tree: tree.sha, parents: [baseCommitSha] }),
  });
  console.log(`新 commit: ${commit.sha}`);

  await api(`/repos/${OWNER}/${REPO}/git/refs/heads/${BRANCH}`, {
    method: 'PATCH',
    body: JSON.stringify({ sha: commit.sha, force: false }),
  });
  console.log(`已更新 ${BRANCH} → ${commit.sha.slice(0, 8)}`);

  if (tag) {
    try {
      await api(`/repos/${OWNER}/${REPO}/git/refs`, {
        method: 'POST',
        body: JSON.stringify({ ref: `refs/tags/${tag}`, sha: commit.sha }),
      });
      console.log(`已建 tag: ${tag}`);
    } catch (e) {
      console.log(`tag 失败（可能已存在）: ${String(e.message).slice(0, 160)}`);
    }
    fs.writeFileSync(
      path.join('C:\\Users\\user\\.dsh\\dsh_wechat\\logs', `gh-commit-${tag}.txt`),
      commit.sha + '\n'
    );
  }

  console.log(JSON.stringify({ commit: commit.sha, tree: tree.sha, added: added.length, changed: changed.length, removed: removed.length }));
})().catch((e) => {
  console.error('失败: ' + e.message);
  process.exit(1);
});
