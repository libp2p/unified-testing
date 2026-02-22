# Unified interoperability, scaling, and performance testing framework for libp2p implementations

[![Made by Protocol Labs](https://img.shields.io/badge/made%20by-Protocol%20Labs-blue.svg?style=flat-square)](http://protocol.ai)

This repository contains:
* interoperability tests for libp2p's transport layers across different implementations and versions
* performance tests for libp2p implementations measured against iperf, https, and quic-go baselines
* hole-punching tests for libp2p implementations that support AutoNAT, Relaying, and DCUtR protocols


## History

The original version of this testing framework can be found in the [old
test-plans repo](https://github.com/libp2p/test-plans). Historically, the
testing framework used Testground. That was later re-written in Node and used
Docker. This new unified framework uses Bash and Docker to drive tests to work
universally on Linux, macOS, and Windows with zero dependency maintenance. The
Bash conventions followed in this repo can be found here:
[docs/bash.md](docs/bash.md).

## Documentation

The entire test framework is well documented in the `docs/` subfolder as well
as in the Bash scripts themselves. If you are wanting to write a test
application that is compatible with this test framework, there are docs on
writing a [transport test](docs/write-a-transport-test-app.md), [perf
test](docs/write-a-perf-test-app.md), and [hole punch
test](docs/write-a-hole-punch-test-app.md).

## License

Dual-licensed: [MIT](./LICENSE-MIT), [Apache Software License v2](./LICENSE-APACHE), by way of the
[Permissive License Stack](https://protocol.ai/blog/announcing-the-permissive-license-stack/).
