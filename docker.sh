#!/usr/bin/env bash

export LANG=en_US.UTF-8

WGCF_DIR='/etc/wireguard'
DOCKER_DIR='/unlock'

# 选择 IP API 服务商
IP_API=https://api.ip.sb/geoip; ISP=isp
#IP_API=https://ifconfig.co/json; ISP=asn_org
#IP_API=https://ip.gs/json; ISP=asn_org

# 自定义字体彩色，read 函数
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
reading(){ read -rp "$(green "$1")" "$2"; }

# 脚本当天及累计运行次数统计
statistics_of_run-times(){
COUNT=$(curl -sm1 "https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffscarmen%2Fwarp_unlock%2Fmain%2Fdocker.sh&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false" 2>&1) &&
TODAY=$(expr "$COUNT" : '.*\s\([0-9]\{1,\}\)\s/.*') && TOTAL=$(expr "$COUNT" : '.*/\s\([0-9]\{1,\}\)\s.*')
}

wgcf_install(){
  # 判断处理器架构
  case $(tr '[:upper:]' '[:lower:]' <<< "$(arch)") in
  aarch64 ) ARCHITECTURE=arm64;;	x86_64 ) ARCHITECTURE=amd64;;	s390x ) ARCHITECTURE=s390x;;	* ) red " Curren architecture $(arch) is not supported. Feedback: [https://github.com/fscarmen/warp/issues] " && exit 1;;
  esac

  # 判断 wgcf 的最新版本,如因 github 接口问题未能获取，默认 v2.2.19
  green " \n Install WGCF \n "
  latest=$(wget -qO- -4 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" | grep "tag_name" | head -n 1 | cut -d : -f2 | sed 's/[ \"v,]//g')
  latest=${latest:-'2.2.19'}

  # 安装 wgcf，尽量下载官方的最新版本，如官方 wgcf 下载不成功，将使用 githubusercontent 的 CDN，以更好的支持双栈。并添加执行权限
  wget -4 -O /usr/local/bin/wgcf https://github.com/ViRb3/wgcf/releases/download/v"$latest"/wgcf_"$latest"_linux_"$ARCHITECTURE" ||
  wget -4 -O /usr/local/bin/wgcf https://gitlab.com/fscarmen/warp/-/raw/main/wgcf/wgcf_"$latest"_linux_"$ARCHITECTURE"
  chmod +x /usr/local/bin/wgcf

  # 注册 WARP 账户 ( wgcf-account.toml 使用默认值加加快速度)。如有 WARP+ 账户，修改 license 并升级
  until [ -e wgcf-account.toml ] >/dev/null 2>&1; do
    wgcf register --accept-tos >/dev/null 2>&1 && break
  done

  # 生成 Wire-Guard 配置文件 (wgcf.conf)
  [ -e wgcf-account.toml ] && wgcf generate -p $WGCF_DIR/wgcf.conf >/dev/null 2>&1

  # 反复测试最佳 MTU。 Wireguard Header：IPv4=60 bytes,IPv6=80 bytes，1280 ≤1 MTU ≤ 1420。 ping = 8(ICMP回显示请求和回显应答报文格式长度) + 20(IP首部) 。
  # 详细说明：<[WireGuard] Header / MTU sizes for Wireguard>：https://lists.zx2c4.com/pipermail/wireguard/2017-December/002201.html
  MTU=$((1500-28))
  ping -c1 -W1 -s $MTU -Mdo 162.159.193.10 >/dev/null 2>&1
  until [[ $? = 0 || $MTU -le $((1280+80-28)) ]]; do
    MTU=$((MTU-10))
    ping -c1 -W1 -s $MTU -Mdo 162.159.193.10 >/dev/null 2>&1
  done

  if [[ $MTU -eq $((1500-28)) ]]; then
    MTU=$MTU
  elif [[ $MTU -le $((1280+80-28)) ]]; then
    MTU=$((1280+80-28))
  else
    for ((i=0; i<9; i++)); do
      (( MTU++ ))
      ping -c1 -W1 -s $MTU -Mdo 162.159.193.10 >/dev/null 2>&1 || break
    done
    (( MTU-- ))
  fi

  MTU=$((MTU+28-80))

  [ -e wgcf.conf ] && sed -i "s/MTU.*/MTU = $MTU/g" $WGCF_DIR/wgcf.conf
  sed -i "s/^.*\:\:\/0/#&/g;s/engage.cloudflareclient.com/162.159.193.10/g" $WGCF_DIR/wgcf.conf
}

