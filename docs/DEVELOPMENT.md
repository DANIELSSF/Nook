# Desarrollo de Nook

## Requisitos

- macOS 27 o posterior para la app empaquetada actual.
- Apple Silicon, plataforma usada para las compilaciones locales actuales.
- Xcode / Swift 6 y herramientas de línea de comandos.
- Homebrew y `libevent`: `brew install libevent`.
- Internet en la primera compilación para resolver SwiftTerm 1.10.1 y descargar tmux 3.5a.

`Package.swift` declara macOS 14 como base del código, pero `Resources/Info.plist` exige macOS 27 para la app. La base del paquete no equivale a soporte probado en versiones anteriores.

## Compilar

```sh
bash Scripts/build-app.sh
bash Scripts/build-app.sh release
```

El script compila tmux cuando hace falta, construye el ejecutable Swift, copia los recursos y las licencias de terceros y firma `dist/Nook.app` de forma ad hoc. No genera una versión notarizada ni un instalador.

Los binarios de `Vendor/bin/`, las descargas, `.build/` y `dist/` son archivos generados y no se versionan. En un clon nuevo, `bootstrap-tmux.sh` reconstruye el tmux incluido.

## Pruebas

Ejecuta desde la raíz:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --cache-path .build/cache --config-path .build/config \
  --security-path .build/security --disable-sandbox
```

Algunas pruebas crean procesos y sockets locales de tmux. Un entorno que los bloquee puede impedirlas aunque el código compile. Las pruebas de integración con datos simulados no sustituyen una validación con una sesión real de Claude Code o Codex.

Las pruebas de render son opcionales. Para producir muestras con conversaciones sintéticas:

```sh
NOOK_RENDER_DIR="$PWD/.build/renders" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --filter PanelRenderTests \
  --cache-path .build/cache --config-path .build/config \
  --security-path .build/security --disable-sandbox
```

## Arquitectura

| Área | Responsabilidad |
| --- | --- |
| SwiftUI y AppKit | Isla, ventanas, ajustes, foco y geometría del notch. |
| Mascota | Rig vectorial, director de gestos, transiciones y ritmo de dibujo. |
| SwiftTerm y tmux | Emulador, PTY y sesiones propias que pueden compartir varias vistas. |
| TerminalAppBridge | Seguimiento y envío a pestañas de Terminal mediante su TTY. |
| ClaudeTranscript | Lectura incremental del registro local de Claude Code. |
| Parsers e indicadores | Comandos `/`, preguntas, actividad, subagentes y avisos. |
| Speech y AVFoundation | Dictado para preparar borradores. |

Terminal se consulta mediante su diccionario de AppleScript, usando un auxiliar persistente para mantener libre la interfaz. Los controles de teclado que Terminal no expone directamente usan Accesibilidad. Las sesiones propias tienen un socket de tmux separado del servidor del usuario.

Los avisos de Claude usan hooks locales y un socket Unix privado. Activarlos puede modificar la configuración local de Claude, conservando copias de seguridad. El reconocimiento de voz puede usar el servicio de Apple cuando el dispositivo no admite reconocimiento local.

## Catálogos de comandos

`Resources/claude-commands.json` y `Resources/codex-commands.json` se regeneran con `Scripts/update-agent-commands.py`. Revisa el script y sus requisitos antes de ejecutarlo; comprueba los cambios de versión y de comandos antes de publicar una actualización.

## Validación antes de distribuir

Comprueba el panel recogido y desplegado, el envío de texto, `/`, las preguntas interactivas, el cambio de pestaña y los permisos en un Mac real. Usa sesiones de prueba para los controles que pueden ejecutar acciones. Revisa también Reducir movimiento y que cerrar una pestaña de Nook conserve la terminal original.

La firma ad hoc sirve para compilación local. La firma de distribución y la notarización siguen pendientes.
