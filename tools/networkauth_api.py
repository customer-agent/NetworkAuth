#!/usr/bin/env python3
"""Small, dependency-free NetworkAuth public API client.

The default ``login`` command matches an API 20 interface configured with
"不加密" for both submit and return data.  Credentials are read from command
line options or environment variables; no test credential is stored here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import sys
import time
from typing import Any, Dict, Optional
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_BASE_URL = "https://auth.weisong.space"
DEFAULT_USER_AGENT = "NetworkAuth-Python/1.0"


def default_machine_code() -> str:
    """Return a stable per-host default without making up a shared value."""
    machine_id_path = "/etc/machine-id"
    try:
        with open(machine_id_path, "r", encoding="utf-8") as machine_id_file:
            machine_id = machine_id_file.read().strip()
        if machine_id:
            return machine_id
    except OSError:
        pass
    return platform.node() or "python-api-test"


def compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def sign_request(app_uuid: str, api_type: int, data: str, timestamp: int, secret: str) -> str:
    raw = f"{app_uuid}|{api_type}|{data}|{timestamp}|{secret}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest().upper()


def endpoint_from_base(base_url: str) -> str:
    base_url = base_url.rstrip("/")
    return base_url if base_url.endswith("/api/open") else f"{base_url}/api/open"


def require(value: Optional[str], option: str) -> str:
    if value is None or value == "":
        raise ValueError(f"缺少 {option}；也可以通过对应环境变量传入")
    return value


def parse_json_object(raw: str, option: str) -> Dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{option} 不是合法 JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{option} 必须是 JSON 对象")
    return value


def call_open_api(
    *,
    base_url: str,
    app_uuid: str,
    app_secret: str,
    api_type: int,
    data: str,
    timeout: float,
    user_agent: str,
) -> Dict[str, Any]:
    timestamp = int(time.time())
    body = {
        "app_uuid": app_uuid,
        "api_type": api_type,
        "data": data,
        "timestamp": timestamp,
        "sign": sign_request(app_uuid, api_type, data, timestamp, app_secret),
    }
    request = Request(
        endpoint_from_base(base_url),
        data=compact_json(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            # Some public WAF rules reject urllib's default Python-urllib UA.
            "User-Agent": user_agent,
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            raw_response = response.read().decode("utf-8")
    except HTTPError as exc:
        raw_response = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {raw_response}") from exc
    except URLError as exc:
        raise RuntimeError(f"请求失败: {exc.reason}") from exc

    try:
        response_json = json.loads(raw_response)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"服务端返回的不是 JSON: {raw_response[:500]}") from exc
    if not isinstance(response_json, dict):
        raise RuntimeError("服务端返回的 JSON 不是对象")
    return response_json


def decode_none_response(response: Dict[str, Any]) -> Dict[str, Any]:
    """Parse an API response configured with return algorithm 0."""
    data = response.get("data")
    if isinstance(data, str):
        try:
            response["data"] = json.loads(data)
        except json.JSONDecodeError:
            # Some successful APIs intentionally return a plain string.
            pass
    return response


def common_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--base-url",
        default=os.environ.get("NETWORKAUTH_BASE_URL", DEFAULT_BASE_URL),
        help=f"NetworkAuth 地址，默认 {DEFAULT_BASE_URL}",
    )
    parser.add_argument("--app-uuid", default=os.environ.get("NETWORKAUTH_APP_UUID"))
    parser.add_argument(
        "--app-secret", default=os.environ.get("NETWORKAUTH_APP_SECRET"), help="应用密钥"
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("NETWORKAUTH_TIMEOUT", "15")),
        help="HTTP 超时秒数，默认 15",
    )
    parser.add_argument(
        "--user-agent",
        default=os.environ.get("NETWORKAUTH_USER_AGENT", DEFAULT_USER_AGENT),
        help=f"HTTP User-Agent，默认 {DEFAULT_USER_AGENT}",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="调用 NetworkAuth /api/open 公开接口")
    subparsers = parser.add_subparsers(dest="command", required=True)

    login = subparsers.add_parser("login", help="调用 API 20 账号登录")
    common_options(login)
    login.add_argument("--username", default=os.environ.get("NETWORKAUTH_USERNAME"))
    login.add_argument("--password", default=os.environ.get("NETWORKAUTH_PASSWORD"))
    login.add_argument(
        "--machine-code",
        default=os.environ.get("NETWORKAUTH_MACHINE_CODE", default_machine_code()),
        help="机器码；默认读取 /etc/machine-id，非 Linux 环境回退到主机名",
    )
    login.add_argument(
        "--version",
        default=os.environ.get("NETWORKAUTH_CLIENT_VERSION", "python-api-test/1.0.0"),
        help="客户端版本；API 20 必填",
    )
    login.add_argument("--device-name", default=os.environ.get("NETWORKAUTH_DEVICE_NAME"))
    login.add_argument("--raw", action="store_true", help="不解析不加密返回 data，直接打印信封")

    rebind = subparsers.add_parser(
        "rebind", help="调用 API 51 查询或转绑机器码（不需要登录令牌）"
    )
    common_options(rebind)
    rebind.add_argument("--username", default=os.environ.get("NETWORKAUTH_USERNAME"))
    rebind.add_argument("--password", default=os.environ.get("NETWORKAUTH_PASSWORD"))
    rebind.add_argument(
        "--machine-code",
        default=None,
        help="新机器码；省略时只查询当前绑定设备",
    )
    rebind.add_argument(
        "--replace-machine",
        help="多设备已达上限时，要替换的旧机器码",
    )
    rebind.add_argument("--device-name", default=os.environ.get("NETWORKAUTH_DEVICE_NAME"))
    rebind.add_argument("--raw", action="store_true", help="不解析不加密返回 data，直接打印信封")

    call = subparsers.add_parser("call", help="调用任意公开接口（默认按不加密处理返回）")
    common_options(call)
    call.add_argument("--api-type", type=int, required=True)
    call.add_argument("--data-json", required=True, help="提交给接口的明文 JSON 对象")
    call.add_argument("--raw", action="store_true", help="不解析不加密返回 data，直接打印信封")
    return parser


def run(args: argparse.Namespace) -> int:
    app_uuid = require(args.app_uuid, "--app-uuid/NETWORKAUTH_APP_UUID")
    app_secret = require(args.app_secret, "--app-secret/NETWORKAUTH_APP_SECRET")

    if args.command == "login":
        payload: Dict[str, Any] = {
            "username": require(args.username, "--username/NETWORKAUTH_USERNAME"),
            "password": require(args.password, "--password/NETWORKAUTH_PASSWORD"),
            "machine_code": args.machine_code,
            "version": args.version,
        }
        if args.device_name:
            payload["device_name"] = args.device_name
        api_type = 20
    elif args.command == "rebind":
        payload = {
            "username": require(args.username, "--username/NETWORKAUTH_USERNAME"),
            "password": require(args.password, "--password/NETWORKAUTH_PASSWORD"),
        }
        if args.machine_code:
            payload["machine_code"] = args.machine_code
        if args.replace_machine:
            payload["replace_machine"] = args.replace_machine
        if args.device_name:
            payload["device_name"] = args.device_name
        api_type = 51
    else:
        payload = parse_json_object(args.data_json, "--data-json")
        api_type = args.api_type

    data = compact_json(payload)
    response = call_open_api(
        base_url=args.base_url,
        app_uuid=app_uuid,
        app_secret=app_secret,
        api_type=api_type,
        data=data,
        timeout=args.timeout,
        user_agent=args.user_agent,
    )
    if not args.raw and response.get("code") == 0:
        response = decode_none_response(response)
    print(json.dumps(response, ensure_ascii=False, indent=2))
    return 0 if response.get("code") == 0 else 1


def main() -> int:
    args = build_parser().parse_args()
    try:
        return run(args)
    except (RuntimeError, ValueError) as exc:
        print(f"networkauth-api: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