# 期望解锁地区
input_region(){
  if [[ -z "$EXPECT" ]]; then
  REGION=$(curl -skm8 -A Mozilla $IP_API | grep -E "country_iso|country_code" | sed 's/.*country_[a-z]\+\":[ ]*\"\([^"]*\).*/\1/g' 2>/dev/null)
  reading " The current region is $REGION. Confirm press [y] . If you want another regions, please enter the two-digit region abbreviation. (such as hk,sg. Default is $REGION): " EXPECT
  until [[ -z $EXPECT || $EXPECT = [Yy] || $EXPECT =~ ^[A-Za-z]{2}$ ]]; do
    reading " The current region is $REGION. Confirm press [y] . If you want another regions, please enter the two-digit region abbreviation. (such as hk,sg. Default is $REGION): " EXPECT
  done
  [[ -z $EXPECT || $EXPECT = [Yy] ]] && EXPECT="$REGION"
  fi
}
  
# Telegram Bot 日志推送
input_tg(){
  [[ -z $CUSTOM ]] && reading " Please enter Bot Token if you need push the logs to Telegram. Leave blank to skip: " TOKEN
  [[ -n $TOKEN && -z $USERID ]] && reading " Enter USERID: " USERID
  [[ -n $USERID && -z $CUSTOM ]] && reading " Enter custom name: " CUSTOM
}

