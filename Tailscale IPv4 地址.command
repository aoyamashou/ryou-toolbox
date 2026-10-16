#!/bin/zsh

clear
echo "Tailscale IPv4 地址"
echo "===================="
tailscale status | awk 'NF >= 2 {printf "%-16s %s\n", $1, $2}'
echo
echo "提示：可直接在此窗口中选中并复制。"
echo "按回车键退出。"
read
