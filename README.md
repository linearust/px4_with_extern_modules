# PX4 External Module Example

Template for developing PX4 external modules without modifying the core PX4 source code.

## Requirements

- [Ubuntu](https://ubuntu.com/download)
- Python 3 packages: [kconfiglib](https://pypi.org/project/kconfiglib/), [pyros-genmsg](https://pypi.org/project/pyros-genmsg/)
- [Gazebo Harmonic](https://gazebosim.org/docs/harmonic/install)
- [just](https://github.com/casey/just#installation)
- [zellij](https://zellij.dev/documentation/installation)

**Important**: Uninstall Anaconda/Miniconda if installed - they cause protobuf version conflicts with Gazebo.

## Usage

```bash
just --list --unsorted   # List available commands
```

## MAVLink Console Examples

### Motor Testing

Test motor 1 by spinning it at 10% throttle for 2 seconds:

```bash
actuator_test set -m 1 -v 0.10 -t 2
```
