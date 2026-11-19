# SEAM Build & Device Verification Makefile

ANDROID_AGENT_JAR := dist/seam-agent.jar
MACOS_HOST_BIN    := dist/seam-host
REMOTE_TMP_JAR    := /data/local/tmp/seam-agent.jar
ADB               ?= adb

.PHONY: all build build-agent build-host deploy-agent app run edge devices device-info self-test calibrate usb-test wifi-test switch-test clean

all: build

build: build-agent build-host

## Compile android-agent Java 17 sources to DEX archive (dist/seam-agent.jar)
build-agent:
	@./scripts/build-agent.sh

## Compile macos-host Swift 6 package to native Apple Silicon executable (dist/seam-host & dist/SEAM.app)
build-host:
	@./scripts/build-host.sh

## Push dist/seam-agent.jar to the connected Android device
deploy-agent: build-agent
	@echo "==> Deploying $(ANDROID_AGENT_JAR) to $(REMOTE_TMP_JAR)..."
	@$(ADB) push $(ANDROID_AGENT_JAR) $(REMOTE_TMP_JAR)

## Launch the native macOS SEAM Control Center & Menu-Bar UI app
app: build
	@./$(MACOS_HOST_BIN) app

run: app

## Launch headless macOS <-> Android screen-edge crossing mode in the terminal
edge: build
	@./$(MACOS_HOST_BIN) edge

## List connected Android devices discovered by seam-host
devices: build-host
	@./$(MACOS_HOST_BIN) devices

## Query display geometry, /dev/uhid permissions, and PointerChoreographer state
device-info: deploy-agent
	@echo "==> Running SEAM Agent Device Info..."
	@$(ADB) shell CLASSPATH=$(REMOTE_TMP_JAR) app_process /system/bin --nice-name=seam_agent com.seam.agent.Main --info

## Run the native /dev/uhid mouse cursor and keyboard verification sequence on the device
self-test: deploy-agent
	@echo "==> Running SEAM Native Hardware Cursor & Keyboard Self-Test..."
	@$(ADB) shell CLASSPATH=$(REMOTE_TMP_JAR) app_process /system/bin --nice-name=seam_agent com.seam.agent.Main --self-test

## Run 16-bit corner-homing and pointer velocity calibration
calibrate: deploy-agent
	@echo "==> Running SEAM Pointer Homing & Velocity Calibration..."
	@$(ADB) shell CLASSPATH=$(REMOTE_TMP_JAR) app_process /system/bin --nice-name=seam_agent com.seam.agent.Main --calibrate

## Run end-to-end macOS -> USB ADB Socket -> Android /dev/uhid transport verification
usb-test: build
	@./$(MACOS_HOST_BIN) usb-test

## Run end-to-end macOS -> Wi-Fi (TCP Control + Authenticated UDP Fast-Path) -> Android /dev/uhid verification
wifi-test: build
	@./$(MACOS_HOST_BIN) wifi-test

## Run live zero-downtime USB <-> Wi-Fi transport switching and cable-pull failover verification
switch-test: build
	@./$(MACOS_HOST_BIN) switch-test

## Remove build and distribution artifacts
clean:
	@rm -rf build dist macos-host/.build
	@echo "==> Cleaned build/, dist/, and macos-host/.build"
