"""Read-only LLDB probes for extension routing in Curium Build 35.

Import this module into LLDB after attaching to a booted Simulator instance
of Curium and letting it load chrome_framework. Then call
`extension_routing_trace.enable(lldb.debugger, "/absolute/path/trace.jsonl")`
and continue. The callbacks never change registers or execution decisions.
"""
import json
import struct
import time
import lldb

EXPECTED_UUID = '4C4C4483-5555-3144-A14F-B2F89F30C28A'
LOG = None
IDS = {'ddkjiahejlhfcafbddmgiahcphecmpfh': 'uBlock', 'eimadpbcbfnmbkopoojfekhnkhdbieeh': 'Dark Reader'}
PENDING, SEEN = {}, set()

def _reg(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()

def _mem(proc, addr, size):
    status = lldb.SBError()
    data = proc.ReadMemory(addr, size, status)
    return data if status.Success() and len(data) == size else b''

def _extension(proc, address):
    layout = _mem(proc, address, 24)
    if not layout or layout[23] < 128:
        return None
    ptr, length = struct.unpack_from('<QQ', layout)
    if length != 32:
        return None
    return IDS.get(_mem(proc, ptr, length).decode('ascii', 'replace'))

def _owner(proc, map_address, renderer):
    pair = _mem(proc, map_address + 8, 16)
    if not pair:
        return None
    entries, count = struct.unpack('<QQ', pair)
    if count > 16:
        return None
    for entry in range(entries, entries + count * 32, 32):
        key = _mem(proc, entry, 4)
        if key and int.from_bytes(key, 'little', signed=True) == renderer:
            return _extension(proc, entry + 8)
    return None

def _log(label, name, renderer, owner, accepted=None):
    if renderer == 0xffffffff:
        renderer = -1
    key = label, name, renderer, owner, accepted
    if key in SEEN:
        return
    SEEN.add(key)
    record = dict(hook=label, extension=name, renderer=renderer, accepted=accepted, at=time.time())
    record['frame' if label == 'factory-issuer' else 'owner'] = owner
    with open(LOG, 'a', encoding='utf-8') as sink:
        sink.write(json.dumps(record) + '\n')

def _before(frame, label, post):
    process = frame.GetThread().GetProcess()
    name = _extension(process, _reg(frame, 'x1'))
    if name is None:
        return False
    renderer = _reg(frame, 'w2')
    entry = name, renderer, _owner(process, _reg(frame, 'x0'), renderer)
    PENDING[frame.GetThread().GetThreadID(), post] = entry
    return False

def _after(frame, label, post):
    entry = PENDING.pop((frame.GetThread().GetThreadID(), post), None)
    if entry:
        _log(label, *entry, bool(_reg(frame,'w0') & 1))
    return False

def resource_before(frame, *_):
    return _before(frame, 'resource', 'resource')

def resource_after(frame, *_):
    return _after(frame, 'resource', 'resource')

def worker_before(frame, *_):
    return _before(frame, 'worker-initialize', 'worker')

def worker_after(frame, *_):
    return _after(frame, 'worker-initialize', 'worker')

def insert_before(frame, *_):
    process = frame.GetThread().GetProcess()
    name = _extension(process, _reg(frame, 'x1'))
    if name:
        renderer = _reg(frame, 'w2')
        _log('insert', name, renderer, _owner(process, _reg(frame, 'x0'), renderer))
    return False

def factory_issuer(frame, *_):
    process = frame.GetThread().GetProcess()
    origin = _reg(frame, 'x22')
    if _mem(process, origin + 0x50, 1) != b'\x01':
        return False
    for offset in range(0, 0x50 - 23, 8):
        name = _extension(process, origin + offset)
        if name:
            _log('factory-issuer', name, _reg(frame, 'w21'), str(_reg(frame, 'w20')))
            break
    return False

def enable(debugger, log_path):
    global LOG
    target = debugger.GetSelectedTarget()
    if not target.GetTriple().endswith('-simulator'):
        raise RuntimeError('the extension routing trace only supports Simulator')
    LOG = log_path
    process = target.GetProcess()
    module = next((m for m in target.modules if m.GetFileSpec().GetFilename() == 'chrome_framework'), None)
    if module is None or module.GetUUIDString().upper() != EXPECTED_UUID:
        raise RuntimeError('trace requires the exact Build 35 chrome_framework')
    hooks = {
        0x02c762f8: (0x978d6443, 'factory_issuer'),
        0x06b2d0a0: (0xd10083ff, 'insert_before'),
        0x02777e28: (0x950ed4cf, 'resource_before'),
        0x02777e2c: (0xaa0003f8, 'resource_after'),
        0x06b369b8: (0x97ffd9eb, 'worker_before'),
        0x06b369bc: (0x340003e0, 'worker_after'),
    }
    # These are file addresses from the verified Build 35 link, not pointers
    # into a running process. Check all instructions before arming any probe.
    addresses = []
    for offset, (word, callback) in hooks.items():
        address = module.ResolveFileAddress(offset).GetLoadAddress(target)
        if _mem(process, address, 4) != word.to_bytes(4, 'little'):
            raise RuntimeError(f'instruction mismatch at {offset:#x}')
        addresses.append((address, callback))
    for address, callback in addresses:
        bp = target.BreakpointCreateByAddress(address)
        if not bp.IsValid() or not bp.GetNumLocations():
            raise RuntimeError(f'unresolved breakpoint {address:#x}')
        bp.SetScriptCallbackFunction(f'{__name__}.{callback}')
        bp.SetAutoContinue(True)
    print(f'{len(addresses)} read-only hook sites installed on {EXPECTED_UUID}')
