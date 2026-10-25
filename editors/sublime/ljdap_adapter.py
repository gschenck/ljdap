"""ljdap-Adapter für das Sublime-Text-Paket „Debugger“ (daveleroy).

Verbindet den Debugger per TCP mit ljdap im Lua-Programm. ljdap ist selbst
der DAP-Server; dieses Plugin startet keinen Prozess.

Installation: Ordner editors/sublime als Packages/ljdap/ kopieren
(Preferences → Browse Packages…). Die Datei .python-version muss mit:
das Debugger-Paket läuft im Python-3.8-Plugin-Host, und Plugins in
verschiedenen Hosts sehen sich nicht.

Konfiguration im .sublime-project:

    "debugger_configurations": [
        { "name": "ljdap", "type": "ljdap", "request": "attach",
          "host": "127.0.0.1", "port": 4711 }
    ]

Registrierung erst in plugin_loaded(): Das Debugger-Paket löscht beim
(Neu-)Laden seine Untermodule aus sys.modules; ein früher registrierter
Adapter ginge dabei verloren.
"""

import sublime  # noqa: F401  (stellt sicher, dass wir in Sublime laufen)

VERSION = "0.1.0-dev"
DOCS = "https://github.com/gschenck/ljdap"

SNIPPETS = [
    {
        "label": "ljdap: an Lua-Programm anhängen",
        "body": {
            "name": "ljdap",
            "type": "ljdap",
            "request": "attach",
            "host": "127.0.0.1",
            "port": 4711,
        },
    },
]

SCHEMA = {
    "attach": {
        "properties": {
            "host": {"type": "string", "default": "127.0.0.1",
                     "description": "Adresse, an der ljdap im Programm lauscht"},
            "port": {"type": "number", "default": 4711,
                     "description": "Port von ljdap (LJDAP=\"port=…\")"},
            "timeout": {"type": "number", "default": 5,
                        "description": "Sekunden, die auf die Verbindung gewartet wird"},
            "stopOnEntry": {"type": "boolean", "default": False,
                            "description": "Mit wait=1: an der ersten Zeile anhalten"},
            "pathMappings": {
                "type": "array",
                "description": "Pfadzuordnung Editor ↔ Programm (z. B. Programm auf einem Server)",
                "items": {
                    "type": "object",
                    "properties": {
                        "localRoot": {"type": "string"},
                        "remoteRoot": {"type": "string"},
                    },
                },
            },
        },
    },
}

_registered = []


def _register(dap):
    """Erzeugt und registriert die Adapterklasse (Metaklasse des Debuggers)."""

    class LjdapInstaller(dap.AdapterInstaller):
        type = "ljdap"

        def installed_version(self):
            return VERSION

        async def installable_versions(self, log):
            return []

        def configuration_snippets(self, schema_type=None):
            return SNIPPETS

        def configuration_schema(self, schema_type=None):
            return SCHEMA

    class Ljdap(dap.Adapter):
        type = "ljdap"
        docs = DOCS
        installer = LjdapInstaller()

        async def start(self, console, configuration):
            host = configuration.get("host") or "127.0.0.1"
            port = int(configuration.get("port") or 4711)
            timeout = int(configuration.get("timeout") or 5)
            return dap.SocketTransport(host=host, port=port, timeout=timeout)

    return Ljdap


def plugin_loaded():
    try:
        from Debugger.modules import dap
    except ImportError as e:
        print("ljdap: Paket „Debugger“ nicht gefunden oder anderer Plugin-Host:", e)
        return
    _registered.append(_register(dap))
    print("ljdap: Adapter „ljdap“ registriert (" + VERSION + ")")
