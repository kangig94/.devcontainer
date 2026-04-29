import os

c = get_config()  # noqa: F821  (provided by jupyter at load time)

c.ServerApp.ip = "0.0.0.0"
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.allow_remote_access = True
c.ServerApp.token = ""
c.ServerApp.password = ""
c.ServerApp.disable_check_xsrf = True
c.ServerApp.root_dir = os.environ.get("HOME", "/home/dev")
c.ServerApp.allow_root = os.getuid() == 0
