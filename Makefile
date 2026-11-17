PREFIX ?= /Applications
APP := Net CPU.app

.PHONY: build install clean

build:
	rm -rf "build/$(APP)"
	mkdir -p "build/$(APP)/Contents/MacOS"
	cp Info.plist "build/$(APP)/Contents/"
	swiftc -O -o "build/$(APP)/Contents/MacOS/NetCPU" main.swift
	# swiftc signs only the executable, under its file name. Signing the bundle
	# gives it the bundle id, which macOS needs to keep it in the menu bar.
	codesign --force --sign - "build/$(APP)"

install: build
	pkill -x NetCPU || true
	while pgrep -qx NetCPU; do sleep 0.1; done
	rm -rf "$(PREFIX)/$(APP)"
	ditto "build/$(APP)" "$(PREFIX)/$(APP)"
	open -g "$(PREFIX)/$(APP)"

clean:
	rm -rf build
