# MicroPython tools layered on the shared AI development image.
FROM ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image:latest

USER root
RUN python -m venv /opt/esp32-tools \
    && /opt/esp32-tools/bin/pip install --no-cache-dir esptool mpremote \
    && ln -s /opt/esp32-tools/bin/esptool /usr/local/bin/esptool \
    && ln -s /opt/esp32-tools/bin/mpremote /usr/local/bin/mpremote
RUN runuser -u vscode -- esptool version \
    && runuser -u vscode -- mpremote --version
