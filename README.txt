DomainProxy 0.3.2 — iOS 16.1 Dopamine RootHide 全局隧道实验版

该版本不包含 MobileSubstrate 插件，不需要为目标 App 开启注入。
桌面“域名代理”App 通过限定功能的 root 控制器，让系统 launchd 启动 sing-box。
核心不再作为设置 App 的普通子进程运行，以避免依赖 UI 的后台生命周期。
启动后发送一次普通域名 DNS 探测，并检查 utun99 双向计数是否增加；未通过则
自动停止服务并显示具体结果。它只能验证当次探测，不代表全设备长期无泄漏。
当前启用 debug 日志；日志界面去除 ANSI 颜色码，并附带当前 utun 收发计数。
这与 0.1/0.2 注入版本的实现不同，升级后应关闭旧版目标 App 注入并重启目标 App。

使用：
1. 在启用了 Dopamine RootHide 越狱的设备上用 Sileo 安装 deb。
2. 打开桌面“域名代理”，填写无认证 HTTP 上游的 IPv4 地址和端口。
3. 先关闭其他 VPN，点击“保存并启动全局代理”。不需要开启 App 注入。
4. 测试 ip138.com 的出口、非目标网站、IPv6。遇到错误，点击“查看运行日志”。
5. 点击“停止全局代理”退出隧道；升级/卸载时安装脚本也会要求服务退出。
  服务定义动态写入 /var/run，按需用 launchctl bootstrap/bootout 管理，
  不设置开机自启；重启设备并重新越狱后需在 App 中重新启动。

规则：
- 通过独立 utun 隧道接管 IPv4/IPv6 路由，目标为全设备流量分流。
- zijieapi.com、fqnovel.com、ip138.com 及其全部子域名通过 FakeIP DNS 映射、
  域名嗅探识别并转发到 HTTP 上游。
- 目标域名 UDP 被拒绝（HTTP 上游不支持原生 UDP），其余 IPv4 流量直连。
- 隧道内 IPv6 数据包被拒绝，DNS AAAA 返回空结果。这不是修改系统 IPv6 开关。
- DNS 明文查询交给 223.5.5.5；现有缓存、独立加密 DNS/ECH/绑定物理网卡的流量
  不保证可识别或拦截，不能把本实验版本当作无泄漏保证。
- 上游地址排除在隧道路由外，避免代理回环；网络切换异常时应停止后重新启动。
- 不提供崩溃断网开关；后台服务退出后网络可恢复直连。

状态与权限：
- 控制器仅提供 start IPv4 端口、stop、status、log 四项，不执行任意命令或文件。
- 控制器为 root 所有的 setuid 可执行文件，核心和模板只有包管理器可修改。
- 服务配置、PID、日志位于 jbroot:/var/run/domainproxy（root 目录权限 0700）。
- UI 中“进程运行”只表示进程存在，不表示全局接管、代理可达或 IPv6 拦截已验证。
- 没有真机，当前无法确认 iOS 16.1 的 utun 创建、路由权限、Wi-Fi/蜂窝切换表现。
  启动失败会返回错误和日志，不会显示虚假的“连接成功”。

编译：
GitHub Actions -> Build RootHide deb -> Run workflow。
使用 roothide/theos 和 THEOS_PACKAGE_SCHEME=roothide，架构 iphoneos-arm64e。
核心固定为 sing-box v1.12.0 / 2dcb86941f5db01bbe296acae555a3b1f38c0441，
并对其 sing-tun v0.7.0-beta.1 的 Inet4GatewayAddr / Inet6GatewayAddr 做局部修补：
GOOS=ios 与 darwin 走同一分支，使用 utun 本地地址作为网关，避免默认 .Next()
生成 172.19.0.2 后将公网路由错误挂到 en0。补丁源见 patches/fix_ios_gateway.py。
从源码交叉编译 GOOS=ios、GOARCH=arm64，使用 RootHide 应用权限签名。
构建会检查规则、用原生核心验证 JSON、检查 deb 内包含 UI/控制器/核心且无注入库。
成功后产物含 deb 和 SHA256 文件，下载到 downloads/。

许可与上游源码：
sing-box 为 GPL-3.0-or-later，完整上游源码及构建脚本版本公开：
https://github.com/SagerNet/sing-box/tree/2dcb86941f5db01bbe296acae555a3b1f38c0441
安装包内 /usr/share/doc/local.domainproxy/COPYING.sing-box 附带其许可证。
本仓库自写的 0.3.0 控制器、UI、规则与构建脚本亦按 GPL-3.0-or-later 发布。
RootHide 开发说明：https://github.com/roothide/Developer
