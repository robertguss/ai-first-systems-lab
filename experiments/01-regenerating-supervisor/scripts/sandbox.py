"""Fail-closed Linux namespaces, bounded process capture, and allowlisted CONNECT."""
import contextlib
import os
from pathlib import Path
import selectors
import shutil
import signal
import socket
import socketserver
import subprocess
import tempfile
import threading
import time


class SandboxError(RuntimeError):
    pass


def tunnel(a, b):
    with selectors.DefaultSelector() as poll:
        poll.register(a, selectors.EVENT_READ, b)
        poll.register(b, selectors.EVENT_READ, a)
        while True:
            ready = poll.select(60)
            if not ready:
                return
            for key, _ in ready:
                data = key.fileobj.recv(65536)
                if not data:
                    return
                key.data.sendall(data)


class ConnectServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


class ConnectHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(15)
            header = b""
            while b"\r\n\r\n" not in header and len(header) <= 16384:
                chunk = self.request.recv(1)
                if not chunk:
                    return
                header += chunk
            method, target, version = header.split(b"\r\n", 1)[0].decode("ascii").split()
            host, port = target.rsplit(":", 1)
            if (method != "CONNECT" or version not in ("HTTP/1.0", "HTTP/1.1")
                    or port != "443" or host.lower() not in self.server.hosts):
                self.request.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
                return
            with socket.create_connection((host, 443), timeout=15) as upstream:
                self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                tunnel(self.request, upstream)
        except (OSError, ValueError, UnicodeError):
            return


# This relay executes INSIDE the network/PID/mount namespaces. It has no host
# networking: its sole egress is the host-side CONNECT policy through one socket.
RELAY = r'''
import socket, socketserver, threading, selectors, subprocess, sys
class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            with socket.socket(socket.AF_UNIX) as remote:
                remote.connect('/bridge/proxy.sock')
                with selectors.DefaultSelector() as poll:
                    poll.register(self.request, 1, remote)
                    poll.register(remote, 1, self.request)
                    while True:
                        for key, _ in poll.select():
                            data = key.fileobj.recv(65536)
                            if not data: return
                            key.data.sendall(data)
        except OSError: pass
class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
server = Server(('127.0.0.1', 18080), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
sys.exit(subprocess.call(sys.argv[1:]))
'''


@contextlib.contextmanager
def proxy(hosts):
    with tempfile.TemporaryDirectory(prefix="repair-proxy-") as directory:
        path = str(Path(directory) / "proxy.sock")
        server = ConnectServer(path, ConnectHandler)
        server.hosts = {host.lower() for host in hosts}
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield path
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


def run(workspace, argv, *, credentials=None, hosts=(), timeout=180,
        max_output=2_000_000):
    """Return mechanically captured output; never fall back to host execution."""
    bwrap = shutil.which("bwrap")
    if not bwrap:
        raise SandboxError("bubblewrap is required; no non-isolated fallback exists")
    credentials = credentials or {}
    with (proxy(hosts) if hosts else contextlib.nullcontext(None)) as bridge:
        command = [bwrap, "--unshare-all", "--die-with-parent", "--new-session",
                   "--clearenv"]
        for directory in ("/usr", "/bin", "/lib", "/lib64", "/opt/regenerator-tools"):
            if Path(directory).exists():
                command += ["--ro-bind", directory, directory]
        # Host-local tooling/configuration is not part of the system runtime.
        command += ["--tmpfs", "/usr/local", "--remount-ro", "/usr/local"]
        if Path("/etc/ssl/certs").exists():
            command += ["--ro-bind", "/etc/ssl/certs", "/etc/ssl/certs"]
        command += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
                    "--tmpfs", "/home", "--dir", "/home/agent",
                    "--bind", str(Path(workspace).resolve()), "/workspace",
                    "--chdir", "/workspace"]
        env = {"HOME": "/home/agent", "TMPDIR": "/tmp", "LANG": "C.UTF-8",
               "PATH": "/opt/regenerator-tools/bin:/usr/bin:/bin",
               "ERL_FLAGS": "+S 2:2"}
        if bridge:
            command += ["--ro-bind", bridge, "/bridge/proxy.sock"]
            env.update({"HTTPS_PROXY": "http://127.0.0.1:18080",
                        "HTTP_PROXY": "http://127.0.0.1:18080",
                        "https_proxy": "http://127.0.0.1:18080",
                        "http_proxy": "http://127.0.0.1:18080"})
            env.update(credentials)
            argv = ["/usr/bin/python3", "-c", RELAY, *argv]
        elif credentials:
            raise SandboxError("credentials require an explicitly configured proxy")
        for name, value in env.items():
            command += ["--setenv", name, value]
        command += ["--", *argv]
        start = time.monotonic()
        process = subprocess.Popen(command, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                   start_new_session=True, env={})
        output = bytearray()
        error = ""
        with selectors.DefaultSelector() as poll:
            poll.register(process.stdout, selectors.EVENT_READ)
            while poll.get_map():
                if time.monotonic() - start > timeout:
                    error = f"sandbox exceeded {timeout}s timeout"
                    break
                for key, _ in poll.select(0.1):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        poll.unregister(key.fileobj)
                    else:
                        room = max_output - len(output)
                        output.extend(chunk[:room])
                        if len(chunk) > room:
                            error = f"sandbox exceeded {max_output} byte output limit"
                            break
                if error:
                    break
        if not error:
            try:
                process.wait(timeout=max(0.01, timeout - (time.monotonic() - start)))
            except subprocess.TimeoutExpired:
                error = f"sandbox exceeded {timeout}s timeout"
        # Killing bubblewrap also tears down the entire private PID namespace.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        code = process.wait()
        process.stdout.close()
        return {"exit_code": code, "output": output.decode("utf-8", "replace"),
                "error": error}
