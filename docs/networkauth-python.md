# NetworkAuth Python 测试与接口调用

`tools/networkauth_api.py` 是一个只使用 Python 标准库的调用示例。它既可以
验证已经部署的 NetworkAuth，也可以作为其他 Python 程序调用公开接口的最小参考。
脚本默认按接口配置为“提交数据：不加密、返回数据：不加密”处理；截图中的 API 20
配置正是这种方式。其他加密算法的完整方向约定见 [api-guide.md](./api-guide.md)。

脚本默认发送 `User-Agent: NetworkAuth-Python/1.0`。部分公网 WAF 会拦截 Python
`urllib` 的默认标识；如果你的反代有自己的规则，可用 `--user-agent` 或
`NETWORKAUTH_USER_AGENT` 覆盖。

## 1. 测试账号登录

不要把应用密钥和账号密码写进仓库或脚本。推荐使用环境变量：

```bash
export NETWORKAUTH_BASE_URL='https://auth.weisong.space'
export NETWORKAUTH_APP_UUID='替换为应用 UUID'
export NETWORKAUTH_APP_SECRET='替换为应用密钥'
export NETWORKAUTH_USERNAME='替换为终端账号'
export NETWORKAUTH_PASSWORD='替换为终端密码'
export NETWORKAUTH_MACHINE_CODE="$(hostname)-python-test"
export NETWORKAUTH_CLIENT_VERSION='python-api-test/1.0.0'

python3 tools/networkauth_api.py login
```

也可以显式传参：

```bash
python3 tools/networkauth_api.py login \
  --base-url https://auth.weisong.space \
  --app-uuid '应用 UUID' \
  --app-secret '应用密钥' \
  --username '终端账号' \
  --password '终端密码' \
  --machine-code '这台机器的稳定机器码' \
  --version '1.0.0' \
  --device-name 'Python test'
```

API 20 的明文业务数据为：

```json
{
  "username": "终端账号",
  "password": "终端密码",
  "machine_code": "这台机器的稳定机器码",
  "version": "1.0.0",
  "device_name": "Python test"
}
```

`machine_code` 必须保持稳定。应用启用机器验证后，同一账号首次使用的机器码会
建立绑定；换机器测试可能返回设备数量或机器绑定相关错误。`version` 是必填字段，
不要省略。

## 2. 机器码转绑

如果返回 `机器码未绑定，请先进行机器码转绑`，说明账号已有其他机器绑定，当前
`machine_code` 不能直接登录。后台先确认应用启用了“转绑”（API 51）及机器码转绑，
然后用账号密码查询当前绑定设备：

```bash
python3 tools/networkauth_api.py rebind
```

查询只读，不带 `machine_code`，会返回 `devices` 列表。单设备限制下，可直接把账号
转到当前测试机；多设备已满时，把要替换的旧机器码传给 `--replace-machine`：

```bash
export NETWORKAUTH_MACHINE_CODE="$(cat /etc/machine-id)"
python3 tools/networkauth_api.py rebind \
  --machine-code "$NETWORKAUTH_MACHINE_CODE" \
  --device-name "Linux test"
```

如果返回“设备数已达上限，请指定要替换的设备”，先从上一步的 `devices` 中选出旧
机器码，再执行：

```bash
python3 tools/networkauth_api.py rebind \
  --machine-code "$NETWORKAUTH_MACHINE_CODE" \
  --replace-machine '要替换的旧机器码' \
  --device-name "Linux test"
```

转绑成功后，再执行 `login`。转绑次数、免费次数和扣费由应用后台设置控制；如果
应用还启用了 IP 验证，API 51 也会按当前请求 IP 执行对应的 IP 转绑。

## 3. 调用其他不加密接口

脚本的 `call` 子命令可发送任意 JSON 对象。下面调用 API 1 获取公告和应用能力：

```bash
python3 tools/networkauth_api.py call \
  --api-type 1 \
  --data-json '{}'
```

需要登录的接口把登录返回的 `token` 放入业务数据，例如 API 40：

```bash
python3 tools/networkauth_api.py call \
  --api-type 40 \
  --data-json '{"token":"登录返回的 token"}'
```

脚本会打印服务端 JSON。`code` 含义通常为：

* `0`：调用成功；
* `1`：参数、签名、接口状态或业务校验失败；
* `2`：客户端版本过低，需要按返回的 `update` 信息升级；
* `3`：达到多开上限且后台配置为手动顶号，需要按返回的 `sessions` 选择会话。

## 4. 签名和请求格式

所有公开接口使用同一个地址：

```text
POST https://auth.weisong.space/api/open
Content-Type: application/json
```

信封格式：

```json
{
  "app_uuid": "应用 UUID",
  "api_type": 20,
  "data": "紧凑 JSON 字符串或密文",
  "timestamp": 1710000000,
  "sign": "大写 SHA256"
}
```

签名原文必须严格使用实际发送的 `data` 字符串：

```text
SHA256(app_uuid|api_type|data|timestamp|app_secret).hexdigest().upper()
```

服务端只接受时间偏差不超过约 300 秒的请求。因此签名后应立即发送，服务器和
客户端的系统时间需要同步。

## 5. NetworkAuth 后台配置检查

对 API 20 登录测试，后台至少确认：

1. **应用管理 → 接口设置**中选择正确的应用；
2. “账号登录”（API 类型 20）状态为“启用”；
3. 脚本使用的应用 UUID 和应用密钥来自同一个应用；
4. 若提交/返回算法设为“不加密”，脚本可以直接解析返回的 `data`；
5. 若应用启用了机器验证，使用已绑定机器码，或先在后台清理/换绑旧设备。

新建应用时接口默认禁用，所以 API 20 必须单独启用。启用状态写入数据库，通常
不需要重启 Docker 容器。

如果调用方是 `sainiu-api`，登录后的调用顺序包含 API 41（检测账号状态/心跳），
退出时调用 API 30（退出登录）。这两个接口也必须在同一个应用的“接口设置”中启用；
否则登录虽然成功，运行一段时间后会因心跳失败，退出时也会返回“接口已停用”。
API 40（获取到期时间）只在调用方明确使用该查询时启用。

如果将接口改为 RC4、RSA、RSA（动态）或易加密，脚本仍可发送签名信封，但不会
替你解密业务数据；应按 [api-guide.md](./api-guide.md) 的密钥方向实现对应客户端。
联调阶段建议先使用“不加密”确认签名、账号、机器码和版本逻辑均正常，再启用加密。

## 6. 常见错误

* `接口已停用`：应用的 API 20 状态仍为禁用，或请求使用了另一个应用 UUID。
* `签名校验失败`：签名使用的 `data` 与实际发送的字符串不完全一致，或应用密钥不匹配。
* `请求已过期，请校准时间`：客户端/服务器系统时间偏差超过签名窗口。
* `请提供客户端版本号`：API 20 的业务 JSON 缺少 `version`。
* `账号或密码错误`：账号属于其他应用、密码错误、账号被禁用，或提交的机器码触发了绑定限制。
* `请求解密失败`：后台接口算法不是“不加密”，但客户端仍发送了明文 JSON，或密钥方向配置错误。

服务端部署在反向代理之后时，`config.json` 的 `server.trusted_proxies` 只影响
客户端 IP 识别、限流和机器/IP 校验，不改变 API 20 的签名规则。
