# AI ESP32 Devbox

AI Devbox plus `esptool` for flashing Espressif chips and `mpremote` for working
with MicroPython. All base tools, agent mounts and caches are inherited.

## Apply and start

On the Docker host, authenticate to the private packages and apply:

```sh
gh auth login
gh auth refresh -h github.com -s read:packages
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-esp32-devbox
```

Prepare the host paths described in [base configuration guide](../src/ai-devbox/.devcontainer/README.md), then reopen the
project in VS Code or run `docker compose -f .devcontainer/docker-compose.yml up -d`.
Compose pulls `ghcr.io/wesleycamargo/devcontainer-template/ai-esp32-devbox-image:latest`.
A board is optional: the default container starts without a serial device.

## Connect a board

The serial device must be visible on the Linux Docker host. On Windows, attach
USB to WSL first using [Microsoft's USB instructions](https://learn.microsoft.com/windows/wsl/connect-usb).
A macOS serial path is not automatically available inside Docker's Linux VM;
use a Linux/WSL Docker host for the direct device mapping below.

On the Docker host, select the actual port and its numeric group:

```sh
export ESP32_SERIAL_PORT=/dev/ttyUSB0  # some boards use /dev/ttyACM0
export ESP32_SERIAL_GID=$(stat -c '%g' "$ESP32_SERIAL_PORT")
docker compose -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.serial.yml up -d
docker compose -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.serial.yml exec devcontainer mpremote connect /dev/ttyESP32 repl
```

For VS Code, put these variables in `.devcontainer/.env` and change
`dockerComposeFile` in `devcontainer.json` to
`["docker-compose.yml", "docker-compose.serial.yml"]`, then rebuild the container.
The mapping exposes only the selected device and grants its group to `vscode`.
Recreate the container if unplugging/replugging changes the device path.

With MicroPython already installed on the board:

```sh
mpremote connect /dev/ttyESP32 exec 'print("hello from ESP32")'
mpremote connect /dev/ttyESP32 run main.py
```

For initial firmware, select your exact board at
[MicroPython downloads](https://micropython.org/download/) and follow its flashing
instructions with `esptool`. Flash offsets and images differ by board.

## Publishing and updates

CI builds this Dockerfile on top of the published `ai-devbox-image:latest` and
publishes the private `ai-esp32-devbox` template and `ai-esp32-devbox-image` image.
Publish the base first. Its updates do not automatically rebuild this variant;
run the ESP32 publish workflow afterward to adopt them. Consumers pull the image
and recreate the container to update.

Project skills ship as `.agents/skills` files. Startup does not install or update them.
