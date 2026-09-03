#!/bin/bash -Eeu

# gomock's mocks are written by mockgen, which a kata runs on every [test]
# press. Installing it as a binary here means a press execs it rather than
# compiling it, which is the difference between milliseconds and seconds.
go install go.uber.org/mock/mockgen@v0.6.0

# A [test] press compiles the kata's packages, the gomock library, and the test
# variant of each, then links a test binary. None of that survives a press,
# because a press runs in a container thrown away afterwards, so every press is
# a first press. The warm-up below pays for all of it once, here, where the
# result is baked into the image every press reads.
#
# It is shaped like the start-point kata, an interface carrying a //go:generate
# line, the mock generated from it, and a test driving the two through gomock,
# so the cache entries it leaves are the ones a kata reaches for. The module is
# named as the start-point's go.mod names it, because a compiled package is
# cached under its import path and a different name would cache under a path no
# kata ever asks for.
mkdir /go/build-cache
mkdir warmup && cd warmup

cat > go.mod << 'EOF'
module cyber-dojo-go-gomock

go 1.26.1

require go.uber.org/mock v0.6.0
EOF

cat > hiker.go << 'EOF'
package hiker

//go:generate mockgen -source=hiker.go -destination=mock_hiker.go -package=hiker

type Listener interface {
    OnAnswer(answer int)
}

type Hiker struct {
    listener Listener
}

func NewHiker(listener Listener) *Hiker {
    return &Hiker{listener: listener}
}

func (hiker *Hiker) Answer() {
    hiker.listener.OnAnswer(6 * 7)
}
EOF

cat > hiker_test.go << 'EOF'
package hiker

import (
    "testing"

    "go.uber.org/mock/gomock"
)

func Test_life_the_universe_and_everything(t *testing.T) {
    controller := gomock.NewController(t)
    listener := NewMockListener(controller)
    listener.EXPECT().OnAnswer(42)
    NewHiker(listener).Answer()
}
EOF

# Downloads go.uber.org/mock into the module cache and writes the go.sum the
# start-point ships. A kata runs with GOPROXY=off, so the module has to be here
# already or nothing resolves.
go mod tidy

go generate ./...
GOCACHE=/go/build-cache go test -count=1 ./...

# A cache is keyed on the toolchain and the flags that filled it. If those ever
# drift from what cyber-dojo.sh runs, go silently rebuilds and the press is
# merely as slow as it was before. This compares a run against the warmed cache
# with one against an empty one, and insists the warm run be several times
# quicker.
#
# The comparison is against a cold run rather than a fixed number of seconds
# because this same script runs under QEMU when the arm64 half of the image is
# built on an amd64 machine. Emulated, a warm run takes seconds where it takes a
# fraction of one natively, so any threshold that fits one fails the other. A
# ratio holds either way: both runs are slowed by the same emulation.
#
# It times go test alone. mockgen is a binary already, so go generate costs the
# same whether the cache is warm or cold, and including it would only dilute the
# ratio being measured.
go_test_seconds()
{
  local -r cache_dir="${1}"
  { TIMEFORMAT='%3R'; time GOCACHE="${cache_dir}" go test -count=1 ./... > /dev/null 2>&1; } 2>&1
}

readonly COLD_SECONDS=$(go_test_seconds /tmp/cold-cache)
readonly WARM_SECONDS=$(go_test_seconds /go/build-cache)
echo "[go test] cold ${COLD_SECONDS}s, warm ${WARM_SECONDS}s"
rm -rf /tmp/cold-cache

if [ "$(echo "${COLD_SECONDS} > ${WARM_SECONDS} * 3" | bc -l)" != '1' ]; then
  >&2 echo "Expected a warmed cache to be several times quicker than an empty one."
  >&2 echo "The cache is not being hit, so a kata's first press will rebuild."
  exit 42
fi

cd ..
rm -rf warmup

# The cache is written here by root and read by the sandbox user a kata runs as,
# which also adds to it, so it has to be writable by everyone.
chmod -R 777 /go/build-cache
