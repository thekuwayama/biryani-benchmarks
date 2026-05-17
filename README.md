# biryani-benchmarks

Requires macOS (Apple Silicon) and [Lima](https://lima-vm.io/).

```sh-session
$ brew install lima

$ git clone --recurse-submodules https://github.com/thekuwayama/biryani-benchmarks.git

$ cd biryani-benchmarks

$ limactl start lima.yaml

$ limactl shell --workdir /biryani-benchmarks lima
```

To generate a FlameGraph from the load test:

```sh-session
$ sudo env PATH="$PATH" perf record -e cpu-clock -F 99 --call-graph dwarf -m 512M -o /tmp/perf.data bundle exec rake load

# Ctrl+C

$ sudo perf script -i /tmp/perf.data | ./FlameGraph/stackcollapse-perf.pl | ./FlameGraph/flamegraph.pl > raw/flamegraph.svg
```
