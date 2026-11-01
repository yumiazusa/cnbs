#!/bin/bash
# mcp-cnbs 1.3.2 补丁：修复 cnbs_fetch_series 全部 404 的问题
# 原因：国家统计局新版 API 把取数接口从 /getEsDataByCidAndDt 改为 /stream/esData，
#       并把 das 数组里的 code 字段改名为 value，新增 daCatalogId。
#       上游包未跟进（npm 最新版仍是 1.3.2），故本地打补丁。
# 影响：仅改 node_modules 里 dist/index.js 的两处，不动配置、不动数据。
# 回滚：把同目录下的 index.js.bak-<时间戳> 改名回 index.js 后 restart 即可。

set -e

TARGET=/home/www/workbuddy/apps/mcp-cnbs/node_modules/mcp-cnbs/dist/index.js

if [ ! -f "$TARGET" ]; then
  echo "!! 找不到 $TARGET，请确认服务安装路径"
  exit 1
fi

cat > /tmp/patch_cnbs.py <<'PY'
import sys, shutil, datetime

path = sys.argv[1]
s = open(path, encoding="utf-8").read()
orig = s

c1 = s.count("/getEsDataByCidAndDt")
s = s.replace("/getEsDataByCidAndDt", "/stream/esData")

old_body = 'das:e.areas||[{text:"\\u5168\\u56FD",code:"000000000000"}],dts:e.periods'
new_body = ('daCatalogId:"",das:(e.areas&&e.areas.length?e.areas:[{text:"\\u5168\\u56FD",code:"000000000000"}])'
            '.map(function(a){return{text:a.text||"\\u5168\\u56FD",value:a.value||a.code||"000000000000"}}),dts:e.periods')
c2 = s.count(old_body)
s = s.replace(old_body, new_body)

print("[1] 接口路径替换 %d 处" % c1)
print("[2] 请求体替换 %d 处" % c2)

if c1 == 0 or c2 == 0:
    print("!! 未找到目标代码，可能版本不匹配，未做修改")
    sys.exit(1)
if s == orig:
    print("!! 无变化")
    sys.exit(1)

bak = path + ".bak-" + datetime.datetime.now().strftime("%Y%m%d%H%M%S")
shutil.copy2(path, bak)
open(path, "w", encoding="utf-8").write(s)
print("[3] 已备份 -> " + bak)
print("[4] 已写入 %s (%d 字节)" % (path, len(s)))
PY

python3 /tmp/patch_cnbs.py "$TARGET"

echo "[5] 语法检查"
node --check "$TARGET" && echo "    Syntax OK"

echo "[6] 重启服务"
systemctl restart mcp-cnbs
sleep 2
systemctl is-active mcp-cnbs

echo
echo "完成。验证历史序列（期望输出 10 个数据点）："
echo '  TOKEN=$(sed -n "s/^MCP_CNBS_AUTH_TOKEN=//p" /home/www/workbuddy/apps/mcp-cnbs/service.env)'
echo '  U=https://cnbs.lets.zone/mcp'
echo '  INIT='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'"'"''
echo '  SID=$(curl -s -D- -o /dev/null -X POST $U -H "Authorization: Bearer $TOKEN" \'
echo '    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d "$INIT" \'
echo '    | awk -F'"'"': '"'"' '"'"'tolower($1)=="mcp-session-id"{print $2}'"'"' | tr -d '"'"'\r'"'"')'
echo '  curl -s --max-time 90 -X POST $U -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SID" \'
echo '    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \'
echo '    -d '"'"'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"cnbs_fetch_series","arguments":{"setId":"f7fd25aaad184414875632cf2327da60","metricIds":["7dc6a2ee6c614960b7059991e0cc4d96"],"periods":["2015YY-2024YY"]}}}'"'"' \'
echo '    | grep -o "\"code\"" | wc -l'
echo
echo "注意：不要用 grep '\"YY\"' 验证。SSE 内层 JSON 被转义，实际是 \\\"2015YY\\\"，必返回 0。"
