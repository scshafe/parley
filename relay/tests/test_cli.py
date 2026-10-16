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


import pytest  # noqa: E402

from parley_relay.cli import main, parse_hosts, url_for  # noqa: E402


def test_hosts_one_name_or_several_literals():
    assert parse_hosts("localhost") == ["localhost"]
    assert parse_hosts("10.253.92.11, 127.0.0.1") == ["10.253.92.11", "127.0.0.1"]
    for bad in ("localhost,127.0.0.1", "127.0.0.1,127.0.0.1", " , "):
        with pytest.raises(ValueError):
            parse_hosts(bad)
    assert url_for("::1", 8765) == "http://[::1]:8765" and url_for("127.0.0.1", 1) == "http://127.0.0.1:1"


def test_a_bad_host_list_is_a_clean_usage_error(capsys):
    with pytest.raises(SystemExit) as exc:
        main(["--dev", "--host", "localhost,127.0.0.1"])
    assert exc.value.code == 2
    assert "each must be an IP address" in capsys.readouterr().err
