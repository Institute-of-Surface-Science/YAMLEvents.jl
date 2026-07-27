# Benchmarks

The suite measures iterator construction and complete event collection for small
inputs, large plain mappings, quoted and escaped values with percent-encoded
tags, and multi-document streams with unknown directives. The sources are
generated deterministically and are validated through both `String` and `IO`
inputs before benchmarks run. Permissive and strict streaming validation are
also measured for the large plain mapping.

From the repository root, initialize the isolated benchmark environment:

```sh
julia --project=benchmark -e 'using Pkg; Pkg.develop(Pkg.PackageSpec(path=pwd())); Pkg.instantiate()'
```

Run absolute measurements for the current checkout:

```sh
julia --project=benchmark benchmark/runbenchmarks.jl
```

Compare the current checkout with a revision:

```sh
git fetch origin main
julia --project=benchmark benchmark/runbenchmarks.jl origin/main
```

Comparison temporarily checks out the baseline, so it requires a clean working
tree. The generated `benchmark/Manifest.toml` and `benchmark/tune.json` are
ignored. Reports include all time and memory ratios; they are informational and
are not a pass/fail performance gate.