# 生成解锁文件
export_unlock_file(){
  [ ! -d $WGCF_DIR ] && mkdir $WGCF_DIR

  # 生成 warp_unlock.sh 文件，判断当前流媒体解锁状态，遇到不解锁时更换 WARP IP，直至刷成功。5分钟后还没有刷成功，将不会重复该进程而浪费系统资源
  cat <<EOF > $WGCF_DIR/warp_unlock.sh
#!/usr/bin/env bash

EXPECT="$EXPECT"
TOKEN="$TOKEN"
USERID="$USERID"
CUSTOM="$CUSTOM"
NIC="-ks4m8"
RESTART="wgcf_restart"
LOG_LIMIT="1000"
UNLOCK_STATUS='Yes 🎉'
NOT_UNLOCK_STATUS='No 😰'
if [[ \$(pgrep -laf ^[/d]*bash.*warp_unlock | awk -F, '{a[\$2]++}END{for (i in a) print i" "a[i]}') -le 2 ]]; then
LMC999=\$(curl -sSLm4 https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh)
RESULT_TITLE=(\$(echo "\$LMC999" | grep "result.*netflix.com/title/" | sed "s/.*title\/\([^\"]*\).*/\1/"))
REGION_TITLE=\$(echo "\$LMC999" | grep "region.*netflix.com/title/" | sed "s/.*title\/\([^\"]*\).*/\1/")
[[ ! \${RESULT_TITLE[0]} =~ ^[0-9]+$ ]] && RESULT_TITLE[0]='81280792'
[[ ! \${RESULT_TITLE[1]} =~ ^[0-9]+$ ]] && RESULT_TITLE[1]='70143836'
[[ ! "\$REGION_TITLE" =~ ^[0-9]+$ ]] && REGION_TITLE='80018499'
tg_output="💻 \\\$CUSTOM. ⏰ \\\$(date +'%F %T'). 🛰 \\\$WAN  🌏 \\\$COUNTRY. \\\$CONTENT"
tg_message(){ curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" -d chat_id=\$USERID -d text="\$(eval echo "\$tg_output")" -d parse_mode="HTML" >/dev/null 2>&1; }

ip(){
  unset IP_INFO WAN COUNTRY ASNORG
  IP_INFO="\$(curl \$NIC -A Mozilla $IP_API 2>/dev/null)"
  WAN=\$(expr "\$IP_INFO" : '.*ip\":[ ]*\"\([^"]*\).*')
  COUNTRY=\$(expr "\$IP_INFO" : '.*country\":[ ]*\"\([^"]*\).*')
  ASNORG=\$(expr "\$IP_INFO" : '.*'$ISP'\":[ ]*\"\([^"]*\).*')
}

wgcf_restart(){ wg-quick down wgcf >/dev/null 2>&1; wg-quick up wgcf >/dev/null 2>&1; sleep 5; ip; }

check0(){
  RESULT[0]=""; REGION[0]=""; R[0]="";

  for ((l=0; l<\${#RESULT_TITLE[@]}; l++)); do
    RESULT_NETFLIX[l]=\$(curl --user-agent "\${UA_Browser}" \$NIC -fsL --write-out %{http_code} --output /dev/null --max-time 10 "https://www.netflix.com/title/\${RESULT_TITLE[l]}")
    [ "\${RESULT_NETFLIX[l]}" = 200 ] && break
  done

  if [[ \${RESULT_NETFLIX[@]} =~ 200 ]]; then
    REGION[0]=\$(curl --user-agent "\${UA_Browser}" \$NIC -fs --max-time 10 --write-out %{redirect_url} --output /dev/null "https://www.netflix.com/title/\$REGION_TITLE" | sed 's/.*com\/\([^-/]\{1,\}\).*/\1/g' | tr '[:lower:]' '[:upper:]')
    REGION[0]=\${REGION[0]:-'US'}
  fi
  echo "\${REGION[0]}" | grep -qi "\$EXPECT" && R[0]="\$UNLOCK_STATUS" || R[0]="\$NOT_UNLOCK_STATUS"
  CONTENT="Netflix: \${R[0]}."
  [[ -n "\$CUSTOM" ]] && [[ \${R[0]} != \$(sed -n '1p' $DOCKER_DIR/status.log) ]] && tg_message
  sed -i "1s/.*/\${R[0]}/" $DOCKER_DIR/status.log
}

ip
UA_Browser="Mozilla/5.0 (Windows NT 10.0; Win64; x6*4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.87 Safari/537.36"
[[ ! \${R[*]} =~ 'No' ]] && check0
until [[ ! \${R[*]}  =~ "\$NOT_UNLOCK_STATUS" ]]; do
  unset R
  \$RESTART
  [[ ! \${R[*]} =~ 'No' ]] && check0
done

fi
EOF
}

container_build(){
  green " \n Docker build and run \n "
	
  # 安装 docker,拉取镜像 + 创建容器,如已经安装容器，先删除旧的
  ! systemctl is-active docker >/dev/null 2>&1 && green "\n Install docker \n" && curl -sSL get.docker.com | sh
  ! systemctl is-active docker >/dev/null 2>&1 && ( systemctl enable --now docker; sleep 2 )
  if [ "$(docker ps -aqf "name=wgcf" | wc -l)" != 0 ]; then
    green "\n Remove the old wgcf container \n"
    docker rm -f wgcf
    docker images -q --filter "reference=fscarmen/netflix_unlock" | xargs docker rmi
  fi
  green  "\n Install wgcf unlock container \n"
  docker run -dit --restart=always \
  --name wgcf \
  --sysctl net.ipv6.conf.all.disable_ipv6=0 \
  --device /dev/net/tun --privileged \
  --cap-add net_admin --cap-add sys_module \
  --log-opt max-size=1m \
  -v /lib/modules:/lib/modules \
  -v $WGCF_DIR:$WGCF_DIR \
  fscarmen/netflix_unlock:latest

  # 清理临时文件
  rm -rf wgcf-account.toml /usr/local/bin/wgcf
  green " \n Done! The script runs on today: $TODAY. Total: $TOTAL \n "
}


statistics_of_run-times

input_region

input_tg

export_unlock_file

wgcf_install

container_build