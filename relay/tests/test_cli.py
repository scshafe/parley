import socket

from parley_relay.cli import listen_socket


def test_listen_socket_binds_one_literal_address():
    sock = listen_socket("127.0.0.1", 0)
    try:
        host, port = sock.getsockname()
        assert host == "127.0.0.1" and port > 0
        assert sock.family == socket.AF_INET and sock.get_inheritable()
        with socket.create_connection((host, port), timeout=2):
            pass
    finally:
        sock.close()
