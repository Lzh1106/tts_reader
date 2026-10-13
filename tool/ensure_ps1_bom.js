// 给「UTF-8 但缺 BOM」的 PowerShell 脚本补 BOM。
// 为什么需要：Windows PowerShell 5.1 读无 BOM 的文件会按 ANSI(GBK) 解码，
// UTF-8 的中文注释会变乱码、字符串引号被判成未终止 → 直接语法错误。
// 安全策略：只处理「能按 UTF-8 解出中文、且当前按 GBK 解码会乱」的文件；
// 纯 ASCII 文件不动（加不加 BOM 都不影响）。
const fs = require('fs');

const files = process.argv.slice(2);
let changed = 0;
for (const p of files) {
  let b;
  try { b = fs.readFileSync(p); } catch (e) { console.log('跳过(读不到) ' + p); continue; }
  const hasBom = b[0] === 0xEF && b[1] === 0xBB && b[2] === 0xBF;
  const utf8 = b.toString('utf8');
  const utf8Ok = !utf8.includes('\uFFFD');            // UTF-8 解码无替换字符
  const hasCjk = /[\u4e00-\u9fff]/.test(utf8);        // 含中文
  const ascii = b.every((x) => x < 0x80);
  if (hasBom) { console.log('已有 BOM  ' + p); continue; }
  if (ascii) { console.log('纯 ASCII  ' + p + '（不动）'); continue; }
  if (!utf8Ok || !hasCjk) { console.log('非 UTF-8 中文，跳过  ' + p); continue; }
  fs.writeFileSync(p, Buffer.concat([Buffer.from([0xEF, 0xBB, 0xBF]), b]));
  console.log('已补 BOM  ' + p);
  changed++;
}
console.log('处理完成，改动 ' + changed + ' 个文件');
