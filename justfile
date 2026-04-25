# NOTE: `default` must stay the first recipe — `just` with no args runs
# whichever recipe appears first in the file, regardless of name.

# Default — run PX4 SITL with simulator and ground control
default: run


# ============================================================================
# Configuration
# ============================================================================

# QGroundControl
QGC_VERSION  := "v5.0.8"
QGC_APPIMAGE := "apps/QGroundControl.AppImage"
QGC_URL      := "https://github.com/mavlink/qgroundcontrol/releases/download/" + QGC_VERSION + "/QGroundControl-x86_64.AppImage"

# PX4
PX4_DIR       := "PX4-Autopilot"
AIRFRAMES_DIR := PX4_DIR + "/ROMFS/px4fmu_common/init.d-posix/airframes"

# Zellij session
LAYOUT_FILE    := "/tmp/px4_layout.kdl"
ZELLIJ_SESSION := "px4"


# ============================================================================
# Setup
# ============================================================================

# Initialize submodules and download QGroundControl
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


# ============================================================================
# Simulation
# ============================================================================

# Run PX4 SITL + Gazebo + QGC. With no arg, shows an interactive picker.
run vehicle="": init
	#!/usr/bin/env bash
	set -e
	vehicle="{{vehicle}}"
	[ -z "$vehicle" ] && vehicle=$(just _pick-vehicle)
	just _launch \
		"PX4 ($vehicle)" \
		"PX4" \
		"cd $(pwd)/{{PX4_DIR}} && make px4_sitl $vehicle EXTERNAL_MODULES_LOCATION=../"

# List SITL vehicle targets (e.g. gz_x500, gz_rc_cessna, gz_standard_vtol)
vehicles:
	@ls {{AIRFRAMES_DIR}} 2>/dev/null | sed -n 's/.*_gz_/gz_/p' | sort -u

# Close PX4 SITL, Gazebo, QGroundControl, and the zellij session
close:
	#!/usr/bin/env bash
	# label|pgrep-f pattern — single source of truth for what belongs to this stack
	patterns=(
		"PX4|PX4-Autopilot.*bin/px4"
		"PX4 (sitl)|px4_sitl_default"
		"Gazebo (gz sim)|gz sim"
		"Gazebo bridge|gz_"
		"make px4_sitl|make px4_sitl"
		"cmake px4_sitl|cmake.*px4_sitl"
		"ninja gz_*|ninja.*gz_"
		"QGroundControl|QGroundControl"
	)
	echo "Closing PX4 stack..."
	for entry in "${patterns[@]}"; do
		IFS='|' read -r label pat <<< "$entry"
		if pgrep -f "$pat" >/dev/null 2>&1; then
			echo "  → $label"
			pkill -f "$pat" 2>/dev/null || true
		fi
	done
	rm -f /tmp/px4-sock-* 2>/dev/null || true
	sleep 1
	# Force-kill any stragglers
	for entry in "${patterns[@]}"; do
		IFS='|' read -r _ pat <<< "$entry"
		pkill -9 -f "$pat" 2>/dev/null || true
	done
	echo
	echo "✓ Cleanup complete"
	pgrep -f "PX4-Autopilot.*bin/px4" >/dev/null 2>&1 && echo "⚠ PX4 still running"    || echo "✓ PX4 closed"
	pgrep -f "gz sim"                 >/dev/null 2>&1 && echo "⚠ Gazebo still running" || echo "✓ Gazebo closed"
	pgrep -f "QGroundControl"         >/dev/null 2>&1 && echo "⚠ QGC still running"    || echo "✓ QGroundControl closed"
	# MUST be last: killing the session may also kill this shell if 'just close'
	# was invoked from inside a zellij pane.
	zellij kill-session   {{ZELLIJ_SESSION}} >/dev/null 2>&1 || true
	zellij delete-session {{ZELLIJ_SESSION}} --force >/dev/null 2>&1 || true


# ============================================================================
# Hardware
# ============================================================================

