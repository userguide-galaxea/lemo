#!/usr/bin/env bash
# Standalone: copy this file to either device; only system Python 3 is needed.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import ipaddress
import json
import os
import shlex
import shutil
import subprocess
import sys
import time


def run(args, check=True):
    result = subprocess.run(args, text=True, capture_output=True,
                            env=dict(os.environ, LC_ALL='C'))
    if check and result.returncode:
        raise RuntimeError(f"命令失败：{shlex.join(args)}\n{result.stderr.strip()}")
    return result


def inspect_interfaces():
    rows = run(['nmcli', '-t', '-f', 'DEVICE,TYPE,STATE', 'device', 'status']).stdout.splitlines()
    ethernet = {}
    for row in rows:
        fields = row.split(':', 2)
        if len(fields) == 3 and fields[1] == 'ethernet':
            ethernet[fields[0]] = fields[2]
    links = {link['ifname']: link for link in json.loads(run(['ip', '-j', 'link', 'show']).stdout)}
    linked = {name for name in ethernet if 'LOWER_UP' in links.get(name, {}).get('flags', [])}
    return ethernet, links, linked


def describe_interfaces(ethernet, links):
    lines = ['有线网口：']
    if not ethernet:
        lines.append('  未检测到网卡，请检查设备连接和驱动。')
    for name, state in ethernet.items():
        flags = links.get(name, {}).get('flags', [])
        enabled = '已启用' if 'UP' in flags else '未启用'
        carrier = '有物理链路' if 'LOWER_UP' in flags else '无物理链路'
        lines.append(f'  {name}: {enabled}；{carrier}；NetworkManager={state}；flags={",".join(flags) or "未知"}')
    if ethernet and not any('LOWER_UP' in links.get(name, {}).get('flags', []) for name in ethernet):
        lines.append('请检查网口是否启用、网线连接及对端供电。')
    return '\n'.join(lines)


def protected_interfaces(routes):
    protected = {}
    ssh = os.environ.get('SSH_CONNECTION', '').split()
    if ssh:
        family = '-6' if ':' in ssh[0] else '-4'
        route = json.loads(run(['ip', '-j', family, 'route', 'get', ssh[0]]).stdout)
        if not route or not route[0].get('dev'):
            raise RuntimeError('无法确定当前 SSH 所用网口，停止自动配置。')
        protected[route[0]['dev']] = '当前 SSH 连接'
    if any(route.get('dst') == 'default' for route in routes):
        uplink = json.loads(run(['ip', '-j', '-4', 'route', 'get', '1.1.1.1']).stdout)
        if not uplink or not uplink[0].get('dev'):
            raise RuntimeError('无法确定当前上网网口，停止自动配置。')
        device = uplink[0]['dev']
        protected[device] = protected.get(device, '') + ('、' if device in protected else '') + '当前实际上网连接'
    return protected


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, f'[error] {message}\n')


