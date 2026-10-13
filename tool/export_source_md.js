// 把工程源码导成一份 Markdown（v1.21.14）
// 用法: node export_source_md.js <项目根> <输出 md 路径>
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
const outPath = process.argv[3];
if (!root || !outPath) { console.error('need <root> <out>'); process.exit(1); }

const SKIP_DIRS = new Set(['build', '.dart_tool', '.gradle', '.idea', '.vscode',
  'snapshots', 'release', 'dist', 'test_assets', 'docs', '.git', 'images', 'res_raw']);
const TEXT_EXT = new Set(['.dart', '.ps1', '.py', '.yaml', '.yml', '.gradle', '.xml',
  '.gitignore', '.json', '.properties', '.kts', '.pro', '.txt', '.md']);

// 明确纳入的目录（相对 root）与根文件
const INCLUDE_DIRS = ['lib', 'test', 'integration_test', 'tool'];
const INCLUDE_ROOT_FILES = ['pubspec.yaml', 'analysis_options.yaml', '.gitignore'];
const INCLUDE_ANDROID = [
  'android/build.gradle', 'android/settings.gradle', 'android/gradle.properties',
  'android/app/build.gradle', 'android/app/src/main/AndroidManifest.xml',
  'android/app/src/main/kotlin', 'android/app/src/main/java',
];

// 内部文档不进（与发布包同规矩）
const SKIP_FILES = new Set(['HANDOFF.md']);

function walk(abs, rel, acc) {
  let st;
  try { st = fs.statSync(abs); } catch (e) { return; }
  if (st.isDirectory()) {
    if (SKIP_DIRS.has(path.basename(abs))) return;
    for (const name of fs.readdirSync(abs).sort()) {
      walk(path.join(abs, name), rel ? rel + '/' + name : name, acc);
    }
    return;
  }
  const ext = path.extname(abs).toLowerCase();
  const base = path.basename(abs);
  if (SKIP_FILES.has(base)) return;
  if (base.startsWith('.')) {
    if (base !== '.gitignore') return;
  }
  if (!TEXT_EXT.has(ext) && base !== '.gitignore') return;
  acc.push(rel);
}

const files = [];
for (const d of INCLUDE_DIRS) {
  const abs = path.join(root, d);
  if (fs.existsSync(abs)) walk(abs, d, files);
}
for (const f of INCLUDE_ROOT_FILES) {
  if (fs.existsSync(path.join(root, f))) files.push(f);
}
for (const f of INCLUDE_ANDROID) {
  const abs = path.join(root, f);
  if (fs.existsSync(abs)) walk(abs, f, files);
}
files.sort((a, b) => a.localeCompare(b));

const fence = '````';
let totalLines = 0;
const parts = [];
for (const rel of files) {
  const abs = path.join(root, rel);
  let text = fs.readFileSync(abs, 'utf8').replace(/\r\n/g, '\n');
  if (!text.endsWith('\n')) text += '\n';
  const lines = text.split('\n').length - 1;
  totalLines += lines;
  const ext = path.extname(rel).toLowerCase();
  const lang = ext === '.dart' ? 'dart' : ext === '.ps1' ? 'powershell' : ext === '.py' ? 'python'
    : (ext === '.yaml' || ext === '.yml') ? 'yaml' : ext === '.gradle' ? 'groovy'
    : ext === '.xml' ? 'xml' : ext === '.json' ? 'json' : ext === '.kts' ? 'kotlin' : 'text';
  parts.push('### `' + rel + '`\n\n' + fence + lang + '\n' + text + fence + '\n');
}

const pubspec = fs.readFileSync(path.join(root, 'pubspec.yaml'), 'utf8');
const version = (pubspec.match(/^version:\s*(.+)$/m) || [])[1] || '?';

const header = [
  '# 桃花源阅读器 源码（v' + version.trim() + '）',
  '',
  '- 导出时间：' + (() => { const d = new Date(); const p = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' '
      + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) + '（本地时间）'; })(),
  '- 文件数：**' + files.length + '**，代码行数：**' + totalLines + '**',
  '- 范围：`lib/`（产品代码）、`test/` 与 `integration_test/`（测试）、`tool/`（脚本）、',
  '  根配置（pubspec / analysis_options / .gitignore）、`android/` 的 Gradle 与清单',
  '- **不含**：`HANDOFF.md`、`docs/*.md`（内部文档）、`build/`、`snapshots/`、keystore、二进制资源',
  '',
  '## 目录',
  '',
  ...files.map((f, i) => (i + 1) + '. `' + f + '`'),
  '',
  '---',
  '',
  '## 源码',
  '',
].join('\n');

fs.writeFileSync(outPath, header + parts.join('\n'), 'utf8');
console.log('files=' + files.length + ' lines=' + totalLines + ' bytes=' + fs.statSync(outPath).size);
