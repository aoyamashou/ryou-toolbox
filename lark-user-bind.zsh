#!/usr/bin/env zsh
# 互动式创建/授权 Lark CLI User Profile，并选择默认使用的 Profile。
set -euo pipefail

export LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1
export LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1

die() { print -u2 "错误：$*"; exit 1; }
command -v lark-cli >/dev/null 2>&1 || die "未找到 lark-cli。"
command -v python3 >/dev/null 2>&1 || die "未找到 python3。"

profile_json() { lark-cli profile list 2>/dev/null; }

print_profiles() {
  profile_json | python3 -c '
import json, sys
try: profiles = json.load(sys.stdin)
except Exception as e: print(f"无法解析 Profile 列表：{e}", file=sys.stderr); sys.exit(1)
if not profiles:
    print("（暂无 Profile）"); sys.exit(0)
for i, p in enumerate(profiles, 1):
    mark = "*" if p.get("active") else " "
    print("{} {}. {}  [{}]  用户：{}".format(mark, i, p.get("name", ""), p.get("brand", "?"), p.get("user") or "未绑定"))
'
}

get_profile_name() {
  local n="$1"
  profile_json | python3 -c 'import json,sys; ps=json.load(sys.stdin); i=int(sys.argv[1]); print(ps[i-1]["name"])' "$n" 2>/dev/null
}

list_authorized_users() {
  local names name status_json result
  names="$(profile_json | python3 -c 'import json,sys; print("\n".join(p.get("name", "") for p in json.load(sys.stdin)))')"
  print
  print "已授权的 User 用户："
  print "--------------------"
  local found=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if status_json="$(lark-cli auth status --profile "$name" --json --verify 2>/dev/null)"; then
      result="$(printf '%s' "$status_json" | python3 -c '
import json,sys
d=json.load(sys.stdin); u=d.get("identities",{}).get("user",{})
if d.get("identity") == "user" and d.get("verified") and u.get("tokenStatus") == "valid":
    print("OK\t{}\t{}".format(u.get("userName") or "-", u.get("openId") or "-"))
' 2>/dev/null || true)"
      if [[ "$result" == OK$'\t'* ]]; then
        result="${result#*$'\t'}"
        print "✅ $name  |  $result"
        found=1
      fi
    fi
  done <<< "$names"
  (( found == 1 )) || print "（暂无已验证的 User 用户）"
  print
}

manage_profiles() {
  local action count choice selected confirm
  print
  print "当前本机 Profile："
  print "----------------"
  print_profiles
  print
  print "n. 新建 Profile"
  print "d. 删除 Profile"
  print "0. 返回主菜单"
  print
  read "action?请选择："
  case "$action" in
    n|N)
      bind_profile
      ;;
    d|D)
      count="$(profile_json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
      (( count > 0 )) || { print "暂无可删除的 Profile。"; return 0; }
      print
      print_profiles
      read "choice?请输入要删除的 Profile 编号（0 返回）："
      [[ "$choice" == 0 ]] && return 0
      [[ "$choice" =~ '^[0-9]+$' ]] || die "请输入数字。"
      selected="$(get_profile_name "$choice")" || die "无效选择。"
      read "confirm?确认删除 Profile \"$selected\"？请输入 yes："
      [[ "$confirm" == "yes" ]] || { print "已取消删除。"; return 0; }
      lark-cli profile remove "$selected"
      print "已删除 Profile：$selected"
      ;;
    0) return 0;;
    *) print -u2 "请输入 n、d 或 0。";;
  esac
}

report_current_status() {
  local current status_json identity verified user_name open_id
  current="$(profile_json | python3 -c 'import json,sys; ps=json.load(sys.stdin); print(next((p.get("name", "") for p in ps if p.get("active")), ""))')"
  print
  print "Lark CLI 当前状态"
  print "================"
  if [[ -z "$current" ]]; then
    print "当前使用的 Profile：无"
    print "权限类型：无"
    print "User 用户：无"
    return 0
  fi
  print "目前使用的 Profile：$current"
  if status_json="$(lark-cli auth status --profile "$current" --json --verify 2>/dev/null)"; then
    identity="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("identity", "unknown"))')"
    verified="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("verified", False)).lower())')"
    if [[ "$identity" == "user" && "$verified" == "true" ]]; then
      user_name="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("identities",{}).get("user",{}).get("userName") or "-")')"
      open_id="$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("identities",{}).get("user",{}).get("openId") or "-")')"
      print "权限类型：User 权限"
      print "User 用户：$user_name（$open_id）"
    else
      print "权限类型：App/Bot 权限"
      print "User 用户：无"
    fi
  else
    print "权限类型：无法验证（可能是 Keychain 或网络不可用）"
    print "User 用户：无法确认"
  fi
}

