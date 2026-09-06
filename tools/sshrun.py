#!/usr/bin/env python3
"""Run ssh/scp with a password over a pty (no sshpass available)."""
import os, pty, sys, select, time
PW = b"1\n"
def run(argv, timeout=60):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(argv[0], argv); os._exit(1)
    buf = b""; sent = False; t0 = time.time()
    while time.time() - t0 < timeout:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try: chunk = os.read(fd, 4096)
            except OSError: break
            if not chunk: break
            buf += chunk
            low = buf.lower()
            if not sent and (b"password:" in low or b"passphrase" in low):
                os.write(fd, PW); sent = True
            if b"(yes/no" in low or b"fingerprint" in low and b"yes/no" in low:
                os.write(fd, b"yes\n")
        else:
            try: 
                if os.waitpid(pid, os.WNOHANG)[0]: break
            except ChildProcessError: break
    try: _, status = os.waitpid(pid, 0)
    except ChildProcessError: status = 0
    os.close(fd)
    return os.waitstatus_to_exitcode(status) if status else 0, buf.decode(errors="replace")
if __name__ == "__main__":
    rc, out = run(sys.argv[1:])
    print(out)
    sys.exit(rc)
