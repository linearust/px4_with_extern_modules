# Gazebo Classic via Docker — separate from native gz to avoid build-dir
# permission contamination. Invoke with:
#
#   just -f classic.just <recipe>
#
# Or with an alias in your shell rc:
#   alias jc='just -f $(git rev-parse --show-toplevel)/classic.just'

# NOTE: `default` must stay the first recipe — `just` with no args runs
# whichever recipe appears first in the file, regardless of name.

# Default — run cloudship via Docker
default: run


# ============================================================================
# Configuration
# ============================================================================

# QGroundControl
QGC_VERSION  := "v5.0.8"
QGC_APPIMAGE := "apps/QGroundControl.AppImage"
QGC_URL      := "https://github.com/mavlink/qgroundcontrol/releases/download/" + QGC_VERSION + "/QGroundControl-x86_64.AppImage"

# PX4
PX4_DIR := "PX4-Autopilot"

# Zellij session — distinct from main 'px4' so the two stacks don't tread on
# each other (you can run native gz and classic mutually exclusively, but
# 'close' on one won't accidentally tear down the other).
LAYOUT_FILE    := "/tmp/px4_classic_layout.kdl"
ZELLIJ_SESSION := "px4-classic"

# Gazebo Classic via Docker. gazebo11 only ships up to Ubuntu 20.04 (focal),
# so this image is the canonical home for Gazebo Classic + PX4.
DOCKER_IMAGE := "px4io/px4-dev-simulation-focal:latest"
DOCKER_NAME  := "px4-classic"


# ============================================================================
# Setup
# ============================================================================

# Initialize submodules, download QGC, and pull the Docker image
init:
	#!/usr/bin/env bash
	set -e
	git pull --rebase --autostash
	git submodule update --init --remote {{PX4_DIR}}
	(cd {{PX4_DIR}} && git submodule update --init --recursive)
	mkdir -p apps
	if [ ! -f {{QGC_APPIMAGE}} ] || [ "$(cat {{QGC_APPIMAGE}}.version 2>/dev/null)" != "{{QGC_VERSION}}" ]; then
		echo "Downloading QGroundControl {{QGC_VERSION}}..."
		wget -qO {{QGC_APPIMAGE}} "{{QGC_URL}}"
		chmod +x {{QGC_APPIMAGE}}
		echo "{{QGC_VERSION}}" > {{QGC_APPIMAGE}}.version
	fi
	echo "Pulling {{DOCKER_IMAGE}} (first time only, ~3 GB)..."
	docker pull {{DOCKER_IMAGE}} 2>&1 | tail -2


# ============================================================================
# Simulation
# ============================================================================

# Run an airship/Gazebo-Classic vehicle (default: cloudship) via Docker + WSLg
run vehicle="cloudship": init
	#!/usr/bin/env bash
	set -e
	# Permit local container X11 connections for Gazebo GUI
	command -v xhost >/dev/null 2>&1 && xhost +local: >/dev/null 2>&1 || true
	just -f {{justfile()}} _launch \
		"PX4-classic ({{vehicle}})" \
		"PX4 (Docker + Gazebo Classic)" \
		"just -f {{justfile()}} _run-docker {{vehicle}}" \
		8

# Close PX4 SITL, Gazebo, QGroundControl, the Docker container, and zellij session
close:
	#!/usr/bin/env bash
	echo "Closing classic stack..."
	# Docker first — stops PX4 + Gazebo running inside it
	if [ -n "$(docker ps -aq --filter name=^{{DOCKER_NAME}}$ 2>/dev/null)" ]; then
		echo "  → Docker ({{DOCKER_NAME}})"
		docker rm -f {{DOCKER_NAME}} >/dev/null 2>&1 || true
	fi
	# QGC runs on the host
	if pgrep -f "QGroundControl" >/dev/null 2>&1; then
		echo "  → QGroundControl"
		pkill -f "QGroundControl" 2>/dev/null || true
	fi
	rm -f /tmp/px4-sock-* 2>/dev/null || true
	sleep 1
	pkill -KILL -f "QGroundControl" 2>/dev/null || true
	echo
	echo "✓ Cleanup complete"
	docker ps -aq --filter name=^{{DOCKER_NAME}}$ 2>/dev/null | grep -q . && echo "⚠ Container still present" || echo "✓ Docker container removed"
	pgrep -f "QGroundControl" >/dev/null 2>&1 && echo "⚠ QGC still running" || echo "✓ QGroundControl closed"
	# MUST be last: killing the session may also kill this shell if 'just close'
	# was invoked from inside a zellij pane.
	zellij kill-session   {{ZELLIJ_SESSION}} >/dev/null 2>&1 || true
	zellij delete-session {{ZELLIJ_SESSION}} --force >/dev/null 2>&1 || true


# ============================================================================
# Private helpers
# ============================================================================

# Build the zellij 3-pane layout (PX4 / QGC / Terminal) and launch the session.
[private]
_launch tab_label pane_label px4_cmd qgc_delay="5":
	#!/usr/bin/env bash
	set -e
	cat > {{LAYOUT_FILE}} <<KDL
	layout {
	    tab name="{{tab_label}}" {
	        pane split_direction="vertical" {
	            pane name="{{pane_label}}" {
	                command "bash"
	                args "-c" "{{px4_cmd}}"
	            }
	            pane split_direction="horizontal" {
	                pane name="QGC" {
	                    command "bash"
	                    args "-c" "sleep {{qgc_delay}} && $(pwd)/{{QGC_APPIMAGE}}"
	                }
	                pane name="Terminal" focus=true {
	                    command "bash"
	                }
	            }
	        }
	    }
	}
	KDL
	zellij delete-session {{ZELLIJ_SESSION}} --force >/dev/null 2>&1 || true
	exec zellij --session {{ZELLIJ_SESSION}} --new-session-with-layout {{LAYOUT_FILE}}

# Build & run PX4 SITL with Gazebo Classic inside the container.
# --user $(id -u):$(id -g) makes build artifacts on the host bind-mount owned
# by the host user, not root — preventing the contamination that breaks the
# native build's clean step. HOME=/tmp gives the in-container uid a writable
# home (the image's /etc/passwd doesn't include uid 1000).
[private]
_run-docker vehicle:
	#!/usr/bin/env bash
	set -e
	docker rm -f {{DOCKER_NAME}} >/dev/null 2>&1 || true
	docker run --rm -it \
		--name {{DOCKER_NAME}} \
		--network host \
		--user $(id -u):$(id -g) \
		-e HOME=/tmp \
		-e DISPLAY \
		-e WAYLAND_DISPLAY \
		-e PULSE_SERVER \
		-e XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir \
		-v /tmp/.X11-unix:/tmp/.X11-unix \
		-v /mnt/wslg:/mnt/wslg \
		-v "$(pwd)":/workspace \
		-w /workspace/{{PX4_DIR}} \
		{{DOCKER_IMAGE}} \
		bash -c "git config --global --add safe.directory '*' && make px4_sitl gazebo-classic_{{vehicle}} EXTERNAL_MODULES_LOCATION=../"