def main():
    parser = ArgumentParser(prog='ethernet_setup.sh', description='配置 LEMO 有线直连网络。')
    parser.add_argument('--role', required=True, choices=['server', 'lemo'],
                        help='server：算力平台；lemo：机器人平台')
    parser.add_argument('--interface', help='指定有线网口；自动选择时排除 SSH、上网及未管理的网口')
    parser.add_argument('--subnet', default='192.168.88.0/24', help='两端必须一致，默认 192.168.88.0/24')
    parser.add_argument('--check', action='store_true', help='检查地址、路由和连通性，不修改配置')
    parser.add_argument('--dry-run', action='store_true', help='预览配置，不修改网络')
    parser.add_argument('--diagnose', action='store_true', help='只列出各有线网口的启用状态、物理链路及 NetworkManager 状态')
    parser.add_argument('--wait-link', type=int, default=5, metavar='秒', help='等待网口出现和链路协商的时间，0–60 秒，默认 5 秒')
    args = parser.parse_args()
    if not 0 <= args.wait_link <= 60:
        parser.error('--wait-link 必须为 0–60 秒')
    for tool in ['nmcli', 'ip'] + ([] if args.diagnose else ['ping']):
        if not shutil.which(tool):
            if tool == 'ping':
                raise RuntimeError('缺少连通性检查工具，请安装 iputils 工具包。')
            raise RuntimeError(f'缺少 {tool}，请先安装对应系统工具。')
    if sys.platform != 'linux':
        raise RuntimeError('本脚本只支持使用 NetworkManager 的 Linux 设备。')
    ethernet, links, linked = inspect_interfaces()
    if args.diagnose:
        print(describe_interfaces(ethernet, links))
        return 0 if linked else 2
    try:
        network = ipaddress.IPv4Network(args.subnet, strict=True)
    except ValueError as error:
        raise RuntimeError(f'无效的 IPv4 网段：{error}')
    private_ranges = [ipaddress.IPv4Network(cidr) for cidr in ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']]
    if network.prefixlen > 30 or not any(network.subnet_of(block) for block in private_ranges):
        raise RuntimeError('请使用至少有两个可用主机地址的私有 IPv4 网段。')
    server, lemo = str(network.network_address + 1), str(network.network_address + 2)
    local, peer = (server, lemo) if args.role == 'server' else (lemo, server)
    address = f'{local}/{network.prefixlen}'

    routes = json.loads(run(['ip', '-j', '-4', 'route', 'show', 'table', 'all']).stdout)
    protected = {} if args.check else protected_interfaces(routes)
    def available():
        return [name for name in ethernet if name in linked
                and name not in protected and ethernet[name] != 'unmanaged']

    wait_seconds = 0 if args.dry_run else args.wait_link
    for attempt in range(wait_seconds):
        has_link = args.interface in linked if args.interface else bool(available())
        if has_link:
            break
        if attempt == 0:
            print(f'等待有线连接（最多 {wait_seconds} 秒）', flush=True)
        time.sleep(1)
        ethernet, links, linked = inspect_interfaces()
    # Refresh routes after waiting; an interface may have become the uplink.
    routes = json.loads(run(['ip', '-j', '-4', 'route', 'show', 'table', 'all']).stdout)
    protected = {} if args.check else protected_interfaces(routes)
    candidates = available()
    for name in ethernet:
        if name in linked and name in protected:
            print(f'跳过 {name}：{protected[name]}', flush=True)
    if args.interface:
        if args.interface not in ethernet:
            raise RuntimeError(f'{args.interface} 不在 NetworkManager 的有线网口列表中。\n{describe_interfaces(ethernet, links)}')
        interface = args.interface
        if interface not in linked:
            raise RuntimeError(f'{interface} 未检测到物理链路。\n{describe_interfaces(ethernet, links)}')
        if interface in protected:
            raise RuntimeError(f'{interface} 用于{protected[interface]}，不会修改；请指定其他直连网口。')
    elif len(candidates) == 1:
        interface = candidates[0]
    elif not candidates:
        if linked:
            raise RuntimeError('没有可自动配置的空闲有线网口：已接通的网口用于 SSH、上网或未由 NetworkManager 管理。'
                               '\n请将另一有线网口接到对端，或改用 Wi-Fi SSH 后重试。\n' + describe_interfaces(ethernet, links))
        raise RuntimeError(f'未检测到有物理链路的有线网口。\n{describe_interfaces(ethernet, links)}')
    else:
        raise RuntimeError(f'排除 SSH 和上网网口后，仍有多个候选有线网口：{", ".join(candidates)}。请用 --interface 指定直连网口。')

    if ethernet[interface] == 'unmanaged':
        raise RuntimeError(f'{interface} 有物理链路但未由 NetworkManager 管理，请先核对系统网络管理方式。')

    for route in routes:
        destination = route.get('dst', 'default')
        if destination == 'default' or route.get('dev') in (interface, 'lo'):
            continue
        try:
            overlap = network.overlaps(ipaddress.IPv4Network(destination, strict=False))
        except ValueError:
            continue
        if overlap:
            raise RuntimeError(f'网段冲突：{destination} 已用于 {route.get("dev", "其他路由")}。两端请统一指定其他 --subnet。')
    # Never reconfigure the interface carrying this SSH session or Internet traffic.
    if not args.check:
        ssh = os.environ.get('SSH_CONNECTION', '').split()
        if ssh:
            family = '-6' if ':' in ssh[0] else '-4'
            route = json.loads(run(['ip', '-j', family, 'route', 'get', ssh[0]]).stdout)
            if route and route[0].get('dev') == interface:
                raise RuntimeError(f'当前 SSH 正通过 {interface}，请改用 Wi-Fi SSH 或本机终端再配置。')
        if any(route.get('dst') == 'default' and route.get('dev') == interface for route in routes):
            # A factory profile may leave an unused, high-metric default route.
            # Resolve an Internet route without sending packets; do not confuse
            # that standby route with the actual uplink.
            uplink = json.loads(run(['ip', '-j', '-4', 'route', 'get', '1.1.1.1']).stdout)
            if not uplink or not uplink[0].get('dev') or uplink[0]['dev'] == interface:
                raise RuntimeError(f'{interface} 当前实际承载上网路由，请改用独立上网连接后再配置。')
            print(f'{interface} 存在备用默认路由，将切换为直连配置。', flush=True)

    profile = f'lemo-direct-{args.role}'
    print(f'设备：{args.role}；有线网口：{interface}；本端：{address}；对端：{peer}', flush=True)
    options = ['connection.interface-name', interface, 'connection.autoconnect', 'yes',
               'connection.autoconnect-priority', '100', 'ipv4.method', 'manual',
               'ipv4.addresses', address, 'ipv4.gateway', '', 'ipv4.dns', '',
               'ipv4.never-default', 'yes', 'ipv4.route-metric', '100', 'ipv6.method', 'disabled']
    if args.dry_run:
        print(f'预览：启用连接 {profile}，未修改网络。')
        return 0
    if not args.check:
        prefix = [] if os.geteuid() == 0 else ['sudo']
        if prefix:
            if not shutil.which('sudo'):
                raise RuntimeError('配置网络需要 sudo 权限。')
            # Inherit terminal input for the password prompt; never store passwords.
            subprocess.run(['sudo', '-p', 'sudo password: ', '-v'], check=True)
        profiles = run(['nmcli', '-t', '-f', 'UUID,NAME', 'connection', 'show']).stdout.splitlines()
        matches = [line.split(':', 1)[0] for line in profiles if line.split(':', 1)[-1] == profile]
        if len(matches) > 1:
            raise RuntimeError(f'存在多个同名连接 {profile}，请先核对，避免修改错误配置。')
        if matches:
            uuid = matches[0]
            kind = run(['nmcli', '-g', 'connection.type', 'connection', 'show', 'uuid', uuid]).stdout.strip()
            if kind != '802-3-ethernet':
                raise RuntimeError(f'{profile} 不是有线连接，停止配置。')
            run(prefix + ['nmcli', 'connection', 'modify', 'uuid', uuid] + options)
            target = ['uuid', uuid]
        else:
            run(prefix + ['nmcli', 'connection', 'add', 'type', 'ethernet', 'con-name', profile] + options)
            target = ['id', profile]
        print('启用有线连接', flush=True)
        run(prefix + ['nmcli', '--wait', '20', 'connection', 'up'] + target + ['ifname', interface])

    addresses = json.loads(run(['ip', '-j', '-4', 'addr', 'show', 'dev', interface]).stdout)
    if not any(item.get('local') == local and item.get('prefixlen') == network.prefixlen
               for entry in addresses for item in entry.get('addr_info', [])):
        raise RuntimeError(f'{interface} 尚未配置 {address}，请先运行不带 --check 的配置命令。')
    route = json.loads(run(['ip', '-j', '-4', 'route', 'get', peer]).stdout)
    if not route or route[0].get('dev') != interface or route[0].get('prefsrc') != local:
        raise RuntimeError('到对端的路由或源地址不正确，请检查重复地址和其他路由。')
    print(f'检查连通性：{peer}', flush=True)
    probe = run(['ping', '-n', '-I', interface, '-c', '3', '-W', '1', peer], check=False)
    if probe.returncode:
        print(f'[error] 无法连接 {peer}。本端地址和路由正确，请检查对端配置及接线。', file=sys.stderr)
        return 2
    print('有线通信验证通过。')
    return 0


try:
    sys.exit(main())
except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError) as error:
    print(f'[error] {error}', file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    print('\n已取消。', file=sys.stderr)
    sys.exit(130)
PY
