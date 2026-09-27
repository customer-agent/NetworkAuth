# NetworkAuth Docker 部署

这套文件位于 NetworkAuth 源码仓库中，持久化数据也保存在仓库的
`deploy/` 目录下，便于备份和迁移。主机需要 Docker Engine、Docker Compose
V2、Git 和 curl。

```bash
git clone -b wws_dev <NetworkAuth仓库地址> NetworkAuth
cd NetworkAuth
chmod +x tools/networkauth.sh
# 中国大陆网络建议先切换镜像源，再安装
tools/networkauth.sh mirror china
tools/networkauth.sh install
```

首次安装会直接使用当前 checkout 构建镜像。首次启动后打开
`http://127.0.0.1:8080/`（或反代域名），前端会进入安装页。
在安装页选择 SQLite、设置站点标题和管理员账号。数据库、日志、配置和环境文件
分别位于 `deploy/networkauth-data`、`deploy/networkauth-logs`、
`deploy/networkauth-config` 和 `deploy/networkauth.env`；环境文件和配置文件已经
按 600 权限创建，不要提交到 Git。

`mirror china` 会把 Docker Hub 基础镜像、Debian 软件包、npm 和 Go 模块切换到
可配置的国内源，默认 Docker 镜像前缀为 `m.daocloud.io/docker.io`。APT 使用清华 HTTP
镜像（Debian 仍校验仓库签名）；如所在网络访问该
镜像不稳定，可以指定其他兼容 Docker Registry 的前缀，例如：

```bash
tools/networkauth.sh mirror china m.daocloud.io/docker.io
tools/networkauth.sh mirror show
```

`tools/networkauth.sh mirror official` 可恢复 Docker Hub、Debian 官方源、npmjs 和
官方 Go proxy。`NETWORKAUTH_PULL_IMAGES=0` 只是不强制更新基础镜像；本机没有所需
镜像时，Docker 仍会从当前配置的镜像前缀拉取。公共镜像可能有缓存延迟、限流或高峰
拥堵，无法保证所有中国网络和时段都可达；生产环境也可以在自己的网络中配置 Docker
Registry pull-through cache。

使用自定义镜像源时，每个基础镜像默认最多尝试 3 次（首次加两次重试），在系统
提供 coreutils `timeout` 时，以 `NETWORKAUTH_PULL_TIMEOUT=600`（秒）限制单次
拉取的总时长，再给予 10 秒退出宽限。它不是“无下载进度”超时；连接很慢但一直有
进度时可调大该值。可在 `deploy/networkauth.env` 中调整
`NETWORKAUTH_PULL_RETRIES` 和 `NETWORKAUTH_PULL_TIMEOUT`，旧配置缺少这两项时
自动使用默认值。将超时设为 `0` 可关闭脚本层超时；未安装 `timeout` 时会明确提示。
手动按 `Ctrl-C` 中断后不会自动重试。脚本保留 Docker 缓存，完整的镜像可直接复用；
未完成或尚未写入缓存的层可能重新下载，不保证字节级断点续传。

如果进度长时间不变，可以先单独运行当前镜像的拉取命令，确认是否脱离部署脚本
仍然停滞；同时在另一终端查看 Docker daemon 日志：

```bash
docker pull m.daocloud.io/docker.io/library/golang:1.25-bookworm
sudo journalctl -u docker --since "15 minutes ago" --no-pager
```

