# ipmisim

The `ipmisim` is a release of ipmi_sim from OpenIPMI, which can be used as an IPMI simulator for a virtual machine. The virtual machine talks to the simulator over a TCP socket, and the simulator can control the virtual machine aspects that it needs to be able to control.

## Configuration

The configuration files are under directory `config`, including:
* chassiscontrol
* vbmc.conf
* vbmc.emu

## Build Debian Package

```
autoreconf -i
debuild --no-lintian --no-tgz-check -us -uc
```

## Install ipmisim

```
echo "deb https://dl.bintray.com/rackhd/debian trusty main" | sudo tee -a /etc/apt/sources.list
sudo apt-get update
sudo apt-get install ipmisim
```

## Usage

```
ipmitool -I lanplus -H 172.31.128.1 -U admin -P admin chassis status
```
## Reference

[Debian New Maintainers' Guide](https://www.debian.org/doc/manuals/maint-guide/)
