#!/usr/bin/env python3
"""Inject keys on MiSTer via /dev/uinput (armv7l).

Usage:  mkeys2.py <action> [...]
  enter, f10, f11, down, up, left, right, space, esc ...   named key tap
  shift+down                                               chord
  type:PRINT IN 31472                                      type a literal string
  sleep:1.5                                                pause
Env: HOLD (key hold, default 0.25 s), GAP (default 0.15 s), SETTLE (default 4 s)
"""
import fcntl, os, struct, sys, time

UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
EV_SYN, EV_KEY, SYN_REPORT = 0, 1, 0
EV_REP, EV_MSC, EV_LED = 0x14, 0x04, 0x11

K = {}
for i, c in enumerate("abcdefghijklmnopqrstuvwxyz"):
    K[c] = [30,48,46,32,18,33,34,35,23,36,37,38,50,49,24,25,16,19,31,20,22,47,17,45,21,44][i]
for i, c in enumerate("1234567890"):
    K[c] = 2 + i
K.update({'space':57,'enter':28,'bs':14,'esc':1,'tab':15,
          'minus':12,'equal':13,'lbrace':26,'rbrace':27,'semi':39,'quote':40,
          'grave':41,'backslash':43,'comma':51,'dot':52,'slash':53,
          'shift':42,'ctrl':29,'alt':56,'caps':42,
          'up':103,'down':108,'left':105,'right':106,
          'f1':59,'f2':60,'f3':61,'f4':62,'f5':63,'f6':64,'f7':65,'f8':66,
          'f9':67,'f10':68,'f11':87,'f12':88})

# printable char -> (shift?, key name)
CHARS = {' ': (0,'space'), '\n': (0,'enter')}
for c in "abcdefghijklmnopqrstuvwxyz0123456789":
    CHARS[c] = (0, c)
for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
    CHARS[c] = (1, c.lower())
CHARS.update({'-':(0,'minus'), '=':(0,'equal'), ';':(0,'semi'), "'":(0,'quote'),
              ',':(0,'comma'), '.':(0,'dot'), '/':(0,'slash'),
              '(':(1,'9'), ')':(1,'0'), '+':(1,'equal'), ':':(1,'semi'),
              '"':(1,'quote'), '*':(1,'8'), '<':(1,'comma'), '>':(1,'dot'),
              '?':(1,'slash'), '#':(1,'3'), '$':(1,'4'), '%':(1,'5'), '@':(1,'2'),
              '!':(1,'1'), '&':(1,'7'), '^':(1,'6')})

HOLD = float(os.environ.get('HOLD', '0.25'))
GAP  = float(os.environ.get('GAP',  '0.15'))

fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
for e in (EV_KEY, EV_REP, EV_MSC, EV_LED):
    fcntl.ioctl(fd, UI_SET_EVBIT, e)
for kc in range(1, 249):
    fcntl.ioctl(fd, UI_SET_KEYBIT, kc)
dev = struct.pack('80s4HI', b'MiSTer Remote Keyboard', 0x03, 0x046d, 0xc31c, 0x0110, 0) + b'\0' * (64*4*4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(float(os.environ.get('SETTLE', '4')))

def ev(t, c, v):
    os.write(fd, struct.pack('llHHi', 0, 0, t, c, v))

def press(codes):
    for c in codes: ev(EV_KEY, c, 1)
    ev(EV_SYN, SYN_REPORT, 0); time.sleep(HOLD)
    for c in reversed(codes): ev(EV_KEY, c, 0)
    ev(EV_SYN, SYN_REPORT, 0); time.sleep(GAP)

def tap_named(spec):
    parts = spec.split('+')
    codes = [K[p] for p in parts]
    press(codes)

for a in sys.argv[1:]:
    if a.startswith('sleep:'):
        time.sleep(float(a.split(':', 1)[1]))
    elif a.startswith('type:'):
        for ch in a.split(':', 1)[1]:
            if ch not in CHARS:
                print('skip char', repr(ch)); continue
            sh, name = CHARS[ch]
            press(([K['shift']] if sh else []) + [K[name]])
    else:
        n = 1
        if '*' in a: a, n = a.split('*'); n = int(n)
        for _ in range(n): tap_named(a)

print("sent:", ' '.join(sys.argv[1:]))
time.sleep(1.0)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