`Waiting` 是 Docker 镜像层的队列状态，不能单凭它判断网络故障。Docker 默认并发
下载 3 层，[官方文档](https://docs.docker.com/reference/cli/docker/image/pull/)
建议低带宽环境降低并发数。若确认有并发下载超时，可以在现有
`/etc/docker/daemon.json` 中合并 `"max-concurrent-downloads": 1` 后安排重启 Docker；
不要覆盖原有配置，重启可能影响该主机上的其他容器。该设置由主机管理员维护。
Linux 日志位置参见 [Docker daemon 日志文档](https://docs.docker.com/engine/daemon/logs/)。

脚本兼容 Git 1.8.3.1（不使用 `git -C`）。若 Git 状态检查本身失败，会在拉取或
构建前退出，不会将失败误判为“源码干净”。

如果前端在另一台公网主机上反代，脚本默认监听 `0.0.0.0:8080`；请在防火墙中只
允许公网反代主机访问该端口，也可以把 `NETWORKAUTH_BIND_ADDRESS` 改为具体内网
地址。把公网反代主机的内网 IP/CIDR 写入 `NETWORKAUTH_TRUSTED_PROXIES`，例如
`192.168.1.20/32`。这是
NetworkAuth 的安全设置：只有列入白名单的代理才会解析 `X-Forwarded-For`，否则
限流、IP 绑定和地区校验会看到反代机地址。修改后删除旧的
`deploy/networkauth-config/config.json` 或手动同步其中的 `server.trusted_proxies`，
然后执行 `tools/networkauth.sh restart`。

## 账号和一机一号

后台应用和终端账号均由 NetworkAuth 前端管理。创建应用后记录应用 UUID 与应用
密钥；客户端公开 API 请求使用应用 UUID、API 类型、请求数据、时间戳和应用密钥
签名，格式为 `SHA256(app_uuid|api_type|data|timestamp|app_secret)`（服务端校验约
±300 秒的时间窗口）。生产环境请始终通过 `https://auth.weisong.space` 发送。
账号登录 API 使用类型 20，数据中包含 `username`、`password`、
`machine_code`、`version` 和可选的 `device_name`。

为了实现一套账号绑定一台机器，在应用编辑页设置：

* 开启“机器验证”（`machine_verify=1`）；
* 多开范围选择“单电脑/机器码”（`multi_open_scope=0`）；
* 多开数量设为 `1`（`multi_open_count=1`）；
* 设备已满时选择“拒绝新登录”（`login_type=1`）。

如果会员等级配置了额外多开数，请一并清零；服务端有效上限会把应用多开数与
会员等级额外多开数相加。

服务端在开启机器验证时拒绝空的 `machine_code`，避免客户端省略该字段后绕过绑定。
机器码仍然是客户端提交的
标识，不能抵抗恶意客户端复制；生产客户端应使用稳定的硬件指纹并配合服务端的
在线会话和换绑审核。

账号新增、禁用、改密、续期、查看在线设备、清理绑定和机器换绑都在“会员/账号”
页面完成。第一次携带某个 `machine_code` 登录会建立绑定，其他机器会被拒绝；如
需允许用户自行换绑，单独在应用设置中开启机器转绑并限制次数。

## 运维命令

```bash
tools/networkauth.sh status
tools/networkauth.sh logs -f --tail=200
tools/networkauth.sh backup
tools/networkauth.sh update       # 备份、快进拉取、重新构建并启动
tools/networkauth.sh restart
tools/networkauth.sh down
```

`update` 使用当前分支的 `git pull --ff-only`，工作区存在未提交修改时会停止，不会覆盖本地
改动；在 `wws_dev` 分支中会从 `origin/wws_dev` 快进升级。SQLite 备份会先短暂停止容器，打包完成后恢复原来的
运行状态；升级前会在 `deploy/` 下生成只允许当前用户读取的备份压缩包。容器启动、
重启和升级都会等待 Docker healthcheck 变为 `healthy`，失败时输出最近日志并返回非零
状态。

Compose 使用 Docker json-file 日志轮转，默认每个文件 10 MB、保留 5 个文件；可以
在 `deploy/networkauth.env` 中设置 `NETWORKAUTH_LOG_MAX_SIZE` 和
`NETWORKAUTH_LOG_MAX_FILE`。首次构建默认拉取最新基础镜像，网络受限时可设置
`NETWORKAUTH_PULL_IMAGES=0`。
