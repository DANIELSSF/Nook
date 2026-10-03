<div align="center">

<img src="docs/assets/nook-banner.svg" alt="Nook — tu terminal de IA, a un gesto del notch" width="100%">

**Un pequeño gato. Una isla compacta. Tu terminal, siempre a mano.**

![macOS](https://img.shields.io/badge/macOS-27%2B-151719?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![Estado](https://img.shields.io/badge/estado-en_desarrollo-8EC9B4)

[Empezar](#empezar) · [Compilar](#compilar) · [Guía de uso](docs/USAGE.md) · [Desarrollo](docs/DEVELOPMENT.md)

</div>

Nook es una app nativa de macOS que convierte el espacio junto al notch en un lugar para seguir tus sesiones de terminal, escribir a tu IA y enterarte de cuándo necesita tu atención. Acerca el cursor al gato y la isla se despliega desde el borde superior de la pantalla.

<div align="center">

<img src="docs/assets/nook-preview.png" alt="Panel real de Nook desplegado con una sesión de Claude y su campo de escritura" width="572">

<sub>Vista del panel generado por la app con una conversación de prueba.</sub>

</div>

## Tu sesión sigue siendo tuya

- **Conecta una pestaña concreta.** Arrastra el gato a Terminal de macOS o elige la sesión que quieres seguir.
- **Escribe con comodidad.** Mensajes de varias líneas, borradores por pestaña, historial y autocompletado de comandos `/` para Claude Code y Codex.
- **Vuelve a la terminal original.** Un botón muestra su ventana. Cerrar la pestaña en Nook conserva la sesión original.
- **Dale tu estilo.** Nombres propios, colores suaves y ajustes de tamaño y letra.
- **Una mascota con personalidad.** Miradas curiosas, aseo, siestas, juego y celebraciones, con soporte para Reducir movimiento.
- **Sigue el trabajo de Claude.** Conversación, preguntas, permisos, resúmenes y actividad de subagentes.
- **Añade contexto.** Dicta un borrador, pega imágenes o arrastra archivos al mensaje.

También puedes crear sesiones propias compartidas mediante tmux. La isla y la conversación mantienen una superficie oscura que se integra con el notch.

## Empezar

1. Abre Nook y elige **Conectar una terminal…**, o arrastra el gato a una ventana de Terminal.
2. Autoriza el control de Terminal cuando macOS lo solicite.
3. Acerca el cursor al gato para desplegar la isla y haz clic para escribir.

En **Ajustes → Permisos** puedes revisar Automatización, Accesibilidad, micrófono, reconocimiento de voz y avisos de Claude. El dictado prepara un borrador: tú eliges cuándo enviarlo.

## Compilar

La app empaquetada actual requiere **macOS 27 o posterior** y está preparada para **Apple Silicon**. Necesitas Swift 6 / Xcode, las herramientas de línea de comandos y Homebrew.

```sh
git clone https://github.com/DANIELSSF/Nook.git
cd Nook
brew install libevent
bash Scripts/build-app.sh release
open dist/Nook.app
```

La primera compilación descarga SwiftTerm y el código fuente de tmux. El resultado se firma localmente de forma ad hoc; todavía no está notarizado. Los CLI de Claude Code y Codex se instalan y autentican por separado.

## Alcance actual

La conexión directa admite **Terminal de macOS**. iTerm2, Ghostty, Warp y terminales de editores todavía no tienen conexión directa. El espejo refleja texto; las sesiones propias de tmux usan el emulador integrado.

Las funciones de registro de conversación, resumen y subagentes son específicas de Claude Code. Las flechas, Tab, Escape y el pegado directo de imágenes en pestañas externas necesitan Accesibilidad. Consulta la [guía de uso](docs/USAGE.md) para los detalles de cada modo.

## Hecho para macOS

**SwiftUI · AppKit · SwiftTerm · tmux · Speech**

[Arquitectura y pruebas](docs/DEVELOPMENT.md) · [Contribuir](CONTRIBUTING.md) · [Créditos de terceros](THIRD_PARTY_NOTICES.md)

Nook está en desarrollo activo. El código propio todavía no tiene una licencia de redistribución elegida; las dependencias conservan sus licencias originales.
