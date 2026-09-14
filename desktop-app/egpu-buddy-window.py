#!/usr/bin/env python3
"""EGPU Buddy desktop window: GTK4 + WebKitGTK 6.0 around the local page. Usage: egpu-buddy-window.py <url>"""
import sys, signal, os
os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
import gi; gi.require_version("Gtk", "4.0"); gi.require_version("WebKit", "6.0")
from gi.repository import Gtk, WebKit
URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8772/"
class App(Gtk.Application):
    def __init__(self): super().__init__(application_id="io.github.denver8989.EGPUBuddy")
    def do_activate(self):
        win = Gtk.ApplicationWindow(application=self, title="EGPU Buddy"); win.set_default_size(900, 640)
        web = WebKit.WebView(); web.load_uri(URL); win.set_child(web); win.present()
if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.SIG_DFL); sys.exit(App().run(None))
