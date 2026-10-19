DomainProxy — RootHide 实验原型（iOS 15+）

功能：为注入进程的 CFNetwork / NSURLSession 设置 PAC；ip138.com 及子域名走
HTTP 代理，其他域名 DIRECT。HTTPS 由 HTTP 代理 CONNECT，未实现解密。
通过 socket/getaddrinfo hook 限制注入进程使用 IPv6。

这不是内核级透明代理，也不是全设备 IPv6 开关。自带网络栈、QUIC、独立网络
服务进程、后台会话或不接受 PAC 的 App 可能绕过代理。RootHide 注入范围和
沙盒文件访问需要真机验证，Safari 的 WebKit 网络进程尤其不能保证覆盖。
IPv6-only / NAT64 网络可能因此无法联网。不要将本原型当作防泄漏工具。

配置：
1. 用 RootHide 环境的 Filza 找到越狱根目录内 Library/DomainProxy/proxy.pac。
   不要假设固定为 /var/jb；程序使用 jbroot() 解析实际路径。
2. 填 PROXY_IP 和 PROXY_PORT（仅支持 IPv4 地址、无认证 HTTP 上游）。
   IP 留空时域名全部直连，但 IPv6 hook 仍生效。
3. 在 RootHide 的 App 注入管理中只启用需要测试的 App，然后彻底退出并重开。
   当前无设置面板。源码中的配置亦可在 GitHub 编译前修改；不要填写真实密码。
4. 关闭该 App 的注入并重启 App，或卸载插件并重启 App，即恢复原状。
   插件不修改系统网络配置，不需要恢复系统 IPv6 参数。

GitHub 编译：
将本目录全部文件（包括隐藏的 .github）放入 GitHub 仓库。
push 或 Actions -> Build RootHide deb -> Run workflow。
成功后从 Artifacts 下载 DomainProxy-roothide，解压得到 deb，用 Sileo 安装。
使用 roothide/theos，THEOS_PACKAGE_SCHEME=roothide；不是普通 rootless 包。
官方说明：https://github.com/roothide/Developer
本地有兼容 macOS 工具链时可运行：
  gmake package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide

验证：
  node tests/pac.test.cjs
真机还需确认：ip138.com 显示代理出口、非目标站保持原出口、代理停止时目标
请求失败、IPv6 请求失败、重启/卸载恢复。PAC 单元测试不能验证这些行为。
当前 Windows 环境不能编译 iOS 动态库；只有 GitHub 构建成功才会产生 deb。
