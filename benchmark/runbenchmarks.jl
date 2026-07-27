using PkgBenchmark
using YAMLEvents

const BENCHMARK_SCRIPT = joinpath(@__DIR__, "benchmarks.jl")
const TIME_TOLERANCE = 0.25
const MEMORY_TOLERANCE = 0.10

function write_report(io, result)
    if result isa BenchmarkJudgement
        export_markdown(io, result; export_invariants = true)
    else
        export_markdown(io, result)
    end
    return nothing
end

function report(result)
    println("Benchmark differences are informational and do not fail this job.")
    write_report(stdout, result)

    summary = get(ENV, "GITHUB_STEP_SUMMARY", nothing)
    summary === nothing && return nothing
    open(summary, "a") do io
        println(io, "> Benchmark differences are informational and do not fail this job.")
        println(io)
        write_report(io, result)
    end
    return nothing
end

function main()
    length(ARGS) <= 1 || error("usage: runbenchmarks.jl [baseline-revision]")
    baseline = isempty(ARGS) ? nothing : only(ARGS)
    result = if baseline === nothing
        benchmarkpkg(YAMLEvents; script = BENCHMARK_SCRIPT, verbose = true)
    else
        judge(YAMLEvents, baseline; script = BENCHMARK_SCRIPT, verbose = true,
              judgekwargs = Dict{Symbol, Any}(:time_tolerance => TIME_TOLERANCE,
                                               :memory_tolerance => MEMORY_TOLERANCE))
    end
    report(result)
    return nothing
end

main()