# Build firmware for hardware (interactive picker)
build_hw:
	#!/usr/bin/env bash
	set -e
	targets=(
		"Cube Orange|cubepilot_cubeorange"
		"Holybro 6C mini|px4_fmu-v6c"
	)
	echo "Select hardware:"
	for i in "${!targets[@]}"; do
		printf "  %d) %s\n" "$((i+1))" "${targets[$i]%%|*}"
	done
	read -p "Enter choice (default: 1): " choice
	target="${targets[$((${choice:-1}-1))]#*|}"
	[ -z "$target" ] && { echo "Invalid choice"; exit 1; }
	(cd {{PX4_DIR}} && make ${target}_default EXTERNAL_MODULES_LOCATION=../)
	artifact="{{PX4_DIR}}/build/${target}_default/${target}_default.px4"
	echo
	echo "✓ Build complete: ${artifact}"
	# WSL2: offer to copy to Windows Downloads
	if grep -qi microsoft /proc/version; then
		read -p "WSL2 detected — copy to Windows Downloads? [Y/n]: " ans
		if [[ "${ans:-Y}" =~ ^[Yy]$ ]]; then
			win_user=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')
			win_dl="/mnt/c/Users/${win_user}/Downloads"
			if [ -n "$win_user" ] && [ -d "$win_dl" ]; then
				cp -v "${artifact}" "$win_dl/" && echo "✓ Copied to Windows Downloads"
			else
				echo "⚠ Could not find Windows Downloads folder"
			fi
		fi
	fi


# ============================================================================
# Maintenance
# ============================================================================

# Clean PX4 build artifacts
clean:
	cd {{PX4_DIR}} && make clean


# ============================================================================
# Private helpers
# ============================================================================

# Interactive vehicle picker — chosen target → stdout, menu/prompts → stderr.
[private]
_pick-vehicle:
	#!/usr/bin/env bash
	set -e
	options=(
		"gz_x500|Quadcopter (X500)"
		"gz_rc_cessna|Fixed-wing (RC Cessna)"
		"gz_advanced_plane|Fixed-wing (Advanced Plane)"
		"gz_standard_vtol|VTOL (Standard)"
		"gz_tiltrotor|VTOL (Tiltrotor)"
		"gz_quadtailsitter|VTOL (Quad Tailsitter)"
		"gz_rover_ackermann|Rover (Ackermann)"
		"gz_rover_differential|Rover (Differential)"
		"gz_uuv_bluerov2_heavy|Underwater (BlueROV2 Heavy)"
	)
	other=$((${#options[@]} + 1))
	# Menu and prompts go to stderr; only the chosen target goes to stdout
	# so the caller can do `vehicle=$(just _pick-vehicle)`.
	{
		echo "Select vehicle:"
		for i in "${!options[@]}"; do
			IFS='|' read -r tgt label <<< "${options[$i]}"
			printf "  %2d) %-35s %s\n" "$((i+1))" "$label" "$tgt"
		done
		printf "  %2d) %s\n" "$other" "Other (type a custom target — see 'just vehicles')"
	} >&2
	read -p "Enter choice (default: 1): " choice
	choice=${choice:-1}
	if [ "$choice" = "$other" ]; then
		read -p "Vehicle target (e.g. gz_x500_vision): " vehicle
	elif [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#options[@]}" ]; then
		vehicle="${options[$((choice-1))]%%|*}"
	else
		echo "Invalid choice" >&2; exit 1
	fi
	[ -z "$vehicle" ] && { echo "No vehicle selected" >&2; exit 1; }
	echo "$vehicle"

# Build the zellij 3-pane layout (PX4 / QGC / Terminal) and launch the session.
# px4_cmd is the bash command for the PX4 pane; qgc_delay is seconds to wait
# before launching QGC (long enough for the PX4 build to register the port).
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
	# -l with --session attaches-and-adds-tab; -n always creates a new session.
	zellij delete-session {{ZELLIJ_SESSION}} --force >/dev/null 2>&1 || true
	exec zellij --session {{ZELLIJ_SESSION}} --new-session-with-layout {{LAYOUT_FILE}}
