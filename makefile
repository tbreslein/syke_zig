RELEASE_FLAGS := "--release=fast -p ~/.local"

.PHONY: all build install run test clean

all: build

install:
	ARGS=${RELEASE_FLAGS} ${MAKE} build

build:
	zig build $(ARGS)

run:
	zig build run -- $(ARGS)

test:
	zig build test --summary all

clean:
	rm -fr ./.zig-cache/ ./zig-out/ ~/.local/bin/syke
