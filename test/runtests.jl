using Aqua
using StringEncodings: encode
using Test
using YAMLEvents

include("event_api.jl")
include("parser_corpus.jl")

@testset "Package quality" begin
    Aqua.test_all(YAMLEvents)
end
