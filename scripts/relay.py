#!/usr/bin/env python3
"""127.0.0.1:8100 -> phone:8100.

The cable is one way to reach the agent; the phone's own address on the local
network is the other, and it is the one that lets the phone leave the desk.
Between them sits whatever cannot open a socket to the LAN directly — here, the
sandbox this project's tooling runs under, which permits localhost and refuses
everything else.

Not part of the product. `iproxy` does this over USB and Hands takes an address
either way (`NUBI_WDA_URL`); this exists so the wireless path can be used from
an environment that only speaks to localhost.

    python3 scripts/relay.py 192.168.0.10
"""
import socket
import sys
import threading

LISTEN = ("127.0.0.1", 8100)


def pump(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            dst.sendall(chunk)
    except OSError:
        pass
    finally:
        # Half-close so the other side sees the end rather than hanging on a
        # socket nobody will write to again.
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve(phone: tuple[str, int]) -> None:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(LISTEN)
    listener.listen(64)
    print(f"relay {LISTEN[0]}:{LISTEN[1]} -> {phone[0]}:{phone[1]}", flush=True)

    while True:
        near, _ = listener.accept()
        try:
            far = socket.create_connection(phone, timeout=10)
        except OSError as err:
            print(f"  cannot reach {phone[0]}: {err}", flush=True)
            near.close()
            continue
        # A reading dump is megabytes and takes half a minute; nothing here
        # should decide it has waited long enough.
        near.settimeout(None)
        far.settimeout(None)
        for a, b in ((near, far), (far, near)):
            threading.Thread(target=pump, args=(a, b), daemon=True).start()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: relay.py <phone-ip> [port]")
    serve((sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 8100))
