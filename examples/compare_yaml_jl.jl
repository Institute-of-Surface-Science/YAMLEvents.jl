import YAML
using YAMLEvents

# The task: find every double-quoted scalar and report its source location.
# This is useful for syntax-aware checks such as enforcing a quoting convention.
source = """
service:
  name: "api"
  paths: ["/health", '/metrics']
  options: {mode: "safe"}
"""

const ScalarLocation = @NamedTuple{value::String, line::Int, column::Int}

function double_quoted_scalars_with_yaml(source)
    # YAML.jl has an event stream internally, but it is not a Julia iterator.
    # Callers must construct the backend objects, advance the stream manually,
    # and recognize the event that terminates the stream.
    tokens = YAML.TokenStream(IOBuffer(source))
    stream = YAML.EventStream(tokens)
    result = ScalarLocation[]

    while true
        event = YAML.forward!(stream)
        if event isa YAML.ScalarEvent && event.style == '"'
            push!(result, (value = event.value,
                           line = Int(event.start_mark.line),
                           column = Int(event.start_mark.column)))
        elseif event isa YAML.StreamEndEvent
            return result
        end
    end
end

function double_quoted_scalars_with_yamlevents(source)
    # YAMLEvents.jl exposes the same information through ordinary iteration, so
    # filtering and projection can be expressed directly as a comprehension.
    return [(value = event.value,
             line = Int(event.start_mark.line),
             column = Int(event.start_mark.column))
            for event in parse_events(source)
            if event isa ScalarEvent && event.style == '"']
end

yaml_result = double_quoted_scalars_with_yaml(source)
yamlevents_result = double_quoted_scalars_with_yamlevents(source)

# Both implementations produce exactly the same result.
@assert typeof(yaml_result) === typeof(yamlevents_result)
@assert yaml_result == yamlevents_result
println("YAML.jl result:      ", yaml_result)
println("YAMLEvents.jl result: ", yamlevents_result)
