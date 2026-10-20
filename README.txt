DomainProxy 0.4.1 — iOS 16.1 Dopamine RootHide

HTTP / SOCKS5 上游、运行中热切换、后台 HTTP 控制 API。
0.4.1 修复 iOS 分段路由遗漏：保留物理默认路由，防止 utun 自身成为出站接口。
停止时还会恢复启动前保存的物理默认路由（不替换系统已有路由）。
App 无需为目标应用开启注入。核心由 launchd 独立运行。

使用：
1. 用 Sileo 安装 deb，打开桌面“域名代理”，先关闭其他 VPN。
2. 填写 IPv4、端口，选择 HTTP / SOCKS5；需要认证时填写账号密码。
   可从取代理 API 获取并填入 IP:端口，协议和账号密码由你在界面选择。
3. 首次点击“保存并启动全局代理”。启动自检检查 DNS 与 utun99 双向收发。
4. 运行中修改代理后，点击“切换代理（不重启服务）”。
   此操作仅更换核心内部的上游出口，不重新加载配置、不重建隧道、不重启进程。
   默认关闭旧代理连接，应用需重新建立连接；新连接使用新代理。
   直连连接不受这个切换动作影响。不能把已建立的 TCP 会话迁移到另一个代理。
5. 点击“刷新服务状态”查看当前上游和 PID，验证出口请访问 ip138.com。
6. 点击“停止全局代理”恢复系统网络，同时关闭 HTTP 切换接口。

后台 HTTP API：
- 接口与隧道核心同生命周期，App 不在前台、退出 App 后仍可调用。
- 手机本机地址：http://127.0.0.1:9099/v1/proxy
- 局域网地址：http://手机Wi-Fi地址:9099/v1/proxy
- “允许局域网调用”在启动服务时应用；关闭后只监听 127.0.0.1。
- “查看并复制 API 调用示例”会复制含独立随机密钥的 curl 示例。
- 必须带 Authorization: Bearer 密钥；密钥不能放在 URL 中。
- 此接口使用 HTTP 明文，仅在可信局域网使用；不要将 9099 映射到公网。

切换示例（全部为占位值，请替换）：
curl -X POST 'http://手机Wi-Fi地址:9099/v1/proxy'   -H 'Authorization: Bearer 从App复制的密钥'   -H 'Content-Type: application/json'   -d '{"type":"socks5","ip":"192.0.2.10","port":1080,"username":"","password":"","close_existing":true}'

HTTP 上游将 type 改成 http；支持 POST 或 PUT。
必须提供 type、ip（IPv4）、port（1..65535）。
username/password 可省略，省略表示无认证，不继承旧账号密码。
close_existing 默认 true：关闭旧代理连接，促使应用重新连接。
传 false：保留已有代理连接直到自然关闭，新建连接仍使用新代理。
切换成功只表示配置已应用，不表示新上游一定可用或出口已验证。
非法参数、保存失败时保留旧上游；网络请求超时后请 GET 查询确认结果。

状态示例：
curl 'http://手机Wi-Fi地址:9099/v1/proxy' -H 'Authorization: Bearer 从App复制的密钥'
返回当前 type、ip、port、username、password_set、generation 和 pid。
不返回密码或控制密钥。成功切换响应含 pid 和 closed_connections。
同一核心 PID 在切换前后保持一致；generation 每次切换递增。
未认证返回 401，参数错误返回 400，服务内部保存失败返回 500。

规则与限制：
- zijieapi.com、fqnovel.com、ip138.com 及全部子域名通过 HTTP/SOCKS5 上游。
- 其余 IPv4 流量直连。目标域名 UDP 仍拒绝；SOCKS5 也只用于 TCP。
- 独立 utun99 接管路由；隧道内 IPv6 拒绝，DNS AAAA 返回空结果。
- DNS 明文发至 223.5.5.5，FakeIP 与域名嗅探用于目标分流。
- 加密 DNS、ECH、应用缓存、绑定物理网卡等不能保证完整识别。
- HTTP/SOCKS5 使用 sing-box 内置拨号器，自动绑定物理接口，换 IP 无需改隧道路由。
- 不提供断线锁网。切换 Wi-Fi/蜂窝出现异常时停止后重启服务。
- 0.4.1 版本新增能力需真机验证；编译与测试不代表所有 App 都已接管。
- -1009 表示当前网络不可用或 App 联网受限，请检查 App 的系统联网权限。

状态与权限：
- root 控制器仅实现 start/switch、JSON 参数版本、stop/status/log/api-info。
- 不执行任意 shell 命令或任意路径文件。
- 配置、API 密钥、当前上游、PID、日志保存在 jbroot:/var/run/domainproxy，目录 0700。
- 上游账号密码保存在 App 本地设置及 root 私有运行配置中。
- API 密钥在当前运行目录保留期间保持不变，重启设备后可能重新生成。
- 重启设备并越狱后需重新启动；不设置开机自启；卸载/升级会停止服务。

编译与验证：
GitHub Actions -> Build RootHide deb。使用 roothide/theos，iphoneos-arm64e。
核心固定 sing-box v1.12.0 / 2dcb86941f5db01bbe296acae555a3b1f38c0441。
patches/fix_ios_gateway.py 修复 iOS utun 网关地址。
patches/install_dynamic.py 安装 patches/dynamic 的核心内动态出口和 HTTP API。
构建执行真实 HTTP CONNECT / SOCKS5 认证切换、连接保留/断开、鉴权、
非法请求、保存失败保留旧配置及并发竞态测试，然后验证配置和 deb 权限。
完成后下载 deb 与 SHA256 到 downloads/。

许可与上游源码：
本项目及核心修改遵循 GPL-3.0-or-later。
https://github.com/pang5813/DomainProxy-RootHide
https://github.com/SagerNet/sing-box/tree/2dcb86941f5db01bbe296acae555a3b1f38c0441
deb 中 /usr/share/doc/local.domainproxy 附带许可证和核心补丁源码。
RootHide：https://github.com/roothide/Developer
