"""Throwaway FTP / explicit FTPS server for the integration tests (pyftpdlib)."""
import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.servers import FTPServer

root, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
auth = DummyAuthorizer()
auth.add_user("tester", "secret", root, perm="elradfmwMT")
if mode == "tls":
    from pyftpdlib.handlers import TLS_FTPHandler as Handler
    Handler.certfile = sys.argv[4]
    Handler.tls_control_required = True
    Handler.tls_data_required = True
else:
    from pyftpdlib.handlers import FTPHandler as Handler
Handler.authorizer = auth
Handler.passive_ports = range(30000 + (port % 100) * 50, 30000 + (port % 100) * 50 + 50)
FTPServer(("127.0.0.1", port), Handler).serve_forever()
