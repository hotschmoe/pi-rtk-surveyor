# Source notes

## build.zig

The daemon uses one thread and an epoll loop. Release binaries are stripped by default; use
`-Dstrip=false` for symbolized debugging. Error tracing and unwind tables are omitted for the
stripped field binary, which cannot symbolize stack traces.

## scripts/add-wifi.sh

The Wi-Fi password is read without echo, sent through SSH standard input, and stored only in a
root-owned NetworkManager profile. Existing profiles remain available, selected by priority.

## scripts/gnss-tap.sh

The service is stopped before the UART capture and restarted by the exit trap, including on Ctrl-C.

## scripts/lib.sh

The USB gadget host is preferred; the Wi-Fi alias is the fallback when USB is unavailable.

## scripts/provision.sh

Provisioning preserves an existing unit configuration and does not handle Wi-Fi credentials. The
old daemon and serial getty are disabled to release the UART.
