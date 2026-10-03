# Créditos de terceros

Nook utiliza estas dependencias. Sus licencias pertenecen a sus autores y se conservan por separado de la del código propio de Nook.

| Dependencia | Uso | Licencia y avisos |
| --- | --- | --- |
| [SwiftTerm 1.10.1](https://github.com/migueldeicaza/SwiftTerm) | Emulador de terminal y PTY. | [Texto de licencia](docs/licenses/SwiftTerm.txt), MIT. |
| [tmux 3.5a](https://github.com/tmux/tmux/tree/3.5a) | Sesiones propias compartidas. | [Aviso de licencia](Vendor/TMUX-LICENSE). Los archivos fuente tienen sus propios avisos, normalmente ISC. |
| [libevent](https://libevent.org/) | Dependencia de tmux. | [Licencias y avisos](docs/licenses/libevent.txt); el proyecto contiene archivos bajo distintas licencias. |

`Scripts/build-app.sh` incluye avisos de terceros dentro de `Nook.app/Contents/Resources/Licenses`. El repositorio distribuye el código de Nook y los scripts para reconstruir las dependencias, no el binario local de tmux.

SwiftUI, AppKit, AVFoundation, Speech y Core Animation forman parte de los frameworks del sistema de Apple.

Claude Code y Codex son herramientas externas. Nook usa sus CLI y sesiones existentes; no incluye sus modelos ni credenciales. Nook es un proyecto independiente, sin afiliación oficial con Apple, Anthropic u OpenAI.