select_profile() {
  local count choice selected
  count="$(profile_json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  (( count > 0 )) || { print "暂无 Profile，请先创建并绑定。"; return 1; }
  print
  print_profiles
  print "  0. 取消"
  print
  read "choice?请选择："
  [[ "$choice" == 0 ]] && return 0
  [[ "$choice" =~ '^[0-9]+$' ]] || die "请输入数字。"
  selected="$(get_profile_name "$choice")" || die "无效选择。"
  lark-cli profile use "$selected" >/dev/null
  print "已选择 Profile：$selected"
  if verify_profile "$selected"; then
    print "Profile 已验证，脚本结束。"
  else
    print "该 Profile 尚未完成 User 身份验证，开始授权……"
    authenticate_profile "$selected"
  fi
  return 0
}

authenticate_profile() {
  local name="$1" auth_json verification_url device_code qr_file desktop_qr
  auth_json="$(lark-cli auth login --profile "$name" --recommend --no-wait --json)" || die "发起 User 授权失败。"
  verification_url="$(printf '%s' "$auth_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verification_url"])')" || die "无法取得授权链接。"
  device_code="$(printf '%s' "$auth_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["device_code"])')" || die "无法取得设备码。"
  qr_file="lark-user-auth-${name}-$(date +%Y%m%d-%H%M%S).png"
  lark-cli auth qrcode "$verification_url" --output "$qr_file" >/dev/null 2>&1 || true
  desktop_qr="$HOME/Desktop/$qr_file"
  if [[ -f "$qr_file" ]] && [[ -d "$HOME/Desktop" ]]; then
    mv -f "$qr_file" "$desktop_qr"
  fi
  print
  print "请让目标用户打开以下链接完成授权："
  print "$verification_url"
  [[ -f "$desktop_qr" ]] && print "二维码已保存到：$desktop_qr"
  print
  print "请使用 Lark 扫描下面的终端二维码："
  if ! lark-cli auth qrcode "$verification_url" --ascii; then
    print "（终端二维码生成失败，请使用上面的授权链接或 PNG 文件。）"
  fi
  print
  read "REPLY?用户完成授权后按回车继续（Ctrl-C 可取消）……"; print
  lark-cli auth login --profile "$name" --device-code "$device_code"
  verify_profile "$name"
  print "User 身份验证完成，脚本结束。"
}

main_menu() {
  local action
  while true; do
    print
    print "Lark CLI User 身份管理"
    print "======================"
    print "1. 选择要使用的Profile并输出User授权状态"
    print "2. 管理Profile"
    print "3. 查看当前授权状态"
    print "4. 退出并汇报状态"
    print
    read "action?请选择："
    case "$action" in
      1) select_profile || true;;
      2) manage_profiles;;
      3) list_authorized_users;;
      4)
        report_current_status
        print
        read -k 1 "REPLY?按任意键退出……"
        print
        return 0
        ;;
      *) print -u2 "请输入 1、2、3 或 4。";;
    esac
  done
}

bind_profile() {
  local name brand auth_json verification_url device_code qr_file
  read "name?新 Profile 名称（例如 alice）："
  [[ "$name" =~ '^[A-Za-z0-9._-]+$' ]] || die "名称只能包含字母、数字、点、下划线或短横线。"
  print "请选择产品：1) 国际版 Lark  2) 国内版飞书"
  local brand_choice; read "brand_choice?选择 [1]："
  [[ -z "$brand_choice" ]] && brand_choice=1
  case "$brand_choice" in
    1) brand=lark;;
    2) brand=feishu;;
    *) die "无效产品选择。";;
  esac

  print "正在创建 Profile（可能需要在浏览器中完成应用配置）……"
  lark-cli config init --new --name "$name" --brand "$brand" --lang zh_cn

  authenticate_profile "$name"
}

verify_profile() {
  local name="$1"
  print "正在验证 User 身份……"
  lark-cli auth status --profile "$name" --json --verify | python3 -c '
import json,sys
d=json.load(sys.stdin); u=d.get("identities",{}).get("user",{})
if d.get("identity") != "user" or not d.get("verified") or u.get("tokenStatus") != "valid":
    print("验证失败：当前不是有效的 User 身份。", file=sys.stderr); sys.exit(1)
print("✅ User 身份有效：{}（{}）".format(u.get("userName") or "-", u.get("openId") or "-"))
'
}

main_menu
