#!/usr/bin/env python3
"""Stands in for lsblk, findmnt, blkid, swapon and readlink, answering from a JSON fixture.

Called as: fake_blockdev.py <tool> [args...]
Environment:
  FAKE_FIXTURE  path of the fixture, re-read on every call so a test can change
                the machine's state between two commands
  FAKE_STATE    directory where the parted stub leaves a partitioned-<disk> marker

Fixture format:
  root_source   what `findmnt -T /` reports
  devices       device tree. Each node has name, type, optional size, model, serial,
                tran, fstype, pttype, label, mountpoint, uuid, partuuid, partlabel, children.
                A node may appear under several parents (RAID, multi-PV LVM).
  mounts        extra sources for `findmnt -rn -o SOURCE`
  swaps         active swap devices
  fstab         SOURCE column of /etc/fstab
  blkid_rc      {device: [exit code, output]} to override the blkid result
  symlinks      {path: target} for `readlink -f`. A path under a known directory
                that isn't listed resolves to itself. A path listed as null exits 1.
  fail          {tool or "findmnt_root": exit code} to make a call fail
"""
import json
import os
import sys

FIELDS = {
    'NAME': 'name', 'TYPE': 'type', 'SIZE': 'size', 'MODEL': 'model',
    'SERIAL': 'serial', 'TRAN': 'tran', 'FSTYPE': 'fstype', 'LABEL': 'label',
    'MOUNTPOINT': 'mountpoint', 'UUID': 'uuid', 'PARTUUID': 'partuuid',
    'PARTLABEL': 'partlabel',
}


def load():
    with open(os.environ['FAKE_FIXTURE']) as f:
        return json.load(f)


def walk(nodes, parent=None):
    for node in nodes:
        yield node, parent
        yield from walk(node.get('children', []), node)


def add_created_partitions(fixture):
    """A disk the parted stub has partitioned gets one partition."""
    state = os.environ.get('FAKE_STATE', '')
    for node in fixture['devices']:
        base = node['name'].rsplit('/', 1)[-1]
        if state and os.path.exists(os.path.join(state, 'partitioned-' + base)):
            sep = 'p' if base.startswith(('nvme', 'mmcblk')) else ''
            node['children'] = [{
                'name': node['name'] + sep + '1', 'type': 'part', 'size': node.get('size', ''),
                'uuid': fixture.get('created_uuid', 'abcd-1234'),
            }]


def parse_flags(args):
    """Parses lsblk-style options, including clusters such as -nrp and -no COLS."""
    flags, columns, devices = set(), None, []
    i = 0
    while i < len(args):
        arg = args[i]
        i += 1
        if arg.startswith('--'):
            flags.add(arg)
        elif arg.startswith('-') and len(arg) > 1:
            for pos, letter in enumerate(arg[1:]):
                if letter == 'o':
                    rest = arg[pos + 2:]
                    if rest:
                        columns = rest
                    else:
                        columns = args[i]
                        i += 1
                    break
                flags.add(letter)
        else:
            devices.append(arg)
    return flags, columns, devices


def value(node, column, parents):
    if column == 'PKNAME':
        return parents.get(node['name'], [''])[0]
    return node.get(FIELDS[column]) or ''


def escape_pairs(text):
    return text.replace('\\', '\\x5c').replace('"', '\\x22')


def escape_raw(text):
    return text.replace('\\', '\\x5c').replace(' ', '\\x20')


def lsblk(args):
    fixture = load()
    if 'lsblk' in fixture.get('fail', {}):
        print('lsblk: failed', file=sys.stderr)
        return fixture['fail']['lsblk']
    add_created_partitions(fixture)
    flags, columns, devices = parse_flags(args)
    columns = (columns or 'NAME,TYPE').split(',')

    by_name, parents = {}, {}
    for node, parent in walk(fixture['devices']):
        by_name[node['name']] = node
        if parent is not None:
            parents.setdefault(node['name'], [])
            if parent['name'] not in parents[node['name']]:
                parents[node['name']].append(parent['name'])

    rows = []

    def descend(node):
        rows.append(node)
        if 'd' not in flags:
            for child in node.get('children', []):
                descend(child)

    def ascend(node):
        rows.append(node)
        for name in parents.get(node['name'], []):
            ascend(by_name[name])

    if devices:
        for device in devices:
            if device not in by_name:
                print(f'lsblk: {device}: not a block device', file=sys.stderr)
                return 32
            (ascend if 's' in flags else descend)(by_name[device])
    else:
        for node in fixture['devices']:
            descend(node)

    for node in rows:
        values = [value(node, c, parents) for c in columns]
        if 'P' in flags:
            print(' '.join(f'{c}="{escape_pairs(v)}"' for c, v in zip(columns, values)))
        elif 'r' in flags:
            print(' '.join(escape_raw(v) for v in values))
        else:
            print(' '.join(values))
    return 0


def findmnt(args):
    fixture = load()
    fail = fixture.get('fail', {})
    if '-T' in args:
        if 'findmnt_root' in fail:
            return fail['findmnt_root']
        print(fixture['root_source'])
        return 0
    if '--fstab' in args:
        entries = fixture.get('fstab', [])
        for entry in entries:
            print(entry)
        return 0 if entries else 1
    if 'findmnt' in fail:
        return fail['findmnt']
    for node, _ in walk(fixture['devices']):
        if node.get('mountpoint') and node['mountpoint'] != '[SWAP]':
            print(node['name'])
    for source in fixture.get('mounts', []):
        print(source)
    return 0


def swapon(args):
    fixture = load()
    if 'swapon' in fixture.get('fail', {}):
        return fixture['fail']['swapon']
    for name in fixture.get('swaps', []):
        print(name)
    return 0


def blkid(args):
    fixture = load()
    add_created_partitions(fixture)
    device = args[-1]
    by_name = {node['name']: node for node, _ in walk(fixture['devices'])}
    if '-s' in args:
        node = by_name.get(device)
        if node and node.get('uuid'):
            print(node['uuid'])
            return 0
        return 2
    override = fixture.get('blkid_rc', {}).get(device)
    if override:
        if override[1]:
            print(override[1], file=sys.stderr)
        return override[0]
    node = by_name.get(device)
    if node is None:
        print(f'error: {device}: No such file or directory', file=sys.stderr)
        return 2
    lines = []
    if node.get('fstype'):
        lines.append('TYPE=' + node['fstype'])
    if node.get('pttype'):
        lines.append('PTTYPE=' + node['pttype'])
    if not lines:
        return 2
    print('DEVNAME=' + device)
    for line in lines:
        print(line)
    return 0


def readlink(args):
    fixture = load()
    if 'readlink' in fixture.get('fail', {}):
        return fixture['fail']['readlink']
    if args[:2] != ['-f', '--'] or len(args) != 3:
        print(f'fake readlink: unexpected arguments: {args}', file=sys.stderr)
        return 99
    path = args[2]
    links = fixture.get('symlinks', {})
    if path in links and links[path] is None:
        return 1
    print(links.get(path, path))
    return 0


TOOLS = {'lsblk': lsblk, 'findmnt': findmnt, 'swapon': swapon, 'blkid': blkid, 'readlink': readlink}

if __name__ == '__main__':
    sys.exit(TOOLS[sys.argv[1]](sys.argv[2:]))
